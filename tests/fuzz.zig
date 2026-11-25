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

test "malformed: recursion depth bomb (>100 nested groups and cyclic submessages)" {
    // 1. 105-deep nested SGROUP/EGROUP unknown field wrapper (field 15)
    var group_bomb: [220]u8 = undefined;
    var pos: usize = 0;
    for (0..105) |_| {
        group_bomb[pos] = (15 << 3) | 3; // sgroup
        pos += 1;
    }
    for (0..105) |_| {
        group_bomb[pos] = (15 << 3) | 4; // egroup
        pos += 1;
    }
    try std.testing.expectError(error.RecursionLimitExceeded, pb.SmallEvent.decode(group_bomb[0..pos]));
    try std.testing.expectError(error.RecursionLimitExceeded, pb.SmallEvent.validateDepth(group_bomb[0..pos], wire.max_recursion_depth));

    // 2. 105-deep nested length-delimited cyclic `UserProfile.manager` (field 11)
    var msg_bomb: [512]u8 = undefined;
    var cur_slice: []const u8 = &.{};
    for (0..105) |_| {
        var next_buf: [512]u8 = undefined;
        var sw = wire.SliceWriter.init(&next_buf);
        try wire.writeTag(&sw, 11, .len);
        try wire.writeBytes(&sw, cur_slice);
        const written = sw.written();
        @memcpy(msg_bomb[0..written.len], written);
        cur_slice = msg_bomb[0..written.len];
    }
    try std.testing.expectError(error.RecursionLimitExceeded, pb.UserProfile.decode(cur_slice));
    try std.testing.expectError(error.RecursionLimitExceeded, pb.UserProfile.validateDepth(cur_slice, wire.max_recursion_depth));
}

test "malformed: merge chunk limit exceeded and BufferTooSmall" {
    // 1. Same-buffer Lazy occurrences extend `.wire` cleanly for arbitrary counts
    var same_buf: [128]u8 = undefined;
    var pos: usize = 0;
    for (0..wire.max_merge_chunks + 4) |_| {
        same_buf[pos] = (11 << 3) | 2; // field 11 (`manager`), LEN
        same_buf[pos + 1] = 0x02;
        same_buf[pos + 2] = 0x08; // inner field 1 (id)
        same_buf[pos + 3] = 0x01;
        pos += 4;
    }
    const same_dec = try pb.UserProfile.decode(same_buf[0..pos]);
    const same_mgr = try same_dec.manager.?.decode();
    try std.testing.expectEqual(@as(u64, 1), same_mgr.id);

    // 2. Disjoint-buffer mergeDepth on Lazy (`RawPair` supports 2 chunks, 3rd fails)
    const mgr_chunk = [_]u8{ (11 << 3) | 2, 0x02, 0x08, 0x01 };
    var lazy_bufs: [3][4]u8 = .{ mgr_chunk, mgr_chunk, mgr_chunk };
    var lazy_msg: pb.UserProfile = .{};
    try lazy_msg.mergeDepth(&lazy_bufs[0], wire.max_recursion_depth);
    try lazy_msg.mergeDepth(&lazy_bufs[1], wire.max_recursion_depth);
    try std.testing.expectError(error.MergeChunkLimitExceeded, lazy_msg.mergeDepth(&lazy_bufs[2], wire.max_recursion_depth));

    // 3. Disjoint-buffer mergeDepth on Repeated (`WireChunks` supports `max_merge_chunks`)
    const score_chunk = [_]u8{ 0x20, 0x07 }; // field 4 (`scores`), varint 7
    var rep_bufs: [wire.max_merge_chunks + 1][2]u8 = undefined;
    var rep_msg: pb.UserProfile = .{};
    for (0..wire.max_merge_chunks) |i| {
        rep_bufs[i] = score_chunk;
        try rep_msg.mergeDepth(&rep_bufs[i], wire.max_recursion_depth);
    }
    rep_bufs[wire.max_merge_chunks] = score_chunk;
    try std.testing.expectError(error.MergeChunkLimitExceeded, rep_msg.mergeDepth(&rep_bufs[wire.max_merge_chunks], wire.max_recursion_depth));

    // 4. Encoding into undersized buffer returns BufferTooSmall cleanly
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
    while (try pit.next()) |pt| acc +%= pt.ts +% pt.label.len +% @as(u64, @bitCast(pt.value));
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
/// 2) `validateDepth` and `decode` must agree on validity (decode may only additionally
///    return `MergeChunkLimitExceeded` on disjoint multi-chunk merges).
/// 3) If decode succeeds, re-encoding via both `encodeSlice` and `encode` must match
///    `decoded.encodedSize()` byte-for-byte and re-decode cleanly.
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
        const d = dec_res catch |err| switch (err) {
            error.MergeChunkLimitExceeded => return,
            else => return err,
        };

        if (traverse_fn) |tf| {
            const acc = tf(d) catch |err| switch (err) {
                error.MergeChunkLimitExceeded => return,
                else => return err,
            };
            std.mem.doNotOptimizeAway(acc);
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
    } else |_| {
        if (dec_res) |_| {
            return error.DecodeAcceptedInvalidWire;
        } else |_| {}
    }
}

