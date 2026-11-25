const std = @import("std");
const wire = @import("wire.zig");
const wkt = @import("wkt.zig");

pub const EncodeOptions = struct {
    /// Emit fields that hold their proto3 default/zero value.
    emit_default_values: bool = false,
    /// Use original `.proto` snake_case names instead of lowerCamelCase `json_name`.
    preserve_proto_field_names: bool = false,
    /// Emit enum values as numeric `i32` instead of variant names.
    emit_enums_as_ints: bool = false,
};

pub const DecodeOptions = struct {
    /// Skip unknown JSON object keys and unknown enum string values instead of erroring.
    ignore_unknown_fields: bool = false,
    /// Maximum JSON and submessage nesting depth.
    max_depth: u32 = wire.max_recursion_depth,
};

pub const JsonFieldKind = enum {
    scalar,
    @"enum",
    message,
    lazy_message,
    repeated,
    map,
    oneof,
};

pub const JsonFieldMeta = struct {
    zig_name: []const u8,
    proto_name: []const u8,
    json_name: []const u8,
    kind: JsonFieldKind,
    is_bytes: bool = false,
    explicit_presence: bool = false,
    oneof_field: []const u8 = "",
    is_lazy: bool = false,
    elem_is_bytes: bool = false,
};

pub fn EncodeError(comptime W: type) type {
    return wire.WriterError(W) || wire.DecodeError || wkt.WktError;
}

pub const SliceEncodeError = wire.EncodeError || wire.DecodeError || wkt.WktError;

pub const DecodeError = wire.Allocator.Error || wkt.WktError || error{
    UnexpectedEof,
    InvalidJson,
    InvalidEscape,
    InvalidUtf8,
    InvalidNumber,
    NumberOutOfRange,
    InvalidBase64,
    UnknownField,
    UnknownEnumValue,
    DuplicateOneofField,
    RecursionLimitExceeded,
    TrailingTokens,
};

// ---------------------------------------------------------------------------
// Public Entry Points
// ---------------------------------------------------------------------------

pub fn encodeMessage(msg: anytype, w: anytype, opts: EncodeOptions) EncodeError(@TypeOf(w))!void {
    return encodeMessageWithTypes(msg, w, opts, .{});
}

pub fn encodeMessageWithTypes(
    msg: anytype,
    w: anytype,
    opts: EncodeOptions,
    comptime known_types: anytype,
) EncodeError(@TypeOf(w))!void {
    return encodeMessageDepth(msg, w, opts, wire.max_recursion_depth, known_types);
}

pub fn encodeMessageSlice(msg: anytype, buf: []u8, opts: EncodeOptions) SliceEncodeError![]const u8 {
    return encodeMessageSliceWithTypes(msg, buf, opts, .{});
}

pub fn encodeMessageSliceWithTypes(
    msg: anytype,
    buf: []u8,
    opts: EncodeOptions,
    comptime known_types: anytype,
) SliceEncodeError![]const u8 {
    var sw = wire.SliceWriter.init(buf);
    try encodeMessageWithTypes(msg, &sw, opts, known_types);
    return sw.written();
}

pub fn decodeMessage(
    comptime M: type,
    arena: wire.Allocator,
    input: []const u8,
    opts: DecodeOptions,
) DecodeError!M {
    return decodeMessageWithTypes(M, arena, input, opts, .{});
}

pub fn decodeMessageWithTypes(
    comptime M: type,
    arena: wire.Allocator,
    input: []const u8,
    opts: DecodeOptions,
    comptime known_types: anytype,
) DecodeError!M {
    var p = JsonParser{ .input = input };
    const out = try decodeMessageDepth(M, arena, &p, opts, opts.max_depth, known_types);
    p.skipWs();
    if (!p.eof()) return error.TrailingTokens;
    return out;
}

// ---------------------------------------------------------------------------
// WKT Classification
// ---------------------------------------------------------------------------

