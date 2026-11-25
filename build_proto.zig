const std = @import("std");

pub const ProtoModuleOptions = struct {
    proto: std.Build.LazyPath,
    out_name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub const ProtoArtifact = struct {
    module: *std.Build.Module,
    generated_file: std.Build.LazyPath,
};

pub fn addProtoModule(
    b: *std.Build,
    protoc_exe: *std.Build.Step.Compile,
    wire_mod: *std.Build.Module,
    opts: ProtoModuleOptions,
) ProtoArtifact {
    const gen = b.addRunArtifact(protoc_exe);
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
    include_dirs: []const std.Build.LazyPath,
    entry_protos: []const std.Build.LazyPath,
    out_dir_name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub const ProtoPackageArtifact = struct {
    module: *std.Build.Module,
    generated_dir: std.Build.LazyPath,
};

/// Multi-file hermetic codegen: generates all imported .pb.zig files + root.zig into one
/// output directory and tracks transitive .proto imports via a Make depfile.
pub fn addProtoPackage(
    b: *std.Build,
    protoc_exe: *std.Build.Step.Compile,
    wire_mod: *std.Build.Module,
    opts: ProtoPackageOptions,
) ProtoPackageArtifact {
    const gen = b.addRunArtifact(protoc_exe);
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
