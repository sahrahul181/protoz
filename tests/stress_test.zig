const std = @import("std");
const protoz = @import("protoz");
const wire = @import("proto_wire");
const pb = @import("stress_pb");

const base = pb.base_common;
const legacy = pb.legacy_proto2_ext;
const editions = pb.editions_ed2023;
const facade = pb.facade_public_bridge;
const v1 = pb.complex;

test "stress: refAllDecls compiles all generated files, messages, enums, WKTs, and services" {
    std.testing.refAllDecls(base);
    std.testing.refAllDecls(legacy);
    std.testing.refAllDecls(editions);
    std.testing.refAllDecls(facade);
    std.testing.refAllDecls(v1);
    std.testing.refAllDecls(v1.MegaEnvelope);
    std.testing.refAllDecls(v1.MegaGateway);
    std.testing.refAllDecls(base.TreeNode);
    std.testing.refAllDecls(v1.CycleA);
    std.testing.refAllDecls(v1.CycleB);
    std.testing.refAllDecls(v1.MethodCollision);
}

test "stress: MegaEnvelope wire round-trip (reverse vs forward, all 15 scalars, all 12 map keys, multi-oneof, cycles, WKTs, unknown fields)" {
    var l4_notes = [_][]const u8{ "deep-1", "deep-2" };
    var l4_list = [_]v1.Level1.Level2.Level3.Level4{
        .{ .leaf_id = 0xDEAD_BEEF_CAFE_BABE, .notes = .{ .slice = &l4_notes } },
    };

    const inner_child = base.TreeNode{
        .label = "child-leaf",
        .branch = .{ .leaf_val = -42 },
    };
    var tree_children = [_]base.TreeNode{inner_child};
    var tree_map = [_]wire.Map(wire.ScalarCodec(.string_utf8), wire.MessageCodec(base.TreeNode)).Entry{
        .{ .key = "left", .value = inner_child },
    };
    const root_tree = base.TreeNode{
        .label = "root",
        .children = .{ .slice = &tree_children },
        .named_children = .{ .slice = &tree_map },
        .branch = .{ .leaf_val = 999 },
    };

    const ts_val = pb.google_protobuf_timestamp.Timestamp{ .seconds = 1_764_075_000, .nanos = 500_000_000 };
    const dur_val = pb.google_protobuf_duration.Duration{ .seconds = 12, .nanos = 345_000_000 };

    const any_payload = v1.Inner{ .from_top = "inside-any" };
    var any_buf: [128]u8 = undefined;
    const packed_any = try pb.google_protobuf_any.Any.packSlice(any_payload, &any_buf);

    var mask_paths = [_][]const u8{ "s_string", "ts.seconds" };
    var struct_fields = [_]wire.Map(wire.ScalarCodec(.string_utf8), wire.MessageCodec(pb.google_protobuf_struct.Value)).Entry{
        .{ .key = "ok", .value = .{ .kind = .{ .bool_value = true } } },
        .{ .key = "score", .value = .{ .kind = .{ .number_value = 99.5 } } },
    };

    var map_i32 = [_]wire.Map(wire.ScalarCodec(.int32), wire.ScalarCodec(.string_utf8)).Entry{.{ .key = -7, .value = "neg" }};
    var map_i64 = [_]wire.Map(wire.ScalarCodec(.int64), wire.ScalarCodec(.bytes)).Entry{.{ .key = -1234567890123, .value = "\x00\xff" }};
    var map_u32 = [_]wire.Map(wire.ScalarCodec(.uint32), wire.ScalarCodec(.double_)).Entry{.{ .key = 42, .value = 3.14159 }};
    var map_u64 = [_]wire.Map(wire.ScalarCodec(.uint64), wire.ScalarCodec(.bool_)).Entry{.{ .key = 9001, .value = true }};
    var map_si32 = [_]wire.Map(wire.ScalarCodec(.sint32), wire.ScalarCodec(.sint64)).Entry{.{ .key = -55, .value = -9999999999 }};
    var map_si64 = [_]wire.Map(wire.ScalarCodec(.sint64), wire.ScalarCodec(.fixed32)).Entry{.{ .key = -88, .value = 0x12345678 }};
    var map_f32 = [_]wire.Map(wire.ScalarCodec(.fixed32), wire.ScalarCodec(.fixed64)).Entry{.{ .key = 7, .value = 8 }};
    var map_f64 = [_]wire.Map(wire.ScalarCodec(.fixed64), wire.ScalarCodec(.sfixed32)).Entry{.{ .key = 9, .value = -10 }};
    var map_sf32 = [_]wire.Map(wire.ScalarCodec(.sfixed32), wire.ScalarCodec(.sfixed64)).Entry{.{ .key = -11, .value = -12 }};
    var map_sf64 = [_]wire.Map(wire.ScalarCodec(.sfixed64), wire.EnumCodec(base.StatusFlag)).Entry{.{ .key = -13, .value = .STATUS_ERR }};
    var map_bool = [_]wire.Map(wire.ScalarCodec(.bool_), wire.MessageCodec(v1.Outer.Inner)).Entry{.{ .key = true, .value = .{ .from_outer = 77 } }};
    var map_str_ts = [_]wire.Map(wire.ScalarCodec(.string_utf8), wire.MessageCodec(pb.google_protobuf_timestamp.Timestamp)).Entry{.{ .key = "now", .value = ts_val }};

    var rep_sint64 = [_]i64{ -1, 0, 1, std.math.minInt(i64), std.math.maxInt(i64) };
    var rep_fixed32 = [_]u32{ 1, 0xCAFEBABE };
    var rep_strings = [_][]const u8{ "alpha", "beta\n\"quote\"" };
    var rep_bytes = [_][]const u8{ "\x00\x01\xfe\xff", "" };
    var rep_enums = [_]base.KeywordEnum{ .type, .@"error", .@"fn", .@"align", .@"test" };

    // Unknown fields of every wire type: varint, i64, len, i32, sgroup/egroup
    var unk_buf: [128]u8 = undefined;
    var uw = wire.SliceWriter.init(&unk_buf);
    try wire.writeTag(&uw, 9999, .varint);
    try wire.writeVarint(&uw, 123456789);
    try wire.writeTag(&uw, 10000, .len);
    try wire.writeBytes(&uw, "preserved-raw");
    try wire.writeTag(&uw, 10001, .i64);
    try wire.writeFixed64(&uw, 0x0102030405060708);
    try wire.writeTag(&uw, 10002, .i32);
    try wire.writeFixed32(&uw, 0x11223344);
    try wire.writeTag(&uw, 10003, .sgroup);
    try wire.writeTag(&uw, 1, .varint);
    try wire.writeVarint(&uw, 42);
    try wire.writeTag(&uw, 10003, .egroup);

    const cycle_b = v1.CycleB{ .code = 202 };
    var cycle_b_slice = [_]v1.CycleB{cycle_b};
    var cycle_b_map = [_]wire.Map(wire.ScalarCodec(.string_utf8), wire.MessageCodec(v1.CycleB)).Entry{
        .{ .key = "first", .value = cycle_b },
    };

    const msg = v1.MegaEnvelope{
        .s_double = 1234.5,
        .s_float = -2.25,
        .s_int32 = -42,
        .s_int64 = -9_000_000_000,
        .s_uint32 = 4_000_000_000,
        .s_uint64 = 18_000_000_000_000_000_000,
        .s_sint32 = -12345,
        .s_sint64 = -9876543210,
        .s_fixed32 = 0xAABBCCDD,
        .s_fixed64 = 0x1122334455667788,
        .s_sfixed32 = -999,
        .s_sfixed64 = -8888888888,
        .s_bool = true,
        .s_string = "hello \xf0\x9f\x9a\x80 protoz",
        .s_bytes = "\x00\x01\x02\xff",
        .opt_i64 = 0,
        .opt_bool = false,
        .opt_str = "",
        .opt_flag = .STATUS_MIN,
        .rep_sint64 = .{ .slice = &rep_sint64 },
        .rep_fixed32 = .{ .slice = &rep_fixed32 },
        .rep_strings = .{ .slice = &rep_strings },
        .rep_bytes = .{ .slice = &rep_bytes },
        .rep_enums = .{ .slice = &rep_enums },
        .rep_l4 = .{ .slice = &l4_list },
        .map_i32 = .{ .slice = &map_i32 },
        .map_i64 = .{ .slice = &map_i64 },
        .map_u32 = .{ .slice = &map_u32 },
        .map_u64 = .{ .slice = &map_u64 },
        .map_si32 = .{ .slice = &map_si32 },
        .map_si64 = .{ .slice = &map_si64 },
        .map_f32 = .{ .slice = &map_f32 },
        .map_f64 = .{ .slice = &map_f64 },
        .map_sf32 = .{ .slice = &map_sf32 },
        .map_sf64 = .{ .slice = &map_sf64 },
        .map_bool = .{ .slice = &map_bool },
        .map_str_ts = .{ .slice = &map_str_ts },
        .payload_one = .{ .nested_payload = .{ .l2 = .{ .l3 = .{ .l4 = l4_list[0] } } } },
        .payload_two = .{ .kw_msg = .{ .@"error" = "err", .@"fn" = "rawfn", .@"align" = 8, .@"test" = true, .@"struct" = .@"test", .u32 = 99, .void = true } },
        .bridged_shadow = .{ .shadowed_tag = 77 },
        .base_empty = .{},
        .tree = root_tree,
        .legacy = .{
            .required_id = 123,
            .unpacked_ids = .{ .slice = &[_]u32{ 10, 20 } },
            .packed_ids = .{ .slice = &[_]u32{ 30, 40 } },
        },
        .edition_cfg = .{
            .raw_non_utf8 = "\xff\xfe",
            .strict_utf8 = "valid",
            .count = 0,
            .implicit_count = 5,
            .expanded_nums = .{ .slice = &[_]i32{ 1, 2 } },
            .packed_nums = .{ .slice = &[_]i32{ 3, 4 } },
        },
        .scope_test = .{
            .shadowed = .{ .from_outer = 11 },
            .explicit_root = .{ .from_top = "top" },
        },
        .collisions = .{
            .encode_ = "enc-val",
            .decode_ = "dec-val",
            .proto_full_name_ = "pfn-val",
            ._unknown_fields = "uf-val",
        },
        .mutual_cycle = .{
            .name = "ca",
            .b = .{ .ptr = &cycle_b },
            .b_list = .{ .slice = &cycle_b_slice },
            .b_map = .{ .slice = &cycle_b_map },
        },
        .ts = ts_val,
        .dur = dur_val,
        .any_val = packed_any,
        .struct_val = .{ .fields = .{ .slice = &struct_fields } },
        .mask_val = .{ .paths = .{ .slice = &mask_paths } },
        .wrap_i64 = .{ .value = -500 },
        .wrap_str = .{ .value = "wrapped" },
        .max_field_num = 536_870_911,
        ._unknown_fields = .{ .raw = uw.written() },
    };

    var rev_buf: [16384]u8 = undefined;
    var fwd_buf: [16384]u8 = undefined;
    const rev_bytes = try msg.encodeSlice(&rev_buf);
    var fw = wire.SliceWriter.init(&fwd_buf);
    try msg.encode(&fw);
    const fwd_bytes = fw.written();

    try std.testing.expectEqual(msg.encodedSize(), rev_bytes.len);
    try std.testing.expectEqualSlices(u8, rev_bytes, fwd_bytes);

    // Decode zero-allocation view
    const dec = try v1.MegaEnvelope.decode(rev_bytes);
    try std.testing.expectEqual(@as(u32, 536_870_911), dec.max_field_num);
    try std.testing.expectEqual(@as(?i64, 0), dec.opt_i64);
    try std.testing.expectEqual(@as(?bool, false), dec.opt_bool);
    try std.testing.expectEqualStrings("", dec.opt_str.?);
    try std.testing.expectEqual(base.StatusFlag.STATUS_MIN, dec.opt_flag.?);
    try std.testing.expectEqualStrings("neg", (try dec.map_i32.get(-7)).?);
    try std.testing.expectEqual(base.StatusFlag.STATUS_ERR, (try dec.map_sf64.get(-13)).?);
    try std.testing.expectEqual(@as(i32, 77), (try dec.map_bool.get(true)).?.from_outer);
    try std.testing.expectEqual(ts_val.seconds, (try dec.map_str_ts.get("now")).?.seconds);
    try std.testing.expectEqualStrings("wrapped", dec.wrap_str.?.value);

    // Unpack Any
    const unpacked = try dec.any_val.?.unpack(v1.Inner);
    try std.testing.expectEqualStrings("inside-any", unpacked.from_top);

    // Unknown field preserved byte-for-byte on re-encode
    try std.testing.expectEqualSlices(u8, rev_bytes, try dec.encodeSlice(&fwd_buf));

    // Recursive tree decode + FieldIterator early exit
    const dec_tree = dec.tree.?;
    try std.testing.expectEqualStrings("root", dec_tree.label);
    const left_child = (try dec_tree.named_children.get("left")).?;
    try std.testing.expectEqualStrings("child-leaf", left_child.label);
    const dec_cycle_b = try dec.mutual_cycle.?.b.?.decode();
    try std.testing.expectEqual(@as(i32, 202), dec_cycle_b.code);

    var fit = v1.MegaEnvelope.fieldIterator(rev_bytes);
    var found_max: u32 = 0;
    while (try fit.next()) |item| switch (item) {
        .max_field_num => |v| {
            found_max = v;
            break;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(u32, 536_870_911), found_max);

    // decodeOnly projection
    const proj = try v1.MegaEnvelope.decodeOnly(rev_bytes, .{ .s_uint64, .max_field_num });
    try std.testing.expectEqual(msg.s_uint64, proj.s_uint64);
    try std.testing.expectEqual(@as(u32, 536_870_911), proj.max_field_num);

    // cloneOwned detach: invalidate wire buffer and verify cloned data survives
    var owned = try protoz.cloneOwned(std.testing.allocator, dec);
    defer owned.deinit();
    @memset(&rev_buf, 0xAA);
    try std.testing.expectEqualStrings("hello \xf0\x9f\x9a\x80 protoz", owned.value.s_string);
    try std.testing.expectEqualStrings("neg", (try owned.value.map_i32.get(-7)).?);

    // Length-delimited streaming over wire payload
    var delim_buf: [16384]u8 = undefined;
    const delim_bytes = try protoz.encodeDelimitedSlice(owned.value, &delim_buf);
    const dframe = (try protoz.tryDecodeDelimited(v1.MegaEnvelope, delim_bytes, 32768)).?;
    try std.testing.expectEqual(@as(u32, 536_870_911), dframe.msg.max_field_num);

    // ProtoJSON round-trip on UTF-8-clean MegaEnvelope (with maps, cycles, oneof, repeated, WKTs, and known_types Any expansion)
    var json_msg = owned.value;
    json_msg.edition_cfg = .{
        .raw_non_utf8 = "clean-utf8-for-json",
        .strict_utf8 = "valid",
        .count = 0,
    };
    const known = .{ v1.Inner, pb.google_protobuf_timestamp.Timestamp };
    var json_buf: [16384]u8 = undefined;
    const json_str = try wire.json.encodeMessageSliceWithTypes(json_msg, &json_buf, .{}, known);
    // Verify Any expanded inline (`"@type":"type.googleapis.com/stress.v1.Inner","fromTop":"inside-any"`)
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"fromTop\":\"inside-any\"") != null);
    // Verify renamed collision fields keep original ProtoJSON wire names (`"encode"`, `"decode"`, `"protoFullName"`)
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"encode\":\"enc-val\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"decode\":\"dec-val\"") != null);

    var json_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer json_arena.deinit();
    const json_dec = try wire.json.decodeMessageWithTypes(v1.MegaEnvelope, json_arena.allocator(), json_str, .{}, known);
    try std.testing.expectEqual(@as(u32, 536_870_911), json_dec.max_field_num);
    try std.testing.expectEqualStrings("neg", (try json_dec.map_i32.get(-7)).?);
    try std.testing.expectEqual(@as(i32, 77), (try json_dec.map_bool.get(true)).?.from_outer);
    try std.testing.expectEqualStrings("root", json_dec.tree.?.label);
    try std.testing.expectEqualStrings("top", json_dec.scope_test.?.explicit_root.?.from_top);
    try std.testing.expectEqualStrings("enc-val", json_dec.collisions.?.encode_);
    try std.testing.expectEqualStrings("dec-val", json_dec.collisions.?.decode_);
    const json_unpacked_any = try json_dec.any_val.?.unpack(v1.Inner);
    try std.testing.expectEqualStrings("inside-any", json_unpacked_any.from_top);
}