fn isSpecialWkt(comptime name: []const u8) bool {
    const names = [_][]const u8{
        "google.protobuf.Timestamp",
        "google.protobuf.Duration",
        "google.protobuf.Empty",
        "google.protobuf.FieldMask",
        "google.protobuf.Any",
        "google.protobuf.Struct",
        "google.protobuf.ListValue",
        "google.protobuf.Value",
        "google.protobuf.DoubleValue",
        "google.protobuf.FloatValue",
        "google.protobuf.Int64Value",
        "google.protobuf.UInt64Value",
        "google.protobuf.Int32Value",
        "google.protobuf.UInt32Value",
        "google.protobuf.BoolValue",
        "google.protobuf.StringValue",
        "google.protobuf.BytesValue",
    };
    inline for (names) |n| {
        if (comptime std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

fn isNullValueEnum(comptime E: type) bool {
    const e = @typeInfo(E).@"enum";
    return e.field_names.len == 1 and std.mem.eql(u8, e.field_names[0], "NULL_VALUE");
}

// ---------------------------------------------------------------------------
// Zero-Allocation ProtoJSON Serializer
// ---------------------------------------------------------------------------

fn encodeMessageDepth(
    msg: anytype,
    w: anytype,
    opts: EncodeOptions,
    depth: u32,
    comptime known_types: anytype,
) EncodeError(@TypeOf(w))!void {
    @setEvalBranchQuota(100_000);
    if (depth == 0) return error.RecursionLimitExceeded;
    const M = @TypeOf(msg);

    if (comptime @hasDecl(M, "proto_full_name") and isSpecialWkt(M.proto_full_name)) {
        try encodeSpecialWkt(msg, w, opts, depth, known_types);
    } else {
        try encodeObject(msg, w, opts, depth, known_types);
    }
}

fn encodeSpecialWkt(
    msg: anytype,
    w: anytype,
    opts: EncodeOptions,
    depth: u32,
    comptime known_types: anytype,
) EncodeError(@TypeOf(w))!void {
    const M = @TypeOf(msg);
    const full = M.proto_full_name;

    if (comptime std.mem.eql(u8, full, "google.protobuf.Timestamp")) {
        var tmp: [32]u8 = undefined;
        const text = try wkt.formatTimestampBuf(msg, &tmp);
        try w.writeByte('"');
        try w.writeAll(text);
        try w.writeByte('"');
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.Duration")) {
        var tmp: [32]u8 = undefined;
        const text = try wkt.formatDurationBuf(msg, &tmp);
        try w.writeByte('"');
        try w.writeAll(text);
        try w.writeByte('"');
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.Empty")) {
        try w.writeAll("{}");
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.FieldMask")) {
        try w.writeByte('"');
        var it = msg.paths.iterator();
        var first = true;
        while (try it.next()) |path| {
            if (!first) try w.writeByte(',');
            try writeFieldMaskPathCamel(w, path);
            first = false;
        }
        try w.writeByte('"');
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.Any")) {
        if (msg.type_url.len == 0 and msg.value.len == 0) {
            try w.writeAll("{}");
            return;
        }
        inline for (known_types) |KnownM| {
            if (wkt.anyIs(msg, KnownM)) {
                const sub = try KnownM.decodeDepth(msg.value, depth - 1);
                try w.writeAll("{\"@type\":");
                try writeJsonString(w, msg.type_url);
                if (comptime @hasDecl(KnownM, "proto_full_name") and isSpecialWkt(KnownM.proto_full_name)) {
                    try w.writeAll(",\"value\":");
                    try encodeSpecialWkt(sub, w, opts, depth - 1, known_types);
                } else {
                    var first = false;
                    try encodeObjectFields(sub, w, opts, depth - 1, known_types, &first);
                }
                try w.writeByte('}');
                return;
            }
        }
        try w.writeAll("{\"@type\":");
        try writeJsonString(w, msg.type_url);
        if (msg.value.len > 0 or opts.emit_default_values) {
            try w.writeAll(",\"value\":");
            try writeBase64String(w, msg.value);
        }
        try w.writeByte('}');
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.Struct")) {
        try w.writeByte('{');
        var it = msg.fields.iterator();
        var first = true;
        while (try it.next()) |entry| {
            if (!first) try w.writeByte(',');
            try writeJsonString(w, entry.key);
            try w.writeByte(':');
            try encodeMessageDepth(entry.value, w, opts, depth - 1, known_types);
            first = false;
        }
        try w.writeByte('}');
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.ListValue")) {
        try w.writeByte('[');
        var it = msg.values.iterator();
        var first = true;
        while (try it.next()) |item| {
            if (!first) try w.writeByte(',');
            try encodeMessageDepth(item, w, opts, depth - 1, known_types);
            first = false;
        }
        try w.writeByte(']');
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.Value")) {
        if (msg.kind) |k| {
            switch (k) {
                .null_value => try w.writeAll("null"),
                .number_value => |n| try encodeScalar(n, false, w),
                .string_value => |s| try writeJsonString(w, s),
                .bool_value => |b| try w.writeAll(if (b) "true" else "false"),
                .struct_value => |sv| try encodeMaybeLazy(sv, w, opts, depth - 1, known_types),
                .list_value => |lv| try encodeMaybeLazy(lv, w, opts, depth - 1, known_types),
            }
        } else {
            try w.writeAll("null");
        }
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.BytesValue")) {
        try writeBase64String(w, msg.value);
    } else {
        // Remaining wrapper types: DoubleValue, FloatValue, Int64Value, UInt64Value,
        // Int32Value, UInt32Value, BoolValue, StringValue
        try encodeScalar(msg.value, false, w);
    }
}

fn encodeMaybeLazy(
    val: anytype,
    w: anytype,
    opts: EncodeOptions,
    depth: u32,
    comptime known_types: anytype,
) EncodeError(@TypeOf(w))!void {
    const T = @TypeOf(val);
    if (comptime @typeInfo(T) == .@"union" and @hasDecl(T, "_protoz_kind") and T._protoz_kind == .lazy) {
        const sub = try val.decodeDepth(depth);
        try encodeMessageDepth(sub, w, opts, depth, known_types);
    } else {
        try encodeMessageDepth(val, w, opts, depth, known_types);
    }
}

fn encodeObject(
    msg: anytype,
    w: anytype,
    opts: EncodeOptions,
    depth: u32,
    comptime known_types: anytype,
) EncodeError(@TypeOf(w))!void {
    try w.writeByte('{');
    var first = true;
    try encodeObjectFields(msg, w, opts, depth, known_types, &first);
    try w.writeByte('}');
}

fn encodeObjectFields(
    msg: anytype,
    w: anytype,
    opts: EncodeOptions,
    depth: u32,
    comptime known_types: anytype,
    first: *bool,
) EncodeError(@TypeOf(w))!void {
    const M = @TypeOf(msg);

    inline for (M._protoz_json_fields) |meta| {
        const key_name = if (opts.preserve_proto_field_names) meta.proto_name else meta.json_name;
        switch (comptime meta.kind) {
            .scalar => {
                if (comptime meta.explicit_presence) {
                    if (@field(msg, meta.zig_name)) |v| {
                        try writeFieldKey(w, first, key_name);
                        try encodeScalar(v, meta.is_bytes, w);
                    }
                } else {
                    const v = @field(msg, meta.zig_name);
                    if (opts.emit_default_values or !isScalarDefault(v)) {
                        try writeFieldKey(w, first, key_name);
                        try encodeScalar(v, meta.is_bytes, w);
                    }
                }
            },
            .@"enum" => {
                if (comptime meta.explicit_presence) {
                    if (@field(msg, meta.zig_name)) |v| {
                        try writeFieldKey(w, first, key_name);
                        try encodeEnum(v, w, opts);
                    }
                } else {
                    const v = @field(msg, meta.zig_name);
                    if (opts.emit_default_values or @backingInt(v) != 0) {
                        try writeFieldKey(w, first, key_name);
                        try encodeEnum(v, w, opts);
                    }
                }
            },
            .message => {
                if (@field(msg, meta.zig_name)) |sub| {
                    try writeFieldKey(w, first, key_name);
                    try encodeMessageDepth(sub, w, opts, depth - 1, known_types);
                }
            },
            .lazy_message => {
                if (@field(msg, meta.zig_name)) |lazy| {
                    const sub = try lazy.decodeDepth(depth);
                    try writeFieldKey(w, first, key_name);
                    try encodeMessageDepth(sub, w, opts, depth - 1, known_types);
                }
            },
            .repeated => {
                var it = @field(msg, meta.zig_name).iterator();
                const first_item = try it.next();
                if (first_item != null or opts.emit_default_values) {
                    try writeFieldKey(w, first, key_name);
                    try w.writeByte('[');
                    if (first_item) |item0| {
                        try encodeElem(item0, meta.elem_is_bytes, w, opts, depth - 1, known_types);
                        while (try it.next()) |item| {
                            try w.writeByte(',');
                            try encodeElem(item, meta.elem_is_bytes, w, opts, depth - 1, known_types);
                        }
                    }
                    try w.writeByte(']');
                }
            },
            .map => {
                var it = @field(msg, meta.zig_name).iterator();
                const first_entry = try it.next();
                if (first_entry != null or opts.emit_default_values) {
                    try writeFieldKey(w, first, key_name);
                    try w.writeByte('{');
                    if (first_entry) |e0| {
                        try encodeMapKey(e0.key, w);
                        try w.writeByte(':');
                        try encodeElem(e0.value, meta.elem_is_bytes, w, opts, depth - 1, known_types);
                        while (try it.next()) |entry| {
                            try w.writeByte(',');
                            try encodeMapKey(entry.key, w);
                            try w.writeByte(':');
                            try encodeElem(entry.value, meta.elem_is_bytes, w, opts, depth - 1, known_types);
                        }
                    }
                    try w.writeByte('}');
                }
            },
            .oneof => {
                if (@field(msg, meta.oneof_field)) |u| {
                    switch (u) {
                        inline else => |payload, tag| {
                            if (comptime std.mem.eql(u8, @tagName(tag), meta.zig_name)) {
                                try writeFieldKey(w, first, key_name);
                                if (comptime meta.is_lazy) {
                                    const sub = try payload.decodeDepth(depth);
                                    try encodeMessageDepth(sub, w, opts, depth - 1, known_types);
                                } else {
                                    try encodeElem(payload, meta.is_bytes, w, opts, depth - 1, known_types);
                                }
                            }
                        },
                    }
                }
            },
        }
    }
}

fn encodeElem(
    val: anytype,
    comptime is_bytes: bool,
    w: anytype,
    opts: EncodeOptions,
    depth: u32,
    comptime known_types: anytype,
) EncodeError(@TypeOf(w))!void {
    const T = @TypeOf(val);
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "_protoz_json_fields")) {
        try encodeMessageDepth(val, w, opts, depth, known_types);
    } else if (comptime @typeInfo(T) == .@"enum") {
        try encodeEnum(val, w, opts);
    } else {
        try encodeScalar(val, is_bytes, w);
    }
}

fn encodeEnum(val: anytype, w: anytype, opts: EncodeOptions) wire.WriterError(@TypeOf(w))!void {
    const E = @TypeOf(val);
    if (comptime isNullValueEnum(E)) {
        try w.writeAll("null");
        return;
    }
    const raw: i32 = @backingInt(val);
    if (!opts.emit_enums_as_ints) {
        const e = @typeInfo(E).@"enum";
        inline for (e.field_names, e.field_values) |ename, ev| {
            if (raw == ev) {
                try w.writeByte('"');
                try w.writeAll(ename);
                try w.writeByte('"');
                return;
            }
        }
    }
    var tmp: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&tmp, "{d}", .{raw}) catch unreachable;
    try w.writeAll(text);
}

