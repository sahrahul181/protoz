const std = @import("std");
const wire = @import("proto_wire");
const pb = @import("bench_pb");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const codegen = @import("codegen.zig");
const loader = @import("loader.zig");
const plugin = @import("plugin.zig");
const diag_mod = @import("diag.zig");
const ast = @import("ast.zig");

// ---------------------------------------------------------------------------
// Lexer & Parser Tests
// ---------------------------------------------------------------------------

test "lexer: tracks line/column and rejects unterminated block comments" {
    var lx = lexer.Lexer{ .src = "syntax = \"proto3\";\n  message /* unterminated" };

    const t0 = lx.next();
    try std.testing.expectEqual(lexer.TokenKind.ident, t0.kind);
    try std.testing.expectEqual(@as(usize, 1), t0.line);
    try std.testing.expectEqual(@as(usize, 1), t0.col);

    _ = lx.next(); // =
    _ = lx.next(); // "proto3"
    _ = lx.next(); // ;

    const t_msg = lx.next();
    try std.testing.expectEqual(lexer.TokenKind.ident, t_msg.kind);
    try std.testing.expectEqual(@as(usize, 2), t_msg.line);
    try std.testing.expectEqual(@as(usize, 3), t_msg.col);

    const t_bad = lx.next();
    try std.testing.expectEqual(lexer.TokenKind.invalid, t_bad.kind);
}

test "parser: 3-token keyword disambiguation, octal/hex, escapes, qualified options, reserved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\syntax = "proto3";
        \\package acme.v1;
        \\option (acme.mode) = acme.Mode.FAST;
        \\option (acme.banner) = "hello\n" "world\x21";
        \\
        \\message message {}
        \\enum enum { ENUM_ZERO = 0; }
        \\message oneof {}
        \\message reserved {}
        \\message extend {}
        \\
        \\message Carrier {
        \\  reserved 2, 9 to 11;
        \\  reserved "legacy_name";
        \\  message payload = 1;
        \\  enum kind = 010;
        \\  oneof choice = 0x10;
        \\  reserved r = 17;
        \\  extend ext = 18;
        \\}
    ;

    const file = try parser.Parser.parse(arena, src);
    try std.testing.expectEqualStrings("acme.Mode.FAST", file.options[0].raw_value);
    try std.testing.expectEqualStrings("hello\nworld!", file.options[1].raw_value);

    const carrier = file.messages[file.messages.len - 1];
    try std.testing.expectEqual(@as(usize, 5), carrier.fields.len);
    try std.testing.expectEqual(@as(u29, 8), carrier.fields[1].number); // octal 010
    try std.testing.expectEqual(@as(u29, 16), carrier.fields[2].number); // hex 0x10
    try std.testing.expectEqual(@as(usize, 2), carrier.reserved_ranges.len);
    try std.testing.expectEqual(@as(i32, 9), carrier.reserved_ranges[1].start);
    try std.testing.expectEqual(@as(i32, 11), carrier.reserved_ranges[1].end);
    try std.testing.expectEqualStrings("legacy_name", carrier.reserved_names[0]);

    // Full semantic build must succeed on contextual-keyword type names
    _ = try resolver.Resolver.build(arena, &file);
}

// ---------------------------------------------------------------------------
// Resolver Schema Validation, Shadowing & Edition 2023 Tests
// ---------------------------------------------------------------------------

test "resolver: innermost-first-component shadowing stops at inner Bar" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\syntax = "proto3";
        \\message Bar { message Baz { int32 x = 1; } }
        \\message Foo {
        \\  message Bar {}
        \\  Bar.Baz broken = 1;
        \\}
    ;
    const file = try parser.Parser.parse(arena, src);
    try std.testing.expectError(error.UnknownType, resolver.Resolver.build(arena, &file));
}

test "resolver: rejects invalid numbers, reserved collisions, map keys, and enum rules" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = .{
        .{ "syntax = \"proto3\"; message M { int32 a = 19000; }", error.InvalidFieldNumber },
        .{ "syntax = \"proto3\"; message M { reserved 5 to 10; int32 a = 7; }", error.ReservedFieldNumber },
        .{ "syntax = \"proto3\"; message M { reserved \"old\"; int32 old = 1; }", error.ReservedFieldName },
        .{ "syntax = \"proto3\"; message M { int32 a = 1; int32 b = 1; }", error.DuplicateFieldNumber },
        .{ "syntax = \"proto3\"; message M { int32 a = 1; string a = 2; }", error.DuplicateFieldName },
        .{ "syntax = \"proto3\"; message M { map<float, string> bad = 1; }", error.InvalidMapKeyType },
        .{ "syntax = \"proto3\"; message M { map<bytes, int32> bad = 1; }", error.InvalidMapKeyType },
        .{ "syntax = \"proto3\"; enum E { A = 1; }", error.Proto3EnumRequiresZeroFirst },
        .{ "syntax = \"proto3\"; enum E { A = 0; B = 0; }", error.DuplicateEnumValue },
    };

    inline for (cases) |c| {
        const file = try parser.Parser.parse(arena, c[0]);
        try std.testing.expectError(c[1], resolver.Resolver.build(arena, &file));
    }
}

test "resolver + codegen: Edition 2023 defaults, feature overrides, keyword paths, and oneof collision" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\edition = "2023";
        \\
        \\enum error {
        \\  option allow_alias = true;
        \\  OK = 0;
        \\  NONE = 0;
        \\}
        \\
        \\message union {
        \\  int32 code = 1;
        \\}
        \\
        \\message Envelope {
        \\  message Value { int32 v = 1; }
        \\  int32 explicit_by_default = 1;
        \\  int32 implicit_override = 2 [features.field_presence = IMPLICIT];
        \\  string utf8_by_default = 3;
        \\  string raw_string = 4 [features.utf8_validation = NONE];
        \\  repeated int32 expanded_nums = 5 [features.repeated_field_encoding = EXPANDED];
        \\  error status = 6;
        \\  union detail = 7;
        \\  oneof value {
        \\    string text = 8;
        \\    Value wrapped = 9;
        \\  }
        \\}
    ;

    const file = try parser.Parser.parse(arena, src);
    const res = try resolver.Resolver.build(arena, &file);

    const env = file.messages[1];
    try std.testing.expect(res.hasExplicitPresence(0, env.options, env.fields[0], .{ .scalar = resolver.lookupScalar("int32").? }));
    try std.testing.expect(!res.hasExplicitPresence(0, env.options, env.fields[1], .{ .scalar = resolver.lookupScalar("int32").? }));
    try std.testing.expect(res.validatesUtf8(0, env.options, env.fields[2].options));
    try std.testing.expect(!res.validatesUtf8(0, env.options, env.fields[3].options));
    try std.testing.expect(!res.isPacked(0, env.options, env.fields[4]));

    var out: std.Io.Writer.Allocating = .init(arena);
    try codegen.generateFile(arena, 0, &res, &out.writer);
    const gen = out.written();

    // Keyword escaping in declarations and referenced type paths
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const @\"error\" = enum(i32)") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const NONE: @This() = .OK;") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "status: ?@\"error\" = null,") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "detail: ?@\"union\" = null,") != null);
    // Edition presence + UTF-8 codec selection
    try std.testing.expect(std.mem.indexOf(u8, gen, "explicit_by_default: ?i32 = null,") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "implicit_override: i32 = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "wire.ScalarCodec(.string_utf8)") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "wire.ScalarCodec(.string)") != null);
    // Oneof / nested-message collision disambiguation
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const ValueOneof = union(enum)") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "value: ?@This().ValueOneof = null,") != null);
}

// ---------------------------------------------------------------------------
// Loader Path Normalization & protoc-gen-zig Plugin Protocol Tests
// ---------------------------------------------------------------------------

test "loader: normalizes separators, dot segments, and Windows drive casing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("a/b/d", try loader.Loader.normalizePath(arena, "a\\b\\./c/../d/"));
    try std.testing.expectEqualStrings("C:/Users/bar", try loader.Loader.normalizePath(arena, "c:\\Users\\foo\\..\\bar"));
    try std.testing.expectEqualStrings(".", try loader.Loader.normalizePath(arena, "./"));
}

test "plugin: decodes CodeGeneratorRequest with allow_alias, map_entry, and proto3_optional" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // EnumDescriptorProto: Kind { option allow_alias = true; A = 0; B = 0; }
    var enum_desc: std.Io.Writer.Allocating = .init(arena);
    {
        const w = &enum_desc.writer;
        try wire.writeTag(w, 1, .len);
        try wire.writeBytes(w, "Kind");

        inline for (.{ "A", "B" }) |vname| {
            var ev: std.Io.Writer.Allocating = .init(arena);
            try wire.writeTag(&ev.writer, 1, .len);
            try wire.writeBytes(&ev.writer, vname);
            try wire.writeTag(&ev.writer, 2, .varint);
            try wire.writeVarint(&ev.writer, 0);
            try wire.writeTag(w, 2, .len);
            try wire.writeBytes(w, ev.written());
        }

        // EnumOptions { allow_alias = true } (field 2 = 1)
        var eopts: std.Io.Writer.Allocating = .init(arena);
        try wire.writeTag(&eopts.writer, 2, .varint);
        try wire.writeVarint(&eopts.writer, 1);
        try wire.writeTag(w, 3, .len);
        try wire.writeBytes(w, eopts.written());
    }

    // FileDescriptorProto: demo/kind.proto
    var fd: std.Io.Writer.Allocating = .init(arena);
    {
        const w = &fd.writer;
        try wire.writeTag(w, 1, .len);
        try wire.writeBytes(w, "demo/kind.proto");
        try wire.writeTag(w, 2, .len);
        try wire.writeBytes(w, "demo");
        try wire.writeTag(w, 5, .len);
        try wire.writeBytes(w, enum_desc.written());
        try wire.writeTag(w, 12, .len);
        try wire.writeBytes(w, "proto3");
    }

    var req: std.Io.Writer.Allocating = .init(arena);
    try wire.writeTag(&req.writer, 1, .len);
    try wire.writeBytes(&req.writer, "demo/kind.proto");
    try wire.writeTag(&req.writer, 15, .len);
    try wire.writeBytes(&req.writer, fd.written());

    const resp = try plugin.processRequest(arena, req.written());
    var r = wire.Reader.init(resp);
    var gen_name: []const u8 = "";
    var gen_content: []const u8 = "";
    while (try r.readTag()) |tag| {
        switch (tag.field_number) {
            1 => return error.UnexpectedPluginError,
            2 => try std.testing.expectEqual(plugin.feature_proto3_optional | plugin.feature_supports_editions, try r.readVarint()),
            3 => try std.testing.expectEqual(@as(i64, plugin.edition_proto2), @as(i64, @bitCast(try r.readVarint()))),
            4 => try std.testing.expectEqual(@as(i64, plugin.edition_2023), @as(i64, @bitCast(try r.readVarint()))),
            15 => {
                var fr = wire.Reader.init(try r.readBytes());
                while (try fr.readTag()) |ft| {
                    switch (ft.field_number) {
                        1 => gen_name = try fr.readBytes(),
                        15 => gen_content = try fr.readBytes(),
                        else => try fr.skipField(ft, wire.max_recursion_depth),
                    }
                }
            },
            else => try r.skipField(tag, wire.max_recursion_depth),
        }
    }

    try std.testing.expectEqualStrings("demo/kind.pb.zig", gen_name);
    try std.testing.expect(std.mem.indexOf(u8, gen_content, "pub const B: @This() = .A;") != null);
}

