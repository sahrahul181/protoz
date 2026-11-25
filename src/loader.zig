const std = @import("std");
const builtin = @import("builtin");
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
        var norm_includes: std.ArrayList([]const u8) = .empty;
        for (include_dirs) |dir| {
            try norm_includes.append(arena, try normalizePath(arena, dir));
        }

        var loader = Loader{
            .arena = arena,
            .io = io,
            .include_dirs = try norm_includes.toOwnedSlice(arena),
        };
        for (entry_files) |entry| {
            const norm = try loader.normalizeEntry(entry);
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

    fn isAbsolutePath(path: []const u8) bool {
        if (path.len == 0) return false;
        if (path[0] == '/') return true;
        return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
    }

    fn baseName(path: []const u8) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
        return path;
    }

    /// Normalizes separators to `/`, collapses `.` and `..`, and uppercases Windows drive letters.
    pub fn normalizePath(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
        const tmp = try arena.dupe(u8, raw);
        for (tmp) |*c| {
            if (c.* == '\\') c.* = '/';
        }

        var drive: ?u8 = null;
        var rest: []const u8 = tmp;
        if (rest.len >= 2 and std.ascii.isAlphabetic(rest[0]) and rest[1] == ':') {
            drive = std.ascii.toUpper(rest[0]);
            rest = rest[2..];
        }

        const is_abs = rest.len > 0 and rest[0] == '/';
        var parts: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, rest, '/');
        while (it.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
            if (std.mem.eql(u8, seg, "..")) {
                if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                    _ = parts.pop();
                } else if (!is_abs and drive == null) {
                    try parts.append(arena, "..");
                }
            } else {
                try parts.append(arena, seg);
            }
        }

        var out: std.ArrayList(u8) = .empty;
        if (drive) |d| {
            try out.append(arena, d);
            try out.append(arena, ':');
        }
        if (is_abs) try out.append(arena, '/');
        for (parts.items, 0..) |seg, i| {
            if (i > 0) try out.append(arena, '/');
            try out.appendSlice(arena, seg);
        }
        if (out.items.len == 0) try out.append(arena, '.');
        return out.toOwnedSlice(arena);
    }

    fn hasDirPrefix(path: []const u8, dir: []const u8) bool {
        if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return false;
        if (path.len <= dir.len or path[dir.len] != '/') return false;
        if (builtin.os.tag == .windows) {
            return std.ascii.eqlIgnoreCase(path[0..dir.len], dir);
        }
        return std.mem.eql(u8, path[0..dir.len], dir);
    }

    fn normalizeEntry(self: *const Loader, raw_entry: []const u8) !Normalized {
        const clean = try normalizePath(self.arena, raw_entry);

        // Choose the longest matching -I prefix so nested include roots resolve accurately.
        var best_len: usize = 0;
        for (self.include_dirs) |dir| {
            if (hasDirPrefix(clean, dir) and dir.len > best_len) {
                best_len = dir.len;
            }
        }
        if (best_len > 0) {
            return .{
                .logical_name = clean[best_len + 1 ..],
                .disk_path = clean,
            };
        }

        // If passed as a logical path relative to an -I directory (e.g. `-I proto acme/order.proto`).
        if (!isAbsolutePath(clean)) {
            if (self.tryFindInIncludeDirs(clean)) |disk_path| {
                return .{ .logical_name = clean, .disk_path = disk_path };
            }
            return .{ .logical_name = clean, .disk_path = clean };
        }

        // Absolute entry outside all -I roots: use basename as logical name so output paths stay valid.
        return .{ .logical_name = baseName(clean), .disk_path = clean };
    }

    fn tryFindInIncludeDirs(self: *const Loader, logical_name: []const u8) ?[]const u8 {
        const cwd = std.Io.Dir.cwd();
        for (self.include_dirs) |dir| {
            const candidate = if (dir.len == 0 or std.mem.eql(u8, dir, "."))
                logical_name
            else
                std.fmt.allocPrint(self.arena, "{s}/{s}", .{ dir, logical_name }) catch return null;

            if (cwd.openFile(self.io, candidate, .{})) |f| {
                f.close(self.io);
                return candidate;
            } else |_| {}
        }
        return null;
    }

    fn resolveImportDiskPath(self: *const Loader, logical_name: []const u8) ![]const u8 {
        if (self.tryFindInIncludeDirs(logical_name)) |disk_path| return disk_path;
        const cwd = std.Io.Dir.cwd();
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

        for (parsed.imports) |imp| {
            const clean_imp = try normalizePath(self.arena, imp);
            try self.loadRecursive(clean_imp, null);
        }

        try self.visited.put(self.arena, logical_name, .done);
        try self.files.append(self.arena, parsed);
        try self.disk_paths.append(self.arena, disk_path);
    }
};
