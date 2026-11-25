const std = @import("std");

pub const wkt = @import("wkt.zig");
pub const json = @import("json.zig");
pub const rpc = @import("rpc.zig");
pub const math = std.math;
pub const Writer = std.Io.Writer;
pub const Allocator = std.mem.Allocator;
pub const CloneError = DecodeError || Allocator.Error;

pub const DelimitedError = DecodeError || error{
    FrameTooLarge,
};

pub const ContainerKind = enum {
    lazy,
    repeated,
    map,
    unknown_fields,
};

pub const max_recursion_depth: u32 = 100;
pub const max_merge_chunks: usize = 2;

pub const WireType = enum(u3) {
    varint = 0,
    i64 = 1,
    len = 2,
    sgroup = 3,
    egroup = 4,
    i32 = 5,
};

pub const Tag = struct {
    field_number: u29,
    wire_type: WireType,
};

pub const EncodeError = error{
    BufferTooSmall,
};

pub const DecodeError = error{
    UnexpectedEof,
    VarintOverflow,
    InvalidTag,
    InvalidWireType,
    WireTypeMismatch,
    UnmatchedEndGroup,
    RecursionLimitExceeded,
    InvalidUtf8,
    MergeChunkLimitExceeded,
    MissingRequiredField,
};

pub inline fn rawTag(comptime field_number: u29, comptime wt: WireType) u32 {
    return (@as(u32, field_number) << 3) | @backingInt(wt);
}

pub inline fn decodeTag(raw: u32) DecodeError!Tag {
    const field_num: u29 = @truncate(raw >> 3);
    if (field_num == 0) return error.InvalidTag;
    const raw_wt: u3 = @truncate(raw & 0x7);
    if (raw_wt > 5) return error.InvalidWireType;
    return .{
        .field_number = field_num,
        .wire_type = @fromBackingInt(raw_wt),
    };
}

/// Resolves the concrete error set of any writer (*SliceWriter, *std.Io.Writer, etc.)
/// to break recursive inferred-error-set dependency loops in cyclic messages.
pub fn WriterError(comptime W: type) type {
    const T = switch (@typeInfo(W)) {
        .pointer => |p| p.child,
        else => W,
    };
    if (@hasDecl(T, "Error")) return T.Error;
    const ret = @typeInfo(@TypeOf(T.writeAll)).@"fn".return_type.?;
    return @typeInfo(ret).error_union.error_set;
}

/// Forward zero-allocation writer targeting a caller-supplied buffer.
pub const SliceWriter = struct {
    pub const Error = EncodeError;

    buf: []u8,
    pos: usize = 0,

    pub inline fn init(buf: []u8) SliceWriter {
        return .{ .buf = buf };
    }

    pub inline fn writeByte(self: *SliceWriter, b: u8) EncodeError!void {
        if (self.pos >= self.buf.len) {
            @branchHint(.unlikely);
            return error.BufferTooSmall;
        }
        self.buf[self.pos] = b;
        self.pos += 1;
    }

    pub inline fn writeAll(self: *SliceWriter, data: []const u8) EncodeError!void {
        if (data.len > self.buf.len - self.pos) {
            @branchHint(.unlikely);
            return error.BufferTooSmall;
        }
        @memcpy(self.buf[self.pos .. self.pos + data.len], data);
        self.pos += data.len;
    }

    pub inline fn written(self: *const SliceWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

/// Single-pass reverse writer (Google upb style): writes backwards from buf.len -> 0.
pub const ReverseWriter = struct {
    pub const Error = EncodeError;

    buf: []u8,
    pos: usize,

    pub inline fn init(buf: []u8) ReverseWriter {
        return .{ .buf = buf, .pos = buf.len };
    }

    pub inline fn written(self: *const ReverseWriter) []const u8 {
        return self.buf[self.pos..self.buf.len];
    }

    pub inline fn reserve(self: *ReverseWriter, n: usize) EncodeError![]u8 {
        if (n > self.pos) {
            @branchHint(.unlikely);
            return error.BufferTooSmall;
        }
        self.pos -= n;
        return self.buf[self.pos .. self.pos + n];
    }

    pub inline fn writeByte(self: *ReverseWriter, b: u8) EncodeError!void {
        if (self.pos == 0) {
            @branchHint(.unlikely);
            return error.BufferTooSmall;
        }
        self.pos -= 1;
        self.buf[self.pos] = b;
    }

    pub inline fn writeAll(self: *ReverseWriter, data: []const u8) EncodeError!void {
        const dst = try self.reserve(data.len);
        @memcpy(dst, data);
    }

    pub inline fn writeVarint(self: *ReverseWriter, value: u64) EncodeError!void {
        if (value < 0x80) {
            @branchHint(.likely);
            return self.writeByte(@truncate(value));
        }
        return self.writeVarintMulti(value);
    }

    fn writeVarintMulti(self: *ReverseWriter, value: u64) EncodeError!void {
        var v = value;
        var tmp: [10]u8 = undefined;
        var i: usize = 0;
        while (v >= 0x80) : (i += 1) {
            tmp[i] = @as(u8, @truncate(v)) | 0x80;
            v >>= 7;
        }
        tmp[i] = @truncate(v);
        const len = i + 1;
        const dst = try self.reserve(len);
        @memcpy(dst, tmp[0..len]);
    }

    pub inline fn writeTag(self: *ReverseWriter, field_number: u29, wire_type: WireType) EncodeError!void {
        const key: u32 = (@as(u32, field_number) << 3) | @backingInt(wire_type);
        try self.writeVarint(key);
    }

    pub inline fn writeFixed32(self: *ReverseWriter, v: u32) EncodeError!void {
        const dst = try self.reserve(4);
        std.mem.writeInt(u32, dst[0..4], v, .little);
    }

    pub inline fn writeFixed64(self: *ReverseWriter, v: u64) EncodeError!void {
        const dst = try self.reserve(8);
        std.mem.writeInt(u64, dst[0..8], v, .little);
    }

    pub inline fn writeBytes(self: *ReverseWriter, data: []const u8) EncodeError!void {
        try self.writeAll(data);
        try self.writeVarint(data.len);
    }
};

// --- Sizing primitives (branchless, division-free) ---

pub inline fn varintSize(v: u64) usize {
    const bits: usize = 63 - @as(usize, @clz(v | 1));
    return (bits * 9 + 73) >> 6;
}

pub inline fn tagSize(field_number: u29) usize {
    return varintSize(@as(u64, field_number) << 3);
}

// --- ZigZag ---

pub inline fn encodeZigZag32(v: i32) u32 {
    return @bitCast((v << 1) ^ (v >> 31));
}

pub inline fn decodeZigZag32(v: u32) i32 {
    return @as(i32, @bitCast(v >> 1)) ^ -@as(i32, @intCast(v & 1));
}

pub inline fn encodeZigZag64(v: i64) u64 {
    return @bitCast((v << 1) ^ (v >> 63));
}

pub inline fn decodeZigZag64(v: u64) i64 {
    return @as(i64, @bitCast(v >> 1)) ^ -@as(i64, @intCast(v & 1));
}

// --- Forward wire write primitives ---

pub inline fn writeVarint(w: anytype, value: u64) WriterError(@TypeOf(w))!void {
    if (value < 0x80) {
        @branchHint(.likely);
        const T = switch (@typeInfo(@TypeOf(w))) {
            .pointer => |p| p.child,
            else => @TypeOf(w),
        };
        const b: u8 = @truncate(value);
        if (@hasDecl(T, "writeByte")) {
            return w.writeByte(b);
        }
        const single = [1]u8{b};
        return w.writeAll(&single);
    }
    return writeVarintMulti(w, value);
}

fn writeVarintMulti(w: anytype, value: u64) WriterError(@TypeOf(w))!void {
    var v = value;
    var buf: [10]u8 = undefined;
    var i: usize = 0;
    while (v >= 0x80) : (i += 1) {
        buf[i] = @as(u8, @truncate(v)) | 0x80;
        v >>= 7;
    }
    buf[i] = @truncate(v);
    try w.writeAll(buf[0 .. i + 1]);
}

pub inline fn writeTag(w: anytype, field_number: u29, wire_type: WireType) WriterError(@TypeOf(w))!void {
    const key: u32 = (@as(u32, field_number) << 3) | @backingInt(wire_type);
    try writeVarint(w, key);
}

pub inline fn writeFixed32(w: anytype, v: u32) WriterError(@TypeOf(w))!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try w.writeAll(&buf);
}

pub inline fn writeFixed64(w: anytype, v: u64) WriterError(@TypeOf(w))!void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try w.writeAll(&buf);
}

pub inline fn writeBytes(w: anytype, data: []const u8) WriterError(@TypeOf(w))!void {
    try writeVarint(w, data.len);
    try w.writeAll(data);
}

// --- Pointer-pair zero-copy Reader ---

