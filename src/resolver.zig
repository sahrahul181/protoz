const std = @import("std");
const ast = @import("ast.zig");

pub const SymbolKind = enum { message, @"enum" };

pub const Symbol = struct {
    kind: SymbolKind,
    file_index: usize,
    proto_fqn: []const u8,
    zig_path: []const u8,
    msg: ?*const ast.Message = null,
};

pub const ScalarInfo = struct {
    wire_kind: []const u8,
    zig_type: []const u8,
    default_expr: []const u8,
    packable: bool,
};

pub const ResolvedType = union(enum) {
    scalar: ScalarInfo,
    @"enum": Symbol,
    message: Symbol,
};

pub fn lookupScalar(name: []const u8) ?ScalarInfo {
    const map = std.StaticStringMap(ScalarInfo).initComptime(.{
        .{ "int32", ScalarInfo{ .wire_kind = ".int32", .zig_type = "i32", .default_expr = "0", .packable = true } },
        .{ "int64", ScalarInfo{ .wire_kind = ".int64", .zig_type = "i64", .default_expr = "0", .packable = true } },
        .{ "uint32", ScalarInfo{ .wire_kind = ".uint32", .zig_type = "u32", .default_expr = "0", .packable = true } },
        .{ "uint64", ScalarInfo{ .wire_kind = ".uint64", .zig_type = "u64", .default_expr = "0", .packable = true } },
        .{ "sint32", ScalarInfo{ .wire_kind = ".sint32", .zig_type = "i32", .default_expr = "0", .packable = true } },
        .{ "sint64", ScalarInfo{ .wire_kind = ".sint64", .zig_type = "i64", .default_expr = "0", .packable = true } },
        .{ "bool", ScalarInfo{ .wire_kind = ".bool_", .zig_type = "bool", .default_expr = "false", .packable = true } },
        .{ "fixed32", ScalarInfo{ .wire_kind = ".fixed32", .zig_type = "u32", .default_expr = "0", .packable = true } },
        .{ "sfixed32", ScalarInfo{ .wire_kind = ".sfixed32", .zig_type = "i32", .default_expr = "0", .packable = true } },
        .{ "float", ScalarInfo{ .wire_kind = ".float_", .zig_type = "f32", .default_expr = "0.0", .packable = true } },
        .{ "fixed64", ScalarInfo{ .wire_kind = ".fixed64", .zig_type = "u64", .default_expr = "0", .packable = true } },
        .{ "sfixed64", ScalarInfo{ .wire_kind = ".sfixed64", .zig_type = "i64", .default_expr = "0", .packable = true } },
        .{ "double", ScalarInfo{ .wire_kind = ".double_", .zig_type = "f64", .default_expr = "0.0", .packable = true } },
        .{ "string", ScalarInfo{ .wire_kind = ".string", .zig_type = "[]const u8", .default_expr = "\"\"", .packable = false } },
        .{ "bytes", ScalarInfo{ .wire_kind = ".bytes", .zig_type = "[]const u8", .default_expr = "\"\"", .packable = false } },
    });
    return map.get(name);
}

fn isValidMapKeyType(name: []const u8) bool {
    const allowed = std.StaticStringMap(void).initComptime(.{
        .{ "int32", {} },    .{ "int64", {} },    .{ "uint32", {} },  .{ "uint64", {} },
        .{ "sint32", {} },   .{ "sint64", {} },   .{ "fixed32", {} }, .{ "fixed64", {} },
        .{ "sfixed32", {} }, .{ "sfixed64", {} }, .{ "bool", {} },    .{ "string", {} },
    });
    return allowed.has(name);
}

fn findOption(opts: []const ast.Option, name: []const u8) ?[]const u8 {
    for (opts) |opt| {
        if (std.mem.eql(u8, opt.name, name)) return opt.raw_value;
    }
    return null;
}

