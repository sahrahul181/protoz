const std = @import("std");
const builtin = @import("builtin");
const wire = @import("proto_wire");
const pb = @import("bench_pb");

const num_samples: usize = 9;

const BenchResult = struct {
    name: []const u8,
    payload_bytes: usize,
    median_ns: f64,
    min_ns: f64,
    mops_s: f64,
    mb_s: f64,
};

// Pointer/usize-sized volatile barriers prevent LLVM from constant-folding struct literals,
// hoisting loads out of benchmark loops, or eliminating stores to the output buffer.
inline fn blackBoxPtr(comptime T: type, p: *const T) *const T {
    var slot: *const T = p;
    const v: *volatile *const T = &slot;
    return v.*;
}

inline fn blackBoxSlice(s: []const u8) []const u8 {
    var p: [*]const u8 = s.ptr;
    var n: usize = s.len;
    const vp: *volatile [*]const u8 = &p;
    const vn: *volatile usize = &n;
    return vp.*[0..vn.*];
}

inline fn blackBoxMutSlice(s: []u8) []u8 {
    var p: [*]u8 = s.ptr;
    var n: usize = s.len;
    const vp: *volatile [*]u8 = &p;
    const vn: *volatile usize = &n;
    return vp.*[0..vn.*];
}

fn runBench(
    io: std.Io,
    name: []const u8,
    payload_bytes: usize,
    iters: usize,
    ctx: anytype,
    comptime func: fn (@TypeOf(ctx)) void,
) BenchResult {
    const warmup = @max(iters / 10, 1_000);
    for (0..warmup) |_| func(ctx);

    var samples: [num_samples]u64 = undefined;
    for (&samples) |*slot| {
        const start = std.Io.Timestamp.now(io, .awake);
        for (0..iters) |_| func(ctx);
        const end = std.Io.Timestamp.now(io, .awake);
        const raw_ns = start.durationTo(end).toNanoseconds();
        slot.* = if (raw_ns > 0) @intCast(raw_ns) else 1;
    }

    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    const iters_f: f64 = @floatFromInt(iters);
    const min_ns = @as(f64, @floatFromInt(samples[0])) / iters_f;
    const med_ns = @as(f64, @floatFromInt(samples[num_samples / 2])) / iters_f;
    const mops = 1_000.0 / med_ns;
    const mb_s = (@as(f64, @floatFromInt(payload_bytes)) * 1_000.0) / med_ns;

    return .{
        .name = name,
        .payload_bytes = payload_bytes,
        .median_ns = med_ns,
        .min_ns = min_ns,
        .mops_s = mops,
        .mb_s = mb_s,
    };
}

fn Ctx(comptime M: type) type {
    return struct {
        msg: *const M,
        encoded: []const u8,
        scratch: []u8,
    };
}

fn verifyTier(comptime M: type, msg: *const M, encoded: []const u8) !void {
    if (msg.encodedSize() != encoded.len) return error.EncodedSizeMismatch;
    try M.validateDepth(encoded, wire.max_recursion_depth);
    const decoded = try M.decode(encoded);
    if (decoded.encodedSize() != encoded.len) return error.DecodedSizeMismatch;
}

fn benchEncodedSize(comptime M: type) fn (Ctx(M)) void {
    return struct {
        fn run(ctx: Ctx(M)) void {
            const msg = blackBoxPtr(M, ctx.msg);
            std.mem.doNotOptimizeAway(msg.encodedSize());
        }
    }.run;
}

fn benchEncodeSlice(comptime M: type) fn (Ctx(M)) void {
    return struct {
        fn run(ctx: Ctx(M)) void {
            const msg = blackBoxPtr(M, ctx.msg);
            const scratch = blackBoxMutSlice(ctx.scratch);
            const out = msg.encodeSlice(scratch) catch unreachable;
            std.mem.doNotOptimizeAway(out);
        }
    }.run;
}

fn benchEncodeForward(comptime M: type) fn (Ctx(M)) void {
    return struct {
        fn run(ctx: Ctx(M)) void {
            const msg = blackBoxPtr(M, ctx.msg);
            const scratch = blackBoxMutSlice(ctx.scratch);
            var sw = wire.SliceWriter.init(scratch);
            msg.encode(&sw) catch unreachable;
            std.mem.doNotOptimizeAway(sw.written());
        }
    }.run;
}

