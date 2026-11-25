const std = @import("std");
const wire = @import("proto_wire");
const ast = @import("ast.zig");
const resolver = @import("resolver.zig");
const codegen = @import("codegen.zig");

pub const feature_proto3_optional: u64 = 1;

pub const GeneratedFile = struct {
    name: []const u8,
    content: []const u8,
};

pub const Response = struct {
    err: ?[]const u8 = null,
    supported_features: u64 = feature_proto3_optional,
    files: []const GeneratedFile = &.{},
};

pub const PluginOptions = struct {
    wire_import: []const u8 = "proto_wire",
    root_file: ?[]const u8 = null,
    preserve_unknown_fields: bool = false,
};

fn parsePluginParams(raw: []const u8) !PluginOptions {
    var opts: PluginOptions = .{};
    if (raw.len == 0) return opts;

    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const item = std.mem.trim(u8, part, " \t\r\n");
        if (item.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse return error.UnknownPluginParameter;
        const key = std.mem.trim(u8, item[0..eq], " \t");
        const val = std.mem.trim(u8, item[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "wire_import")) {
            if (val.len == 0) return error.InvalidPluginParameter;
            opts.wire_import = val;
        } else if (std.mem.eql(u8, key, "root_file")) {
            if (val.len == 0) return error.InvalidPluginParameter;
            opts.root_file = val;
        } else if (std.mem.eql(u8, key, "preserve_unknown_fields")) {
            if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1")) {
                opts.preserve_unknown_fields = true;
            } else if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) {
                opts.preserve_unknown_fields = false;
            } else {
                return error.InvalidPluginParameter;
            }
        } else {
            return error.UnknownPluginParameter;
        }
    }
    return opts;
}

pub fn processRequest(arena: std.mem.Allocator, req_bytes: []const u8) ![]u8 {
    const resp = processRequestTyped(arena, req_bytes) catch |err| Response{
        .err = try std.fmt.allocPrint(arena, "protoc-gen-zig: {s}", .{@errorName(err)}),
    };
    return encodeResponse(arena, resp);
}

pub fn encodeResponse(arena: std.mem.Allocator, resp: Response) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    if (resp.err) |msg| {
        try wire.writeTag(w, 1, .len);
        try wire.writeBytes(w, msg);
    }
    if (resp.supported_features != 0) {
        try wire.writeTag(w, 2, .varint);
        try wire.writeVarint(w, resp.supported_features);
    }
    for (resp.files) |f| {
        const entry_size =
            wire.tagSize(1) + wire.varintSize(f.name.len) + f.name.len +
            wire.tagSize(15) + wire.varintSize(f.content.len) + f.content.len;
        try wire.writeTag(w, 15, .len);
        try wire.writeVarint(w, entry_size);
        try wire.writeTag(w, 1, .len);
        try wire.writeBytes(w, f.name);
        try wire.writeTag(w, 15, .len);
        try wire.writeBytes(w, f.content);
    }
    return out.toOwnedSlice();
}