// ---------------------------------------------------------------------------
// Wire Conformance Edge Cases (Multi-Chunk, Lazy Merge, Map Merge, Varints)
// ---------------------------------------------------------------------------

test "wire: disjoint 2-chunk submessage merge preserves repeated and map fields" {
    var b1: [128]u8 = undefined;
    const c1 = try (pb.UserProfile{
        .id = 7,
        .scores = .{ .slice = &.{ 1, 2 } },
        .quotas = .{ .slice = &.{.{ .key = "a", .value = 10 }} },
    }).encodeSlice(&b1);

    var b2: [128]u8 = undefined;
    const c2 = try (pb.UserProfile{
        .name = "lead",
        .scores = .{ .slice = &.{3} },
        .quotas = .{ .slice = &.{
            .{ .key = "b", .value = 20 },
            .{ .key = "a", .value = 99 },
        } },
    }).encodeSlice(&b2);

    var merged: pb.UserProfile = .{};
    try merged.mergeDepth(c1, wire.max_recursion_depth);
    try merged.mergeDepth(c2, wire.max_recursion_depth);

    try std.testing.expectEqual(@as(u64, 7), merged.id);
    try std.testing.expectEqualStrings("lead", merged.name);

    var it = merged.scores.iterator();
    try std.testing.expectEqual(@as(?u32, 1), try it.next());
    try std.testing.expectEqual(@as(?u32, 2), try it.next());
    try std.testing.expectEqual(@as(?u32, 3), try it.next());
    try std.testing.expectEqual(@as(?u32, null), try it.next());

    try std.testing.expectEqual(@as(?i32, 99), try merged.quotas.get("a"));
    try std.testing.expectEqual(@as(?i32, 20), try merged.quotas.get("b"));
}

test "wire: same-buffer multi-occurrence cyclic Lazy merges and re-encodes without panicking" {
    var sub1_buf: [64]u8 = undefined;
    const sub1 = try (pb.UserProfile{ .id = 7, .scores = .{ .slice = &.{10} } }).encodeSlice(&sub1_buf);
    var sub2_buf: [64]u8 = undefined;
    const sub2 = try (pb.UserProfile{ .name = "lead", .scores = .{ .slice = &.{20} } }).encodeSlice(&sub2_buf);
    var sub3_buf: [64]u8 = undefined;
    const sub3 = try (pb.UserProfile{ .role = .ROLE_ADMIN }).encodeSlice(&sub3_buf);

    var parent_buf: [256]u8 = undefined;
    var sw = wire.SliceWriter.init(&parent_buf);
    for ([_][]const u8{ sub1, sub2, sub3 }) |chunk| {
        try wire.writeTag(&sw, 11, .len);
        try wire.writeBytes(&sw, chunk);
    }

    const parent = try pb.UserProfile.decode(sw.written());
    const mgr = try parent.manager.?.decode();
    try std.testing.expectEqual(@as(u64, 7), mgr.id);
    try std.testing.expectEqualStrings("lead", mgr.name);
    try std.testing.expectEqual(pb.Role.ROLE_ADMIN, mgr.role);

    var sit = mgr.scores.iterator();
    try std.testing.expectEqual(@as(?u32, 10), try sit.next());
    try std.testing.expectEqual(@as(?u32, 20), try sit.next());
    try std.testing.expectEqual(@as(?u32, null), try sit.next());

    // Re-encoding a Lazy.wire with 3 occurrences must match forward & reverse byte-for-byte
    var rev_buf: [256]u8 = undefined;
    var fwd_buf: [256]u8 = undefined;
    const rev = try parent.encodeSlice(&rev_buf);
    var fwd_sw = wire.SliceWriter.init(&fwd_buf);
    try parent.encode(&fwd_sw);
    try std.testing.expectEqualSlices(u8, rev, fwd_sw.written());
}

test "wire: duplicate message values inside a map entry merge instead of overwriting" {
    const AddrMap = wire.Map(wire.ScalarCodec(.string_utf8), wire.MessageCodec(pb.UserProfile.Address));

    var a1_buf: [32]u8 = undefined;
    const a1 = try (pb.UserProfile.Address{ .city = "Delhi" }).encodeSlice(&a1_buf);
    var a2_buf: [32]u8 = undefined;
    const a2 = try (pb.UserProfile.Address{ .zip = 110001 }).encodeSlice(&a2_buf);

    var entry_buf: [128]u8 = undefined;
    var esw = wire.SliceWriter.init(&entry_buf);
    try wire.writeTag(&esw, 1, .len);
    try wire.writeBytes(&esw, "hq");
    try wire.writeTag(&esw, 2, .len);
    try wire.writeBytes(&esw, a1);
    try wire.writeTag(&esw, 2, .len);
    try wire.writeBytes(&esw, a2);

    var outer_buf: [160]u8 = undefined;
    var osw = wire.SliceWriter.init(&outer_buf);
    try wire.writeTag(&osw, 6, .len);
    try wire.writeBytes(&osw, esw.written());

    const m = AddrMap{ .wire = .{ .buf = osw.written(), .field_number = 6 } };
    const got = (try m.get("hq")).?;
    try std.testing.expectEqualStrings("Delhi", got.city);
    try std.testing.expectEqual(@as(u32, 110001), got.zip);
}

test "wire: accepts non-canonical 10-byte varints (MSB clear) and masks bit 63" {
    const low_bit_clear = [_]u8{ 0x08, 0x81, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 };
    const low_bit_set = [_]u8{ 0x08, 0x81, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x03 };

    try pb.SmallEvent.validateDepth(&low_bit_clear, wire.max_recursion_depth);
    try std.testing.expectEqual(@as(u64, 1), (try pb.SmallEvent.decode(&low_bit_clear)).id);

    try pb.SmallEvent.validateDepth(&low_bit_set, wire.max_recursion_depth);
    try std.testing.expectEqual((@as(u64, 1) << 63) | 1, (try pb.SmallEvent.decode(&low_bit_set)).id);
}

test "parser: populates file:line:col diagnostic on syntax error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diag: diag_mod.Diagnostic = .{};
    const bad = "syntax = \"proto3\";\nmessage Broken {\n  int32 x = ;\n}\n";
    try std.testing.expectError(
        error.UnexpectedToken,
        parser.Parser.parseWithDiag(arena, "broken.proto", bad, &diag),
    );
    try std.testing.expectEqualStrings("broken.proto", diag.file);
    try std.testing.expectEqual(@as(usize, 3), diag.line);
    try std.testing.expectEqual(@as(usize, 13), diag.col);
}

test "resolver: populates file and message diagnostic on semantic error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var file = try parser.Parser.parse(arena, "syntax = \"proto3\"; message Order { Missing item = 1; }");
    file.name = "acme/order.proto";

    var diag: diag_mod.Diagnostic = .{};
    try std.testing.expectError(
        error.UnknownType,
        resolver.Resolver.buildMultiWithDiag(arena, (&file)[0..1], &diag),
    );
    try std.testing.expectEqualStrings("acme/order.proto", diag.file);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "Missing") != null);
}

test "codegen: emits transitive import public re-exports" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f_leaf = try parser.Parser.parse(arena, "syntax = \"proto3\"; message Leaf { int32 v = 1; }");
    f_leaf.name = "leaf.proto";

    var f_mid = try parser.Parser.parse(arena, "syntax = \"proto3\"; import public \"leaf.proto\"; enum MidEnum { MID_ZERO = 0; }");
    f_mid.name = "mid.proto";

    var f_top = try parser.Parser.parse(arena, "syntax = \"proto3\"; import public \"mid.proto\"; message Top { Leaf leaf = 1; }");
    f_top.name = "top.proto";

    const files = [_]ast.File{ f_leaf, f_mid, f_top };
    const res = try resolver.Resolver.buildMulti(arena, &files);

    var out: std.Io.Writer.Allocating = .init(arena);
    try codegen.generateFile(arena, 2, &res, &out.writer);
    const gen = out.written();

    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const MidEnum = _imp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const Leaf = _imp_") != null);
}

test "plugin: honors wire_import and root_file parameters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fd: std.Io.Writer.Allocating = .init(arena);
    try wire.writeTag(&fd.writer, 1, .len);
    try wire.writeBytes(&fd.writer, "pkg/item.proto");
    try wire.writeTag(&fd.writer, 12, .len);
    try wire.writeBytes(&fd.writer, "proto3");

    var req: std.Io.Writer.Allocating = .init(arena);
    try wire.writeTag(&req.writer, 1, .len);
    try wire.writeBytes(&req.writer, "pkg/item.proto");
    try wire.writeTag(&req.writer, 2, .len);
    try wire.writeBytes(&req.writer, "wire_import=custom_wire,root_file=root.zig");
    try wire.writeTag(&req.writer, 15, .len);
    try wire.writeBytes(&req.writer, fd.written());

    const resp = try plugin.processRequest(arena, req.written());
    var r = wire.Reader.init(resp);
    var saw_item = false;
    var saw_root = false;
    while (try r.readTag()) |tag| {
        if (tag.field_number != 15) {
            try r.skipField(tag, wire.max_recursion_depth);
            continue;
        }
        var fr = wire.Reader.init(try r.readBytes());
        var name: []const u8 = "";
        var content: []const u8 = "";
        while (try fr.readTag()) |ft| {
            switch (ft.field_number) {
                1 => name = try fr.readBytes(),
                15 => content = try fr.readBytes(),
                else => try fr.skipField(ft, wire.max_recursion_depth),
            }
        }
        if (std.mem.eql(u8, name, "pkg/item.pb.zig")) {
            saw_item = true;
            try std.testing.expect(std.mem.indexOf(u8, content, "const wire = @import(\"custom_wire\");") != null);
        } else if (std.mem.eql(u8, name, "root.zig")) {
            saw_root = true;
            try std.testing.expect(std.mem.indexOf(u8, content, "pub const pkg_item = @import(\"pkg/item.pb.zig\");") != null);
        }
    }
    try std.testing.expect(saw_item and saw_root);
}

// ---------------------------------------------------------------------------
// Length-Delimited Framing & `{f}` Debug Formatting Tests
// ---------------------------------------------------------------------------

