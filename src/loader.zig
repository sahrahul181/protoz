const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");

pub const LoadedWorkspace = struct {
    files: []ast.File,
    disk_paths: [][]const u8,
};

const VisitState = enum { loading, done };

pub const Loader = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    include_dirs: []const []const u8,
    visited: std.StringHashMapUnmanaged(VisitState) = .empty,
    files: std.ArrayList(ast.File) = .empty,
    disk_paths: std.ArrayList([]const u8) = .empty,

    pub fn load(
        arena: std.mem.Allocator,
        io: std.Io,
        include_dirs: []const []const u8,
        entry_files: []const []const u8,
    ) !LoadedWorkspace {
        var loader = Loader{
            .arena = arena,
            .io = io,
            .include_dirs = include_dirs,
        };
        for (entry_files) |entry| {
            const norm = try normalizeProtoName(arena, include_dirs, entry);
            try loader.loadRecursive(norm.logical_name, norm.disk_path);
        }
        return .{
            .files = try loader.files.toOwnedSlice(arena),
            .disk_paths = try loader.disk_paths.toOwnedSlice(arena),
        };
    }

    const Normalized = struct {
        logical_name: []const u8,
        disk_path: []const u8,
    };

    fn normalizeSlashes(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
        const dup = try arena.dupe(u8, path);
        for (dup) |*c| {
            if (c.* == '\\') c.* = '/';
        }
        return std.mem.trimEnd(u8, dup, "/");
    }

    fn normalizeProtoName(
        arena: std.mem.Allocator,
        include_dirs: []const []const u8,
        raw_entry: []const u8,
    ) !Normalized {
        const clean = try normalizeSlashes(arena, raw_entry);
        // If the entry path starts with one of the -I directories, strip it to obtain the canonical logical import name.
        for (include_dirs) |dir| {
            const clean_dir = try normalizeSlashes(arena, dir);
            if (clean_dir.len == 0 or std.mem.eql(u8, clean_dir, ".")) continue;
            if (std.mem.startsWith(u8, clean, clean_dir) and
                clean.len > clean_dir.len and
                clean[clean_dir.len] == '/')
            {
                return .{
                    .logical_name = clean[clean_dir.len + 1 ..],
                    .disk_path = clean,
                };
            }
        }
        return .{ .logical_name = clean, .disk_path = clean };
    }

    fn resolveImportDiskPath(self: *Loader, logical_name: []const u8) ![]const u8 {
        const cwd = std.Io.Dir.cwd();
        for (self.include_dirs) |dir| {
            const clean_dir = try normalizeSlashes(self.arena, dir);
            const candidate = if (clean_dir.len == 0 or std.mem.eql(u8, clean_dir, "."))
                logical_name
            else
                try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ clean_dir, logical_name });

            if (cwd.openFile(self.io, candidate, .{})) |f| {
                f.close(self.io);
                return candidate;
            } else |_| {}
        }
        // Fallback: try directly relative to cwd
        if (cwd.openFile(self.io, logical_name, .{})) |f| {
            f.close(self.io);
            return logical_name;
        } else |_| {}
        return error.ImportNotFound;
    }

    fn loadRecursive(self: *Loader, logical_name: []const u8, explicit_disk_path: ?[]const u8) !void {
        if (self.visited.get(logical_name)) |state| {
            return switch (state) {
                .loading => error.CircularImport,
                .done => {},
            };
        }
        try self.visited.put(self.arena, logical_name, .loading);

        const disk_path = explicit_disk_path orelse try self.resolveImportDiskPath(logical_name);
        const src = try std.Io.Dir.cwd().readFileAlloc(self.io, disk_path, self.arena, .limited(16 << 20));

        var parsed = try parser.Parser.parse(self.arena, src);
        parsed.name = logical_name;

        // Depth-first: load imports before registering dependents
        for (parsed.imports) |imp| {
            const clean_imp = try normalizeSlashes(self.arena, imp);
            try self.loadRecursive(clean_imp, null);
        }

        try self.visited.put(self.arena, logical_name, .done);
        try self.files.append(self.arena, parsed);
        try self.disk_paths.append(self.arena, disk_path);
    }
};
