const std = @import("std");
const wire = @import("wire.zig");

pub const ns_per_ms: i128 = 1_000_000;
pub const ns_per_sec: i128 = 1_000_000_000;

/// 0001-01-01T00:00:00Z
pub const min_timestamp_seconds: i64 = -62_135_596_800;
/// 9999-12-31T23:59:59Z
pub const max_timestamp_seconds: i64 = 253_402_300_799;

/// ±10,000 years (365.25 * 86400 * 10000)
pub const min_duration_seconds: i64 = -315_576_000_000;
pub const max_duration_seconds: i64 = 315_576_000_000;

pub const default_type_url_prefix: []const u8 = "type.googleapis.com/";

pub const WktError = error{
    InvalidFormat,
    OutOfRange,
    InvalidNanos,
    SignMismatch,
};

pub const AnyError = wire.DecodeError || error{
    TypeUrlMismatch,
};

// ---------------------------------------------------------------------------
// google.protobuf.Timestamp
// ---------------------------------------------------------------------------

pub fn validateTimestamp(ts: anytype) WktError!void {
    if (ts.seconds < min_timestamp_seconds or ts.seconds > max_timestamp_seconds) {
        return error.OutOfRange;
    }
    if (ts.nanos < 0 or ts.nanos > 999_999_999) {
        return error.InvalidNanos;
    }
}

pub fn timestampFromUnixSeconds(comptime TsT: type, seconds: i64) WktError!TsT {
    const out: TsT = .{ .seconds = seconds, .nanos = 0 };
    try validateTimestamp(out);
    return out;
}

pub fn timestampFromUnixMillis(comptime TsT: type, millis: i64) WktError!TsT {
    return timestampFromUnixNanos(TsT, @as(i128, millis) * ns_per_ms);
}

pub fn timestampFromUnixNanos(comptime TsT: type, total_ns: i128) WktError!TsT {
    // Timestamp nanos are always non-negative [0, 999_999_999], so floor division matches spec.
    const secs_128 = @divFloor(total_ns, ns_per_sec);
    const rem_128 = @mod(total_ns, ns_per_sec);
    if (secs_128 < min_timestamp_seconds or secs_128 > max_timestamp_seconds) {
        return error.OutOfRange;
    }
    return .{
        .seconds = @intCast(secs_128),
        .nanos = @intCast(rem_128),
    };
}

pub fn timestampToUnixNanos(ts: anytype) WktError!i128 {
    try validateTimestamp(ts);
    return @as(i128, ts.seconds) * ns_per_sec + @as(i128, ts.nanos);
}

pub fn timestampToUnixMillis(ts: anytype) WktError!i64 {
    const ns = try timestampToUnixNanos(ts);
    return @intCast(@divFloor(ns, ns_per_ms));
}

pub fn timestampAddDuration(ts: anytype, dur: anytype) WktError!@TypeOf(ts) {
    const ts_ns = try timestampToUnixNanos(ts);
    const dur_ns = try durationToNanos(dur);
    return timestampFromUnixNanos(@TypeOf(ts), ts_ns + dur_ns);
}

pub fn timestampDiff(comptime DurT: type, a: anytype, b: anytype) WktError!DurT {
    const a_ns = try timestampToUnixNanos(a);
    const b_ns = try timestampToUnixNanos(b);
    return durationFromNanos(DurT, a_ns - b_ns);
}

pub fn timestampOrder(a: anytype, b: anytype) std.math.Order {
    const sec_ord = std.math.order(a.seconds, b.seconds);
    if (sec_ord != .eq) return sec_ord;
    return std.math.order(a.nanos, b.nanos);
}

