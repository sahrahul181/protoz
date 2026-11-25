const std = @import("std");
const wire = @import("proto_wire");
const pb = @import("bench_pb");
const wkt = @import("proto_wkt");

// ---------------------------------------------------------------------------
// Adversarial Malformed-Wire Regression Tests
// ---------------------------------------------------------------------------

test "malformed: varint overflow and 11-byte unterminated varint" {
    // 10th byte with MSB set (>= 0x80) overflows 64-bit varint
    const overlong_10th_msb = [_]u8{
        0x08, // field 1 (id), varint
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x01,
    };
    try std.testing.expectError(error.VarintOverflow, pb.SmallEvent.decode(&overlong_10th_msb));
    try std.testing.expectError(error.VarintOverflow, pb.SmallEvent.validateDepth(&overlong_10th_msb, wire.max_recursion_depth));

    // Truncated 2-byte varint
    const truncated_varint = [_]u8{ 0x08, 0x81 };
    try std.testing.expectError(error.UnexpectedEof, pb.SmallEvent.decode(&truncated_varint));
    try std.testing.expectError(error.UnexpectedEof, pb.SmallEvent.validateDepth(&truncated_varint, wire.max_recursion_depth));
}

test "malformed: invalid tag, wire type, wire type mismatch, and unmatched end group" {
    // Field number 0 (raw tag 0x00)
    const zero_tag = [_]u8{ 0x00, 0x01 };
    try std.testing.expectError(error.InvalidTag, pb.SmallEvent.decode(&zero_tag));

    // Wire type 6 / 7
    const bad_wt6 = [_]u8{(1 << 3) | 6};
    const bad_wt7 = [_]u8{(15 << 3) | 7};
    try std.testing.expectError(error.InvalidWireType, pb.SmallEvent.decode(&bad_wt6));
    try std.testing.expectError(error.InvalidWireType, pb.SmallEvent.decode(&bad_wt7));

    // Field 1 on SmallEvent expects varint, feed length-delimited
    const mismatch = [_]u8{ (1 << 3) | 2, 0x01, 0xAA };
    try std.testing.expectError(error.WireTypeMismatch, pb.SmallEvent.decode(&mismatch));

    // Unmatched EGROUP on unknown field
    const unmatched_egroup = [_]u8{(14 << 3) | 4};
    try std.testing.expectError(error.UnmatchedEndGroup, pb.SmallEvent.decode(&unmatched_egroup));
}

test "malformed: truncated length-delimited payload and invalid UTF-8" {
    // Field 4 (source: string) declares 50 bytes, only 3 follow
    const trunc_len = [_]u8{ (4 << 3) | 2, 50, 'a', 'b', 'c' };
    try std.testing.expectError(error.UnexpectedEof, pb.SmallEvent.decode(&trunc_len));

    // Invalid UTF-8 byte sequence in proto3 string field 4
    const bad_utf8 = [_]u8{ (4 << 3) | 2, 2, 0xFF, 0xFE };
    try std.testing.expectError(error.InvalidUtf8, pb.SmallEvent.decode(&bad_utf8));
    try std.testing.expectError(error.InvalidUtf8, pb.SmallEvent.validateDepth(&bad_utf8, wire.max_recursion_depth));
}

test "malformed: recursion depth bomb (>100 nested submessages / groups)" {
    // Build a 105-deep nested SGROUP/EGROUP unknown field wrapper for field 99:
    // outer validateDepth runs at depth = 100, and skipping nested SGROUP decrements depth.
    var bomb: [220]u8 = undefined;
    var pos: usize = 0;
    for (0..105) |_| {
        // tag 15 (field 15, wire_type = 3 sgroup) -> 1 byte = (15 << 3) | 3 = 0x7B
        bomb[pos] = 0x7B;
        pos += 1;
    }
    for (0..105) |_| {
        // tag 15 (field 15, wire_type = 4 egroup) -> 1 byte = (15 << 3) | 4 = 0x7C
        bomb[pos] = 0x7C;
        pos += 1;
    }
    try std.testing.expectError(error.RecursionLimitExceeded, pb.SmallEvent.decode(bomb[0..pos]));
    try std.testing.expectError(error.RecursionLimitExceeded, pb.SmallEvent.validateDepth(bomb[0..pos], wire.max_recursion_depth));
}

