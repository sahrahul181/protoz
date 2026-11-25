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
    file_alias: []const u8 = "_protoz_file",
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
        try self.collectExtensions(arena, m.extensions, scope_fqn, res);
    }

    fn collectExtensions(
        self: *ImportTable,
        arena: std.mem.Allocator,
        extensions: []const ast.ExtensionDecl,
        scope_fqn: []const u8,
        res: *const resolver.Resolver,
    ) !void {
        for (extensions) |ext| {
            const host_rt = try res.resolveType(scope_fqn, ext.extendee);
            if (host_rt == .message) try self.noteSymbol(arena, host_rt.message);
            for (ext.fields) |f| {
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
        return self.writeSymPathQualified(w, sym, false);
    }

    fn writeSymPathQualified(self: *const ImportTable, w: *std.Io.Writer, sym: resolver.Symbol, prefix_self: bool) !void {
        if (sym.file_index != self.file_idx) {
            const alias_id = self.alias_by_file.get(sym.file_index).?;
            try w.print("_imp_{d}.", .{alias_id});
        } else if (prefix_self) {
            try w.print("{s}.", .{self.file_alias});
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
    wire_alias: []const u8 = "wire",
    scope_fqn: []const u8 = "",
    svc_name: []const u8 = "",

    fn withScope(self: GenCtx, scope_fqn: []const u8) GenCtx {
        var next = self;
        next.scope_fqn = scope_fqn;
        return next;
    }

    fn writeSymPath(self: GenCtx, w: *std.Io.Writer, sym: resolver.Symbol) !void {
        return self.imports.writeSymPathQualified(w, sym, self.isSymbolShadowed(sym));
    }

    fn isSymbolShadowed(self: GenCtx, sym: resolver.Symbol) bool {
        if (sym.file_index != self.file_idx) return false;
        const first_seg = if (std.mem.indexOfScalar(u8, sym.zig_path, '.')) |dot|
            sym.zig_path[0..dot]
        else
            sym.zig_path;
        if (self.svc_name.len > 0 and std.mem.eql(u8, self.svc_name, first_seg)) {
            return true;
        }
        const pkg_scope = self.res.files[self.file_idx].package orelse "";
        var cur = self.scope_fqn;
        while (cur.len > pkg_scope.len) {
            if (self.res.symbols.get(cur)) |enclosing| {
                if (enclosing.msg) |em| {
                    for (em.nested_messages) |nm| if (std.mem.eql(u8, nm.name, first_seg)) return true;
                    for (em.nested_enums) |ne| if (std.mem.eql(u8, ne.name, first_seg)) return true;
                    for (em.oneofs) |o| {
                        const otype = oneofZigTypeName(self.arena, em.*, o.name) catch continue;
                        if (std.mem.eql(u8, otype, first_seg)) return true;
                    }
                }
            }
            if (std.mem.lastIndexOfScalar(u8, cur, '.')) |dot| {
                cur = cur[0..dot];
            } else break;
        }
        return false;
    }
};

fn isReservedMessageDecl(name: []const u8) bool {
    const reserved = std.StaticStringMap(void).initComptime(.{
        .{ "encodedSize", {} },          .{ "encode", {} },
        .{ "encodeReverse", {} },        .{ "encodeSlice", {} },
        .{ "validateDepth", {} },        .{ "decode", {} },
        .{ "decodeDepth", {} },          .{ "decodeOnly", {} },
        .{ "mergeDepth", {} },           .{ "mergeOnlyDepth", {} },
        .{ "format", {} },               .{ "cloneInto", {} },
        .{ "cloneOwned", {} },           .{ "encodeJson", {} },
        .{ "encodeJsonSlice", {} },      .{ "decodeJson", {} },
        .{ "fieldIterator", {} },        .{ "FieldIterator", {} },
        .{ "WireFieldIterator", {} },    .{ "proto_full_name", {} },
        .{ "defaults", {} },             .{ "isInitialized", {} },
        .{ "_protozSkipOrReject", {} },  .{ "_protoz_json_fields", {} },
        .{ "_protoz_known_fields", {} },
    });
    return reserved.has(name);
}

fn collidesWithMessageMember(m: ast.Message, candidate: []const u8, self_proto_name: []const u8) bool {
    if (isReservedMessageDecl(candidate)) return true;
    for (m.nested_messages) |nm| if (std.mem.eql(u8, nm.name, candidate)) return true;
    for (m.nested_enums) |ne| if (std.mem.eql(u8, ne.name, candidate)) return true;
    if (!std.mem.eql(u8, candidate, self_proto_name)) {
        for (m.fields) |f| if (std.mem.eql(u8, f.name, candidate)) return true;
        for (m.maps) |mp| if (std.mem.eql(u8, mp.name, candidate)) return true;
        for (m.oneofs) |o| if (std.mem.eql(u8, o.name, candidate)) return true;
    }
    return false;
}

/// Returns a collision-free Zig struct field name (e.g., `encode` -> `encode_`)
/// while preserving the original `.proto` name for ProtoJSON and diagnostics.
fn zigFieldName(arena: std.mem.Allocator, m: ast.Message, proto_name: []const u8) ![]const u8 {
    var candidate = proto_name;
    while (collidesWithMessageMember(m, candidate, proto_name)) {
        candidate = try std.fmt.allocPrint(arena, "{s}_", .{candidate});
    }
    return candidate;
}

fn needsZigIdentEscape(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, "_")) return true;
    return std.zig.Token.getKeyword(name) != null or std.zig.primitives.isPrimitive(name);
}

pub fn writeIdent(w: *std.Io.Writer, name: []const u8) !void {
    if (needsZigIdentEscape(name)) {
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
                try w.print("{s}.ScalarCodec(.string_utf8)", .{ctx.wire_alias});
            } else {
                try w.print("{s}.ScalarCodec({s})", .{ ctx.wire_alias, s.wire_kind });
            }
        },
        .@"enum" => |e| {
            try w.print("{s}.EnumCodec(", .{ctx.wire_alias});
            try ctx.writeSymPath(w, e);
            try w.writeAll(")");
        },
        .message => |m| {
            try w.print("{s}.MessageCodec(", .{ctx.wire_alias});
            try ctx.writeSymPath(w, m);
            try w.writeAll(")");
        },
    }
}

fn writeFieldCodecExpr(ctx: GenCtx, w: *std.Io.Writer, f: ast.Field, rt: resolver.ResolvedType, utf8_check: bool) !void {
    if (f.is_group and rt == .message) {
        try w.print("{s}.GroupCodec(", .{ctx.wire_alias});
        try ctx.writeSymPath(w, rt.message);
        try w.print(", {d})", .{f.number});
    } else {
        try writeCodecExpr(ctx, w, rt, utf8_check);
    }
}

fn writeZigStringLiteral(w: *std.Io.Writer, raw: []const u8) !void {
    try w.writeByte('"');
    for (raw) |b| {
        switch (b) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x20...0x21, 0x23...0x5B, 0x5D...0x7E => try w.writeByte(b),
            else => try w.print("\\x{x:0>2}", .{b}),
        }
    }
    try w.writeByte('"');
}

fn findDefaultOption(options: []const ast.Option) ?[]const u8 {
    for (options) |opt| {
        if (std.mem.eql(u8, opt.name, "default")) return opt.raw_value;
    }
    return null;
}

fn writeDefaultValueExpr(ctx: GenCtx, w: *std.Io.Writer, rt: resolver.ResolvedType, raw: []const u8) !void {
    switch (rt) {
        .@"enum" => {
            try w.writeByte('.');
            try writeIdent(w, raw);
        },
        .message => unreachable,
        .scalar => |s| {
            if (std.mem.eql(u8, s.wire_kind, ".string") or std.mem.eql(u8, s.wire_kind, ".bytes")) {
                try writeZigStringLiteral(w, raw);
            } else if (std.mem.eql(u8, s.wire_kind, ".bool_")) {
                try w.writeAll(if (std.mem.eql(u8, raw, "true")) "true" else "false");
            } else if (std.mem.eql(u8, s.wire_kind, ".float_") or std.mem.eql(u8, s.wire_kind, ".double_")) {
                if (std.mem.eql(u8, raw, "inf")) {
                    try w.print("{s}.math.inf({s})", .{ ctx.wire_alias, s.zig_type });
                } else if (std.mem.eql(u8, raw, "-inf")) {
                    try w.print("-{s}.math.inf({s})", .{ ctx.wire_alias, s.zig_type });
                } else if (std.mem.eql(u8, raw, "nan")) {
                    try w.print("{s}.math.nan({s})", .{ ctx.wire_alias, s.zig_type });
                } else {
                    try w.writeAll(raw);
                }
            } else {
                if (std.mem.startsWith(u8, raw, "-0x") or std.mem.startsWith(u8, raw, "-0X") or
                    std.mem.startsWith(u8, raw, "0x") or std.mem.startsWith(u8, raw, "0X"))
                {
                    try w.writeAll(raw);
                } else if (raw.len >= 2 and raw[0] == '0') {
                    try w.print("0o{s}", .{raw[1..]});
                } else if (raw.len >= 3 and raw[0] == '-' and raw[1] == '0') {
                    try w.print("-0o{s}", .{raw[2..]});
                } else {
                    try w.writeAll(raw);
                }
            }
        },
    }
}

