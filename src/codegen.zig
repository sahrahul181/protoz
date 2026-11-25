const std = @import("std");
const ast = @import("ast.zig");
const resolver = @import("resolver.zig");

/// Converts a canonical proto path ("common/types.proto") to its generated Zig path ("common/types.pb.zig").
pub fn protoToZigRelPath(arena: std.mem.Allocator, proto_name: []const u8) ![]const u8 {
    const stem = if (std.mem.endsWith(u8, proto_name, ".proto"))
        proto_name[0 .. proto_name.len - ".proto".len]
    else
        proto_name;
    return std.fmt.allocPrint(arena, "{s}.pb.zig", .{stem});
}

/// Computes a POSIX relative import path from `from_proto` to `to_proto` (e.g., "../common/types.pb.zig").
pub fn relativeZigImport(arena: std.mem.Allocator, from_proto: []const u8, to_proto: []const u8) ![]const u8 {
    const to_zig = try protoToZigRelPath(arena, to_proto);
    const from_dir = dirName(from_proto);
    const to_dir = dirName(to_zig);
    const to_base = baseName(to_zig);

    var from_parts: std.ArrayList([]const u8) = .empty;
    var to_parts: std.ArrayList([]const u8) = .empty;

    var fi = std.mem.splitScalar(u8, from_dir, '/');
    while (fi.next()) |seg| {
        if (seg.len > 0 and !std.mem.eql(u8, seg, ".")) try from_parts.append(arena, seg);
    }
    var ti = std.mem.splitScalar(u8, to_dir, '/');
    while (ti.next()) |seg| {
        if (seg.len > 0 and !std.mem.eql(u8, seg, ".")) try to_parts.append(arena, seg);
    }

    var common: usize = 0;
    while (common < from_parts.items.len and
        common < to_parts.items.len and
        std.mem.eql(u8, from_parts.items[common], to_parts.items[common])) : (common += 1)
    {}

    var out: std.ArrayList(u8) = .empty;
    for (common..from_parts.items.len) |_| try out.appendSlice(arena, "../");
    for (common..to_parts.items.len) |idx| {
        try out.appendSlice(arena, to_parts.items[idx]);
        try out.append(arena, '/');
    }
    try out.appendSlice(arena, to_base);
    return out.toOwnedSlice(arena);
}

fn dirName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[0..idx];
    return "";
}

fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    return path;
}

const ImportTable = struct {
    file_idx: usize,
    alias_by_file: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    ordered_deps: std.ArrayList(usize) = .empty,

    fn noteSymbol(self: *ImportTable, arena: std.mem.Allocator, sym: resolver.Symbol) !void {
        if (sym.file_index == self.file_idx) return;
        if (!self.alias_by_file.contains(sym.file_index)) {
            const alias_id = self.ordered_deps.items.len;
            try self.alias_by_file.put(arena, sym.file_index, alias_id);
            try self.ordered_deps.append(arena, sym.file_index);
        }
    }

    fn collectMessage(
        self: *ImportTable,
        arena: std.mem.Allocator,
        m: ast.Message,
        scope_fqn: []const u8,
        res: *const resolver.Resolver,
    ) !void {
        for (m.nested_messages) |nm| {
            const child_fqn = try std.fmt.allocPrint(arena, "{s}.{s}", .{ scope_fqn, nm.name });
            try self.collectMessage(arena, nm, child_fqn, res);
        }
        for (m.fields) |f| {
            const rt = try res.resolveType(scope_fqn, f.type_name);
            switch (rt) {
                .scalar => {},
                .@"enum" => |e| try self.noteSymbol(arena, e),
                .message => |ms| try self.noteSymbol(arena, ms),
            }
        }
        for (m.maps) |mp| {
            const kt = try res.resolveType(scope_fqn, mp.key_type);
            const vt = try res.resolveType(scope_fqn, mp.value_type);
            switch (kt) {
                .scalar => {},
                .@"enum" => |e| try self.noteSymbol(arena, e),
                .message => |ms| try self.noteSymbol(arena, ms),
            }
            switch (vt) {
                .scalar => {},
                .@"enum" => |e| try self.noteSymbol(arena, e),
                .message => |ms| try self.noteSymbol(arena, ms),
            }
        }
        for (m.oneofs) |o| {
            for (o.fields) |f| {
                const rt = try res.resolveType(scope_fqn, f.type_name);
                switch (rt) {
                    .scalar => {},
                    .@"enum" => |e| try self.noteSymbol(arena, e),
                    .message => |ms| try self.noteSymbol(arena, ms),
                }
            }
        }
    }

    fn writeSymPath(self: *const ImportTable, w: *std.Io.Writer, sym: resolver.Symbol) !void {
        if (sym.file_index != self.file_idx) {
            const alias_id = self.alias_by_file.get(sym.file_index).?;
            try w.print("_imp_{d}.", .{alias_id});
        }
        var it = std.mem.splitScalar(u8, sym.zig_path, '.');
        var first = true;
        while (it.next()) |seg| {
            if (!first) try w.writeByte('.');
            try writeIdent(w, seg);
            first = false;
        }
    }
};

const GenCtx = struct {
    arena: std.mem.Allocator,
    file_idx: usize,
    res: *const resolver.Resolver,
    imports: *const ImportTable,
};

