const std = @import("std");
const ast = @import("ast.zig");
const resolver = @import("resolver.zig");

pub const CodegenOptions = struct {
    wire_import: []const u8 = "proto_wire",
    preserve_unknown_fields: bool = false,
};

pub fn makeUniqueRootExportName(
    arena: std.mem.Allocator,
    proto_name: []const u8,
    used: *std.StringHashMapUnmanaged(void),
) ![]const u8 {
    const stem = if (std.mem.endsWith(u8, proto_name, ".proto"))
        proto_name[0 .. proto_name.len - ".proto".len]
    else
        proto_name;

    var buf: std.ArrayList(u8) = .empty;
    if (stem.len == 0 or std.ascii.isDigit(stem[0])) {
        try buf.append(arena, '_');
    }
    for (stem) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            try buf.append(arena, ch);
        } else {
            try buf.append(arena, '_');
        }
    }

    const base = try buf.toOwnedSlice(arena);
    if (!used.contains(base)) {
        try used.put(arena, base, {});
        return base;
    }

    var suffix: usize = 2;
    while (true) : (suffix += 1) {
        const candidate = try std.fmt.allocPrint(arena, "{s}_{d}", .{ base, suffix });
        if (!used.contains(candidate)) {
            try used.put(arena, candidate, {});
            return candidate;
        }
    }
}

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

    fn noteFile(self: *ImportTable, arena: std.mem.Allocator, dep_idx: usize) !void {
        if (dep_idx == self.file_idx) return;
        if (!self.alias_by_file.contains(dep_idx)) {
            const alias_id = self.ordered_deps.items.len;
            try self.alias_by_file.put(arena, dep_idx, alias_id);
            try self.ordered_deps.append(arena, dep_idx);
        }
    }

    fn noteSymbol(self: *ImportTable, arena: std.mem.Allocator, sym: resolver.Symbol) !void {
        return self.noteFile(arena, sym.file_index);
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

    fn collectService(
        self: *ImportTable,
        arena: std.mem.Allocator,
        svc: ast.Service,
        pkg_scope: []const u8,
        res: *const resolver.Resolver,
    ) !void {
        for (svc.rpcs) |rpc| {
            const req_rt = try res.resolveType(pkg_scope, rpc.req_type);
            if (req_rt == .message) try self.noteSymbol(arena, req_rt.message);
            const res_rt = try res.resolveType(pkg_scope, rpc.res_type);
            if (res_rt == .message) try self.noteSymbol(arena, res_rt.message);
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
    opts: CodegenOptions,
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

fn writeMapType(ctx: GenCtx, scope_fqn: []const u8, mp: ast.MapField, w: *std.Io.Writer) !void {
    const kt = try ctx.res.resolveType(scope_fqn, mp.key_type);
    const vt = try ctx.res.resolveType(scope_fqn, mp.value_type);
    const utf8 = ctx.res.validatesUtf8(ctx.file_idx, mp.options);
    try w.writeAll("wire.Map(");
    try writeCodecExpr(ctx, w, kt, utf8);
    try w.writeAll(", ");
    try writeCodecExpr(ctx, w, vt, utf8);
    try w.writeAll(")");
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

fn unknownFieldsMemberName(m: ast.Message) []const u8 {
    for (m.fields) |f| if (std.mem.eql(u8, f.name, "_unknown_fields")) return "_protoz_unknown_fields";
    for (m.maps) |mp| if (std.mem.eql(u8, mp.name, "_unknown_fields")) return "_protoz_unknown_fields";
    for (m.oneofs) |o| if (std.mem.eql(u8, o.name, "_unknown_fields")) return "_protoz_unknown_fields";
    return "_unknown_fields";
}

fn writeCamelCase(w: *std.Io.Writer, snake: []const u8, initial_cap: bool) !void {
    var cap = initial_cap;
    for (snake) |ch| {
        if (ch == '_') {
            cap = true;
        } else if (cap) {
            try w.writeByte(std.ascii.toUpper(ch));
            cap = false;
        } else {
            try w.writeByte(ch);
        }
    }
}

fn writePascalCase(w: *std.Io.Writer, snake: []const u8) !void {
    return writeCamelCase(w, snake, true);
}

fn writeLowerCamelCase(w: *std.Io.Writer, proto_name: []const u8) !void {
    return writeCamelCase(w, proto_name, false);
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

fn findFileIndexByImport(res: *const resolver.Resolver, raw_imp: []const u8) ?usize {
    const imp = if (std.mem.startsWith(u8, raw_imp, "./")) raw_imp[2..] else raw_imp;
    for (res.files, 0..) |f, idx| {
        if (std.mem.eql(u8, f.name, imp)) return idx;
    }
    return null;
}

fn collectPublicDeps(
    arena: std.mem.Allocator,
    file_idx: usize,
    res: *const resolver.Resolver,
    visited: *std.AutoHashMapUnmanaged(usize, void),
    out_deps: *std.ArrayList(usize),
) !void {
    const file = &res.files[file_idx];
    for (file.public_imports) |imp_idx| {
        if (imp_idx >= file.imports.len) continue;
        const dep_idx = findFileIndexByImport(res, file.imports[imp_idx]) orelse continue;
        if (visited.contains(dep_idx)) continue;
        try visited.put(arena, dep_idx, {});
        try out_deps.append(arena, dep_idx);
        try collectPublicDeps(arena, dep_idx, res, visited, out_deps);
    }
}

/// Generates a single `.pb.zig` file with default options.
pub fn generateFile(
    arena: std.mem.Allocator,
    file_idx: usize,
    res: *const resolver.Resolver,
    w: *std.Io.Writer,
) !void {
    return generateFileWithOptions(arena, file_idx, res, w, .{});
}

/// Generates a single `.pb.zig` file with customizable runtime import name and `import public` re-exports.
pub fn generateFileWithOptions(
    arena: std.mem.Allocator,
    file_idx: usize,
    res: *const resolver.Resolver,
    w: *std.Io.Writer,
    opts: CodegenOptions,
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
    for (file.services) |svc| {
        try imp_table.collectService(arena, svc, pkg_scope, res);
    }

    var pub_visited: std.AutoHashMapUnmanaged(usize, void) = .empty;
    try pub_visited.put(arena, file_idx, {});
    var pub_deps: std.ArrayList(usize) = .empty;
    try collectPublicDeps(arena, file_idx, res, &pub_visited, &pub_deps);
    for (pub_deps.items) |dep_idx| {
        try imp_table.noteFile(arena, dep_idx);
    }

    const ctx = GenCtx{
        .arena = arena,
        .file_idx = file_idx,
        .res = res,
        .imports = &imp_table,
        .opts = opts,
    };

    try w.print(
        \\// Auto-generated by zig-protoc (Zig 0.17.1, zero-allocation runtime).
        \\// DO NOT EDIT.
        \\const wire = @import("{s}");
        \\
    , .{opts.wire_import});

    for (imp_table.ordered_deps.items, 0..) |dep_idx, alias_id| {
        const rel = try relativeZigImport(arena, file.name, res.files[dep_idx].name);
        try w.print("const _imp_{d} = @import(\"{s}\");\n", .{ alias_id, rel });
    }
    try w.writeAll("\n");

    // Emit `import public` top-level symbol re-exports (skipping names shadowed locally).
    if (pub_deps.items.len > 0) {
        var declared: std.StringHashMapUnmanaged(void) = .empty;
        for (file.enums) |e| try declared.put(arena, e.name, {});
        for (file.messages) |m| try declared.put(arena, m.name, {});
        for (file.services) |svc| try declared.put(arena, svc.name, {});

        var emitted_any = false;
        for (pub_deps.items) |dep_idx| {
            const alias_id = imp_table.alias_by_file.get(dep_idx).?;
            const dep_file = &res.files[dep_idx];
            for (dep_file.enums) |e| {
                if (try emitReexport(w, arena, &declared, e.name, alias_id)) emitted_any = true;
            }
            for (dep_file.messages) |m| {
                if (try emitReexport(w, arena, &declared, m.name, alias_id)) emitted_any = true;
            }
            for (dep_file.services) |svc| {
                if (try emitReexport(w, arena, &declared, svc.name, alias_id)) emitted_any = true;
            }
        }
        if (emitted_any) try w.writeAll("\n");
    }

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

    for (file.services) |svc| {
        try emitService(ctx, svc, pkg_scope, w);
        try w.writeAll("\n");
    }
}

fn emitReexport(
    w: *std.Io.Writer,
    arena: std.mem.Allocator,
    declared: *std.StringHashMapUnmanaged(void),
    name: []const u8,
    alias_id: usize,
) !bool {
    if (declared.contains(name)) return false;
    try declared.put(arena, name, {});
    try w.writeAll("pub const ");
    try writeIdent(w, name);
    try w.print(" = _imp_{d}.", .{alias_id});
    try writeIdent(w, name);
    try w.writeAll(";\n");
    return true;
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

    var has_full_name_collision = false;
    for (m.fields) |f| if (std.mem.eql(u8, f.name, "proto_full_name")) {
        has_full_name_collision = true;
    };
    for (m.maps) |mp| if (std.mem.eql(u8, mp.name, "proto_full_name")) {
        has_full_name_collision = true;
    };
    for (m.oneofs) |o| if (std.mem.eql(u8, o.name, "proto_full_name")) {
        has_full_name_collision = true;
    };
    if (!has_full_name_collision) {
        try writeIndent(w, indent + 1);
        try w.print("pub const proto_full_name: []const u8 = \"{s}\";\n\n", .{scope_fqn});
    }

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
        try writeIndent(w, indent + 1);
        try writeIdent(w, mp.name);
        try w.writeAll(": ");
        try writeMapType(ctx, scope_fqn, mp, w);
        try w.writeAll(" = .empty,\n");
    }

    for (m.oneofs) |o| {
        try writeIndent(w, indent + 1);
        try writeIdent(w, o.name);
        try w.writeAll(": ?@This().");
        const otype = try oneofZigTypeName(ctx.arena, m, o.name);
        try writeIdent(w, otype);
        try w.writeAll(" = null,\n");
    }

    const uf_name = unknownFieldsMemberName(m);
    if (ctx.opts.preserve_unknown_fields) {
        try writeIndent(w, indent + 1);
        try w.print("{s}: wire.UnknownFields = .empty,\n\n", .{uf_name});

        try writeIndent(w, indent + 1);
        try w.writeAll("pub const _protoz_known_fields: []const u29 = &.{ ");
        var first_kf = true;
        for (m.fields) |f| {
            if (!first_kf) try w.writeAll(", ");
            try w.print("{d}", .{f.number});
            first_kf = false;
        }
        for (m.maps) |mp| {
            if (!first_kf) try w.writeAll(", ");
            try w.print("{d}", .{mp.number});
            first_kf = false;
        }
        for (m.oneofs) |o| {
            for (o.fields) |f| {
                if (!first_kf) try w.writeAll(", ");
                try w.print("{d}", .{f.number});
                first_kf = false;
            }
        }
        try w.writeAll(" };\n");
    }

    var has_members = m.fields.len > 0 or m.maps.len > 0;
    for (m.oneofs) |o| {
        if (o.fields.len > 0) has_members = true;
    }

    var tag_ptr_fields: std.ArrayList([]const u8) = .empty;
    for (m.fields) |f| {
        if (f.label == .repeated) {
            try tag_ptr_fields.append(ctx.arena, f.name);
        } else {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            if (rt == .message and try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn)) {
                try tag_ptr_fields.append(ctx.arena, f.name);
            }
        }
    }
    for (m.maps) |mp| {
        try tag_ptr_fields.append(ctx.arena, mp.name);
    }
    for (m.oneofs) |o| {
        for (o.fields) |f| {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            if (rt == .message and try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn)) {
                try tag_ptr_fields.append(ctx.arena, o.name);
                break;
            }
        }
    }
    if (ctx.opts.preserve_unknown_fields) {
        try tag_ptr_fields.append(ctx.arena, uf_name);
    }

    // encodedSize()
    try w.writeAll("\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn encodedSize(self: *const @This()) usize {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("@setEvalBranchQuota(100_000);\n");
    if (!has_members) {
        if (ctx.opts.preserve_unknown_fields) {
            try writeIndent(w, indent + 2);
            try w.print("return self.{s}.encodedSize(@This()._protoz_known_fields);\n", .{uf_name});
        } else {
            try writeIndent(w, indent + 2);
            try w.writeAll("_ = self;\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("return 0;\n");
        }
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
        if (ctx.opts.preserve_unknown_fields) {
            try writeIndent(w, indent + 2);
            try w.print("total += self.{s}.encodedSize(@This()._protoz_known_fields);\n", .{uf_name});
        }
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
        if (ctx.opts.preserve_unknown_fields) {
            try writeIndent(w, indent + 2);
            try w.print("try self.{s}.encode(@This()._protoz_known_fields, w);\n", .{uf_name});
        } else {
            try writeIndent(w, indent + 2);
            try w.writeAll("_ = self;\n");
        }
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
        if (ctx.opts.preserve_unknown_fields) {
            try writeIndent(w, indent + 2);
            try w.print("try self.{s}.encode(@This()._protoz_known_fields, w);\n", .{uf_name});
        }
    }
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    // encodeReverse(rw: *wire.ReverseWriter)
    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn encodeReverse(self: *const @This(), rw: *wire.ReverseWriter) wire.EncodeError!void {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("@setEvalBranchQuota(100_000);\n");
    if (!has_members) {
        if (ctx.opts.preserve_unknown_fields) {
            try writeIndent(w, indent + 2);
            try w.print("try self.{s}.encodeReverse(@This()._protoz_known_fields, rw);\n", .{uf_name});
        } else {
            try writeIndent(w, indent + 2);
            try w.writeAll("_ = self;\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("_ = rw;\n");
        }
    } else {
        if (ctx.opts.preserve_unknown_fields) {
            try writeIndent(w, indent + 2);
            try w.print("try self.{s}.encodeReverse(@This()._protoz_known_fields, rw);\n", .{uf_name});
        }
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
        try w.writeAll("_ = try @This()._protozSkipOrReject(@This(), &r, raw_tag, next_depth);\n");
    } else {
        try writeIndent(w, indent + 3);
        try w.writeAll("switch (raw_tag) {\n");
        for (m.fields) |f| {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            try emitFieldValidate(ctx, f, rt, indent + 4, w);
        }
        for (m.maps) |mp| {
            try writeIndent(w, indent + 4);
            try w.print("comptime wire.rawTag({d}, .len) => try ", .{mp.number});
            try writeMapType(ctx, scope_fqn, mp, w);
            try w.writeAll(".validateEntry(try r.readBytes(), next_depth),\n");
        }
        for (m.oneofs) |o| try emitOneofValidate(ctx, o, scope_fqn, indent + 4, w);
        try writeIndent(w, indent + 4);
        try w.writeAll("else => _ = try @This()._protozSkipOrReject(@This(), &r, raw_tag, next_depth),\n");
        try writeIndent(w, indent + 3);
        try w.writeAll("}\n");
    }
    try writeIndent(w, indent + 2);
    try w.writeAll("}\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    // decode / decodeDepth / decodeOnly / mergeDepth / mergeOnlyDepth
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
    try w.writeAll("pub fn decodeOnly(bytes: []const u8, comptime fields: anytype) wire.DecodeError!wire.Projection(@This(), fields) {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("var self: wire.Projection(@This(), fields) = .{};\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("try @This().mergeOnlyDepth(&self, bytes, wire.max_recursion_depth);\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("return self;\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn mergeDepth(self: *@This(), bytes: []const u8, depth: u32) wire.DecodeError!void {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("return @This().mergeOnlyDepth(self, bytes, depth);\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try writeIndent(w, indent + 1);
    try w.writeAll("fn mergeOnlyDepth(self: anytype, bytes: []const u8, depth: u32) wire.DecodeError!void {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("@setEvalBranchQuota(100_000);\n");
    if (!has_members) {
        if (ctx.opts.preserve_unknown_fields) {
            try writeIndent(w, indent + 2);
            try w.writeAll("const Target = @TypeOf(self.*);\n");
            try writeIndent(w, indent + 2);
            try w.print("const needs_tag_ptr = comptime @hasField(Target, \"{s}\");\n", .{uf_name});
            try writeIndent(w, indent + 2);
            try w.writeAll("if (depth == 0) return error.RecursionLimitExceeded;\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("const next_depth = depth - 1;\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("var r = wire.Reader.init(bytes);\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("while (true) {\n");
            try writeIndent(w, indent + 3);
            try w.writeAll("const tag_ptr = if (needs_tag_ptr) r.ptr else {};\n");
            try writeIndent(w, indent + 3);
            try w.writeAll("const raw_tag = (try r.readRawTag()) orelse break;\n");
            try writeIndent(w, indent + 3);
            try w.writeAll("const is_unknown = try @This()._protozSkipOrReject(Target, &r, raw_tag, next_depth);\n");
            try writeIndent(w, indent + 3);
            try w.print("if (comptime @hasField(Target, \"{s}\")) {{\n", .{uf_name});
            try writeIndent(w, indent + 4);
            try w.print("if (is_unknown) try self.{s}.record(bytes.ptr, tag_ptr, r.ptr);\n", .{uf_name});
            try writeIndent(w, indent + 3);
            try w.writeAll("}\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("}\n");
        } else {
            try writeIndent(w, indent + 2);
            try w.writeAll("_ = self;\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("return @This().validateDepth(bytes, depth);\n");
        }
    } else {
        try writeIndent(w, indent + 2);
        try w.writeAll("const Target = @TypeOf(self.*);\n");
        if (tag_ptr_fields.items.len > 0) {
            try writeIndent(w, indent + 2);
            try w.writeAll("const needs_tag_ptr = comptime (");
            for (tag_ptr_fields.items, 0..) |fname, idx| {
                if (idx > 0) try w.writeAll(" or ");
                try w.print("@hasField(Target, \"{s}\")", .{fname});
            }
            try w.writeAll(");\n");
        }
        try writeIndent(w, indent + 2);
        try w.writeAll("if (depth == 0) return error.RecursionLimitExceeded;\n");
        try writeIndent(w, indent + 2);
        try w.writeAll("const next_depth = depth - 1;\n");
        try writeIndent(w, indent + 2);
        try w.writeAll("var r = wire.Reader.init(bytes);\n");
        if (tag_ptr_fields.items.len > 0) {
            try writeIndent(w, indent + 2);
            try w.writeAll("while (true) {\n");
            try writeIndent(w, indent + 3);
            try w.writeAll("const tag_ptr = if (needs_tag_ptr) r.ptr else {};\n");
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
            try w.print("comptime wire.rawTag({d}, .len) => if (comptime @hasField(Target, \"{s}\")) {{\n", .{ mp.number, mp.name });
            try writeIndent(w, indent + 5);
            try w.writeAll("try self.");
            try writeIdent(w, mp.name);
            try w.print(".recordEntry(bytes.ptr, tag_ptr, &r, {d}, next_depth);\n", .{mp.number});
            try writeIndent(w, indent + 4);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 5);
            try w.writeAll("try r.skipWireType(.len);\n");
            try writeIndent(w, indent + 4);
            try w.writeAll("},\n");
        }
        for (m.oneofs) |o| try emitOneofDecode(ctx, o, scope_fqn, indent + 4, w);

        if (ctx.opts.preserve_unknown_fields) {
            try writeIndent(w, indent + 4);
            try w.writeAll("else => {\n");
            try writeIndent(w, indent + 5);
            try w.writeAll("const is_unknown = try @This()._protozSkipOrReject(Target, &r, raw_tag, next_depth);\n");
            try writeIndent(w, indent + 5);
            try w.print("if (comptime @hasField(Target, \"{s}\")) {{\n", .{uf_name});
            try writeIndent(w, indent + 6);
            try w.print("if (is_unknown) try self.{s}.record(bytes.ptr, tag_ptr, r.ptr);\n", .{uf_name});
            try writeIndent(w, indent + 5);
            try w.writeAll("}\n");
            try writeIndent(w, indent + 4);
            try w.writeAll("},\n");
        } else {
            try writeIndent(w, indent + 4);
            try w.writeAll("else => _ = try @This()._protozSkipOrReject(Target, &r, raw_tag, next_depth),\n");
        }
        try writeIndent(w, indent + 3);
        try w.writeAll("}\n");
        try writeIndent(w, indent + 2);
        try w.writeAll("}\n");
    }
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n");

    // Zero-allocation `{f}` debug formatting
    try w.writeAll("\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn format(self: @This(), w: *wire.Writer) wire.Writer.Error!void {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("return wire.formatMessage(self, w);\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n");

    // Arena-backed owned escape hatch for messages outliving their wire buffer
    try w.writeAll("\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn cloneInto(self: @This(), arena: wire.Allocator) wire.CloneError!@This() {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("return wire.cloneMessage(arena, self);\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn cloneOwned(self: @This(), allocator: wire.Allocator) wire.CloneError!wire.Owned(@This()) {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("return wire.cloneOwned(allocator, self);\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n");

    try emitJsonMeta(ctx, m, scope_fqn, indent, w);

    // Zero-allocation streaming FieldIterator
    try emitFieldIterator(ctx, m, scope_fqn, has_members, indent, w);
    try emitWktMethods(scope_fqn, indent, w);

    try writeIndent(w, indent);
    try w.writeAll("};\n");
}

fn emitJsonMeta(ctx: GenCtx, m: ast.Message, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    try w.writeAll("\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("pub const _protoz_json_fields: []const wire.json.JsonFieldMeta = &.{\n");

    for (m.fields) |f| {
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        const is_bytes = (rt == .scalar and std.mem.eql(u8, rt.scalar.wire_kind, ".bytes"));
        const kind_name: []const u8 = if (f.label == .repeated)
            ".repeated"
        else switch (rt) {
            .scalar => ".scalar",
            .@"enum" => ".@\"enum\"",
            .message => |sym| if (try ctx.res.createsCycle(scope_fqn, sym.proto_fqn)) ".lazy_message" else ".message",
        };
        const explicit = f.label != .repeated and rt != .message and ctx.res.hasExplicitPresence(ctx.file_idx, f, rt);

        try writeIndent(w, indent + 2);
        try w.print(".{{ .zig_name = \"{s}\", .proto_name = \"{s}\", .json_name = \"", .{ f.name, f.name });
        try writeLowerCamelCase(w, f.name);
        try w.print("\", .kind = {s}, .is_bytes = {}, .explicit_presence = {}, .elem_is_bytes = {} }},\n", .{
            kind_name,
            is_bytes and f.label != .repeated,
            explicit,
            is_bytes and f.label == .repeated,
        });
    }

    for (m.maps) |mp| {
        const vt = try ctx.res.resolveType(scope_fqn, mp.value_type);
        const val_is_bytes = (vt == .scalar and std.mem.eql(u8, vt.scalar.wire_kind, ".bytes"));
        try writeIndent(w, indent + 2);
        try w.print(".{{ .zig_name = \"{s}\", .proto_name = \"{s}\", .json_name = \"", .{ mp.name, mp.name });
        try writeLowerCamelCase(w, mp.name);
        try w.print("\", .kind = .map, .elem_is_bytes = {} }},\n", .{val_is_bytes});
    }

    for (m.oneofs) |o| {
        for (o.fields) |f| {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            const is_bytes = (rt == .scalar and std.mem.eql(u8, rt.scalar.wire_kind, ".bytes"));
            const is_lazy = (rt == .message and try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn));
            try writeIndent(w, indent + 2);
            try w.print(".{{ .zig_name = \"{s}\", .proto_name = \"{s}\", .json_name = \"", .{ f.name, f.name });
            try writeLowerCamelCase(w, f.name);
            try w.print("\", .kind = .oneof, .is_bytes = {}, .oneof_field = \"{s}\", .is_lazy = {} }},\n", .{
                is_bytes,
                o.name,
                is_lazy,
            });
        }
    }

    try writeIndent(w, indent + 1);
    try w.writeAll("};\n\n");

    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn encodeJson(self: @This(), w: anytype, opts: wire.json.EncodeOptions) wire.json.EncodeError(@TypeOf(w))!void {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("return wire.json.encodeMessage(self, w, opts);\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn encodeJsonSlice(self: @This(), buf: []u8, opts: wire.json.EncodeOptions) wire.json.SliceEncodeError![]const u8 {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("return wire.json.encodeMessageSlice(self, buf, opts);\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try writeIndent(w, indent + 1);
    try w.writeAll("pub fn decodeJson(arena: wire.Allocator, input: []const u8, opts: wire.json.DecodeOptions) wire.json.DecodeError!@This() {\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("return wire.json.decodeMessage(@This(), arena, input, opts);\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n");
}

fn emitWktMethods(scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    const lines: []const []const u8 = if (std.mem.eql(u8, scope_fqn, "google.protobuf.Timestamp")) &.{
        "pub fn validate(self: @This()) wire.wkt.WktError!void { return wire.wkt.validateTimestamp(self); }",
        "pub fn fromUnixSeconds(seconds: i64) wire.wkt.WktError!@This() { return wire.wkt.timestampFromUnixSeconds(@This(), seconds); }",
        "pub fn fromUnixMillis(millis: i64) wire.wkt.WktError!@This() { return wire.wkt.timestampFromUnixMillis(@This(), millis); }",
        "pub fn fromUnixNanos(total_ns: i128) wire.wkt.WktError!@This() { return wire.wkt.timestampFromUnixNanos(@This(), total_ns); }",
        "pub fn toUnixNanos(self: @This()) wire.wkt.WktError!i128 { return wire.wkt.timestampToUnixNanos(self); }",
        "pub fn toUnixMillis(self: @This()) wire.wkt.WktError!i64 { return wire.wkt.timestampToUnixMillis(self); }",
        "pub fn addDuration(self: @This(), dur: anytype) wire.wkt.WktError!@This() { return wire.wkt.timestampAddDuration(self, dur); }",
        "pub fn diff(self: @This(), comptime DurT: type, other: @This()) wire.wkt.WktError!DurT { return wire.wkt.timestampDiff(DurT, self, other); }",
        "pub fn formatRfc3339Buf(self: @This(), buf: *[32]u8) wire.wkt.WktError![]const u8 { return wire.wkt.formatTimestampBuf(self, buf); }",
        "pub fn formatRfc3339(self: @This(), w: *wire.Writer) (wire.wkt.WktError || wire.Writer.Error)!void { return wire.wkt.formatTimestamp(self, w); }",
        "pub fn parseRfc3339(input: []const u8) wire.wkt.WktError!@This() { return wire.wkt.parseTimestamp(@This(), input); }",
    } else if (std.mem.eql(u8, scope_fqn, "google.protobuf.Duration")) &.{
        "pub fn validate(self: @This()) wire.wkt.WktError!void { return wire.wkt.validateDuration(self); }",
        "pub fn fromSeconds(seconds: i64) wire.wkt.WktError!@This() { return wire.wkt.durationFromSeconds(@This(), seconds); }",
        "pub fn fromMillis(millis: i64) wire.wkt.WktError!@This() { return wire.wkt.durationFromMillis(@This(), millis); }",
        "pub fn fromNanos(total_ns: i128) wire.wkt.WktError!@This() { return wire.wkt.durationFromNanos(@This(), total_ns); }",
        "pub fn toNanos(self: @This()) wire.wkt.WktError!i128 { return wire.wkt.durationToNanos(self); }",
        "pub fn toMillis(self: @This()) wire.wkt.WktError!i64 { return wire.wkt.durationToMillis(self); }",
        "pub fn add(self: @This(), other: @This()) wire.wkt.WktError!@This() { return wire.wkt.durationAdd(self, other); }",
        "pub fn sub(self: @This(), other: @This()) wire.wkt.WktError!@This() { return wire.wkt.durationSub(self, other); }",
        "pub fn negate(self: @This()) wire.wkt.WktError!@This() { return wire.wkt.durationNegate(self); }",
        "pub fn formatProtoJsonBuf(self: @This(), buf: *[32]u8) wire.wkt.WktError![]const u8 { return wire.wkt.formatDurationBuf(self, buf); }",
        "pub fn formatProtoJson(self: @This(), w: *wire.Writer) (wire.wkt.WktError || wire.Writer.Error)!void { return wire.wkt.formatDuration(self, w); }",
        "pub fn parseProtoJson(input: []const u8) wire.wkt.WktError!@This() { return wire.wkt.parseDuration(@This(), input); }",
    } else if (std.mem.eql(u8, scope_fqn, "google.protobuf.Any")) &.{
        "pub fn typeName(self: @This()) ?[]const u8 { return wire.wkt.anyTypeName(self.type_url); }",
        "pub inline fn is(self: @This(), comptime M: type) bool { return wire.wkt.anyIs(self, M); }",
        "pub fn unpack(self: @This(), comptime M: type) wire.wkt.AnyError!M { return wire.wkt.unpackAny(self, M); }",
        "pub fn packSlice(msg: anytype, value_buf: []u8) wire.EncodeError!@This() { return wire.wkt.packAnySlice(@This(), msg, value_buf); }",
        "pub fn packWithPrefixSlice(comptime prefix: []const u8, msg: anytype, value_buf: []u8) wire.EncodeError!@This() { return wire.wkt.packAnyWithPrefixSlice(@This(), prefix, msg, value_buf); }",
        "pub fn packAlloc(allocator: wire.Allocator, msg: anytype) wire.Allocator.Error!@This() { return wire.wkt.packAnyAlloc(@This(), allocator, msg); }",
    } else return;

    try w.writeAll("\n");
    for (lines) |line| {
        try writeIndent(w, indent + 1);
        try w.writeAll(line);
        try w.writeAll("\n");
    }
}

fn emitSkipOrReject(m: ast.Message, has_members: bool, indent: usize, w: *std.Io.Writer) !void {
    try writeIndent(w, indent);
    try w.writeAll("fn _protozSkipOrReject(comptime Target: type, r: *wire.Reader, raw_tag: u32, depth: u32) wire.DecodeError!bool {\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("@branchHint(.cold);\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("const tag = try wire.decodeTag(raw_tag);\n");
    if (!has_members) {
        try writeIndent(w, indent + 1);
        try w.writeAll("_ = Target;\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("try r.skipField(tag, depth);\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("return true;\n");
    } else {
        try writeIndent(w, indent + 1);
        try w.writeAll("switch (tag.field_number) {\n");
        for (m.fields) |f| {
            try writeIndent(w, indent + 2);
            try w.print("{d} => if (comptime @hasField(Target, \"{s}\")) return error.WireTypeMismatch else {{ try r.skipField(tag, depth); return false; }},\n", .{ f.number, f.name });
        }
        for (m.maps) |mp| {
            try writeIndent(w, indent + 2);
            try w.print("{d} => if (comptime @hasField(Target, \"{s}\")) return error.WireTypeMismatch else {{ try r.skipField(tag, depth); return false; }},\n", .{ mp.number, mp.name });
        }
        for (m.oneofs) |o| {
            for (o.fields) |f| {
                try writeIndent(w, indent + 2);
                try w.print("{d} => if (comptime @hasField(Target, \"{s}\")) return error.WireTypeMismatch else {{ try r.skipField(tag, depth); return false; }},\n", .{ f.number, o.name });
            }
        }
        try writeIndent(w, indent + 2);
        try w.writeAll("else => { try r.skipField(tag, depth); return true; },\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("}\n");
    }
    try writeIndent(w, indent);
    try w.writeAll("}\n");
}

fn emitFieldIterator(
    ctx: GenCtx,
    m: ast.Message,
    scope_fqn: []const u8,
    has_members: bool,
    indent: usize,
    w: *std.Io.Writer,
) !void {
    var iter_name: []const u8 = "FieldIterator";
    for (m.nested_messages) |nm| if (std.mem.eql(u8, nm.name, "FieldIterator")) {
        iter_name = "WireFieldIterator";
    };
    for (m.nested_enums) |ne| if (std.mem.eql(u8, ne.name, "FieldIterator")) {
        iter_name = "WireFieldIterator";
    };
    for (m.oneofs) |o| {
        const otype = try oneofZigTypeName(ctx.arena, m, o.name);
        if (std.mem.eql(u8, otype, "FieldIterator")) {
            iter_name = "WireFieldIterator";
        }
    }

    var has_unknown_name = false;
    for (m.fields) |f| if (std.mem.eql(u8, f.name, "unknown")) {
        has_unknown_name = true;
    };
    for (m.maps) |mp| if (std.mem.eql(u8, mp.name, "unknown")) {
        has_unknown_name = true;
    };
    for (m.oneofs) |o| {
        for (o.fields) |f| if (std.mem.eql(u8, f.name, "unknown")) {
            has_unknown_name = true;
        };
    }
    const unknown_tag = if (has_unknown_name) "_unknown" else "unknown";

    try w.writeAll("\n");
    try writeIndent(w, indent + 1);
    try w.print("pub const {s} = struct {{\n", .{iter_name});
    try writeIndent(w, indent + 2);
    try w.writeAll("r: wire.Reader,\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("depth: u32 = wire.max_recursion_depth,\n\n");

    try writeIndent(w, indent + 2);
    try w.writeAll("pub const Item = union(enum) {\n");

    for (m.fields) |f| {
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
        try writeIndent(w, indent + 3);
        try writeIdent(w, f.name);
        try w.writeAll(": ");
        if (f.label == .repeated and isPackable(rt)) {
            try w.writeAll("wire.PackedChunk(");
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(")");
        } else switch (rt) {
            .scalar => |s| try w.writeAll(s.zig_type),
            .@"enum" => |sym| try ctx.imports.writeSymPath(w, sym),
            .message => try w.writeAll("[]const u8"),
        }
        try w.writeAll(",\n");
    }

    for (m.maps) |mp| {
        try writeIndent(w, indent + 3);
        try writeIdent(w, mp.name);
        try w.writeAll(": ");
        try writeMapType(ctx, scope_fqn, mp, w);
        try w.writeAll(".Entry,\n");
    }

    for (m.oneofs) |o| {
        for (o.fields) |f| {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            try writeIndent(w, indent + 3);
            try writeIdent(w, f.name);
            try w.writeAll(": ");
            switch (rt) {
                .scalar => |s| try w.writeAll(s.zig_type),
                .@"enum" => |sym| try ctx.imports.writeSymPath(w, sym),
                .message => try w.writeAll("[]const u8"),
            }
            try w.writeAll(",\n");
        }
    }

    try writeIndent(w, indent + 3);
    try w.print("{s}: wire.UnknownField,\n", .{unknown_tag});
    try writeIndent(w, indent + 2);
    try w.writeAll("};\n\n");

    try writeIndent(w, indent + 2);
    try w.writeAll("pub fn next(self: *@This()) wire.DecodeError!?Item {\n");
    try writeIndent(w, indent + 3);
    try w.writeAll("@setEvalBranchQuota(100_000);\n");
    try writeIndent(w, indent + 3);
    try w.writeAll("const raw_tag = (try self.r.readRawTag()) orelse return null;\n");

    if (!has_members) {
        try writeIndent(w, indent + 3);
        try w.writeAll("const tag = try wire.decodeTag(raw_tag);\n");
        try writeIndent(w, indent + 3);
        try w.print("return .{{ .{s} = try self.r.readUnknownField(tag, self.depth) }};\n", .{unknown_tag});
    } else {
        try writeIndent(w, indent + 3);
        try w.writeAll("switch (raw_tag) {\n");

        for (m.fields) |f| {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
            if (f.label == .repeated and isPackable(rt)) {
                try writeIndent(w, indent + 4);
                try w.print("comptime wire.rawTag({d}, .len) => return .{{ .", .{f.number});
                try writeIdent(w, f.name);
                try w.writeAll(" = .{ .@\"packed\" = try self.r.readBytes() } },\n");

                try writeIndent(w, indent + 4);
                try w.print("comptime wire.rawTag({d}, ", .{f.number});
                try writeCodecExpr(ctx, w, rt, utf8);
                try w.writeAll(".wire_type) => return .{ .");
                try writeIdent(w, f.name);
                try w.writeAll(" = .{ .single = try ");
                try writeCodecExpr(ctx, w, rt, utf8);
                try w.writeAll(".read(&self.r, self.depth) } },\n");
            } else if (rt == .message) {
                try writeIndent(w, indent + 4);
                try w.print("comptime wire.rawTag({d}, .len) => return .{{ .", .{f.number});
                try writeIdent(w, f.name);
                try w.writeAll(" = try self.r.readBytes() },\n");
            } else {
                try writeIndent(w, indent + 4);
                try w.print("comptime wire.rawTag({d}, ", .{f.number});
                try writeCodecExpr(ctx, w, rt, utf8);
                try w.writeAll(".wire_type) => return .{ .");
                try writeIdent(w, f.name);
                try w.writeAll(" = try ");
                try writeCodecExpr(ctx, w, rt, utf8);
                try w.writeAll(".read(&self.r, self.depth) },\n");
            }
        }

        for (m.maps) |mp| {
            try writeIndent(w, indent + 4);
            try w.print("comptime wire.rawTag({d}, .len) => {{\n", .{mp.number});
            try writeIndent(w, indent + 5);
            try w.writeAll("if (self.depth == 0) return error.RecursionLimitExceeded;\n");
            try writeIndent(w, indent + 5);
            try w.writeAll("const entry_bytes = try self.r.readBytes();\n");
            try writeIndent(w, indent + 5);
            try w.writeAll("return .{ .");
            try writeIdent(w, mp.name);
            try w.writeAll(" = try ");
            try writeMapType(ctx, scope_fqn, mp, w);
            try w.writeAll(".decodeEntry(entry_bytes, self.depth - 1) };\n");
            try writeIndent(w, indent + 4);
            try w.writeAll("},\n");
        }

        for (m.oneofs) |o| {
            for (o.fields) |f| {
                const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
                const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
                if (rt == .message) {
                    try writeIndent(w, indent + 4);
                    try w.print("comptime wire.rawTag({d}, .len) => return .{{ .", .{f.number});
                    try writeIdent(w, f.name);
                    try w.writeAll(" = try self.r.readBytes() },\n");
                } else {
                    try writeIndent(w, indent + 4);
                    try w.print("comptime wire.rawTag({d}, ", .{f.number});
                    try writeCodecExpr(ctx, w, rt, utf8);
                    try w.writeAll(".wire_type) => return .{ .");
                    try writeIdent(w, f.name);
                    try w.writeAll(" = try ");
                    try writeCodecExpr(ctx, w, rt, utf8);
                    try w.writeAll(".read(&self.r, self.depth) },\n");
                }
            }
        }

        try writeIndent(w, indent + 4);
        try w.writeAll("else => {\n");
        try writeIndent(w, indent + 5);
        try w.writeAll("const tag = try wire.decodeTag(raw_tag);\n");
        try writeIndent(w, indent + 5);
        try w.writeAll("switch (tag.field_number) {\n");
        try writeIndent(w, indent + 6);
        var first_num = true;
        for (m.fields) |f| {
            if (!first_num) try w.writeAll(", ");
            try w.print("{d}", .{f.number});
            first_num = false;
        }
        for (m.maps) |mp| {
            if (!first_num) try w.writeAll(", ");
            try w.print("{d}", .{mp.number});
            first_num = false;
        }
        for (m.oneofs) |o| {
            for (o.fields) |f| {
                if (!first_num) try w.writeAll(", ");
                try w.print("{d}", .{f.number});
                first_num = false;
            }
        }
        try w.writeAll(" => return error.WireTypeMismatch,\n");
        try writeIndent(w, indent + 6);
        try w.print("else => return .{{ .{s} = try self.r.readUnknownField(tag, self.depth) }},\n", .{unknown_tag});
        try writeIndent(w, indent + 5);
        try w.writeAll("}\n");
        try writeIndent(w, indent + 4);
        try w.writeAll("},\n");

        try writeIndent(w, indent + 3);
        try w.writeAll("}\n");
    }

    try writeIndent(w, indent + 2);
    try w.writeAll("}\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("};\n\n");

    try writeIndent(w, indent + 1);
    try w.print("pub inline fn fieldIterator(bytes: []const u8) @This().{s} {{\n", .{iter_name});
    try writeIndent(w, indent + 2);
    try w.writeAll("return .{ .r = wire.Reader.init(bytes) };\n");
    try writeIndent(w, indent + 1);
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
            try w.print("comptime wire.rawTag({d}, .len) => if (comptime @hasField(Target, \"{s}\")) {{\n", .{ f.number, f.name });
            try writeIndent(w, indent + 1);
            try w.writeAll("try self.");
            try writeIdent(w, f.name);
            try w.print(".recordPacked(bytes.ptr, tag_ptr, &r, {d});\n", .{f.number});
            try writeIndent(w, indent);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("try r.skipWireType(.len);\n");
            try writeIndent(w, indent);
            try w.writeAll("},\n");

            try writeIndent(w, indent);
            try w.print("comptime wire.rawTag({d}, ", .{f.number});
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.print(".wire_type) => if (comptime @hasField(Target, \"{s}\")) {{\n", .{f.name});
            try writeIndent(w, indent + 1);
            try w.writeAll("try self.");
            try writeIdent(w, f.name);
            try w.print(".recordUnpacked(bytes.ptr, tag_ptr, &r, {d}, next_depth);\n", .{f.number});
            try writeIndent(w, indent);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("try r.skipWireType(");
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".wire_type);\n");
            try writeIndent(w, indent);
            try w.writeAll("},\n");
        } else {
            try writeIndent(w, indent);
            try w.print("comptime wire.rawTag({d}, .len) => if (comptime @hasField(Target, \"{s}\")) {{\n", .{ f.number, f.name });
            try writeIndent(w, indent + 1);
            try w.writeAll("try self.");
            try writeIdent(w, f.name);
            try w.print(".recordUnpacked(bytes.ptr, tag_ptr, &r, {d}, next_depth);\n", .{f.number});
            try writeIndent(w, indent);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("try r.skipWireType(.len);\n");
            try writeIndent(w, indent);
            try w.writeAll("},\n");
        }
    } else if (rt == .message) {
        const cyclic = try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn);
        try writeIndent(w, indent);
        try w.print("comptime wire.rawTag({d}, .len) => {{\n", .{f.number});
        try writeIndent(w, indent + 1);
        try w.print("if (comptime @hasField(Target, \"{s}\")) {{\n", .{f.name});
        try writeIndent(w, indent + 2);
        try w.writeAll("const sub_bytes = try r.readBytes();\n");
        if (cyclic) {
            try writeIndent(w, indent + 2);
            try w.writeAll("try ");
            try ctx.imports.writeSymPath(w, rt.message);
            try w.writeAll(".validateDepth(sub_bytes, next_depth);\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("if (self.");
            try writeIdent(w, f.name);
            try w.writeAll(") |*existing| {\n");
            try writeIndent(w, indent + 3);
            try w.print("try existing.mergeRaw(bytes.ptr, tag_ptr, sub_bytes, r.ptr, {d});\n", .{f.number});
            try writeIndent(w, indent + 2);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 3);
            try w.writeAll("self.");
            try writeIdent(w, f.name);
            try w.writeAll(" = .{ .raw_wire = .{ .data = sub_bytes, .tag_ptr = tag_ptr } };\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("}\n");
        } else {
            try writeIndent(w, indent + 2);
            try w.writeAll("if (self.");
            try writeIdent(w, f.name);
            try w.writeAll(") |*existing| {\n");
            try writeIndent(w, indent + 3);
            try w.writeAll("try existing.mergeDepth(sub_bytes, next_depth);\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 3);
            try w.writeAll("self.");
            try writeIdent(w, f.name);
            try w.writeAll(" = try ");
            try ctx.imports.writeSymPath(w, rt.message);
            try w.writeAll(".decodeDepth(sub_bytes, next_depth);\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("}\n");
        }
        try writeIndent(w, indent + 1);
        try w.writeAll("} else {\n");
        try writeIndent(w, indent + 2);
        try w.writeAll("try r.skipWireType(.len);\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("}\n");
        try writeIndent(w, indent);
        try w.writeAll("},\n");
    } else {
        try writeIndent(w, indent);
        try w.print("comptime wire.rawTag({d}, ", .{f.number});
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.print(".wire_type) => if (comptime @hasField(Target, \"{s}\")) {{\n", .{f.name});
        try writeIndent(w, indent + 1);
        try w.writeAll("self.");
        try writeIdent(w, f.name);
        try w.writeAll(" = try ");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".read(&r, next_depth);\n");
        try writeIndent(w, indent);
        try w.writeAll("} else {\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("try r.skipWireType(");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".wire_type);\n");
        try writeIndent(w, indent);
        try w.writeAll("},\n");
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
            try w.print("if (comptime @hasField(Target, \"{s}\")) {{\n", .{o.name});
            try writeIndent(w, indent + 2);
            try w.writeAll("const sub_bytes = try r.readBytes();\n");
            if (cyclic) {
                try writeIndent(w, indent + 2);
                try w.writeAll("try ");
                try ctx.imports.writeSymPath(w, rt.message);
                try w.writeAll(".validateDepth(sub_bytes, next_depth);\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("if (self.");
                try writeIdent(w, o.name);
                try w.writeAll(" != null and self.");
                try writeIdent(w, o.name);
                try w.writeAll(".? == .");
                try writeIdent(w, f.name);
                try w.writeAll(") {\n");
                try writeIndent(w, indent + 3);
                try w.writeAll("try self.");
                try writeIdent(w, o.name);
                try w.writeAll(".?.");
                try writeIdent(w, f.name);
                try w.print(".mergeRaw(bytes.ptr, tag_ptr, sub_bytes, r.ptr, {d});\n", .{f.number});
                try writeIndent(w, indent + 2);
                try w.writeAll("} else {\n");
                try writeIndent(w, indent + 3);
                try w.writeAll("self.");
                try writeIdent(w, o.name);
                try w.writeAll(" = .{ .");
                try writeIdent(w, f.name);
                try w.writeAll(" = .{ .raw_wire = .{ .data = sub_bytes, .tag_ptr = tag_ptr } } };\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("}\n");
            } else {
                try writeIndent(w, indent + 2);
                try w.writeAll("if (self.");
                try writeIdent(w, o.name);
                try w.writeAll(" != null and self.");
                try writeIdent(w, o.name);
                try w.writeAll(".? == .");
                try writeIdent(w, f.name);
                try w.writeAll(") {\n");
                try writeIndent(w, indent + 3);
                try w.writeAll("try self.");
                try writeIdent(w, o.name);
                try w.writeAll(".?.");
                try writeIdent(w, f.name);
                try w.writeAll(".mergeDepth(sub_bytes, next_depth);\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("} else {\n");
                try writeIndent(w, indent + 3);
                try w.writeAll("self.");
                try writeIdent(w, o.name);
                try w.writeAll(" = .{ .");
                try writeIdent(w, f.name);
                try w.writeAll(" = try ");
                try ctx.imports.writeSymPath(w, rt.message);
                try w.writeAll(".decodeDepth(sub_bytes, next_depth) };\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("}\n");
            }
            try writeIndent(w, indent + 1);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("try r.skipWireType(.len);\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("}\n");
            try writeIndent(w, indent);
            try w.writeAll("},\n");
        } else {
            try writeIndent(w, indent);
            try w.print("comptime wire.rawTag({d}, ", .{f.number});
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.print(".wire_type) => if (comptime @hasField(Target, \"{s}\")) {{\n", .{o.name});
            try writeIndent(w, indent + 1);
            try w.writeAll("self.");
            try writeIdent(w, o.name);
            try w.writeAll(" = .{ .");
            try writeIdent(w, f.name);
            try w.writeAll(" = try ");
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".read(&r, next_depth) };\n");
            try writeIndent(w, indent);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("try r.skipWireType(");
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".wire_type);\n");
            try writeIndent(w, indent);
            try w.writeAll("},\n");
        }
    }
}

fn writeRpcZigName(w: *std.Io.Writer, rpc_name: []const u8) !void {
    if (rpc_name.len == 0) return;
    try w.writeByte(std.ascii.toLower(rpc_name[0]));
    try w.writeAll(rpc_name[1..]);
}

fn streamKindExpr(req_stream: bool, res_stream: bool) []const u8 {
    if (req_stream and res_stream) return ".bidi_streaming";
    if (req_stream) return ".client_streaming";
    if (res_stream) return ".server_streaming";
    return ".unary";
}

fn emitService(
    ctx: GenCtx,
    svc: ast.Service,
    pkg_scope: []const u8,
    w: *std.Io.Writer,
) !void {
    const svc_full_name = if (pkg_scope.len == 0)
        svc.name
    else
        try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ pkg_scope, svc.name });

    try w.writeAll("pub const ");
    try writeIdent(w, svc.name);
    try w.writeAll(" = struct {\n");
    try w.print("    pub const proto_full_name: []const u8 = \"{s}\";\n\n", .{svc_full_name});

    for (svc.rpcs) |rpc| {
        const req_rt = try ctx.res.resolveType(pkg_scope, rpc.req_type);
        if (req_rt != .message) return error.RpcTypeMustBeMessage;
        const res_rt = try ctx.res.resolveType(pkg_scope, rpc.res_type);
        if (res_rt != .message) return error.RpcTypeMustBeMessage;

        try w.writeAll("    pub const ");
        try writeIdent(w, rpc.name);
        try w.writeAll(" = struct {\n");
        try w.print("        pub const name: []const u8 = \"{s}\";\n", .{rpc.name});
        try w.writeAll("        pub const zig_name: []const u8 = \"");
        try writeRpcZigName(w, rpc.name);
        try w.writeAll("\";\n");
        try w.print("        pub const path: []const u8 = \"/{s}/{s}\";\n", .{ svc_full_name, rpc.name });
        try w.writeAll("        pub const Request = ");
        try ctx.imports.writeSymPath(w, req_rt.message);
        try w.writeAll(";\n");
        try w.writeAll("        pub const Response = ");
        try ctx.imports.writeSymPath(w, res_rt.message);
        try w.writeAll(";\n");
        try w.print("        pub const client_streaming: bool = {};\n", .{rpc.req_stream});
        try w.print("        pub const server_streaming: bool = {};\n", .{rpc.res_stream});
        try w.print("        pub const stream_kind: wire.rpc.StreamKind = {s};\n", .{streamKindExpr(rpc.req_stream, rpc.res_stream)});
        try w.writeAll("    };\n\n");
    }

    try w.writeAll("    pub const MethodId = enum {\n");
    for (svc.rpcs) |rpc| {
        try w.writeAll("        ");
        try writeIdent(w, rpc.name);
        try w.writeAll(",\n");
    }
    try w.writeAll("    };\n\n");

    try w.writeAll("    pub const methods = .{\n");
    for (svc.rpcs) |rpc| {
        try w.writeAll("        ");
        try writeIdent(w, rpc.name);
        try w.writeAll(",\n");
    }
    try w.writeAll("    };\n\n");

    try w.writeAll("    pub const method_infos: []const wire.rpc.MethodInfo = &.{\n");
    for (svc.rpcs) |rpc| {
        try w.writeAll("        .{ .name = \"");
        try w.writeAll(rpc.name);
        try w.writeAll("\", .zig_name = \"");
        try writeRpcZigName(w, rpc.name);
        try w.print("\", .path = \"/{s}/{s}\", .stream_kind = {s} }},\n", .{
            svc_full_name,
            rpc.name,
            streamKindExpr(rpc.req_stream, rpc.res_stream),
        });
    }
    try w.writeAll("    };\n\n");

    try w.writeAll("    pub fn matchPath(path: []const u8) ?MethodId {\n");
    if (svc.rpcs.len == 0) {
        try w.writeAll("        _ = path;\n");
    } else {
        for (svc.rpcs) |rpc| {
            try w.print("        if (wire.rpc.eqlPath(path, \"/{s}/{s}\")) return .", .{ svc_full_name, rpc.name });
            try writeIdent(w, rpc.name);
            try w.writeAll(";\n");
        }
    }
    try w.writeAll("        return null;\n");
    try w.writeAll("    }\n");
    try w.writeAll("};\n");
}