test "wire: length-delimited framing round-trip, streaming partial reads, and FrameTooLarge" {
    const e1 = pb.SmallEvent{ .id = 1, .status = 200, .source = "gw-1" };
    const e2 = pb.SmallEvent{ .id = 2, .status = 404, .source = "gw-2" };
    const e3 = pb.SmallEvent{}; // zero-length empty frame

    var stream_buf: [256]u8 = undefined;
    var sw = wire.SliceWriter.init(&stream_buf);

    // Mix reverse-encoded frame and forward-encoded frames into one contiguous stream
    var f1_buf: [64]u8 = undefined;
    const f1 = try wire.encodeDelimitedSlice(e1, &f1_buf);
    try std.testing.expectEqual(wire.encodedDelimitedSize(e1), f1.len);
    try sw.writeAll(f1);
    try wire.encodeDelimited(e2, &sw);
    try wire.encodeDelimited(e3, &sw);

    const stream = sw.written();

    // Streaming partial-buffer checks: every prefix shorter than frame 1 returns null
    try std.testing.expectEqual(@as(?wire.DelimitedFrame(pb.SmallEvent), null), try wire.tryDecodeDelimited(pb.SmallEvent, "", 1024));
    for (1..f1.len) |partial_len| {
        try std.testing.expectEqual(
            @as(?wire.DelimitedFrame(pb.SmallEvent), null),
            try wire.tryDecodeDelimited(pb.SmallEvent, stream[0..partial_len], 1024),
        );
    }

    // Reject oversized frames before waiting for full body
    try std.testing.expectError(
        error.FrameTooLarge,
        wire.tryDecodeDelimited(pb.SmallEvent, stream, 4),
    );

    // Partial multi-byte varint length prefix returns null (need more bytes), not error
    const partial_varint = [_]u8{0x80};
    try std.testing.expectEqual(
        @as(?wire.DelimitedFrame(pb.SmallEvent), null),
        try wire.tryDecodeDelimited(pb.SmallEvent, &partial_varint, 1024),
    );

    // Full sequential iteration via DelimitedIterator
    var it = wire.DelimitedIterator(pb.SmallEvent).init(stream);
    const d1 = (try it.next()).?;
    const d2 = (try it.next()).?;
    const d3 = (try it.next()).?;
    try std.testing.expectEqual(@as(?pb.SmallEvent, null), try it.next());

    try std.testing.expectEqual(@as(u64, 1), d1.id);
    try std.testing.expectEqualStrings("gw-1", d1.source);
    try std.testing.expectEqual(@as(u64, 2), d2.id);
    try std.testing.expectEqual(@as(u32, 404), d2.status);
    try std.testing.expectEqual(@as(u64, 0), d3.id);
}

test "wire: zero-allocation {f} formatting prints structs, repeated, maps, oneofs, Lazy, and open enums" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mgr = pb.UserProfile{
        .id = 9,
        .name = "lead",
        .role = @fromBackingInt(77), // unknown open enum value -> prints numeric 77
    };
    const user = pb.UserProfile{
        .id = 42,
        .name = "alice\n",
        .role = .ROLE_ADMIN,
        .scores = .{ .slice = &.{ 10, 20 } },
        .quotas = .{ .slice = &.{.{ .key = "cpu", .value = 8 }} },
        .contact = .{ .email = "a@b.dev" },
        .manager = .{ .ptr = &mgr },
    };

    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("{f}", .{user});
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "id: 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "name: \"alice\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "role: ROLE_ADMIN") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "scores: [10, 20]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "quotas: {\"cpu\": 8}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "contact: { email: \"a@b.dev\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "role: 77") != null);
}

// ---------------------------------------------------------------------------
// On-Demand Tests: Comptime `decodeOnly` & Streaming `FieldIterator`
// ---------------------------------------------------------------------------

test "on-demand: decodeOnly projects minimal stack struct and skips unselected fields" {
    const mgr = pb.UserProfile{ .id = 1, .name = "cto", .role = .ROLE_ADMIN };
    const full = pb.UserProfile{
        .id = 9_876_543_210,
        .name = "alice",
        .role = .ROLE_MEMBER,
        .scores = .{ .slice = &.{ 10, 20, 30 } },
        .tags = .{ .slice = &.{ "zig", "protoz" } },
        .quotas = .{ .slice = &.{.{ .key = "ram", .value = 64 }} },
        .address = .{ .city = "Gurugram", .zip = 122001 },
        .verified = true,
        .contact = .{ .email = "alice@acme.dev" },
        .manager = .{ .ptr = &mgr },
    };

    var buf: [512]u8 = undefined;
    const encoded = try full.encodeSlice(&buf);

    // 1. Tiny scalar projection: only `id` (u64) + `role` (Role = i32) -> 16 bytes
    const routing = try pb.UserProfile.decodeOnly(encoded, .{ .id, .role });
    try std.testing.expect(@sizeOf(@TypeOf(routing)) <= 16);
    try std.testing.expectEqual(@as(u64, 9_876_543_210), routing.id);
    try std.testing.expectEqual(pb.Role.ROLE_MEMBER, routing.role);

    // 2. Projection with containers + oneof + nested submessage
    const partial = try pb.UserProfile.decodeOnly(encoded, .{ .scores, .address, .contact });
    try std.testing.expectEqualStrings("Gurugram", partial.address.?.city);
    try std.testing.expectEqualStrings("alice@acme.dev", partial.contact.?.email);
    var sit = partial.scores.iterator();
    try std.testing.expectEqual(@as(?u32, 10), try sit.next());
    try std.testing.expectEqual(@as(?u32, 20), try sit.next());
    try std.testing.expectEqual(@as(?u32, 30), try sit.next());
    try std.testing.expectEqual(@as(?u32, null), try sit.next());

    // 3. Unselected field with invalid UTF-8 is skipped cleanly without failing `decodeOnly`
    const bad_name_good_id = [_]u8{
        0x08, 0x2A, // field 1 (`id`) = 42
        0x12, 0x02, 0xFF, 0xFE, // field 2 (`name`) = invalid UTF-8 (unselected)
    };
    const ok_proj = try pb.UserProfile.decodeOnly(&bad_name_good_id, .{.id});
    try std.testing.expectEqual(@as(u64, 42), ok_proj.id);
    try std.testing.expectError(error.InvalidUtf8, pb.UserProfile.decodeOnly(&bad_name_good_id, .{.name}));

    // 4. Wire-type mismatch on a SELECTED field still returns WireTypeMismatch
    const bad_id_wt = [_]u8{ (1 << 3) | 2, 0x01, 0xAA };
    try std.testing.expectError(error.WireTypeMismatch, pb.UserProfile.decodeOnly(&bad_id_wt, .{.id}));
}

test "on-demand: FieldIterator streams packed/unpacked, maps, oneofs, lazy submessages, and unknowns" {
    // Wire buffer with: id=7, packed scores=[1,2], unpacked score=3, map quota=("cpu", 8),
    // nested address, oneof phone, and unknown field 99 = varint 55.
    var buf: [256]u8 = undefined;
    var sw = wire.SliceWriter.init(&buf);

    try wire.writeTag(&sw, 1, .varint);
    try wire.writeVarint(&sw, 7);

    // Packed scores [1, 2]
    try wire.writeTag(&sw, 4, .len);
    try wire.writeBytes(&sw, &.{ 1, 2 });
    // Unpacked score 3
    try wire.writeTag(&sw, 4, .varint);
    try wire.writeVarint(&sw, 3);

    // Map entry: key="cpu", value=8
    var entry_buf: [32]u8 = undefined;
    var esw = wire.SliceWriter.init(&entry_buf);
    try wire.writeTag(&esw, 1, .len);
    try wire.writeBytes(&esw, "cpu");
    try wire.writeTag(&esw, 2, .varint);
    try wire.writeVarint(&esw, 8);
    try wire.writeTag(&sw, 6, .len);
    try wire.writeBytes(&sw, esw.written());

    // Address submessage
    var addr_buf: [32]u8 = undefined;
    const addr_raw = try (pb.UserProfile.Address{ .city = "Delhi", .zip = 110001 }).encodeSlice(&addr_buf);
    try wire.writeTag(&sw, 7, .len);
    try wire.writeBytes(&sw, addr_raw);

    // Oneof phone (field 10)
    try wire.writeTag(&sw, 10, .len);
    try wire.writeBytes(&sw, "+91-555");

    // Unknown field 99 = varint 55
    try wire.writeTag(&sw, 99, .varint);
    try wire.writeVarint(&sw, 55);

    var it = pb.UserProfile.fieldIterator(sw.written());
    var id: u64 = 0;
    var score_sum: u32 = 0;
    var quota_cpu: i32 = 0;
    var city: []const u8 = "";
    var phone: []const u8 = "";
    var saw_unknown = false;

    while (try it.next()) |item| switch (item) {
        .id => |v| id = v,
        .scores => |chunk| {
            var cit = chunk.iterator();
            while (try cit.next()) |s| score_sum += s;
        },
        .quotas => |entry| {
            if (std.mem.eql(u8, entry.key, "cpu")) quota_cpu = entry.value;
        },
        .address => |raw| {
            const addr = try pb.UserProfile.Address.decode(raw);
            city = addr.city;
        },
        .phone => |p| phone = p,
        .unknown => |u| {
            try std.testing.expectEqual(@as(u29, 99), u.field_number);
            try std.testing.expectEqual(wire.WireType.varint, u.wire_type);
            saw_unknown = true;
        },
        else => {},
    };

    try std.testing.expectEqual(@as(u64, 7), id);
    try std.testing.expectEqual(@as(u32, 6), score_sum);
    try std.testing.expectEqual(@as(i32, 8), quota_cpu);
    try std.testing.expectEqualStrings("Delhi", city);
    try std.testing.expectEqualStrings("+91-555", phone);
    try std.testing.expect(saw_unknown);
}

// ---------------------------------------------------------------------------
// Owned Escape Hatch (`cloneOwned` / `cloneInto`) Tests
// ---------------------------------------------------------------------------

