//! protoz — Zero-allocation Protobuf compiler and runtime for Zig 0.17.1.
//!
//! Application code imports `@import("protoz")`. Generated `.pb.zig` files
//! import the slim `@import("proto_wire")` module directly.

pub const wire = @import("proto_wire");
pub const wkt = wire.wkt;
pub const json = wire.json;
pub const rpc = wire.rpc;

// Core wire primitives & containers
pub const Reader = wire.Reader;
pub const ReverseWriter = wire.ReverseWriter;
pub const SliceWriter = wire.SliceWriter;
pub const WireType = wire.WireType;
pub const Tag = wire.Tag;
pub const DecodeError = wire.DecodeError;
pub const EncodeError = wire.EncodeError;
pub const max_recursion_depth = wire.max_recursion_depth;

pub const Lazy = wire.Lazy;
pub const Repeated = wire.Repeated;
pub const Map = wire.Map;
pub const PackedChunk = wire.PackedChunk;
pub const UnknownField = wire.UnknownField;
pub const UnknownFields = wire.UnknownFields;
pub const Projection = wire.Projection;

// Length-delimited streaming (TCP/Unix sockets, WALs, .binpb)
pub const DelimitedError = wire.DelimitedError;
pub const DelimitedFrame = wire.DelimitedFrame;
pub const DelimitedIterator = wire.DelimitedIterator;
pub const encodedDelimitedSize = wire.encodedDelimitedSize;
pub const encodeDelimited = wire.encodeDelimited;
pub const encodeDelimitedSlice = wire.encodeDelimitedSlice;
pub const tryDecodeDelimited = wire.tryDecodeDelimited;
pub const decodeDelimitedSlice = wire.decodeDelimitedSlice;

// Arena-backed owned escape hatch
pub const Owned = wire.Owned;
pub const CloneError = wire.CloneError;
pub const cloneMessage = wire.cloneMessage;
pub const cloneOwned = wire.cloneOwned;

// Debug formatting
pub const formatMessage = wire.formatMessage;
