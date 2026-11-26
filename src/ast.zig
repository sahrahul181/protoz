pub const Syntax = enum { proto2, proto3, edition };

pub const FieldLabel = enum { implicit, optional, required, repeated };

pub const Option = struct {
    name: []const u8,
    raw_value: []const u8,
};

pub const ReservedRange = struct {
    start: i32,
    end: i32,
};

pub const Field = struct {
    label: FieldLabel,
    type_name: []const u8,
    name: []const u8,
    number: u29,
    options: []Option,
    is_group: bool = false,
};

pub const ExtensionDecl = struct {
    extendee: []const u8,
    fields: []Field,
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
    allow_alias: bool = false,
};

pub const Message = struct {
    name: []const u8,
    fields: []Field,
    maps: []MapField,
    oneofs: []Oneof,
    nested_messages: []Message,
    nested_enums: []Enum,
    options: []const Option = &.{},
    reserved_ranges: []const ReservedRange = &.{},
    reserved_names: []const []const u8 = &.{},
    extension_ranges: []const ReservedRange = &.{},
    extensions: []const ExtensionDecl = &.{},
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
    extensions: []const ExtensionDecl = &.{},
};