fn isZigKeyword(name: []const u8) bool {
    const kws = std.StaticStringMap(void).initComptime(.{
        .{ "addrspace", {} },   .{ "align", {} },       .{ "allowzero", {} }, .{ "and", {} },
        .{ "anyframe", {} },    .{ "anytype", {} },     .{ "asm", {} },       .{ "break", {} },
        .{ "callconv", {} },    .{ "catch", {} },       .{ "comptime", {} },  .{ "const", {} },
        .{ "continue", {} },    .{ "defer", {} },       .{ "else", {} },      .{ "enum", {} },
        .{ "errdefer", {} },    .{ "error", {} },       .{ "export", {} },    .{ "extern", {} },
        .{ "false", {} },       .{ "fn", {} },          .{ "for", {} },       .{ "if", {} },
        .{ "inline", {} },      .{ "linksection", {} }, .{ "noalias", {} },   .{ "nosuspend", {} },
        .{ "null", {} },        .{ "opaque", {} },      .{ "or", {} },        .{ "orelse", {} },
        .{ "packed", {} },      .{ "pub", {} },         .{ "resume", {} },    .{ "return", {} },
        .{ "struct", {} },      .{ "suspend", {} },     .{ "switch", {} },    .{ "test", {} },
        .{ "threadlocal", {} }, .{ "true", {} },        .{ "try", {} },       .{ "undefined", {} },
        .{ "union", {} },       .{ "unreachable", {} }, .{ "var", {} },       .{ "volatile", {} },
        .{ "while", {} },
    });
    return kws.has(name);
}

pub fn writeIdent(w: *std.Io.Writer, name: []const u8) !void {
    if (isZigKeyword(name)) {
        try w.print("@\"{s}\"", .{name});
    } else {
        try w.writeAll(name);
    }
}

fn writeIndent(w: *std.Io.Writer, level: usize) !void {
    for (0..level) |_| try w.writeAll("    ");
}

fn writeCodecExpr(ctx: GenCtx, w: *std.Io.Writer, rt: resolver.ResolvedType, utf8_check: bool) !void {
    switch (rt) {
        .scalar => |s| {
            if (utf8_check and std.mem.eql(u8, s.wire_kind, ".string")) {
                try w.writeAll("wire.ScalarCodec(.string_utf8)");
            } else {
                try w.print("wire.ScalarCodec({s})", .{s.wire_kind});
            }
        },
        .@"enum" => |e| {
            try w.writeAll("wire.EnumCodec(");
            try ctx.imports.writeSymPath(w, e);
            try w.writeAll(")");
        },
        .message => |m| {
            try w.writeAll("wire.MessageCodec(");
            try ctx.imports.writeSymPath(w, m);
            try w.writeAll(")");
        },
    }
}

fn isPackable(rt: resolver.ResolvedType) bool {
    return switch (rt) {
        .scalar => |s| s.packable,
        .@"enum" => true,
        .message => false,
    };
}

fn oneofZigTypeName(arena: std.mem.Allocator, m: ast.Message, oneof_name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var cap = true;
    for (oneof_name) |ch| {
        if (ch == '_') {
            cap = true;
        } else {
            try buf.append(arena, if (cap) std.ascii.toUpper(ch) else ch);
            cap = false;
        }
    }
    const candidate = try buf.toOwnedSlice(arena);
    for (m.nested_messages) |nm| {
        if (std.mem.eql(u8, nm.name, candidate)) {
            return std.fmt.allocPrint(arena, "{s}Oneof", .{candidate});
        }
    }
    for (m.nested_enums) |ne| {
        if (std.mem.eql(u8, ne.name, candidate)) {
            return std.fmt.allocPrint(arena, "{s}Oneof", .{candidate});
        }
    }
    return candidate;
}

fn writePascalCase(w: *std.Io.Writer, snake: []const u8) !void {
    var cap = true;
    for (snake) |ch| {
        if (ch == '_') {
            cap = true;
        } else {
            try w.writeByte(if (cap) std.ascii.toUpper(ch) else ch);
            cap = false;
        }
    }
}

/// Backward-compatible single-file generator.
pub fn generate(
    arena: std.mem.Allocator,
    _: *const ast.File,
    res: *const resolver.Resolver,
    w: *std.Io.Writer,
) !void {
    return generateFile(arena, 0, res, w);
}

/// Generates a single `.pb.zig` file within a multi-file resolved workspace.
pub fn generateFile(
    arena: std.mem.Allocator,
    file_idx: usize,
    res: *const resolver.Resolver,
    w: *std.Io.Writer,
) !void {
    const file = &res.files[file_idx];
    const pkg_scope = file.package orelse "";

    var imp_table = ImportTable{ .file_idx = file_idx };
    for (file.messages) |m| {
        const fqn = if (pkg_scope.len == 0)
            m.name
        else
            try std.fmt.allocPrint(arena, "{s}.{s}", .{ pkg_scope, m.name });
        try imp_table.collectMessage(arena, m, fqn, res);
    }

    const ctx = GenCtx{
        .arena = arena,
        .file_idx = file_idx,
        .res = res,
        .imports = &imp_table,
    };

    try w.writeAll(
        \\// Auto-generated by zig-protoc (Zig 0.17.1, zero-allocation runtime).
        \\// DO NOT EDIT.
        \\const wire = @import("proto_wire");
        \\
    );

    for (imp_table.ordered_deps.items, 0..) |dep_idx, alias_id| {
        const rel = try relativeZigImport(arena, file.name, res.files[dep_idx].name);
        try w.print("const _imp_{d} = @import(\"{s}\");\n", .{ alias_id, rel });
    }
    try w.writeAll("\n");

    for (file.enums) |e| {
        try emitEnum(e, 0, w);
        try w.writeAll("\n");
    }

    for (file.messages) |m| {
        const fqn = if (pkg_scope.len == 0)
            m.name
        else
            try std.fmt.allocPrint(arena, "{s}.{s}", .{ pkg_scope, m.name });
        try emitMessage(ctx, m, fqn, 0, w);
        try w.writeAll("\n");
    }
}