fn processRequestTyped(arena: std.mem.Allocator, req_bytes: []const u8) !Response {
    var files_to_gen: std.StringHashMapUnmanaged(void) = .empty;
    var ast_files: std.ArrayList(ast.File) = .empty;
    var parameter: []const u8 = "";

    var r = wire.Reader.init(req_bytes);
    while (try r.readTag()) |tag| {
        switch (tag.field_number) {
            1 => { // repeated string file_to_generate
                if (tag.wire_type != .len) return error.WireTypeMismatch;
                try files_to_gen.put(arena, try r.readBytes(), {});
            },
            2 => { // optional string parameter
                if (tag.wire_type != .len) return error.WireTypeMismatch;
                parameter = try r.readBytes();
            },
            15 => { // repeated FileDescriptorProto proto_file
                if (tag.wire_type != .len) return error.WireTypeMismatch;
                try ast_files.append(arena, try decodeFileDescriptorProto(arena, try r.readBytes()));
            },
            else => try r.skipField(tag, wire.max_recursion_depth),
        }
    }

    const opts = try parsePluginParams(parameter);
    const all_files = try ast_files.toOwnedSlice(arena);
    const res = try resolver.Resolver.buildMulti(arena, all_files);

    var generated: std.ArrayList(GeneratedFile) = .empty;
    var generated_protos: std.ArrayList([]const u8) = .empty;

    for (all_files, 0..) |file, idx| {
        if (!files_to_gen.contains(file.name)) continue;

        var buf: std.Io.Writer.Allocating = .init(arena);
        try codegen.generateFileWithOptions(arena, idx, &res, &buf.writer, .{
            .wire_import = opts.wire_import,
            .preserve_unknown_fields = opts.preserve_unknown_fields,
        });

        try generated_protos.append(arena, file.name);
        try generated.append(arena, .{
            .name = try codegen.protoToZigRelPath(arena, file.name),
            .content = try buf.toOwnedSlice(),
        });
    }

    if (opts.root_file) |root_name| {
        var root_src: std.Io.Writer.Allocating = .init(arena);
        var used_exports: std.StringHashMapUnmanaged(void) = .empty;
        try root_src.writer.writeAll("// Auto-generated package root by protoc-gen-zig.\n");
        for (generated_protos.items) |proto_name| {
            const rel_zig = try codegen.protoToZigRelPath(arena, proto_name);
            const export_name = try codegen.makeUniqueRootExportName(arena, proto_name, &used_exports);
            try root_src.writer.writeAll("pub const ");
            try codegen.writeIdent(&root_src.writer, export_name);
            try root_src.writer.print(" = @import(\"{s}\");\n", .{rel_zig});
        }
        try generated.append(arena, .{
            .name = root_name,
            .content = try root_src.toOwnedSlice(),
        });
    }

    return .{
        .supported_features = feature_proto3_optional,
        .files = try generated.toOwnedSlice(arena),
    };
}

// --- google.protobuf.FileDescriptorProto wire decoder -> ast.File ---

fn decodeFileDescriptorProto(arena: std.mem.Allocator, bytes: []const u8) !ast.File {
    var name: []const u8 = "";
    var package: ?[]const u8 = null;
    var syntax: ast.Syntax = .proto2;
    var imports: std.ArrayList([]const u8) = .empty;
    var public_imports: std.ArrayList(usize) = .empty;
    var enums: std.ArrayList(ast.Enum) = .empty;
    var raw_msgs: std.ArrayList([]const u8) = .empty;
    var services: std.ArrayList(ast.Service) = .empty;

    var r = wire.Reader.init(bytes);
    while (try r.readTag()) |tag| {
        switch (tag.field_number) {
            1 => name = try r.readBytes(),
            2 => package = try r.readBytes(),
            3 => try imports.append(arena, try r.readBytes()),
            4 => try raw_msgs.append(arena, try r.readBytes()),
            5 => try enums.append(arena, try decodeEnumDescriptor(arena, try r.readBytes())),
            6 => try services.append(arena, try decodeServiceDescriptorProto(arena, try r.readBytes())),
            10 => { // public_dependency (repeated int32, packed or unpacked)
                if (tag.wire_type == .len) {
                    var pr = wire.Reader.init(try r.readBytes());
                    while (!pr.eof()) {
                        const raw_idx: i32 = @truncate(@as(i64, @bitCast(try pr.readVarint())));
                        if (std.math.cast(usize, raw_idx)) |u| try public_imports.append(arena, u);
                    }
                } else {
                    const raw_idx: i32 = @truncate(@as(i64, @bitCast(try r.readVarint())));
                    if (std.math.cast(usize, raw_idx)) |u| try public_imports.append(arena, u);
                }
            },
            12 => {
                const s = try r.readBytes();
                if (std.mem.eql(u8, s, "proto3")) {
                    syntax = .proto3;
                } else if (std.mem.eql(u8, s, "editions")) {
                    syntax = .edition;
                } else {
                    syntax = .proto2;
                }
            },
            else => try r.skipField(tag, wire.max_recursion_depth),
        }
    }

    const pkg_scope = package orelse "";
    var messages: std.ArrayList(ast.Message) = .empty;
    for (raw_msgs.items) |mb| {
        const decoded = try decodeDescriptorProto(arena, mb, pkg_scope, syntax);
        try messages.append(arena, decoded.msg);
    }

    return .{
        .name = name,
        .syntax = syntax,
        .package = package,
        .imports = try imports.toOwnedSlice(arena),
        .public_imports = try public_imports.toOwnedSlice(arena),
        .options = &.{},
        .messages = try messages.toOwnedSlice(arena),
        .enums = try enums.toOwnedSlice(arena),
        .services = try services.toOwnedSlice(arena),
    };
}

