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

pub const FieldMask = struct {
    paths: ArrayListU(ManagedString) = .{},

    pub const _desc_table = .{
        .paths = fd(1, .{ .List = .String }),
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};
