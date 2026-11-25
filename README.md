# protoz

A blazing-fast, **zero-allocation** Protocol Buffers (proto3 & proto2) compiler and runtime written in pure Zig.

---

## Highlights

- **Zero Heap Allocations:** Encode, decode, and validate protobuf messages with 0 heap bytes allocated. Strings and byte fields reference the raw wire slice directly; repeated submessages utilize zero-copy lazy wire views.
- **Extreme Throughput:** >80 Million operations/sec per CPU core (~12 ns encode/decode on typical messages) and >1 GB/s wire processing throughput.
- **Single-Pass Reverse Encoding (`ReverseWriter`):** Serializes wire packets in a single backward pass, eliminating the need to pre-compute nested submessage lengths or buffer intermediate data.
- **Standalone or Plugin:**
  - `zig-protoc`: Standalone protobuf compiler CLI (requires no external `protoc` or C++ runtimes).
  - `protoc-gen-zig`: Official plugin for Google's `protoc` or `buf`.
- **First-Class `build.zig` Integration:** Reusable build helpers (`addProtoModule` and `addProtoPackage`) with automatic Make `.d` depfile generation for incremental, hermetic builds.
- **Comprehensive Schema Support:** Proto3 & Proto2 scalar types, packed/unpacked repeated fields, enums (with aliasing), oneofs, maps, nested messages, Well-Known Types (Timestamp, Duration, Struct, Any, Wrappers), and recursive messages.

---

## Table of Contents