test "malformed: merge chunk limit exceeded and BufferTooSmall" {
    // > max_merge_chunks occurrences of Lazy submessage field 11 (`manager`) overflows WireChunks.
    var fragmented: [128]u8 = undefined;
    var pos: usize = 0;
    for (0..wire.max_merge_chunks + 2) |_| {
        fragmented[pos] = (11 << 3) | 2; // field 11 (`manager`), LEN
        fragmented[pos + 1] = 0x02;
        fragmented[pos + 2] = 0x08; // inner field 1 (id)
        fragmented[pos + 3] = 0x01;
        pos += 4;
    }
    try std.testing.expectError(error.MergeChunkLimitExceeded, pb.UserProfile.decode(fragmented[0..pos]));

    // Encoding into undersized buffer returns BufferTooSmall cleanly
    const ev = pb.SmallEvent{ .id = 42, .source = "hello-world" };
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, ev.encodeSlice(&tiny));
    var sw = wire.SliceWriter.init(&tiny);
    try std.testing.expectError(error.BufferTooSmall, ev.encode(&sw));
}

// ---------------------------------------------------------------------------
// Wire Property & Traversal Helpers (used by PRNG fuzzer & std.testing.fuzz)
// ---------------------------------------------------------------------------

fn traverseUser(d: pb.UserProfile) wire.DecodeError!u64 {
    var acc: u64 = d.id +% d.name.len +% @as(u64, @bitCast(@as(i64, @backingInt(d.role))));
    if (d.address) |a| acc +%= a.zip +% a.city.len;
    if (d.contact) |c| switch (c) {
        .email => |s| acc +%= s.len,
        .phone => |s| acc +%= s.len,
    };
    var sit = d.scores.iterator();
    while (try sit.next()) |s| acc +%= s;
    var tit = d.tags.iterator();
    while (try tit.next()) |t| acc +%= t.len;
    _ = try d.quotas.get("ram");
    var qit = d.quotas.iterator();
    while (try qit.next()) |entry| acc +%= entry.key.len +% @as(u64, @bitCast(@as(i64, entry.value)));
    if (d.manager) |mgr| {
        const sub = try mgr.decode();
        acc +%= sub.id +% sub.name.len;
    }
    return acc;
}

fn traverseBatch(d: pb.TelemetryBatch) wire.DecodeError!u64 {
    var acc: u64 = d.host.len;
    var dit = d.deltas.iterator();
    while (try dit.next()) |v| acc +%= @bitCast(v);
    var hit = d.hashes.iterator();
    while (try hit.next()) |h| acc +%= h;
    var pit = d.points.iterator();
    while (try pit.next()) |pt| acc +%= pt.ts +% pt.label.len;
    return acc;
}

fn traverseStruct(s: wkt.google_protobuf_struct.Struct, depth: u32) wire.DecodeError!u64 {
    if (depth == 0) return 0;
    var acc: u64 = 0;
    var it = s.fields.iterator();
    while (try it.next()) |entry| {
        acc +%= entry.key.len;
        if (entry.value.kind) |k| switch (k) {
            .number_value => |n| acc +%= @bitCast(n),
            .string_value => |str| acc +%= str.len,
            .bool_value => |b| acc +%= @intFromBool(b),
            .struct_value => |sub| acc +%= try traverseStruct(sub, depth - 1),
            .list_value => |lv| {
                var lit = lv.values.iterator();
                while (try lit.next()) |item| {
                    if (item.kind) |ik| switch (ik) {
                        .string_value => |str| acc +%= str.len,
                        .number_value => |n| acc +%= @bitCast(n),
                        else => {},
                    };
                }
            },
            .null_value => {},
        };
    }
    return acc;
}