test "wire: cloneOwned detaches all views from source buffer and frees cleanly" {
    const mgr = pb.UserProfile{
        .id = 1,
        .name = "cto-lead",
        .role = .ROLE_ADMIN,
        .tags = .{ .slice = &.{"exec"} },
    };
    const orig = pb.UserProfile{
        .id = 42,
        .name = "alice",
        .role = .ROLE_MEMBER,
        .scores = .{ .slice = &.{ 10, 20, 30 } },
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

    var wire_buf: [512]u8 = undefined;
    const encoded = try orig.encodeSlice(&wire_buf);
    const view = try pb.UserProfile.decode(encoded);

    var owned = try view.cloneOwned(std.testing.allocator);
    defer owned.deinit();

    // Clobber the original wire buffer to guarantee zero dangling slices/views
    @memset(&wire_buf, 0xAA);

    const v = owned.value;
    try std.testing.expectEqual(@as(u64, 42), v.id);
    try std.testing.expectEqualStrings("alice", v.name);
    try std.testing.expectEqual(pb.Role.ROLE_MEMBER, v.role);
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, v.scores.slice);
    try std.testing.expectEqual(@as(usize, 2), v.tags.slice.len);
    try std.testing.expectEqualStrings("zig", v.tags.slice[0]);
    try std.testing.expectEqualStrings("protoz", v.tags.slice[1]);
    try std.testing.expectEqual(@as(?i32, 64), try v.quotas.get("ram"));
    try std.testing.expectEqualStrings("Gurugram", v.address.?.city);
    try std.testing.expectEqualStrings("alice@acme.dev", v.contact.?.email);

    const cloned_mgr = try v.manager.?.decode();
    try std.testing.expectEqual(@as(u64, 1), cloned_mgr.id);
    try std.testing.expectEqualStrings("cto-lead", cloned_mgr.name);
    try std.testing.expectEqualStrings("exec", cloned_mgr.tags.slice[0]);

    // Cloned message re-encodes cleanly
    var re_buf: [512]u8 = undefined;
    const re_enc = try v.encodeSlice(&re_buf);
    try pb.UserProfile.validateDepth(re_enc, wire.max_recursion_depth);
}

test "wire: cloneInto materializes directly into caller-owned arena" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var buf: [64]u8 = undefined;
    const encoded = try (pb.SmallEvent{ .id = 99, .source = "edge-01" }).encodeSlice(&buf);
    const view = try pb.SmallEvent.decode(encoded);

    const cloned = try view.cloneInto(arena_state.allocator());
    @memset(&buf, 0x55);

    try std.testing.expectEqual(@as(u64, 99), cloned.id);
    try std.testing.expectEqualStrings("edge-01", cloned.source);
}
// ---------------------------------------------------------------------------
// Opt-In Unknown-Field Preservation Tests
// ---------------------------------------------------------------------------

test "wire: UnknownFields preserves contiguous, interleaved, and disjoint spans with exact parity" {
    const known = [_]u29{ 1, 2 };

    // 1. Contiguous unknown fields stay in `.raw` (O(1) re-encode)
    var contig_buf: [64]u8 = undefined;
    var csw = wire.SliceWriter.init(&contig_buf);
    const u1_start = csw.pos;
    try wire.writeTag(&csw, 90, .varint);
    try wire.writeVarint(&csw, 123);
    const u1_end = csw.pos;
    try wire.writeTag(&csw, 91, .len);
    try wire.writeBytes(&csw, "future");
    const u2_end = csw.pos;

    var uf_raw: wire.UnknownFields = .empty;
    try uf_raw.record(contig_buf[0..].ptr, contig_buf[u1_start..].ptr, contig_buf[u1_end..].ptr);
    try uf_raw.record(contig_buf[0..].ptr, contig_buf[u1_end..].ptr, contig_buf[u2_end..].ptr);
    try std.testing.expect(uf_raw == .raw);
    try std.testing.expectEqual(u2_end - u1_start, uf_raw.encodedSize(&known));

    // 2. Interleaved unknown + known + unknown promotes to `.window` and filters known tags
    var mix_buf: [128]u8 = undefined;
    var msw = wire.SliceWriter.init(&mix_buf);
    const m_u1_s = msw.pos;
    try wire.writeTag(&msw, 90, .varint);
    try wire.writeVarint(&msw, 77);
    const m_u1_e = msw.pos;
    // Known field 1 (must be filtered out when re-encoding unknown fields)
    try wire.writeTag(&msw, 1, .varint);
    try wire.writeVarint(&msw, 999);
    const m_u2_s = msw.pos;
    try wire.writeTag(&msw, 92, .len);
    try wire.writeBytes(&msw, "v2");
    const m_u2_e = msw.pos;

    var uf_win: wire.UnknownFields = .empty;
    try uf_win.record(mix_buf[0..].ptr, mix_buf[m_u1_s..].ptr, mix_buf[m_u1_e..].ptr);
    try uf_win.record(mix_buf[0..].ptr, mix_buf[m_u2_s..].ptr, mix_buf[m_u2_e..].ptr);
    try std.testing.expect(uf_win == .window);

    // 3. Disjoint 2nd buffer promotes to `.chunks` and preserves order
    var extra_buf: [32]u8 = undefined;
    var esw = wire.SliceWriter.init(&extra_buf);
    try wire.writeTag(&esw, 95, .i32);
    try wire.writeFixed32(&esw, 0xCAFEBABE);
    const extra_span = esw.written();

    try uf_win.record(extra_buf[0..].ptr, extra_span.ptr, extra_span.ptr + extra_span.len);
    try std.testing.expect(uf_win == .chunks);

    // Forward encode vs Reverse encode must match byte-for-byte
    var fwd_buf: [128]u8 = undefined;
    var fwd_sw = wire.SliceWriter.init(&fwd_buf);
    try uf_win.encode(&known, &fwd_sw);

    var rev_buf: [128]u8 = undefined;
    var rw = wire.ReverseWriter.init(&rev_buf);
    try uf_win.encodeReverse(&known, &rw);

    try std.testing.expectEqual(uf_win.encodedSize(&known), fwd_sw.written().len);
    try std.testing.expectEqualSlices(u8, fwd_sw.written(), rw.written());

    // Iterator yields 90, 92, 95 (skipping known field 1)
    var it = uf_win.iterator(&known);
    try std.testing.expectEqual(@as(u29, 90), (try it.next()).?.field_number);
    const second = (try it.next()).?;
    try std.testing.expectEqual(@as(u29, 92), second.field_number);
    try std.testing.expectEqualStrings("v2", second.bytes);
    try std.testing.expectEqual(@as(u29, 95), (try it.next()).?.field_number);
    try std.testing.expectEqual(@as(?wire.UnknownField, null), try it.next());

    // cloneCompact detaches from source buffers into a flat `.raw` slice
    const compact = try uf_win.cloneCompact(std.testing.allocator, &known);
    defer std.testing.allocator.free(compact.raw);
    @memset(&mix_buf, 0xAA);
    @memset(&extra_buf, 0x55);
    try std.testing.expectEqualSlices(u8, fwd_sw.written(), compact.raw);
}

test "codegen + plugin: preserve_unknown_fields is strictly opt-in" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src = "syntax = \"proto3\"; message Ping { uint64 id = 1; }";
    const file = try parser.Parser.parse(arena, src);
    const res = try resolver.Resolver.build(arena, &file);

    var default_out: std.Io.Writer.Allocating = .init(arena);
    try codegen.generateFileWithOptions(arena, 0, &res, &default_out.writer, .{});
    try std.testing.expect(std.mem.indexOf(u8, default_out.written(), "_unknown_fields") == null);

    var optin_out: std.Io.Writer.Allocating = .init(arena);
    try codegen.generateFileWithOptions(arena, 0, &res, &optin_out.writer, .{ .preserve_unknown_fields = true });
    const gen = optin_out.written();
    try std.testing.expect(std.mem.indexOf(u8, gen, "_unknown_fields: wire.UnknownFields = .empty,") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const _protoz_known_fields: []const u29 = &.{ 1 };") != null);

    // Plugin parameter `preserve_unknown_fields=true`
    var fd: std.Io.Writer.Allocating = .init(arena);
    try wire.writeTag(&fd.writer, 1, .len);
    try wire.writeBytes(&fd.writer, "proxy/ping.proto");
    try wire.writeTag(&fd.writer, 12, .len);
    try wire.writeBytes(&fd.writer, "proto3");

    var req: std.Io.Writer.Allocating = .init(arena);
    try wire.writeTag(&req.writer, 1, .len);
    try wire.writeBytes(&req.writer, "proxy/ping.proto");
    try wire.writeTag(&req.writer, 2, .len);
    try wire.writeBytes(&req.writer, "preserve_unknown_fields=true");
    try wire.writeTag(&req.writer, 15, .len);
    try wire.writeBytes(&req.writer, fd.written());

    const resp = try plugin.processRequest(arena, req.written());
    try std.testing.expect(std.mem.indexOf(u8, resp, "wire.UnknownFields") == null or std.mem.indexOf(u8, resp, "proxy/ping.pb.zig") != null);
}

// ---------------------------------------------------------------------------
// Phase 4: Zero-Allocation Well-Known Type Helper Tests
// ---------------------------------------------------------------------------

test "wkt: Timestamp RFC 3339 parse/format, leap years, offsets, and epoch math" {
    const Ts = struct { seconds: i64 = 0, nanos: i32 = 0 };
    const Dur = struct { seconds: i64 = 0, nanos: i32 = 0 };

    var buf: [32]u8 = undefined;

    // Boundary min & max dates
    const min_ts = try wire.wkt.parseTimestamp(Ts, "0001-01-01T00:00:00Z");
    try std.testing.expectEqual(wire.wkt.min_timestamp_seconds, min_ts.seconds);
    try std.testing.expectEqualStrings("0001-01-01T00:00:00Z", try wire.wkt.formatTimestampBuf(min_ts, &buf));

    const max_ts = try wire.wkt.parseTimestamp(Ts, "9999-12-31T23:59:59.999999999Z");
    try std.testing.expectEqual(wire.wkt.max_timestamp_seconds, max_ts.seconds);
    try std.testing.expectEqualStrings("9999-12-31T23:59:59.999999999Z", try wire.wkt.formatTimestampBuf(max_ts, &buf));

    // Canonical 3 / 6 / 9 fractional digit precision + timezone offset normalization (+05:30 IST)
    const ist = try wire.wkt.parseTimestamp(Ts, "2026-11-25T20:11:00.5+05:30");
    try std.testing.expectEqualStrings("2026-11-25T14:41:00.500Z", try wire.wkt.formatTimestampBuf(ist, &buf));

    const micros = try wire.wkt.parseTimestamp(Ts, "2024-02-29t12:00:00.000123z"); // leap day
    try std.testing.expectEqualStrings("2024-02-29T12:00:00.000123Z", try wire.wkt.formatTimestampBuf(micros, &buf));

    // Reject non-leap day & offset pushing past min bound
    try std.testing.expectError(error.InvalidFormat, wire.wkt.parseTimestamp(Ts, "2023-02-29T00:00:00Z"));
    try std.testing.expectError(error.OutOfRange, wire.wkt.parseTimestamp(Ts, "0001-01-01T00:00:00+01:00"));

    // Negative epoch nanoseconds preserve non-negative nanos (-0.25s => seconds=-1, nanos=750_000_000)
    const pre_epoch = try wire.wkt.timestampFromUnixNanos(Ts, -250_000_000);
    try std.testing.expectEqual(@as(i64, -1), pre_epoch.seconds);
    try std.testing.expectEqual(@as(i32, 750_000_000), pre_epoch.nanos);
    try std.testing.expectEqual(@as(i128, -250_000_000), try wire.wkt.timestampToUnixNanos(pre_epoch));

    // Timestamp + Duration arithmetic
    const shifted = try wire.wkt.timestampAddDuration(pre_epoch, Dur{ .seconds = 0, .nanos = 250_000_000 });
    try std.testing.expectEqual(@as(i64, 0), shifted.seconds);
    try std.testing.expectEqual(@as(i32, 0), shifted.nanos);
    const delta = try wire.wkt.timestampDiff(Dur, shifted, pre_epoch);
    try std.testing.expectEqual(@as(i64, 0), delta.seconds);
    try std.testing.expectEqual(@as(i32, 250_000_000), delta.nanos);
}

