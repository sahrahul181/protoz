# protoz
[![CI](https://github.com/sahrahul181/protoz/actions/workflows/ci.yml/badge.svg)](https://github.com/sahrahul181/protoz/actions/workflows/ci.yml)
A high-performance, **zero-allocation** Protocol Buffers (`proto3`, `proto2`, and `edition`) compiler and runtime written in pure Zig.

---

## Highlights

- **Zero Heap Allocations:** Encode, size, decode, validate, iterate repeated fields, query maps, and resolve cyclic submessages with **0 heap allocations**. Strings and byte fields borrow directly from the wire buffer; repeated, map, and cyclic fields use zero-copy views.
- **Multi-GB/s Wire Throughput:** Up to **66.87 Mops/s** (14.96 ns) on small messages and **3.08 GB/s** decode / **2.69 GB/s** encode on batched payloads in `ReleaseFast` (see [Benchmarks](#benchmarks)).
- **Single-Pass Reverse Encoding (`ReverseWriter`):** Serializes length-delimited submessages, maps, and packed repeated fields backwards in a single $O(N)$ pass—up to **1.71x faster** than forward streaming with no intermediate buffers.
- **High-Speed Wire Engine:** Pointer-pair `Reader`, direct `u32` raw-tag switching, 1- and 2-byte varint fast paths, shift-free packed varint validation, direct `.packed_slice` views, tight wire windows, and lossless multi-chunk submessage merging.
- **Standalone Compiler or Official `protoc` Plugin:**
  - `zig-protoc`: Pure-Zig standalone compiler with multi-file import resolution, schema validation, and Make `.d` depfile generation (no external `protoc` or C++ toolchain required).
  - `protoc-gen-zig`: Drop-in plugin for Google's `protoc` and `buf` speaking `CodeGeneratorRequest` / `CodeGeneratorResponse`.
- **First-Class `build.zig` Integration:** Hermetic helpers (`addProtoModule`, `addProtoPackage`, and `*With` variants), bundled Google Well-Known Types (`include/google/protobuf/` + pre-wired `proto_wkt` module), and automatic transitive rebuild tracking via `.d` depfiles.

---

## Table of Contents

- [Supported Features](#supported-features)
- [Benchmarks](#benchmarks)
- [Installation](#installation)
- [Zig Build System Integration](#zig-build-system-integration)
  - [Single `.proto` File (`addProtoModule`)](#single-proto-file-addprotomodule)
  - [Multi-File Package with Imports (`addProtoPackage`)](#multi-file-package-with-imports-addprotopackage)
  - [Pre-Wired Well-Known Types (`proto_wkt`)](#pre-wired-well-known-types-proto_wkt)
- [Building & Testing](#building--testing)
- [CLI Usage](#cli-usage)
  - [1. Standalone Compiler (`zig-protoc`)](#1-standalone-compiler-zig-protoc)
  - [2. Official `protoc` Plugin (`protoc-gen-zig`)](#2-official-protoc-plugin-protoc-gen-zig)
- [Runtime Usage](#runtime-usage)
  - [Encoding (`encodeSlice` & `encode`)](#encoding-encodeslice--encode)
  - [Decoding & Validation (`decode` & `validateDepth`)](#decoding--validation-decode--validatedepth)
  - [Repeated Fields, Maps, Oneofs, and Cyclic Messages](#repeated-fields-maps-oneofs-and-cyclic-messages)
- [Repository Structure](#repository-structure)
- [License](#license)

---

## Supported Features

### Schema & Compiler Frontend
- **Syntax Support:** `proto3`, `proto2`, and Protobuf `edition` (`2023+` defaults: explicit field presence, packed repeated encoding, UTF-8 verification, plus file/field-level `features.*` overrides).
- **Full Type System:** All scalar types (`int32`/`64`, `uint32`/`64`, `sint32`/`64` ZigZag, `fixed32`/`64`, `sfixed32`/`64`, `float`, `double`, `bool`, `string`, `bytes`), nested messages and enums, enum aliases (`allow_alias = true`), `oneof` tagged unions, `map<K, V>`, `optional` explicit presence (`proto3_optional`), and self-/mutually-recursive messages (`wire.Lazy(T)`).
- **Multi-File Imports:** Recursive `-I` include-path resolution with circular-import detection, cross-file relative `@import` generation, cross-file cycle detection, Windows & POSIX path canonicalization, and Make `.d` depfiles with proper space escaping.
- **Schema Validation & Zig Safety:** Innermost-component scope shadowing, duplicate field number/name detection, `19000..19999` and `reserved` range/name enforcement, `map` key-type enforcement, proto3 enum zero-first and alias checks, automatic Zig keyword escaping (`@"type"`, `@"error"`, etc.), and `oneof`/nested-type collision disambiguation.
- **Bundled Google Well-Known Types:** Ships standard `google/protobuf/*.proto` definitions (`Any`, `Duration`, `Empty`, `FieldMask`, `Struct`, `Timestamp`, `Wrappers`, `Descriptor`, etc.) automatically wired into `addProtoPackage`.

### Zero-Allocation Wire Runtime
- **Wire Conformance:** Packed and unpacked repeated decoding, 10-byte sign-extended negative `int32` and non-canonical varints, duplicate submessage merging (including across disjoint multi-chunk envelopes and cyclic `Lazy` fields), duplicate map-value message merging, last-key-wins `Map.get`, last-writer-wins `oneof`, and unknown field / Proto2 `SGROUP`–`EGROUP` skipping.
- **Safety Guarantees:** Enforces the official 100-level recursion limit (`error.RecursionLimitExceeded`), overflow-safe bounds checks, strict Proto3/Edition UTF-8 validation (`error.InvalidUtf8`), and zero-stack payload validation (`validateDepth`).

---

## Benchmarks

Measured with `zig build bench -Doptimize=ReleaseFast` (9 samples per operation, volatile anti-constant-folding barriers, **0 heap allocations**):

| Benchmark | Payload | Median (ns) | Min (ns) | Mops/s | Throughput (MB/s) |
|---|---:|---:|---:|---:|---:|
| `Small/encodedSize` | 29 B | 2.82 | 2.82 | 354.04 | 10,267.1 |
| `Small/encodeSlice` (reverse) | 29 B | 14.96 | 14.94 | 66.87 | 1,939.2 |
| `Small/encode` (forward) | 29 B | 16.70 | 16.68 | 59.87 | 1,736.3 |
| `Small/validateDepth` | 29 B | 16.08 | 15.82 | 62.20 | 1,803.8 |
| `Small/decode` (validate + views) | 29 B | 24.32 | 24.23 | 41.11 | 1,192.3 |
| `User/encodedSize` | 161 B | 40.18 | 40.00 | 24.89 | 4,006.5 |
| `User/encodeSlice` (reverse) | 161 B | 107.41 | 107.25 | 9.31 | 1,499.0 |
| `User/encode` (forward) | 161 B | 155.64 | 154.67 | 6.43 | 1,034.5 |
| `User/validateDepth` | 161 B | 123.99 | 123.30 | 8.06 | 1,298.4 |
| `User/decode` (validate + views) | 161 B | 175.80 | 175.06 | 5.69 | 915.8 |
| `User/decode + full traversal` | 161 B | 386.05 | 383.42 | 2.59 | 417.0 |
| `Batch/encodedSize` | 3,020 B | 250.24 | 246.71 | 4.00 | 12,068.5 |
| `Batch/encodeSlice` (reverse) | 3,020 B | 1,123.13 | 1,121.47 | 0.89 | 2,688.9 |
| `Batch/encode` (forward) | 3,020 B | 1,925.59 | 1,923.20 | 0.52 | 1,568.4 |
| `Batch/validateDepth` | 3,020 B | 901.12 | 890.50 | 1.11 | 3,351.4 |
| `Batch/decode` (validate + views) | 3,020 B | 981.34 | 954.15 | 1.02 | 3,077.4 |
| `Batch/decode + full traversal` | 3,020 B | 2,824.12 | 2,764.94 | 0.35 | 1,069.4 |

- **`Small` (`SmallEvent`):** Flat telemetry event (`uint64`, `int64`, `uint32`, UTF-8 `string`).
- **`User` (`UserProfile`):** Rich RPC message (packed `repeated uint32`, `repeated string`, `map<string, int32>`, nested message, explicit `optional bool`, `oneof`, cyclic `Lazy` message).
- **`Batch` (`TelemetryBatch`):** Telemetry batch (128 packed `sint64`, 128 packed `fixed64`, 64 repeated `Point` submessages).

Run locally (supports `--filter`):

```sh
zig build bench -Doptimize=ReleaseFast
zig build bench -Doptimize=ReleaseFast -- --filter Batch
```

---

## Installation

Requires **Zig 0.17.1+**.

Add `protoz` to your project's `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/sahrahul181/protoz
```

---

## Zig Build System Integration

`protoz` re-exports `addProtoModule`, `addProtoPackage`, `addProtoModuleWith`, and `addProtoPackageWith` directly from its package root (`@import("protoz")`). Always forward `target` and `optimize` to `b.dependency("protoz", .{ ... })` so `proto_wire` compiles for your target and optimization mode.

### Single `.proto` File (`addProtoModule`)

Use `addProtoModule` for standalone `.proto` files with no `import` statements:

```zig
const std = @import("std");
const protoz = @import("protoz");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protoz_dep = b.dependency("protoz", .{
        .target = target,
        .optimize = optimize,
    });

    const user_pb = protoz.addProtoModule(b, protoz_dep, .{
        .proto = b.path("proto/user.proto"),
        .out_name = "user.pb.zig",
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "proto_wire", .module = protoz_dep.module("proto_wire") },
                .{ .name = "user_pb", .module = user_pb.module },
            },
        }),
    });
    b.installArtifact(exe);
}
```

### Multi-File Package with Imports (`addProtoPackage`)

Use `addProtoPackage` whenever schemas import other `.proto` files or Google Well-Known Types. It automatically appends `protoz`'s bundled `include/` path (configurable via `.include_well_known_types = true`), generates a `root.zig` barrel, and tracks all transitive imports with a Make `.d` depfile:

```zig
const std = @import("std");
const protoz = @import("protoz");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protoz_dep = b.dependency("protoz", .{
        .target = target,
        .optimize = optimize,
    });

    const orders_pkg = protoz.addProtoPackage(b, protoz_dep, .{
        .include_dirs = &.{b.path("proto")},
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
                .{ .name = "proto_wire", .module = protoz_dep.module("proto_wire") },
                .{ .name = "orders_pb", .module = orders_pkg.module },
            },
        }),
    });
    b.installArtifact(exe);
}
```

In your Zig source, access each generated schema through the barrel module (`orders/models.proto` -> `orders_models`):

```zig
const orders_pb = @import("orders_pb");
const Order = orders_pb.orders_models.Order;
```

### Pre-Wired Well-Known Types (`proto_wkt`)

If you only need standard Google Well-Known Types (`Any`, `Duration`, `Empty`, `FieldMask`, `Struct`, `Timestamp`, `Wrappers`), import the pre-wired `proto_wkt` module directly:

```zig
.{ .name = "proto_wkt", .module = protoz_dep.module("proto_wkt") }
```

```zig
const wkt = @import("proto_wkt");
const ts = wkt.google_protobuf_timestamp.Timestamp{
    .seconds = 1764075000,
    .nanos = 500_000_000,
};
```

---

## Building & Testing

```sh
# Build zig-protoc and protoc-gen-zig into zig-out/bin/
zig build -Doptimize=ReleaseFast

# Run test suite (including bundled Google Well-Known Types verification)
zig build test

# Run zero-allocation benchmarks
zig build bench -Doptimize=ReleaseFast
```

Artifacts produced in `zig-out/bin/`:
- `zig-protoc` (`zig-protoc.exe` on Windows): Standalone compiler CLI
- `protoc-gen-zig` (`protoc-gen-zig.exe` on Windows): Official `protoc` / `buf` plugin

---

## CLI Usage

### 1. Standalone Compiler (`zig-protoc`)

#### Single `.proto` file

```sh
./zig-out/bin/zig-protoc --out person.pb.zig person.proto
```

#### Multi-file package with imports & depfile

```sh
./zig-out/bin/zig-protoc \
    -I proto \
    -I include \
    --out-dir generated_pb \
    --root-file root.zig \
    --depfile generated_pb/proto.d \
    proto/service.proto proto/models/user.proto
```

Flags:
- `-I <dir>` / `--proto-path <dir>`: Add an import search root (repeatable).
- `--out <file>`: Emit a single `.pb.zig` file (omit to write to stdout).
- `--out-dir <dir>`: Emit generated `.pb.zig` files preserving subdirectory structure.
- `--root-file <name>`: Barrel file emitted inside `--out-dir` (default: `root.zig`).
- `--depfile <file>`: Emit a Make-format `.d` dependency file for build systems.

### 2. Official `protoc` Plugin (`protoc-gen-zig`)

```sh
# POSIX
protoc --plugin=protoc-gen-zig=./zig-out/bin/protoc-gen-zig \
    -I proto -I include \
    --zig_out=generated_pb \
    proto/service.proto
```

```powershell
# Windows PowerShell
protoc --plugin=protoc-gen-zig=.\zig-out\bin\protoc-gen-zig.exe `
    -I proto -I include `
    --zig_out=generated_pb `
    proto/service.proto
```

---

## Runtime Usage

### Encoding (`encodeSlice` & `encode`)

#### Single-Pass Reverse Serialization (`encodeSlice`) — Fastest
Serializes directly into a caller-supplied buffer in a single backward pass with zero allocations:

```zig
const pb = @import("user_pb");

const user = pb.User{
    .id = 1001,
    .name = "Alice",
    .scores = .{ .slice = &.{ 10, 20, 300 } },
    .quotas = .{ .slice = &.{
        .{ .key = "cpu", .value = 8 },
        .{ .key = "ram", .value = 32 },
    } },
    .contact = .{ .email = "alice@example.com" },
};

var buffer: [1024]u8 = undefined;
const wire_bytes = try user.encodeSlice(&buffer);
// `wire_bytes` is a slice inside `buffer` of length `user.encodedSize()`.
```

#### Forward Streaming (`encode`)
Writes sequentially to `*wire.SliceWriter` or any writer providing `writeAll` / `writeByte` (including `*std.Io.Writer`):

```zig
const wire = @import("proto_wire");

var stream_buf: [1024]u8 = undefined;
var sw = wire.SliceWriter.init(&stream_buf);
try user.encode(&sw);
const written_bytes = sw.written();
```

### Decoding & Validation (`decode` & `validateDepth`)

```zig
const std = @import("std");
const wire = @import("proto_wire");
const pb = @import("user_pb");

// Zero-allocation decode: strings/bytes borrow from `wire_bytes`
const user = try pb.User.decode(wire_bytes);
std.debug.print("id={d}, name={s}\n", .{ user.id, user.name });

// Zero-stack wire validation (verifies tags, lengths, UTF-8, recursion depth)
try pb.User.validateDepth(wire_bytes, wire.max_recursion_depth);
```

### Repeated Fields, Maps, Oneofs, and Cyclic Messages

```zig
// 1. Repeated fields (packed or unpacked, zero allocations)
var scores_it = user.scores.iterator();
while (try scores_it.next()) |score| {
    std.debug.print("score: {d}\n", .{score});
}

// 2. Map fields (official last-duplicate-key-wins semantics)
if (try user.quotas.get("ram")) |ram| {
    std.debug.print("ram quota: {d}\n", .{ram});
}
var quotas_it = user.quotas.iterator();
while (try quotas_it.next()) |entry| {
    std.debug.print("{s} = {d}\n", .{ entry.key, entry.value });
}

// 3. Oneof tagged unions
if (user.contact) |contact| switch (contact) {
    .email => |addr| std.debug.print("email: {s}\n", .{addr}),
    .phone => |num| std.debug.print("phone: {s}\n", .{num}),
};

// 4. Cyclic messages (`wire.Lazy(T)`) decoded on demand
if (user.manager) |mgr_lazy| {
    const mgr = try mgr_lazy.decode();
    std.debug.print("manager: {s}\n", .{mgr.name});
}
```

---

## Repository Structure

```text
├── build.zig                    # Exports proto_wire, proto_wkt, zig-protoc, protoc-gen-zig, test & bench steps
├── build.zig.zon                # Zig package manifest
├── build_proto.zig              # Reusable build helpers (addProtoModule, addProtoPackage, *With variants)
├── LICENSE                      # MIT License
├── README.md
├── bench/                       # 3-tier zero-allocation benchmark suite (Small, User, Batch)
│   ├── bench.proto
│   └── main.zig
├── include/                     # Bundled Google Well-Known Types (timestamp.proto, any.proto, etc.)
│   └── google/protobuf/
└── src/
    ├── ast.zig                  # Typed AST (proto2, proto3, editions, reserved, aliases)
    ├── codegen.zig              # Zero-allocation Zig 0.17.1 code emitter
    ├── lexer.zig                # Spec-compliant tokenizer with line/column tracking
    ├── loader.zig               # Multi-file import loader & cross-platform path normalization
    ├── parser.zig               # 3-token lookahead recursive-descent .proto parser
    ├── plugin.zig               # Google protoc CodeGeneratorRequest/Response codec
    ├── protoc_gen_zig_main.zig  # Entrypoint for protoc-gen-zig plugin
    ├── protoc_main.zig          # Entrypoint for standalone zig-protoc CLI
    ├── resolver.zig             # Scoped type resolution, cycle detection, and schema validation
    └── wire.zig                 # Zero-allocation wire runtime (Reader, ReverseWriter, Repeated, Map, Lazy)
```

---

## License

[MIT](LICENSE)