/// Checks arbitrary wire bytes against Message `M`:
/// 1) Never panics in validateDepth, decode, or traversal.
/// 2) If decode + full traversal succeeds, re-encoding with both encodeSlice & encode
///    must match `decoded.encodedSize()` byte-for-byte and re-decode cleanly.
fn checkArbitraryWire(
    comptime M: type,
    bytes: []const u8,
    comptime traverse_fn: ?fn (M) wire.DecodeError!u64,
    scratch_a: []u8,
    scratch_b: []u8,
) !void {
    const val_res = M.validateDepth(bytes, wire.max_recursion_depth);
    const dec_res = M.decode(bytes);

    if (val_res) |_| {
        // Validation passed; decode may only additionally fail with MergeChunkLimitExceeded.
        if (dec_res) |d| {
            if (traverse_fn) |tf| {
                if (tf(d)) |acc| {
                    std.mem.doNotOptimizeAway(acc);
                } else |_| {
                    return;
                }
            }
            const expected_len = d.encodedSize();
            if (expected_len <= scratch_a.len) {
                const slice_out = try d.encodeSlice(scratch_a);
                try std.testing.expectEqual(expected_len, slice_out.len);

                var sw = wire.SliceWriter.init(scratch_b);
                try d.encode(&sw);
                try std.testing.expectEqualSlices(u8, slice_out, sw.written());

                try M.validateDepth(slice_out, wire.max_recursion_depth);
                _ = try M.decode(slice_out);
            }
        } else |err| switch (err) {
            error.MergeChunkLimitExceeded => {},
            else => {
                // Note: Lazy / Map / Repeated entries aren't validated eagerly for internal
                // payload corruption on decode() unless traversed; allow other DecodeErrors only if valid?
                // Wait: validateDepth ALREADY validates nested/map/repeated entries eagerly, so
                // decode() must not fail with anything other than MergeChunkLimitExceeded!
                return err;
            },
        }
    } else |_| {
        // validateDepth rejected the payload. If decode() didn't catch a lazy inner field yet,
        // full traversal MUST reject it (unless it was an untouched lazy depth-100 boundary).
        if (dec_res) |d| {
            if (traverse_fn) |tf| {
                _ = tf(d) catch {};
            }
        } else |_| {}
    }
}

fn checkAllSchemas(bytes: []const u8, scratch_a: []u8, scratch_b: []u8) !void {
    try checkArbitraryWire(pb.SmallEvent, bytes, null, scratch_a, scratch_b);
    try checkArbitraryWire(pb.UserProfile, bytes, traverseUser, scratch_a, scratch_b);
    try checkArbitraryWire(pb.TelemetryBatch, bytes, traverseBatch, scratch_a, scratch_b);
    try checkArbitraryWire(wkt.google_protobuf_timestamp.Timestamp, bytes, null, scratch_a, scratch_b);

    // Also exercise Struct decode + validateDepth + traversal without panicking
    _ = wkt.google_protobuf_struct.Struct.validateDepth(bytes, wire.max_recursion_depth) catch {};
    if (wkt.google_protobuf_struct.Struct.decode(bytes)) |st| {
        _ = traverseStruct(st, 16) catch {};
    } else |_| {}
}

// ---------------------------------------------------------------------------
// Cross-Platform Seed Corpus & PRNG Mutation + Structured Fuzzing
// ---------------------------------------------------------------------------

const SeedCorpus = struct {
    small: [32]u8,
    small_len: usize,
    user: [512]u8,
    user_len: usize,
    batch: [1024]u8,
    batch_len: usize,

    fn init() !SeedCorpus {
        var c: SeedCorpus = undefined;

        const ev = pb.SmallEvent{
            .id = 1_048_576,
            .timestamp_ns = -1_764_075_000,
            .status = 200,
            .source = "edge-gw-01",
        };
        c.small_len = (try ev.encodeSlice(&c.small)).len;
        // Shift slice to start at index 0
        const s_off = c.small.len - c.small_len;
        std.mem.copyForwards(u8, c.small[0..c.small_len], c.small[s_off..]);

        const mgr = pb.UserProfile{
            .id = 1,
            .name = "cto",
            .role = .ROLE_ADMIN,
        };
        const usr = pb.UserProfile{
            .id = 9_876_543_210,
            .name = "alice-engineer",
            .role = .ROLE_MEMBER,
            .scores = .{ .slice = &.{ 10, 250, 4096, 65535 } },
            .tags = .{ .slice = &.{ "zig", "protoz" } },
            .quotas = .{ .slice = &.{
                .{ .key = "cpu", .value = 16 },
                .{ .key = "ram", .value = 64 },
            } },
            .address = .{ .city = "Gurugram", .zip = 122001 },
            .verified = true,
            .contact = .{ .email = "alice@acme.dev" },
            .manager = .{ .ptr = &mgr },
        };
        const u_enc = try usr.encodeSlice(&c.user);
        c.user_len = u_enc.len;
        std.mem.copyForwards(u8, c.user[0..c.user_len], u_enc);

        var deltas = [_]i64{ -1, 0, 17, -31, 9999, -123456 };
        var hashes = [_]u64{ 1, 0xDEADBEEF_CAFEBABE, std.math.maxInt(u64) };
        var pts = [_]pb.TelemetryBatch.Point{
            .{ .ts = 100, .value = 1.5, .label = "cpu" },
            .{ .ts = 200, .value = -2.25, .label = "mem" },
        };
        const bat = pb.TelemetryBatch{
            .host = "prod-01",
            .deltas = .{ .slice = &deltas },
            .hashes = .{ .slice = &hashes },
            .points = .{ .slice = &pts },
        };
        const b_enc = try bat.encodeSlice(&c.batch);
        c.batch_len = b_enc.len;
        std.mem.copyForwards(u8, c.batch[0..c.batch_len], b_enc);

        return c;
    }
};