pub const Reader = struct {
    ptr: [*]const u8,
    end: [*]const u8,

    pub inline fn init(buf: []const u8) Reader {
        return .{
            .ptr = buf.ptr,
            .end = buf.ptr + buf.len,
        };
    }

    pub inline fn eof(self: *const Reader) bool {
        return self.ptr == self.end;
    }

    pub inline fn remaining(self: *const Reader) usize {
        return @intFromPtr(self.end) - @intFromPtr(self.ptr);
    }

    pub inline fn readVarint(self: *Reader) DecodeError!u64 {
        if (self.ptr == self.end) {
            @branchHint(.unlikely);
            return error.UnexpectedEof;
        }
        const b0 = self.ptr[0];
        self.ptr += 1;
        if (b0 < 0x80) return b0;
        return self.readVarintMulti(b0);
    }

    inline fn readVarintMulti(self: *Reader, b0: u8) DecodeError!u64 {
        if (self.ptr == self.end) {
            @branchHint(.unlikely);
            return error.UnexpectedEof;
        }
        const b1 = self.ptr[0];
        self.ptr += 1;
        const v1: u64 = (@as(u64, b0 & 0x7F)) | (@as(u64, b1 & 0x7F) << 7);
        if (b1 < 0x80) return v1;
        return self.readVarintLoop(v1);
    }

    fn readVarintLoop(self: *Reader, initial: u64) DecodeError!u64 {
        var result = initial;
        var count: usize = 2;
        while (count < 10) : (count += 1) {
            if (self.ptr == self.end) return error.UnexpectedEof;
            const b = self.ptr[0];
            self.ptr += 1;
            if (count == 9) {
                if (b >= 0x80) return error.VarintOverflow;
                result |= @as(u64, b & 0x01) << 63;
                return result;
            }
            const shift: u6 = @intCast(count * 7);
            result |= @as(u64, b & 0x7F) << shift;
            if (b < 0x80) return result;
        }
        return error.VarintOverflow;
    }

    /// Shift-free varint skip for validation and unknown-field skipping.
    pub inline fn skipVarint(self: *Reader) DecodeError!void {
        if (self.ptr == self.end) {
            @branchHint(.unlikely);
            return error.UnexpectedEof;
        }
        const b0 = self.ptr[0];
        self.ptr += 1;
        if (b0 < 0x80) return;
        return self.skipVarintLoop();
    }

    fn skipVarintLoop(self: *Reader) DecodeError!void {
        var count: usize = 1;
        while (true) : (count += 1) {
            if (self.ptr == self.end) return error.UnexpectedEof;
            const b = self.ptr[0];
            self.ptr += 1;
            if (count == 9) {
                if (b >= 0x80) return error.VarintOverflow;
                return;
            }
            if (b < 0x80) return;
        }
    }

    /// Reads the raw varint tag (u32) without splitting field_number / wire_type.
    /// Hot path (fields 1..15) is a single byte load + MSB test.
    pub inline fn readRawTag(self: *Reader) DecodeError!?u32 {
        if (self.ptr == self.end) return null;
        const b0 = self.ptr[0];
        if (b0 < 0x80) {
            @branchHint(.likely);
            self.ptr += 1;
            return b0;
        }
        return self.readRawTagSlow();
    }

    fn readRawTagSlow(self: *Reader) DecodeError!?u32 {
        @branchHint(.cold);
        const raw = try self.readVarint();
        if (raw == 0 or raw > std.math.maxInt(u32)) return error.InvalidTag;
        return @intCast(raw);
    }

    pub inline fn readTag(self: *Reader) DecodeError!?Tag {
        const raw = (try self.readRawTag()) orelse return null;
        return try decodeTag(raw);
    }

    pub inline fn readFixed32(self: *Reader) DecodeError!u32 {
        if (self.remaining() < 4) {
            @branchHint(.unlikely);
            return error.UnexpectedEof;
        }
        const v = std.mem.readInt(u32, self.ptr[0..4], .little);
        self.ptr += 4;
        return v;
    }

    pub inline fn readFixed64(self: *Reader) DecodeError!u64 {
        if (self.remaining() < 8) {
            @branchHint(.unlikely);
            return error.UnexpectedEof;
        }
        const v = std.mem.readInt(u64, self.ptr[0..8], .little);
        self.ptr += 8;
        return v;
    }

    pub inline fn skipFixed(self: *Reader, comptime n: usize) DecodeError!void {
        if (self.remaining() < n) {
            @branchHint(.unlikely);
            return error.UnexpectedEof;
        }
        self.ptr += n;
    }

    pub inline fn readBytes(self: *Reader) DecodeError![]const u8 {
        const len_u64 = try self.readVarint();
        const len: usize = std.math.cast(usize, len_u64) orelse return error.UnexpectedEof;
        if (len > self.remaining()) {
            @branchHint(.unlikely);
            return error.UnexpectedEof;
        }
        const slice = self.ptr[0..len];
        self.ptr += len;
        return slice;
    }

    /// Official-spec unknown field skipping, including nested Proto2 SGROUP/EGROUP.
    pub fn skipField(self: *Reader, tag: Tag, depth: u32) DecodeError!void {
        switch (tag.wire_type) {
            .varint => try self.skipVarint(),
            .i64 => try self.skipFixed(8),
            .len => _ = try self.readBytes(),
            .i32 => try self.skipFixed(4),
            .egroup => return error.UnmatchedEndGroup,
            .sgroup => {
                if (depth == 0) return error.RecursionLimitExceeded;
                while (try self.readTag()) |inner| {
                    if (inner.wire_type == .egroup) {
                        if (inner.field_number != tag.field_number) return error.UnmatchedEndGroup;
                        return;
                    }
                    try self.skipField(inner, depth - 1);
                }
                return error.UnexpectedEof;
            },
        }
    }
    /// Fast comptime-specialized skip used by `decodeOnly` for unselected fields.
    pub inline fn skipWireType(self: *Reader, comptime wt: WireType) DecodeError!void {
        switch (wt) {
            .varint => _ = try self.readVarint(),
            .i64 => {
                if (self.remaining() < 8) return error.UnexpectedEof;
                self.ptr += 8;
            },
            .len => _ = try self.readBytes(),
            .i32 => {
                if (self.remaining() < 4) return error.UnexpectedEof;
                self.ptr += 4;
            },
            .sgroup, .egroup => unreachable,
        }
    }

    /// Skips an unrecognized field while returning its payload slice.
    /// For `.len` fields, returns the unwrapped length-delimited payload bytes.
    pub fn readUnknownField(self: *Reader, tag: Tag, depth: u32) DecodeError!UnknownField {
        if (tag.wire_type == .len) {
            return .{
                .field_number = tag.field_number,
                .wire_type = .len,
                .bytes = try self.readBytes(),
            };
        }
        const start = self.ptr;
        try self.skipField(tag, depth);
        const len = @intFromPtr(self.ptr) - @intFromPtr(start);
        return .{
            .field_number = tag.field_number,
            .wire_type = tag.wire_type,
            .bytes = start[0..len],
        };
    }

    /// Consumes fields until the matching `EGROUP` tag for `field_number` and returns
    /// the inner body slice (excluding the closing `EGROUP` tag).
    pub fn readGroupBytes(self: *Reader, field_number: u29, depth: u32) DecodeError![]const u8 {
        if (depth == 0) return error.RecursionLimitExceeded;
        const body_start = self.ptr;
        while (true) {
            const tag_start = self.ptr;
            const tag = (try self.readTag()) orelse return error.UnexpectedEof;
            if (tag.wire_type == .egroup) {
                if (tag.field_number != field_number) return error.UnmatchedEndGroup;
                return body_start[0 .. @intFromPtr(tag_start) - @intFromPtr(body_start)];
            }
            try self.skipField(tag, depth - 1);
        }
    }
};

/// Shift-free packed varint validation loop enforcing 10-byte / bit-63 overflow checks.
pub fn validatePackedVarints(payload: []const u8) DecodeError!void {
    var p = payload.ptr;
    const end = payload.ptr + payload.len;
    while (p != end) {
        const b0 = p[0];
        p += 1;
        if (b0 < 0x80) continue;
        var count: usize = 1;
        while (true) : (count += 1) {
            if (p == end) return error.UnexpectedEof;
            const b = p[0];
            p += 1;
            if (count == 9) {
                if (b >= 0x80) return error.VarintOverflow;
                break;
            }
            if (b < 0x80) break;
        }
    }
}

inline fn canExtendPtr(prev_ptr: [*]const u8, msg_start: [*]const u8, tag_ptr: [*]const u8) bool {
    const base = @intFromPtr(msg_start);
    const p = @intFromPtr(prev_ptr);
    const t = @intFromPtr(tag_ptr);
    return p >= base and p <= t;
}

/// Compact 2-chunk inline list preserving disjoint slices across merged submessage envelopes.
/// Contiguous tags within the same buffer always coalesce into a single `.wire` window first.
pub const WireChunks = struct {
    ptrs: [max_merge_chunks][*]const u8,
    lens: [max_merge_chunks]u32,
    field_number: u29,
    len: u2,
    /// Bit `i` is 1 when chunk `i` is a raw packed payload, 0 when it is a tagged wire window.
    packed_mask: u2 = 0,

    pub inline fn init(field_number: u29) WireChunks {
        return .{
            .ptrs = undefined,
            .lens = undefined,
            .field_number = field_number,
            .len = 0,
            .packed_mask = 0,
        };
    }

    pub inline fn sliceAt(self: *const WireChunks, idx: usize) []const u8 {
        return self.ptrs[idx][0..self.lens[idx]];
    }

    pub inline fn isPackedChunk(self: *const WireChunks, idx: usize) bool {
        return (self.packed_mask & (@as(u2, 1) << @as(u1, @intCast(idx)))) != 0;
    }

    pub fn append(self: *WireChunks, data: []const u8, is_packed: bool) DecodeError!void {
        if (self.len >= max_merge_chunks) return error.MergeChunkLimitExceeded;
        const n = std.math.cast(u32, data.len) orelse return error.UnexpectedEof;
        const idx: usize = self.len;
        self.ptrs[idx] = data.ptr;
        self.lens[idx] = n;
        if (is_packed) self.packed_mask |= (@as(u2, 1) << @as(u1, @intCast(idx)));
        self.len += 1;
    }

    pub fn tryExtendLast(
        self: *WireChunks,
        msg_start: [*]const u8,
        tag_ptr: [*]const u8,
        end_ptr: [*]const u8,
    ) DecodeError!bool {
        if (self.len == 0) return false;
        const last_idx: usize = self.len - 1;
        if (self.isPackedChunk(last_idx)) return false;
        if (canExtendPtr(self.ptrs[last_idx], msg_start, tag_ptr)) {
            const new_len = @intFromPtr(end_ptr) - @intFromPtr(self.ptrs[last_idx]);
            self.lens[last_idx] = std.math.cast(u32, new_len) orelse return error.UnexpectedEof;
            return true;
        }
        return false;
    }
};

// --- Comptime Field Codecs ---

pub const ScalarKind = enum {
    int32,
    int64,
    uint32,
    uint64,
    sint32,
    sint64,
    bool_,
    fixed32,
    sfixed32,
    float_,
    fixed64,
    sfixed64,
    double_,
    string,
    string_utf8,
    bytes,
};

pub fn ScalarCodec(comptime kind: ScalarKind) type {
    return struct {
        pub const T = switch (kind) {
            .int32, .sint32, .sfixed32 => i32,
            .int64, .sint64, .sfixed64 => i64,
            .uint32, .fixed32 => u32,
            .uint64, .fixed64 => u64,
            .bool_ => bool,
            .float_ => f32,
            .double_ => f64,
            .string, .string_utf8, .bytes => []const u8,
        };

        pub const wire_type: WireType = switch (kind) {
            .int32, .int64, .uint32, .uint64, .sint32, .sint64, .bool_ => .varint,
            .fixed32, .sfixed32, .float_ => .i32,
            .fixed64, .sfixed64, .double_ => .i64,
            .string, .string_utf8, .bytes => .len,
        };

        pub const is_packable: bool = (wire_type != .len);
        pub const is_message: bool = false;

        pub const fixed_size: ?usize = switch (wire_type) {
            .i32 => 4,
            .i64 => 8,
            else => null,
        };

        pub const default_value: T = switch (kind) {
            .bool_ => false,
            .float_, .double_ => 0.0,
            .string, .string_utf8, .bytes => "",
            else => 0,
        };

        pub inline fn isDefault(v: T) bool {
            return switch (kind) {
                .bool_ => !v,
                .float_ => @as(u32, @bitCast(v)) == 0,
                .double_ => @as(u64, @bitCast(v)) == 0,
                .string, .string_utf8, .bytes => v.len == 0,
                else => v == 0,
            };
        }

        pub inline fn size(v: T) usize {
            return switch (kind) {
                .int32 => varintSize(@bitCast(@as(i64, v))),
                .int64 => varintSize(@bitCast(v)),
                .uint32, .uint64 => varintSize(v),
                .sint32 => varintSize(encodeZigZag32(v)),
                .sint64 => varintSize(encodeZigZag64(v)),
                .bool_ => 1,
                .fixed32, .sfixed32, .float_ => 4,
                .fixed64, .sfixed64, .double_ => 8,
                .string, .string_utf8, .bytes => varintSize(v.len) + v.len,
            };
        }

        pub inline fn write(w: anytype, v: T) WriterError(@TypeOf(w))!void {
            switch (kind) {
                .int32 => try writeVarint(w, @bitCast(@as(i64, v))),
                .int64 => try writeVarint(w, @bitCast(v)),
                .uint32, .uint64 => try writeVarint(w, v),
                .sint32 => try writeVarint(w, encodeZigZag32(v)),
                .sint64 => try writeVarint(w, encodeZigZag64(v)),
                .bool_ => try writeVarint(w, @intFromBool(v)),
                .fixed32 => try writeFixed32(w, v),
                .sfixed32, .float_ => try writeFixed32(w, @bitCast(v)),
                .fixed64 => try writeFixed64(w, v),
                .sfixed64, .double_ => try writeFixed64(w, @bitCast(v)),
                .string, .string_utf8, .bytes => try writeBytes(w, v),
            }
        }

        pub inline fn writeReverse(rw: *ReverseWriter, v: T) EncodeError!void {
            switch (kind) {
                .int32 => try rw.writeVarint(@bitCast(@as(i64, v))),
                .int64 => try rw.writeVarint(@bitCast(v)),
                .uint32, .uint64 => try rw.writeVarint(v),
                .sint32 => try rw.writeVarint(encodeZigZag32(v)),
                .sint64 => try rw.writeVarint(encodeZigZag64(v)),
                .bool_ => try rw.writeByte(@intFromBool(v)),
                .fixed32 => try rw.writeFixed32(v),
                .sfixed32, .float_ => try rw.writeFixed32(@bitCast(v)),
                .fixed64 => try rw.writeFixed64(v),
                .sfixed64, .double_ => try rw.writeFixed64(@bitCast(v)),
                .string, .string_utf8, .bytes => try rw.writeBytes(v),
            }
        }

        pub inline fn read(r: *Reader, depth: u32) DecodeError!T {
            _ = depth;
            return switch (kind) {
                .int32 => @as(i32, @truncate(@as(i64, @bitCast(try r.readVarint())))),
                .int64 => @as(i64, @bitCast(try r.readVarint())),
                .uint32 => @as(u32, @truncate(try r.readVarint())),
                .uint64 => try r.readVarint(),
                .sint32 => decodeZigZag32(@truncate(try r.readVarint())),
                .sint64 => decodeZigZag64(try r.readVarint()),
                .bool_ => (try r.readVarint()) != 0,
                .fixed32 => try r.readFixed32(),
                .sfixed32, .float_ => @bitCast(try r.readFixed32()),
                .fixed64 => try r.readFixed64(),
                .sfixed64, .double_ => @bitCast(try r.readFixed64()),
                .string, .bytes => try r.readBytes(),
                .string_utf8 => blk: {
                    const s = try r.readBytes();
                    if (!std.unicode.utf8ValidateSlice(s)) {
                        @branchHint(.unlikely);
                        return error.InvalidUtf8;
                    }
                    break :blk s;
                },
            };
        }

        pub inline fn validate(r: *Reader, depth: u32) DecodeError!void {
            _ = depth;
            switch (wire_type) {
                .varint => try r.skipVarint(),
                .i32 => try r.skipFixed(4),
                .i64 => try r.skipFixed(8),
                .len => {
                    const s = try r.readBytes();
                    if (comptime kind == .string_utf8) {
                        if (!std.unicode.utf8ValidateSlice(s)) {
                            @branchHint(.unlikely);
                            return error.InvalidUtf8;
                        }
                    }
                },
                else => unreachable,
            }
        }
    };
}