fn decodeServiceDescriptorProto(arena: std.mem.Allocator, bytes: []const u8) !ast.Service {
    var name: []const u8 = "";
    var rpcs: std.ArrayList(ast.Rpc) = .empty;

    var r = wire.Reader.init(bytes);
    while (try r.readTag()) |tag| {
        switch (tag.field_number) {
            1 => name = try r.readBytes(),
            2 => try rpcs.append(arena, try decodeMethodDescriptorProto(try r.readBytes())),
            else => try r.skipField(tag, wire.max_recursion_depth),
        }
    }
    return .{
        .name = name,
        .rpcs = try rpcs.toOwnedSlice(arena),
    };
}

fn decodeMethodDescriptorProto(bytes: []const u8) !ast.Rpc {
    var name: []const u8 = "";
    var req_type: []const u8 = "";
    var res_type: []const u8 = "";
    var req_stream = false;
    var res_stream = false;

    var r = wire.Reader.init(bytes);
    while (try r.readTag()) |tag| {
        switch (tag.field_number) {
            1 => name = try r.readBytes(),
            2 => req_type = try r.readBytes(),
            3 => res_type = try r.readBytes(),
            5 => req_stream = (try r.readVarint()) != 0,
            6 => res_stream = (try r.readVarint()) != 0,
            else => try r.skipField(tag, wire.max_recursion_depth),
        }
    }
    return .{
        .name = name,
        .req_type = req_type,
        .req_stream = req_stream,
        .res_type = res_type,
        .res_stream = res_stream,
    };
}

fn decodeEnumDescriptor(arena: std.mem.Allocator, bytes: []const u8) !ast.Enum {
    var name: []const u8 = "";
    var values: std.ArrayList(ast.EnumValue) = .empty;
    var allow_alias = false;

    var r = wire.Reader.init(bytes);
    while (try r.readTag()) |tag| {
        switch (tag.field_number) {
            1 => name = try r.readBytes(),
            2 => {
                var vname: []const u8 = "";
                var vnum: i32 = 0;
                var vr = wire.Reader.init(try r.readBytes());
                while (try vr.readTag()) |vt| {
                    switch (vt.field_number) {
                        1 => vname = try vr.readBytes(),
                        2 => vnum = @truncate(@as(i64, @bitCast(try vr.readVarint()))),
                        else => try vr.skipField(vt, wire.max_recursion_depth),
                    }
                }
                try values.append(arena, .{ .name = vname, .number = vnum });
            },
            3 => { // EnumOptions
                var ordr = wire.Reader.init(try r.readBytes());
                while (try ordr.readTag()) |ot| {
                    if (ot.field_number == 2) {
                        allow_alias = (try ordr.readVarint()) != 0;
                    } else {
                        try ordr.skipField(ot, wire.max_recursion_depth);
                    }
                }
            },
            else => try r.skipField(tag, wire.max_recursion_depth),
        }
    }
    return .{
        .name = name,
        .values = try values.toOwnedSlice(arena),
        .allow_alias = allow_alias,
    };
}

const RawField = struct {
    name: []const u8 = "",
    number: u29 = 0,
    label: u32 = 1, // 1=OPTIONAL, 2=REQUIRED, 3=REPEATED
    type_enum: u32 = 0,
    type_name: []const u8 = "",
    packed_opt: ?bool = null,
    oneof_index: ?usize = null,
    proto3_optional: bool = false,
};

