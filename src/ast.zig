pub const Syntax = enum { proto2, proto3, edition };

pub const FieldLabel = enum { implicit, optional, required, repeated };

pub const Option = struct {
    name: []const u8,
    raw_value: []const u8,
};

pub const Field = struct {
    label: FieldLabel,
    type_name: []const u8,
    name: []const u8,
    number: u29,
    options: []Option,
};

pub const MapField = struct {
    key_type: []const u8,
    value_type: []const u8,
    name: []const u8,
    number: u29,
    options: []Option,
};

pub const Oneof = struct {
    name: []const u8,
    fields: []Field,
};

pub const EnumValue = struct {
    name: []const u8,
    number: i32,
};

pub const Enum = struct {
    name: []const u8,
    values: []EnumValue,
};

pub const Message = struct {
    name: []const u8,
    fields: []Field,
    maps: []MapField,
    oneofs: []Oneof,
    nested_messages: []Message,
    nested_enums: []Enum,
};

pub const Rpc = struct {
    name: []const u8,
    req_type: []const u8,
    req_stream: bool,
    res_type: []const u8,
    res_stream: bool,
};

pub const Service = struct {
    name: []const u8,
    rpcs: []Rpc,
};

pub const File = struct {
    name: []const u8 = "",
    syntax: Syntax = .proto2,
    package: ?[]const u8 = null,
    imports: [][]const u8,
    public_imports: []usize = &.{},
    options: []Option,
    messages: []Message,
    enums: []Enum,
    services: []Service,
};