pub fn EnumCodec(comptime E: type) type {
    @setEvalBranchQuota(100_000);
    return struct {
        pub const T = E;
        pub const wire_type: WireType = .varint;
        pub const is_packable: bool = true;
        pub const is_message: bool = false;
        pub const fixed_size: ?usize = null;
        pub const default_value: T = @fromBackingInt(0);

        pub inline fn isDefault(v: T) bool {
            return @backingInt(v) == 0;
        }

        pub inline fn size(v: T) usize {
            return varintSize(@bitCast(@as(i64, @backingInt(v))));
        }

        pub inline fn write(w: anytype, v: T) WriterError(@TypeOf(w))!void {
            try writeVarint(w, @bitCast(@as(i64, @backingInt(v))));
        }

        pub inline fn writeReverse(rw: *ReverseWriter, v: T) EncodeError!void {
            try rw.writeVarint(@bitCast(@as(i64, @backingInt(v))));
        }

        pub inline fn read(r: *Reader, depth: u32) DecodeError!T {
            _ = depth;
            const raw: i32 = @truncate(@as(i64, @bitCast(try r.readVarint())));
            return @as(T, @fromBackingInt(raw));
        }

        pub inline fn validate(r: *Reader, depth: u32) DecodeError!void {
            _ = depth;
            try r.skipVarint();
        }
    };
}

pub fn MessageCodec(comptime M: type) type {
    @setEvalBranchQuota(100_000);
    return struct {
        pub const T = M;
        pub const wire_type: WireType = .len;
        pub const is_packable: bool = false;
        pub const is_message: bool = true;
        pub const fixed_size: ?usize = null;
        pub const default_value: T = .{};

        pub inline fn isDefault(_: T) bool {
            return false;
        }

        pub fn size(v: T) usize {
            const n = v.encodedSize();
            return varintSize(n) + n;
        }

        pub fn write(w: anytype, v: T) WriterError(@TypeOf(w))!void {
            try writeVarint(w, v.encodedSize());
            try v.encode(w);
        }

        pub fn writeReverse(rw: *ReverseWriter, v: T) EncodeError!void {
            const end = rw.pos;
            try v.encodeReverse(rw);
            try rw.writeVarint(end - rw.pos);
        }

        pub fn read(r: *Reader, depth: u32) DecodeError!T {
            return M.decodeDepth(try r.readBytes(), depth);
        }

        pub fn mergeRead(dst: *T, r: *Reader, depth: u32) DecodeError!void {
            try dst.mergeDepth(try r.readBytes(), depth);
        }

        pub fn validate(r: *Reader, depth: u32) DecodeError!void {
            try M.validateDepth(try r.readBytes(), depth);
        }
    };
}

pub const RawPair = struct {
    ptrs: [2][*]const u8,
    lens: [2]u32,
};

/// 32-byte cyclic message view: handles unlimited same-buffer duplicates via `.wire`
/// and 2 disjoint merged chunks via `.pair`, with zero heap allocations.
pub fn Lazy(comptime M: type) type {
    @setEvalBranchQuota(100_000);
    return union(enum) {
        raw: []const u8,
        ptr: *const M,
        raw_wire: PackedSlice,
        wire: WireFieldView,
        pair: RawPair,
        pub const _protoz_kind: ContainerKind = .lazy;
        pub fn mergeRaw(
            self: *@This(),
            msg_start: [*]const u8,
            tag_ptr: [*]const u8,
            sub_bytes: []const u8,
            end_ptr: [*]const u8,
            field_number: u29,
        ) DecodeError!void {
            @branchHint(.cold);
            switch (self.*) {
                .raw_wire => |prev| {
                    if (canExtendPtr(prev.tag_ptr, msg_start, tag_ptr)) {
                        self.* = .{ .wire = .{
                            .buf = prev.tag_ptr[0 .. @intFromPtr(end_ptr) - @intFromPtr(prev.tag_ptr)],
                            .field_number = field_number,
                        } };
                    } else {
                        const n0 = std.math.cast(u32, prev.data.len) orelse return error.UnexpectedEof;
                        const n1 = std.math.cast(u32, sub_bytes.len) orelse return error.UnexpectedEof;
                        self.* = .{ .pair = .{
                            .ptrs = .{ prev.data.ptr, sub_bytes.ptr },
                            .lens = .{ n0, n1 },
                        } };
                    }
                },
                .wire => |*prev| {
                    if (canExtendPtr(prev.buf.ptr, msg_start, tag_ptr)) {
                        prev.buf = prev.buf.ptr[0 .. @intFromPtr(end_ptr) - @intFromPtr(prev.buf.ptr)];
                    } else {
                        return error.MergeChunkLimitExceeded;
                    }
                },
                .raw => |prev| {
                    const n0 = std.math.cast(u32, prev.len) orelse return error.UnexpectedEof;
                    const n1 = std.math.cast(u32, sub_bytes.len) orelse return error.UnexpectedEof;
                    self.* = .{ .pair = .{
                        .ptrs = .{ prev.ptr, sub_bytes.ptr },
                        .lens = .{ n0, n1 },
                    } };
                },
                .pair => return error.MergeChunkLimitExceeded,
                .ptr => {
                    self.* = .{ .raw_wire = .{ .data = sub_bytes, .tag_ptr = tag_ptr } };
                },
            }
        }

        pub fn decode(self: @This()) DecodeError!M {
            return self.decodeDepth(max_recursion_depth);
        }

        pub fn decodeDepth(self: @This(), depth: u32) DecodeError!M {
            return switch (self) {
                .raw => |b| M.decodeDepth(b, depth),
                .raw_wire => |rw_slice| M.decodeDepth(rw_slice.data, depth),
                .ptr => |p| p.*,
                .wire => |w| blk: {
                    var msg: M = .{};
                    var r = Reader.init(w.buf);
                    const expected_len: u32 = (@as(u32, w.field_number) << 3) | @backingInt(WireType.len);
                    const expected_grp: u32 = (@as(u32, w.field_number) << 3) | @backingInt(WireType.sgroup);
                    while (try r.readRawTag()) |raw_tag| {
                        if (raw_tag == expected_len) {
                            try msg.mergeDepth(try r.readBytes(), depth);
                        } else if (raw_tag == expected_grp) {
                            try msg.mergeDepth(try r.readGroupBytes(w.field_number, depth), depth);
                        } else {
                            const tag = try decodeTag(raw_tag);
                            try r.skipField(tag, depth);
                        }
                    }
                    break :blk msg;
                },
                .pair => |pr| blk: {
                    var msg: M = .{};
                    try msg.mergeDepth(pr.ptrs[0][0..pr.lens[0]], depth);
                    try msg.mergeDepth(pr.ptrs[1][0..pr.lens[1]], depth);
                    break :blk msg;
                },
            };
        }

        pub fn encodedSize(self: @This()) usize {
            return switch (self) {
                .raw => |b| b.len,
                .raw_wire => |rw_slice| rw_slice.data.len,
                .ptr => |p| p.encodedSize(),
                .wire => |w| blk: {
                    var total: usize = 0;
                    var r = Reader.init(w.buf);
                    const expected_len: u32 = (@as(u32, w.field_number) << 3) | @backingInt(WireType.len);
                    const expected_grp: u32 = (@as(u32, w.field_number) << 3) | @backingInt(WireType.sgroup);
                    while (r.readRawTag() catch return 0) |raw_tag| {
                        if (raw_tag == expected_len) {
                            total += (r.readBytes() catch return 0).len;
                        } else if (raw_tag == expected_grp) {
                            total += (r.readGroupBytes(w.field_number, max_recursion_depth) catch return 0).len;
                        } else {
                            const tag = decodeTag(raw_tag) catch return 0;
                            r.skipField(tag, max_recursion_depth) catch return 0;
                        }
                    }
                    break :blk total;
                },
                .pair => |pr| @as(usize, pr.lens[0]) + @as(usize, pr.lens[1]),
            };
        }

        pub fn encode(self: @This(), w: anytype) WriterError(@TypeOf(w))!void {
            switch (self) {
                .raw => |b| try w.writeAll(b),
                .raw_wire => |rw_slice| try w.writeAll(rw_slice.data),
                .ptr => |p| try p.encode(w),
                .wire => |wf| {
                    var r = Reader.init(wf.buf);
                    const expected_len: u32 = (@as(u32, wf.field_number) << 3) | @backingInt(WireType.len);
                    const expected_grp: u32 = (@as(u32, wf.field_number) << 3) | @backingInt(WireType.sgroup);
                    while (r.readRawTag() catch unreachable) |raw_tag| {
                        if (raw_tag == expected_len) {
                            try w.writeAll(r.readBytes() catch unreachable);
                        } else if (raw_tag == expected_grp) {
                            try w.writeAll(r.readGroupBytes(wf.field_number, max_recursion_depth) catch unreachable);
                        } else {
                            const tag = decodeTag(raw_tag) catch unreachable;
                            r.skipField(tag, max_recursion_depth) catch unreachable;
                        }
                    }
                },
                .pair => |pr| {
                    try w.writeAll(pr.ptrs[0][0..pr.lens[0]]);
                    try w.writeAll(pr.ptrs[1][0..pr.lens[1]]);
                },
            }
        }

        pub fn encodeReverse(self: @This(), rw: *ReverseWriter) EncodeError!void {
            switch (self) {
                .raw => |b| try rw.writeAll(b),
                .raw_wire => |rw_slice| try rw.writeAll(rw_slice.data),
                .ptr => |p| try p.encodeReverse(rw),
                .wire => {
                    const sz = self.encodedSize();
                    if (sz == 0) return;
                    const dst = try rw.reserve(sz);
                    var sw = SliceWriter.init(dst);
                    try self.encode(&sw);
                },
                .pair => |pr| {
                    try rw.writeAll(pr.ptrs[1][0..pr.lens[1]]);
                    try rw.writeAll(pr.ptrs[0][0..pr.lens[0]]);
                },
            }
        }
    };
}

pub const PackedSlice = struct {
    data: []const u8,
    tag_ptr: [*]const u8,
};

pub const WireFieldView = struct {
    buf: []const u8,
    field_number: u29,
};