fn benchValidate(comptime M: type) fn (Ctx(M)) void {
    return struct {
        fn run(ctx: Ctx(M)) void {
            const bytes = blackBoxSlice(ctx.encoded);
            M.validateDepth(bytes, wire.max_recursion_depth) catch unreachable;
        }
    }.run;
}

fn benchDecode(comptime M: type) fn (Ctx(M)) void {
    return struct {
        fn run(ctx: Ctx(M)) void {
            const bytes = blackBoxSlice(ctx.encoded);
            const decoded = M.decode(bytes) catch unreachable;
            std.mem.doNotOptimizeAway(decoded);
        }
    }.run;
}

fn benchUserTraverse(ctx: Ctx(pb.UserProfile)) void {
    const bytes = blackBoxSlice(ctx.encoded);
    const d = pb.UserProfile.decode(bytes) catch unreachable;
    var acc: u64 = d.id +% d.name.len +% @as(u64, @intCast(@backingInt(d.role)));
    if (d.address) |a| acc +%= a.zip +% a.city.len;
    if (d.contact) |c| switch (c) {
        .email => |s| acc +%= s.len,
        .phone => |s| acc +%= s.len,
    };

    var scores_it = d.scores.iterator();
    while (scores_it.next() catch unreachable) |s| acc +%= s;

    var tags_it = d.tags.iterator();
    while (tags_it.next() catch unreachable) |t| acc +%= t.len;

    if (d.quotas.get("ram") catch unreachable) |ram| acc +%= @bitCast(@as(i64, ram));

    if (d.manager) |mgr| {
        const sub = mgr.decode() catch unreachable;
        acc +%= sub.id;
    }
    std.mem.doNotOptimizeAway(acc);
}

fn benchBatchTraverse(ctx: Ctx(pb.TelemetryBatch)) void {
    const bytes = blackBoxSlice(ctx.encoded);
    const d = pb.TelemetryBatch.decode(bytes) catch unreachable;
    var acc: u64 = d.host.len;

    var dit = d.deltas.iterator();
    while (dit.next() catch unreachable) |v| acc +%= @bitCast(v);

    var hit = d.hashes.iterator();
    while (hit.next() catch unreachable) |h| acc +%= h;

    var pit = d.points.iterator();
    while (pit.next() catch unreachable) |pt| acc +%= pt.ts +% pt.label.len;

    std.mem.doNotOptimizeAway(acc);
}

fn matchesFilter(filter: ?[]const u8, label: []const u8) bool {
    const f = filter orelse return true;
    return std.mem.indexOf(u8, label, f) != null;
}

fn printRow(w: *std.Io.Writer, r: BenchResult) !void {
    try w.print("{s:<36} {d:>6} B {d:>11.2} {d:>10.2} {d:>9.2} {d:>10.1}\n", .{
        r.name,
        r.payload_bytes,
        r.median_ns,
        r.min_ns,
        r.mops_s,
        r.mb_s,
    });
}

