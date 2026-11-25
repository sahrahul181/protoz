const std = @import("std");

// Re-export proto compilation helpers for consumers of this build file
pub const proto = @import("build_proto.zig");
pub const addProtoModule = proto.addProtoModule;
pub const addProtoPackage = proto.addProtoPackage;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Zero-allocation runtime module
    _ = b.addModule("proto_wire", .{
        .root_source_file = b.path("src/wire.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 2. Standalone protobuf compiler (zig-protoc)
    const protoc_exe = b.addExecutable(.{
        .name = "zig-protoc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protoc_main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    b.installArtifact(protoc_exe);

    // 3. Official protoc plugin binary (protoc-gen-zig)
    const host_wire_mod = b.createModule(.{
        .root_source_file = b.path("src/wire.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const protoc_plugin_exe = b.addExecutable(.{
        .name = "protoc-gen-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protoc_gen_zig_main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto_wire", .module = host_wire_mod },
            },
        }),
    });
    b.installArtifact(protoc_plugin_exe);
}