/// Zero-allocation repeated field with packed-slice fast path, tight wire windows,
/// and lossless multi-chunk submessage merging.
pub fn Repeated(comptime Codec: type) type {
    @setEvalBranchQuota(100_000);
    return union(enum) {
        slice: []const Codec.T,
        packed_slice: PackedSlice,
        wire: WireFieldView,
        chunks: WireChunks,
        pub const _protoz_kind: ContainerKind = .repeated;
        pub const empty: @This() = .{ .slice = &.{} };

        pub const Iterator = struct {
            source: union(enum) {
                slice: struct { items: []const Codec.T, idx: usize = 0 },
                packed_slice: Reader,
                wire: struct {
                    reader: Reader,
                    field_number: u29,
                    packed_reader: ?Reader = null,
                },
                chunks: struct {
                    chunks: WireChunks,
                    chunk_idx: usize = 0,
                    reader: Reader = Reader.init(&.{}),
                    in_packed_chunk: bool = false,
                    packed_reader: ?Reader = null,
                },
            },

            pub inline fn next(self: *Iterator) DecodeError!?Codec.T {
                switch (self.source) {
                    .slice => |*s| {
                        if (s.idx >= s.items.len) return null;
                        const item = s.items[s.idx];
                        s.idx += 1;
                        return item;
                    },
                    .packed_slice => |*pr| {
                        if (pr.eof()) return null;
                        return try Codec.read(pr, max_recursion_depth);
                    },
                    .wire => |*w| return nextWire(w),
                    .chunks => |*c| return nextChunks(c),
                }
            }

            fn nextWire(w: anytype) DecodeError!?Codec.T {
                const expected_unpacked: u32 = (@as(u32, w.field_number) << 3) | @backingInt(Codec.wire_type);
                const expected_packed: u32 = (@as(u32, w.field_number) << 3) | @backingInt(WireType.len);
                while (true) {
                    if (w.packed_reader) |*pr| {
                        if (!pr.eof()) return try Codec.read(pr, max_recursion_depth);
                        w.packed_reader = null;
                    }
                    const raw_tag = (try w.reader.readRawTag()) orelse return null;
                    if (raw_tag == expected_unpacked) {
                        return try Codec.read(&w.reader, max_recursion_depth);
                    }
                    if (comptime Codec.is_packable) {
                        if (raw_tag == expected_packed) {
                            w.packed_reader = Reader.init(try w.reader.readBytes());
                            continue;
                        }
                    }
                    const tag = try decodeTag(raw_tag);
                    if (tag.field_number == w.field_number) return error.WireTypeMismatch;
                    try w.reader.skipField(tag, max_recursion_depth);
                }
            }

            fn nextChunks(c: anytype) DecodeError!?Codec.T {
                const expected_unpacked: u32 = (@as(u32, c.chunks.field_number) << 3) | @backingInt(Codec.wire_type);
                const expected_packed: u32 = (@as(u32, c.chunks.field_number) << 3) | @backingInt(WireType.len);
                while (true) {
                    if (c.packed_reader) |*pr| {
                        if (!pr.eof()) return try Codec.read(pr, max_recursion_depth);
                        c.packed_reader = null;
                    }
                    if (c.in_packed_chunk) {
                        if (!c.reader.eof()) return try Codec.read(&c.reader, max_recursion_depth);
                        c.in_packed_chunk = false;
                    }
                    if (!c.reader.eof()) {
                        const raw_tag = (try c.reader.readRawTag()) orelse continue;
                        if (raw_tag == expected_unpacked) {
                            return try Codec.read(&c.reader, max_recursion_depth);
                        }
                        if (comptime Codec.is_packable) {
                            if (raw_tag == expected_packed) {
                                c.packed_reader = Reader.init(try c.reader.readBytes());
                                continue;
                            }
                        }
                        const tag = try decodeTag(raw_tag);
                        if (tag.field_number == c.chunks.field_number) return error.WireTypeMismatch;
                        try c.reader.skipField(tag, max_recursion_depth);
                        continue;
                    }
                    if (c.chunk_idx >= c.chunks.len) return null;
                    const idx = c.chunk_idx;
                    c.chunk_idx += 1;
                    c.reader = Reader.init(c.chunks.sliceAt(idx));
                    c.in_packed_chunk = c.chunks.isPackedChunk(idx);
                }
            }
        };

        pub inline fn iterator(self: @This()) Iterator {
            return switch (self) {
                .slice => |s| .{ .source = .{ .slice = .{ .items = s } } },
                .packed_slice => |p| .{ .source = .{ .packed_slice = Reader.init(p.data) } },
                .wire => |w| .{ .source = .{ .wire = .{
                    .reader = Reader.init(w.buf),
                    .field_number = w.field_number,
                } } },
                .chunks => |c| .{ .source = .{ .chunks = .{ .chunks = c } } },
            };
        }

        pub inline fn validatePacked(payload: []const u8) DecodeError!void {
            if (comptime Codec.fixed_size) |fsz| {
                if (payload.len % fsz != 0) {
                    @branchHint(.unlikely);
                    return error.UnexpectedEof;
                }
            } else {
                try validatePackedVarints(payload);
            }
        }

        pub inline fn recordPacked(
            self: *@This(),
            msg_start: [*]const u8,
            tag_ptr: [*]const u8,
            r: *Reader,
            field_number: u29,
        ) DecodeError!void {
            const payload = try r.readBytes();
            try validatePacked(payload);
            if (self.* == .slice) {
                @branchHint(.likely);
                self.* = .{ .packed_slice = .{ .data = payload, .tag_ptr = tag_ptr } };
                return;
            }
            try self.mergePackedSlow(msg_start, tag_ptr, payload, r.ptr, field_number);
        }

        fn mergePackedSlow(
            self: *@This(),
            msg_start: [*]const u8,
            tag_ptr: [*]const u8,
            payload: []const u8,
            end_ptr: [*]const u8,
            field_number: u29,
        ) DecodeError!void {
            @branchHint(.cold);
            if (payload.len == 0) return;
            switch (self.*) {
                .slice => unreachable,
                .packed_slice => |prev| {
                    if (prev.data.len == 0) {
                        self.* = .{ .packed_slice = .{ .data = payload, .tag_ptr = tag_ptr } };
                    } else if (canExtendPtr(prev.tag_ptr, msg_start, tag_ptr)) {
                        self.* = .{ .wire = .{
                            .buf = prev.tag_ptr[0 .. @intFromPtr(end_ptr) - @intFromPtr(prev.tag_ptr)],
                            .field_number = field_number,
                        } };
                    } else {
                        var c = WireChunks.init(field_number);
                        try c.append(prev.data, true);
                        try c.append(payload, true);
                        self.* = .{ .chunks = c };
                    }
                },
                .wire => |*prev| {
                    if (canExtendPtr(prev.buf.ptr, msg_start, tag_ptr)) {
                        prev.buf = prev.buf.ptr[0 .. @intFromPtr(end_ptr) - @intFromPtr(prev.buf.ptr)];
                    } else {
                        var c = WireChunks.init(field_number);
                        try c.append(prev.buf, false);
                        try c.append(payload, true);
                        self.* = .{ .chunks = c };
                    }
                },
                .chunks => |*c| {
                    if (!try c.tryExtendLast(msg_start, tag_ptr, end_ptr)) {
                        try c.append(payload, true);
                    }
                },
            }
        }

        pub fn recordUnpacked(
            self: *@This(),
            msg_start: [*]const u8,
            tag_ptr: [*]const u8,
            r: *Reader,
            field_number: u29,
            depth: u32,
        ) DecodeError!void {
            try Codec.validate(r, depth);
            const elem_slice = tag_ptr[0 .. @intFromPtr(r.ptr) - @intFromPtr(tag_ptr)];
            switch (self.*) {
                .slice => {
                    self.* = .{ .wire = .{
                        .buf = elem_slice,
                        .field_number = field_number,
                    } };
                },
                .wire => |*prev| {
                    if (canExtendPtr(prev.buf.ptr, msg_start, tag_ptr)) {
                        @branchHint(.likely);
                        prev.buf = prev.buf.ptr[0 .. @intFromPtr(r.ptr) - @intFromPtr(prev.buf.ptr)];
                    } else {
                        var c = WireChunks.init(field_number);
                        try c.append(prev.buf, false);
                        try c.append(elem_slice, false);
                        self.* = .{ .chunks = c };
                    }
                },
                .packed_slice => |prev| {
                    try self.mergeUnpackedAfterPacked(msg_start, prev, tag_ptr, r.ptr, field_number);
                },
                .chunks => |*c| {
                    if (!try c.tryExtendLast(msg_start, tag_ptr, r.ptr)) {
                        try c.append(elem_slice, false);
                    }
                },
            }
        }

        fn mergeUnpackedAfterPacked(
            self: *@This(),
            msg_start: [*]const u8,
            prev: PackedSlice,
            tag_ptr: [*]const u8,
            end_ptr: [*]const u8,
            field_number: u29,
        ) DecodeError!void {
            @branchHint(.cold);
            const elem_slice = tag_ptr[0 .. @intFromPtr(end_ptr) - @intFromPtr(tag_ptr)];
            if (prev.data.len == 0) {
                self.* = .{ .wire = .{
                    .buf = elem_slice,
                    .field_number = field_number,
                } };
                return;
            }
            if (canExtendPtr(prev.tag_ptr, msg_start, tag_ptr)) {
                self.* = .{ .wire = .{
                    .buf = prev.tag_ptr[0 .. @intFromPtr(end_ptr) - @intFromPtr(prev.tag_ptr)],
                    .field_number = field_number,
                } };
            } else {
                var c = WireChunks.init(field_number);
                try c.append(prev.data, true);
                try c.append(elem_slice, false);
                self.* = .{ .chunks = c };
            }
        }

        pub fn encodedSize(self: @This(), field_number: u29, comptime pack: bool) usize {
            switch (self) {
                .slice => |items| {
                    if (items.len == 0) return 0;
                    if (comptime (Codec.is_packable and pack)) {
                        var payload: usize = 0;
                        for (items) |v| payload += Codec.size(v);
                        return tagSize(field_number) + varintSize(payload) + payload;
                    } else {
                        var total: usize = 0;
                        const tsz = tagSize(field_number);
                        for (items) |v| total += tsz + Codec.size(v);
                        return total;
                    }
                },
                .packed_slice => |p| {
                    if (p.data.len == 0) return 0;
                    if (comptime (Codec.is_packable and pack)) {
                        return tagSize(field_number) + varintSize(p.data.len) + p.data.len;
                    } else {
                        var total: usize = 0;
                        const tsz = tagSize(field_number);
                        var pr = Reader.init(p.data);
                        while (!pr.eof()) {
                            const v = Codec.read(&pr, max_recursion_depth) catch return 0;
                            total += tsz + Codec.size(v);
                        }
                        return total;
                    }
                },
                .wire, .chunks => {
                    var it = self.iterator();
                    if (comptime (Codec.is_packable and pack)) {
                        var payload: usize = 0;
                        while (it.next() catch return 0) |v| payload += Codec.size(v);
                        if (payload == 0) return 0;
                        return tagSize(field_number) + varintSize(payload) + payload;
                    } else {
                        var total: usize = 0;
                        const tsz = tagSize(field_number);
                        while (it.next() catch return 0) |v| total += tsz + Codec.size(v);
                        return total;
                    }
                },
            }
        }

        pub fn encode(self: @This(), field_number: u29, comptime pack: bool, w: anytype) WriterError(@TypeOf(w))!void {
            switch (self) {
                .slice => |items| {
                    if (items.len == 0) return;
                    if (comptime (Codec.is_packable and pack)) {
                        var payload: usize = 0;
                        for (items) |v| payload += Codec.size(v);
                        try writeTag(w, field_number, .len);
                        try writeVarint(w, payload);
                        for (items) |v| try Codec.write(w, v);
                    } else {
                        for (items) |v| {
                            try writeTag(w, field_number, Codec.wire_type);
                            try Codec.write(w, v);
                        }
                    }
                },
                .packed_slice => |p| {
                    if (p.data.len == 0) return;
                    if (comptime (Codec.is_packable and pack)) {
                        try writeTag(w, field_number, .len);
                        try writeBytes(w, p.data);
                    } else {
                        var pr = Reader.init(p.data);
                        while (!pr.eof()) {
                            const v = Codec.read(&pr, max_recursion_depth) catch unreachable;
                            try writeTag(w, field_number, Codec.wire_type);
                            try Codec.write(w, v);
                        }
                    }
                },
                .wire, .chunks => {
                    if (comptime (Codec.is_packable and pack)) {
                        var payload: usize = 0;
                        var size_it = self.iterator();
                        while (size_it.next() catch unreachable) |v| payload += Codec.size(v);
                        if (payload == 0) return;
                        try writeTag(w, field_number, .len);
                        try writeVarint(w, payload);
                        var write_it = self.iterator();
                        while (write_it.next() catch unreachable) |v| try Codec.write(w, v);
                    } else {
                        var it = self.iterator();
                        while (it.next() catch unreachable) |v| {
                            try writeTag(w, field_number, Codec.wire_type);
                            try Codec.write(w, v);
                        }
                    }
                },
            }
        }

        pub fn encodeReverse(self: @This(), field_number: u29, comptime pack: bool, rw: *ReverseWriter) EncodeError!void {
            switch (self) {
                .slice => |items| {
                    if (items.len == 0) return;
                    if (comptime (Codec.is_packable and pack)) {
                        const end = rw.pos;
                        var i = items.len;
                        while (i > 0) {
                            i -= 1;
                            try Codec.writeReverse(rw, items[i]);
                        }
                        try rw.writeVarint(end - rw.pos);
                        try rw.writeTag(field_number, .len);
                    } else {
                        var i = items.len;
                        while (i > 0) {
                            i -= 1;
                            try Codec.writeReverse(rw, items[i]);
                            try rw.writeTag(field_number, Codec.wire_type);
                        }
                    }
                },
                .packed_slice => |p| {
                    if (p.data.len == 0) return;
                    if (comptime (Codec.is_packable and pack)) {
                        try rw.writeBytes(p.data);
                        try rw.writeTag(field_number, .len);
                    } else {
                        const sz = self.encodedSize(field_number, pack);
                        if (sz == 0) return;
                        const dst = try rw.reserve(sz);
                        var sw = SliceWriter.init(dst);
                        try self.encode(field_number, pack, &sw);
                    }
                },
                .wire, .chunks => {
                    const sz = self.encodedSize(field_number, pack);
                    if (sz == 0) return;
                    const dst = try rw.reserve(sz);
                    var sw = SliceWriter.init(dst);
                    try self.encode(field_number, pack, &sw);
                },
            }
        }
    };
}

