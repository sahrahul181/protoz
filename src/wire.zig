const std = @import("std");

pub const max_recursion_depth: u32 = 100;

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
            if (count == 9 and b > 1) return error.VarintOverflow;
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
                if (b > 1) return error.VarintOverflow;
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
                if (b > 1) return error.VarintOverflow;
                break;
            }
            if (b < 0x80) break;
        }
    }
}

inline fn extendWindow(
    prev: []const u8,
    msg_start: [*]const u8,
    tag_ptr: [*]const u8,
    end_ptr: [*]const u8,
) []const u8 {
    const base = @intFromPtr(msg_start);
    const p = @intFromPtr(prev.ptr);
    const t = @intFromPtr(tag_ptr);
    if (p >= base and p <= t) {
        @branchHint(.likely);
        return prev.ptr[0 .. @intFromPtr(end_ptr) - p];
    }
    return tag_ptr[0 .. @intFromPtr(end_ptr) - t];
}

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
            .string, .bytes => []const u8,
        };

        pub const wire_type: WireType = switch (kind) {
            .int32, .int64, .uint32, .uint64, .sint32, .sint64, .bool_ => .varint,
            .fixed32, .sfixed32, .float_ => .i32,
            .fixed64, .sfixed64, .double_ => .i64,
            .string, .bytes => .len,
        };

        pub const is_packable: bool = (wire_type != .len);

        pub const fixed_size: ?usize = switch (wire_type) {
            .i32 => 4,
            .i64 => 8,
            else => null,
        };

        pub const default_value: T = switch (kind) {
            .bool_ => false,
            .float_, .double_ => 0.0,
            .string, .bytes => "",
            else => 0,
        };

        pub inline fn isDefault(v: T) bool {
            return switch (kind) {
                .bool_ => !v,
                .float_ => @as(u32, @bitCast(v)) == 0,
                .double_ => @as(u64, @bitCast(v)) == 0,
                .string, .bytes => v.len == 0,
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
                .string, .bytes => varintSize(v.len) + v.len,
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
                .string, .bytes => try writeBytes(w, v),
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
                .string, .bytes => try rw.writeBytes(v),
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
            };
        }

        pub inline fn validate(r: *Reader, depth: u32) DecodeError!void {
            _ = depth;
            switch (wire_type) {
                .varint => try r.skipVarint(),
                .i32 => try r.skipFixed(4),
                .i64 => try r.skipFixed(8),
                .len => _ = try r.readBytes(),
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

        pub fn validate(r: *Reader, depth: u32) DecodeError!void {
            try M.validateDepth(try r.readBytes(), depth);
        }
    };
}

// --- Zero-Allocation Containers: Lazy, Repeated, Map ---

