// Code generated by protoc-gen-zig
///! package google/protobuf/wrappers.proto
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const fd = protobuf.fd;

test {
    std.testing.refAllDeclsRecursive(@This());
}
pub const DoubleValue = struct {
    value: f64 = 0,

    pub const _desc_table = .{
        .value = fd(1, .{ .FixedInt = .I64 }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const FloatValue = struct {
    value: f32 = 0,

    pub const _desc_table = .{
        .value = fd(1, .{ .FixedInt = .I32 }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const Int64Value = struct {
    value: i64 = 0,

    pub const _desc_table = .{
        .value = fd(1, .{ .Varint = .Simple }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const UInt64Value = struct {
    value: u64 = 0,

    pub const _desc_table = .{
        .value = fd(1, .{ .Varint = .Simple }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const Int32Value = struct {
    value: i32 = 0,

    pub const _desc_table = .{
        .value = fd(1, .{ .Varint = .Simple }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const UInt32Value = struct {
    value: u32 = 0,

    pub const _desc_table = .{
        .value = fd(1, .{ .Varint = .Simple }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const BoolValue = struct {
    value: bool = false,

    pub const _desc_table = .{
        .value = fd(1, .{ .Varint = .Simple }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const StringValue = struct {
    value: ManagedString = .Empty,

    pub const _desc_table = .{
        .value = fd(1, .String),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};

pub const BytesValue = struct {
    value: ManagedString = .Empty,

    pub const _desc_table = .{
        .value = fd(1, .String),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};