inline fn keysEqual(comptime K: type, a: K, b: K) bool {
    return if (K == []const u8) std.mem.eql(u8, a, b) else a == b;
}

/// Zero-allocation map field backed by tight wire windows and lossless multi-chunk merging.
pub fn Map(comptime KCodec: type, comptime VCodec: type) type {
    @setEvalBranchQuota(100_000);
    return union(enum) {
        slice: []const Entry,
        wire: WireFieldView,
        chunks: WireChunks,
        pub const _protoz_kind: ContainerKind = .map;
        pub const Entry = struct {
            key: KCodec.T,
            value: VCodec.T,
        };

        pub const empty: @This() = .{ .slice = &.{} };

        pub fn decodeEntry(entry_bytes: []const u8, depth: u32) DecodeError!Entry {
            const Key = @FieldType(Entry, "key");
            const Val = @FieldType(Entry, "value");
            var key: Key = codecDefault(Key);
            var value: Val = codecDefault(Val);
            var r = Reader.init(entry_bytes);
            while (try r.readTag()) |tag| {
                switch (tag.field_number) {
                    1 => {
                        if (tag.wire_type != KCodec.wire_type) return error.WireTypeMismatch;
                        key = try KCodec.read(&r, depth);
                    },
                    2 => {
                        if (tag.wire_type != VCodec.wire_type) return error.WireTypeMismatch;
                        if (comptime @typeInfo(Val) == .@"struct" and @hasDecl(Val, "mergeDepth")) {
                            if (depth == 0) return error.RecursionLimitExceeded;
                            try value.mergeDepth(try r.readBytes(), depth - 1);
                        } else {
                            value = try VCodec.read(&r, depth);
                        }
                    },
                    else => try r.skipField(tag, depth),
                }
            }
            return .{ .key = key, .value = value };
        }

        /// Zero-struct entry validator using raw tags and skip-validation.
        pub fn validateEntry(bytes: []const u8, depth: u32) DecodeError!void {
            if (depth == 0) return error.RecursionLimitExceeded;
            var r = Reader.init(bytes);
            const key_tag = comptime rawTag(1, KCodec.wire_type);
            const val_tag = comptime rawTag(2, VCodec.wire_type);
            while (try r.readRawTag()) |raw_tag| {
                if (raw_tag == key_tag) {
                    try KCodec.validate(&r, depth - 1);
                } else if (raw_tag == val_tag) {
                    try VCodec.validate(&r, depth - 1);
                } else {
                    const tag = try decodeTag(raw_tag);
                    if (tag.field_number == 1 or tag.field_number == 2) return error.WireTypeMismatch;
                    try r.skipField(tag, depth - 1);
                }
            }
        }

        pub fn recordEntry(
            self: *@This(),
            msg_start: [*]const u8,
            tag_ptr: [*]const u8,
            r: *Reader,
            field_number: u29,
            depth: u32,
        ) DecodeError!void {
            try validateEntry(try r.readBytes(), depth);
            const entry_wire = tag_ptr[0 .. @intFromPtr(r.ptr) - @intFromPtr(tag_ptr)];

            switch (self.*) {
                .slice => {
                    self.* = .{ .wire = .{
                        .buf = entry_wire,
                        .field_number = field_number,
                    } };
                },
                .wire => |*prev| {
                    if (canExtendPtr(prev.buf.ptr, msg_start, tag_ptr)) {
                        @branchHint(.likely);
                        prev.buf = prev.buf.ptr[0 .. @intFromPtr(r.ptr) - @intFromPtr(prev.buf.ptr)];
                    } else {
                        var c = WireChunks.init(field_number);
                        try c.append(prev.buf, false);
                        try c.append(entry_wire, false);
                        self.* = .{ .chunks = c };
                    }
                },
                .chunks => |*c| {
                    if (!try c.tryExtendLast(msg_start, tag_ptr, r.ptr)) {
                        try c.append(entry_wire, false);
                    }
                },
            }
        }

        pub const Iterator = struct {
            source: union(enum) {
                slice: struct { items: []const Entry, idx: usize = 0 },
                wire: struct { reader: Reader, field_number: u29 },
                chunks: struct {
                    chunks: WireChunks,
                    chunk_idx: usize = 0,
                    reader: Reader = Reader.init(&.{}),
                },
            },

            pub inline fn next(self: *Iterator) DecodeError!?Entry {
                switch (self.source) {
                    .slice => |*s| {
                        if (s.idx >= s.items.len) return null;
                        const e = s.items[s.idx];
                        s.idx += 1;
                        return e;
                    },
                    .wire => |*w| {
                        const expected_raw: u32 = (@as(u32, w.field_number) << 3) | @backingInt(WireType.len);
                        while (try w.reader.readRawTag()) |raw_tag| {
                            if (raw_tag == expected_raw) {
                                return try decodeEntry(try w.reader.readBytes(), max_recursion_depth);
                            }
                            const tag = try decodeTag(raw_tag);
                            if (tag.field_number == w.field_number) return error.WireTypeMismatch;
                            try w.reader.skipField(tag, max_recursion_depth);
                        }
                        return null;
                    },
                    .chunks => |*c| {
                        const expected_raw: u32 = (@as(u32, c.chunks.field_number) << 3) | @backingInt(WireType.len);
                        while (true) {
                            if (!c.reader.eof()) {
                                const raw_tag = (try c.reader.readRawTag()) orelse continue;
                                if (raw_tag == expected_raw) {
                                    return try decodeEntry(try c.reader.readBytes(), max_recursion_depth);
                                }
                                const tag = try decodeTag(raw_tag);
                                if (tag.field_number == c.chunks.field_number) return error.WireTypeMismatch;
                                try c.reader.skipField(tag, max_recursion_depth);
                                continue;
                            }
                            if (c.chunk_idx >= c.chunks.len) return null;
                            const idx = c.chunk_idx;
                            c.chunk_idx += 1;
                            c.reader = Reader.init(c.chunks.sliceAt(idx));
                        }
                    },
                }
            }
        };

        pub inline fn iterator(self: @This()) Iterator {
            return switch (self) {
                .slice => |s| .{ .source = .{ .slice = .{ .items = s } } },
                .wire => |w| .{ .source = .{ .wire = .{
                    .reader = Reader.init(w.buf),
                    .field_number = w.field_number,
                } } },
                .chunks => |c| .{ .source = .{ .chunks = .{ .chunks = c } } },
            };
        }

        fn scanWindowForKey(
            buf: []const u8,
            field_number: u29,
            key: KCodec.T,
            found: *?VCodec.T,
        ) DecodeError!void {
            var r = Reader.init(buf);
            const expected_raw: u32 = (@as(u32, field_number) << 3) | @backingInt(WireType.len);
            const key_tag = comptime rawTag(1, KCodec.wire_type);
            const val_tag = comptime rawTag(2, VCodec.wire_type);
            while (try r.readRawTag()) |raw_tag| {
                if (raw_tag != expected_raw) {
                    const tag = try decodeTag(raw_tag);
                    if (tag.field_number == field_number) return error.WireTypeMismatch;
                    try r.skipField(tag, max_recursion_depth);
                    continue;
                }
                const entry_bytes = try r.readBytes();
                var er = Reader.init(entry_bytes);
                var k: KCodec.T = KCodec.default_value;
                var v: VCodec.T = VCodec.default_value;
                var has_key = false;
                var key_matches = false;
                var skipped_val = false;
                while (try er.readRawTag()) |eraw| {
                    if (eraw == key_tag) {
                        k = try KCodec.read(&er, max_recursion_depth - 1);
                        has_key = true;
                        key_matches = keysEqual(KCodec.T, k, key);
                        if (key_matches and skipped_val) {
                            const full = try decodeEntry(entry_bytes, max_recursion_depth);
                            if (keysEqual(KCodec.T, full.key, key)) found.* = full.value;
                            key_matches = false;
                            break;
                        }
                    } else if (eraw == val_tag) {
                        if (has_key and !key_matches) {
                            try VCodec.validate(&er, max_recursion_depth - 1);
                            skipped_val = true;
                        } else {
                            if (comptime VCodec.is_message) {
                                try VCodec.mergeRead(&v, &er, max_recursion_depth - 1);
                            } else {
                                v = try VCodec.read(&er, max_recursion_depth - 1);
                            }
                        }
                    } else {
                        const etag = try decodeTag(eraw);
                        if (etag.field_number == 1 or etag.field_number == 2) return error.WireTypeMismatch;
                        try er.skipField(etag, max_recursion_depth - 1);
                    }
                }
                if (!has_key) key_matches = keysEqual(KCodec.T, k, key);
                if (key_matches) found.* = v;
            }
        }

        /// Official Protobuf map semantics: last duplicate key wins.
        /// Skips decoding values when key (field 1) mismatches.
        pub fn get(self: @This(), key: KCodec.T) DecodeError!?VCodec.T {
            switch (self) {
                .slice => |items| {
                    var i = items.len;
                    while (i > 0) {
                        i -= 1;
                        if (keysEqual(KCodec.T, items[i].key, key)) return items[i].value;
                    }
                    return null;
                },
                .wire => |w| {
                    var found: ?VCodec.T = null;
                    try scanWindowForKey(w.buf, w.field_number, key, &found);
                    return found;
                },
                .chunks => |c| {
                    var found: ?VCodec.T = null;
                    for (0..c.len) |i| {
                        try scanWindowForKey(c.sliceAt(i), c.field_number, key, &found);
                    }
                    return found;
                },
            }
        }

        inline fn entryPayloadSize(e: Entry) usize {
            var s: usize = 0;
            if (!KCodec.isDefault(e.key)) s += tagSize(1) + KCodec.size(e.key);
            if (!VCodec.isDefault(e.value)) s += tagSize(2) + VCodec.size(e.value);
            return s;
        }

        pub fn encodedSize(self: @This(), field_number: u29) usize {
            var total: usize = 0;
            const tsz = tagSize(field_number);
            switch (self) {
                .slice => |items| {
                    for (items) |e| {
                        const payload = entryPayloadSize(e);
                        total += tsz + varintSize(payload) + payload;
                    }
                },
                .wire, .chunks => {
                    var it = self.iterator();
                    while (it.next() catch return 0) |e| {
                        const payload = entryPayloadSize(e);
                        total += tsz + varintSize(payload) + payload;
                    }
                },
            }
            return total;
        }

        pub fn encode(self: @This(), field_number: u29, w: anytype) WriterError(@TypeOf(w))!void {
            switch (self) {
                .slice => |items| {
                    for (items) |e| {
                        const payload = entryPayloadSize(e);
                        try writeTag(w, field_number, .len);
                        try writeVarint(w, payload);
                        if (!KCodec.isDefault(e.key)) {
                            try writeTag(w, 1, KCodec.wire_type);
                            try KCodec.write(w, e.key);
                        }
                        if (!VCodec.isDefault(e.value)) {
                            try writeTag(w, 2, VCodec.wire_type);
                            try VCodec.write(w, e.value);
                        }
                    }
                },
                .wire, .chunks => {
                    var it = self.iterator();
                    while (it.next() catch unreachable) |e| {
                        const payload = entryPayloadSize(e);
                        try writeTag(w, field_number, .len);
                        try writeVarint(w, payload);
                        if (!KCodec.isDefault(e.key)) {
                            try writeTag(w, 1, KCodec.wire_type);
                            try KCodec.write(w, e.key);
                        }
                        if (!VCodec.isDefault(e.value)) {
                            try writeTag(w, 2, VCodec.wire_type);
                            try VCodec.write(w, e.value);
                        }
                    }
                },
            }
        }

        pub fn encodeReverse(self: @This(), field_number: u29, rw: *ReverseWriter) EncodeError!void {
            switch (self) {
                .slice => |items| {
                    var i = items.len;
                    while (i > 0) {
                        i -= 1;
                        const e = items[i];
                        const end = rw.pos;
                        if (!VCodec.isDefault(e.value)) {
                            try VCodec.writeReverse(rw, e.value);
                            try rw.writeTag(2, VCodec.wire_type);
                        }
                        if (!KCodec.isDefault(e.key)) {
                            try KCodec.writeReverse(rw, e.key);
                            try rw.writeTag(1, KCodec.wire_type);
                        }
                        try rw.writeVarint(end - rw.pos);
                        try rw.writeTag(field_number, .len);
                    }
                },
                .wire, .chunks => {
                    const sz = self.encodedSize(field_number);
                    if (sz == 0) return;
                    const dst = try rw.reserve(sz);
                    var sw = SliceWriter.init(dst);
                    try self.encode(field_number, &sw);
                },
            }
        }
    };
}