test "stress: Proto2 required enforcement and defaults namespace" {
    try std.testing.expectEqual(@as(i32, 5), legacy.LegacyRecord.defaults.retry_limit);
    try std.testing.expectEqualStrings("us-east", legacy.LegacyRecord.defaults.region);
    try std.testing.expectEqual(legacy.LegacyMode.MODE_BETA, legacy.LegacyRecord.defaults.mode);

    // Missing required_id fails with error.MissingRequiredField
    try std.testing.expectError(error.MissingRequiredField, legacy.LegacyRecord.decode(""));

    // Present required_id succeeds while preserving optional defaults as null until defaulted by caller
    var rep_tag_items = [_]legacy.LegacyRecord.LegacyTag{ .{ .tag = "alpha" }, .{ .tag = "beta" } };
    const rec = legacy.LegacyRecord{
        .required_id = 42,
        .legacygroup = .{ .a = 9, .b = "hello-grp" },
        .legacytag = .{ .slice = &rep_tag_items },
        .choice = .{ .groupchoice = .{ .code = 77, .msg = "oneof-grp" } },
    };
    var buf: [256]u8 = undefined;
    const bytes = try rec.encodeSlice(&buf);
    var fwd_buf: [256]u8 = undefined;
    var fwd_sw = wire.SliceWriter.init(&fwd_buf);
    try rec.encode(&fwd_sw);
    try std.testing.expectEqualSlices(u8, bytes, fwd_sw.written());

    const dec = try legacy.LegacyRecord.decode(bytes);
    try std.testing.expectEqual(@as(?u64, 42), dec.required_id);
    try std.testing.expectEqual(@as(i32, 5), dec.retry_limit orelse legacy.LegacyRecord.defaults.retry_limit);
    try std.testing.expectEqual(@as(?i32, 9), dec.legacygroup.?.a);
    try std.testing.expectEqualStrings("hello-grp", dec.legacygroup.?.b.?);
    try std.testing.expectEqual(@as(?i32, 77), dec.choice.?.groupchoice.code);
    try std.testing.expectEqualStrings("oneof-grp", dec.choice.?.groupchoice.msg.?);
    var tag_it = dec.legacytag.iterator();
    try std.testing.expectEqualStrings("alpha", (try tag_it.next()).?.tag.?);
    try std.testing.expectEqualStrings("beta", (try tag_it.next()).?.tag.?);
    try std.testing.expectEqual(@as(?legacy.LegacyRecord.LegacyTag, null), try tag_it.next());

    // Cyclic recursive group (Lazy .sgroup) multi-occurrence merge & round-trip
    const leaf = legacy.CyclicGroupNode{ .val = 99 };
    const grp1 = legacy.CyclicGroupNode.Next{ .target = .{ .ptr = &leaf } };
    const grp2 = legacy.CyclicGroupNode.Next{ .note = "merged-grp" };
    const node1 = legacy.CyclicGroupNode{ .val = 1, .next = .{ .ptr = &grp1 } };
    const node2 = legacy.CyclicGroupNode{ .next = .{ .ptr = &grp2 } };

    var cyc_wire_buf: [256]u8 = undefined;
    var cyc_sw = wire.SliceWriter.init(&cyc_wire_buf);
    try node1.encode(&cyc_sw);
    try node2.encode(&cyc_sw);

    const dec_cyc = try legacy.CyclicGroupNode.decode(cyc_sw.written());
    try std.testing.expectEqual(@as(?i32, 1), dec_cyc.val);
    const dec_next = try dec_cyc.next.?.decode();
    try std.testing.expectEqualStrings("merged-grp", dec_next.note.?);
    const dec_leaf = try dec_next.target.?.decode();
    try std.testing.expectEqual(@as(?i32, 99), dec_leaf.val);

    // Re-encode the unexpanded `.wire` Lazy(.sgroup) node and verify round-trip parity
    var cyc_re_buf: [256]u8 = undefined;
    const cyc_re = try dec_cyc.encodeSlice(&cyc_re_buf);
    var cyc_fwd_buf: [256]u8 = undefined;
    var cyc_fwd_sw = wire.SliceWriter.init(&cyc_fwd_buf);
    try dec_cyc.encode(&cyc_fwd_sw);
    try std.testing.expectEqualSlices(u8, cyc_re, cyc_fwd_sw.written());

    const redec_cyc = try legacy.CyclicGroupNode.decode(cyc_re);
    const redec_next = try redec_cyc.next.?.decode();
    try std.testing.expectEqualStrings("merged-grp", redec_next.note.?);
    try std.testing.expectEqual(@as(?i32, 99), (try redec_next.target.?.decode()).val);

    // Transitive isInitialized() across optional, repeated, map, and oneof submessages
    var p_ok = legacy.LegacyParent{ .opt_rec = rec };
    try std.testing.expect(p_ok.isInitialized());
    p_ok.opt_rec = .{}; // missing required_id inside optional child
    try std.testing.expect(!p_ok.isInitialized());

    var bad_rep = [_]legacy.LegacyRecord{.{}};
    const p_rep = legacy.LegacyParent{ .rep_recs = .{ .slice = &bad_rep } };
    try std.testing.expect(!p_rep.isInitialized());

    var bad_map = [_]wire.Map(wire.ScalarCodec(.string), wire.MessageCodec(legacy.LegacyRecord)).Entry{
        .{ .key = "k", .value = .{} },
    };
    const p_map = legacy.LegacyParent{ .map_recs = .{ .slice = &bad_map } };
    try std.testing.expect(!p_map.isInitialized());

    const p_oneof = legacy.LegacyParent{ .pick = .{ .oneof_rec = .{} } };
    try std.testing.expect(!p_oneof.isInitialized());
}