/// Formats `Timestamp` as canonical RFC 3339 UTC (`YYYY-MM-DDTHH:MM:SS[.fff|ffffff|fffffffff]Z`)
/// into a stack buffer with zero allocations. Max length is 30 bytes.
pub fn formatTimestampBuf(ts: anytype, buf: *[32]u8) WktError![]const u8 {
    try validateTimestamp(ts);

    const days = @divFloor(ts.seconds, 86_400);
    const sod: u32 = @intCast(@mod(ts.seconds, 86_400));
    const date = civilFromDays(days);

    const hour: u8 = @intCast(sod / 3600);
    const rem_h: u32 = sod % 3600;
    const minute: u8 = @intCast(rem_h / 60);
    const second: u8 = @intCast(rem_h % 60);

    var pos: usize = 0;
    writeFixedDigits(buf, &pos, date.year, 4);
    buf[pos] = '-';
    pos += 1;
    writeFixedDigits(buf, &pos, date.month, 2);
    buf[pos] = '-';
    pos += 1;
    writeFixedDigits(buf, &pos, date.day, 2);
    buf[pos] = 'T';
    pos += 1;
    writeFixedDigits(buf, &pos, hour, 2);
    buf[pos] = ':';
    pos += 1;
    writeFixedDigits(buf, &pos, minute, 2);
    buf[pos] = ':';
    pos += 1;
    writeFixedDigits(buf, &pos, second, 2);

    writeCanonicalFraction(buf, &pos, @intCast(ts.nanos));
    buf[pos] = 'Z';
    pos += 1;
    return buf[0..pos];
}

pub fn formatTimestamp(ts: anytype, w: *wire.Writer) (WktError || wire.Writer.Error)!void {
    var tmp: [32]u8 = undefined;
    const text = try formatTimestampBuf(ts, &tmp);
    try w.writeAll(text);
}

/// Parses an RFC 3339 timestamp (`YYYY-MM-DD(T|t)HH:MM:SS[.frac](Z|z|±HH:MM)`) into `TsT`.
pub fn parseTimestamp(comptime TsT: type, input: []const u8) WktError!TsT {
    if (input.len < 20) return error.InvalidFormat;

    const year = try parseFixedDigits(u16, input[0..4]);
    if (input[4] != '-') return error.InvalidFormat;
    const month = try parseFixedDigits(u8, input[5..7]);
    if (input[7] != '-') return error.InvalidFormat;
    const day = try parseFixedDigits(u8, input[8..10]);
    if (input[10] != 'T' and input[10] != 't') return error.InvalidFormat;
    const hour = try parseFixedDigits(u8, input[11..13]);
    if (input[13] != ':') return error.InvalidFormat;
    const minute = try parseFixedDigits(u8, input[14..16]);
    if (input[16] != ':') return error.InvalidFormat;
    const second = try parseFixedDigits(u8, input[17..19]);

    if (year < 1 or year > 9999) return error.OutOfRange;
    if (month < 1 or month > 12) return error.InvalidFormat;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidFormat;
    if (hour > 23 or minute > 59 or second > 59) return error.InvalidFormat;

    var pos: usize = 19;
    var nanos: u32 = 0;
    if (pos < input.len and input[pos] == '.') {
        pos += 1;
        nanos = try parseFractionalNanos(input, &pos);
    }

    const tail = input[pos..];
    var offset_secs: i64 = 0;
    if (tail.len == 1 and (tail[0] == 'Z' or tail[0] == 'z')) {
        offset_secs = 0;
    } else if (tail.len == 6 and (tail[0] == '+' or tail[0] == '-') and tail[3] == ':') {
        const off_h = try parseFixedDigits(u8, tail[1..3]);
        const off_m = try parseFixedDigits(u8, tail[4..6]);
        if (off_h > 23 or off_m > 59) return error.InvalidFormat;
        const abs_off: i64 = @as(i64, off_h) * 3600 + @as(i64, off_m) * 60;
        offset_secs = if (tail[0] == '+') abs_off else -abs_off;
    } else {
        return error.InvalidFormat;
    }

    const days = daysFromCivil(year, month, day);
    const utc_secs = days * 86_400 +
        @as(i64, hour) * 3600 +
        @as(i64, minute) * 60 +
        @as(i64, second) - offset_secs;

    if (utc_secs < min_timestamp_seconds or utc_secs > max_timestamp_seconds) {
        return error.OutOfRange;
    }
    return .{
        .seconds = utc_secs,
        .nanos = @intCast(nanos),
    };
}

// ---------------------------------------------------------------------------
// google.protobuf.Duration
// ---------------------------------------------------------------------------