// --- Length-Delimited Message Framing (TCP/Unix streams, WALs, .binpb) ---

pub fn DelimitedFrame(comptime M: type) type {
    return struct {
        msg: M,
        consumed: usize,
        rest: []const u8,
    };
}

/// Exact byte length of a varint-length-prefixed message frame.
pub inline fn encodedDelimitedSize(msg: anytype) usize {
    const body = msg.encodedSize();
    return varintSize(body) + body;
}

/// Single-pass reverse serialization of a length-delimited message frame into `buf`.
pub fn encodeDelimitedSlice(msg: anytype, buf: []u8) EncodeError![]const u8 {
    var rw = ReverseWriter.init(buf);
    const end = rw.pos;
    try msg.encodeReverse(&rw);
    try rw.writeVarint(end - rw.pos);
    return rw.written();
}

/// Forward-streaming serialization of a length-delimited message frame to any writer.
pub fn encodeDelimited(msg: anytype, w: anytype) WriterError(@TypeOf(w))!void {
    const body = msg.encodedSize();
    try writeVarint(w, body);
    try msg.encode(w);
}

/// Streaming-safe decoder for partial network/file buffers.
/// - Returns `null` when more bytes are needed (empty buffer, partial length varint, or incomplete body).
/// - Returns `error.FrameTooLarge` immediately if the declared length exceeds `max_frame_bytes`.
/// - Returns `DecodeError` if the varint overflows or the complete frame payload is invalid protobuf.
pub fn tryDecodeDelimited(
    comptime M: type,
    buf: []const u8,
    max_frame_bytes: usize,
) DelimitedError!?DelimitedFrame(M) {
    if (buf.len == 0) return null;
    var r = Reader.init(buf);
    const frame_len_u64 = r.readVarint() catch |err| switch (err) {
        error.UnexpectedEof => return null,
        else => return err,
    };
    const frame_len = std.math.cast(usize, frame_len_u64) orelse return error.FrameTooLarge;
    if (frame_len > max_frame_bytes) return error.FrameTooLarge;
    if (frame_len > r.remaining()) return null;

    const payload = r.ptr[0..frame_len];
    r.ptr += frame_len;
    const consumed = @intFromPtr(r.ptr) - @intFromPtr(buf.ptr);
    return .{
        .msg = try M.decode(payload),
        .consumed = consumed,
        .rest = buf[consumed..],
    };
}

/// Strict decoder for complete length-delimited buffers (returns `error.UnexpectedEof` on truncation).
pub fn decodeDelimitedSlice(comptime M: type, buf: []const u8) DecodeError!DelimitedFrame(M) {
    var r = Reader.init(buf);
    const payload = try r.readBytes();
    const consumed = @intFromPtr(r.ptr) - @intFromPtr(buf.ptr);
    return .{
        .msg = try M.decode(payload),
        .consumed = consumed,
        .rest = buf[consumed..],
    };
}

/// Zero-allocation iterator over a buffer containing consecutive length-delimited messages.
pub fn DelimitedIterator(comptime M: type) type {
    return struct {
        rest: []const u8,

        pub inline fn init(buf: []const u8) @This() {
            return .{ .rest = buf };
        }

        pub fn next(self: *@This()) DecodeError!?M {
            if (self.rest.len == 0) return null;
            const frame = try decodeDelimitedSlice(M, self.rest);
            self.rest = frame.rest;
            return frame.msg;
        }
    };
}

// --- Zero-Allocation Debug Formatting (`{f}`) ---

pub fn formatMessage(msg: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
    return formatValue(msg, w, 16);
}

fn writeQuotedBytes(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (bytes) |b| {
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x20...0x21, 0x23...0x5B, 0x5D...0x7E => try w.writeByte(b),
            else => try w.print("\\x{x:0>2}", .{b}),
        }
    }
    try w.writeByte('"');
}

fn formatValue(val: anytype, w: *std.Io.Writer, depth: u32) std.Io.Writer.Error!void {
    @setEvalBranchQuota(100_000);
    const T = @TypeOf(val);

    if (@typeInfo(T) == .@"union" and @hasDecl(T, "_protoz_kind")) {
        switch (T._protoz_kind) {
            .lazy => {
                if (depth == 0) {
                    try w.writeAll("{...}");
                    return;
                }
                const sub = val.decodeDepth(depth) catch {
                    try w.writeAll("<invalid-lazy>");
                    return;
                };
                return formatValue(sub, w, depth - 1);
            },
            .repeated => {
                try w.writeByte('[');
                var it = val.iterator();
                var first = true;
                while (true) {
                    const maybe_item = it.next() catch {
                        if (!first) try w.writeAll(", ");
                        try w.writeAll("<invalid>");
                        break;
                    };
                    const item = maybe_item orelse break;
                    if (!first) try w.writeAll(", ");
                    try formatValue(item, w, depth);
                    first = false;
                }
                try w.writeByte(']');
                return;
            },
            .map => {
                try w.writeByte('{');
                var it = val.iterator();
                var first = true;
                while (true) {
                    const maybe_entry = it.next() catch {
                        if (!first) try w.writeAll(", ");
                        try w.writeAll("<invalid>");
                        break;
                    };
                    const entry = maybe_entry orelse break;
                    if (!first) try w.writeAll(", ");
                    try formatValue(entry.key, w, depth);
                    try w.writeAll(": ");
                    try formatValue(entry.value, w, depth);
                    first = false;
                }
                try w.writeByte('}');
                return;
            },
            .unknown_fields => {
                try val.formatWithKnown(&.{}, w);
                return;
            },
        }
    }

    switch (@typeInfo(T)) {
        .optional => {
            if (val) |inner| {
                try formatValue(inner, w, depth);
            } else {
                try w.writeAll("null");
            }
        },
        .bool => try w.writeAll(if (val) "true" else "false"),
        .int, .float => try w.print("{d}", .{val}),
        .@"enum" => |e| {
            const raw = @backingInt(val);
            inline for (e.field_names, e.field_values) |ename, ev| {
                if (raw == ev) {
                    try w.writeAll(ename);
                    return;
                }
            }
            try w.print("{d}", .{raw});
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                try writeQuotedBytes(w, val);
            } else {
                try formatValue(val.*, w, depth);
            }
        },
        .@"union" => {
            switch (val) {
                inline else => |payload, tag| {
                    try w.writeAll("{ ");
                    try w.writeAll(@tagName(tag));
                    try w.writeAll(": ");
                    try formatValue(payload, w, depth);
                    try w.writeAll(" }");
                },
            }
        },
        .@"struct" => |st| {
            if (depth == 0) {
                try w.writeAll("{...}");
                return;
            }
            try w.writeByte('{');
            var first = true;
            inline for (st.field_names, st.field_types) |fname, FT| {
                const fv = @field(val, fname);
                const omit = blk: {
                    if (@typeInfo(FT) == .optional) break :blk (fv == null);
                    if (FT == UnknownFields) {
                        if (@hasDecl(T, "_protoz_known_fields")) {
                            break :blk (fv.encodedSize(T._protoz_known_fields) == 0);
                        }
                        break :blk fv.isEmpty();
                    }
                    if (@typeInfo(FT) == .@"union" and @hasDecl(FT, "_protoz_kind")) {
                        if (FT._protoz_kind == .repeated or FT._protoz_kind == .map) {
                            break :blk (fv == .slice and fv.slice.len == 0);
                        }
                    }
                    break :blk false;
                };
                if (!omit) {
                    try w.writeAll(if (first) " " else ", ");
                    try w.writeAll(fname);
                    try w.writeAll(": ");
                    if (FT == UnknownFields and @hasDecl(T, "_protoz_known_fields")) {
                        try fv.formatWithKnown(T._protoz_known_fields, w);
                    } else {
                        try formatValue(fv, w, depth - 1);
                    }
                    first = false;
                }
            }
            if (!first) try w.writeByte(' ');
            try w.writeByte('}');
        },
        else => try w.print("{any}", .{val}),
    }
}

// --- On-Demand Streaming & Comptime Selective Projection ---

pub const UnknownField = struct {
    field_number: u29,
    wire_type: WireType,
    bytes: []const u8,
};

fn codecDefault(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .bool => false,
        .int, .float => 0,
        .@"enum" => @fromBackingInt(0),
        .@"struct" => .{},
        .pointer => |p| if (p.size == .slice and p.child == u8) "" else @compileError("unsupported map codec type"),
        else => @compileError("unsupported map codec type"),
    };
}

