const std = @import("std");
const loader = @import("loader.zig");
const resolver = @import("resolver.zig");
const codegen = @import("codegen.zig");
const diag_mod = @import("diag.zig");

fn parentDir(path: []const u8) ?[]const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        if (idx > 0) return path[0..idx];
    }
    return null;
}

fn makeUniqueRootExportName(
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

/// Writes a path in Make depfile format (forward slashes, escaped spaces/`#`/`$`).
fn writeDepPath(w: *std.Io.Writer, path: []const u8) !void {
    for (path) |ch| {
        switch (ch) {
            '\\' => try w.writeByte('/'),
            ' ' => try w.writeAll("\\ "),
            '#' => try w.writeAll("\\#"),
            '$' => try w.writeAll("$$"),
            else => try w.writeByte(ch),
        }
    }
}

fn appendCommaRoots(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), raw: []const u8) !void {
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len > 0) try list.append(arena, trimmed);
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var include_dirs: std.ArrayList([]const u8) = .empty;
    var entry_files: std.ArrayList([]const u8) = .empty;
    var only_roots: std.ArrayList([]const u8) = .empty;
    var output_path: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var root_file_name: ?[]const u8 = null;
    var depfile_path: ?[]const u8 = null;
    var cg_opts: codegen.CodegenOptions = .{};

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
        } else if (std.mem.eql(u8, arg, "--preserve-unknown-fields")) {
            cg_opts.preserve_unknown_fields = true;
        } else if (std.mem.eql(u8, arg, "--minimal")) {
            cg_opts.emit_json = false;
            cg_opts.emit_field_iterator = false;
            cg_opts.emit_helpers = false;
            cg_opts.emit_decode_only = false;
            cg_opts.emit_forward_encode = false;
            cg_opts.emit_validate = false;
        } else if (std.mem.eql(u8, arg, "--no-json")) {
            cg_opts.emit_json = false;
        } else if (std.mem.eql(u8, arg, "--emit-json")) {
            cg_opts.emit_json = true;
        } else if (std.mem.eql(u8, arg, "--no-iter") or std.mem.eql(u8, arg, "--no-field-iterator")) {
            cg_opts.emit_field_iterator = false;
        } else if (std.mem.eql(u8, arg, "--emit-iter") or std.mem.eql(u8, arg, "--emit-field-iterator")) {
            cg_opts.emit_field_iterator = true;
        } else if (std.mem.eql(u8, arg, "--no-helpers")) {
            cg_opts.emit_helpers = false;
        } else if (std.mem.eql(u8, arg, "--emit-helpers")) {
            cg_opts.emit_helpers = true;
        } else if (std.mem.eql(u8, arg, "--no-decode-only")) {
            cg_opts.emit_decode_only = false;
        } else if (std.mem.eql(u8, arg, "--emit-decode-only")) {
            cg_opts.emit_decode_only = true;
        } else if (std.mem.eql(u8, arg, "--no-forward-encode")) {
            cg_opts.emit_forward_encode = false;
        } else if (std.mem.eql(u8, arg, "--emit-forward-encode")) {
            cg_opts.emit_forward_encode = true;
        } else if (std.mem.eql(u8, arg, "--no-validate")) {
            cg_opts.emit_validate = false;
        } else if (std.mem.eql(u8, arg, "--emit-validate")) {
            cg_opts.emit_validate = true;
        } else if (std.mem.eql(u8, arg, "--only")) {
            const raw = args.next() orelse return error.MissingOnlyRoots;
            try appendCommaRoots(arena, &only_roots, raw);
        } else if (std.mem.startsWith(u8, arg, "--only=")) {
            try appendCommaRoots(arena, &only_roots, arg["--only=".len..]);
        } else if (std.mem.eql(u8, arg, "-I") or std.mem.eql(u8, arg, "--proto-path")) {
            try include_dirs.append(arena, args.next() orelse return error.MissingIncludeDir);
        } else if (std.mem.startsWith(u8, arg, "-I")) {
            try include_dirs.append(arena, arg[2..]);
        } else {
            try entry_files.append(arena, arg);
        }
    }

    if (entry_files.items.len == 0) return error.MissingInputPath;

    var diag: diag_mod.Diagnostic = .{};
    const ws = loader.Loader.loadWithDiag(arena, init.io, include_dirs.items, entry_files.items, &diag) catch |err| {
        var err_buf: [1024]u8 = undefined;
        var stderr_w = std.Io.File.stderr().writerStreaming(init.io, &err_buf);
        if (diag.message.len > 0) {
            try diag.format(&stderr_w.interface);
        } else {
            try stderr_w.interface.print("zig-protoc: error: {s}\n", .{@errorName(err)});
        }
        try stderr_w.interface.flush();
        std.process.exit(1);
    };
    const res = try resolver.Resolver.buildMultiWithDiag(arena, ws.files, &diag);

    var rs_storage: codegen.ReachableSet = undefined;
    if (only_roots.items.len > 0) {
        cg_opts.only_roots = only_roots.items;
        rs_storage = try codegen.computeReachable(arena, &res, only_roots.items);
        cg_opts.reachable = &rs_storage;
    }

    const cwd = std.Io.Dir.cwd();

    if (out_dir) |raw_dir_path| {
        const dir_path = try loader.Loader.normalizePath(arena, raw_dir_path);
        try cwd.createDirPath(init.io, dir_path);
        var buf: [8192]u8 = undefined;
        var emitted_files: std.ArrayList([]const u8) = .empty;

        for (ws.files, 0..) |file, idx| {
            if (cg_opts.reachable) |rs| {
                if (!rs.files.contains(idx)) continue;
            }
            const rel_zig = try codegen.protoToZigRelPath(arena, file.name);
            const full_out = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, rel_zig });
            if (parentDir(full_out)) |pdir| try cwd.createDirPath(init.io, pdir);

            const out_file = try cwd.createFile(init.io, full_out, .{});
            defer out_file.close(init.io);
            var writer = out_file.writerStreaming(init.io, &buf);
            try codegen.generateFileWithOptions(arena, idx, &res, &writer.interface, cg_opts);
            try writer.interface.flush();
            try emitted_files.append(arena, file.name);
        }

        const root_rel = root_file_name orelse "root.zig";
        const root_full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, root_rel });
        {
            const rf = try cwd.createFile(init.io, root_full, .{});
            defer rf.close(init.io);
            var rw = rf.writerStreaming(init.io, &buf);
            var used_exports: std.StringHashMapUnmanaged(void) = .empty;
            try rw.interface.writeAll("// Auto-generated package root by zig-protoc.\n");
            for (emitted_files.items) |file_name| {
                const rel_zig = try codegen.protoToZigRelPath(arena, file_name);
                const export_name = try makeUniqueRootExportName(arena, file_name, &used_exports);
                try rw.interface.writeAll("pub const ");
                try codegen.writeIdent(&rw.interface, export_name);
                try rw.interface.print(" = @import(\"{s}\");\n", .{rel_zig});
            }
            try rw.interface.flush();
        }

        if (depfile_path) |dp| {
            const clean_dp = try loader.Loader.normalizePath(arena, dp);
            if (parentDir(clean_dp)) |pdir| try cwd.createDirPath(init.io, pdir);
            const df = try cwd.createFile(init.io, clean_dp, .{});
            defer df.close(init.io);
            var dw = df.writerStreaming(init.io, &buf);
            try writeDepPath(&dw.interface, root_full);
            try dw.interface.writeByte(':');
            for (ws.disk_paths) |p| {
                try dw.interface.writeByte(' ');
                try writeDepPath(&dw.interface, p);
            }
            try dw.interface.writeByte('\n');
            try dw.interface.flush();
        }
        return;
    }

    const target_idx = ws.files.len - 1;
    var buf: [8192]u8 = undefined;
    if (output_path) |out_path| {
        const clean_out = try loader.Loader.normalizePath(arena, out_path);
        if (parentDir(clean_out)) |pdir| try cwd.createDirPath(init.io, pdir);
        const out_file = try cwd.createFile(init.io, clean_out, .{});
        defer out_file.close(init.io);
        var writer = out_file.writerStreaming(init.io, &buf);
        try codegen.generateFileWithOptions(arena, target_idx, &res, &writer.interface, cg_opts);
        try writer.interface.flush();
    } else {
        var writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
        try codegen.generateFileWithOptions(arena, target_idx, &res, &writer.interface, cg_opts);
        try writer.interface.flush();
    }
}