pub fn validateDuration(dur: anytype) WktError!void {
    if (dur.seconds < min_duration_seconds or dur.seconds > max_duration_seconds) {
        return error.OutOfRange;
    }
    if (dur.nanos < -999_999_999 or dur.nanos > 999_999_999) {
        return error.InvalidNanos;
    }
    if ((dur.seconds > 0 and dur.nanos < 0) or (dur.seconds < 0 and dur.nanos > 0)) {
        return error.SignMismatch;
    }
}

pub fn durationFromSeconds(comptime DurT: type, seconds: i64) WktError!DurT {
    const out: DurT = .{ .seconds = seconds, .nanos = 0 };
    try validateDuration(out);
    return out;
}

pub fn durationFromMillis(comptime DurT: type, millis: i64) WktError!DurT {
    return durationFromNanos(DurT, @as(i128, millis) * ns_per_ms);
}

pub fn durationFromNanos(comptime DurT: type, total_ns: i128) WktError!DurT {
    // Duration nanos share the sign of seconds, so truncating division matches spec.
    const secs_128 = @divTrunc(total_ns, ns_per_sec);
    const rem_128 = @rem(total_ns, ns_per_sec);
    if (secs_128 < min_duration_seconds or secs_128 > max_duration_seconds) {
        return error.OutOfRange;
    }
    return .{
        .seconds = @intCast(secs_128),
        .nanos = @intCast(rem_128),
    };
}

pub fn durationToNanos(dur: anytype) WktError!i128 {
    try validateDuration(dur);
    return @as(i128, dur.seconds) * ns_per_sec + @as(i128, dur.nanos);
}

pub fn durationToMillis(dur: anytype) WktError!i64 {
    const ns = try durationToNanos(dur);
    return @intCast(@divTrunc(ns, ns_per_ms));
}

pub fn durationAdd(a: anytype, b: anytype) WktError!@TypeOf(a) {
    const a_ns = try durationToNanos(a);
    const b_ns = try durationToNanos(b);
    return durationFromNanos(@TypeOf(a), a_ns + b_ns);
}

pub fn durationSub(a: anytype, b: anytype) WktError!@TypeOf(a) {
    const a_ns = try durationToNanos(a);
    const b_ns = try durationToNanos(b);
    return durationFromNanos(@TypeOf(a), a_ns - b_ns);
}

pub fn durationNegate(dur: anytype) WktError!@TypeOf(dur) {
    try validateDuration(dur);
    return .{
        .seconds = -dur.seconds,
        .nanos = -dur.nanos,
    };
}

pub fn durationOrder(a: anytype, b: anytype) std.math.Order {
    const sec_ord = std.math.order(a.seconds, b.seconds);
    if (sec_ord != .eq) return sec_ord;
    return std.math.order(a.nanos, b.nanos);
}

/// Formats `Duration` as canonical ProtoJSON (`[-]SECONDS[.fff|ffffff|fffffffff]s`).
/// Max length is 24 bytes.
pub fn formatDurationBuf(dur: anytype, buf: *[32]u8) WktError![]const u8 {
    try validateDuration(dur);

    var pos: usize = 0;
    if (dur.seconds < 0 or dur.nanos < 0) {
        buf[pos] = '-';
        pos += 1;
    }

    const abs_sec: u64 = @abs(dur.seconds);
    const abs_nanos: u32 = @abs(dur.nanos);
    writeUnsignedDecimal(buf, &pos, abs_sec);
    writeCanonicalFraction(buf, &pos, abs_nanos);
    buf[pos] = 's';
    pos += 1;
    return buf[0..pos];
}

pub fn formatDuration(dur: anytype, w: *wire.Writer) (WktError || wire.Writer.Error)!void {
    var tmp: [32]u8 = undefined;
    const text = try formatDurationBuf(dur, &tmp);
    try w.writeAll(text);
}