fn encodeMapKey(key: anytype, w: anytype) wire.WriterError(@TypeOf(w))!void {
    const K = @TypeOf(key);
    switch (@typeInfo(K)) {
        .pointer => try writeJsonString(w, key),
        .bool => try w.writeAll(if (key) "\"true\"" else "\"false\""),
        .int => {
            var tmp: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&tmp, "\"{d}\"", .{key}) catch unreachable;
            try w.writeAll(text);
        },
        else => @compileError("unsupported ProtoJSON map key type: " ++ @typeName(K)),
    }
}

fn encodeScalar(val: anytype, comptime is_bytes: bool, w: anytype) wire.WriterError(@TypeOf(w))!void {
    const T = @TypeOf(val);
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (val) "true" else "false"),
        .int => |info| {
            var tmp: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch unreachable;
            if (comptime info.bits >= 64) {
                try w.writeByte('"');
                try w.writeAll(text);
                try w.writeByte('"');
            } else {
                try w.writeAll(text);
            }
        },
        .float => {
            if (val != val) {
                try w.writeAll("\"NaN\"");
            } else if (val == std.math.inf(T)) {
                try w.writeAll("\"Infinity\"");
            } else if (val == -std.math.inf(T)) {
                try w.writeAll("\"-Infinity\"");
            } else {
                var tmp: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch unreachable;
                try w.writeAll(text);
            }
        },
        .pointer => {
            if (comptime is_bytes) {
                try writeBase64String(w, val);
            } else {
                try writeJsonString(w, val);
            }
        },
        else => @compileError("unsupported ProtoJSON scalar type: " ++ @typeName(T)),
    }
}

fn isScalarDefault(v: anytype) bool {
    const T = @TypeOf(v);
    return switch (@typeInfo(T)) {
        .bool => !v,
        .int => v == 0,
        .float => if (T == f32) @as(u32, @bitCast(v)) == 0 else @as(u64, @bitCast(v)) == 0,
        .pointer => v.len == 0,
        else => false,
    };
}

fn writeFieldKey(w: anytype, first: *bool, key: []const u8) wire.WriterError(@TypeOf(w))!void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":");
}

fn writeJsonString(w: anytype, s: []const u8) wire.WriterError(@TypeOf(w))!void {
    try w.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |b, i| {
        const esc: ?[]const u8 = switch (b) {
            '"' => "\\\"",
            '\\' => "\\\\",
            0x08 => "\\b",
            0x0C => "\\f",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x00...0x07, 0x0B, 0x0E...0x1F => null,
            else => continue,
        };
        if (i > start) try w.writeAll(s[start..i]);
        if (esc) |e| {
            try w.writeAll(e);
        } else {
            const hex = "0123456789abcdef";
            const seq = [_]u8{ '\\', 'u', '0', '0', hex[b >> 4], hex[b & 0xF] };
            try w.writeAll(&seq);
        }
        start = i + 1;
    }
    if (start < s.len) try w.writeAll(s[start..]);
    try w.writeByte('"');
}

fn writeBase64String(w: anytype, bytes: []const u8) wire.WriterError(@TypeOf(w))!void {
    const alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    try w.writeByte('"');
    var i: usize = 0;
    while (i + 3 <= bytes.len) : (i += 3) {
        const n: u24 = (@as(u24, bytes[i]) << 16) | (@as(u24, bytes[i + 1]) << 8) | bytes[i + 2];
        const quad = [_]u8{
            alpha[(n >> 18) & 0x3F],
            alpha[(n >> 12) & 0x3F],
            alpha[(n >> 6) & 0x3F],
            alpha[n & 0x3F],
        };
        try w.writeAll(&quad);
    }
    const rem = bytes.len - i;
    if (rem == 1) {
        const b0: u24 = bytes[i];
        const quad = [_]u8{
            alpha[(b0 >> 2) & 0x3F],
            alpha[(b0 << 4) & 0x3F],
            '=',
            '=',
        };
        try w.writeAll(&quad);
    } else if (rem == 2) {
        const n: u24 = (@as(u24, bytes[i]) << 8) | bytes[i + 1];
        const quad = [_]u8{
            alpha[(n >> 10) & 0x3F],
            alpha[(n >> 4) & 0x3F],
            alpha[(n << 2) & 0x3F],
            '=',
        };
        try w.writeAll(&quad);
    }
    try w.writeByte('"');
}