pub const Resolver = struct {
    arena: std.mem.Allocator,
    files: []const ast.File,
    symbols: std.StringHashMapUnmanaged(Symbol) = .empty,

    /// Backward-compatible single-file entry point.
    pub fn build(arena: std.mem.Allocator, file: *const ast.File) !Resolver {
        return buildMulti(arena, file[0..1]);
    }

    pub fn buildMulti(arena: std.mem.Allocator, files: []const ast.File) !Resolver {
        var r = Resolver{
            .arena = arena,
            .files = files,
        };
        for (files, 0..) |*file, file_idx| {
            const pkg_prefix = file.package orelse "";
            for (file.enums) |*e| {
                try r.registerEnum(file_idx, pkg_prefix, "", e);
            }
            for (file.messages) |*m| {
                try r.registerMessage(file_idx, pkg_prefix, "", m);
            }
        }
        try r.validate();
        return r;
    }

    fn joinDot(self: *Resolver, a: []const u8, b: []const u8) ![]const u8 {
        if (a.len == 0) return b;
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ a, b });
    }

    fn registerEnum(
        self: *Resolver,
        file_idx: usize,
        proto_scope: []const u8,
        zig_scope: []const u8,
        e: *const ast.Enum,
    ) !void {
        const fqn = try self.joinDot(proto_scope, e.name);
        const zig_path = try self.joinDot(zig_scope, e.name);
        try self.symbols.put(self.arena, fqn, .{
            .kind = .@"enum",
            .file_index = file_idx,
            .proto_fqn = fqn,
            .zig_path = zig_path,
        });
    }

    fn registerMessage(
        self: *Resolver,
        file_idx: usize,
        proto_scope: []const u8,
        zig_scope: []const u8,
        m: *const ast.Message,
    ) !void {
        const fqn = try self.joinDot(proto_scope, m.name);
        const zig_path = try self.joinDot(zig_scope, m.name);
        try self.symbols.put(self.arena, fqn, .{
            .kind = .message,
            .file_index = file_idx,
            .proto_fqn = fqn,
            .zig_path = zig_path,
            .msg = m,
        });
        for (m.nested_enums) |*ne| try self.registerEnum(file_idx, fqn, zig_path, ne);
        for (m.nested_messages) |*nm| try self.registerMessage(file_idx, fqn, zig_path, nm);
    }

    pub fn validate(self: *const Resolver) !void {
        for (self.files) |file| {
            const pkg_prefix = file.package orelse "";
            for (file.enums) |e| try self.validateEnum(file.syntax, e);
            for (file.messages) |m| {
                const fqn = if (pkg_prefix.len == 0)
                    m.name
                else
                    try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ pkg_prefix, m.name });
                try self.validateMessage(file.syntax, m, fqn);
            }
        }
    }

    fn validateEnum(self: *const Resolver, syntax: ast.Syntax, e: ast.Enum) !void {
        if (syntax == .proto3 and (e.values.len == 0 or e.values[0].number != 0)) {
            return error.Proto3EnumRequiresZeroFirst;
        }
        if (!e.allow_alias) {
            var seen: std.AutoHashMapUnmanaged(i32, void) = .empty;
            for (e.values) |v| {
                if (seen.contains(v.number)) return error.DuplicateEnumValue;
                try seen.put(self.arena, v.number, {});
            }
        }
    }

    fn validateFieldMeta(
        self: *const Resolver,
        m: ast.Message,
        number: u29,
        name: []const u8,
        used_numbers: *std.AutoHashMapUnmanaged(u29, void),
        used_names: *std.StringHashMapUnmanaged(void),
    ) !void {
        if (number == 0 or number > 536_870_911 or (number >= 19000 and number <= 19999)) {
            return error.InvalidFieldNumber;
        }
        const num_i32: i32 = @intCast(number);
        for (m.reserved_ranges) |rr| {
            if (num_i32 >= rr.start and num_i32 <= rr.end) return error.ReservedFieldNumber;
        }
        for (m.reserved_names) |rn| {
            if (std.mem.eql(u8, rn, name)) return error.ReservedFieldName;
        }
        if (used_numbers.contains(number)) return error.DuplicateFieldNumber;
        try used_numbers.put(self.arena, number, {});
        if (used_names.contains(name)) return error.DuplicateFieldName;
        try used_names.put(self.arena, name, {});
    }

    fn validateMessage(self: *const Resolver, syntax: ast.Syntax, m: ast.Message, scope_fqn: []const u8) !void {
        for (m.nested_enums) |ne| try self.validateEnum(syntax, ne);
        for (m.nested_messages) |nm| {
            const child_fqn = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ scope_fqn, nm.name });
            try self.validateMessage(syntax, nm, child_fqn);
        }

        var used_numbers: std.AutoHashMapUnmanaged(u29, void) = .empty;
        var used_names: std.StringHashMapUnmanaged(void) = .empty;

        for (m.fields) |f| {
            try self.validateFieldMeta(m, f.number, f.name, &used_numbers, &used_names);
            _ = try self.resolveType(scope_fqn, f.type_name);
        }
        for (m.maps) |mp| {
            if (!isValidMapKeyType(mp.key_type)) return error.InvalidMapKeyType;
            try self.validateFieldMeta(m, mp.number, mp.name, &used_numbers, &used_names);
            _ = try self.resolveType(scope_fqn, mp.value_type);
        }
        for (m.oneofs) |o| {
            if (used_names.contains(o.name)) return error.DuplicateFieldName;
            try used_names.put(self.arena, o.name, {});
            for (o.fields) |f| {
                try self.validateFieldMeta(m, f.number, f.name, &used_numbers, &used_names);
                _ = try self.resolveType(scope_fqn, f.type_name);
            }
        }
    }

    /// Official Protobuf scope-walk type resolution with innermost-first-component shadowing.
    pub fn resolveType(self: *const Resolver, current_scope: []const u8, type_name: []const u8) !ResolvedType {
        if (lookupScalar(type_name)) |s| return .{ .scalar = s };

        if (type_name.len > 0 and type_name[0] == '.') {
            if (self.symbols.get(type_name[1..])) |sym| {
                return if (sym.kind == .@"enum") .{ .@"enum" = sym } else .{ .message = sym };
            }
            return error.UnknownType;
        }

        const first_comp = if (std.mem.indexOfScalar(u8, type_name, '.')) |dot|
            type_name[0..dot]
        else
            type_name;

        var scope = current_scope;
        while (true) {
            const first_candidate = if (scope.len == 0)
                first_comp
            else
                try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ scope, first_comp });

            // Innermost shadowing: if the first component matches a symbol in this scope,
            // resolution MUST stay anchored here and not fall through to an outer scope.
            if (self.symbols.get(first_candidate)) |first_sym| {
                if (first_comp.len == type_name.len) {
                    return if (first_sym.kind == .@"enum") .{ .@"enum" = first_sym } else .{ .message = first_sym };
                }
                const full_candidate = if (scope.len == 0)
                    type_name
                else
                    try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ scope, type_name });
                if (self.symbols.get(full_candidate)) |sym| {
                    return if (sym.kind == .@"enum") .{ .@"enum" = sym } else .{ .message = sym };
                }
                return error.UnknownType;
            }

            if (first_comp.len < type_name.len) {
                const candidate = if (scope.len == 0)
                    type_name
                else
                    try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ scope, type_name });

                if (self.symbols.get(candidate)) |sym| {
                    return if (sym.kind == .@"enum") .{ .@"enum" = sym } else .{ .message = sym };
                }
            }

            if (scope.len == 0) break;
            if (std.mem.lastIndexOfScalar(u8, scope, '.')) |dot| {
                scope = scope[0..dot];
            } else {
                scope = "";
            }
        }
        return error.UnknownType;
    }

    pub fn isPacked(self: *const Resolver, file_idx: usize, f: ast.Field) bool {
        if (findOption(f.options, "packed")) |v| {
            return std.mem.eql(u8, v, "true");
        }
        if (findOption(f.options, "features.repeated_field_encoding") orelse
            findOption(self.files[file_idx].options, "features.repeated_field_encoding")) |enc|
        {
            if (std.mem.eql(u8, enc, "EXPANDED")) return false;
            if (std.mem.eql(u8, enc, "PACKED")) return true;
        }
        return self.files[file_idx].syntax != .proto2;
    }

    pub fn hasExplicitPresence(self: *const Resolver, file_idx: usize, f: ast.Field, rt: ResolvedType) bool {
        if (rt == .message) return true;
        if (f.label == .optional or f.label == .required) return true;
        if (findOption(f.options, "features.field_presence") orelse
            findOption(self.files[file_idx].options, "features.field_presence")) |pres|
        {
            if (std.mem.eql(u8, pres, "IMPLICIT")) return false;
            if (std.mem.eql(u8, pres, "EXPLICIT") or std.mem.eql(u8, pres, "LEGACY_REQUIRED")) return true;
        }
        return self.files[file_idx].syntax != .proto3;
    }

    pub fn validatesUtf8(self: *const Resolver, file_idx: usize, field_opts: []const ast.Option) bool {
        if (findOption(field_opts, "features.utf8_validation") orelse
            findOption(self.files[file_idx].options, "features.utf8_validation")) |mode|
        {
            if (std.mem.eql(u8, mode, "NONE")) return false;
            if (std.mem.eql(u8, mode, "VERIFY")) return true;
        }
        return self.files[file_idx].syntax != .proto2;
    }

    pub fn createsCycle(self: *const Resolver, owner_fqn: []const u8, target_fqn: []const u8) !bool {
        var visited: std.StringHashMapUnmanaged(void) = .empty;
        return self.canReach(target_fqn, owner_fqn, &visited);
    }

    fn canReach(
        self: *const Resolver,
        cur_fqn: []const u8,
        goal_fqn: []const u8,
        visited: *std.StringHashMapUnmanaged(void),
    ) !bool {
        if (std.mem.eql(u8, cur_fqn, goal_fqn)) return true;
        if (visited.contains(cur_fqn)) return false;
        try visited.put(self.arena, cur_fqn, {});

        const sym = self.symbols.get(cur_fqn) orelse return false;
        const msg = sym.msg orelse return false;

        for (msg.fields) |f| {
            if (f.label == .repeated) continue;
            const rt = self.resolveType(cur_fqn, f.type_name) catch continue;
            if (rt == .message) {
                if (try self.canReach(rt.message.proto_fqn, goal_fqn, visited)) return true;
            }
        }
        for (msg.oneofs) |o| {
            for (o.fields) |f| {
                const rt = self.resolveType(cur_fqn, f.type_name) catch continue;
                if (rt == .message) {
                    if (try self.canReach(rt.message.proto_fqn, goal_fqn, visited)) return true;
                }
            }
        }
        return false;
    }
};