test "stress: wire GroupCodec, Extension, and RepeatedExtension over UnknownFields" {
    const GroupMsg = struct {
        a: ?i32 = null,
        pub fn encodedSize(self: *const @This()) usize {
            return if (self.a) |v| wire.tagSize(1) + wire.ScalarCodec(.int32).size(v) else 0;
        }
        pub fn encode(self: *const @This(), w: anytype) wire.WriterError(@TypeOf(w))!void {
            if (self.a) |v| {
                try wire.writeTag(w, 1, .varint);
                try wire.ScalarCodec(.int32).write(w, v);
            }
        }
        pub fn encodeReverse(self: *const @This(), rw: *wire.ReverseWriter) wire.EncodeError!void {
            if (self.a) |v| {
                try wire.ScalarCodec(.int32).writeReverse(rw, v);
                try rw.writeTag(1, .varint);
            }
        }
        pub fn validateDepth(bytes: []const u8, depth: u32) wire.DecodeError!void {
            if (depth == 0) return error.RecursionLimitExceeded;
            var r = wire.Reader.init(bytes);
            while (try r.readTag()) |tag| try r.skipField(tag, depth - 1);
        }
        pub fn decodeDepth(bytes: []const u8, depth: u32) wire.DecodeError!@This() {
            if (depth == 0) return error.RecursionLimitExceeded;
            var out: @This() = .{};
            var r = wire.Reader.init(bytes);
            while (try r.readTag()) |tag| {
                if (tag.field_number == 1) out.a = try wire.ScalarCodec(.int32).read(&r, depth - 1) else try r.skipField(tag, depth - 1);
            }
            return out;
        }
        pub fn mergeDepth(self: *@This(), bytes: []const u8, depth: u32) wire.DecodeError!void {
            const d = try decodeDepth(bytes, depth);
            if (d.a != null) self.a = d.a;
        }
    };

    const GCodec = wire.GroupCodec(GroupMsg, 10);
    var rep_groups = [_]GroupMsg{ .{ .a = 11 }, .{ .a = 22 } };
    const rep = wire.Repeated(GCodec){ .slice = &rep_groups };
    var gbuf: [64]u8 = undefined;
    var grw = wire.ReverseWriter.init(&gbuf);
    try rep.encodeReverse(10, false, &grw);
    const gbytes = grw.written();

    var gr = wire.Reader.init(gbytes);
    const t1 = (try gr.readTag()).?;
    try std.testing.expectEqual(@as(u29, 10), t1.field_number);
    try std.testing.expectEqual(wire.WireType.sgroup, t1.wire_type);
    try std.testing.expectEqual(@as(?i32, 11), (try GCodec.read(&gr, 10)).a);
    const t2 = (try gr.readTag()).?;
    try std.testing.expectEqual(wire.WireType.sgroup, t2.wire_type);
    try std.testing.expectEqual(@as(?i32, 22), (try GCodec.read(&gr, 10)).a);
    try std.testing.expectEqual(@as(?wire.Tag, null), try gr.readTag());

    // Extension + RepeatedExtension over LegacyRecord._unknown_fields
    const ExtTag = wire.Extension(legacy.LegacyRecord, 100, wire.ScalarCodec(.string_utf8));
    const ExtNums = wire.RepeatedExtension(legacy.LegacyRecord, 101, wire.ScalarCodec(.uint32));
    var ext_buf: [128]u8 = undefined;
    const base_rec = legacy.LegacyRecord{ .required_id = 7 };
    const base_bytes = try base_rec.encodeSlice(&ext_buf);

    var tag_buf: [64]u8 = undefined;
    const ext_tag_bytes = try ExtTag.encodeSlice("canary", &tag_buf);

    var combined: [256]u8 = undefined;
    var cw = wire.SliceWriter.init(&combined);
    try cw.writeAll(base_bytes);
    try cw.writeAll(ext_tag_bytes);
    try wire.writeTag(&cw, 101, .len);
    try wire.writeBytes(&cw, &[_]u8{ 3, 9 });
    try wire.writeTag(&cw, 101, .varint);
    try wire.writeVarint(&cw, 27);

    // Extension + RepeatedExtension over LegacyRecord._unknown_fields (both manual & codegen'd)
    const dec_rec = try legacy.LegacyRecord.decode(cw.written());
    try std.testing.expect(try legacy.ext_tag.has(&dec_rec));
    try std.testing.expectEqualStrings("canary", (try legacy.ext_tag.get(&dec_rec)).?);

    var nit = legacy.ext_nums.iterator(&dec_rec);
    try std.testing.expectEqual(@as(?u32, 3), try nit.next());
    try std.testing.expectEqual(@as(?u32, 9), try nit.next());
    try std.testing.expectEqual(@as(?u32, 27), try nit.next());
    try std.testing.expectEqual(@as(?u32, null), try nit.next());

    try std.testing.expectEqualStrings("canary", (try ExtTag.get(&dec_rec)).?);
    var mit = ExtNums.iterator(&dec_rec);
    try std.testing.expectEqual(@as(?u32, 3), try mit.next());
    try std.testing.expectEqual(@as(?u32, 9), try mit.next());
    try std.testing.expectEqual(@as(?u32, 27), try mit.next());
    try std.testing.expectEqual(@as(?u32, null), try mit.next());
}