fn checkAllSchemas(bytes: []const u8, scratch_a: []u8, scratch_b: []u8) !void {
    try checkArbitraryWire(pb.SmallEvent, bytes, null, scratch_a, scratch_b);
    try checkArbitraryWire(pb.UserProfile, bytes, traverseUser, scratch_a, scratch_b);
    try checkArbitraryWire(pb.TelemetryBatch, bytes, traverseBatch, scratch_a, scratch_b);
    try checkArbitraryWire(wkt.google_protobuf_timestamp.Timestamp, bytes, null, scratch_a, scratch_b);

    // Exercise recursive Struct validateDepth/decode parity + traversal
    const st_val = wkt.google_protobuf_struct.Struct.validateDepth(bytes, wire.max_recursion_depth);
    const st_dec = wkt.google_protobuf_struct.Struct.decode(bytes);
    if (st_val) |_| {
        const st = st_dec catch |err| switch (err) {
            error.MergeChunkLimitExceeded => return,
            else => return err,
        };
        const acc = traverseStruct(st, 16) catch |err| switch (err) {
            error.MergeChunkLimitExceeded => return,
            else => return err,
        };
        std.mem.doNotOptimizeAway(acc);
    } else |_| {
        if (st_dec) |_| return error.DecodeAcceptedInvalidWire else |_| {}
    }
}

// ---------------------------------------------------------------------------
// Cross-Platform Seed Corpus & PRNG Mutation + Structured Fuzzing
// ---------------------------------------------------------------------------

