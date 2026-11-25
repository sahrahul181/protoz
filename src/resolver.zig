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

    /// Official Protobuf scope-walk type resolution across all loaded files.
    pub fn resolveType(self: *const Resolver, current_scope: []const u8, type_name: []const u8) !ResolvedType {
        if (lookupScalar(type_name)) |s| return .{ .scalar = s };

        if (type_name.len > 0 and type_name[0] == '.') {
            if (self.symbols.get(type_name[1..])) |sym| {
                return if (sym.kind == .@"enum") .{ .@"enum" = sym } else .{ .message = sym };
            }
            return error.UnknownType;
        }

        var scope = current_scope;
        while (true) {
            const candidate = if (scope.len == 0)
                type_name
            else
                try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ scope, type_name });

            if (self.symbols.get(candidate)) |sym| {
                return if (sym.kind == .@"enum") .{ .@"enum" = sym } else .{ .message = sym };
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
        for (f.options) |opt| {
            if (std.mem.eql(u8, opt.name, "packed")) {
                return std.mem.eql(u8, opt.raw_value, "true");
            }
        }
        return self.files[file_idx].syntax != .proto2;
    }

    pub fn hasExplicitPresence(self: *const Resolver, file_idx: usize, f: ast.Field, rt: ResolvedType) bool {
        if (rt == .message) return true;
        if (f.label == .optional or f.label == .required) return true;
        return self.files[file_idx].syntax == .proto2;
    }

    /// Detects both intra-file and cross-file value cycles.
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