fn emitEnum(e: ast.Enum, indent: usize, w: *std.Io.Writer) !void {
    try writeIndent(w, indent);
    try w.writeAll("pub const ");
    try writeIdent(w, e.name);
    try w.writeAll(" = enum(i32) {\n");

    var has_aliases = false;
    for (e.values, 0..) |v, i| {
        var is_alias = false;
        for (e.values[0..i]) |prev| {
            if (prev.number == v.number) {
                is_alias = true;
                has_aliases = true;
                break;
            }
        }
        if (!is_alias) {
            try writeIndent(w, indent + 1);
            try writeIdent(w, v.name);
            try w.print(" = {d},\n", .{v.number});
        }
    }

    try writeIndent(w, indent + 1);
    try w.writeAll("_,\n");

    if (has_aliases) {
        try w.writeAll("\n");
        for (e.values, 0..) |v, i| {
            for (e.values[0..i]) |prev| {
                if (prev.number == v.number) {
                    try writeIndent(w, indent + 1);
                    try w.writeAll("pub const ");
                    try writeIdent(w, v.name);
                    try w.writeAll(": @This() = .");
                    try writeIdent(w, prev.name);
                    try w.writeAll(";\n");
                    break;
                }
            }
        }
    }

    try writeIndent(w, indent);
    try w.writeAll("};\n");
}

