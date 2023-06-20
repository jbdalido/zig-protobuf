// Code generated by protoc-gen-zig
///! package vector_tile
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const protobuf = @import("protobuf");
const fd = protobuf.fd;

pub const Tile = struct {
    layers: ArrayList(Layer),

    pub const _desc_table = .{
        .layers = fd(3, .{ .List = .{ .SubMessage = {} } }),
    };

    pub const GeomType = enum(i32) {
        UNKNOWN = 0,
        POINT = 1,
        LINESTRING = 2,
        POLYGON = 3,
        _,
    };

    pub const Value = struct {
        string_value: ?[]const u8,
        float_value: ?f32,
        double_value: ?f64,
        int_value: ?i64,
        uint_value: ?u64,
        sint_value: ?i64,
        bool_value: ?bool,

        pub const _desc_table = .{
            .string_value = fd(1, .String),
            .float_value = fd(2, .{ .FixedInt = .I32 }),
            .double_value = fd(3, .{ .FixedInt = .I64 }),
            .int_value = fd(4, .{ .Varint = .Simple }),
            .uint_value = fd(5, .{ .Varint = .Simple }),
            .sint_value = fd(6, .{ .Varint = .ZigZagOptimized }),
            .bool_value = fd(7, .{ .Varint = .Simple }),
        };

        pub usingnamespace protobuf.MessageMixins(@This());
    };

    pub const Feature = struct {
        id: ?u64 = 0,
        tags: ArrayList(u32),
        type: ?Tile.GeomType = .UNKNOWN,
        geometry: ArrayList(u32),

        pub const _desc_table = .{
            .id = fd(1, .{ .Varint = .Simple }),
            .tags = fd(2, .{ .PackedList = .{ .Varint = .Simple } }),
            .type = fd(3, .{ .Varint = .Simple }),
            .geometry = fd(4, .{ .PackedList = .{ .Varint = .Simple } }),
        };

        pub usingnamespace protobuf.MessageMixins(@This());
    };

    pub const Layer = struct {
        version: u32 = 1,
        name: []const u8,
        features: ArrayList(Tile.Feature),
        keys: ArrayList([]const u8),
        values: ArrayList(Tile.Value),
        extent: ?u32 = 4096,

        pub const _desc_table = .{
            .version = fd(15, .{ .Varint = .Simple }),
            .name = fd(1, .String),
            .features = fd(2, .{ .List = .{ .SubMessage = {} } }),
            .keys = fd(3, .{ .List = .String }),
            .values = fd(4, .{ .List = .{ .SubMessage = {} } }),
            .extent = fd(5, .{ .Varint = .Simple }),
        };

        pub usingnamespace protobuf.MessageMixins(@This());
    };

    pub usingnamespace protobuf.MessageMixins(@This());
};