/// Parses a ProtoJSON duration string (`[-]SECONDS[.frac]s`) into `DurT`.
pub fn parseDuration(comptime DurT: type, input: []const u8) WktError!DurT {
    if (input.len < 2 or input[input.len - 1] != 's') return error.InvalidFormat;
    const body = input[0 .. input.len - 1];

    var pos: usize = 0;
    var negative = false;
    if (body[0] == '-') {
        negative = true;
        pos = 1;
    }

    if (pos >= body.len or !std.ascii.isDigit(body[pos])) return error.InvalidFormat;

    var sec: u64 = 0;
    while (pos < body.len and std.ascii.isDigit(body[pos])) : (pos += 1) {
        sec = sec * 10 + (body[pos] - '0');
        if (sec > @as(u64, @intCast(max_duration_seconds))) return error.OutOfRange;
    }

    var nanos: u32 = 0;
    if (pos < body.len) {
        if (body[pos] != '.') return error.InvalidFormat;
        pos += 1;
        nanos = try parseFractionalNanos(body, &pos);
    }
    if (pos != body.len) return error.InvalidFormat;

    const sec_i64: i64 = @intCast(sec);
    const nanos_i32: i32 = @intCast(nanos);
    return .{
        .seconds = if (negative) -sec_i64 else sec_i64,
        .nanos = if (negative) -nanos_i32 else nanos_i32,
    };
}

// ---------------------------------------------------------------------------
// google.protobuf.Any
// ---------------------------------------------------------------------------

fn MessageType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

/// Comptime `"type.googleapis.com/<proto_full_name>"` string for any generated message `M`.
pub fn anyTypeUrl(comptime M: type) []const u8 {
    return anyTypeUrlWithPrefix(default_type_url_prefix, M);
}

/// Comptime `"<prefix>/<proto_full_name>"` string (normalizes trailing `'/'` at comptime).
pub fn anyTypeUrlWithPrefix(comptime prefix: []const u8, comptime M: type) []const u8 {
    if (!@hasDecl(M, "proto_full_name")) {
        @compileError("type " ++ @typeName(M) ++ " is missing `pub const proto_full_name`");
    }
    if (prefix.len == 0) {
        @compileError("Any type_url prefix must be non-empty");
    }
    if (prefix[prefix.len - 1] == '/') {
        return prefix ++ M.proto_full_name;
    }
    return prefix ++ "/" ++ M.proto_full_name;
}

/// Extracts the full Protobuf message name after the last `'/'` in `type_url`.
pub fn anyTypeName(type_url: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, type_url, '/') orelse return null;
    if (slash + 1 >= type_url.len) return null;
    return type_url[slash + 1 ..];
}

/// Returns true if `any_msg.type_url` matches `M.proto_full_name` (regardless of URL domain prefix).
pub inline fn anyIs(any_msg: anytype, comptime M: type) bool {
    if (!@hasDecl(M, "proto_full_name")) {
        @compileError("type " ++ @typeName(M) ++ " is missing `pub const proto_full_name`");
    }
    const name = anyTypeName(any_msg.type_url) orelse return false;
    return std.mem.eql(u8, name, M.proto_full_name);
}

/// Zero-allocation unpack: checks `type_url` against `M.proto_full_name`, then decodes `value`.
pub fn unpackAny(any_msg: anytype, comptime M: type) AnyError!M {
    if (!anyIs(any_msg, M)) return error.TypeUrlMismatch;
    return M.decode(any_msg.value);
}

/// Zero-allocation pack into a caller-provided scratch buffer using `type.googleapis.com/`.
pub fn packAnySlice(comptime AnyT: type, msg: anytype, value_buf: []u8) wire.EncodeError!AnyT {
    return packAnyWithPrefixSlice(AnyT, default_type_url_prefix, msg, value_buf);
}

/// Zero-allocation pack into a caller-provided scratch buffer with a custom comptime URL prefix.
pub fn packAnyWithPrefixSlice(
    comptime AnyT: type,
    comptime prefix: []const u8,
    msg: anytype,
    value_buf: []u8,
) wire.EncodeError!AnyT {
    const M = MessageType(@TypeOf(msg));
    const encoded = try msg.encodeSlice(value_buf);
    return .{
        .type_url = comptime anyTypeUrlWithPrefix(prefix, M),
        .value = encoded,
    };
}