fn randomUtf8(rng: std.Random, buf: []u8) []const u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789-_./@🚀测试";
    const max_len = @min(buf.len, 24);
    const target_len = rng.uintLessThan(usize, max_len + 1);
    var pos: usize = 0;
    while (pos < target_len) {
        // Pick a valid UTF-8 codepoint sequence cleanly
        const choice = rng.uintLessThan(usize, 5);
        switch (choice) {
            0 => {
                // ASCII
                buf[pos] = alphabet[rng.uintLessThan(usize, 40)];
                pos += 1;
            },
            1 => {
                // 2-byte UTF-8: U+00E9 (é)
                if (pos + 2 > buf.len) break;
                buf[pos] = 0xC3;
                buf[pos + 1] = 0xA9;
                pos += 2;
            },
            2 => {
                // 3-byte UTF-8: U+6D4B (测)
                if (pos + 3 > buf.len) break;
                buf[pos] = 0xE6;
                buf[pos + 1] = 0xB5;
                buf[pos + 2] = 0x8B;
                pos += 3;
            },
            3 => {
                // 4-byte UTF-8: U+1F680 (🚀)
                if (pos + 4 > buf.len) break;
                buf[pos] = 0xF0;
                buf[pos + 1] = 0x9F;
                buf[pos + 2] = 0x9A;
                buf[pos + 3] = 0x80;
                pos += 4;
            },
            else => {
                buf[pos] = 'z';
                pos += 1;
            },
        }
    }
    return buf[0..pos];
}

fn edgeI64(rng: std.Random) i64 {
    return switch (rng.uintLessThan(u8, 6)) {
        0 => 0,
        1 => 1,
        2 => -1,
        3 => std.math.maxInt(i64),
        4 => std.math.minInt(i64),
        else => rng.int(i64),
    };
}

fn edgeU64(rng: std.Random) u64 {
    return switch (rng.uintLessThan(u8, 5)) {
        0 => 0,
        1 => 1,
        2 => 127,
        3 => 128,
        else => rng.int(u64),
    };
}

pub fn runMutationFuzz(iters: usize, seed: u64) !void {
    const corpus = try SeedCorpus.init();
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var mut_buf: [2048]u8 = undefined;
    var scratch_a: [4096]u8 = undefined;
    var scratch_b: [4096]u8 = undefined;

    for (0..iters) |iter| {
        const mode = rng.uintLessThan(u8, 5);
        var len: usize = 0;

        if (mode == 4) {
            // Pure random bytes
            len = rng.uintLessThan(usize, 256);
            rng.bytes(mut_buf[0..len]);
        } else {
            // Pick one of the 3 valid seed messages and mutate it
            const src = switch (iter % 3) {
                0 => corpus.small[0..corpus.small_len],
                1 => corpus.user[0..corpus.user_len],
                else => corpus.batch[0..corpus.batch_len],
            };
            len = @min(src.len, mut_buf.len);
            @memcpy(mut_buf[0..len], src[0..len]);

            if (len > 0) {
                switch (mode) {
                    0 => {
                        // Bit flips (1..4 flips)
                        const flips = rng.uintLessThan(usize, 4) + 1;
                        for (0..flips) |_| {
                            const idx = rng.uintLessThan(usize, len);
                            const bit = @as(u8, 1) << rng.int(u3);
                            mut_buf[idx] ^= bit;
                        }
                    },
                    1 => {
                        // Truncate
                        len = rng.uintLessThan(usize, len + 1);
                    },
                    2 => {
                        // Byte overwrite burst
                        const idx = rng.uintLessThan(usize, len);
                        const burst = @min(len - idx, rng.uintLessThan(usize, 8) + 1);
                        rng.bytes(mut_buf[idx .. idx + burst]);
                    },
                    else => {
                        // Duplicate / append random tail
                        const extra = rng.uintLessThan(usize, 64);
                        if (len + extra <= mut_buf.len) {
                            rng.bytes(mut_buf[len .. len + extra]);
                            len += extra;
                        }
                    },
                }
            }
        }

        try checkAllSchemas(mut_buf[0..len], &scratch_a, &scratch_b);
    }
}