const MapEntryTypes = struct {
    key_type: []const u8,
    value_type: []const u8,
};

const DecodedMessage = struct {
    msg: ast.Message,
    is_map_entry: bool,
    map_types: ?MapEntryTypes,
};

fn fieldProtoTypeName(f: RawField) ![]const u8 {
    return switch (f.type_enum) {
        1 => "double",
        2 => "float",
        3 => "int64",
        4 => "uint64",
        5 => "int32",
        6 => "fixed64",
        7 => "fixed32",
        8 => "bool",
        9 => "string",
        11, 14 => f.type_name, // MESSAGE / ENUM
        12 => "bytes",
        13 => "uint32",
        15 => "sfixed32",
        16 => "sfixed64",
        17 => "sint32",
        18 => "sint64",
        else => error.UnsupportedFieldType,
    };
}

fn decodeFieldDescriptor(bytes: []const u8) !RawField {
    var f: RawField = .{};
    var r = wire.Reader.init(bytes);
    while (try r.readTag()) |tag| {
        switch (tag.field_number) {
            1 => f.name = try r.readBytes(),
            3 => f.number = @truncate(try r.readVarint()),
            4 => f.label = @truncate(try r.readVarint()),
            5 => f.type_enum = @truncate(try r.readVarint()),
            6 => f.type_name = try r.readBytes(),
            8 => { // FieldOptions
                var ordr = wire.Reader.init(try r.readBytes());
                while (try ordr.readTag()) |ot| {
                    if (ot.field_number == 2) {
                        f.packed_opt = (try ordr.readVarint()) != 0;
                    } else {
                        try ordr.skipField(ot, wire.max_recursion_depth);
                    }
                }
            },
            9 => f.oneof_index = @intCast(try r.readVarint()),
            17 => f.proto3_optional = (try r.readVarint()) != 0,
            else => try r.skipField(tag, wire.max_recursion_depth),
        }
    }
    return f;
}

