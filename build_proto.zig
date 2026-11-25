const std = @import("std");

pub const ProtoModuleOptions = struct {
    proto: std.Build.LazyPath,
    out_name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    preserve_unknown_fields: bool = false,
};

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
    if (opts.preserve_unknown_fields) {
        gen.addArg("--preserve-unknown-fields");
    }
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
    if (opts.preserve_unknown_fields) {
        gen.addArg("--preserve-unknown-fields");
    }
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
