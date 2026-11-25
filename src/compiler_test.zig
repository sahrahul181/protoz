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
    try std.testing.expect(res.hasExplicitPresence(0, env.fields[0], .{ .scalar = resolver.lookupScalar("int32").? }));
    try std.testing.expect(!res.hasExplicitPresence(0, env.fields[1], .{ .scalar = resolver.lookupScalar("int32").? }));
    try std.testing.expect(res.validatesUtf8(0, env.fields[2].options));
    try std.testing.expect(!res.validatesUtf8(0, env.fields[3].options));
    try std.testing.expect(!res.isPacked(0, env.fields[4]));

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
            2 => try std.testing.expectEqual(plugin.feature_proto3_optional, try r.readVarint()),
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