fn messageNeedsInitCheck(
    arena: std.mem.Allocator,
    res: *const resolver.Resolver,
    scope_fqn: []const u8,
    m: ast.Message,
) !bool {
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    return messageNeedsInitCheckRec(arena, res, scope_fqn, m, &visited);
}

fn messageNeedsInitCheckRec(
    arena: std.mem.Allocator,
    res: *const resolver.Resolver,
    scope_fqn: []const u8,
    m: ast.Message,
    visited: *std.StringHashMapUnmanaged(void),
) !bool {
    if (visited.contains(scope_fqn)) return false;
    try visited.put(arena, scope_fqn, {});

    for (m.fields) |f| {
        if (f.label == .required) return true;
        const rt = try res.resolveType(scope_fqn, f.type_name);
        if (rt == .message) {
            if (rt.message.msg) |sub_m| {
                if (try messageNeedsInitCheckRec(arena, res, rt.message.proto_fqn, sub_m.*, visited)) return true;
            }
        }
    }
    for (m.maps) |mp| {
        const vt = try res.resolveType(scope_fqn, mp.value_type);
        if (vt == .message) {
            if (vt.message.msg) |sub_m| {
                if (try messageNeedsInitCheckRec(arena, res, vt.message.proto_fqn, sub_m.*, visited)) return true;
            }
        }
    }
    for (m.oneofs) |o| {
        for (o.fields) |f| {
            const rt = try res.resolveType(scope_fqn, f.type_name);
            if (rt == .message) {
                if (rt.message.msg) |sub_m| {
                    if (try messageNeedsInitCheckRec(arena, res, rt.message.proto_fqn, sub_m.*, visited)) return true;
                }
            }
        }
    }
    return false;
}