fn writeFieldMaskPathCamel(w: anytype, path: []const u8) wire.WriterError(@TypeOf(w))!void {
    var cap = false;
    for (path) |ch| {
        if (ch == '_') {
            cap = true;
        } else if (cap) {
            try w.writeByte(std.ascii.toUpper(ch));
            cap = false;
        } else {
            try w.writeByte(ch);
        }
    }
}

// ---------------------------------------------------------------------------
// ProtoJSON Parser (Zero-Copy Fast Path + Arena Fallback)
// ---------------------------------------------------------------------------

const JsonParser = struct {
    input: []const u8,
    pos: usize = 0,

    inline fn eof(self: *const JsonParser) bool {
        return self.pos >= self.input.len;
    }

    inline fn peek(self: *const JsonParser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn skipWs(self: *JsonParser) void {
        while (self.pos < self.input.len) : (self.pos += 1) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\r', '\n' => {},
                else => break,
            }
        }
    }

    fn expectByte(self: *JsonParser, ch: u8) DecodeError!void {
        self.skipWs();
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        if (self.input[self.pos] != ch) return error.InvalidJson;
        self.pos += 1;
    }

    fn consumeByte(self: *JsonParser, ch: u8) bool {
        self.skipWs();
        if (self.pos < self.input.len and self.input[self.pos] == ch) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn consumeLiteral(self: *JsonParser, lit: []const u8) bool {
        self.skipWs();
        if (self.pos + lit.len <= self.input.len and std.mem.eql(u8, self.input[self.pos .. self.pos + lit.len], lit)) {
            self.pos += lit.len;
            return true;
        }
        return false;
    }

    fn parseHex4(self: *JsonParser) DecodeError!u16 {
        if (self.pos + 4 > self.input.len) return error.UnexpectedEof;
        var val: u16 = 0;
        for (self.input[self.pos .. self.pos + 4]) |ch| {
            const d: u16 = switch (ch) {
                '0'...'9' => ch - '0',
                'a'...'f' => ch - 'a' + 10,
                'A'...'F' => ch - 'A' + 10,
                else => return error.InvalidEscape,
            };
            val = (val << 4) | d;
        }
        self.pos += 4;
        return val;
    }

    /// Parses a JSON string. Returns a zero-copy slice into `input` when no escapes are present.
    fn parseStringSlice(self: *JsonParser, arena: wire.Allocator) DecodeError![]const u8 {
        self.skipWs();
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        if (self.input[self.pos] != '"') return error.InvalidJson;
        self.pos += 1;
        const start = self.pos;

        // Fast path: scan for closing quote without escapes
        while (self.pos < self.input.len) : (self.pos += 1) {
            const b = self.input[self.pos];
            if (b == '"') {
                const slice = self.input[start..self.pos];
                self.pos += 1;
                if (!std.unicode.utf8ValidateSlice(slice)) return error.InvalidUtf8;
                return slice;
            }
            if (b == '\\') break;
            if (b < 0x20) return error.InvalidJson;
        }
        if (self.pos >= self.input.len) return error.UnexpectedEof;

        // Slow path: unescape into caller's arena
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, self.input[start..self.pos]);

        while (self.pos < self.input.len) {
            const b = self.input[self.pos];
            self.pos += 1;
            if (b == '"') {
                const slice = try out.toOwnedSlice(arena);
                if (!std.unicode.utf8ValidateSlice(slice)) return error.InvalidUtf8;
                return slice;
            }
            if (b < 0x20) return error.InvalidJson;
            if (b != '\\') {
                try out.append(arena, b);
                continue;
            }
            if (self.pos >= self.input.len) return error.UnexpectedEof;
            const esc = self.input[self.pos];
            self.pos += 1;
            switch (esc) {
                '"' => try out.append(arena, '"'),
                '\\' => try out.append(arena, '\\'),
                '/' => try out.append(arena, '/'),
                'b' => try out.append(arena, 0x08),
                'f' => try out.append(arena, 0x0C),
                'n' => try out.append(arena, '\n'),
                'r' => try out.append(arena, '\r'),
                't' => try out.append(arena, '\t'),
                'u' => {
                    const @"u1" = try self.parseHex4();
                    if (@"u1" >= 0xD800 and @"u1" <= 0xDBFF) {
                        if (self.pos + 2 > self.input.len or
                            self.input[self.pos] != '\\' or
                            self.input[self.pos + 1] != 'u')
                        {
                            return error.InvalidEscape;
                        }
                        self.pos += 2;
                        const @"u2" = try self.parseHex4();
                        if (@"u2" < 0xDC00 or @"u2" > 0xDFFF) return error.InvalidEscape;
                        const cp: u21 = 0x10000 + (@as(u21, @"u1" - 0xD800) << 10) + @as(u21, @"u2" - 0xDC00);
                        try appendUtf8(arena, &out, cp);
                    } else if (@"u1" >= 0xDC00 and @"u1" <= 0xDFFF) {
                        return error.InvalidEscape;
                    } else {
                        try appendUtf8(arena, &out, @as(u21, @"u1"));
                    }
                },
                else => return error.InvalidEscape,
            }
        }
        return error.UnexpectedEof;
    }

    fn readNumberToken(self: *JsonParser) DecodeError![]const u8 {
        self.skipWs();
        const start = self.pos;
        if (self.pos >= self.input.len) return error.UnexpectedEof;

        if (self.input[self.pos] == '-') self.pos += 1;
        if (self.pos >= self.input.len) return error.InvalidNumber;

        if (self.input[self.pos] == '0') {
            self.pos += 1;
        } else if (self.input[self.pos] >= '1' and self.input[self.pos] <= '9') {
            self.pos += 1;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) : (self.pos += 1) {}
        } else {
            return error.InvalidNumber;
        }

        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            const frac_start = self.pos;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) : (self.pos += 1) {}
            if (self.pos == frac_start) return error.InvalidNumber;
        }

        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) {
                self.pos += 1;
            }
            const exp_start = self.pos;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) : (self.pos += 1) {}
            if (self.pos == exp_start) return error.InvalidNumber;
        }

        return self.input[start..self.pos];
    }

    fn skipString(self: *JsonParser) DecodeError!void {
        self.skipWs();
        if (self.pos >= self.input.len or self.input[self.pos] != '"') return error.InvalidJson;
        self.pos += 1;
        while (self.pos < self.input.len) {
            const b = self.input[self.pos];
            self.pos += 1;
            if (b == '"') return;
            if (b < 0x20) return error.InvalidJson;
            if (b == '\\') {
                if (self.pos >= self.input.len) return error.UnexpectedEof;
                const esc = self.input[self.pos];
                self.pos += 1;
                if (esc == 'u') _ = try self.parseHex4();
            }
        }
        return error.UnexpectedEof;
    }

    fn skipValue(self: *JsonParser, depth: u32) DecodeError!void {
        if (depth == 0) return error.RecursionLimitExceeded;
        self.skipWs();
        const ch = self.peek() orelse return error.UnexpectedEof;
        switch (ch) {
            '"' => try self.skipString(),
            '{' => {
                self.pos += 1;
                if (self.consumeByte('}')) return;
                while (true) {
                    try self.skipString();
                    try self.expectByte(':');
                    try self.skipValue(depth - 1);
                    if (self.consumeByte(',')) continue;
                    try self.expectByte('}');
                    return;
                }
            },
            '[' => {
                self.pos += 1;
                if (self.consumeByte(']')) return;
                while (true) {
                    try self.skipValue(depth - 1);
                    if (self.consumeByte(',')) continue;
                    try self.expectByte(']');
                    return;
                }
            },
            't' => if (!self.consumeLiteral("true")) return error.InvalidJson,
            'f' => if (!self.consumeLiteral("false")) return error.InvalidJson,
            'n' => if (!self.consumeLiteral("null")) return error.InvalidJson,
            '-', '0'...'9' => _ = try self.readNumberToken(),
            else => return error.InvalidJson,
        }
    }
};