test "stress: Edition 2023 strict vs NONE UTF-8 validation & explicit presence" {
    const bad_utf8_on_none = editions.EditionConfig{ .raw_non_utf8 = "\xff\xfe\xfd" };
    var buf: [128]u8 = undefined;
    const bytes = try bad_utf8_on_none.encodeSlice(&buf);
    const dec = try editions.EditionConfig.decode(bytes);
    try std.testing.expectEqualStrings("\xff\xfe\xfd", dec.raw_non_utf8.?);

    // Field 2 (strict_utf8 with VERIFY) rejects invalid UTF-8
    var sw = wire.SliceWriter.init(&buf);
    try wire.writeTag(&sw, 2, .len);
    try wire.writeBytes(&sw, "\xff");
    try std.testing.expectError(error.InvalidUtf8, editions.EditionConfig.decode(sw.written()));

    // Edition 2023 DELIMITED message_encoding + LEGACY_REQUIRED enforcement
    try std.testing.expectError(error.MissingRequiredField, editions.EditionStrictChild.decode(""));
    var items = [_]editions.EditionStrictChild{.{ .id = "i1" }};
    const bad_host = editions.EditionDelimitedHost{ .items = .{ .slice = &items } };
    var host_buf: [256]u8 = undefined;
    const host_wire = try bad_host.encodeSlice(&host_buf);
    // Verify DELIMITED wire format emits .sgroup/.egroup on field 2
    var hr = wire.Reader.init(host_wire);
    const htag = (try hr.readTag()).?;
    try std.testing.expectEqual(@as(u29, 2), htag.field_number);
    try std.testing.expectEqual(wire.WireType.sgroup, htag.wire_type);
    const host_dec = try editions.EditionDelimitedHost.decode(host_wire);
    var hit = host_dec.items.iterator();
    try std.testing.expectEqualStrings("i1", (try hit.next()).?.id.?);
    try std.testing.expectEqual(@as(?editions.EditionStrictChild, null), try hit.next());

    // Missing LEGACY_REQUIRED field inside nested DELIMITED child fails decode
    var bad_delim_wire: [32]u8 = undefined;
    var bdw = wire.SliceWriter.init(&bad_delim_wire);
    try wire.writeTag(&bdw, 1, .sgroup);
    try wire.writeTag(&bdw, 1, .egroup);
    try std.testing.expectError(error.MissingRequiredField, editions.EditionDelimitedHost.decode(bdw.written()));
}