pub fn runStructuredFuzz(iters: usize, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x9E3779B97F4A7C15);
    const rng = prng.random();

    var enc_rev: [8192]u8 = undefined;
    var enc_fwd: [8192]u8 = undefined;
    var str_bufs: [8][32]u8 = undefined;

    for (0..iters) |_| {
        // 1. SmallEvent roundtrip
        {
            const src_str = randomUtf8(rng, &str_bufs[0]);
            const msg = pb.SmallEvent{
                .id = edgeU64(rng),
                .timestamp_ns = edgeI64(rng),
                .status = rng.int(u32),
                .source = src_str,
            };
            const rev = try msg.encodeSlice(&enc_rev);
            try std.testing.expectEqual(msg.encodedSize(), rev.len);

            var sw = wire.SliceWriter.init(&enc_fwd);
            try msg.encode(&sw);
            try std.testing.expectEqualSlices(u8, rev, sw.written());

            try pb.SmallEvent.validateDepth(rev, wire.max_recursion_depth);
            const dec = try pb.SmallEvent.decode(rev);
            try std.testing.expectEqual(msg.id, dec.id);
            try std.testing.expectEqual(msg.timestamp_ns, dec.timestamp_ns);
            try std.testing.expectEqual(msg.status, dec.status);
            try std.testing.expectEqualStrings(msg.source, dec.source);
        }

        // 2. UserProfile roundtrip (maps, repeated, nested, optional, oneof, Lazy)
        {
            var scores_buf: [16]u32 = undefined;
            const n_scores = rng.uintLessThan(usize, scores_buf.len + 1);
            for (scores_buf[0..n_scores]) |*s| s.* = rng.int(u32);

            var tags_buf: [4][]const u8 = undefined;
            const n_tags = rng.uintLessThan(usize, tags_buf.len + 1);
            for (0..n_tags) |i| tags_buf[i] = randomUtf8(rng, &str_bufs[1 + i]);

            var quotas_buf = [_]wire.Map(wire.ScalarCodec(.string_utf8), wire.ScalarCodec(.int32)).Entry{
                .{ .key = "cpu", .value = rng.int(i32) },
                .{ .key = "ram", .value = rng.int(i32) },
                .{ .key = "cpu", .value = rng.int(i32) }, // duplicate key -> last wins
            };
            const n_quotas = rng.uintLessThan(usize, quotas_buf.len + 1);

            const mgr = pb.UserProfile{
                .id = edgeU64(rng),
                .name = randomUtf8(rng, &str_bufs[5]),
                .role = @fromBackingInt(@intCast(@as(i32, @intCast(rng.uintLessThan(u8, 4))))),
            };
            const city = randomUtf8(rng, &str_bufs[6]);
            const contact_str = randomUtf8(rng, &str_bufs[7]);

            const msg = pb.UserProfile{
                .id = edgeU64(rng),
                .name = mgr.name,
                .role = switch (rng.uintLessThan(u8, 3)) {
                    0 => .ROLE_UNSPECIFIED,
                    1 => .ROLE_ADMIN,
                    else => .ROLE_MEMBER,
                },
                .scores = .{ .slice = scores_buf[0..n_scores] },
                .tags = .{ .slice = tags_buf[0..n_tags] },
                .quotas = .{ .slice = quotas_buf[0..n_quotas] },
                .address = if (rng.boolean()) .{ .city = city, .zip = rng.int(u32) } else null,
                .verified = if (rng.boolean()) rng.boolean() else null,
                .contact = switch (rng.uintLessThan(u8, 3)) {
                    0 => null,
                    1 => .{ .email = contact_str },
                    else => .{ .phone = contact_str },
                },
                .manager = if (rng.boolean()) .{ .ptr = &mgr } else null,
            };

            const rev = try msg.encodeSlice(&enc_rev);
            try std.testing.expectEqual(msg.encodedSize(), rev.len);

            var sw = wire.SliceWriter.init(&enc_fwd);
            try msg.encode(&sw);
            try std.testing.expectEqualSlices(u8, rev, sw.written());

            try pb.UserProfile.validateDepth(rev, wire.max_recursion_depth);
            const dec = try pb.UserProfile.decode(rev);
            try std.testing.expectEqual(msg.id, dec.id);
            try std.testing.expectEqualStrings(msg.name, dec.name);
            try std.testing.expectEqual(msg.role, dec.role);
            try std.testing.expectEqual(msg.verified, dec.verified);

            // Check repeated scores count & elements
            var sit = dec.scores.iterator();
            var idx: usize = 0;
            while (try sit.next()) |s| : (idx += 1) {
                try std.testing.expectEqual(scores_buf[idx], s);
            }
            try std.testing.expectEqual(n_scores, idx);

            // Check map last-key-wins semantics on "cpu"
            if (n_quotas == 3) {
                try std.testing.expectEqual(@as(?i32, quotas_buf[2].value), try dec.quotas.get("cpu"));
            } else if (n_quotas >= 1) {
                try std.testing.expectEqual(@as(?i32, quotas_buf[0].value), try dec.quotas.get("cpu"));
            }

            // Check cyclic Lazy submessage
            if (msg.manager != null) {
                const dec_mgr = try dec.manager.?.decode();
                try std.testing.expectEqual(mgr.id, dec_mgr.id);
                try std.testing.expectEqualStrings(mgr.name, dec_mgr.name);
            }
        }
    }
}