fn decodeMessageDepth(
    comptime M: type,
    arena: wire.Allocator,
    p: *JsonParser,
    opts: DecodeOptions,
    depth: u32,
    comptime known_types: anytype,
) DecodeError!M {
    @setEvalBranchQuota(100_000);
    if (depth == 0) return error.RecursionLimitExceeded;

    if (comptime @hasDecl(M, "proto_full_name") and isSpecialWkt(M.proto_full_name)) {
        return decodeSpecialWkt(M, arena, p, opts, depth, known_types);
    } else {
        return decodeObject(M, arena, p, opts, depth, known_types);
    }
}

fn peekAnyTypeUrl(arena: wire.Allocator, p: *JsonParser, depth: u32) DecodeError!?[]const u8 {
    try p.expectByte('{');
    if (p.consumeByte('}')) return null;
    while (true) {
        const key = try p.parseStringSlice(arena);
        try p.expectByte(':');
        if (std.mem.eql(u8, key, "@type")) {
            if (p.consumeLiteral("null")) return null;
            return try p.parseStringSlice(arena);
        }
        try p.skipValue(depth);
        if (p.consumeByte(',')) continue;
        try p.expectByte('}');
        return null;
    }
}

fn decodeAnyWrappedWkt(
    comptime KnownM: type,
    arena: wire.Allocator,
    p: *JsonParser,
    opts: DecodeOptions,
    depth: u32,
    comptime known_types: anytype,
) DecodeError!KnownM {
    var out: KnownM = .{};
    try p.expectByte('{');
    if (p.consumeByte('}')) return out;
    while (true) {
        const key = try p.parseStringSlice(arena);
        try p.expectByte(':');
        if (std.mem.eql(u8, key, "@type")) {
            if (!p.consumeLiteral("null")) _ = try p.parseStringSlice(arena);
        } else if (std.mem.eql(u8, key, "value")) {
            if (!p.consumeLiteral("null")) {
                out = try decodeSpecialWkt(KnownM, arena, p, opts, depth, known_types);
            }
        } else if (opts.ignore_unknown_fields) {
            try p.skipValue(depth);
        } else {
            return error.UnknownField;
        }
        if (p.consumeByte(',')) continue;
        try p.expectByte('}');
        return out;
    }
}