/// Lightweight 24-byte streaming view over one wire occurrence of a packable repeated field.
/// Handles both packed LEN chunks and unpacked single elements uniformly via `.iterator()`.
pub fn PackedChunk(comptime Codec: type) type {
    const Elem = @typeInfo(@FieldType(Repeated(Codec), "slice")).pointer.child;
    return union(enum) {
        single: Elem,
        @"packed": []const u8,

        pub const Iterator = struct {
            mode: union(enum) {
                single: ?Elem,
                @"packed": Reader,
            },

            pub fn next(self: *@This()) DecodeError!?Elem {
                switch (self.mode) {
                    .single => |*val| {
                        const out = val.* orelse return null;
                        val.* = null;
                        return out;
                    },
                    .@"packed" => |*r| {
                        if (r.eof()) return null;
                        return try Codec.read(r, max_recursion_depth);
                    },
                }
            }
        };

        pub inline fn iterator(self: @This()) Iterator {
            return switch (self) {
                .single => |v| .{ .mode = .{ .single = v } },
                .@"packed" => |b| .{ .mode = .{ .@"packed" = Reader.init(b) } },
            };
        }
    };
}

// --- Opt-In Unknown-Field Preservation (Zero-Allocation Proxy Pass-Through) ---

pub const UnknownChunks = struct {
    ptrs: [max_merge_chunks][*]const u8,
    lens: [max_merge_chunks]u32,
    len: u2,
    /// Bit `i` is 1 when chunk `i` is a filtered window (may contain known tags), 0 when pure raw unknown bytes.
    window_mask: u2 = 0,

    pub inline fn init() UnknownChunks {
        return .{
            .ptrs = undefined,
            .lens = undefined,
            .len = 0,
            .window_mask = 0,
        };
    }

    pub inline fn sliceAt(self: *const UnknownChunks, idx: usize) []const u8 {
        return self.ptrs[idx][0..self.lens[idx]];
    }

    pub inline fn isWindowChunk(self: *const UnknownChunks, idx: usize) bool {
        return (self.window_mask & (@as(u2, 1) << @as(u1, @intCast(idx)))) != 0;
    }

    pub fn append(self: *UnknownChunks, data: []const u8, is_window: bool) DecodeError!void {
        if (self.len >= max_merge_chunks) return error.MergeChunkLimitExceeded;
        const n = std.math.cast(u32, data.len) orelse return error.UnexpectedEof;
        const idx: usize = self.len;
        self.ptrs[idx] = data.ptr;
        self.lens[idx] = n;
        if (is_window) self.window_mask |= (@as(u2, 1) << @as(u1, @intCast(idx)));
        self.len += 1;
    }

    pub fn tryExtendLast(
        self: *UnknownChunks,
        msg_start: [*]const u8,
        tag_ptr: [*]const u8,
        end_ptr: [*]const u8,
    ) DecodeError!bool {
        if (self.len == 0) return false;
        const last_idx: usize = self.len - 1;
        const prev_ptr = self.ptrs[last_idx];
        const prev_len: usize = self.lens[last_idx];
        if (!self.isWindowChunk(last_idx) and @intFromPtr(prev_ptr) + prev_len == @intFromPtr(tag_ptr)) {
            const new_len = @intFromPtr(end_ptr) - @intFromPtr(prev_ptr);
            self.lens[last_idx] = std.math.cast(u32, new_len) orelse return error.UnexpectedEof;
            return true;
        }
        if (canExtendPtr(prev_ptr, msg_start, tag_ptr)) {
            const new_len = @intFromPtr(end_ptr) - @intFromPtr(prev_ptr);
            self.lens[last_idx] = std.math.cast(u32, new_len) orelse return error.UnexpectedEof;
            self.window_mask |= (@as(u2, 1) << @as(u1, @intCast(last_idx)));
            return true;
        }
        return false;
    }
};

/// 40-byte zero-allocation view preserving unrecognized wire fields for proxy pass-through.
pub const UnknownFields = union(enum) {
    empty,
    /// Pure contiguous unknown wire spans (tag + payload); O(1) size and re-encode.
    raw: []const u8,
    /// Single-buffer slice spanning first..last unknown tag (may contain interleaved known fields).
    window: []const u8,
    /// Up to 2 disjoint chunks from `mergeDepth` across separate wire buffers.
    chunks: UnknownChunks,

    pub const _protoz_kind: ContainerKind = .unknown_fields;

    pub inline fn isEmpty(self: UnknownFields) bool {
        return switch (self) {
            .empty => true,
            .raw => |b| b.len == 0,
            .window => |w| w.len == 0,
            .chunks => |c| c.len == 0,
        };
    }

    pub fn record(
        self: *UnknownFields,
        msg_start: [*]const u8,
        tag_ptr: [*]const u8,
        end_ptr: [*]const u8,
    ) DecodeError!void {
        @branchHint(.cold);
        const span_len = @intFromPtr(end_ptr) - @intFromPtr(tag_ptr);
        const span = tag_ptr[0..span_len];
        switch (self.*) {
            .empty => {
                self.* = .{ .raw = span };
            },
            .raw => |*prev| {
                if (@intFromPtr(prev.ptr) + prev.len == @intFromPtr(tag_ptr)) {
                    prev.* = prev.ptr[0 .. prev.len + span_len];
                } else if (canExtendPtr(prev.ptr, msg_start, tag_ptr)) {
                    self.* = .{ .window = prev.ptr[0 .. @intFromPtr(end_ptr) - @intFromPtr(prev.ptr)] };
                } else {
                    var c = UnknownChunks.init();
                    try c.append(prev.*, false);
                    try c.append(span, false);
                    self.* = .{ .chunks = c };
                }
            },
            .window => |*prev| {
                if (canExtendPtr(prev.ptr, msg_start, tag_ptr)) {
                    prev.* = prev.ptr[0 .. @intFromPtr(end_ptr) - @intFromPtr(prev.ptr)];
                } else {
                    var c = UnknownChunks.init();
                    try c.append(prev.*, true);
                    try c.append(span, false);
                    self.* = .{ .chunks = c };
                }
            },
            .chunks => |*c| {
                if (try c.tryExtendLast(msg_start, tag_ptr, end_ptr)) return;
                try c.append(span, false);
            },
        }
    }

    inline fn isKnownField(comptime known_fields: []const u29, field_number: u29) bool {
        if (comptime known_fields.len == 0) return false;
        inline for (known_fields) |kf| {
            if (field_number == kf) return true;
        }
        return false;
    }

    fn windowEncodedSize(win: []const u8, comptime known_fields: []const u29) usize {
        @setEvalBranchQuota(100_000);
        var total: usize = 0;
        var r = Reader.init(win);
        while (true) {
            const start = r.ptr;
            const raw_tag = (r.readRawTag() catch return 0) orelse break;
            const tag = decodeTag(raw_tag) catch return 0;
            r.skipField(tag, max_recursion_depth) catch return 0;
            if (!isKnownField(known_fields, tag.field_number)) {
                total += @intFromPtr(r.ptr) - @intFromPtr(start);
            }
        }
        return total;
    }

    fn writeWindow(win: []const u8, comptime known_fields: []const u29, w: anytype) WriterError(@TypeOf(w))!void {
        @setEvalBranchQuota(100_000);
        var r = Reader.init(win);
        while (true) {
            const start = r.ptr;
            const raw_tag = (r.readRawTag() catch unreachable) orelse break;
            const tag = decodeTag(raw_tag) catch unreachable;
            r.skipField(tag, max_recursion_depth) catch unreachable;
            if (!isKnownField(known_fields, tag.field_number)) {
                const len = @intFromPtr(r.ptr) - @intFromPtr(start);
                try w.writeAll(start[0..len]);
            }
        }
    }

    pub fn encodedSize(self: UnknownFields, comptime known_fields: []const u29) usize {
        return switch (self) {
            .empty => 0,
            .raw => |b| b.len,
            .window => |win| windowEncodedSize(win, known_fields),
            .chunks => |c| blk: {
                var total: usize = 0;
                for (0..c.len) |i| {
                    const s = c.sliceAt(i);
                    total += if (c.isWindowChunk(i)) windowEncodedSize(s, known_fields) else s.len;
                }
                break :blk total;
            },
        };
    }

    pub fn encode(self: UnknownFields, comptime known_fields: []const u29, w: anytype) WriterError(@TypeOf(w))!void {
        switch (self) {
            .empty => {},
            .raw => |b| try w.writeAll(b),
            .window => |win| try writeWindow(win, known_fields, w),
            .chunks => |c| {
                for (0..c.len) |i| {
                    const s = c.sliceAt(i);
                    if (c.isWindowChunk(i)) {
                        try writeWindow(s, known_fields, w);
                    } else {
                        try w.writeAll(s);
                    }
                }
            },
        }
    }

    pub fn encodeReverse(self: UnknownFields, comptime known_fields: []const u29, rw: *ReverseWriter) EncodeError!void {
        switch (self) {
            .empty => {},
            .raw => |b| try rw.writeAll(b),
            .window => |win| {
                const sz = windowEncodedSize(win, known_fields);
                if (sz == 0) return;
                const dst = try rw.reserve(sz);
                var sw = SliceWriter.init(dst);
                try writeWindow(win, known_fields, &sw);
            },
            .chunks => |c| {
                var i: usize = c.len;
                while (i > 0) {
                    i -= 1;
                    const s = c.sliceAt(i);
                    if (c.isWindowChunk(i)) {
                        const sz = windowEncodedSize(s, known_fields);
                        if (sz == 0) continue;
                        const dst = try rw.reserve(sz);
                        var sw = SliceWriter.init(dst);
                        try writeWindow(s, known_fields, &sw);
                    } else {
                        try rw.writeAll(s);
                    }
                }
            },
        }
    }

    /// Compacts any `.window` or `.chunks` view into a single owned `.raw` slice.
    pub fn cloneCompact(
        self: UnknownFields,
        allocator: Allocator,
        comptime known_fields: []const u29,
    ) CloneError!UnknownFields {
        const sz = self.encodedSize(known_fields);
        if (sz == 0) return .empty;
        const buf = try allocator.alloc(u8, sz);
        var sw = SliceWriter.init(buf);
        self.encode(known_fields, &sw) catch unreachable;
        return .{ .raw = sw.written() };
    }

    pub fn Iterator(comptime known_fields: []const u29) type {
        return struct {
            source: UnknownFields,
            chunk_idx: usize = 0,
            reader: Reader = Reader.init(""),
            filter_known: bool = false,
            active: bool = false,

            fn loadChunk(self: *@This()) bool {
                switch (self.source) {
                    .empty => return false,
                    .raw => |b| {
                        if (self.chunk_idx > 0 or b.len == 0) return false;
                        self.chunk_idx = 1;
                        self.reader = Reader.init(b);
                        self.filter_known = false;
                        self.active = true;
                        return true;
                    },
                    .window => |win| {
                        if (self.chunk_idx > 0 or win.len == 0) return false;
                        self.chunk_idx = 1;
                        self.reader = Reader.init(win);
                        self.filter_known = true;
                        self.active = true;
                        return true;
                    },
                    .chunks => |c| {
                        if (self.chunk_idx >= c.len) return false;
                        const idx = self.chunk_idx;
                        self.chunk_idx += 1;
                        self.reader = Reader.init(c.sliceAt(idx));
                        self.filter_known = c.isWindowChunk(idx);
                        self.active = true;
                        return true;
                    },
                }
            }

            pub fn next(self: *@This()) DecodeError!?UnknownField {
                @setEvalBranchQuota(100_000);
                while (true) {
                    if (!self.active or self.reader.eof()) {
                        if (!self.loadChunk()) return null;
                    }
                    const raw_tag = (try self.reader.readRawTag()) orelse continue;
                    const tag = try decodeTag(raw_tag);
                    if (self.filter_known and isKnownField(known_fields, tag.field_number)) {
                        try self.reader.skipField(tag, max_recursion_depth);
                        continue;
                    }
                    return try self.reader.readUnknownField(tag, max_recursion_depth);
                }
            }
        };
    }

    pub inline fn iterator(self: UnknownFields, comptime known_fields: []const u29) Iterator(known_fields) {
        return .{ .source = self };
    }

    pub fn formatWithKnown(
        self: UnknownFields,
        comptime known_fields: []const u29,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try w.writeByte('[');
        var it = self.iterator(known_fields);
        var first = true;
        while (true) {
            const maybe_u = it.next() catch {
                if (!first) try w.writeAll(", ");
                try w.writeAll("<invalid>");
                break;
            };
            const u = maybe_u orelse break;
            if (!first) try w.writeAll(", ");
            try w.print("#{d}({s}, {d}B)", .{ u.field_number, @tagName(u.wire_type), u.bytes.len });
            first = false;
        }
        try w.writeByte(']');
    }
};