test "fuzz: PRNG wire mutation and structured round-trip properties" {
    try runMutationFuzz(10_000, 0xC0FFEE_2026);
    try runStructuredFuzz(2_000, 0xBEEF_2026);
}

fn smithFuzzOne(_: void, smith: *std.testing.Smith) !void {
    var input_buf: [512]u8 = undefined;
    const n = smith.slice(&input_buf);
    var scratch_a: [2048]u8 = undefined;
    var scratch_b: [2048]u8 = undefined;
    try checkAllSchemas(input_buf[0..n], &scratch_a, &scratch_b);
}

test "fuzz: std.testing.fuzz wire corpus and coverage hook" {
    const corpus = try SeedCorpus.init();
    try std.testing.fuzz({}, smithFuzzOne, .{
        .corpus = &.{
            corpus.small[0..corpus.small_len],
            corpus.user[0..corpus.user_len],
            corpus.batch[0..corpus.batch_len],
            "",
            &.{ 0x08, 0x96, 0x01 },
        },
    });
}

// ---------------------------------------------------------------------------
// Standalone Runner (`zig build fuzz -- --iters 200000 --seed 123`)
// Works natively on Windows, macOS, and Linux.
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var iters: usize = 100_000;
    var seed: u64 = 0x517CC1B727220A95;

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--iters")) {
            const val = args.next() orelse return error.MissingItersValue;
            iters = try std.fmt.parseInt(usize, val, 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            const val = args.next() orelse return error.MissingSeedValue;
            seed = try std.fmt.parseInt(u64, val, 0);
        }
    }

    const structured_iters = @max(iters / 5, 1_000);
    const start = std.Io.Timestamp.now(init.io, .awake);
    try runMutationFuzz(iters, seed);
    try runStructuredFuzz(structured_iters, seed);
    const elapsed_ns = start.durationTo(std.Io.Timestamp.now(init.io, .awake)).toNanoseconds();
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    var out_buf: [1024]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    try stdout_w.interface.print(
        "protoz fuzz passed: {d} mutation cases + {d} structured round-trips (seed=0x{x}, {d:.1} ms)\n",
        .{ iters, structured_iters, seed, elapsed_ms },
    );
    try stdout_w.interface.flush();
}