test "stress: recursion depth boundary (99 succeeds, 101 fails)" {
    var nodes: [102]base.TreeNode = undefined;
    nodes[0] = .{ .label = "bottom" };
    for (1..102) |i| {
        nodes[i] = .{ .label = "n", .parent = .{ .ptr = &nodes[i - 1] } };
    }
    var buf: [4096]u8 = undefined;
    const ok_bytes = try nodes[98].encodeSlice(&buf);
    _ = try base.TreeNode.decode(ok_bytes);

    const fail_bytes = try nodes[100].encodeSlice(&buf);
    try std.testing.expectError(error.RecursionLimitExceeded, base.TreeNode.decode(fail_bytes));
}

test "stress: gRPC MegaGateway partial handler, assertCompleteUnaryHandler, & keyword RPC method" {
    const PartialHandler = struct {
        pub fn process(_: *@This(), req: v1.MegaEnvelope) !pb.google_protobuf_empty.Empty {
            if (req.max_field_num != 536_870_911) return error.BadField;
            return .{};
        }
    };
    const FullHandler = struct {
        pub fn process(_: *@This(), req: v1.MegaEnvelope) !pb.google_protobuf_empty.Empty {
            if (req.max_field_num != 536_870_911) return error.BadField;
            return .{};
        }
        pub fn checkLegacy(_: *@This(), req: legacy.LegacyRecord) !editions.EditionConfig {
            return .{ .count = @intCast(req.required_id orelse 0) };
        }
        pub fn @"test"(_: *@This(), req: v1.MethodCollision) !v1.Outer {
            _ = req;
            return .{ .shadowed = .{ .from_outer = 5 } };
        }
    };
    comptime protoz.rpc.assertCompleteUnaryHandler(v1.MegaGateway, FullHandler);

    var handler: PartialHandler = .{};
    const req = v1.MegaEnvelope{ .max_field_num = 536_870_911 };
    var req_buf: [64]u8 = undefined;
    var resp_buf: [64]u8 = undefined;
    const req_frame = try protoz.rpc.encodeGrpcSlice(req, &req_buf);
    const resp_frame = try protoz.rpc.dispatchUnaryGrpc(
        v1.MegaGateway,
        &handler,
        "/stress.v1.MegaGateway/Process",
        req_frame,
        1024,
        &resp_buf,
    );
    _ = (try protoz.rpc.tryDecodeGrpc(pb.google_protobuf_empty.Empty, resp_frame, 1024)).?;

    // Unimplemented unary RPC omitted from PartialHandler returns error.Unimplemented cleanly
    const leg_req = legacy.LegacyRecord{ .required_id = 1 };
    const leg_frame = try protoz.rpc.encodeGrpcSlice(leg_req, &req_buf);
    try std.testing.expectError(
        error.Unimplemented,
        protoz.rpc.dispatchUnaryGrpc(v1.MegaGateway, &handler, "/stress.v1.MegaGateway/CheckLegacy", leg_frame, 1024, &resp_buf),
    );
    try std.testing.expectEqual(@as(?v1.MegaGateway.MethodId, .@"test"), v1.MegaGateway.matchPath("/stress.v1.MegaGateway/test"));

    // Streaming gRPC dispatchers + unified dispatchGrpc + assertCompleteHandler on BaseService
    const BaseHandler = struct {
        pub fn ping(_: *@This(), _: base.EmptyMarker) !base.EmptyMarker {
            return .{};
        }
        pub fn upload(_: *@This(), stream: *protoz.rpc.GrpcFrameIterator(base.TreeNode)) !base.EmptyMarker {
            var count: usize = 0;
            while (try stream.next()) |_| count += 1;
            if (count != 2) return error.UnexpectedCount;
            return .{};
        }
        pub fn streamTree(_: *@This(), tree_req: base.TreeNode, out_stream: anytype) !void {
            try out_stream.send(.{ .label = tree_req.label });
            try out_stream.send(.{ .label = "second" });
        }
        pub fn sync(_: *@This(), in_stream: *protoz.rpc.GrpcFrameIterator(base.TreeNode), out_stream: anytype) !void {
            while (try in_stream.next()) |node| {
                try out_stream.send(.{ .label = node.label });
            }
        }
    };
    comptime protoz.rpc.assertCompleteHandler(base.BaseService, BaseHandler);
    var bh: BaseHandler = .{};

    var stream_in_buf: [256]u8 = undefined;
    var sw_in = wire.SliceWriter.init(&stream_in_buf);
    try protoz.rpc.encodeGrpc(base.TreeNode{ .label = "n1" }, &sw_in);
    try protoz.rpc.encodeGrpc(base.TreeNode{ .label = "n2" }, &sw_in);

    var out_buf: [256]u8 = undefined;
    const up_resp = try protoz.rpc.dispatchClientStreamGrpc(base.BaseService, &bh, "/stress.base.BaseService/Upload", sw_in.written(), 1024, &out_buf);
    _ = (try protoz.rpc.tryDecodeGrpc(base.EmptyMarker, up_resp, 1024)).?;

    var one_in_buf: [64]u8 = undefined;
    const one_in = try protoz.rpc.encodeGrpcSlice(base.TreeNode{ .label = "first" }, &one_in_buf);
    var sw_srv = wire.SliceWriter.init(&out_buf);
    try protoz.rpc.dispatchServerStreamGrpc(base.BaseService, &bh, "/stress.base.BaseService/StreamTree", one_in, 1024, &sw_srv);
    var srv_it = protoz.rpc.GrpcFrameIterator(base.TreeNode).init(sw_srv.written(), 1024);
    try std.testing.expectEqualStrings("first", (try srv_it.next()).?.label);
    try std.testing.expectEqualStrings("second", (try srv_it.next()).?.label);
    try std.testing.expectEqual(@as(?base.TreeNode, null), try srv_it.next());

    var bidi_buf: [256]u8 = undefined;
    var sw_bidi = wire.SliceWriter.init(&bidi_buf);
    try protoz.rpc.dispatchGrpc(base.BaseService, &bh, "/stress.base.BaseService/Sync", sw_in.written(), 1024, &sw_bidi);
    var bidi_it = protoz.rpc.GrpcFrameIterator(base.TreeNode).init(sw_bidi.written(), 1024);
    try std.testing.expectEqualStrings("n1", (try bidi_it.next()).?.label);
    try std.testing.expectEqualStrings("n2", (try bidi_it.next()).?.label);
    try std.testing.expectEqual(@as(?base.TreeNode, null), try bidi_it.next());
}