fn emitMessage(ctx: GenCtx, m: ast.Message, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    try writeIndent(w, indent);
    try w.writeAll("pub const ");
    try writeIdent(w, m.name);
    try w.writeAll(" = struct {\n");

    for (m.nested_enums) |ne| {
        try emitEnum(ne, indent + 1, w);
        try w.writeAll("\n");
    }

    for (m.nested_messages) |nm| {
        const child_fqn = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ scope_fqn, nm.name });
        try emitMessage(ctx, nm, child_fqn, indent + 1, w);
        try w.writeAll("\n");
    }

    for (m.oneofs) |o| {
        try writeIndent(w, indent + 1);
        try w.writeAll("pub const ");
        const otype = try oneofZigTypeName(ctx.arena, m, o.name);
        try writeIdent(w, otype);
        try w.writeAll(" = union(enum) {\n");
        for (o.fields) |f| {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            try writeIndent(w, indent + 2);
            try writeIdent(w, f.name);
            try w.writeAll(": ");
            switch (rt) {
                .scalar => |s| try w.writeAll(s.zig_type),
                .@"enum" => |e| try ctx.imports.writeSymPath(w, e),
                .message => |sym| {
                    if (try ctx.res.createsCycle(scope_fqn, sym.proto_fqn)) {
                        try w.writeAll("wire.Lazy(");
                        try ctx.imports.writeSymPath(w, sym);
                        try w.writeAll(")");
                    } else {
                        try ctx.imports.writeSymPath(w, sym);
                    }
                },
            }
            try w.writeAll(",\n");
        }
        try writeIndent(w, indent + 1);
        try w.writeAll("};\n\n");
    }

    for (m.fields) |f| {
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
        try writeIndent(w, indent + 1);
        try writeIdent(w, f.name);
        try w.writeAll(": ");
        if (f.label == .repeated) {
            try w.writeAll("wire.Repeated(");
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(") = .empty,\n");
        } else if (rt == .message) {
            if (try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn)) {
                try w.writeAll("?wire.Lazy(");
                try ctx.imports.writeSymPath(w, rt.message);
                try w.writeAll(") = null,\n");
            } else {
                try w.writeAll("?");
                try ctx.imports.writeSymPath(w, rt.message);
                try w.writeAll(" = null,\n");
            }
        } else if (ctx.res.hasExplicitPresence(ctx.file_idx, f, rt)) {
            try w.writeAll("?");
            switch (rt) {
                .scalar => |s| try w.writeAll(s.zig_type),
                .@"enum" => |e| try ctx.imports.writeSymPath(w, e),
                .message => unreachable,
            }
            try w.writeAll(" = null,\n");
        } else {
            switch (rt) {
                .scalar => |s| try w.print("{s} = {s},\n", .{ s.zig_type, s.default_expr }),
                .@"enum" => |e| {
                    try ctx.imports.writeSymPath(w, e);
                    try w.writeAll(" = @fromBackingInt(0),\n");
                },
                .message => unreachable,
            }
        }
    }

    for (m.maps) |mp| {
        const kt = try ctx.res.resolveType(scope_fqn, mp.key_type);
        const vt = try ctx.res.resolveType(scope_fqn, mp.value_type);
        const utf8 = ctx.res.validatesUtf8(ctx.file_idx, mp.options);
        try writeIndent(w, indent + 1);
        try writeIdent(w, mp.name);
        try w.writeAll(": wire.Map(");
        try writeCodecExpr(ctx, w, kt, utf8);
        try w.writeAll(", ");
        try writeCodecExpr(ctx, w, vt, utf8);
        try w.writeAll(") = .empty,\n");
    }

    for (m.oneofs) |o| {
        try writeIndent(w, indent + 1);
        try writeIdent(w, o.name);
        try w.writeAll(": ?@This().");
        const otype = try oneofZigTypeName(ctx.arena, m, o.name);
        try writeIdent(w, otype);
        try w.writeAll(" = null,\n");
    }

    var has_members = m.fields.len > 0 or m.maps.len > 0;
    for (m.oneofs) |o| {
        if (o.fields.len > 0) has_members = true;
    }

    var has_repeated_or_map = m.maps.len > 0;
    for (m.fields) |f| {
        if (f.label == .repeated) has_repeated_or_map = true;
    }

    // encodedSize()
    try w.writeAll("\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn encodedSize(self: *const @This()) usize {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("@setEvalBranchQuota(100_000);\n");
    if (!has_members) {
        try writeIndent(w, indent + 2);
        try w.writeAll("_ = self;\n");
        try writeIndent(w, indent + 2);
        try w.writeAll("return 0;\n");
    } else {
        try writeIndent(w, indent + 2);
        try w.writeAll("var total: usize = 0;\n");
        for (m.fields) |f| {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            try emitFieldSize(ctx, f, rt, indent + 2, w);
        }
        for (m.maps) |mp| {
            try writeIndent(w, indent + 2);
            try w.writeAll("total += self.");
            try writeIdent(w, mp.name);
            try w.print(".encodedSize({d});\n", .{mp.number});
        }
        for (m.oneofs) |o| try emitOneofSize(ctx, o, scope_fqn, indent + 2, w);
        try writeIndent(w, indent + 2);
        try w.writeAll("return total;\n");
    }
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    // encode(w: anytype)
    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn encode(self: *const @This(), w: anytype) wire.WriterError(@TypeOf(w))!void {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("@setEvalBranchQuota(100_000);\n");
    if (!has_members) {
        try writeIndent(w, indent + 2);
        try w.writeAll("_ = self;\n");
    } else {
        for (m.fields) |f| {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            try emitFieldEncode(ctx, f, rt, indent + 2, w);
        }
        for (m.maps) |mp| {
            try writeIndent(w, indent + 2);
            try w.writeAll("try self.");
            try writeIdent(w, mp.name);
            try w.print(".encode({d}, w);\n", .{mp.number});
        }
        for (m.oneofs) |o| try emitOneofEncode(ctx, o, scope_fqn, indent + 2, w);
    }
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    // encodeReverse(rw: *wire.ReverseWriter)
    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn encodeReverse(self: *const @This(), rw: *wire.ReverseWriter) wire.EncodeError!void {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("@setEvalBranchQuota(100_000);\n");
    if (!has_members) {
        try writeIndent(w, indent + 2);
        try w.writeAll("_ = self;\n");
        try writeIndent(w, indent + 2);
        try w.writeAll("_ = rw;\n");
    } else {
        var oi = m.oneofs.len;
        while (oi > 0) {
            oi -= 1;
            try emitOneofReverse(ctx, m.oneofs[oi], scope_fqn, indent + 2, w);
        }
        var mi = m.maps.len;
        while (mi > 0) {
            mi -= 1;
            const mp = m.maps[mi];
            try writeIndent(w, indent + 2);
            try w.writeAll("try self.");
            try writeIdent(w, mp.name);
            try w.print(".encodeReverse({d}, rw);\n", .{mp.number});
        }
        var fi = m.fields.len;
        while (fi > 0) {
            fi -= 1;
            const f = m.fields[fi];
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            try emitFieldReverse(ctx, f, rt, indent + 2, w);
        }
    }
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    // encodeSlice(buf: []u8)
    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn encodeSlice(self: *const @This(), buf: []u8) wire.EncodeError![]const u8 {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("var rw = wire.ReverseWriter.init(buf);\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("try self.encodeReverse(&rw);\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("return rw.written();\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try emitSkipOrReject(m, has_members, indent + 1, w);
    try w.writeAll("\n");

    // validateDepth
    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn validateDepth(bytes: []const u8, depth: u32) wire.DecodeError!void {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("@setEvalBranchQuota(100_000);\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("if (depth == 0) return error.RecursionLimitExceeded;\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("const next_depth = depth - 1;\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("var r = wire.Reader.init(bytes);\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("while (try r.readRawTag()) |raw_tag| {\n");
    if (!has_members) {
        try writeIndent(w, indent + 3);
        try w.writeAll("try @This()._protozSkipOrReject(&r, raw_tag, next_depth);\n");
    } else {
        try writeIndent(w, indent + 3);
        try w.writeAll("switch (raw_tag) {\n");
        for (m.fields) |f| {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            try emitFieldValidate(ctx, f, rt, indent + 4, w);
        }
        for (m.maps) |mp| {
            const kt = try ctx.res.resolveType(scope_fqn, mp.key_type);
            const vt = try ctx.res.resolveType(scope_fqn, mp.value_type);
            const utf8 = ctx.res.validatesUtf8(ctx.file_idx, mp.options);
            try writeIndent(w, indent + 4);
            try w.print("comptime wire.rawTag({d}, .len) => try wire.Map(", .{mp.number});
            try writeCodecExpr(ctx, w, kt, utf8);
            try w.writeAll(", ");
            try writeCodecExpr(ctx, w, vt, utf8);
            try w.writeAll(").validateEntry(try r.readBytes(), next_depth),\n");
        }
        for (m.oneofs) |o| try emitOneofValidate(ctx, o, scope_fqn, indent + 4, w);
        try writeIndent(w, indent + 4);
        try w.writeAll("else => try @This()._protozSkipOrReject(&r, raw_tag, next_depth),\n");
        try writeIndent(w, indent + 3);
        try w.writeAll("}\n");
    }
    try writeIndent(w, indent + 2);
    try w.writeAll("}\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    // decode / decodeDepth / mergeDepth
    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn decode(bytes: []const u8) wire.DecodeError!@This() {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("return @This().decodeDepth(bytes, wire.max_recursion_depth);\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn decodeDepth(bytes: []const u8, depth: u32) wire.DecodeError!@This() {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("var self: @This() = .{};\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("try self.mergeDepth(bytes, depth);\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("return self;\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn mergeDepth(self: *@This(), bytes: []const u8, depth: u32) wire.DecodeError!void {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("@setEvalBranchQuota(100_000);\n");
    if (!has_members) {
        try writeIndent(w, indent + 2);
        try w.writeAll("_ = self;\n");
        try writeIndent(w, indent + 2);
        try w.writeAll("return @This().validateDepth(bytes, depth);\n");
    } else {
        try writeIndent(w, indent + 2);
        try w.writeAll("if (depth == 0) return error.RecursionLimitExceeded;\n");
        try writeIndent(w, indent + 2);
        try w.writeAll("const next_depth = depth - 1;\n");
        try writeIndent(w, indent + 2);
        try w.writeAll("var r = wire.Reader.init(bytes);\n");
        if (has_repeated_or_map) {
            try writeIndent(w, indent + 2);
            try w.writeAll("while (true) {\n");
            try writeIndent(w, indent + 3);
            try w.writeAll("const tag_ptr = r.ptr;\n");
            try writeIndent(w, indent + 3);
            try w.writeAll("const raw_tag = (try r.readRawTag()) orelse break;\n");
        } else {
            try writeIndent(w, indent + 2);
            try w.writeAll("while (try r.readRawTag()) |raw_tag| {\n");
        }
        try writeIndent(w, indent + 3);
        try w.writeAll("switch (raw_tag) {\n");

        for (m.fields) |f| {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            try emitFieldDecode(ctx, f, rt, scope_fqn, indent + 4, w);
        }
        for (m.maps) |mp| {
            try writeIndent(w, indent + 4);
            try w.print("comptime wire.rawTag({d}, .len) => try self.", .{mp.number});
            try writeIdent(w, mp.name);
            try w.print(".recordEntry(bytes.ptr, tag_ptr, &r, {d}, next_depth),\n", .{mp.number});
        }
        for (m.oneofs) |o| try emitOneofDecode(ctx, o, scope_fqn, indent + 4, w);

        try writeIndent(w, indent + 4);
        try w.writeAll("else => try @This()._protozSkipOrReject(&r, raw_tag, next_depth),\n");
        try writeIndent(w, indent + 3);
        try w.writeAll("}\n");
        try writeIndent(w, indent + 2);
        try w.writeAll("}\n");
    }
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n");

    try writeIndent(w, indent);
    try w.writeAll("};\n");
}

fn emitSkipOrReject(m: ast.Message, has_members: bool, indent: usize, w: *std.Io.Writer) !void {
    try writeIndent(w, indent);
    try w.writeAll("fn _protozSkipOrReject(r: *wire.Reader, raw_tag: u32, depth: u32) wire.DecodeError!void {\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("@branchHint(.cold);\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("const tag = try wire.decodeTag(raw_tag);\n");
    if (!has_members) {
        try writeIndent(w, indent + 1);
        try w.writeAll("return r.skipField(tag, depth);\n");
    } else {
        try writeIndent(w, indent + 1);
        try w.writeAll("switch (tag.field_number) {\n");
        try writeIndent(w, indent + 2);
        var first = true;
        for (m.fields) |f| {
            if (!first) try w.writeAll(", ");
            try w.print("{d}", .{f.number});
            first = false;
        }
        for (m.maps) |mp| {
            if (!first) try w.writeAll(", ");
            try w.print("{d}", .{mp.number});
            first = false;
        }
        for (m.oneofs) |o| {
            for (o.fields) |f| {
                if (!first) try w.writeAll(", ");
                try w.print("{d}", .{f.number});
                first = false;
            }
        }
        try w.writeAll(" => return error.WireTypeMismatch,\n");
        try writeIndent(w, indent + 2);
        try w.writeAll("else => return r.skipField(tag, depth),\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("}\n");
    }
    try writeIndent(w, indent);
    try w.writeAll("}\n");
}

fn emitFieldSize(ctx: GenCtx, f: ast.Field, rt: resolver.ResolvedType, indent: usize, w: *std.Io.Writer) !void {
    if (f.label == .repeated) {
        const pack = ctx.res.isPacked(ctx.file_idx, f);
        try writeIndent(w, indent);
        try w.writeAll("total += self.");
        try writeIdent(w, f.name);
        try w.print(".encodedSize({d}, {});\n", .{ f.number, pack });
        return;
    }
    if (rt == .message) {
        try writeIndent(w, indent);
        try w.writeAll("if (self.");
        try writeIdent(w, f.name);
        try w.writeAll(") |val| {\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("const sub = val.encodedSize();\n");
        try writeIndent(w, indent + 1);
        try w.print("total += wire.tagSize({d}) + wire.varintSize(sub) + sub;\n", .{f.number});
        try writeIndent(w, indent);
        try w.writeAll("}\n");
        return;
    }
    const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
    if (ctx.res.hasExplicitPresence(ctx.file_idx, f, rt)) {
        try writeIndent(w, indent);
        try w.writeAll("if (self.");
        try writeIdent(w, f.name);
        try w.print(") |val| total += wire.tagSize({d}) + ", .{f.number});
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".size(val);\n");
    } else {
        try writeIndent(w, indent);
        try w.writeAll("if (!");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".isDefault(self.");
        try writeIdent(w, f.name);
        try w.print(")) total += wire.tagSize({d}) + ", .{f.number});
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".size(self.");
        try writeIdent(w, f.name);
        try w.writeAll(");\n");
    }
}

fn emitFieldEncode(ctx: GenCtx, f: ast.Field, rt: resolver.ResolvedType, indent: usize, w: *std.Io.Writer) !void {
    if (f.label == .repeated) {
        const pack = ctx.res.isPacked(ctx.file_idx, f);
        try writeIndent(w, indent);
        try w.writeAll("try self.");
        try writeIdent(w, f.name);
        try w.print(".encode({d}, {}, w);\n", .{ f.number, pack });
        return;
    }
    if (rt == .message) {
        try writeIndent(w, indent);
        try w.writeAll("if (self.");
        try writeIdent(w, f.name);
        try w.writeAll(") |val| {\n");
        try writeIndent(w, indent + 1);
        try w.print("try wire.writeTag(w, {d}, .len);\n", .{f.number});
        try writeIndent(w, indent + 1);
        try w.writeAll("try wire.writeVarint(w, val.encodedSize());\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("try val.encode(w);\n");
        try writeIndent(w, indent);
        try w.writeAll("}\n");
        return;
    }
    const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
    if (ctx.res.hasExplicitPresence(ctx.file_idx, f, rt)) {
        try writeIndent(w, indent);
        try w.writeAll("if (self.");
        try writeIdent(w, f.name);
        try w.writeAll(") |val| {\n");
        try writeIndent(w, indent + 1);
        try w.print("try wire.writeTag(w, {d}, ", .{f.number});
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".wire_type);\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("try ");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".write(w, val);\n");
        try writeIndent(w, indent);
        try w.writeAll("}\n");
    } else {
        try writeIndent(w, indent);
        try w.writeAll("if (!");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".isDefault(self.");
        try writeIdent(w, f.name);
        try w.writeAll(")) {\n");
        try writeIndent(w, indent + 1);
        try w.print("try wire.writeTag(w, {d}, ", .{f.number});
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".wire_type);\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("try ");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".write(w, self.");
        try writeIdent(w, f.name);
        try w.writeAll(");\n");
        try writeIndent(w, indent);
        try w.writeAll("}\n");
    }
}

fn emitFieldReverse(ctx: GenCtx, f: ast.Field, rt: resolver.ResolvedType, indent: usize, w: *std.Io.Writer) !void {
    if (f.label == .repeated) {
        const pack = ctx.res.isPacked(ctx.file_idx, f);
        try writeIndent(w, indent);
        try w.writeAll("try self.");
        try writeIdent(w, f.name);
        try w.print(".encodeReverse({d}, {}, rw);\n", .{ f.number, pack });
        return;
    }
    if (rt == .message) {
        try writeIndent(w, indent);
        try w.writeAll("if (self.");
        try writeIdent(w, f.name);
        try w.writeAll(") |val| {\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("const end = rw.pos;\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("try val.encodeReverse(rw);\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("try rw.writeVarint(end - rw.pos);\n");
        try writeIndent(w, indent + 1);
        try w.print("try rw.writeTag({d}, .len);\n", .{f.number});
        try writeIndent(w, indent);
        try w.writeAll("}\n");
        return;
    }
    const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
    if (ctx.res.hasExplicitPresence(ctx.file_idx, f, rt)) {
        try writeIndent(w, indent);
        try w.writeAll("if (self.");
        try writeIdent(w, f.name);
        try w.writeAll(") |val| {\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("try ");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".writeReverse(rw, val);\n");
        try writeIndent(w, indent + 1);
        try w.print("try rw.writeTag({d}, ", .{f.number});
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".wire_type);\n");
        try writeIndent(w, indent);
        try w.writeAll("}\n");
    } else {
        try writeIndent(w, indent);
        try w.writeAll("if (!");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".isDefault(self.");
        try writeIdent(w, f.name);
        try w.writeAll(")) {\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("try ");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".writeReverse(rw, self.");
        try writeIdent(w, f.name);
        try w.writeAll(");\n");
        try writeIndent(w, indent + 1);
        try w.print("try rw.writeTag({d}, ", .{f.number});
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".wire_type);\n");
        try writeIndent(w, indent);
        try w.writeAll("}\n");
    }
}

fn emitFieldValidate(ctx: GenCtx, f: ast.Field, rt: resolver.ResolvedType, indent: usize, w: *std.Io.Writer) !void {
    const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
    if (f.label == .repeated) {
        if (isPackable(rt)) {
            try writeIndent(w, indent);
            try w.print("comptime wire.rawTag({d}, .len) => try wire.Repeated(", .{f.number});
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(").validatePacked(try r.readBytes()),\n");

            try writeIndent(w, indent);
            try w.print("comptime wire.rawTag({d}, ", .{f.number});
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".wire_type) => try ");
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".validate(&r, next_depth),\n");
        } else {
            try writeIndent(w, indent);
            try w.print("comptime wire.rawTag({d}, .len) => try ", .{f.number});
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".validate(&r, next_depth),\n");
        }
    } else if (rt == .message) {
        try writeIndent(w, indent);
        try w.print("comptime wire.rawTag({d}, .len) => try ", .{f.number});
        try ctx.imports.writeSymPath(w, rt.message);
        try w.writeAll(".validateDepth(try r.readBytes(), next_depth),\n");
    } else {
        try writeIndent(w, indent);
        try w.print("comptime wire.rawTag({d}, ", .{f.number});
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".wire_type) => try ");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".validate(&r, next_depth),\n");
    }
}

fn emitFieldDecode(ctx: GenCtx, f: ast.Field, rt: resolver.ResolvedType, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
    if (f.label == .repeated) {
        if (isPackable(rt)) {
            try writeIndent(w, indent);
            try w.print("comptime wire.rawTag({d}, .len) => try self.", .{f.number});
            try writeIdent(w, f.name);
            try w.print(".recordPacked(bytes.ptr, tag_ptr, &r, {d}),\n", .{f.number});

            try writeIndent(w, indent);
            try w.print("comptime wire.rawTag({d}, ", .{f.number});
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".wire_type) => try self.");
            try writeIdent(w, f.name);
            try w.print(".recordUnpacked(bytes.ptr, tag_ptr, &r, {d}, next_depth),\n", .{f.number});
        } else {
            try writeIndent(w, indent);
            try w.print("comptime wire.rawTag({d}, .len) => try self.", .{f.number});
            try writeIdent(w, f.name);
            try w.print(".recordUnpacked(bytes.ptr, tag_ptr, &r, {d}, next_depth),\n", .{f.number});
        }
    } else if (rt == .message) {
        const cyclic = try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn);
        try writeIndent(w, indent);
        try w.print("comptime wire.rawTag({d}, .len) => {{\n", .{f.number});
        try writeIndent(w, indent + 1);
        try w.writeAll("const sub_bytes = try r.readBytes();\n");
        if (cyclic) {
            try writeIndent(w, indent + 1);
            try w.writeAll("try ");
            try ctx.imports.writeSymPath(w, rt.message);
            try w.writeAll(".validateDepth(sub_bytes, next_depth);\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("if (self.");
            try writeIdent(w, f.name);
            try w.writeAll(") |*existing| {\n");
            try writeIndent(w, indent + 2);
            try w.print("try existing.mergeRaw(sub_bytes, {d});\n", .{f.number});
            try writeIndent(w, indent + 1);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("self.");
            try writeIdent(w, f.name);
            try w.writeAll(" = .{ .raw = sub_bytes };\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("}\n");
        } else {
            try writeIndent(w, indent + 1);
            try w.writeAll("if (self.");
            try writeIdent(w, f.name);
            try w.writeAll(") |*existing| {\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("try existing.mergeDepth(sub_bytes, next_depth);\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("self.");
            try writeIdent(w, f.name);
            try w.writeAll(" = try ");
            try ctx.imports.writeSymPath(w, rt.message);
            try w.writeAll(".decodeDepth(sub_bytes, next_depth);\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("}\n");
        }
        try writeIndent(w, indent);
        try w.writeAll("},\n");
    } else {
        try writeIndent(w, indent);
        try w.print("comptime wire.rawTag({d}, ", .{f.number});
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".wire_type) => self.");
        try writeIdent(w, f.name);
        try w.writeAll(" = try ");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".read(&r, next_depth),\n");
    }
}

fn emitOneofSize(ctx: GenCtx, o: ast.Oneof, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    if (o.fields.len == 0) return;
    try writeIndent(w, indent);
    try w.writeAll("if (self.");
    try writeIdent(w, o.name);
    try w.writeAll(") |u| switch (u) {\n");
    for (o.fields) |f| {
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
        try writeIndent(w, indent + 1);
        try w.writeAll(".");
        try writeIdent(w, f.name);
        try w.writeAll(" => |val| ");
        if (rt == .message) {
            try w.print("{{ const sub = val.encodedSize(); total += wire.tagSize({d}) + wire.varintSize(sub) + sub; }},\n", .{f.number});
        } else {
            try w.print("total += wire.tagSize({d}) + ", .{f.number});
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".size(val),\n");
        }
    }
    try writeIndent(w, indent);
    try w.writeAll("};\n");
}

fn emitOneofEncode(ctx: GenCtx, o: ast.Oneof, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    if (o.fields.len == 0) return;
    try writeIndent(w, indent);
    try w.writeAll("if (self.");
    try writeIdent(w, o.name);
    try w.writeAll(") |u| switch (u) {\n");
    for (o.fields) |f| {
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
        try writeIndent(w, indent + 1);
        try w.writeAll(".");
        try writeIdent(w, f.name);
        try w.writeAll(" => |val| {\n");
        if (rt == .message) {
            try writeIndent(w, indent + 2);
            try w.print("try wire.writeTag(w, {d}, .len);\n", .{f.number});
            try writeIndent(w, indent + 2);
            try w.writeAll("try wire.writeVarint(w, val.encodedSize());\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("try val.encode(w);\n");
        } else {
            try writeIndent(w, indent + 2);
            try w.print("try wire.writeTag(w, {d}, ", .{f.number});
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".wire_type);\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("try ");
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".write(w, val);\n");
        }
        try writeIndent(w, indent + 1);
        try w.writeAll("},\n");
    }
    try writeIndent(w, indent);
    try w.writeAll("};\n");
}

fn emitOneofReverse(ctx: GenCtx, o: ast.Oneof, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    if (o.fields.len == 0) return;
    try writeIndent(w, indent);
    try w.writeAll("if (self.");
    try writeIdent(w, o.name);
    try w.writeAll(") |u| switch (u) {\n");
    for (o.fields) |f| {
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
        try writeIndent(w, indent + 1);
        try w.writeAll(".");
        try writeIdent(w, f.name);
        try w.writeAll(" => |val| {\n");
        if (rt == .message) {
            try writeIndent(w, indent + 2);
            try w.writeAll("const end = rw.pos;\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("try val.encodeReverse(rw);\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("try rw.writeVarint(end - rw.pos);\n");
            try writeIndent(w, indent + 2);
            try w.print("try rw.writeTag({d}, .len);\n", .{f.number});
        } else {
            try writeIndent(w, indent + 2);
            try w.writeAll("try ");
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".writeReverse(rw, val);\n");
            try writeIndent(w, indent + 2);
            try w.print("try rw.writeTag({d}, ", .{f.number});
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".wire_type);\n");
        }
        try writeIndent(w, indent + 1);
        try w.writeAll("},\n");
    }
    try writeIndent(w, indent);
    try w.writeAll("};\n");
}

fn emitOneofValidate(ctx: GenCtx, o: ast.Oneof, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    for (o.fields) |f| {
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
        try writeIndent(w, indent);
        if (rt == .message) {
            try w.print("comptime wire.rawTag({d}, .len) => try ", .{f.number});
            try ctx.imports.writeSymPath(w, rt.message);
            try w.writeAll(".validateDepth(try r.readBytes(), next_depth),\n");
        } else {
            try w.print("comptime wire.rawTag({d}, ", .{f.number});
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".wire_type) => try ");
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".validate(&r, next_depth),\n");
        }
    }
}

fn emitOneofDecode(ctx: GenCtx, o: ast.Oneof, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    for (o.fields) |f| {
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
        if (rt == .message) {
            const cyclic = try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn);
            try writeIndent(w, indent);
            try w.print("comptime wire.rawTag({d}, .len) => {{\n", .{f.number});
            try writeIndent(w, indent + 1);
            try w.writeAll("const sub_bytes = try r.readBytes();\n");
            if (cyclic) {
                try writeIndent(w, indent + 1);
                try w.writeAll("try ");
                try ctx.imports.writeSymPath(w, rt.message);
                try w.writeAll(".validateDepth(sub_bytes, next_depth);\n");
                try writeIndent(w, indent + 1);
                try w.writeAll("if (self.");
                try writeIdent(w, o.name);
                try w.writeAll(" != null and self.");
                try writeIdent(w, o.name);
                try w.writeAll(".? == .");
                try writeIdent(w, f.name);
                try w.writeAll(") {\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("try self.");
                try writeIdent(w, o.name);
                try w.writeAll(".?.");
                try writeIdent(w, f.name);
                try w.print(".mergeRaw(sub_bytes, {d});\n", .{f.number});
                try writeIndent(w, indent + 1);
                try w.writeAll("} else {\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("self.");
                try writeIdent(w, o.name);
                try w.writeAll(" = .{ .");
                try writeIdent(w, f.name);
                try w.writeAll(" = .{ .raw = sub_bytes } };\n");
                try writeIndent(w, indent + 1);
                try w.writeAll("}\n");
            } else {
                try writeIndent(w, indent + 1);
                try w.writeAll("if (self.");
                try writeIdent(w, o.name);
                try w.writeAll(" != null and self.");
                try writeIdent(w, o.name);
                try w.writeAll(".? == .");
                try writeIdent(w, f.name);
                try w.writeAll(") {\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("try self.");
                try writeIdent(w, o.name);
                try w.writeAll(".?.");
                try writeIdent(w, f.name);
                try w.writeAll(".mergeDepth(sub_bytes, next_depth);\n");
                try writeIndent(w, indent + 1);
                try w.writeAll("} else {\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("self.");
                try writeIdent(w, o.name);
                try w.writeAll(" = .{ .");
                try writeIdent(w, f.name);
                try w.writeAll(" = try ");
                try ctx.imports.writeSymPath(w, rt.message);
                try w.writeAll(".decodeDepth(sub_bytes, next_depth) };\n");
                try writeIndent(w, indent + 1);
                try w.writeAll("}\n");
            }
            try writeIndent(w, indent);
            try w.writeAll("},\n");
        } else {
            try writeIndent(w, indent);
            try w.print("comptime wire.rawTag({d}, ", .{f.number});
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".wire_type) => self.");
            try writeIdent(w, o.name);
            try w.writeAll(" = .{ .");
            try writeIdent(w, f.name);
            try w.writeAll(" = try ");
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".read(&r, next_depth) },\n");
        }
    }
}