test "wkt: Duration ProtoJSON parse/format, sign rules, and arithmetic" {
    const Dur = struct { seconds: i64 = 0, nanos: i32 = 0 };
    var buf: [32]u8 = undefined;

    // Negative sub-second duration formats as `-0.500s`, never `0.-500s`
    const neg_half = try wire.wkt.parseDuration(Dur, "-0.5s");
    try std.testing.expectEqual(@as(i64, 0), neg_half.seconds);
    try std.testing.expectEqual(@as(i32, -500_000_000), neg_half.nanos);
    try std.testing.expectEqualStrings("-0.500s", try wire.wkt.formatDurationBuf(neg_half, &buf));

    const zero = try wire.wkt.parseDuration(Dur, "-0s");
    try std.testing.expectEqualStrings("0s", try wire.wkt.formatDurationBuf(zero, &buf));

    const max_dur = try wire.wkt.parseDuration(Dur, "-315576000000.999999999s");
    try std.testing.expectEqualStrings("-315576000000.999999999s", try wire.wkt.formatDurationBuf(max_dur, &buf));

    // Reject sign mismatch and out-of-range
    try std.testing.expectError(error.SignMismatch, wire.wkt.validateDuration(Dur{ .seconds = 1, .nanos = -1 }));
    try std.testing.expectError(error.OutOfRange, wire.wkt.parseDuration(Dur, "315576000001s"));
    try std.testing.expectError(error.InvalidFormat, wire.wkt.parseDuration(Dur, "1.s"));
    try std.testing.expectError(error.InvalidFormat, wire.wkt.parseDuration(Dur, ".5s"));

    // Arithmetic across zero boundary
    const sum = try wire.wkt.durationAdd(Dur{ .seconds = 1, .nanos = 0 }, neg_half);
    try std.testing.expectEqual(@as(i64, 0), sum.seconds);
    try std.testing.expectEqual(@as(i32, 500_000_000), sum.nanos);
}

test "wkt: Any zero-allocation packSlice, is, unpack, and custom prefixes" {
    const Any = struct { type_url: []const u8 = "", value: []const u8 = "" };

    const event = pb.SmallEvent{
        .id = 777,
        .timestamp_ns = 123456,
        .status = 201,
        .source = "gateway",
    };

    var val_buf: [128]u8 = undefined;
    const packed_any = try wire.wkt.packAnySlice(Any, event, &val_buf);

    try std.testing.expectEqualStrings("type.googleapis.com/" ++ pb.SmallEvent.proto_full_name, packed_any.type_url);
    try std.testing.expect(wire.wkt.anyIs(packed_any, pb.SmallEvent));
    try std.testing.expect(!wire.wkt.anyIs(packed_any, pb.UserProfile));

    const unpacked = try wire.wkt.unpackAny(packed_any, pb.SmallEvent);
    try std.testing.expectEqual(@as(u64, 777), unpacked.id);
    try std.testing.expectEqualStrings("gateway", unpacked.source);

    try std.testing.expectError(error.TypeUrlMismatch, wire.wkt.unpackAny(packed_any, pb.UserProfile));

    // Custom domain prefix still matches `anyIs` by trailing full name
    const custom_any = try wire.wkt.packAnyWithPrefixSlice(Any, "types.acme.dev", event, &val_buf);
    try std.testing.expectEqualStrings("types.acme.dev/" ++ pb.SmallEvent.proto_full_name, custom_any.type_url);
    try std.testing.expect(wire.wkt.anyIs(custom_any, pb.SmallEvent));

    // Allocator-backed pack frees cleanly
    const owned_any = try wire.wkt.packAnyAlloc(Any, std.testing.allocator, event);
    defer std.testing.allocator.free(owned_any.value);
    const decoded_owned = try wire.wkt.unpackAny(owned_any, pb.SmallEvent);
    try std.testing.expectEqual(@as(u32, 201), decoded_owned.status);
}

// ---------------------------------------------------------------------------
// Phase 4: Zero-Allocation ProtoJSON Tests
// ---------------------------------------------------------------------------

test "json: flat message encodes and decodes with strictly zero heap allocations" {
    const orig = pb.SmallEvent{
        .id = 1_048_576,
        .timestamp_ns = 1_764_075_000_123_456_789,
        .status = 200,
        .source = "edge-gw-01",
    };

    var json_buf: [256]u8 = undefined;
    const json_text = try orig.encodeJsonSlice(&json_buf, .{});
    try std.testing.expectEqualStrings(
        "{\"id\":\"1048576\",\"timestampNs\":\"1764075000123456789\",\"status\":200,\"source\":\"edge-gw-01\"}",
        json_text,
    );

    // Passing `failing_allocator` proves unescaped flat messages perform 0 allocations
    const decoded = try pb.SmallEvent.decodeJson(std.testing.failing_allocator, json_text, .{});
    try std.testing.expectEqual(orig.id, decoded.id);
    try std.testing.expectEqual(orig.timestamp_ns, decoded.timestamp_ns);
    try std.testing.expectEqual(orig.status, decoded.status);
    try std.testing.expectEqualStrings(orig.source, decoded.source);

    // Also accepts original snake_case field names and numeric 64-bit ints
    const snake = "{\"id\":42,\"timestamp_ns\":-99,\"status\":\"404\",\"source\":\"gw\"}";
    const d2 = try pb.SmallEvent.decodeJson(std.testing.failing_allocator, snake, .{});
    try std.testing.expectEqual(@as(u64, 42), d2.id);
    try std.testing.expectEqual(@as(i64, -99), d2.timestamp_ns);
    try std.testing.expectEqual(@as(u32, 404), d2.status);
}

test "json: zero-alloc wire-to-JSON transcoding and full UserProfile round-trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mgr = pb.UserProfile{ .id = 1, .name = "lead\ncto", .role = .ROLE_ADMIN };
    const orig = pb.UserProfile{
        .id = 9_876_543_210,
        .name = "alice \"dev\" 🚀",
        .role = .ROLE_MEMBER,
        .scores = .{ .slice = &.{ 10, 20, 30 } },
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

    // Transcode wire bytes -> zero-alloc view -> JSON without cloning
    var wire_buf: [512]u8 = undefined;
    const wire_bytes = try orig.encodeSlice(&wire_buf);
    const wire_view = try pb.UserProfile.decode(wire_bytes);

    var json_buf: [1024]u8 = undefined;
    const json_text = try wire_view.encodeJsonSlice(&json_buf, .{});

    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"role\":\"ROLE_MEMBER\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"email\":\"alice@acme.dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_text, "\"scores\":[10,20,30]") != null);

    // Round-trip back from JSON
    const decoded = try pb.UserProfile.decodeJson(arena, json_text, .{});
    try std.testing.expectEqual(orig.id, decoded.id);
    try std.testing.expectEqualStrings("alice \"dev\" 🚀", decoded.name);
    try std.testing.expectEqual(pb.Role.ROLE_MEMBER, decoded.role);
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30 }, decoded.scores.slice);
    try std.testing.expectEqual(@as(?i32, 64), try decoded.quotas.get("ram"));
    try std.testing.expectEqualStrings("Gurugram", decoded.address.?.city);
    try std.testing.expectEqualStrings("alice@acme.dev", decoded.contact.?.email);
    const d_mgr = try decoded.manager.?.decode();
    try std.testing.expectEqualStrings("lead\ncto", d_mgr.name);

    // Reject duplicate oneof variants, and honor ignore_unknown_fields + surrogate pairs
    try std.testing.expectError(
        error.DuplicateOneofField,
        pb.UserProfile.decodeJson(arena, "{\"email\":\"a@b\",\"phone\":\"123\"}", .{}),
    );
    const escaped_with_unknown = "{\"name\":\"hi \\uD83D\\uDE80\",\"unknownObj\":{\"a\":[1,true,null]}}";
    try std.testing.expectError(error.UnknownField, pb.UserProfile.decodeJson(arena, escaped_with_unknown, .{}));
    const ok = try pb.UserProfile.decodeJson(arena, escaped_with_unknown, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("hi 🚀", ok.name);
}

test "json: WKT Timestamp, Duration, BytesValue, and special floats" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const MockTs = struct {
        pub const proto_full_name: []const u8 = "google.protobuf.Timestamp";
        pub const _protoz_json_fields: []const wire.json.JsonFieldMeta = &.{};
        seconds: i64 = 0,
        nanos: i32 = 0,
    };
    const MockDur = struct {
        pub const proto_full_name: []const u8 = "google.protobuf.Duration";
        pub const _protoz_json_fields: []const wire.json.JsonFieldMeta = &.{};
        seconds: i64 = 0,
        nanos: i32 = 0,
    };
    const MockBytes = struct {
        pub const proto_full_name: []const u8 = "google.protobuf.BytesValue";
        pub const _protoz_json_fields: []const wire.json.JsonFieldMeta = &.{};
        value: []const u8 = "",
    };

    var buf: [128]u8 = undefined;

    const ts = try wire.json.decodeMessage(MockTs, std.testing.failing_allocator, "\"2026-11-25T14:41:00.500Z\"", .{});
    try std.testing.expectEqualStrings("\"2026-11-25T14:41:00.500Z\"", try wire.json.encodeMessageSlice(ts, &buf, .{}));

    const dur = try wire.json.decodeMessage(MockDur, std.testing.failing_allocator, "\"-0.5s\"", .{});
    try std.testing.expectEqualStrings("\"-0.500s\"", try wire.json.encodeMessageSlice(dur, &buf, .{}));

    // Standard & URL-safe unpadded Base64 decode
    const bv = try wire.json.decodeMessage(MockBytes, arena, "\"aGVsbG8\"", .{});
    try std.testing.expectEqualStrings("hello", bv.value);
    try std.testing.expectEqualStrings("\"aGVsbG8=\"", try wire.json.encodeMessageSlice(bv, &buf, .{}));

    // Special float values (NaN / Infinity / -Infinity)
    const pt = pb.TelemetryBatch.Point{ .ts = 1, .value = std.math.inf(f64), .label = "inf" };
    const pt_json = try pt.encodeJsonSlice(&buf, .{});
    try std.testing.expect(std.mem.indexOf(u8, pt_json, "\"value\":\"Infinity\"") != null);
    const pt_dec = try pb.TelemetryBatch.Point.decodeJson(std.testing.failing_allocator, pt_json, .{});
    try std.testing.expectEqual(std.math.inf(f64), pt_dec.value);
}

