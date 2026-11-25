const std = @import("std");
const wire = @import("wire.zig");

/// 1-byte compression flag + 4-byte big-endian message length (gRPC over HTTP/2 spec).
pub const header_size: usize = 5;

pub const StreamKind = enum {
    unary,
    client_streaming,
    server_streaming,
    bidi_streaming,
};

pub const MethodInfo = struct {
    name: []const u8,
    zig_name: []const u8,
    path: []const u8,
    stream_kind: StreamKind,
};

/// Canonical gRPC status codes (0..16).
pub const StatusCode = enum(u8) {
    ok = 0,
    cancelled = 1,
    unknown = 2,
    invalid_argument = 3,
    deadline_exceeded = 4,
    not_found = 5,
    already_exists = 6,
    permission_denied = 7,
    resource_exhausted = 8,
    failed_precondition = 9,
    aborted = 10,
    out_of_range = 11,
    unimplemented = 12,
    internal = 13,
    unavailable = 14,
    data_loss = 15,
    unauthenticated = 16,
};

pub const FrameError = wire.DecodeError || error{
    InvalidCompressionFlag,
    CompressedFrameUnsupported,
    FrameTooLarge,
};

pub const RawGrpcFrame = struct {
    compressed: bool,
    payload: []const u8,
    consumed: usize,
    rest: []const u8,
};

pub fn GrpcFrame(comptime M: type) type {
    return struct {
        msg: M,
        consumed: usize,
        rest: []const u8,
    };
}

/// Exact byte length of a 5-byte gRPC Length-Prefixed-Message frame.
pub inline fn encodedGrpcSize(msg: anytype) usize {
    return header_size + msg.encodedSize();
}

/// Single-pass reverse serialization of an uncompressed gRPC frame into `buf`.
pub fn encodeGrpcSlice(msg: anytype, buf: []u8) wire.EncodeError![]const u8 {
    var rw = wire.ReverseWriter.init(buf);
    const end = rw.pos;
    try msg.encodeReverse(&rw);
    const body_len = end - rw.pos;
    const body_u32 = std.math.cast(u32, body_len) orelse return error.BufferTooSmall;
    var hdr: [header_size]u8 = undefined;
    hdr[0] = 0; // uncompressed
    std.mem.writeInt(u32, hdr[1..5], body_u32, .big);
    try rw.writeAll(&hdr);
    return rw.written();
}

/// Forward-streaming serialization of an uncompressed gRPC frame to any writer.
pub fn encodeGrpc(msg: anytype, w: anytype) (wire.WriterError(@TypeOf(w)) || error{MessageTooLarge})!void {
    const body_len = msg.encodedSize();
    const body_u32 = std.math.cast(u32, body_len) orelse return error.MessageTooLarge;
    var hdr: [header_size]u8 = undefined;
    hdr[0] = 0;
    std.mem.writeInt(u32, hdr[1..5], body_u32, .big);
    try w.writeAll(&hdr);
    try msg.encode(w);
}

/// Streaming-safe raw gRPC frame parser for partial HTTP/2 DATA buffers.
/// - Returns `null` when fewer than 5 header bytes or fewer than `len` body bytes are available.
/// - Returns `error.FrameTooLarge` immediately on reading the 5-byte header if `len > max_frame_bytes`.
pub fn tryDecodeGrpcRaw(buf: []const u8, max_frame_bytes: usize) FrameError!?RawGrpcFrame {
    if (buf.len < header_size) return null;
    const flag = buf[0];
    if (flag != 0 and flag != 1) return error.InvalidCompressionFlag;

    const frame_len: usize = std.mem.readInt(u32, buf[1..5], .big);
    if (frame_len > max_frame_bytes) return error.FrameTooLarge;
    if (buf.len - header_size < frame_len) return null;

    const consumed = header_size + frame_len;
    return .{
        .compressed = (flag == 1),
        .payload = buf[header_size..consumed],
        .consumed = consumed,
        .rest = buf[consumed..],
    };
}

