const std = @import("std");
const loader = @import("loader.zig");
const resolver = @import("resolver.zig");
const codegen = @import("codegen.zig");

fn parentDir(path: []const u8) ?[]const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        if (idx > 0) return path[0..idx];
    }
    return null;
}

fn writeRootExportName(w: *std.Io.Writer, proto_name: []const u8) !void {
    const stem = if (std.mem.endsWith(u8, proto_name, ".proto"))
        proto_name[0 .. proto_name.len - ".proto".len]
    else
        proto_name;
    for (stem) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            try w.writeByte(ch);
        } else {
            try w.writeByte('_');
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var include_dirs: std.ArrayList([]const u8) = .empty;
    var entry_files: std.ArrayList([]const u8) = .empty;
    var output_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var root_file_name: ?[]const u8 = null;
    var depfile_path: ?[]const u8 = null;

    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next(); // argv[0]
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out")) {
            output_path = args.next() orelse return error.MissingOutputPath;
        } else if (std.mem.eql(u8, arg, "--out-dir")) {
            out_dir = args.next() orelse return error.MissingOutputDir;
        } else if (std.mem.eql(u8, arg, "--root-file")) {
            root_file_name = args.next() orelse return error.MissingRootFileName;
        } else if (std.mem.eql(u8, arg, "--depfile")) {
            depfile_path = args.next() orelse return error.MissingDepfilePath;
        } else if (std.mem.eql(u8, arg, "-I") or std.mem.eql(u8, arg, "--proto-path")) {
            try include_dirs.append(arena, args.next() orelse return error.MissingIncludeDir);
        } else if (std.mem.startsWith(u8, arg, "-I")) {
            try include_dirs.append(arena, arg[2..]);
        } else {
            try entry_files.append(arena, arg);
        }
    }

    if (entry_files.items.len == 0) return error.MissingInputPath;

    const ws = try loader.Loader.load(arena, init.io, include_dirs.items, entry_files.items);
    const res = try resolver.Resolver.buildMulti(arena, ws.files);
    const cwd = std.Io.Dir.cwd();

    if (out_dir) |dir_path| {
        try cwd.createDirPath(init.io, dir_path);
        var buf: [8192]u8 = undefined;

        for (ws.files, 0..) |file, idx| {
            const rel_zig = try codegen.protoToZigRelPath(arena, file.name);
            const full_out = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, rel_zig });
            if (parentDir(full_out)) |pdir| try cwd.createDirPath(init.io, pdir);

            const out_file = try cwd.createFile(init.io, full_out, .{});
            defer out_file.close(init.io);
            var writer = out_file.writerStreaming(init.io, &buf);
            try codegen.generateFile(arena, idx, &res, &writer.interface);
            try writer.interface.flush();
        }

        // Emit package root barrel so Zig's module root covers all relative cross-file @imports.
        const root_rel = root_file_name orelse "root.zig";
        const root_full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, root_rel });
        {
            const rf = try cwd.createFile(init.io, root_full, .{});
            defer rf.close(init.io);
            var rw = rf.writerStreaming(init.io, &buf);
            try rw.interface.writeAll("// Auto-generated package root by zig-protoc.\n");
            for (ws.files) |file| {
                const rel_zig = try codegen.protoToZigRelPath(arena, file.name);
                try rw.interface.writeAll("pub const ");
                try writeRootExportName(&rw.interface, file.name);
                try rw.interface.print(" = @import(\"{s}\");\n", .{rel_zig});
            }
            try rw.interface.flush();
        }

        // Emit Make-format depfile so `zig build` tracks all transitively imported .proto files.
        if (depfile_path) |dp| {
            const df = try cwd.createFile(init.io, dp, .{});
            defer df.close(init.io);
            var dw = df.writerStreaming(init.io, &buf);
            try dw.interface.print("{s}:", .{root_full});
            for (ws.disk_paths) |p| try dw.interface.print(" {s}", .{p});
            try dw.interface.writeAll("\n");
            try dw.interface.flush();
        }
        return;
    }

    // Legacy single-file mode (last loaded file is the entry file after depth-first imports)
    const target_idx = ws.files.len - 1;
    var buf: [8192]u8 = undefined;
    if (output_path) |out_path| {
        const out_file = try cwd.createFile(init.io, out_path, .{});
        defer out_file.close(init.io);
        var writer = out_file.writerStreaming(init.io, &buf);
        try codegen.generateFile(arena, target_idx, &res, &writer.interface);
        try writer.interface.flush();
    } else {
        var writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
        try codegen.generateFile(arena, target_idx, &res, &writer.interface);
        try writer.interface.flush();
    }
}