fn decodeSpecialWkt(
    comptime M: type,
    arena: wire.Allocator,
    p: *JsonParser,
    opts: DecodeOptions,
    depth: u32,
    comptime known_types: anytype,
) DecodeError!M {
    const full = M.proto_full_name;

    if (comptime std.mem.eql(u8, full, "google.protobuf.Timestamp")) {
        const s = try p.parseStringSlice(arena);
        return wkt.parseTimestamp(M, s);
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.Duration")) {
        const s = try p.parseStringSlice(arena);
        return wkt.parseDuration(M, s);
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.Empty")) {
        try p.expectByte('{');
        if (p.consumeByte('}')) return .{};
        while (true) {
            _ = try p.parseStringSlice(arena);
            try p.expectByte(':');
            if (!opts.ignore_unknown_fields) return error.UnknownField;
            try p.skipValue(depth - 1);
            if (p.consumeByte(',')) continue;
            try p.expectByte('}');
            return .{};
        }
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.FieldMask")) {
        const s = try p.parseStringSlice(arena);
        if (s.len == 0) return .{ .paths = .empty };
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, s, ',');
        while (it.next()) |seg| {
            if (seg.len == 0) return error.InvalidFormat;
            try list.append(arena, try camelToSnakeAlloc(arena, seg));
        }
        return .{ .paths = .{ .slice = try list.toOwnedSlice(arena) } };
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.Any")) {
        if (comptime @typeInfo(@TypeOf(known_types)).@"struct".field_names.len > 0) {
            p.skipWs();
            const obj_start = p.pos;
            var probe = p.*;
            const type_url = try peekAnyTypeUrl(arena, &probe, depth - 1);
            if (type_url) |url| {
                const type_name = wkt.anyTypeName(url) orelse "";
                inline for (known_types) |KnownM| {
                    if (comptime @hasDecl(KnownM, "proto_full_name")) {
                        if (std.mem.eql(u8, type_name, KnownM.proto_full_name)) {
                            p.pos = obj_start;
                            const sub: KnownM = if (comptime isSpecialWkt(KnownM.proto_full_name))
                                try decodeAnyWrappedWkt(KnownM, arena, p, opts, depth - 1, known_types)
                            else
                                try decodeObjectInner(KnownM, arena, p, opts, depth - 1, known_types, true);

                            const sz = sub.encodedSize();
                            const buf = if (sz == 0) "" else blk: {
                                const dst = try arena.alloc(u8, sz);
                                break :blk sub.encodeSlice(dst) catch unreachable;
                            };
                            return .{ .type_url = url, .value = buf };
                        }
                    }
                }
            }
            p.pos = obj_start;
        }
        var out: M = .{};
        try p.expectByte('{');
        if (p.consumeByte('}')) return out;
        while (true) {
            const key = try p.parseStringSlice(arena);
            try p.expectByte(':');
            if (p.consumeLiteral("null")) {
                // ignore null fields
            } else if (std.mem.eql(u8, key, "@type") or std.mem.eql(u8, key, "typeUrl") or std.mem.eql(u8, key, "type_url")) {
                out.type_url = try p.parseStringSlice(arena);
            } else if (std.mem.eql(u8, key, "value")) {
                out.value = try decodeBase64(arena, try p.parseStringSlice(arena));
            } else if (opts.ignore_unknown_fields) {
                try p.skipValue(depth - 1);
            } else {
                return error.UnknownField;
            }
            if (p.consumeByte(',')) continue;
            try p.expectByte('}');
            return out;
        }
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.Struct")) {
        const MapT = @FieldType(M, "fields");
        const EntryT = @typeInfo(@FieldType(MapT, "slice")).pointer.child;
        const ValM = @FieldType(EntryT, "value");
        try p.expectByte('{');
        if (p.consumeByte('}')) return .{ .fields = .empty };
        var list: std.ArrayList(EntryT) = .empty;
        while (true) {
            const k = try p.parseStringSlice(arena);
            try p.expectByte(':');
            const v = try decodeMessageDepth(ValM, arena, p, opts, depth - 1, known_types);
            try list.append(arena, .{ .key = k, .value = v });
            if (p.consumeByte(',')) continue;
            try p.expectByte('}');
            return .{ .fields = .{ .slice = try list.toOwnedSlice(arena) } };
        }
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.ListValue")) {
        const RepT = @FieldType(M, "values");
        const ValM = @typeInfo(@FieldType(RepT, "slice")).pointer.child;
        try p.expectByte('[');
        if (p.consumeByte(']')) return .{ .values = .empty };
        var list: std.ArrayList(ValM) = .empty;
        while (true) {
            try list.append(arena, try decodeMessageDepth(ValM, arena, p, opts, depth - 1, known_types));
            if (p.consumeByte(',')) continue;
            try p.expectByte(']');
            return .{ .values = .{ .slice = try list.toOwnedSlice(arena) } };
        }
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.Value")) {
        const UnionT = @typeInfo(@FieldType(M, "kind")).optional.child;
        p.skipWs();
        const ch = p.peek() orelse return error.UnexpectedEof;
        return switch (ch) {
            'n' => {
                if (!p.consumeLiteral("null")) return error.InvalidJson;
                return .{ .kind = .{ .null_value = @fromBackingInt(0) } };
            },
            't', 'f' => .{ .kind = .{ .bool_value = try decodeScalar(bool, false, arena, p) } },
            '"' => .{ .kind = .{ .string_value = try p.parseStringSlice(arena) } },
            '-', '0'...'9' => .{ .kind = .{ .number_value = try decodeScalar(f64, false, arena, p) } },
            '{' => {
                const FieldT = @FieldType(UnionT, "struct_value");
                return .{ .kind = .{ .struct_value = try decodeMaybeLazy(FieldT, arena, p, opts, depth - 1, known_types) } };
            },
            '[' => {
                const FieldT = @FieldType(UnionT, "list_value");
                return .{ .kind = .{ .list_value = try decodeMaybeLazy(FieldT, arena, p, opts, depth - 1, known_types) } };
            },
            else => error.InvalidJson,
        };
    } else if (comptime std.mem.eql(u8, full, "google.protobuf.BytesValue")) {
        return .{ .value = try decodeBase64(arena, try p.parseStringSlice(arena)) };
    } else {
        const ValT = @FieldType(M, "value");
        return .{ .value = try decodeScalar(ValT, false, arena, p) };
    }
}

fn decodeMaybeLazy(
    comptime T: type,
    arena: wire.Allocator,
    p: *JsonParser,
    opts: DecodeOptions,
    depth: u32,
    comptime known_types: anytype,
) DecodeError!T {
    if (comptime @typeInfo(T) == .@"union" and @hasDecl(T, "_protoz_kind") and T._protoz_kind == .lazy) {
        const SubM = @typeInfo(@FieldType(T, "ptr")).pointer.child;
        const sub = try decodeMessageDepth(SubM, arena, p, opts, depth, known_types);
        const ptr = try arena.create(SubM);
        ptr.* = sub;
        return .{ .ptr = ptr };
    } else {
        return decodeMessageDepth(T, arena, p, opts, depth, known_types);
    }
}

fn decodeObject(
    comptime M: type,
    arena: wire.Allocator,
    p: *JsonParser,
    opts: DecodeOptions,
    depth: u32,
    comptime known_types: anytype,
) DecodeError!M {
    return decodeObjectInner(M, arena, p, opts, depth, known_types, false);
}