// ---------------------------------------------------------------------------
// Phase 4: gRPC Framing & Service Descriptor Codegen Tests
// ---------------------------------------------------------------------------

test "rpc: gRPC 5-byte framing round-trip, partial reads, compression flag, and FrameTooLarge" {
    const e1 = pb.SmallEvent{ .id = 10, .status = 200, .source = "rpc-1" };
    const e2 = pb.SmallEvent{ .id = 20, .status = 201, .source = "rpc-2" };

    var stream_buf: [256]u8 = undefined;
    var sw = wire.SliceWriter.init(&stream_buf);

    var f1_buf: [64]u8 = undefined;
    const f1 = try wire.rpc.encodeGrpcSlice(e1, &f1_buf);
    try std.testing.expectEqual(wire.rpc.encodedGrpcSize(e1), f1.len);
    try std.testing.expectEqual(@as(u8, 0), f1[0]);
    try sw.writeAll(f1);
    try wire.rpc.encodeGrpc(e2, &sw);

    const stream = sw.written();

    // Every prefix shorter than frame 1 returns null (awaiting more HTTP/2 DATA bytes)
    for (0..f1.len) |partial_len| {
        try std.testing.expectEqual(
            @as(?wire.rpc.GrpcFrame(pb.SmallEvent), null),
            try wire.rpc.tryDecodeGrpc(pb.SmallEvent, stream[0..partial_len], 1024),
        );
    }

    // Oversized frame rejected immediately from the 5-byte header
    try std.testing.expectError(
        error.FrameTooLarge,
        wire.rpc.tryDecodeGrpc(pb.SmallEvent, stream, 4),
    );

    // Invalid compression flag (neither 0 nor 1) & compressed frame handling
    const bad_flag = [_]u8{ 2, 0, 0, 0, 0 };
    try std.testing.expectError(
        error.InvalidCompressionFlag,
        wire.rpc.tryDecodeGrpcRaw(&bad_flag, 1024),
    );
    const compressed_empty = [_]u8{ 1, 0, 0, 0, 0 };
    try std.testing.expectError(
        error.CompressedFrameUnsupported,
        wire.rpc.tryDecodeGrpc(pb.SmallEvent, &compressed_empty, 1024),
    );

    // Iterate both frames with zero allocations
    var it = wire.rpc.GrpcFrameIterator(pb.SmallEvent).init(stream, 1024);
    const d1 = (try it.next()).?;
    const d2 = (try it.next()).?;
    try std.testing.expectEqual(@as(?pb.SmallEvent, null), try it.next());
    try std.testing.expectEqual(@as(u64, 10), d1.id);
    try std.testing.expectEqualStrings("rpc-1", d1.source);
    try std.testing.expectEqual(@as(u64, 20), d2.id);
    try std.testing.expectEqualStrings("rpc-2", d2.source);
}

test "rpc: zero-allocation comptime dispatchUnary and dispatchUnaryGrpc" {
    const MockService = struct {
        pub const proto_full_name: []const u8 = "bench.EventService";
        pub const MethodId = enum { Echo, StreamEvents };

        pub const Echo = struct {
            pub const name: []const u8 = "Echo";
            pub const zig_name: []const u8 = "echo";
            pub const path: []const u8 = "/bench.EventService/Echo";
            pub const Request = pb.SmallEvent;
            pub const Response = pb.SmallEvent;
            pub const client_streaming: bool = false;
            pub const server_streaming: bool = false;
            pub const stream_kind: wire.rpc.StreamKind = .unary;
        };

        pub const StreamEvents = struct {
            pub const name: []const u8 = "StreamEvents";
            pub const zig_name: []const u8 = "streamEvents";
            pub const path: []const u8 = "/bench.EventService/StreamEvents";
            pub const Request = pb.SmallEvent;
            pub const Response = pb.SmallEvent;
            pub const client_streaming: bool = false;
            pub const server_streaming: bool = true;
            pub const stream_kind: wire.rpc.StreamKind = .server_streaming;
        };

        pub const methods = .{ Echo, StreamEvents };
    };

    const Handler = struct {
        calls: u32 = 0,

        pub fn echo(self: *@This(), req: pb.SmallEvent) !pb.SmallEvent {
            self.calls += 1;
            return .{
                .id = req.id + 1,
                .status = 200,
                .source = req.source,
            };
        }
    };

    var handler: Handler = .{};
    const req = pb.SmallEvent{ .id = 41, .source = "client" };

    var req_buf: [64]u8 = undefined;
    var resp_buf: [64]u8 = undefined;
    const req_grpc = try wire.rpc.encodeGrpcSlice(req, &req_buf);

    const resp_grpc = try wire.rpc.dispatchUnaryGrpc(
        MockService,
        &handler,
        "/bench.EventService/Echo",
        req_grpc,
        1024,
        &resp_buf,
    );
    const decoded_frame = (try wire.rpc.tryDecodeGrpc(pb.SmallEvent, resp_grpc, 1024)).?;
    try std.testing.expectEqual(@as(u32, 1), handler.calls);
    try std.testing.expectEqual(@as(u64, 42), decoded_frame.msg.id);
    try std.testing.expectEqualStrings("client", decoded_frame.msg.source);

    // Unknown or non-unary path returns error.Unimplemented
    try std.testing.expectError(
        error.Unimplemented,
        wire.rpc.dispatchUnaryGrpc(MockService, &handler, "/bench.EventService/Unknown", req_grpc, 1024, &resp_buf),
    );
    try std.testing.expectError(
        error.Unimplemented,
        wire.rpc.dispatchUnaryGrpc(MockService, &handler, "/bench.EventService/StreamEvents", req_grpc, 1024, &resp_buf),
    );
}

test "codegen: emits typed gRPC service descriptors, paths, and streaming kinds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\syntax = "proto3";
        \\package acme.v1;
        \\message Ping { uint64 id = 1; }
        \\message Pong { uint64 id = 1; }
        \\service Health {
        \\  rpc Check (Ping) returns (Pong);
        \\  rpc Watch (Ping) returns (stream Pong);
        \\  rpc Chat (stream Ping) returns (stream Pong);
        \\}
    ;
    const file = try parser.Parser.parse(arena, src);
    const res = try resolver.Resolver.build(arena, &file);

    var out: std.Io.Writer.Allocating = .init(arena);
    try codegen.generateFile(arena, 0, &res, &out.writer);
    const gen = out.written();

    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const Health = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const path: []const u8 = \"/acme.v1.Health/Check\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const zig_name: []const u8 = \"check\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const stream_kind: wire.rpc.StreamKind = .server_streaming;") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const stream_kind: wire.rpc.StreamKind = .bidi_streaming;") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub fn matchPath(path: []const u8) ?MethodId {") != null);
}

test "protoz: public facade exports compile cleanly alongside generated .pb.zig" {
    const protoz = @import("protoz");
    std.testing.refAllDecls(protoz);

    const e = pb.SmallEvent{ .id = 7, .status = 200, .source = "facade" };
    var frame_buf: [64]u8 = undefined;
    const frame = try protoz.encodeDelimitedSlice(e, &frame_buf);
    const decoded = (try protoz.tryDecodeDelimited(pb.SmallEvent, frame, 1024)).?;
    try std.testing.expectEqual(@as(u64, 7), decoded.msg.id);
    try std.testing.expectEqualStrings("facade", decoded.msg.source);
}

test "codegen: escapes Zig primitive names in declarations, fields, and import public" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f_base = try parser.Parser.parse(arena,
        \\syntax = "proto3";
        \\package stress.base;
        \\enum u8 { U8_ZERO = 0; }
        \\message type {
        \\  bool bool = 1;
        \\  uint32 usize = 2;
        \\  u8 u01 = 3;
        \\  int32 _ = 4;
        \\}
    );
    f_base.name = "base.proto";

    var f_reexport = try parser.Parser.parse(arena,
        \\syntax = "proto3";
        \\import public "base.proto";
        \\message Holder { stress.base.type item = 1; }
    );
    f_reexport.name = "reexport.proto";

    const files = [_]ast.File{ f_base, f_reexport };
    const res = try resolver.Resolver.buildMulti(arena, &files);

    var base_out: std.Io.Writer.Allocating = .init(arena);
    try codegen.generateFile(arena, 0, &res, &base_out.writer);
    const base_gen = base_out.written();

    try std.testing.expect(std.mem.indexOf(u8, base_gen, "pub const @\"u8\" = enum(i32) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, base_gen, "pub const @\"type\" = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, base_gen, "@\"bool\": bool = false,") != null);
    try std.testing.expect(std.mem.indexOf(u8, base_gen, "@\"usize\": u32 = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, base_gen, "@\"u01\": @\"u8\" = @fromBackingInt(0),") != null);
    try std.testing.expect(std.mem.indexOf(u8, base_gen, "@\"_\": i32 = 0,") != null);

    var re_out: std.Io.Writer.Allocating = .init(arena);
    try codegen.generateFile(arena, 1, &res, &re_out.writer);
    const re_gen = re_out.written();

    try std.testing.expect(std.mem.indexOf(u8, re_gen, "pub const @\"type\" = _imp_0.@\"type\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, re_gen, "item: ?_imp_0.@\"type\" = null,") != null);
}

test "codegen: avoids file-scope wire and _protoz_file alias collisions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const file = try parser.Parser.parse(arena,
        \\syntax = "proto3";
        \\package pkg;
        \\message wire { string x = 1; }
        \\message _protoz_file {
        \\  message wire { int32 y = 1; }
        \\  .pkg.wire outer_wire = 1;
        \\}
    );
    const res = try resolver.Resolver.build(arena, &file);

    var out: std.Io.Writer.Allocating = .init(arena);
    try codegen.generateFile(arena, 0, &res, &out.writer);
    const gen = out.written();

    try std.testing.expect(std.mem.indexOf(u8, gen, "const _protoz_wire = @import(\"proto_wire\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "const _protoz_self = @This();") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const wire = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "outer_wire: ?_protoz_self.wire = null,") != null);
}

test "proto2: parser, resolver, and codegen materialize groups, extension ranges, and extend" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const src =
        \\syntax = "proto2";
        \\package legacy.v1;
        \\message Envelope {
        \\  optional group Header = 1 {
        \\    required string key = 1;
        \\    optional int32 priority = 2 [default = 5];
        \\  }
        \\  repeated group Tag = 2 {
        \\    optional string label = 1;
        \\  }
        \\  extensions 100 to 199;
        \\  extend Envelope {
        \\    optional uint64 nested_ext = 105;
        \\  }
        \\}
        \\extend Envelope {
        \\  optional string note = 100;
        \\  repeated int32 ids = 101;
        \\  optional group Audit = 102 {
        \\    optional int64 ts = 1;
        \\  }
        \\}
    ;

    const file = try parser.Parser.parse(arena, src);
    const res = try resolver.Resolver.build(arena, &file);

    var out: std.Io.Writer.Allocating = .init(arena);
    try codegen.generateFileWithOptions(arena, 0, &res, &out.writer, .{ .preserve_unknown_fields = true });
    const gen = out.written();

    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const Header = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "header: ?Envelope.Header = null,") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "tag: wire.Repeated(wire.GroupCodec(Envelope.Tag, 2)) = .empty,") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "try wire.writeTag(w, 1, .sgroup);") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "try wire.writeTag(w, 1, .egroup);") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const nested_ext = wire.Extension(Envelope, 105, wire.ScalarCodec(.uint64));") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const note = wire.Extension(Envelope, 100, wire.ScalarCodec(.string));") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const ids = wire.RepeatedExtension(Envelope, 101, wire.ScalarCodec(.int32));") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "pub const audit = wire.Extension(Envelope, 102, wire.GroupCodec(Audit, 102));") != null);

    // Reject extension number outside declared `extensions` range
    const bad =
        \\syntax = "proto2";
        \\message Host { extensions 100 to 110; }
        \\extend Host { optional int32 oob = 200; }
    ;
    const bad_file = try parser.Parser.parse(arena, bad);
    try std.testing.expectError(error.ExtensionNumberOutOfRange, resolver.Resolver.build(arena, &bad_file));
}