fn writeMapType(ctx: GenCtx, scope_fqn: []const u8, mp: ast.MapField, w: *std.Io.Writer) !void {
    const kt = try ctx.res.resolveType(scope_fqn, mp.key_type);
    const vt = try ctx.res.resolveType(scope_fqn, mp.value_type);
    const utf8 = ctx.res.validatesUtf8(ctx.file_idx, mp.options);
    try w.print("{s}.Map(", .{ctx.wire_alias});
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

fn fileHasTopLevelDecl(
    file: *const ast.File,
    pub_deps: []const usize,
    res: *const resolver.Resolver,
    name: []const u8,
) bool {
    for (file.enums) |e| if (std.mem.eql(u8, e.name, name)) return true;
    for (file.messages) |m| if (std.mem.eql(u8, m.name, name)) return true;
    for (file.services) |s| if (std.mem.eql(u8, s.name, name)) return true;
    for (file.extensions) |ext| for (ext.fields) |f| if (std.mem.eql(u8, f.name, name)) return true;
    for (pub_deps) |dep_idx| {
        const dep = &res.files[dep_idx];
        for (dep.enums) |e| if (std.mem.eql(u8, e.name, name)) return true;
        for (dep.messages) |m| if (std.mem.eql(u8, m.name, name)) return true;
        for (dep.services) |s| if (std.mem.eql(u8, s.name, name)) return true;
        for (dep.extensions) |ext| for (ext.fields) |f| if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

fn pickSafeFileAlias(
    arena: std.mem.Allocator,
    file: *const ast.File,
    pub_deps: []const usize,
    res: *const resolver.Resolver,
    preferred: []const u8,
    fallback: []const u8,
) ![]const u8 {
    if (!fileHasTopLevelDecl(file, pub_deps, res, preferred)) return preferred;
    var candidate = fallback;
    while (fileHasTopLevelDecl(file, pub_deps, res, candidate)) {
        candidate = try std.fmt.allocPrint(arena, "{s}_", .{candidate});
    }
    return candidate;
}

fn emitExtensions(
    ctx: GenCtx,
    extensions: []const ast.ExtensionDecl,
    scope_fqn: []const u8,
    indent: usize,
    used_names: *std.StringHashMapUnmanaged(void),
    check_msg_reserved: bool,
    w: *std.Io.Writer,
) !void {
    for (extensions) |ext| {
        const host_rt = try ctx.res.resolveType(scope_fqn, ext.extendee);
        if (host_rt != .message) return error.ExtendeeMustBeMessage;
        for (ext.fields) |f| {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
            var zname = f.name;
            while (used_names.contains(zname) or (check_msg_reserved and isReservedMessageDecl(zname))) {
                zname = try std.fmt.allocPrint(ctx.arena, "{s}_", .{zname});
            }
            try used_names.put(ctx.arena, zname, {});

            try writeIndent(w, indent);
            try w.writeAll("pub const ");
            try writeIdent(w, zname);
            if (f.label == .repeated) {
                try w.print(" = {s}.RepeatedExtension(", .{ctx.wire_alias});
            } else {
                try w.print(" = {s}.Extension(", .{ctx.wire_alias});
            }
            try ctx.writeSymPath(w, host_rt.message);
            try w.print(", {d}, ", .{f.number});
            try writeFieldCodecExpr(ctx, w, f, rt, utf8);
            try w.writeAll(");\n");
        }
    }
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
    try imp_table.collectExtensions(arena, file.extensions, pkg_scope, res);

    var pub_visited: std.AutoHashMapUnmanaged(usize, void) = .empty;
    try pub_visited.put(arena, file_idx, {});
    var pub_deps: std.ArrayList(usize) = .empty;
    try collectPublicDeps(arena, file_idx, res, &pub_visited, &pub_deps);
    for (pub_deps.items) |dep_idx| {
        try imp_table.noteFile(arena, dep_idx);
    }

    const wire_alias = try pickSafeFileAlias(arena, file, pub_deps.items, res, "wire", "_protoz_wire");
    const file_alias = try pickSafeFileAlias(arena, file, pub_deps.items, res, "_protoz_file", "_protoz_self");
    imp_table.file_alias = file_alias;

    const ctx = GenCtx{
        .arena = arena,
        .file_idx = file_idx,
        .res = res,
        .imports = &imp_table,
        .opts = opts,
        .wire_alias = wire_alias,
    };

    try w.print(
        \\// Auto-generated by zig-protoc (Zig 0.17.1, zero-allocation runtime).
        \\// DO NOT EDIT.
        \\const {s} = @import("{s}");
        \\const {s} = @This();
        \\
    , .{ wire_alias, opts.wire_import, file_alias });

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
        for (file.extensions) |ext| for (ext.fields) |f| try declared.put(arena, f.name, {});

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
            for (dep_file.extensions) |ext| {
                for (ext.fields) |f| {
                    if (try emitReexport(w, arena, &declared, f.name, alias_id)) emitted_any = true;
                }
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

    if (file.extensions.len > 0) {
        var file_used: std.StringHashMapUnmanaged(void) = .empty;
        try file_used.put(arena, wire_alias, {});
        try file_used.put(arena, file_alias, {});
        for (file.enums) |e| try file_used.put(arena, e.name, {});
        for (file.messages) |m| try file_used.put(arena, m.name, {});
        for (file.services) |svc| try file_used.put(arena, svc.name, {});
        try emitExtensions(ctx, file.extensions, pkg_scope, 0, &file_used, false, w);
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

fn emitMessage(parent_ctx: GenCtx, m: ast.Message, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    const ctx = parent_ctx.withScope(scope_fqn);
    try writeIndent(w, indent);
    try w.writeAll("pub const ");
    try writeIdent(w, m.name);
    try w.writeAll(" = struct {\n");

    try writeIndent(w, indent + 1);
    try w.print("pub const proto_full_name: []const u8 = \"{s}\";\n\n", .{scope_fqn});

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
                .@"enum" => |e| try ctx.writeSymPath(w, e),
                .message => |sym| {
                    if (try ctx.res.createsCycle(scope_fqn, sym.proto_fqn)) {
                        try w.print("{s}.Lazy(", .{ctx.wire_alias});
                        try ctx.writeSymPath(w, sym);
                        try w.writeAll(")");
                    } else {
                        try ctx.writeSymPath(w, sym);
                    }
                },
            }
            try w.writeAll(",\n");
        }
        try writeIndent(w, indent + 1);
        try w.writeAll("};\n\n");
    }

    var has_defaults = false;
    for (m.fields) |f| {
        if (f.label == .repeated) continue;
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        if (rt == .message) continue;
        if (findDefaultOption(f.options) != null) {
            has_defaults = true;
            break;
        }
    }
    if (has_defaults) {
        try writeIndent(w, indent + 1);
        try w.writeAll("pub const defaults = struct {\n");
        for (m.fields) |f| {
            if (f.label == .repeated) continue;
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            if (rt == .message) continue;
            const raw_def = findDefaultOption(f.options) orelse continue;
            try writeIndent(w, indent + 2);
            try w.writeAll("pub const ");
            try writeIdent(w, f.name);
            try w.writeAll(": ");
            switch (rt) {
                .scalar => |s| try w.writeAll(s.zig_type),
                .@"enum" => |e| try ctx.writeSymPath(w, e),
                .message => unreachable,
            }
            try w.writeAll(" = ");
            try writeDefaultValueExpr(ctx, w, rt, raw_def);
            try w.writeAll(";\n");
        }
        try writeIndent(w, indent + 1);
        try w.writeAll("};\n\n");
    }

    for (m.fields) |f| {
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
        const zname = try zigFieldName(ctx.arena, m, f.name);
        try writeIndent(w, indent + 1);
        try writeIdent(w, zname);
        try w.writeAll(": ");
        if (f.label == .repeated) {
            try w.print("{s}.Repeated(", .{ctx.wire_alias});
            try writeFieldCodecExpr(ctx, w, f, rt, utf8);
            try w.writeAll(") = .empty,\n");
        } else if (rt == .message) {
            if (try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn)) {
                try w.print("?{s}.Lazy(", .{ctx.wire_alias});
                try ctx.writeSymPath(w, rt.message);
                try w.writeAll(") = null,\n");
            } else {
                try w.writeAll("?");
                try ctx.writeSymPath(w, rt.message);
                try w.writeAll(" = null,\n");
            }
        } else if (ctx.res.hasExplicitPresence(ctx.file_idx, f, rt)) {
            try w.writeAll("?");
            switch (rt) {
                .scalar => |s| try w.writeAll(s.zig_type),
                .@"enum" => |e| try ctx.writeSymPath(w, e),
                .message => unreachable,
            }
            try w.writeAll(" = null,\n");
        } else {
            switch (rt) {
                .scalar => |s| try w.print("{s} = {s},\n", .{ s.zig_type, s.default_expr }),
                .@"enum" => |e| {
                    try ctx.writeSymPath(w, e);
                    try w.writeAll(" = @fromBackingInt(0),\n");
                },
                .message => unreachable,
            }
        }
    }

    for (m.maps) |mp| {
        const zname = try zigFieldName(ctx.arena, m, mp.name);
        try writeIndent(w, indent + 1);
        try writeIdent(w, zname);
        try w.writeAll(": ");
        try writeMapType(ctx, scope_fqn, mp, w);
        try w.writeAll(" = .empty,\n");
    }

    for (m.oneofs) |o| {
        const zname = try zigFieldName(ctx.arena, m, o.name);
        try writeIndent(w, indent + 1);
        try writeIdent(w, zname);
        try w.writeAll(": ?@This().");
        const otype = try oneofZigTypeName(ctx.arena, m, o.name);
        try writeIdent(w, otype);
        try w.writeAll(" = null,\n");
    }

    const uf_name = unknownFieldsMemberName(m);
    if (ctx.opts.preserve_unknown_fields) {
        try writeIndent(w, indent + 1);
        try w.print("{s}: {s}.UnknownFields = .empty,\n\n", .{ uf_name, ctx.wire_alias });

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
            try tag_ptr_fields.append(ctx.arena, try zigFieldName(ctx.arena, m, f.name));
        } else {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            if (rt == .message and try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn)) {
                try tag_ptr_fields.append(ctx.arena, try zigFieldName(ctx.arena, m, f.name));
            }
        }
    }
    for (m.maps) |mp| {
        try tag_ptr_fields.append(ctx.arena, try zigFieldName(ctx.arena, m, mp.name));
    }
    for (m.oneofs) |o| {
        for (o.fields) |f| {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            if (rt == .message and try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn)) {
                try tag_ptr_fields.append(ctx.arena, try zigFieldName(ctx.arena, m, o.name));
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
            try emitFieldSize(ctx, m, f, rt, indent + 2, w);
        }
        for (m.maps) |mp| {
            const zname = try zigFieldName(ctx.arena, m, mp.name);
            try writeIndent(w, indent + 2);
            try w.writeAll("total += self.");
            try writeIdent(w, zname);
            try w.print(".encodedSize({d});\n", .{mp.number});
        }
        for (m.oneofs) |o| try emitOneofSize(ctx, m, o, scope_fqn, indent + 2, w);
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
    try w.print("pub fn encode(self: *const @This(), w: anytype) {s}.WriterError(@TypeOf(w))!void {{\n", .{ctx.wire_alias});
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
            try emitFieldEncode(ctx, m, f, rt, indent + 2, w);
        }
        for (m.maps) |mp| {
            const zname = try zigFieldName(ctx.arena, m, mp.name);
            try writeIndent(w, indent + 2);
            try w.writeAll("try self.");
            try writeIdent(w, zname);
            try w.print(".encode({d}, w);\n", .{mp.number});
        }
        for (m.oneofs) |o| try emitOneofEncode(ctx, m, o, scope_fqn, indent + 2, w);
        if (ctx.opts.preserve_unknown_fields) {
            try writeIndent(w, indent + 2);
            try w.print("try self.{s}.encode(@This()._protoz_known_fields, w);\n", .{uf_name});
        }
    }
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    // encodeReverse(rw: *wire.ReverseWriter)
    try writeIndent(w, indent + 1);
    try w.print("pub fn encodeReverse(self: *const @This(), rw: *{s}.ReverseWriter) {s}.EncodeError!void {{\n", .{ ctx.wire_alias, ctx.wire_alias });
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
            try emitOneofReverse(ctx, m, m.oneofs[oi], scope_fqn, indent + 2, w);
        }
        var mi = m.maps.len;
        while (mi > 0) {
            mi -= 1;
            const mp = m.maps[mi];
            const zname = try zigFieldName(ctx.arena, m, mp.name);
            try writeIndent(w, indent + 2);
            try w.writeAll("try self.");
            try writeIdent(w, zname);
            try w.print(".encodeReverse({d}, rw);\n", .{mp.number});
        }
        var fi = m.fields.len;
        while (fi > 0) {
            fi -= 1;
            const f = m.fields[fi];
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            try emitFieldReverse(ctx, m, f, rt, indent + 2, w);
        }
    }
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    // encodeSlice(buf: []u8)
    try writeIndent(w, indent + 1);
    try w.print("pub fn encodeSlice(self: *const @This(), buf: []u8) {s}.EncodeError![]const u8 {{\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 2);
    try w.print("var rw = {s}.ReverseWriter.init(buf);\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 2);
    try w.writeAll("try self.encodeReverse(&rw);\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("return rw.written();\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try emitSkipOrReject(ctx, m, has_members, indent + 1, w);
    try w.writeAll("\n");

    // validateDepth
    try writeIndent(w, indent + 1);
    try w.print("pub fn validateDepth(bytes: []const u8, depth: u32) {s}.DecodeError!void {{\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 2);
    try w.writeAll("@setEvalBranchQuota(100_000);\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("if (depth == 0) return error.RecursionLimitExceeded;\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("const next_depth = depth - 1;\n");
    try writeIndent(w, indent + 2);
    try w.print("var r = {s}.Reader.init(bytes);\n", .{ctx.wire_alias});
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
            try w.print("comptime {s}.rawTag({d}, .len) => try ", .{ ctx.wire_alias, mp.number });
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

    const needs_init_check = try messageNeedsInitCheck(ctx.arena, ctx.res, scope_fqn, m);
    if (needs_init_check) {
        try writeIndent(w, indent + 1);
        try w.writeAll("pub fn isInitialized(self: *const @This()) bool {\n");
        try writeIndent(w, indent + 2);
        try w.print("return self.isInitializedDepth({s}.max_recursion_depth);\n", .{ctx.wire_alias});
        try writeIndent(w, indent + 1);
        try w.writeAll("}\n\n");

        try writeIndent(w, indent + 1);
        try w.writeAll("pub fn isInitializedDepth(self: *const @This(), depth: u32) bool {\n");
        try writeIndent(w, indent + 2);
        try w.writeAll("if (depth == 0) return false;\n");

        for (m.fields) |f| {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            const zname = try zigFieldName(ctx.arena, m, f.name);
            if (f.label == .repeated) {
                if (rt == .message) {
                    const sub_needs = if (rt.message.msg) |sm| try messageNeedsInitCheck(ctx.arena, ctx.res, rt.message.proto_fqn, sm.*) else false;
                    if (sub_needs) {
                        try writeIndent(w, indent + 2);
                        try w.writeAll("{ var it = self.");
                        try writeIdent(w, zname);
                        try w.writeAll(".iterator(); while (it.next() catch return false) |sub| { if (!sub.isInitializedDepth(depth - 1)) return false; } }\n");
                    }
                }
            } else if (rt == .message) {
                const sub_needs = if (rt.message.msg) |sm| try messageNeedsInitCheck(ctx.arena, ctx.res, rt.message.proto_fqn, sm.*) else false;
                if (f.label == .required or sub_needs) {
                    const cyclic = try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn);
                    try writeIndent(w, indent + 2);
                    try w.writeAll("if (self.");
                    try writeIdent(w, zname);
                    if (cyclic) {
                        try w.writeAll(") |lazy| { ");
                        if (sub_needs) {
                            try w.writeAll("const sub = lazy.decodeDepth(depth - 1) catch return false; if (!sub.isInitializedDepth(depth - 1)) return false; ");
                        } else {
                            try w.writeAll("_ = lazy; ");
                        }
                        try w.writeAll("}");
                    } else {
                        try w.writeAll(") |sub| { ");
                        if (sub_needs) {
                            try w.writeAll("if (!sub.isInitializedDepth(depth - 1)) return false; ");
                        } else {
                            try w.writeAll("_ = sub; ");
                        }
                        try w.writeAll("}");
                    }
                    if (f.label == .required) try w.writeAll(" else return false;");
                    try w.writeAll("\n");
                }
            } else if (f.label == .required and ctx.res.hasExplicitPresence(ctx.file_idx, f, rt)) {
                try writeIndent(w, indent + 2);
                try w.writeAll("if (self.");
                try writeIdent(w, zname);
                try w.writeAll(" == null) return false;\n");
            }
        }

        for (m.maps) |mp| {
            const vt = try ctx.res.resolveType(scope_fqn, mp.value_type);
            if (vt == .message) {
                const sub_needs = if (vt.message.msg) |sm| try messageNeedsInitCheck(ctx.arena, ctx.res, vt.message.proto_fqn, sm.*) else false;
                if (sub_needs) {
                    const zname = try zigFieldName(ctx.arena, m, mp.name);
                    try writeIndent(w, indent + 2);
                    try w.writeAll("{ var it = self.");
                    try writeIdent(w, zname);
                    try w.writeAll(".iterator(); while (it.next() catch return false) |entry| { if (!entry.value.isInitializedDepth(depth - 1)) return false; } }\n");
                }
            }
        }

        for (m.oneofs) |o| {
            var covered_branches: usize = 0;
            for (o.fields) |f| {
                const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
                if (rt == .message) {
                    if (rt.message.msg) |sm| {
                        if (try messageNeedsInitCheck(ctx.arena, ctx.res, rt.message.proto_fqn, sm.*)) {
                            covered_branches += 1;
                        }
                    }
                }
            }
            if (covered_branches == 0) continue;
            const o_zname = try zigFieldName(ctx.arena, m, o.name);
            try writeIndent(w, indent + 2);
            try w.writeAll("if (self.");
            try writeIdent(w, o_zname);
            try w.writeAll(") |u| switch (u) {\n");
            for (o.fields) |f| {
                const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
                if (rt != .message) continue;
                const sub_needs = if (rt.message.msg) |sm| try messageNeedsInitCheck(ctx.arena, ctx.res, rt.message.proto_fqn, sm.*) else false;
                if (!sub_needs) continue;
                const cyclic = try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn);
                try writeIndent(w, indent + 3);
                try w.writeAll(".");
                try writeIdent(w, f.name);
                if (cyclic) {
                    try w.writeAll(" => |lazy| { const sub = lazy.decodeDepth(depth - 1) catch return false; if (!sub.isInitializedDepth(depth - 1)) return false; },\n");
                } else {
                    try w.writeAll(" => |sub| if (!sub.isInitializedDepth(depth - 1)) return false,\n");
                }
            }
            if (covered_branches < o.fields.len) {
                try writeIndent(w, indent + 3);
                try w.writeAll("else => {},\n");
            }
            try writeIndent(w, indent + 2);
            try w.writeAll("};\n");
        }

        try writeIndent(w, indent + 2);
        try w.writeAll("return true;\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("}\n\n");
    }

    // decode / decodeDepth / decodeOnly / mergeDepth / mergeOnlyDepth
    try writeIndent(w, indent + 1);
    try w.print("pub fn decode(bytes: []const u8) {s}.DecodeError!@This() {{\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 2);
    try w.print("return @This().decodeDepth(bytes, {s}.max_recursion_depth);\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try writeIndent(w, indent + 1);
    try w.print("pub fn decodeDepth(bytes: []const u8, depth: u32) {s}.DecodeError!@This() {{\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 2);
    try w.writeAll("var self: @This() = .{};\n");
    try writeIndent(w, indent + 2);
    try w.writeAll("try self.mergeDepth(bytes, depth);\n");
    if (needs_init_check) {
        try writeIndent(w, indent + 2);
        try w.writeAll("if (!self.isInitializedDepth(depth)) return error.MissingRequiredField;\n");
    }
    try writeIndent(w, indent + 2);
    try w.writeAll("return self;\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try writeIndent(w, indent + 1);
    try w.print("pub fn decodeOnly(bytes: []const u8, comptime fields: anytype) {s}.DecodeError!{s}.Projection(@This(), fields) {{\n", .{ ctx.wire_alias, ctx.wire_alias });
    try writeIndent(w, indent + 2);
    try w.print("var self: {s}.Projection(@This(), fields) = .{{}};\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 2);
    try w.print("try @This().mergeOnlyDepth(&self, bytes, {s}.max_recursion_depth);\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 2);
    try w.writeAll("return self;\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try writeIndent(w, indent + 1);
    try w.print("pub fn mergeDepth(self: *@This(), bytes: []const u8, depth: u32) {s}.DecodeError!void {{\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 2);
    try w.writeAll("return @This().mergeOnlyDepth(self, bytes, depth);\n");
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try writeIndent(w, indent + 1);
    try w.print("fn mergeOnlyDepth(self: anytype, bytes: []const u8, depth: u32) {s}.DecodeError!void {{\n", .{ctx.wire_alias});
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
            try w.print("var r = {s}.Reader.init(bytes);\n", .{ctx.wire_alias});
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
        try w.print("var r = {s}.Reader.init(bytes);\n", .{ctx.wire_alias});
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
            try emitFieldDecode(ctx, m, f, rt, scope_fqn, indent + 4, w);
        }
        for (m.maps) |mp| {
            const zname = try zigFieldName(ctx.arena, m, mp.name);
            try writeIndent(w, indent + 4);
            try w.print("comptime {s}.rawTag({d}, .len) => if (comptime @hasField(Target, \"{s}\")) {{\n", .{ ctx.wire_alias, mp.number, zname });
            try writeIndent(w, indent + 5);
            try w.writeAll("try self.");
            try writeIdent(w, zname);
            try w.print(".recordEntry(bytes.ptr, tag_ptr, &r, {d}, next_depth);\n", .{mp.number});
            try writeIndent(w, indent + 4);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 5);
            try w.writeAll("try r.skipWireType(.len);\n");
            try writeIndent(w, indent + 4);
            try w.writeAll("},\n");
        }
        for (m.oneofs) |o| try emitOneofDecode(ctx, m, o, scope_fqn, indent + 4, w);

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
    try w.print("pub fn format(self: @This(), w: *{s}.Writer) {s}.Writer.Error!void {{\n", .{ ctx.wire_alias, ctx.wire_alias });
    try writeIndent(w, indent + 2);
    try w.print("return {s}.formatMessage(self, w);\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n");

    // Arena-backed owned escape hatch for messages outliving their wire buffer
    try w.writeAll("\n");
    try writeIndent(w, indent + 1);
    try w.print("pub fn cloneInto(self: @This(), arena: {s}.Allocator) {s}.CloneError!@This() {{\n", .{ ctx.wire_alias, ctx.wire_alias });
    try writeIndent(w, indent + 2);
    try w.print("return {s}.cloneMessage(arena, self);\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try writeIndent(w, indent + 1);
    try w.print("pub fn cloneOwned(self: @This(), allocator: {s}.Allocator) {s}.CloneError!{s}.Owned(@This()) {{\n", .{ ctx.wire_alias, ctx.wire_alias, ctx.wire_alias });
    try writeIndent(w, indent + 2);
    try w.print("return {s}.cloneOwned(allocator, self);\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n");

    try emitJsonMeta(ctx, m, scope_fqn, indent, w);

    // Zero-allocation streaming FieldIterator
    try emitFieldIterator(ctx, m, scope_fqn, has_members, indent, w);
    try emitWktMethods(ctx, scope_fqn, indent, w);

    if (m.extensions.len > 0) {
        var msg_used: std.StringHashMapUnmanaged(void) = .empty;
        for (m.nested_enums) |ne| try msg_used.put(ctx.arena, ne.name, {});
        for (m.nested_messages) |nm| try msg_used.put(ctx.arena, nm.name, {});
        for (m.fields) |f| try msg_used.put(ctx.arena, try zigFieldName(ctx.arena, m, f.name), {});
        for (m.maps) |mp| try msg_used.put(ctx.arena, try zigFieldName(ctx.arena, m, mp.name), {});
        for (m.oneofs) |o| {
            try msg_used.put(ctx.arena, try zigFieldName(ctx.arena, m, o.name), {});
            try msg_used.put(ctx.arena, try oneofZigTypeName(ctx.arena, m, o.name), {});
        }
        if (ctx.opts.preserve_unknown_fields) try msg_used.put(ctx.arena, uf_name, {});
        try w.writeAll("\n");
        try emitExtensions(ctx, m.extensions, scope_fqn, indent + 1, &msg_used, true, w);
    }

    try writeIndent(w, indent);
    try w.writeAll("};\n");
}

fn emitJsonMeta(ctx: GenCtx, m: ast.Message, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    try w.writeAll("\n");
    try writeIndent(w, indent + 1);
    try w.print("pub const _protoz_json_fields: []const {s}.json.JsonFieldMeta = &.{{\n", .{ctx.wire_alias});

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
        const zname = try zigFieldName(ctx.arena, m, f.name);

        try writeIndent(w, indent + 2);
        try w.print(".{{ .zig_name = \"{s}\", .proto_name = \"{s}\", .json_name = \"", .{ zname, f.name });
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
        const zname = try zigFieldName(ctx.arena, m, mp.name);
        try writeIndent(w, indent + 2);
        try w.print(".{{ .zig_name = \"{s}\", .proto_name = \"{s}\", .json_name = \"", .{ zname, mp.name });
        try writeLowerCamelCase(w, mp.name);
        try w.print("\", .kind = .map, .elem_is_bytes = {} }},\n", .{val_is_bytes});
    }

    for (m.oneofs) |o| {
        const o_zname = try zigFieldName(ctx.arena, m, o.name);
        for (o.fields) |f| {
            const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
            const is_bytes = (rt == .scalar and std.mem.eql(u8, rt.scalar.wire_kind, ".bytes"));
            const is_lazy = (rt == .message and try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn));
            try writeIndent(w, indent + 2);
            try w.print(".{{ .zig_name = \"{s}\", .proto_name = \"{s}\", .json_name = \"", .{ f.name, f.name });
            try writeLowerCamelCase(w, f.name);
            try w.print("\", .kind = .oneof, .is_bytes = {}, .oneof_field = \"{s}\", .is_lazy = {} }},\n", .{
                is_bytes,
                o_zname,
                is_lazy,
            });
        }
    }

    try writeIndent(w, indent + 1);
    try w.writeAll("};\n\n");

    try writeIndent(w, indent + 1);
    try w.print("pub fn encodeJson(self: @This(), w: anytype, opts: {s}.json.EncodeOptions) {s}.json.EncodeError(@TypeOf(w))!void {{\n", .{ ctx.wire_alias, ctx.wire_alias });
    try writeIndent(w, indent + 2);
    try w.print("return {s}.json.encodeMessage(self, w, opts);\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try writeIndent(w, indent + 1);
    try w.print("pub fn encodeJsonSlice(self: @This(), buf: []u8, opts: {s}.json.EncodeOptions) {s}.json.SliceEncodeError![]const u8 {{\n", .{ ctx.wire_alias, ctx.wire_alias });
    try writeIndent(w, indent + 2);
    try w.print("return {s}.json.encodeMessageSlice(self, buf, opts);\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n\n");

    try writeIndent(w, indent + 1);
    try w.print("pub fn decodeJson(arena: {s}.Allocator, input: []const u8, opts: {s}.json.DecodeOptions) {s}.json.DecodeError!@This() {{\n", .{ ctx.wire_alias, ctx.wire_alias, ctx.wire_alias });
    try writeIndent(w, indent + 2);
    try w.print("return {s}.json.decodeMessage(@This(), arena, input, opts);\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n");
}

fn emitWktMethods(ctx: GenCtx, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    const wa = ctx.wire_alias;
    const wkt_kind: enum { none, timestamp, duration, any } =
        if (std.mem.eql(u8, scope_fqn, "google.protobuf.Timestamp"))
            .timestamp
        else if (std.mem.eql(u8, scope_fqn, "google.protobuf.Duration"))
            .duration
        else if (std.mem.eql(u8, scope_fqn, "google.protobuf.Any"))
            .any
        else
            .none;
    if (wkt_kind == .none) return;

    try w.writeAll("\n");
    switch (wkt_kind) {
        .timestamp => {
            try writeIndent(w, indent + 1);
            try w.print("pub fn validate(self: @This()) {s}.wkt.WktError!void {{ return {s}.wkt.validateTimestamp(self); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn fromUnixSeconds(seconds: i64) {s}.wkt.WktError!@This() {{ return {s}.wkt.timestampFromUnixSeconds(@This(), seconds); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn fromUnixMillis(millis: i64) {s}.wkt.WktError!@This() {{ return {s}.wkt.timestampFromUnixMillis(@This(), millis); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn fromUnixNanos(total_ns: i128) {s}.wkt.WktError!@This() {{ return {s}.wkt.timestampFromUnixNanos(@This(), total_ns); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn toUnixNanos(self: @This()) {s}.wkt.WktError!i128 {{ return {s}.wkt.timestampToUnixNanos(self); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn toUnixMillis(self: @This()) {s}.wkt.WktError!i64 {{ return {s}.wkt.timestampToUnixMillis(self); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn addDuration(self: @This(), dur: anytype) {s}.wkt.WktError!@This() {{ return {s}.wkt.timestampAddDuration(self, dur); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn diff(self: @This(), comptime DurT: type, other: @This()) {s}.wkt.WktError!DurT {{ return {s}.wkt.timestampDiff(DurT, self, other); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn formatRfc3339Buf(self: @This(), buf: *[32]u8) {s}.wkt.WktError![]const u8 {{ return {s}.wkt.formatTimestampBuf(self, buf); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn formatRfc3339(self: @This(), w: *{s}.Writer) ({s}.wkt.WktError || {s}.Writer.Error)!void {{ return {s}.wkt.formatTimestamp(self, w); }}\n", .{ wa, wa, wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn parseRfc3339(input: []const u8) {s}.wkt.WktError!@This() {{ return {s}.wkt.parseTimestamp(@This(), input); }}\n", .{ wa, wa });
        },
        .duration => {
            try writeIndent(w, indent + 1);
            try w.print("pub fn validate(self: @This()) {s}.wkt.WktError!void {{ return {s}.wkt.validateDuration(self); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn fromSeconds(seconds: i64) {s}.wkt.WktError!@This() {{ return {s}.wkt.durationFromSeconds(@This(), seconds); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn fromMillis(millis: i64) {s}.wkt.WktError!@This() {{ return {s}.wkt.durationFromMillis(@This(), millis); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn fromNanos(total_ns: i128) {s}.wkt.WktError!@This() {{ return {s}.wkt.durationFromNanos(@This(), total_ns); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn toNanos(self: @This()) {s}.wkt.WktError!i128 {{ return {s}.wkt.durationToNanos(self); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn toMillis(self: @This()) {s}.wkt.WktError!i64 {{ return {s}.wkt.durationToMillis(self); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn add(self: @This(), other: @This()) {s}.wkt.WktError!@This() {{ return {s}.wkt.durationAdd(self, other); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn sub(self: @This(), other: @This()) {s}.wkt.WktError!@This() {{ return {s}.wkt.durationSub(self, other); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn negate(self: @This()) {s}.wkt.WktError!@This() {{ return {s}.wkt.durationNegate(self); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn formatProtoJsonBuf(self: @This(), buf: *[32]u8) {s}.wkt.WktError![]const u8 {{ return {s}.wkt.formatDurationBuf(self, buf); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn formatProtoJson(self: @This(), w: *{s}.Writer) ({s}.wkt.WktError || {s}.Writer.Error)!void {{ return {s}.wkt.formatDuration(self, w); }}\n", .{ wa, wa, wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn parseProtoJson(input: []const u8) {s}.wkt.WktError!@This() {{ return {s}.wkt.parseDuration(@This(), input); }}\n", .{ wa, wa });
        },
        .any => {
            try writeIndent(w, indent + 1);
            try w.print("pub fn typeName(self: @This()) ?[]const u8 {{ return {s}.wkt.anyTypeName(self.type_url); }}\n", .{wa});
            try writeIndent(w, indent + 1);
            try w.print("pub inline fn is(self: @This(), comptime M: type) bool {{ return {s}.wkt.anyIs(self, M); }}\n", .{wa});
            try writeIndent(w, indent + 1);
            try w.print("pub fn unpack(self: @This(), comptime M: type) {s}.wkt.AnyError!M {{ return {s}.wkt.unpackAny(self, M); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn packSlice(msg: anytype, value_buf: []u8) {s}.EncodeError!@This() {{ return {s}.wkt.packAnySlice(@This(), msg, value_buf); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn packWithPrefixSlice(comptime prefix: []const u8, msg: anytype, value_buf: []u8) {s}.EncodeError!@This() {{ return {s}.wkt.packAnyWithPrefixSlice(@This(), prefix, msg, value_buf); }}\n", .{ wa, wa });
            try writeIndent(w, indent + 1);
            try w.print("pub fn packAlloc(allocator: {s}.Allocator, msg: anytype) {s}.Allocator.Error!@This() {{ return {s}.wkt.packAnyAlloc(@This(), allocator, msg); }}\n", .{ wa, wa, wa });
        },
        .none => unreachable,
    }
}

fn emitSkipOrReject(ctx: GenCtx, m: ast.Message, has_members: bool, indent: usize, w: *std.Io.Writer) !void {
    try writeIndent(w, indent);
    try w.print("fn _protozSkipOrReject(comptime Target: type, r: *{s}.Reader, raw_tag: u32, depth: u32) {s}.DecodeError!bool {{\n", .{ ctx.wire_alias, ctx.wire_alias });
    try writeIndent(w, indent + 1);
    try w.writeAll("@branchHint(.cold);\n");
    try writeIndent(w, indent + 1);
    try w.print("const tag = try {s}.decodeTag(raw_tag);\n", .{ctx.wire_alias});
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
            const zname = try zigFieldName(ctx.arena, m, f.name);
            try writeIndent(w, indent + 2);
            try w.print("{d} => if (comptime @hasField(Target, \"{s}\")) return error.WireTypeMismatch else {{ try r.skipField(tag, depth); return false; }},\n", .{ f.number, zname });
        }
        for (m.maps) |mp| {
            const zname = try zigFieldName(ctx.arena, m, mp.name);
            try writeIndent(w, indent + 2);
            try w.print("{d} => if (comptime @hasField(Target, \"{s}\")) return error.WireTypeMismatch else {{ try r.skipField(tag, depth); return false; }},\n", .{ mp.number, zname });
        }
        for (m.oneofs) |o| {
            const o_zname = try zigFieldName(ctx.arena, m, o.name);
            for (o.fields) |f| {
                try writeIndent(w, indent + 2);
                try w.print("{d} => if (comptime @hasField(Target, \"{s}\")) return error.WireTypeMismatch else {{ try r.skipField(tag, depth); return false; }},\n", .{ f.number, o_zname });
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
    try w.print("r: {s}.Reader,\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 2);
    try w.print("depth: u32 = {s}.max_recursion_depth,\n\n", .{ctx.wire_alias});

    try writeIndent(w, indent + 2);
    try w.writeAll("pub const Item = union(enum) {\n");

    for (m.fields) |f| {
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
        try writeIndent(w, indent + 3);
        try writeIdent(w, f.name);
        try w.writeAll(": ");
        if (f.label == .repeated and isPackable(rt)) {
            try w.print("{s}.PackedChunk(", .{ctx.wire_alias});
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(")");
        } else switch (rt) {
            .scalar => |s| try w.writeAll(s.zig_type),
            .@"enum" => |sym| try ctx.writeSymPath(w, sym),
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
                .@"enum" => |sym| try ctx.writeSymPath(w, sym),
                .message => try w.writeAll("[]const u8"),
            }
            try w.writeAll(",\n");
        }
    }

    try writeIndent(w, indent + 3);
    try w.print("{s}: {s}.UnknownField,\n", .{ unknown_tag, ctx.wire_alias });
    try writeIndent(w, indent + 2);
    try w.writeAll("};\n\n");

    try writeIndent(w, indent + 2);
    try w.print("pub fn next(self: *@This()) {s}.DecodeError!?Item {{\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 3);
    try w.writeAll("@setEvalBranchQuota(100_000);\n");
    try writeIndent(w, indent + 3);
    try w.writeAll("const raw_tag = (try self.r.readRawTag()) orelse return null;\n");

    if (!has_members) {
        try writeIndent(w, indent + 3);
        try w.print("const tag = try {s}.decodeTag(raw_tag);\n", .{ctx.wire_alias});
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
                try w.print("comptime {s}.rawTag({d}, .len) => return .{{ .", .{ ctx.wire_alias, f.number });
                try writeIdent(w, f.name);
                try w.writeAll(" = .{ .@\"packed\" = try self.r.readBytes() } },\n");

                try writeIndent(w, indent + 4);
                try w.print("comptime {s}.rawTag({d}, ", .{ ctx.wire_alias, f.number });
                try writeCodecExpr(ctx, w, rt, utf8);
                try w.writeAll(".wire_type) => return .{ .");
                try writeIdent(w, f.name);
                try w.writeAll(" = .{ .single = try ");
                try writeCodecExpr(ctx, w, rt, utf8);
                try w.writeAll(".read(&self.r, self.depth) } },\n");
            } else if (rt == .message) {
                if (f.is_group) {
                    try writeIndent(w, indent + 4);
                    try w.print("comptime {s}.rawTag({d}, .sgroup) => return .{{ .", .{ ctx.wire_alias, f.number });
                    try writeIdent(w, f.name);
                    try w.print(" = try self.r.readGroupBytes({d}, self.depth) }},\n", .{f.number});
                } else {
                    try writeIndent(w, indent + 4);
                    try w.print("comptime {s}.rawTag({d}, .len) => return .{{ .", .{ ctx.wire_alias, f.number });
                    try writeIdent(w, f.name);
                    try w.writeAll(" = try self.r.readBytes() },\n");
                }
            } else {
                try writeIndent(w, indent + 4);
                try w.print("comptime {s}.rawTag({d}, ", .{ ctx.wire_alias, f.number });
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
            try w.print("comptime {s}.rawTag({d}, .len) => {{\n", .{ ctx.wire_alias, mp.number });
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
                    if (f.is_group) {
                        try writeIndent(w, indent + 4);
                        try w.print("comptime {s}.rawTag({d}, .sgroup) => return .{{ .", .{ ctx.wire_alias, f.number });
                        try writeIdent(w, f.name);
                        try w.print(" = try self.r.readGroupBytes({d}, self.depth) }},\n", .{f.number});
                    } else {
                        try writeIndent(w, indent + 4);
                        try w.print("comptime {s}.rawTag({d}, .len) => return .{{ .", .{ ctx.wire_alias, f.number });
                        try writeIdent(w, f.name);
                        try w.writeAll(" = try self.r.readBytes() },\n");
                    }
                } else {
                    try writeIndent(w, indent + 4);
                    try w.print("comptime {s}.rawTag({d}, ", .{ ctx.wire_alias, f.number });
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
        try w.print("const tag = try {s}.decodeTag(raw_tag);\n", .{ctx.wire_alias});
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
    try w.print("return .{{ .r = {s}.Reader.init(bytes) }};\n", .{ctx.wire_alias});
    try writeIndent(w, indent + 1);
    try w.writeAll("}\n");
}

fn emitFieldSize(ctx: GenCtx, m: ast.Message, f: ast.Field, rt: resolver.ResolvedType, indent: usize, w: *std.Io.Writer) !void {
    const zname = try zigFieldName(ctx.arena, m, f.name);
    if (f.label == .repeated) {
        const pack = ctx.res.isPacked(ctx.file_idx, f);
        try writeIndent(w, indent);
        try w.writeAll("total += self.");
        try writeIdent(w, zname);
        try w.print(".encodedSize({d}, {});\n", .{ f.number, pack });
        return;
    }
    if (rt == .message) {
        try writeIndent(w, indent);
        try w.writeAll("if (self.");
        try writeIdent(w, zname);
        try w.writeAll(") |val| {\n");
        if (f.is_group) {
            try writeIndent(w, indent + 1);
            try w.print("total += {s}.tagSize({d}) * 2 + val.encodedSize();\n", .{ ctx.wire_alias, f.number });
        } else {
            try writeIndent(w, indent + 1);
            try w.writeAll("const sub = val.encodedSize();\n");
            try writeIndent(w, indent + 1);
            try w.print("total += {s}.tagSize({d}) + {s}.varintSize(sub) + sub;\n", .{ ctx.wire_alias, f.number, ctx.wire_alias });
        }
        try writeIndent(w, indent);
        try w.writeAll("}\n");
        return;
    }
    const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
    if (ctx.res.hasExplicitPresence(ctx.file_idx, f, rt)) {
        try writeIndent(w, indent);
        try w.writeAll("if (self.");
        try writeIdent(w, zname);
        try w.print(") |val| total += {s}.tagSize({d}) + ", .{ ctx.wire_alias, f.number });
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".size(val);\n");
    } else {
        try writeIndent(w, indent);
        try w.writeAll("if (!");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".isDefault(self.");
        try writeIdent(w, zname);
        try w.print(")) total += {s}.tagSize({d}) + ", .{ ctx.wire_alias, f.number });
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".size(self.");
        try writeIdent(w, zname);
        try w.writeAll(");\n");
    }
}

fn emitFieldEncode(ctx: GenCtx, m: ast.Message, f: ast.Field, rt: resolver.ResolvedType, indent: usize, w: *std.Io.Writer) !void {
    const zname = try zigFieldName(ctx.arena, m, f.name);
    if (f.label == .repeated) {
        const pack = ctx.res.isPacked(ctx.file_idx, f);
        try writeIndent(w, indent);
        try w.writeAll("try self.");
        try writeIdent(w, zname);
        try w.print(".encode({d}, {}, w);\n", .{ f.number, pack });
        return;
    }
    if (rt == .message) {
        try writeIndent(w, indent);
        try w.writeAll("if (self.");
        try writeIdent(w, zname);
        try w.writeAll(") |val| {\n");
        if (f.is_group) {
            try writeIndent(w, indent + 1);
            try w.print("try {s}.writeTag(w, {d}, .sgroup);\n", .{ ctx.wire_alias, f.number });
            try writeIndent(w, indent + 1);
            try w.writeAll("try val.encode(w);\n");
            try writeIndent(w, indent + 1);
            try w.print("try {s}.writeTag(w, {d}, .egroup);\n", .{ ctx.wire_alias, f.number });
        } else {
            try writeIndent(w, indent + 1);
            try w.print("try {s}.writeTag(w, {d}, .len);\n", .{ ctx.wire_alias, f.number });
            try writeIndent(w, indent + 1);
            try w.print("try {s}.writeVarint(w, val.encodedSize());\n", .{ctx.wire_alias});
            try writeIndent(w, indent + 1);
            try w.writeAll("try val.encode(w);\n");
        }
        try writeIndent(w, indent);
        try w.writeAll("}\n");
        return;
    }
    const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
    if (ctx.res.hasExplicitPresence(ctx.file_idx, f, rt)) {
        try writeIndent(w, indent);
        try w.writeAll("if (self.");
        try writeIdent(w, zname);
        try w.writeAll(") |val| {\n");
        try writeIndent(w, indent + 1);
        try w.print("try {s}.writeTag(w, {d}, ", .{ ctx.wire_alias, f.number });
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
        try writeIdent(w, zname);
        try w.writeAll(")) {\n");
        try writeIndent(w, indent + 1);
        try w.print("try {s}.writeTag(w, {d}, ", .{ ctx.wire_alias, f.number });
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".wire_type);\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("try ");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".write(w, self.");
        try writeIdent(w, zname);
        try w.writeAll(");\n");
        try writeIndent(w, indent);
        try w.writeAll("}\n");
    }
}

fn emitFieldReverse(ctx: GenCtx, m: ast.Message, f: ast.Field, rt: resolver.ResolvedType, indent: usize, w: *std.Io.Writer) !void {
    const zname = try zigFieldName(ctx.arena, m, f.name);
    if (f.label == .repeated) {
        const pack = ctx.res.isPacked(ctx.file_idx, f);
        try writeIndent(w, indent);
        try w.writeAll("try self.");
        try writeIdent(w, zname);
        try w.print(".encodeReverse({d}, {}, rw);\n", .{ f.number, pack });
        return;
    }
    if (rt == .message) {
        try writeIndent(w, indent);
        try w.writeAll("if (self.");
        try writeIdent(w, zname);
        try w.writeAll(") |val| {\n");
        if (f.is_group) {
            try writeIndent(w, indent + 1);
            try w.print("try rw.writeTag({d}, .egroup);\n", .{f.number});
            try writeIndent(w, indent + 1);
            try w.writeAll("try val.encodeReverse(rw);\n");
            try writeIndent(w, indent + 1);
            try w.print("try rw.writeTag({d}, .sgroup);\n", .{f.number});
        } else {
            try writeIndent(w, indent + 1);
            try w.writeAll("const end = rw.pos;\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("try val.encodeReverse(rw);\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("try rw.writeVarint(end - rw.pos);\n");
            try writeIndent(w, indent + 1);
            try w.print("try rw.writeTag({d}, .len);\n", .{f.number});
        }
        try writeIndent(w, indent);
        try w.writeAll("}\n");
        return;
    }
    const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
    if (ctx.res.hasExplicitPresence(ctx.file_idx, f, rt)) {
        try writeIndent(w, indent);
        try w.writeAll("if (self.");
        try writeIdent(w, zname);
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
        try writeIdent(w, zname);
        try w.writeAll(")) {\n");
        try writeIndent(w, indent + 1);
        try w.writeAll("try ");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".writeReverse(rw, self.");
        try writeIdent(w, zname);
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
            try w.print("comptime {s}.rawTag({d}, .len) => try {s}.Repeated(", .{ ctx.wire_alias, f.number, ctx.wire_alias });
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(").validatePacked(try r.readBytes()),\n");

            try writeIndent(w, indent);
            try w.print("comptime {s}.rawTag({d}, ", .{ ctx.wire_alias, f.number });
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".wire_type) => try ");
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".validate(&r, next_depth),\n");
        } else {
            const wt_str = if (f.is_group) ".sgroup" else ".len";
            try writeIndent(w, indent);
            try w.print("comptime {s}.rawTag({d}, {s}) => try ", .{ ctx.wire_alias, f.number, wt_str });
            try writeFieldCodecExpr(ctx, w, f, rt, utf8);
            try w.writeAll(".validate(&r, next_depth),\n");
        }
    } else if (rt == .message) {
        if (f.is_group) {
            try writeIndent(w, indent);
            try w.print("comptime {s}.rawTag({d}, .sgroup) => try ", .{ ctx.wire_alias, f.number });
            try ctx.writeSymPath(w, rt.message);
            try w.print(".validateDepth(try r.readGroupBytes({d}, next_depth), next_depth),\n", .{f.number});
        } else {
            try writeIndent(w, indent);
            try w.print("comptime {s}.rawTag({d}, .len) => try ", .{ ctx.wire_alias, f.number });
            try ctx.writeSymPath(w, rt.message);
            try w.writeAll(".validateDepth(try r.readBytes(), next_depth),\n");
        }
    } else {
        try writeIndent(w, indent);
        try w.print("comptime {s}.rawTag({d}, ", .{ ctx.wire_alias, f.number });
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".wire_type) => try ");
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.writeAll(".validate(&r, next_depth),\n");
    }
}

fn emitFieldDecode(ctx: GenCtx, m: ast.Message, f: ast.Field, rt: resolver.ResolvedType, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
    const zname = try zigFieldName(ctx.arena, m, f.name);
    if (f.label == .repeated) {
        if (isPackable(rt)) {
            try writeIndent(w, indent);
            try w.print("comptime {s}.rawTag({d}, .len) => if (comptime @hasField(Target, \"{s}\")) {{\n", .{ ctx.wire_alias, f.number, zname });
            try writeIndent(w, indent + 1);
            try w.writeAll("try self.");
            try writeIdent(w, zname);
            try w.print(".recordPacked(bytes.ptr, tag_ptr, &r, {d});\n", .{f.number});
            try writeIndent(w, indent);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 1);
            try w.writeAll("try r.skipWireType(.len);\n");
            try writeIndent(w, indent);
            try w.writeAll("},\n");

            try writeIndent(w, indent);
            try w.print("comptime {s}.rawTag({d}, ", .{ ctx.wire_alias, f.number });
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.print(".wire_type) => if (comptime @hasField(Target, \"{s}\")) {{\n", .{zname});
            try writeIndent(w, indent + 1);
            try w.writeAll("try self.");
            try writeIdent(w, zname);
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
            const wt_str = if (f.is_group) ".sgroup" else ".len";
            try writeIndent(w, indent);
            try w.print("comptime {s}.rawTag({d}, {s}) => if (comptime @hasField(Target, \"{s}\")) {{\n", .{ ctx.wire_alias, f.number, wt_str, zname });
            try writeIndent(w, indent + 1);
            try w.writeAll("try self.");
            try writeIdent(w, zname);
            try w.print(".recordUnpacked(bytes.ptr, tag_ptr, &r, {d}, next_depth);\n", .{f.number});
            try writeIndent(w, indent);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 1);
            if (f.is_group) {
                try w.print("_ = try r.readGroupBytes({d}, next_depth);\n", .{f.number});
            } else {
                try w.writeAll("try r.skipWireType(.len);\n");
            }
            try writeIndent(w, indent);
            try w.writeAll("},\n");
        }
    } else if (rt == .message) {
        const wt_str = if (f.is_group) ".sgroup" else ".len";
        const cyclic = try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn);
        try writeIndent(w, indent);
        try w.print("comptime {s}.rawTag({d}, {s}) => {{\n", .{ ctx.wire_alias, f.number, wt_str });
        try writeIndent(w, indent + 1);
        try w.print("if (comptime @hasField(Target, \"{s}\")) {{\n", .{zname});
        try writeIndent(w, indent + 2);
        if (f.is_group) {
            try w.print("const sub_bytes = try r.readGroupBytes({d}, next_depth);\n", .{f.number});
        } else {
            try w.writeAll("const sub_bytes = try r.readBytes();\n");
        }
        if (cyclic) {
            try writeIndent(w, indent + 2);
            try w.writeAll("try ");
            try ctx.writeSymPath(w, rt.message);
            try w.writeAll(".validateDepth(sub_bytes, next_depth);\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("if (self.");
            try writeIdent(w, zname);
            try w.writeAll(") |*existing| {\n");
            try writeIndent(w, indent + 3);
            try w.print("try existing.mergeRaw(bytes.ptr, tag_ptr, sub_bytes, r.ptr, {d});\n", .{f.number});
            try writeIndent(w, indent + 2);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 3);
            try w.writeAll("self.");
            try writeIdent(w, zname);
            try w.writeAll(" = .{ .raw_wire = .{ .data = sub_bytes, .tag_ptr = tag_ptr } };\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("}\n");
        } else {
            try writeIndent(w, indent + 2);
            try w.writeAll("if (self.");
            try writeIdent(w, zname);
            try w.writeAll(") |*existing| {\n");
            try writeIndent(w, indent + 3);
            try w.writeAll("try existing.mergeDepth(sub_bytes, next_depth);\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 3);
            try w.writeAll("self.");
            try writeIdent(w, zname);
            try w.writeAll(" = try ");
            try ctx.writeSymPath(w, rt.message);
            try w.writeAll(".decodeDepth(sub_bytes, next_depth);\n");
            try writeIndent(w, indent + 2);
            try w.writeAll("}\n");
        }
        try writeIndent(w, indent + 1);
        try w.writeAll("} else {\n");
        try writeIndent(w, indent + 2);
        if (f.is_group) {
            try w.print("_ = try r.readGroupBytes({d}, next_depth);\n", .{f.number});
        } else {
            try w.writeAll("try r.skipWireType(.len);\n");
        }
        try writeIndent(w, indent + 1);
        try w.writeAll("}\n");
        try writeIndent(w, indent);
        try w.writeAll("},\n");
    } else {
        try writeIndent(w, indent);
        try w.print("comptime {s}.rawTag({d}, ", .{ ctx.wire_alias, f.number });
        try writeCodecExpr(ctx, w, rt, utf8);
        try w.print(".wire_type) => if (comptime @hasField(Target, \"{s}\")) {{\n", .{zname});
        try writeIndent(w, indent + 1);
        try w.writeAll("self.");
        try writeIdent(w, zname);
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

fn emitOneofSize(ctx: GenCtx, m: ast.Message, o: ast.Oneof, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    if (o.fields.len == 0) return;
    const o_zname = try zigFieldName(ctx.arena, m, o.name);
    try writeIndent(w, indent);
    try w.writeAll("if (self.");
    try writeIdent(w, o_zname);
    try w.writeAll(") |u| switch (u) {\n");
    for (o.fields) |f| {
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
        try writeIndent(w, indent + 1);
        try w.writeAll(".");
        try writeIdent(w, f.name);
        try w.writeAll(" => |val| ");
        if (rt == .message) {
            if (f.is_group) {
                try w.print("total += {s}.tagSize({d}) * 2 + val.encodedSize(),\n", .{ ctx.wire_alias, f.number });
            } else {
                try w.print("{{ const sub = val.encodedSize(); total += {s}.tagSize({d}) + {s}.varintSize(sub) + sub; }},\n", .{ ctx.wire_alias, f.number, ctx.wire_alias });
            }
        } else {
            try w.print("total += {s}.tagSize({d}) + ", .{ ctx.wire_alias, f.number });
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".size(val),\n");
        }
    }
    try writeIndent(w, indent);
    try w.writeAll("};\n");
}

fn emitOneofEncode(ctx: GenCtx, m: ast.Message, o: ast.Oneof, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    if (o.fields.len == 0) return;
    const o_zname = try zigFieldName(ctx.arena, m, o.name);
    try writeIndent(w, indent);
    try w.writeAll("if (self.");
    try writeIdent(w, o_zname);
    try w.writeAll(") |u| switch (u) {\n");
    for (o.fields) |f| {
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
        try writeIndent(w, indent + 1);
        try w.writeAll(".");
        try writeIdent(w, f.name);
        try w.writeAll(" => |val| {\n");
        if (rt == .message) {
            if (f.is_group) {
                try writeIndent(w, indent + 2);
                try w.print("try {s}.writeTag(w, {d}, .sgroup);\n", .{ ctx.wire_alias, f.number });
                try writeIndent(w, indent + 2);
                try w.writeAll("try val.encode(w);\n");
                try writeIndent(w, indent + 2);
                try w.print("try {s}.writeTag(w, {d}, .egroup);\n", .{ ctx.wire_alias, f.number });
            } else {
                try writeIndent(w, indent + 2);
                try w.print("try {s}.writeTag(w, {d}, .len);\n", .{ ctx.wire_alias, f.number });
                try writeIndent(w, indent + 2);
                try w.print("try {s}.writeVarint(w, val.encodedSize());\n", .{ctx.wire_alias});
                try writeIndent(w, indent + 2);
                try w.writeAll("try val.encode(w);\n");
            }
        } else {
            try writeIndent(w, indent + 2);
            try w.print("try {s}.writeTag(w, {d}, ", .{ ctx.wire_alias, f.number });
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

fn emitOneofReverse(ctx: GenCtx, m: ast.Message, o: ast.Oneof, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    if (o.fields.len == 0) return;
    const o_zname = try zigFieldName(ctx.arena, m, o.name);
    try writeIndent(w, indent);
    try w.writeAll("if (self.");
    try writeIdent(w, o_zname);
    try w.writeAll(") |u| switch (u) {\n");
    for (o.fields) |f| {
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
        try writeIndent(w, indent + 1);
        try w.writeAll(".");
        try writeIdent(w, f.name);
        try w.writeAll(" => |val| {\n");
        if (rt == .message) {
            if (f.is_group) {
                try writeIndent(w, indent + 2);
                try w.print("try rw.writeTag({d}, .egroup);\n", .{f.number});
                try writeIndent(w, indent + 2);
                try w.writeAll("try val.encodeReverse(rw);\n");
                try writeIndent(w, indent + 2);
                try w.print("try rw.writeTag({d}, .sgroup);\n", .{f.number});
            } else {
                try writeIndent(w, indent + 2);
                try w.writeAll("const end = rw.pos;\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("try val.encodeReverse(rw);\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("try rw.writeVarint(end - rw.pos);\n");
                try writeIndent(w, indent + 2);
                try w.print("try rw.writeTag({d}, .len);\n", .{f.number});
            }
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
            if (f.is_group) {
                try w.print("comptime {s}.rawTag({d}, .sgroup) => try ", .{ ctx.wire_alias, f.number });
                try ctx.writeSymPath(w, rt.message);
                try w.print(".validateDepth(try r.readGroupBytes({d}, next_depth), next_depth),\n", .{f.number});
            } else {
                try w.print("comptime {s}.rawTag({d}, .len) => try ", .{ ctx.wire_alias, f.number });
                try ctx.writeSymPath(w, rt.message);
                try w.writeAll(".validateDepth(try r.readBytes(), next_depth),\n");
            }
        } else {
            try w.print("comptime {s}.rawTag({d}, ", .{ ctx.wire_alias, f.number });
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".wire_type) => try ");
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.writeAll(".validate(&r, next_depth),\n");
        }
    }
}

fn emitOneofDecode(ctx: GenCtx, m: ast.Message, o: ast.Oneof, scope_fqn: []const u8, indent: usize, w: *std.Io.Writer) !void {
    const o_zname = try zigFieldName(ctx.arena, m, o.name);
    for (o.fields) |f| {
        const rt = try ctx.res.resolveType(scope_fqn, f.type_name);
        const utf8 = ctx.res.validatesUtf8(ctx.file_idx, f.options);
        if (rt == .message) {
            const wt_str = if (f.is_group) ".sgroup" else ".len";
            const cyclic = try ctx.res.createsCycle(scope_fqn, rt.message.proto_fqn);
            try writeIndent(w, indent);
            try w.print("comptime {s}.rawTag({d}, {s}) => {{\n", .{ ctx.wire_alias, f.number, wt_str });
            try writeIndent(w, indent + 1);
            try w.print("if (comptime @hasField(Target, \"{s}\")) {{\n", .{o_zname});
            try writeIndent(w, indent + 2);
            if (f.is_group) {
                try w.print("const sub_bytes = try r.readGroupBytes({d}, next_depth);\n", .{f.number});
            } else {
                try w.writeAll("const sub_bytes = try r.readBytes();\n");
            }
            if (cyclic) {
                try writeIndent(w, indent + 2);
                try w.writeAll("try ");
                try ctx.writeSymPath(w, rt.message);
                try w.writeAll(".validateDepth(sub_bytes, next_depth);\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("if (self.");
                try writeIdent(w, o_zname);
                try w.writeAll(" != null and self.");
                try writeIdent(w, o_zname);
                try w.writeAll(".? == .");
                try writeIdent(w, f.name);
                try w.writeAll(") {\n");
                try writeIndent(w, indent + 3);
                try w.writeAll("try self.");
                try writeIdent(w, o_zname);
                try w.writeAll(".?.");
                try writeIdent(w, f.name);
                try w.print(".mergeRaw(bytes.ptr, tag_ptr, sub_bytes, r.ptr, {d});\n", .{f.number});
                try writeIndent(w, indent + 2);
                try w.writeAll("} else {\n");
                try writeIndent(w, indent + 3);
                try w.writeAll("self.");
                try writeIdent(w, o_zname);
                try w.writeAll(" = .{ .");
                try writeIdent(w, f.name);
                try w.writeAll(" = .{ .raw_wire = .{ .data = sub_bytes, .tag_ptr = tag_ptr } } };\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("}\n");
            } else {
                try writeIndent(w, indent + 2);
                try w.writeAll("if (self.");
                try writeIdent(w, o_zname);
                try w.writeAll(" != null and self.");
                try writeIdent(w, o_zname);
                try w.writeAll(".? == .");
                try writeIdent(w, f.name);
                try w.writeAll(") {\n");
                try writeIndent(w, indent + 3);
                try w.writeAll("try self.");
                try writeIdent(w, o_zname);
                try w.writeAll(".?.");
                try writeIdent(w, f.name);
                try w.writeAll(".mergeDepth(sub_bytes, next_depth);\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("} else {\n");
                try writeIndent(w, indent + 3);
                try w.writeAll("self.");
                try writeIdent(w, o_zname);
                try w.writeAll(" = .{ .");
                try writeIdent(w, f.name);
                try w.writeAll(" = try ");
                try ctx.writeSymPath(w, rt.message);
                try w.writeAll(".decodeDepth(sub_bytes, next_depth) };\n");
                try writeIndent(w, indent + 2);
                try w.writeAll("}\n");
            }
            try writeIndent(w, indent + 1);
            try w.writeAll("} else {\n");
            try writeIndent(w, indent + 2);
            if (f.is_group) {
                try w.print("_ = try r.readGroupBytes({d}, next_depth);\n", .{f.number});
            } else {
                try w.writeAll("try r.skipWireType(.len);\n");
            }
            try writeIndent(w, indent + 1);
            try w.writeAll("}\n");
            try writeIndent(w, indent);
            try w.writeAll("},\n");
        } else {
            try writeIndent(w, indent);
            try w.print("comptime {s}.rawTag({d}, ", .{ ctx.wire_alias, f.number });
            try writeCodecExpr(ctx, w, rt, utf8);
            try w.print(".wire_type) => if (comptime @hasField(Target, \"{s}\")) {{\n", .{o_zname});
            try writeIndent(w, indent + 1);
            try w.writeAll("self.");
            try writeIdent(w, o_zname);
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
    parent_ctx: GenCtx,
    svc: ast.Service,
    pkg_scope: []const u8,
    w: *std.Io.Writer,
) !void {
    var ctx = parent_ctx;
    ctx.svc_name = svc.name;
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
        try ctx.writeSymPath(w, req_rt.message);
        try w.writeAll(";\n");
        try w.writeAll("        pub const Response = ");
        try ctx.writeSymPath(w, res_rt.message);
        try w.writeAll(";\n");
        try w.print("        pub const client_streaming: bool = {};\n", .{rpc.req_stream});
        try w.print("        pub const server_streaming: bool = {};\n", .{rpc.res_stream});
        try w.print("        pub const stream_kind: {s}.rpc.StreamKind = {s};\n", .{ ctx.wire_alias, streamKindExpr(rpc.req_stream, rpc.res_stream) });
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

    try w.writeAll("    pub const method_infos: []const ");
    try w.print("{s}.rpc.MethodInfo = &.{{\n", .{ctx.wire_alias});
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
            try w.print("        if ({s}.rpc.eqlPath(path, \"/{s}/{s}\")) return .", .{ ctx.wire_alias, svc_full_name, rpc.name });
            try writeIdent(w, rpc.name);
            try w.writeAll(";\n");
        }
    }
    try w.writeAll("        return null;\n");
    try w.writeAll("    }\n");
    try w.writeAll("};\n");
}