/// Breaks recursive message cycles without heap allocation.
pub fn Lazy(comptime M: type) type {
    return union(enum) {
        raw: []const u8,
        ptr: *const M,
        wire: WireFieldView, // used only when a cyclic field appears multiple times

        pub fn decode(self: @This()) DecodeError!M {
            return switch (self) {
                .raw => |b| M.decode(b),
                .ptr => |p| p.*,
                .wire => |w| blk: {
                    var msg: M = .{};
                    var r = Reader.init(w.buf);
                    const expected_raw: u32 = (@as(u32, w.field_number) << 3) | @backingInt(WireType.len);
                    while (try r.readRawTag()) |raw_tag| {
                        if (raw_tag == expected_raw) {
                            try msg.mergeDepth(try r.readBytes(), max_recursion_depth);
                        } else {
                            const tag = try decodeTag(raw_tag);
                            try r.skipField(tag, max_recursion_depth);
                        }
                    }
                    break :blk msg;
                },
            };
        }

        pub fn encodedSize(self: @This()) usize {
            return switch (self) {
                .raw => |b| b.len,
                .ptr => |p| p.encodedSize(),
                .wire => (self.decode() catch return 0).encodedSize(),
            };
        }

        pub fn encode(self: @This(), w: anytype) WriterError(@TypeOf(w))!void {
            switch (self) {
                .raw => |b| try w.writeAll(b),
                .ptr => |p| try p.encode(w),
                .wire => {
                    const merged = self.decode() catch unreachable;
                    try merged.encode(w);
                },
            }
        }

        pub fn encodeReverse(self: @This(), rw: *ReverseWriter) EncodeError!void {
            switch (self) {
                .raw => |b| try rw.writeAll(b),
                .ptr => |p| try p.encodeReverse(rw),
                .wire => {
                    const merged = self.decode() catch unreachable;
                    try merged.encodeReverse(rw);
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

/// Zero-allocation repeated field with direct packed-slice fast path and tight wire windows.
pub fn Repeated(comptime Codec: type) type {
    return union(enum) {
        slice: []const Codec.T,
        packed_slice: PackedSlice,
        wire: WireFieldView,

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
        };

        pub inline fn iterator(self: @This()) Iterator {
            return switch (self) {
                .slice => |s| .{ .source = .{ .slice = .{ .items = s } } },
                .packed_slice => |p| .{ .source = .{ .packed_slice = Reader.init(p.data) } },
                .wire => |w| .{ .source = .{ .wire = .{
                    .reader = Reader.init(w.buf),
                    .field_number = w.field_number,
                } } },
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
            self.mergePackedSlow(msg_start, tag_ptr, payload, r.ptr, field_number);
        }

        fn mergePackedSlow(
            self: *@This(),
            msg_start: [*]const u8,
            tag_ptr: [*]const u8,
            payload: []const u8,
            end_ptr: [*]const u8,
            field_number: u29,
        ) void {
            @branchHint(.cold);
            switch (self.*) {
                .slice => unreachable,
                .packed_slice => |prev| {
                    if (prev.data.len == 0) {
                        self.* = .{ .packed_slice = .{ .data = payload, .tag_ptr = tag_ptr } };
                    } else if (payload.len == 0) {
                        // Trailing empty packed chunk adds no elements.
                    } else {
                        const base = @intFromPtr(msg_start);
                        const p = @intFromPtr(prev.tag_ptr);
                        const t = @intFromPtr(tag_ptr);
                        if (p >= base and p <= t) {
                            self.* = .{ .wire = .{
                                .buf = prev.tag_ptr[0 .. @intFromPtr(end_ptr) - p],
                                .field_number = field_number,
                            } };
                        } else {
                            self.* = .{ .packed_slice = .{ .data = payload, .tag_ptr = tag_ptr } };
                        }
                    }
                },
                .wire => |*prev| {
                    prev.buf = extendWindow(prev.buf, msg_start, tag_ptr, end_ptr);
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
            switch (self.*) {
                .slice => {
                    self.* = .{ .wire = .{
                        .buf = tag_ptr[0 .. @intFromPtr(r.ptr) - @intFromPtr(tag_ptr)],
                        .field_number = field_number,
                    } };
                },
                .wire => |*prev| {
                    prev.buf = extendWindow(prev.buf, msg_start, tag_ptr, r.ptr);
                },
                .packed_slice => |prev| {
                    self.mergeUnpackedAfterPacked(msg_start, prev, tag_ptr, r.ptr, field_number);
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
        ) void {
            @branchHint(.cold);
            if (prev.data.len == 0) {
                self.* = .{ .wire = .{
                    .buf = tag_ptr[0 .. @intFromPtr(end_ptr) - @intFromPtr(tag_ptr)],
                    .field_number = field_number,
                } };
                return;
            }
            const base = @intFromPtr(msg_start);
            const p = @intFromPtr(prev.tag_ptr);
            const t = @intFromPtr(tag_ptr);
            if (p >= base and p <= t) {
                self.* = .{ .wire = .{
                    .buf = prev.tag_ptr[0 .. @intFromPtr(end_ptr) - p],
                    .field_number = field_number,
                } };
            } else {
                self.* = .{ .wire = .{
                    .buf = tag_ptr[0 .. @intFromPtr(end_ptr) - t],
                    .field_number = field_number,
                } };
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
                .wire => {
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
                .wire => {
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
                .wire => {
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

/// Zero-allocation map field backed by tight [first..last] wire windows.
pub fn Map(comptime KCodec: type, comptime VCodec: type) type {
    @setEvalBranchQuota(100_000);
    return union(enum) {
        slice: []const Entry,
        wire: WireFieldView,

        pub const Entry = struct {
            key: KCodec.T,
            value: VCodec.T,
        };

        pub const empty: @This() = .{ .slice = &.{} };

        fn decodeEntry(bytes: []const u8, depth: u32) DecodeError!Entry {
            if (depth == 0) return error.RecursionLimitExceeded;
            var entry: Entry = .{
                .key = KCodec.default_value,
                .value = VCodec.default_value,
            };
            var r = Reader.init(bytes);
            const key_tag = comptime rawTag(1, KCodec.wire_type);
            const val_tag = comptime rawTag(2, VCodec.wire_type);
            while (try r.readRawTag()) |raw_tag| {
                if (raw_tag == key_tag) {
                    entry.key = try KCodec.read(&r, depth - 1);
                } else if (raw_tag == val_tag) {
                    entry.value = try VCodec.read(&r, depth - 1);
                } else {
                    const tag = try decodeTag(raw_tag);
                    if (tag.field_number == 1 or tag.field_number == 2) return error.WireTypeMismatch;
                    try r.skipField(tag, depth - 1);
                }
            }
            return entry;
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

            switch (self.*) {
                .slice => {
                    self.* = .{ .wire = .{
                        .buf = tag_ptr[0 .. @intFromPtr(r.ptr) - @intFromPtr(tag_ptr)],
                        .field_number = field_number,
                    } };
                },
                .wire => |*prev| {
                    prev.buf = extendWindow(prev.buf, msg_start, tag_ptr, r.ptr);
                },
            }
        }

        pub const Iterator = struct {
            source: union(enum) {
                slice: struct { items: []const Entry, idx: usize = 0 },
                wire: struct { reader: Reader, field_number: u29 },
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
            };
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
                    var r = Reader.init(w.buf);
                    const expected_raw: u32 = (@as(u32, w.field_number) << 3) | @backingInt(WireType.len);
                    const key_tag = comptime rawTag(1, KCodec.wire_type);
                    const val_tag = comptime rawTag(2, VCodec.wire_type);
                    while (try r.readRawTag()) |raw_tag| {
                        if (raw_tag != expected_raw) {
                            const tag = try decodeTag(raw_tag);
                            if (tag.field_number == w.field_number) return error.WireTypeMismatch;
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
                                    if (keysEqual(KCodec.T, full.key, key)) found = full.value;
                                    key_matches = false;
                                    break;
                                }
                            } else if (eraw == val_tag) {
                                if (has_key and !key_matches) {
                                    try VCodec.validate(&er, max_recursion_depth - 1);
                                    skipped_val = true;
                                } else {
                                    v = try VCodec.read(&er, max_recursion_depth - 1);
                                }
                            } else {
                                const etag = try decodeTag(eraw);
                                if (etag.field_number == 1 or etag.field_number == 2) return error.WireTypeMismatch;
                                try er.skipField(etag, max_recursion_depth - 1);
                            }
                        }
                        if (!has_key) key_matches = keysEqual(KCodec.T, k, key);
                        if (key_matches) found = v;
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
                .wire => {
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
                .wire => {
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
                .wire => {
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