test "wire: GroupCodec, Extension, and RepeatedExtension round-trip with zero allocations" {
    const Host = struct {
        id: u64 = 0,
        _unknown_fields: wire.UnknownFields = .empty,
        pub const _protoz_known_fields: []const u29 = &.{1};
    };

    const ExtNote = wire.Extension(Host, 100, wire.ScalarCodec(.string));
    const ExtIds = wire.RepeatedExtension(Host, 101, wire.ScalarCodec(.int32));
    const ExtGroup = wire.Extension(Host, 102, wire.GroupCodec(pb.SmallEvent, 102));

    var raw_buf: [256]u8 = undefined;
    var sw = wire.SliceWriter.init(&raw_buf);

    var tmp: [128]u8 = undefined;
    try sw.writeAll(try ExtNote.encodeSlice("proto2-ext", &tmp));
    try sw.writeAll(try ExtIds.encodeSlice(&.{ 7, 11, 13 }, true, &tmp));
    try sw.writeAll(try ExtGroup.encodeSlice(.{ .id = 55, .source = "grp" }, &tmp));

    const host = Host{
        .id = 1,
        ._unknown_fields = .{ .raw = sw.written() },
    };

    try std.testing.expect(try ExtNote.has(&host));
    try std.testing.expectEqualStrings("proto2-ext", (try ExtNote.get(&host)).?);

    var id_it = ExtIds.iterator(&host);
    try std.testing.expectEqual(@as(?i32, 7), try id_it.next());
    try std.testing.expectEqual(@as(?i32, 11), try id_it.next());
    try std.testing.expectEqual(@as(?i32, 13), try id_it.next());
    try std.testing.expectEqual(@as(?i32, null), try id_it.next());

    const grp = (try ExtGroup.get(&host)).?;
    try std.testing.expectEqual(@as(u64, 55), grp.id);
    try std.testing.expectEqualStrings("grp", grp.source);
}

fn writeDescriptorField(
    arena: std.mem.Allocator,
    opts: struct {
        name: []const u8,
        extendee: []const u8 = "",
        number: u29,
        label: u32,
        type_enum: u32,
        type_name: []const u8 = "",
        default_value: ?[]const u8 = null,
    },
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try wire.writeTag(w, 1, .len);
    try wire.writeBytes(w, opts.name);
    if (opts.extendee.len > 0) {
        try wire.writeTag(w, 2, .len);
        try wire.writeBytes(w, opts.extendee);
    }
    try wire.writeTag(w, 3, .varint);
    try wire.writeVarint(w, opts.number);
    try wire.writeTag(w, 4, .varint);
    try wire.writeVarint(w, opts.label);
    try wire.writeTag(w, 5, .varint);
    try wire.writeVarint(w, opts.type_enum);
    if (opts.type_name.len > 0) {
        try wire.writeTag(w, 6, .len);
        try wire.writeBytes(w, opts.type_name);
    }
    if (opts.default_value) |dv| {
        try wire.writeTag(w, 7, .len);
        try wire.writeBytes(w, dv);
    }
    return out.toOwnedSlice();
}