/// Allocator-backed pack for callers managing an arena or dynamic output buffer.
pub fn packAnyAlloc(comptime AnyT: type, allocator: wire.Allocator, msg: anytype) wire.Allocator.Error!AnyT {
    const M = MessageType(@TypeOf(msg));
    const size = msg.encodedSize();
    if (size == 0) {
        return .{
            .type_url = comptime anyTypeUrl(M),
            .value = "",
        };
    }
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    const encoded = msg.encodeSlice(buf) catch unreachable;
    return .{
        .type_url = comptime anyTypeUrl(M),
        .value = encoded,
    };
}

// ---------------------------------------------------------------------------
// Internal Calendar & Formatting Helpers
// ---------------------------------------------------------------------------

const CivilDate = struct {
    year: u16,
    month: u8,
    day: u8,
};

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

/// Howard Hinnant's civil-from-days algorithm (days since 1970-01-01 -> proleptic Gregorian date).
fn civilFromDays(days_since_epoch: i64) CivilDate {
    const z = days_since_epoch + 719_468;
    const era = @divFloor(z, 146_097);
    const doe: u64 = @intCast(z - era * 146_097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    var y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    if (m <= 2) y += 1;
    return .{
        .year = @intCast(y),
        .month = m,
        .day = d,
    };
}

/// Howard Hinnant's days-from-civil algorithm (proleptic Gregorian date -> days since 1970-01-01).
fn daysFromCivil(year: u16, month: u8, day: u8) i64 {
    const y: i64 = if (month <= 2) @as(i64, year) - 1 else @as(i64, year);
    const era = @divFloor(y, 400);
    const yoe: u64 = @intCast(y - era * 400);
    const m_adj: u64 = if (month > 2) month - 3 else month + 9;
    const doy: u64 = (153 * m_adj + 2) / 5 + day - 1;
    const doe: u64 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146_097 + @as(i64, @intCast(doe)) - 719_468;
}

fn writeFixedDigits(buf: *[32]u8, pos: *usize, value: u32, comptime width: usize) void {
    var v = value;
    var i: usize = width;
    while (i > 0) {
        i -= 1;
        buf[pos.* + i] = @as(u8, @intCast(v % 10)) + '0';
        v /= 10;
    }
    pos.* += width;
}

fn writeUnsignedDecimal(buf: *[32]u8, pos: *usize, value: u64) void {
    if (value == 0) {
        buf[pos.*] = '0';
        pos.* += 1;
        return;
    }
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        tmp[n] = @as(u8, @intCast(v % 10)) + '0';
        n += 1;
    }
    while (n > 0) {
        n -= 1;
        buf[pos.*] = tmp[n];
        pos.* += 1;
    }
}

fn writeCanonicalFraction(buf: *[32]u8, pos: *usize, nanos: u32) void {
    if (nanos == 0) return;
    buf[pos.*] = '.';
    pos.* += 1;
    if (nanos % 1_000_000 == 0) {
        writeFixedDigits(buf, pos, nanos / 1_000_000, 3);
    } else if (nanos % 1_000 == 0) {
        writeFixedDigits(buf, pos, nanos / 1_000, 6);
    } else {
        writeFixedDigits(buf, pos, nanos, 9);
    }
}

fn parseFixedDigits(comptime T: type, slice: []const u8) WktError!T {
    var val: T = 0;
    for (slice) |ch| {
        if (!std.ascii.isDigit(ch)) return error.InvalidFormat;
        val = val * 10 + @as(T, ch - '0');
    }
    return val;
}

fn parseFractionalNanos(input: []const u8, pos: *usize) WktError!u32 {
    var nanos: u32 = 0;
    var scale: u32 = 100_000_000;
    var digits: usize = 0;
    while (pos.* < input.len and std.ascii.isDigit(input[pos.*])) : (pos.* += 1) {
        if (scale == 0) return error.InvalidFormat;
        nanos += @as(u32, input[pos.*] - '0') * scale;
        scale /= 10;
        digits += 1;
    }
    if (digits == 0) return error.InvalidFormat;
    return nanos;
}