fn runSuite(
    comptime M: type,
    io: std.Io,
    w: *std.Io.Writer,
    filter: ?[]const u8,
    prefix: []const u8,
    iters: usize,
    ctx: Ctx(M),
    comptime traverse_fn: ?fn (Ctx(M)) void,
) !void {
    const ops = .{
        .{ "encodedSize", benchEncodedSize(M) },
        .{ "encodeSlice (reverse)", benchEncodeSlice(M) },
        .{ "encode (forward)", benchEncodeForward(M) },
        .{ "validateDepth", benchValidate(M) },
        .{ "decode (validate + views)", benchDecode(M) },
    };

    var name_buf: [64]u8 = undefined;
    inline for (ops) |entry| {
        const full_name = std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ prefix, entry[0] }) catch unreachable;
        if (matchesFilter(filter, full_name)) {
            const res = runBench(io, full_name, ctx.encoded.len, iters, ctx, entry[1]);
            try printRow(w, res);
        }
    }

    if (traverse_fn) |tf| {
        const full_name = std.fmt.bufPrint(&name_buf, "{s}/decode + full traversal", .{prefix}) catch unreachable;
        if (matchesFilter(filter, full_name)) {
            const res = runBench(io, full_name, ctx.encoded.len, iters, ctx, tf);
            try printRow(w, res);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var filter: ?[]const u8 = null;
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--filter")) {
            filter = args.next();
        }
    }

    var out_buf: [8192]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const w = &stdout_w.interface;

    try w.print("protoz Zero-Allocation Benchmark (mode={s}, samples={d})\n", .{
        @tagName(builtin.mode),
        num_samples,
    });
    try w.writeAll("==========================================================================================\n");
    try w.writeAll("Benchmark                              Size  Median(ns)    Min(ns)    Mops/s       MB/s\n");
    try w.writeAll("------------------------------------------------------------------------------------------\n");

    // --- Tier 1: SmallEvent ---
    {
        const small = pb.SmallEvent{
            .id = 1_048_576,
            .timestamp_ns = 1_764_075_000_123_456_789,
            .status = 200,
            .source = "edge-gw-01",
        };
        var wire_buf: [128]u8 = undefined;
        var scratch: [128]u8 = undefined;
        const encoded = try small.encodeSlice(&wire_buf);
        try verifyTier(pb.SmallEvent, &small, encoded);

        try runSuite(pb.SmallEvent, init.io, w, filter, "Small", 2_000_000, .{
            .msg = &small,
            .encoded = encoded,
            .scratch = &scratch,
        }, null);
    }

    // --- Tier 2: UserProfile ---
    {
        const manager = pb.UserProfile{
            .id = 1,
            .name = "cto-principal",
            .role = .ROLE_ADMIN,
        };
        const user = pb.UserProfile{
            .id = 9_876_543_210,
            .name = "alice-engineer",
            .role = .ROLE_MEMBER,
            .scores = .{ .slice = &.{ 10, 250, 4096, 65535, 1_000_000, 42, 7, 999 } },
            .tags = .{ .slice = &.{ "zig", "protobuf", "zero-alloc", "systems" } },
            .quotas = .{ .slice = &.{
                .{ .key = "cpu", .value = 16 },
                .{ .key = "ram", .value = 64 },
                .{ .key = "disk", .value = 2048 },
            } },
            .address = .{ .city = "Gurugram", .zip = 122001 },
            .verified = true,
            .contact = .{ .email = "alice@acme.dev" },
            .manager = .{ .ptr = &manager },
        };
        var wire_buf: [512]u8 = undefined;
        var scratch: [512]u8 = undefined;
        const encoded = try user.encodeSlice(&wire_buf);
        try verifyTier(pb.UserProfile, &user, encoded);

        try w.writeAll("------------------------------------------------------------------------------------------\n");
        try runSuite(pb.UserProfile, init.io, w, filter, "User", 500_000, .{
            .msg = &user,
            .encoded = encoded,
            .scratch = &scratch,
        }, benchUserTraverse);
    }

    // --- Tier 3: TelemetryBatch ---
    {
        var deltas: [128]i64 = undefined;
        var hashes: [128]u64 = undefined;
        var points: [64]pb.TelemetryBatch.Point = undefined;
        for (&deltas, 0..) |*d, i| {
            const signed: i64 = @intCast(i);
            d.* = if (i % 2 == 0) signed * 17 else -signed * 31;
        }
        for (&hashes, 0..) |*h, i| {
            h.* = 0x9E37_79B9_7F4A_7C15 *% (@as(u64, i) + 1);
        }
        for (&points, 0..) |*pt, i| {
            pt.* = .{
                .ts = 1_764_075_000 + i,
                .value = @as(f64, @floatFromInt(i)) * 0.25,
                .label = "cpu.util",
            };
        }

        const batch = pb.TelemetryBatch{
            .host = "prod-in-north-07",
            .deltas = .{ .slice = &deltas },
            .hashes = .{ .slice = &hashes },
            .points = .{ .slice = &points },
        };
        var wire_buf: [8192]u8 = undefined;
        var scratch: [8192]u8 = undefined;
        const encoded = try batch.encodeSlice(&wire_buf);
        try verifyTier(pb.TelemetryBatch, &batch, encoded);

        try w.writeAll("------------------------------------------------------------------------------------------\n");
        try runSuite(pb.TelemetryBatch, init.io, w, filter, "Batch", 50_000, .{
            .msg = &batch,
            .encoded = encoded,
            .scratch = &scratch,
        }, benchBatchTraverse);
    }

    try w.writeAll("==========================================================================================\n");
    try w.flush();
}