fn decodeObjectInner(
    comptime M: type,
    arena: wire.Allocator,
    p: *JsonParser,
    opts: DecodeOptions,
    depth: u32,
    comptime known_types: anytype,
    comptime skip_at_type: bool,
) DecodeError!M {
    var out: M = .{};
    try p.expectByte('{');
    if (p.consumeByte('}')) return out;

    while (true) {
        const key = try p.parseStringSlice(arena);
        try p.expectByte(':');

        var matched = false;
        inline for (M._protoz_json_fields) |meta| {
            const is_match = if (comptime std.mem.eql(u8, meta.json_name, meta.proto_name))
                std.mem.eql(u8, key, meta.json_name)
            else
                std.mem.eql(u8, key, meta.json_name) or std.mem.eql(u8, key, meta.proto_name);

            if (is_match) {
                matched = true;
                switch (comptime meta.kind) {
                    .scalar => {
                        if (!p.consumeLiteral("null")) {
                            const FT = @FieldType(M, meta.zig_name);
                            const Inner = if (comptime meta.explicit_presence) @typeInfo(FT).optional.child else FT;
                            @field(out, meta.zig_name) = try decodeScalar(Inner, meta.is_bytes, arena, p);
                        }
                    },
                    .@"enum" => {
                        const FT = @FieldType(M, meta.zig_name);
                        const Inner = if (comptime meta.explicit_presence) @typeInfo(FT).optional.child else FT;
                        if (p.consumeLiteral("null")) {
                            if (comptime isNullValueEnum(Inner)) {
                                @field(out, meta.zig_name) = @fromBackingInt(0);
                            }
                        } else if (try decodeEnum(Inner, arena, p, opts)) |ev| {
                            @field(out, meta.zig_name) = ev;
                        }
                    },
                    .message => {
                        const SubM = @typeInfo(@FieldType(M, meta.zig_name)).optional.child;
                        if (p.consumeLiteral("null")) {
                            if (comptime @hasDecl(SubM, "proto_full_name") and std.mem.eql(u8, SubM.proto_full_name, "google.protobuf.Value")) {
                                @field(out, meta.zig_name) = .{ .kind = .{ .null_value = @fromBackingInt(0) } };
                            }
                        } else {
                            @field(out, meta.zig_name) = try decodeMessageDepth(SubM, arena, p, opts, depth - 1, known_types);
                        }
                    },
                    .lazy_message => {
                        if (!p.consumeLiteral("null")) {
                            const LazyT = @typeInfo(@FieldType(M, meta.zig_name)).optional.child;
                            const SubM = @typeInfo(@FieldType(LazyT, "ptr")).pointer.child;
                            const sub = try decodeMessageDepth(SubM, arena, p, opts, depth - 1, known_types);
                            const ptr = try arena.create(SubM);
                            ptr.* = sub;
                            @field(out, meta.zig_name) = .{ .ptr = ptr };
                        }
                    },
                    .repeated => {
                        if (!p.consumeLiteral("null")) {
                            const RepT = @FieldType(M, meta.zig_name);
                            const ElemT = @typeInfo(@FieldType(RepT, "slice")).pointer.child;
                            try p.expectByte('[');
                            if (p.consumeByte(']')) {
                                @field(out, meta.zig_name) = .empty;
                            } else {
                                var list: std.ArrayList(ElemT) = .empty;
                                while (true) {
                                    if (try decodeElemOpt(ElemT, meta.elem_is_bytes, arena, p, opts, depth - 1, known_types)) |item| {
                                        try list.append(arena, item);
                                    }
                                    if (p.consumeByte(',')) continue;
                                    try p.expectByte(']');
                                    break;
                                }
                                @field(out, meta.zig_name) = .{ .slice = try list.toOwnedSlice(arena) };
                            }
                        }
                    },
                    .map => {
                        if (!p.consumeLiteral("null")) {
                            const MapT = @FieldType(M, meta.zig_name);
                            const EntryT = @typeInfo(@FieldType(MapT, "slice")).pointer.child;
                            const KeyT = @FieldType(EntryT, "key");
                            const ValT = @FieldType(EntryT, "value");
                            try p.expectByte('{');
                            if (p.consumeByte('}')) {
                                @field(out, meta.zig_name) = .empty;
                            } else {
                                var list: std.ArrayList(EntryT) = .empty;
                                while (true) {
                                    const raw_k = try p.parseStringSlice(arena);
                                    try p.expectByte(':');
                                    const mk = try decodeMapKey(KeyT, raw_k);
                                    const mv = (try decodeElemOpt(ValT, meta.elem_is_bytes, arena, p, opts, depth - 1, known_types)) orelse return error.InvalidJson;
                                    try list.append(arena, .{ .key = mk, .value = mv });
                                    if (p.consumeByte(',')) continue;
                                    try p.expectByte('}');
                                    break;
                                }
                                @field(out, meta.zig_name) = .{ .slice = try list.toOwnedSlice(arena) };
                            }
                        }
                    },
                    .oneof => {
                        if (!p.consumeLiteral("null")) {
                            if (@field(out, meta.oneof_field) != null) return error.DuplicateOneofField;
                            const UnionT = @typeInfo(@FieldType(M, meta.oneof_field)).optional.child;
                            if (comptime meta.is_lazy) {
                                const LazyT = @FieldType(UnionT, meta.zig_name);
                                const SubM = @typeInfo(@FieldType(LazyT, "ptr")).pointer.child;
                                const sub = try decodeMessageDepth(SubM, arena, p, opts, depth - 1, known_types);
                                const ptr = try arena.create(SubM);
                                ptr.* = sub;
                                @field(out, meta.oneof_field) = @unionInit(UnionT, meta.zig_name, .{ .ptr = ptr });
                            } else {
                                const PayloadT = @FieldType(UnionT, meta.zig_name);
                                if (try decodeElemOpt(PayloadT, meta.is_bytes, arena, p, opts, depth - 1, known_types)) |payload| {
                                    @field(out, meta.oneof_field) = @unionInit(UnionT, meta.zig_name, payload);
                                }
                            }
                        }
                    },
                }
            }
        }

        if (!matched and comptime skip_at_type) {
            if (std.mem.eql(u8, key, "@type")) {
                if (!p.consumeLiteral("null")) _ = try p.parseStringSlice(arena);
                matched = true;
            }
        }

        if (!matched) {
            if (!opts.ignore_unknown_fields) return error.UnknownField;
            try p.skipValue(depth - 1);
        }

        if (p.consumeByte(',')) continue;
        try p.expectByte('}');
        return out;
    }
}

fn decodeElemOpt(
    comptime T: type,
    comptime is_bytes: bool,
    arena: wire.Allocator,
    p: *JsonParser,
    opts: DecodeOptions,
    depth: u32,
    comptime known_types: anytype,
) DecodeError!?T {
    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "_protoz_json_fields")) {
        return try decodeMessageDepth(T, arena, p, opts, depth, known_types);
    } else if (comptime @typeInfo(T) == .@"enum") {
        return try decodeEnum(T, arena, p, opts);
    } else {
        return try decodeScalar(T, is_bytes, arena, p);
    }
}

fn decodeEnum(
    comptime E: type,
    arena: wire.Allocator,
    p: *JsonParser,
    opts: DecodeOptions,
) DecodeError!?E {
    p.skipWs();
    const ch = p.peek() orelse return error.UnexpectedEof;
    if (ch == '"') {
        const s = try p.parseStringSlice(arena);
        const e = @typeInfo(E).@"enum";
        inline for (e.field_names, e.field_values) |ename, ev| {
            if (std.mem.eql(u8, s, ename)) return @fromBackingInt(ev);
        }
        if (opts.ignore_unknown_fields) return null;
        return error.UnknownEnumValue;
    }
    const n = try decodeInt(i32, arena, p);
    return @fromBackingInt(n);
}

fn decodeMapKey(comptime K: type, raw: []const u8) DecodeError!K {
    return switch (@typeInfo(K)) {
        .pointer => raw,
        .bool => if (std.mem.eql(u8, raw, "true")) true else if (std.mem.eql(u8, raw, "false")) false else error.InvalidJson,
        .int => parseIntString(K, raw),
        else => @compileError("unsupported ProtoJSON map key type: " ++ @typeName(K)),
    };
}

fn decodeScalar(
    comptime T: type,
    comptime is_bytes: bool,
    arena: wire.Allocator,
    p: *JsonParser,
) DecodeError!T {
    return switch (@typeInfo(T)) {
        .bool => {
            if (p.consumeLiteral("true")) return true;
            if (p.consumeLiteral("false")) return false;
            return error.InvalidJson;
        },
        .int => decodeInt(T, arena, p),
        .float => decodeFloat(T, arena, p),
        .pointer => {
            const s = try p.parseStringSlice(arena);
            if (comptime is_bytes) {
                return decodeBase64(arena, s);
            }
            return s;
        },
        else => @compileError("unsupported ProtoJSON scalar type: " ++ @typeName(T)),
    };
}