- [Building the Tools](#building-the-tools)
- [CLI Usage](#cli-usage)
  - [1. Using the Standalone Compiler (`zig-protoc`)](#1-using-the-standalone-compiler-zig-protoc)
  - [2. Using with Official `protoc` (`protoc-gen-zig`)](#2-using-with-official-protoc-protoc-gen-zig)
- [Zig Build System Integration](#zig-build-system-integration)
  - [Single `.proto` File (`addProtoModule`)](#single-proto-file-addprotomodule)
  - [Multi-File Package with Imports (`addProtoPackage`)](#multi-file-package-with-imports-addprotopackage)
- [Runtime Usage](#runtime-usage)
  - [Encoding](#encoding)
  - [Decoding](#decoding)
  - [Iterating Repeated Fields](#iterating-repeated-fields)
- [Repository Structure](#repository-structure)

---

## Building the Tools

Requires **Zig 0.17+**.

```powershell
# Build both zig-protoc and protoc-gen-zig into zig-out/bin/
zig build -Doptimize=ReleaseFast
```

Artifacts produced:
- `zig-out/bin/zig-protoc.exe`: Standalone compiler CLI
- `zig-out/bin/protoc-gen-zig.exe`: `protoc` plugin

---

## CLI Usage

### 1. Using the Standalone Compiler (`zig-protoc`)

#### Single `.proto` File
Compiles a standalone protobuf file into a `.pb.zig` source file:

```powershell
.\zig-out\bin\zig-protoc.exe --out person.pb.zig person.proto
```

#### Multi-File Package with Imports
When schemas import each other or standard Google Well-Known Types:

```powershell
.\zig-out\bin\zig-protoc.exe `
    -I proto `
    -I include `
    --out-dir generated_pb `
    --root-file root.zig `
    proto/service.proto proto/models/user.proto
```

- `-I <dir>`: Adds directory to schema import search paths.
- `--out-dir <dir>`: Emits generated code preserving subdirectory hierarchies.
- `--root-file <file>`: Emits a barrel file re-exporting all generated modules.

---

### 2. Using with Official `protoc` (`protoc-gen-zig`)

If your project already uses Google's `protoc`:

```powershell
protoc --plugin=protoc-gen-zig=.\zig-out\bin\protoc-gen-zig.exe `
    -I proto `
    -I include `
    --zig_out=generated_pb `
    proto/service.proto
```

---

## Zig Build System Integration

You can integrate protobuf code generation directly and hermetically into your `build.zig` using `build_proto.zig`.

### Single `.proto` File (`addProtoModule`)

```zig
const std = @import("std");
const proto = @import("build_proto.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Runtime wire module
    const wire_mod = b.dependency("protoz", .{}).module("proto_wire");

    // 2. Standalone compiler artifact
    const protoc_exe = b.dependency("protoz", .{}).artifact("zig-protoc");

    // 3. Generate Zig code from proto
    const user_pb = proto.addProtoModule(b, protoc_exe, wire_mod, .{
        .proto = b.path("proto/user.proto"),
        .out_name = "user.pb.zig",
        .target = target,
        .optimize = optimize,
    });

    // 4. Import module into your executable
    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "user_pb", .module = user_pb.module },
            },
        }),
    });
    b.installArtifact(exe);
}
```

---

### Multi-File Package with Imports (`addProtoPackage`)

For projects with cross-importing `.proto` files, `addProtoPackage` automatically tracks transitive schema dependencies using Make `.d` depfiles so only modified schemas trigger recompilation:

```zig
const std = @import("std");
const proto = @import("build_proto.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wire_mod = b.dependency("protoz", .{}).module("proto_wire");
    const protoc_exe = b.dependency("protoz", .{}).artifact("zig-protoc");

    const orders_pkg = proto.addProtoPackage(b, protoc_exe, wire_mod, .{
        .include_dirs = &.{ b.path("proto"), b.path("include") },
        .entry_protos = &.{
            b.path("proto/orders/service.proto"),
            b.path("proto/orders/models.proto"),
        },
        .out_dir_name = "orders_pb",
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "orders-service",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "orders_pb", .module = orders_pkg.module },
            },
        }),
    });
    b.installArtifact(exe);
}
```

---

## Runtime Usage

### Encoding

Generated structs come with default field values conforming to Proto3 semantics.

#### Option A: Single-Pass Backward Serialization (`encodeSlice`)
Fastest, zero-allocation serialization directly into a buffer using `ReverseWriter`:

```zig
const std = @import("std");
const pb = @import("user_pb");

var user = pb.User{
    .id = 1001,
    .name = "Alice",
    .email = "alice@example.com",
};

var buffer: [1024]u8 = undefined;
const wire_bytes = try user.encodeSlice(&buffer);
// `wire_bytes` is a slice within `buffer` containing the exact encoded message.
```

#### Option B: Forward Streaming (`encode`)
Writes sequentially to any writer meeting Zig's writer interface:

```zig
var stream_buf: [1024]u8 = undefined;
var sw = wire.SliceWriter.init(&stream_buf);
try user.encode(&sw);
const written_bytes = sw.buf[0..sw.pos];
```

---

### Decoding

#### Zero-Allocation Struct Decoding (`decode`)
Unpacks protobuf wire bytes directly into your native Zig struct without heap allocations:

```zig
const pb = @import("user_pb");

const user = try pb.User.decode(wire_bytes);

std.debug.print("User ID: {d}, Name: {s}\n", .{ user.id, user.name });
```

#### Fast Wire Validation (`validateDepth`)
Validates that a wire payload is well-formed protobuf (tag numbers, wire types, lengths, recursion limits) without constructing any struct:

```zig
const wire = @import("proto_wire");
try pb.User.validateDepth(wire_bytes, wire.max_recursion_depth);
```

---

### Iterating Repeated Fields

Repeated submessages are decoded into zero-copy `WireFieldView` objects to prevent unnecessary allocations. Use the zero-allocation iterator:

```zig
var it = user.roles.iterator();
while (try it.next()) |role| {
    std.debug.print("Role: {s}\n", .{ role.title });
}
```

---

## Repository Structure

```text
├── build.zig               # Core build file (exports proto_wire, zig-protoc, protoc-gen-zig)
├── build.zig.zon           # Package manifest
├── build_proto.zig         # Reusable build helpers (addProtoModule, addProtoPackage)
├── include/                # Standard Google Well-Known Types (timestamp.proto, any.proto, etc.)
│   └── google/protobuf/
└── src/
    ├── ast.zig             # Proto AST node definitions
    ├── codegen.zig         # Zero-allocation Zig code emitter
    ├── lexer.zig           # Tokenizer for .proto files
    ├── loader.zig          # Multi-file resolver and dependency graph loader
    ├── parser.zig          # Handcrafted parser for proto3 & proto2
    ├── plugin.zig          # Google protoc CodeGeneratorRequest/Response codec
    ├── protoc_gen_zig_main.zig # Entrypoint for protoc-gen-zig plugin
    ├── protoc_main.zig     # Entrypoint for standalone zig-protoc CLI
    ├── resolver.zig        # Semantic type resolution & symbol table
    └── wire.zig            # Zero-allocation runtime codec & wire primitives
```

---

## License

[MIT](LICENSE)
