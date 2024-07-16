// Code generated by protoc-gen-zig
///! package google.protobuf
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListU = std.ArrayListUnmanaged;

const protobuf = @import("protobuf");
const ManagedString = protobuf.ManagedString;
const fd = protobuf.fd;

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub const Any = struct {
    type_url: ManagedString = .Empty,
    value: ManagedString = .Empty,

    pub const _desc_table = .{
        .type_url = fd(1, .String),
        .value = fd(2, .String),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};