fn decodeDescriptorProto(
    arena: std.mem.Allocator,
    bytes: []const u8,
    parent_scope: []const u8,
    syntax: ast.Syntax,
) !DecodedMessage {
    var name: []const u8 = "";
    var raw_fields: std.ArrayList(RawField) = .empty;
    var raw_nested: std.ArrayList([]const u8) = .empty;
    var nested_enums: std.ArrayList(ast.Enum) = .empty;
    var oneof_names: std.ArrayList([]const u8) = .empty;
    var is_map_entry = false;

    var r = wire.Reader.init(bytes);
    while (try r.readTag()) |tag| {
        switch (tag.field_number) {
            1 => name = try r.readBytes(),
            2 => try raw_fields.append(arena, try decodeFieldDescriptor(try r.readBytes())),
            3 => try raw_nested.append(arena, try r.readBytes()),
            4 => try nested_enums.append(arena, try decodeEnumDescriptor(arena, try r.readBytes())),
            7 => { // MessageOptions
                var mr = wire.Reader.init(try r.readBytes());
                while (try mr.readTag()) |mt| {
                    if (mt.field_number == 7) {
                        is_map_entry = (try mr.readVarint()) != 0;
                    } else {
                        try mr.skipField(mt, wire.max_recursion_depth);
                    }
                }
            },
            8 => { // OneofDescriptorProto
                var oname: []const u8 = "";
                var ordr = wire.Reader.init(try r.readBytes());
                while (try ordr.readTag()) |ot| {
                    if (ot.field_number == 1) oname = try ordr.readBytes() else try ordr.skipField(ot, wire.max_recursion_depth);
                }
                try oneof_names.append(arena, oname);
            },
            else => try r.skipField(tag, wire.max_recursion_depth),
        }
    }

    const my_scope = if (parent_scope.len == 0)
        name
    else
        try std.fmt.allocPrint(arena, "{s}.{s}", .{ parent_scope, name });

    if (is_map_entry) {
        var key_t: []const u8 = "string";
        var val_t: []const u8 = "string";
        for (raw_fields.items) |rf| {
            if (rf.number == 1) key_t = try fieldProtoTypeName(rf);
            if (rf.number == 2) val_t = try fieldProtoTypeName(rf);
        }
        return .{
            .msg = .{
                .name = name,
                .fields = &.{},
                .maps = &.{},
                .oneofs = &.{},
                .nested_messages = &.{},
                .nested_enums = &.{},
            },
            .is_map_entry = true,
            .map_types = .{ .key_type = key_t, .value_type = val_t },
        };
    }

    var map_entries: std.StringHashMapUnmanaged(MapEntryTypes) = .empty;
    var nested_messages: std.ArrayList(ast.Message) = .empty;
    for (raw_nested.items) |nb| {
        const sub = try decodeDescriptorProto(arena, nb, my_scope, syntax);
        if (sub.is_map_entry) {
            const entry_fqn = try std.fmt.allocPrint(arena, ".{s}.{s}", .{ my_scope, sub.msg.name });
            try map_entries.put(arena, entry_fqn, sub.map_types.?);
        } else {
            try nested_messages.append(arena, sub.msg);
        }
    }

    // Track synthetic proto3_optional oneofs so they don't emit Zig unions
    const synthetic_oneof = try arena.alloc(bool, oneof_names.items.len);
    @memset(synthetic_oneof, false);
    for (raw_fields.items) |rf| {
        if (rf.proto3_optional) {
            if (rf.oneof_index) |oi| {
                if (oi < synthetic_oneof.len) synthetic_oneof[oi] = true;
            }
        }
    }

    const oneof_buckets = try arena.alloc(std.ArrayList(ast.Field), oneof_names.items.len);
    for (oneof_buckets) |*b| b.* = .empty;

    var fields: std.ArrayList(ast.Field) = .empty;
    var maps: std.ArrayList(ast.MapField) = .empty;

    for (raw_fields.items) |rf| {
        if (rf.type_enum == 10) continue; // Skip legacy Proto2 GROUP fields

        // Reconstruct map<K, V>
        if (rf.label == 3 and rf.type_enum == 11) {
            if (map_entries.get(rf.type_name)) |mt| {
                try maps.append(arena, .{
                    .key_type = mt.key_type,
                    .value_type = mt.value_type,
                    .name = rf.name,
                    .number = rf.number,
                    .options = &.{},
                });
                continue;
            }
        }

        const opts: []ast.Option = if (rf.packed_opt) |p| blk: {
            const o = try arena.alloc(ast.Option, 1);
            o[0] = .{ .name = "packed", .raw_value = if (p) "true" else "false" };
            break :blk o;
        } else &.{};

        const type_name = try fieldProtoTypeName(rf);

        if (rf.oneof_index) |oi| {
            if (oi < synthetic_oneof.len and !synthetic_oneof[oi]) {
                try oneof_buckets[oi].append(arena, .{
                    .label = .optional,
                    .type_name = type_name,
                    .name = rf.name,
                    .number = rf.number,
                    .options = opts,
                });
                continue;
            }
        }

        const label: ast.FieldLabel = if (rf.label == 3)
            .repeated
        else if (rf.label == 2)
            .required
        else if (rf.proto3_optional or syntax == .proto2)
            .optional
        else
            .implicit;

        try fields.append(arena, .{
            .label = label,
            .type_name = type_name,
            .name = rf.name,
            .number = rf.number,
            .options = opts,
        });
    }

    var oneofs: std.ArrayList(ast.Oneof) = .empty;
    for (oneof_names.items, 0..) |oname, oi| {
        if (synthetic_oneof[oi]) continue;
        try oneofs.append(arena, .{
            .name = oname,
            .fields = try oneof_buckets[oi].toOwnedSlice(arena),
        });
    }

    return .{
        .msg = .{
            .name = name,
            .fields = try fields.toOwnedSlice(arena),
            .maps = try maps.toOwnedSlice(arena),
            .oneofs = try oneofs.toOwnedSlice(arena),
            .nested_messages = try nested_messages.toOwnedSlice(arena),
            .nested_enums = try nested_enums.toOwnedSlice(arena),
        },
        .is_map_entry = false,
        .map_types = null,
    };
}