fn decodeInt(comptime I: type, arena: wire.Allocator, p: *JsonParser) DecodeError!I {
    p.skipWs();
    const ch = p.peek() orelse return error.UnexpectedEof;
    if (ch == '"') {
        const s = try p.parseStringSlice(arena);
        return parseIntString(I, s);
    }
    const tok = try p.readNumberToken();
    return parseIntString(I, tok);
}

fn parseIntString(comptime I: type, tok: []const u8) DecodeError!I {
    if (tok.len == 0) return error.InvalidNumber;
    if (std.mem.indexOfAny(u8, tok, ".eE") != null) {
        const f = std.fmt.parseFloat(f64, tok) catch return error.InvalidNumber;
        if (f != f or f == std.math.inf(f64) or f == -std.math.inf(f64)) return error.InvalidNumber;
        if (@trunc(f) != f) return error.InvalidNumber;
        const min_f: f64 = @floatFromInt(std.math.minInt(I));
        const max_f: f64 = @floatFromInt(std.math.maxInt(I));
        if (comptime @bitSizeOf(I) >= 64) {
            if (f < min_f or f >= max_f) return error.NumberOutOfRange;
        } else {
            if (f < min_f or f > max_f) return error.NumberOutOfRange;
        }
        return @intFromFloat(f);
    }
    return std.fmt.parseInt(I, tok, 10) catch |err| switch (err) {
        error.Overflow => error.NumberOutOfRange,
        error.InvalidCharacter => error.InvalidNumber,
    };
}

fn decodeFloat(comptime F: type, arena: wire.Allocator, p: *JsonParser) DecodeError!F {
    p.skipWs();
    const ch = p.peek() orelse return error.UnexpectedEof;
    if (ch == '"') {
        const s = try p.parseStringSlice(arena);
        if (std.mem.eql(u8, s, "NaN")) return std.math.nan(F);
        if (std.mem.eql(u8, s, "Infinity")) return std.math.inf(F);
        if (std.mem.eql(u8, s, "-Infinity")) return -std.math.inf(F);
        const f = std.fmt.parseFloat(F, s) catch return error.InvalidNumber;
        if (f != f or f == std.math.inf(F) or f == -std.math.inf(F)) return error.NumberOutOfRange;
        return f;
    }
    const tok = try p.readNumberToken();
    const f = std.fmt.parseFloat(F, tok) catch return error.InvalidNumber;
    if (f != f or f == std.math.inf(F) or f == -std.math.inf(F)) return error.NumberOutOfRange;
    return f;
}

// ---------------------------------------------------------------------------
// Base64, UTF-8, & FieldMask Helpers
// ---------------------------------------------------------------------------

fn b64Val(ch: u8) ?u8 {
    return switch (ch) {
        'A'...'Z' => ch - 'A',
        'a'...'z' => ch - 'a' + 26,
        '0'...'9' => ch - '0' + 52,
        '+', '-' => 62,
        '/', '_' => 63,
        else => null,
    };
}

/// Decodes standard or URL-safe Base64 (padded or unpadded) per ProtoJSON spec.
fn decodeBase64(arena: wire.Allocator, input: []const u8) DecodeError![]const u8 {
    var trimmed = input;
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '=') {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    if (trimmed.len == 0) return "";
    const rem = trimmed.len % 4;
    if (rem == 1) return error.InvalidBase64;

    const out_len = (trimmed.len / 4) * 3 + (if (rem == 2) @as(usize, 1) else if (rem == 3) @as(usize, 2) else @as(usize, 0));
    const buf = try arena.alloc(u8, out_len);

    var i: usize = 0;
    var o: usize = 0;
    while (i + 4 <= trimmed.len) : (i += 4) {
        const a = b64Val(trimmed[i]) orelse return error.InvalidBase64;
        const b = b64Val(trimmed[i + 1]) orelse return error.InvalidBase64;
        const c = b64Val(trimmed[i + 2]) orelse return error.InvalidBase64;
        const d = b64Val(trimmed[i + 3]) orelse return error.InvalidBase64;
        buf[o] = (a << 2) | (b >> 4);
        buf[o + 1] = ((b & 0x0F) << 4) | (c >> 2);
        buf[o + 2] = ((c & 0x03) << 6) | d;
        o += 3;
    }
    if (rem == 2) {
        const a = b64Val(trimmed[i]) orelse return error.InvalidBase64;
        const b = b64Val(trimmed[i + 1]) orelse return error.InvalidBase64;
        buf[o] = (a << 2) | (b >> 4);
    } else if (rem == 3) {
        const a = b64Val(trimmed[i]) orelse return error.InvalidBase64;
        const b = b64Val(trimmed[i + 1]) orelse return error.InvalidBase64;
        const c = b64Val(trimmed[i + 2]) orelse return error.InvalidBase64;
        buf[o] = (a << 2) | (b >> 4);
        buf[o + 1] = ((b & 0x0F) << 4) | (c >> 2);
    }
    return buf;
}

fn appendUtf8(arena: wire.Allocator, list: *std.ArrayList(u8), cp: u21) wire.Allocator.Error!void {
    if (cp < 0x80) {
        try list.append(arena, @intCast(cp));
    } else if (cp < 0x800) {
        try list.append(arena, @intCast(0xC0 | (cp >> 6)));
        try list.append(arena, @intCast(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        try list.append(arena, @intCast(0xE0 | (cp >> 12)));
        try list.append(arena, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try list.append(arena, @intCast(0x80 | (cp & 0x3F)));
    } else {
        try list.append(arena, @intCast(0xF0 | (cp >> 18)));
        try list.append(arena, @intCast(0x80 | ((cp >> 12) & 0x3F)));
        try list.append(arena, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try list.append(arena, @intCast(0x80 | (cp & 0x3F)));
    }
}

fn camelToSnakeAlloc(arena: wire.Allocator, camel: []const u8) DecodeError![]const u8 {
    var has_upper = false;
    for (camel) |ch| {
        if (ch == '_') return error.InvalidFormat;
        if (std.ascii.isUpper(ch)) has_upper = true;
    }
    if (!has_upper) return camel;

    var out: std.ArrayList(u8) = .empty;
    for (camel) |ch| {
        if (std.ascii.isUpper(ch)) {
            try out.append(arena, '_');
            try out.append(arena, std.ascii.toLower(ch));
        } else {
            try out.append(arena, ch);
        }
    }
    return out.toOwnedSlice(arena);
}