fn selectorFieldName(comptime item: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(item))) {
        .enum_literal => @tagName(item),
        .pointer => item,
        else => @compileError("decodeOnly selectors must be enum literals like `.id`"),
    };
}

/// Builds a minimal struct containing only the selected fields of message `M`,
/// preserving each field's exact type, alignment, and Protobuf default value.
pub fn Projection(comptime M: type, comptime fields: anytype) type {
    @setEvalBranchQuota(100_000);
    const m_info = @typeInfo(M).@"struct";
    const sel_info = @typeInfo(@TypeOf(fields)).@"struct";
    const n = sel_info.field_names.len;

    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]std.lang.Type.Struct.FieldAttributes = undefined;

    inline for (sel_info.field_names, 0..) |tuple_key, i| {
        const want = selectorFieldName(@field(fields, tuple_key));
        for (0..i) |prev| {
            if (std.mem.eql(u8, names[prev], want)) {
                @compileError("duplicate field in decodeOnly: " ++ want);
            }
        }
        var found = false;
        inline for (m_info.field_names, m_info.field_types, m_info.field_attrs) |fname, ftype, fattr| {
            if (std.mem.eql(u8, fname, want)) {
                names[i] = fname;
                types[i] = ftype;
                attrs[i] = fattr;
                found = true;
                break;
            }
        }
        if (!found) {
            @compileError("unknown field '" ++ want ++ "' for " ++ @typeName(M));
        }
    }

    return @Struct(.auto, null, &names, &types, &attrs);
}

// --- Owned Escape Hatch (Arena-Backed Deep Copy) ---

/// Self-contained arena-backed deep copy of a message that can outlive its wire buffer.
/// All wire-backed views (`Repeated`, `Map`, `Lazy`, strings/bytes) are materialized into
/// owned memory; calling `.deinit()` releases the entire graph in O(1).
pub fn Owned(comptime M: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: M,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

/// Deep-copies `msg` into a caller-managed arena (ideal for per-request HTTP/gRPC arenas).
pub fn cloneMessage(arena: Allocator, msg: anytype) CloneError!@TypeOf(msg) {
    return cloneValue(arena, msg, max_recursion_depth);
}

/// Creates a dedicated `ArenaAllocator`, deep-copies `msg` into it, and returns an `Owned(M)`.
pub fn cloneOwned(allocator: Allocator, msg: anytype) CloneError!Owned(@TypeOf(msg)) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const cloned = try cloneValue(arena.allocator(), msg, max_recursion_depth);
    return .{
        .arena = arena,
        .value = cloned,
    };
}

fn cloneValue(allocator: Allocator, val: anytype, depth: u32) CloneError!@TypeOf(val) {
    @setEvalBranchQuota(100_000);
    const T = @TypeOf(val);

    if (@typeInfo(T) == .@"union" and @hasDecl(T, "_protoz_kind")) {
        switch (T._protoz_kind) {
            .lazy => {
                if (depth == 0) return error.RecursionLimitExceeded;
                const M = @typeInfo(@FieldType(T, "ptr")).pointer.child;
                const sub = try val.decodeDepth(depth);
                const ptr = try allocator.create(M);
                ptr.* = try cloneValue(allocator, sub, depth - 1);
                return .{ .ptr = ptr };
            },
            .repeated => {
                const Elem = @typeInfo(@FieldType(T, "slice")).pointer.child;
                var list: std.ArrayList(Elem) = .empty;
                var it = val.iterator();
                while (try it.next()) |item| {
                    try list.append(allocator, try cloneValue(allocator, item, depth));
                }
                return .{ .slice = try list.toOwnedSlice(allocator) };
            },
            .map => {
                const Entry = @typeInfo(@FieldType(T, "slice")).pointer.child;
                var list: std.ArrayList(Entry) = .empty;
                var it = val.iterator();
                while (try it.next()) |entry| {
                    try list.append(allocator, .{
                        .key = try cloneValue(allocator, entry.key, depth),
                        .value = try cloneValue(allocator, entry.value, depth),
                    });
                }
                return .{ .slice = try list.toOwnedSlice(allocator) };
            },
            .unknown_fields => return try val.cloneCompact(allocator, &.{}),
        }
    } else switch (@typeInfo(T)) {
        .optional => {
            if (val) |inner| {
                return try cloneValue(allocator, inner, depth);
            }
            return null;
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                if (val.len == 0) return "";
                return try allocator.dupe(u8, val);
            }
            @compileError("unsupported pointer type in wire.cloneMessage: " ++ @typeName(T));
        },
        .@"union" => {
            switch (val) {
                inline else => |payload, tag| {
                    return @unionInit(T, @tagName(tag), try cloneValue(allocator, payload, depth));
                },
            }
        },
        .@"struct" => |st| {
            var out: T = undefined;
            inline for (st.field_names, st.field_types) |fname, FT| {
                if (FT == UnknownFields and @hasDecl(T, "_protoz_known_fields")) {
                    @field(out, fname) = try @field(val, fname).cloneCompact(allocator, T._protoz_known_fields);
                } else {
                    @field(out, fname) = try cloneValue(allocator, @field(val, fname), depth);
                }
            }
            return out;
        },
        .bool, .int, .float, .@"enum", .void => return val,
        else => @compileError("unsupported type in wire.cloneMessage: " ++ @typeName(T)),
    }
}

/// Codec for Proto2 delimited `group` fields (`TAG(N, .sgroup) ... TAG(N, .egroup)`).
/// Compatible with `wire.Repeated(wire.GroupCodec(GroupMsg, N))`.
pub fn GroupCodec(comptime M: type, comptime field_number: u29) type {
    @setEvalBranchQuota(100_000);
    return struct {
        pub const T = M;
        pub const wire_type: WireType = .sgroup;
        pub const is_packable: bool = false;
        pub const is_message: bool = true;
        pub const fixed_size: ?usize = null;
        pub const default_value: T = .{};

        pub inline fn isDefault(_: T) bool {
            return false;
        }

        pub fn size(v: T) usize {
            return v.encodedSize() + tagSize(field_number);
        }

        pub fn write(w: anytype, v: T) WriterError(@TypeOf(w))!void {
            try v.encode(w);
            try writeTag(w, field_number, .egroup);
        }

        pub fn writeReverse(rw: *ReverseWriter, v: T) EncodeError!void {
            try rw.writeTag(field_number, .egroup);
            try v.encodeReverse(rw);
        }

        pub fn read(r: *Reader, depth: u32) DecodeError!T {
            const body = try r.readGroupBytes(field_number, depth);
            return M.decodeDepth(body, depth);
        }

        pub fn mergeRead(dst: *T, r: *Reader, depth: u32) DecodeError!void {
            const body = try r.readGroupBytes(field_number, depth);
            try dst.mergeDepth(body, depth);
        }

        pub fn validate(r: *Reader, depth: u32) DecodeError!void {
            const body = try r.readGroupBytes(field_number, depth);
            try M.validateDepth(body, depth);
        }
    };
}

fn unknownFieldsOf(msg: anytype) *const UnknownFields {
    const M = @typeInfo(@TypeOf(msg)).pointer.child;
    if (comptime @hasField(M, "_unknown_fields")) return &msg._unknown_fields;
    if (comptime @hasField(M, "_protoz_unknown_fields")) return &msg._protoz_unknown_fields;
    @compileError(@typeName(M) ++ " was compiled without `preserve_unknown_fields = true`");
}

fn decodeUnknownPayload(comptime Codec: type, u: UnknownField) DecodeError!Codec.T {
    if (comptime Codec.is_message) {
        if (comptime Codec.wire_type == .sgroup) {
            var er = Reader.init(u.bytes);
            const body = try er.readGroupBytes(u.field_number, max_recursion_depth);
            return Codec.T.decodeDepth(body, max_recursion_depth);
        }
        return Codec.T.decodeDepth(u.bytes, max_recursion_depth);
    } else if (comptime Codec.wire_type == .len) {
        if (comptime Codec == ScalarCodec(.string_utf8)) {
            if (!std.unicode.utf8ValidateSlice(u.bytes)) return error.InvalidUtf8;
        }
        return u.bytes;
    } else {
        var er = Reader.init(u.bytes);
        return Codec.read(&er, max_recursion_depth);
    }
}

/// Zero-allocation typed Proto2 singular extension descriptor backed by `UnknownFields`.
pub fn Extension(comptime Extendee: type, comptime field_number: u29, comptime Codec: type) type {
    return struct {
        pub const Host = Extendee;
        pub const number: u29 = field_number;
        pub const Value = Codec.T;

        pub fn has(msg: *const Extendee) DecodeError!bool {
            const uf = unknownFieldsOf(msg);
            var it = uf.iterator(Extendee._protoz_known_fields);
            while (try it.next()) |u| {
                if (u.field_number == field_number) return true;
            }
            return false;
        }

        pub fn get(msg: *const Extendee) DecodeError!?Value {
            const uf = unknownFieldsOf(msg);
            var it = uf.iterator(Extendee._protoz_known_fields);
            var found: ?Value = null;
            while (try it.next()) |u| {
                if (u.field_number != field_number) continue;
                if (u.wire_type != Codec.wire_type) return error.WireTypeMismatch;
                if (comptime Codec.is_message) {
                    const body = if (comptime Codec.wire_type == .sgroup) blk: {
                        var er = Reader.init(u.bytes);
                        break :blk try er.readGroupBytes(field_number, max_recursion_depth);
                    } else u.bytes;
                    if (found) |*existing| {
                        try existing.mergeDepth(body, max_recursion_depth);
                    } else {
                        found = try Codec.T.decodeDepth(body, max_recursion_depth);
                    }
                } else {
                    found = try decodeUnknownPayload(Codec, u);
                }
            }
            return found;
        }

        pub fn encodeSlice(val: Value, buf: []u8) EncodeError![]const u8 {
            var rw = ReverseWriter.init(buf);
            try Codec.writeReverse(&rw, val);
            try rw.writeTag(field_number, Codec.wire_type);
            return rw.written();
        }
    };
}

/// Zero-allocation typed Proto2 repeated extension descriptor backed by `UnknownFields`.
pub fn RepeatedExtension(comptime Extendee: type, comptime field_number: u29, comptime Codec: type) type {
    return struct {
        pub const Host = Extendee;
        pub const number: u29 = field_number;
        pub const Value = Codec.T;

        pub const Iterator = struct {
            base: UnknownFields.Iterator(Extendee._protoz_known_fields),
            packed_reader: ?Reader = null,

            pub fn next(self: *@This()) DecodeError!?Value {
                while (true) {
                    if (self.packed_reader) |*pr| {
                        if (!pr.eof()) return try Codec.read(pr, max_recursion_depth);
                        self.packed_reader = null;
                    }
                    const u = (try self.base.next()) orelse return null;
                    if (u.field_number != field_number) continue;
                    if (u.wire_type == Codec.wire_type) {
                        return try decodeUnknownPayload(Codec, u);
                    }
                    if (comptime Codec.is_packable) {
                        if (u.wire_type == .len) {
                            self.packed_reader = Reader.init(u.bytes);
                            continue;
                        }
                    }
                    return error.WireTypeMismatch;
                }
            }
        };

        pub inline fn iterator(msg: *const Extendee) Iterator {
            return .{ .base = unknownFieldsOf(msg).iterator(Extendee._protoz_known_fields) };
        }

        pub fn encodeSlice(items: []const Value, comptime pack: bool, buf: []u8) EncodeError![]const u8 {
            const rep: Repeated(Codec) = .{ .slice = items };
            var rw = ReverseWriter.init(buf);
            try rep.encodeReverse(field_number, pack, &rw);
            return rw.written();
        }
    };
}
