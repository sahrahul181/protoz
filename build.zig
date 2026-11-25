const std = @import("std");

// Re-export proto compilation helpers for consumers of this package (`const protoz = @import("protoz");`)
pub const proto = @import("build_proto.zig");
pub const addProtoModule = proto.addProtoModule;
pub const addProtoModuleWith = proto.addProtoModuleWith;
pub const addProtoPackage = proto.addProtoPackage;
pub const addProtoPackageWith = proto.addProtoPackageWith;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Zero-allocation runtime module
    const wire_mod = b.addModule("proto_wire", .{
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

    // 4. Pre-wired Google Well-Known Types module (`proto_wkt`) + `zig build test` smoke check
    const wkt_pkg = addProtoPackageWith(b, protoc_exe, wire_mod, b.path("include"), .{
        .entry_protos = &.{
            b.path("include/google/protobuf/any.proto"),
            b.path("include/google/protobuf/duration.proto"),
            b.path("include/google/protobuf/empty.proto"),
            b.path("include/google/protobuf/field_mask.proto"),
            b.path("include/google/protobuf/struct.proto"),
            b.path("include/google/protobuf/timestamp.proto"),
            b.path("include/google/protobuf/wrappers.proto"),
        },
        .out_dir_name = "proto_wkt",
        .target = target,
        .optimize = optimize,
    });
    b.modules.put(b.allocator, "proto_wkt", wkt_pkg.module) catch @panic("OOM");

    const wf = b.addWriteFiles();
    const wkt_smoke = wf.add("wkt_smoke_test.zig",
        \\const std = @import("std");
        \\const wkt = @import("proto_wkt");
        \\
        \\test "bundled Google Well-Known Types compile and round-trip" {
        \\    std.testing.refAllDecls(wkt);
        \\    const ts = wkt.google_protobuf_timestamp.Timestamp{ .seconds = 1764075000, .nanos = 123_456_789 };
        \\    var buf: [64]u8 = undefined;
        \\    const wire_bytes = try ts.encodeSlice(&buf);
        \\    const decoded = try wkt.google_protobuf_timestamp.Timestamp.decode(wire_bytes);
        \\    try std.testing.expectEqual(@as(i64, 1764075000), decoded.seconds);
        \\    try std.testing.expectEqual(@as(i32, 123_456_789), decoded.nanos);
        \\}
        \\
    );

    const wkt_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = wkt_smoke,
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto_wire", .module = wire_mod },
                .{ .name = "proto_wkt", .module = wkt_pkg.module },
            },
        }),
    });
    const test_step = b.step("test", "Run protoz tests and Google Well-Known Types verification");
    test_step.dependOn(&b.addRunArtifact(wkt_test).step);

    // 5. Zero-allocation benchmark suite (`zig build bench -Doptimize=ReleaseFast`)
    const bench_pb = addProtoModuleWith(b, protoc_exe, wire_mod, .{
        .proto = b.path("bench/bench.proto"),
        .out_name = "bench.pb.zig",
        .target = target,
        .optimize = optimize,
    });
    const bench_exe = b.addExecutable(.{
        .name = "protoz-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto_wire", .module = wire_mod },
                .{ .name = "bench_pb", .module = bench_pb.module },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addPassthruArgs();
    b.step("bench", "Run zero-allocation protobuf benchmarks (pass -Doptimize=ReleaseFast)")
        .dependOn(&run_bench.step);
}