test "plugin: decodes CodeGeneratorRequest with TYPE_GROUP, extension_range, extension, and default_value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Nested DescriptorProto: Header { required string key = 1; optional int32 retry = 2 [default = 5]; }
    var header_desc: std.Io.Writer.Allocating = .init(arena);
    {
        const w = &header_desc.writer;
        try wire.writeTag(w, 1, .len);
        try wire.writeBytes(w, "Header");
        try wire.writeTag(w, 2, .len);
        try wire.writeBytes(w, try writeDescriptorField(arena, .{ .name = "key", .number = 1, .label = 2, .type_enum = 9 }));
        try wire.writeTag(w, 2, .len);
        try wire.writeBytes(w, try writeDescriptorField(arena, .{ .name = "retry", .number = 2, .label = 1, .type_enum = 5, .default_value = "5" }));
    }

    // Nested DescriptorProto: Audit { optional int64 ts = 1; }
    var audit_desc: std.Io.Writer.Allocating = .init(arena);
    {
        const w = &audit_desc.writer;
        try wire.writeTag(w, 1, .len);
        try wire.writeBytes(w, "Audit");
        try wire.writeTag(w, 2, .len);
        try wire.writeBytes(w, try writeDescriptorField(arena, .{ .name = "ts", .number = 1, .label = 1, .type_enum = 3 }));
    }

    // Envelope DescriptorProto with TYPE_GROUP field, ExtensionRange [100, 200), and nested extension
    var env_desc: std.Io.Writer.Allocating = .init(arena);
    {
        const w = &env_desc.writer;
        try wire.writeTag(w, 1, .len);
        try wire.writeBytes(w, "Envelope");
        try wire.writeTag(w, 2, .len);
        try wire.writeBytes(w, try writeDescriptorField(arena, .{
            .name = "header",
            .number = 1,
            .label = 1,
            .type_enum = 10, // TYPE_GROUP
            .type_name = ".legacy.v1.Envelope.Header",
        }));
        try wire.writeTag(w, 3, .len);
        try wire.writeBytes(w, header_desc.written());
        try wire.writeTag(w, 3, .len);
        try wire.writeBytes(w, audit_desc.written());

        // ExtensionRange: start = 100 (inclusive), end = 200 (exclusive -> 199)
        var er: std.Io.Writer.Allocating = .init(arena);
        try wire.writeTag(&er.writer, 1, .varint);
        try wire.writeVarint(&er.writer, 100);
        try wire.writeTag(&er.writer, 2, .varint);
        try wire.writeVarint(&er.writer, 200);
        try wire.writeTag(w, 5, .len);
        try wire.writeBytes(w, er.written());

        // Nested extension (DescriptorProto.extension = 6)
        try wire.writeTag(w, 6, .len);
        try wire.writeBytes(w, try writeDescriptorField(arena, .{
            .name = "nested_ext",
            .extendee = ".legacy.v1.Envelope",
            .number = 105,
            .label = 1,
            .type_enum = 4, // UINT64
        }));
    }

    // FileDescriptorProto: legacy/ext.proto
    var fd: std.Io.Writer.Allocating = .init(arena);
    {
        const w = &fd.writer;
        try wire.writeTag(w, 1, .len);
        try wire.writeBytes(w, "legacy/ext.proto");
        try wire.writeTag(w, 2, .len);
        try wire.writeBytes(w, "legacy.v1");
        try wire.writeTag(w, 4, .len);
        try wire.writeBytes(w, env_desc.written());
        // File-level extensions (FileDescriptorProto.extension = 7)
        try wire.writeTag(w, 7, .len);
        try wire.writeBytes(w, try writeDescriptorField(arena, .{
            .name = "note",
            .extendee = ".legacy.v1.Envelope",
            .number = 100,
            .label = 1,
            .type_enum = 9, // STRING
        }));
        try wire.writeTag(w, 7, .len);
        try wire.writeBytes(w, try writeDescriptorField(arena, .{
            .name = "audit",
            .extendee = ".legacy.v1.Envelope",
            .number = 102,
            .label = 1,
            .type_enum = 10, // TYPE_GROUP
            .type_name = ".legacy.v1.Envelope.Audit",
        }));
        try wire.writeTag(w, 12, .len);
        try wire.writeBytes(w, "proto2");
    }

    var req: std.Io.Writer.Allocating = .init(arena);
    try wire.writeTag(&req.writer, 1, .len);
    try wire.writeBytes(&req.writer, "legacy/ext.proto");
    try wire.writeTag(&req.writer, 2, .len);
    try wire.writeBytes(&req.writer, "preserve_unknown_fields=true");
    try wire.writeTag(&req.writer, 15, .len);
    try wire.writeBytes(&req.writer, fd.written());

    const resp = try plugin.processRequest(arena, req.written());
    var r = wire.Reader.init(resp);
    var gen_name: []const u8 = "";
    var gen_content: []const u8 = "";
    while (try r.readTag()) |tag| {
        switch (tag.field_number) {
            1 => return error.UnexpectedPluginError,
            15 => {
                var fr = wire.Reader.init(try r.readBytes());
                while (try fr.readTag()) |ft| {
                    switch (ft.field_number) {
                        1 => gen_name = try fr.readBytes(),
                        15 => gen_content = try fr.readBytes(),
                        else => try fr.skipField(ft, wire.max_recursion_depth),
                    }
                }
            },
            else => try r.skipField(tag, wire.max_recursion_depth),
        }
    }

    try std.testing.expectEqualStrings("legacy/ext.pb.zig", gen_name);
    try std.testing.expect(std.mem.indexOf(u8, gen_content, "pub const retry: i32 = 5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_content, "header: ?Envelope.Header = null,") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_content, "try wire.writeTag(w, 1, .sgroup);") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_content, "try wire.writeTag(w, 1, .egroup);") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_content, "return error.MissingRequiredField;") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_content, "pub const nested_ext = wire.Extension(Envelope, 105, wire.ScalarCodec(.uint64));") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_content, "pub const note = wire.Extension(Envelope, 100, wire.ScalarCodec(.string));") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_content, "pub const audit = wire.Extension(Envelope, 102, wire.GroupCodec(Envelope.Audit, 102));") != null);
}

fn writeFeatureSet(
    arena: std.mem.Allocator,
    opts: struct {
        field_presence: ?u64 = null,
        repeated_field_encoding: ?u64 = null,
        utf8_validation: ?u64 = null,
        message_encoding: ?u64 = null,
    },
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (opts.field_presence) |v| {
        try wire.writeTag(w, 1, .varint);
        try wire.writeVarint(w, v);
    }
    if (opts.repeated_field_encoding) |v| {
        try wire.writeTag(w, 3, .varint);
        try wire.writeVarint(w, v);
    }
    if (opts.utf8_validation) |v| {
        try wire.writeTag(w, 4, .varint);
        try wire.writeVarint(w, v);
    }
    if (opts.message_encoding) |v| {
        try wire.writeTag(w, 5, .varint);
        try wire.writeVarint(w, v);
    }
    return out.toOwnedSlice();
}

test "edition 2023: DELIMITED message encoding, LEGACY_REQUIRED, and plugin FeatureSet" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1. zig-protoc frontend: DELIMITED + LEGACY_REQUIRED
    const src =
        \\edition = "2023";
        \\package ed.v1;
        \\message Child {
        \\  string id = 1 [features.field_presence = LEGACY_REQUIRED];
        \\}
        \\message Parent {
        \\  option features.message_encoding = DELIMITED;
        \\  Child child = 1;
        \\  repeated Child items = 2;
        \\}
    ;
    const file = try parser.Parser.parse(arena, src);
    const res = try resolver.Resolver.build(arena, &file);

    var out: std.Io.Writer.Allocating = .init(arena);
    try codegen.generateFile(arena, 0, &res, &out.writer);
    const gen = out.written();

    try std.testing.expect(std.mem.indexOf(u8, gen, "pub fn isInitialized(") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "try wire.writeTag(w, 1, .sgroup);") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "try wire.writeTag(w, 1, .egroup);") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "items: wire.Repeated(wire.GroupCodec(Child, 2)) = .empty,") != null);

    // 2. protoc-gen-zig binary FeatureSet decoding (FileOptions.features=50, MessageOptions.features=12, FieldOptions.features=21)
    const f_child_id_feat = try writeFeatureSet(arena, .{ .field_presence = 3 }); // LEGACY_REQUIRED
    var f_child_id_opts: std.Io.Writer.Allocating = .init(arena);
    try wire.writeTag(&f_child_id_opts.writer, 21, .len);
    try wire.writeBytes(&f_child_id_opts.writer, f_child_id_feat);

    var f_child_id: std.Io.Writer.Allocating = .init(arena);
    try f_child_id.writer.writeAll(try writeDescriptorField(arena, .{
        .name = "id",
        .number = 1,
        .label = 1,
        .type_enum = 9, // STRING
    }));
    try wire.writeTag(&f_child_id.writer, 8, .len);
    try wire.writeBytes(&f_child_id.writer, f_child_id_opts.written());

    var child_desc: std.Io.Writer.Allocating = .init(arena);
    try wire.writeTag(&child_desc.writer, 1, .len);
    try wire.writeBytes(&child_desc.writer, "Child");
    try wire.writeTag(&child_desc.writer, 2, .len);
    try wire.writeBytes(&child_desc.writer, f_child_id.written());

    const msg_feat = try writeFeatureSet(arena, .{ .message_encoding = 2 }); // DELIMITED
    var msg_opts: std.Io.Writer.Allocating = .init(arena);
    try wire.writeTag(&msg_opts.writer, 12, .len);
    try wire.writeBytes(&msg_opts.writer, msg_feat);

    var parent_desc: std.Io.Writer.Allocating = .init(arena);
    {
        const w = &parent_desc.writer;
        try wire.writeTag(w, 1, .len);
        try wire.writeBytes(w, "Parent");
        try wire.writeTag(w, 2, .len);
        try wire.writeBytes(w, try writeDescriptorField(arena, .{
            .name = "child",
            .number = 1,
            .label = 1,
            .type_enum = 11, // MESSAGE
            .type_name = ".ed.v1.Child",
        }));
        try wire.writeTag(w, 2, .len);
        try wire.writeBytes(w, try writeDescriptorField(arena, .{
            .name = "items",
            .number = 2,
            .label = 3, // REPEATED
            .type_enum = 11,
            .type_name = ".ed.v1.Child",
        }));
        try wire.writeTag(w, 7, .len);
        try wire.writeBytes(w, msg_opts.written());
    }

    // FileOptions { features = { utf8_validation = NONE (3) } }
    const file_feat = try writeFeatureSet(arena, .{ .utf8_validation = 3 });
    var file_opts: std.Io.Writer.Allocating = .init(arena);
    try wire.writeTag(&file_opts.writer, 50, .len);
    try wire.writeBytes(&file_opts.writer, file_feat);

    var fd: std.Io.Writer.Allocating = .init(arena);
    {
        const w = &fd.writer;
        try wire.writeTag(w, 1, .len);
        try wire.writeBytes(w, "ed/test.proto");
        try wire.writeTag(w, 2, .len);
        try wire.writeBytes(w, "ed.v1");
        try wire.writeTag(w, 4, .len);
        try wire.writeBytes(w, child_desc.written());
        try wire.writeTag(w, 4, .len);
        try wire.writeBytes(w, parent_desc.written());
        try wire.writeTag(w, 8, .len);
        try wire.writeBytes(w, file_opts.written());
        try wire.writeTag(w, 12, .len);
        try wire.writeBytes(w, "editions");
        try wire.writeTag(w, 14, .varint);
        try wire.writeVarint(w, @bitCast(@as(i64, plugin.edition_2023)));
    }

    var req: std.Io.Writer.Allocating = .init(arena);
    try wire.writeTag(&req.writer, 1, .len);
    try wire.writeBytes(&req.writer, "ed/test.proto");
    try wire.writeTag(&req.writer, 15, .len);
    try wire.writeBytes(&req.writer, fd.written());

    const resp = try plugin.processRequest(arena, req.written());
    var r = wire.Reader.init(resp);
    var plugin_gen: []const u8 = "";
    var features_val: u64 = 0;
    while (try r.readTag()) |tag| {
        switch (tag.field_number) {
            1 => return error.UnexpectedPluginError,
            2 => features_val = try r.readVarint(),
            15 => {
                var fr = wire.Reader.init(try r.readBytes());
                while (try fr.readTag()) |ft| {
                    if (ft.field_number == 15) plugin_gen = try fr.readBytes() else try fr.skipField(ft, wire.max_recursion_depth);
                }
            },
            else => try r.skipField(tag, wire.max_recursion_depth),
        }
    }

    try std.testing.expectEqual(plugin.feature_proto3_optional | plugin.feature_supports_editions, features_val);
    try std.testing.expect(std.mem.indexOf(u8, plugin_gen, "pub fn isInitialized(") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin_gen, "wire.ScalarCodec(.string)") != null); // FileOptions.features NONE
    try std.testing.expect(std.mem.indexOf(u8, plugin_gen, "try wire.writeTag(w, 1, .sgroup);") != null);
    try std.testing.expect(std.mem.indexOf(u8, plugin_gen, "items: wire.Repeated(wire.GroupCodec(Child, 2)) = .empty,") != null);
}

test "json: rejects Zig-only numeric syntax, bad base64 padding, and invalid skipped escapes" {
    try std.testing.expectError(
        error.InvalidNumber,
        pb.SmallEvent.decodeJson(std.testing.failing_allocator, "{\"id\":\"1_000\"}", .{}),
    );
    try std.testing.expectError(
        error.InvalidNumber,
        pb.SmallEvent.decodeJson(std.testing.failing_allocator, "{\"id\":\"+42\"}", .{}),
    );
    try std.testing.expectError(
        error.InvalidNumber,
        pb.TelemetryBatch.Point.decodeJson(std.testing.failing_allocator, "{\"value\":\"nan\"}", .{}),
    );
    try std.testing.expectError(
        error.InvalidNumber,
        pb.TelemetryBatch.Point.decodeJson(std.testing.failing_allocator, "{\"value\":\"0x1p4\"}", .{}),
    );
    try std.testing.expectError(
        error.InvalidEscape,
        pb.SmallEvent.decodeJson(std.testing.failing_allocator, "{\"unknown\":\"\\q\"}", .{ .ignore_unknown_fields = true }),
    );

    const MockBytes = struct {
        pub const proto_full_name: []const u8 = "google.protobuf.BytesValue";
        pub const _protoz_json_fields: []const wire.json.JsonFieldMeta = &.{};
        value: []const u8 = "",
    };
    try std.testing.expectError(
        error.InvalidBase64,
        wire.json.decodeMessage(MockBytes, std.testing.allocator, "\"AAAA====\"", .{}),
    );
    try std.testing.expectError(
        error.InvalidBase64,
        wire.json.decodeMessage(MockBytes, std.testing.allocator, "\"YQ=\"", .{}),
    );
}

test "wire: mergeDepth rejects overwriting non-empty owned Repeated/Map/Lazy views" {
    var msg = pb.UserProfile{
        .scores = .{ .slice = &.{ 1, 2, 3 } },
    };
    var wire_buf: [64]u8 = undefined;
    const encoded = try (pb.UserProfile{ .scores = .{ .slice = &.{4} } }).encodeSlice(&wire_buf);
    try std.testing.expectError(
        error.CannotMergeOwnedContainer,
        msg.mergeDepth(encoded, wire.max_recursion_depth),
    );
}

test "parser + resolver: diagnostic line/col and duplicate symbol/enum/rpc/extension checks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Parser populates Diagnostic on top-level & service syntax errors
    var diag: diag_mod.Diagnostic = .{};
    try std.testing.expectError(
        error.UnexpectedToken,
        parser.Parser.parseWithDiag(arena, "bad.proto", "syntax = \"proto3\";\nbogus_top_level;\n", &diag),
    );
    try std.testing.expectEqualStrings("bad.proto", diag.file);
    try std.testing.expectEqual(@as(u32, 2), diag.line);
    try std.testing.expect(diag.message.len > 0);

    // Duplicate message symbol
    const dup_msg = try parser.Parser.parse(arena, "syntax = \"proto3\"; message A {} message A {}");
    try std.testing.expectError(error.DuplicateSymbol, resolver.Resolver.build(arena, &dup_msg));

    // Duplicate enum value name (even with allow_alias = true)
    const dup_enum = try parser.Parser.parse(arena,
        \\syntax = "proto3";
        \\enum E { option allow_alias = true; A = 0; A = 0; }
    );
    try std.testing.expectError(error.DuplicateEnumValueName, resolver.Resolver.build(arena, &dup_enum));

    // Duplicate RPC name in service
    const dup_rpc = try parser.Parser.parse(arena,
        \\syntax = "proto3";
        \\message Req {}
        \\service S { rpc Ping (Req) returns (Req); rpc Ping (Req) returns (Req); }
    );
    try std.testing.expectError(error.DuplicateRpcName, resolver.Resolver.build(arena, &dup_rpc));

    // Duplicate extension field number across two extend blocks
    const dup_ext = try parser.Parser.parse(arena,
        \\syntax = "proto2";
        \\message Host { extensions 100 to 199; }
        \\extend Host { optional int32 a = 100; }
        \\extend Host { optional string b = 100; }
    );
    try std.testing.expectError(error.DuplicateExtensionNumber, resolver.Resolver.build(arena, &dup_ext));
}
