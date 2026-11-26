const std = @import("std");

pub const CodegenFlags = struct {
    preserve_unknown_fields: bool = false,
    minimal: bool = false,
    emit_json: ?bool = null,
    emit_field_iterator: ?bool = null,
    emit_helpers: ?bool = null,
    emit_decode_only: ?bool = null,
    emit_forward_encode: ?bool = null,
    emit_validate: ?bool = null,
    only_roots: []const []const u8 = &.{},
};

pub const ProtoModuleOptions = struct {
    proto: std.Build.LazyPath,
    out_name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    preserve_unknown_fields: bool = false,
    minimal: bool = false,
    emit_json: ?bool = null,
    emit_field_iterator: ?bool = null,
    emit_helpers: ?bool = null,
    emit_decode_only: ?bool = null,
    emit_forward_encode: ?bool = null,
    emit_validate: ?bool = null,
    only_roots: []const []const u8 = &.{},
};

fn appendCodegenFlags(gen: *std.Build.Step.Run, f: CodegenFlags) void {
    if (f.preserve_unknown_fields) gen.addArg("--preserve-unknown-fields");
    if (f.minimal) gen.addArg("--minimal");
    if (f.emit_json) |v| gen.addArg(if (v) "--emit-json" else "--no-json");
    if (f.emit_field_iterator) |v| gen.addArg(if (v) "--emit-iter" else "--no-iter");
    if (f.emit_helpers) |v| gen.addArg(if (v) "--emit-helpers" else "--no-helpers");
    if (f.emit_decode_only) |v| gen.addArg(if (v) "--emit-decode-only" else "--no-decode-only");
    if (f.emit_forward_encode) |v| gen.addArg(if (v) "--emit-forward-encode" else "--no-forward-encode");
    if (f.emit_validate) |v| gen.addArg(if (v) "--emit-validate" else "--no-validate");
    for (f.only_roots) |root| {
        gen.addArg("--only");
        gen.addArg(root);
    }
}

fn codegenFlagsFrom(opts: anytype) CodegenFlags {
    return .{
        .preserve_unknown_fields = opts.preserve_unknown_fields,
        .minimal = opts.minimal,
        .emit_json = opts.emit_json,
        .emit_field_iterator = opts.emit_field_iterator,
        .emit_helpers = opts.emit_helpers,
        .emit_decode_only = opts.emit_decode_only,
        .emit_forward_encode = opts.emit_forward_encode,
        .emit_validate = opts.emit_validate,
        .only_roots = opts.only_roots,
    };
}

pub const ProtoArtifact = struct {
    module: *std.Build.Module,
    generated_file: std.Build.LazyPath,
};

/// Compiles a standalone `.proto` file (with no `import` statements) using a `protoz` dependency.
pub fn addProtoModule(
    b: *std.Build,
    protoz_dep: *std.Build.Dependency,
    opts: ProtoModuleOptions,
) ProtoArtifact {
    return addProtoModuleWith(
        b,
        protoz_dep.artifact("zig-protoc"),
        protoz_dep.module("proto_wire"),
        opts,
    );
}

pub fn addProtoModuleWith(
    b: *std.Build,
    protoc_exe: *std.Build.Step.Compile,
    wire_mod: *std.Build.Module,
    opts: ProtoModuleOptions,
) ProtoArtifact {
    const gen = b.addRunArtifact(protoc_exe);
    appendCodegenFlags(gen, codegenFlagsFrom(opts));
    gen.addArg("--out");
    const gen_file = gen.addOutputFileArg(opts.out_name);
    gen.addFileArg(opts.proto);

    const mod = b.createModule(.{
        .root_source_file = gen_file,
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "proto_wire", .module = wire_mod },
        },
    });
    return .{ .module = mod, .generated_file = gen_file };
}

pub const ProtoPackageOptions = struct {
    include_dirs: []const std.Build.LazyPath = &.{},
    entry_protos: []const std.Build.LazyPath,
    out_dir_name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Automatically appends protoz's bundled `include/` (google/protobuf/*.proto) as a fallback `-I` path.
    include_well_known_types: bool = true,
    preserve_unknown_fields: bool = false,
    minimal: bool = false,
    emit_json: ?bool = null,
    emit_field_iterator: ?bool = null,
    emit_helpers: ?bool = null,
    emit_decode_only: ?bool = null,
    emit_forward_encode: ?bool = null,
    emit_validate: ?bool = null,
    only_roots: []const []const u8 = &.{},
};

pub const ProtoPackageArtifact = struct {
    module: *std.Build.Module,
    generated_dir: std.Build.LazyPath,
};

/// Multi-file hermetic codegen using a `protoz` dependency.
/// Automatically wires `zig-protoc`, `proto_wire`, bundled Well-Known Types, and Make `.d` depfiles.
pub fn addProtoPackage(
    b: *std.Build,
    protoz_dep: *std.Build.Dependency,
    opts: ProtoPackageOptions,
) ProtoPackageArtifact {
    return addProtoPackageWith(
        b,
        protoz_dep.artifact("zig-protoc"),
        protoz_dep.module("proto_wire"),
        if (opts.include_well_known_types) protoz_dep.path("include") else null,
        opts,
    );
}

pub fn addProtoPackageWith(
    b: *std.Build,
    protoc_exe: *std.Build.Step.Compile,
    wire_mod: *std.Build.Module,
    wkt_include_dir: ?std.Build.LazyPath,
    opts: ProtoPackageOptions,
) ProtoPackageArtifact {
    const gen = b.addRunArtifact(protoc_exe);
    appendCodegenFlags(gen, codegenFlagsFrom(opts));
    gen.addArg("--out-dir");
    const out_dir = gen.addOutputDirectoryArg2(opts.out_dir_name, .{});
    gen.addArg("--root-file");
    gen.addArg("root.zig");
    gen.addArg("--depfile");
    _ = gen.addDepFileOutputArg2("proto.d", .{});

    for (opts.include_dirs) |inc| {
        gen.addArg("-I");
        gen.addDirectoryArg2(inc, .{});
    }
    if (wkt_include_dir) |wkt| {
        gen.addArg("-I");
        gen.addDirectoryArg2(wkt, .{});
    }
    for (opts.entry_protos) |entry| {
        gen.addFileArg(entry);
    }

    const mod = b.createModule(.{
        .root_source_file = out_dir.path(b, "root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "proto_wire", .module = wire_mod },
        },
    });
    return .{ .module = mod, .generated_dir = out_dir };
}