const SeedCorpus = struct {
    small: [64]u8,
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
        const s_enc = try ev.encodeSlice(&c.small);
        c.small_len = s_enc.len;
        std.mem.copyForwards(u8, c.small[0..c.small_len], s_enc);

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
    const ascii = "abcdefghijklmnopqrstuvwxyz0123456789-_./@";
    const max_len = @min(buf.len, 24);
    const target_len = rng.uintLessThan(usize, max_len + 1);
    var pos: usize = 0;
    while (pos < target_len) {
        switch (rng.uintLessThan(u8, 5)) {
            0 => {
                buf[pos] = ascii[rng.uintLessThan(usize, ascii.len)];
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
    return switch (rng.uintLessThan(u8, 6)) {
        0 => 0,
        1 => 1,
        2 => 127,
        3 => 128,
        4 => std.math.maxInt(u64),
        else => rng.int(u64),
    };
}

fn edgeF64(rng: std.Random) f64 {
    return switch (rng.uintLessThan(u8, 7)) {
        0 => 0.0,
        1 => -0.0,
        2 => 1.0,
        3 => -42.125,
        4 => std.math.inf(f64),
        5 => -std.math.inf(f64),
        else => @bitCast(rng.int(u64)),
    };
}

fn edgeRole(rng: std.Random) pb.Role {
    return switch (rng.uintLessThan(u8, 8)) {
        0 => .ROLE_UNSPECIFIED,
        1 => .ROLE_ADMIN,
        2 => .ROLE_MEMBER,
        3 => @fromBackingInt(-1), // 10-byte sign-extended negative enum varint
        4 => @fromBackingInt(-42),
        5 => @fromBackingInt(999),
        6 => @fromBackingInt(std.math.minInt(i32)),
        else => @fromBackingInt(std.math.maxInt(i32)),
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
            len = rng.uintLessThan(usize, 256);
            rng.bytes(mut_buf[0..len]);
        } else {
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
                        const flips = rng.uintLessThan(usize, 4) + 1;
                        for (0..flips) |_| {
                            const idx = rng.uintLessThan(usize, len);
                            const bit = @as(u8, 1) << rng.int(u3);
                            mut_buf[idx] ^= bit;
                        }
                    },
                    1 => {
                        len = rng.uintLessThan(usize, len + 1);
                    },
                    2 => {
                        const idx = rng.uintLessThan(usize, len);
                        const burst = @min(len - idx, rng.uintLessThan(usize, 8) + 1);
                        rng.bytes(mut_buf[idx .. idx + burst]);
                    },
                    else => {
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
    var str_bufs: [10][32]u8 = undefined;

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

        // 2. UserProfile roundtrip (maps, repeated, nested, optional, oneof, negative enums, Lazy)
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
                .role = edgeRole(rng),
            };
            const user_name = randomUtf8(rng, &str_bufs[6]);
            const city = randomUtf8(rng, &str_bufs[7]);
            const contact_str = randomUtf8(rng, &str_bufs[8]);

            const msg = pb.UserProfile{
                .id = edgeU64(rng),
                .name = user_name,
                .role = edgeRole(rng),
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

            if (msg.address) |addr| {
                try std.testing.expect(dec.address != null);
                try std.testing.expectEqualStrings(addr.city, dec.address.?.city);
                try std.testing.expectEqual(addr.zip, dec.address.?.zip);
            } else {
                try std.testing.expect(dec.address == null);
            }

            if (msg.contact) |c| {
                try std.testing.expect(dec.contact != null);
                switch (c) {
                    .email => |s| try std.testing.expectEqualStrings(s, dec.contact.?.email),
                    .phone => |s| try std.testing.expectEqualStrings(s, dec.contact.?.phone),
                }
            } else {
                try std.testing.expect(dec.contact == null);
            }

            var sit = dec.scores.iterator();
            var s_idx: usize = 0;
            while (try sit.next()) |s| : (s_idx += 1) {
                try std.testing.expectEqual(scores_buf[s_idx], s);
            }
            try std.testing.expectEqual(n_scores, s_idx);

            var tit = dec.tags.iterator();
            var t_idx: usize = 0;
            while (try tit.next()) |t| : (t_idx += 1) {
                try std.testing.expectEqualStrings(tags_buf[t_idx], t);
            }
            try std.testing.expectEqual(n_tags, t_idx);

            if (n_quotas == 3) {
                try std.testing.expectEqual(@as(?i32, quotas_buf[2].value), try dec.quotas.get("cpu"));
            } else if (n_quotas >= 1) {
                try std.testing.expectEqual(@as(?i32, quotas_buf[0].value), try dec.quotas.get("cpu"));
            }

            if (msg.manager != null) {
                const dec_mgr = try dec.manager.?.decode();
                try std.testing.expectEqual(mgr.id, dec_mgr.id);
                try std.testing.expectEqualStrings(mgr.name, dec_mgr.name);
                try std.testing.expectEqual(mgr.role, dec_mgr.role);
            }
        }

        // 3. TelemetryBatch roundtrip (packed ZigZag sint64, packed fixed64, f64 bit-exact, repeated submessages)
        {
            var deltas_buf: [24]i64 = undefined;
            const n_deltas = rng.uintLessThan(usize, deltas_buf.len + 1);
            for (deltas_buf[0..n_deltas]) |*d| d.* = edgeI64(rng);

            var hashes_buf: [24]u64 = undefined;
            const n_hashes = rng.uintLessThan(usize, hashes_buf.len + 1);
            for (hashes_buf[0..n_hashes]) |*h| h.* = edgeU64(rng);

            var points_buf: [8]pb.TelemetryBatch.Point = undefined;
            const n_points = rng.uintLessThan(usize, points_buf.len + 1);
            for (0..n_points) |i| {
                points_buf[i] = .{
                    .ts = edgeU64(rng),
                    .value = edgeF64(rng),
                    .label = randomUtf8(rng, &str_bufs[i]),
                };
            }

            const batch = pb.TelemetryBatch{
                .host = randomUtf8(rng, &str_bufs[9]),
                .deltas = .{ .slice = deltas_buf[0..n_deltas] },
                .hashes = .{ .slice = hashes_buf[0..n_hashes] },
                .points = .{ .slice = points_buf[0..n_points] },
            };

            const rev = try batch.encodeSlice(&enc_rev);
            try std.testing.expectEqual(batch.encodedSize(), rev.len);

            var sw = wire.SliceWriter.init(&enc_fwd);
            try batch.encode(&sw);
            try std.testing.expectEqualSlices(u8, rev, sw.written());

            try pb.TelemetryBatch.validateDepth(rev, wire.max_recursion_depth);
            const dec = try pb.TelemetryBatch.decode(rev);
            try std.testing.expectEqualStrings(batch.host, dec.host);

            var dit = dec.deltas.iterator();
            var d_idx: usize = 0;
            while (try dit.next()) |v| : (d_idx += 1) {
                try std.testing.expectEqual(deltas_buf[d_idx], v);
            }
            try std.testing.expectEqual(n_deltas, d_idx);

            var hit = dec.hashes.iterator();
            var h_idx: usize = 0;
            while (try hit.next()) |h| : (h_idx += 1) {
                try std.testing.expectEqual(hashes_buf[h_idx], h);
            }
            try std.testing.expectEqual(n_hashes, h_idx);

            var pit = dec.points.iterator();
            var p_idx: usize = 0;
            while (try pit.next()) |pt| : (p_idx += 1) {
                try std.testing.expectEqual(points_buf[p_idx].ts, pt.ts);
                try std.testing.expectEqual(@as(u64, @bitCast(points_buf[p_idx].value)), @as(u64, @bitCast(pt.value)));
                try std.testing.expectEqualStrings(points_buf[p_idx].label, pt.label);
            }
            try std.testing.expectEqual(n_points, p_idx);
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