/// Streaming-safe typed gRPC frame decoder (zero-allocation for uncompressed frames).
/// Callers supporting gzip/zstd should use `tryDecodeGrpcRaw`, decompress `payload`, and call `M.decode`.
pub fn tryDecodeGrpc(comptime M: type, buf: []const u8, max_frame_bytes: usize) FrameError!?GrpcFrame(M) {
    const raw = (try tryDecodeGrpcRaw(buf, max_frame_bytes)) orelse return null;
    if (raw.compressed) return error.CompressedFrameUnsupported;
    return .{
        .msg = try M.decode(raw.payload),
        .consumed = raw.consumed,
        .rest = raw.rest,
    };
}

/// Zero-allocation iterator over consecutive gRPC frames in a buffer (e.g., server/bidi stream).
pub fn GrpcFrameIterator(comptime M: type) type {
    return struct {
        rest: []const u8,
        max_frame_bytes: usize,

        pub inline fn init(buf: []const u8, max_frame_bytes: usize) @This() {
            return .{ .rest = buf, .max_frame_bytes = max_frame_bytes };
        }

        pub fn next(self: *@This()) FrameError!?M {
            if (self.rest.len == 0) return null;
            const frame = (try tryDecodeGrpc(M, self.rest, self.max_frame_bytes)) orelse return error.UnexpectedEof;
            self.rest = frame.rest;
            return frame.msg;
        }
    };
}

/// Helper used by generated `Service.matchPath` so `.pb.zig` files don't need `@import("std")`.
pub inline fn eqlPath(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn DerefType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

inline fn invokeUnaryHandler(
    comptime H: type,
    comptime Method: type,
    handler: anytype,
    req: Method.Request,
) !Method.Response {
    const fn_name = comptime if (@hasDecl(H, Method.zig_name))
        Method.zig_name
    else if (@hasDecl(H, Method.name))
        Method.name
    else
        @compileError("RPC handler " ++ @typeName(H) ++ " must declare `pub fn " ++ Method.zig_name ++ "` or `" ++ Method.name ++ "`");

    const res = @field(H, fn_name)(handler, req);
    if (comptime @typeInfo(@TypeOf(res)) == .error_union) {
        return try res;
    }
    return res;
}

/// Zero-allocation comptime unary RPC dispatcher for raw Protobuf payloads.
/// Matches `path` (e.g. `"/acme.v1.Greeter/SayHello"`), decodes `Request`, invokes
/// `handler.<camelCase>` (or `handler.<PascalCase>`), and encodes `Response` into `resp_buf`.
pub fn dispatchUnary(
    comptime Service: type,
    handler: anytype,
    path: []const u8,
    req_bytes: []const u8,
    resp_buf: []u8,
) ![]const u8 {
    const H = DerefType(@TypeOf(handler));
    inline for (Service.methods) |Method| {
        if (comptime Method.stream_kind == .unary) {
            if (eqlPath(path, Method.path)) {
                const req = try Method.Request.decode(req_bytes);
                const resp = try invokeUnaryHandler(H, Method, handler, req);
                return try resp.encodeSlice(resp_buf);
            }
        }
    }
    return error.Unimplemented;
}

/// Zero-allocation comptime unary RPC dispatcher for 5-byte gRPC Length-Prefixed frames.
pub fn dispatchUnaryGrpc(
    comptime Service: type,
    handler: anytype,
    path: []const u8,
    req_frame_bytes: []const u8,
    max_frame_bytes: usize,
    resp_buf: []u8,
) ![]const u8 {
    const H = DerefType(@TypeOf(handler));
    inline for (Service.methods) |Method| {
        if (comptime Method.stream_kind == .unary) {
            if (eqlPath(path, Method.path)) {
                const frame = (try tryDecodeGrpc(Method.Request, req_frame_bytes, max_frame_bytes)) orelse return error.UnexpectedEof;
                const resp = try invokeUnaryHandler(H, Method, handler, frame.msg);
                return try encodeGrpcSlice(resp, resp_buf);
            }
        }
    }
    return error.Unimplemented;
}
