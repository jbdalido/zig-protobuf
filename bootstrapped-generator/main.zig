const warn = @import("std").debug.warn;
const std = @import("std");
const pb = @import("protobuf");
const plugin = @import("google/protobuf/compiler.pb.zig");
const descriptor = @import("google/protobuf.pb.zig");
const mem = std.mem;
const FullName = @import("./FullName.zig").FullName;

const allocator = std.heap.page_allocator;

const string = []const u8;

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    for (args, 0..) |a, i| {
        if (i > 0) std.log.warn("Will open: {s}", .{a});
    }
    const stdin, const stdout = if (args.len < 3) .{
        std.io.getStdIn(),
        std.io.getStdOut(),
    } else .{
        try std.fs.cwd().openFile(args[1], .{ .mode = .read_only }),
        try std.fs.cwd().createFile(args[2], .{ .truncate = true }),
    };

    // Read the contents (up to 10MB)
    const buffer_size = 1024 * 1024 * 10;

    const file_buffer = try stdin.readToEndAlloc(allocator, buffer_size);
    defer allocator.free(file_buffer);

    const request: plugin.CodeGeneratorRequest = try plugin.CodeGeneratorRequest.decode(file_buffer, allocator);
    for (request.file_to_generate.items) |f| std.log.info("file_to_generate: {s}", .{f.getSlice()});
    for (request.proto_file.items) |p| std.log.info("input_file: {s} @ {s}", .{ if (p.package) |pkg| pkg.getSlice() else "???", if (p.name) |name| name.getSlice() else "???" });

    var ctx: GenerationContext = GenerationContext{ .allocator = allocator, .req = request };

    try ctx.processRequest();

    const r = try ctx.res.encode(allocator);
    _ = try stdout.write(r);
}

const GenerationContext = struct {
    allocator: std.mem.Allocator,
    req: plugin.CodeGeneratorRequest,
    res: plugin.CodeGeneratorResponse = plugin.CodeGeneratorResponse.init(allocator),

    /// map of known packages
    known_packages: std.StringHashMap(FullName) = std.StringHashMap(FullName).init(allocator),

    imports_map: std.StringHashMap([]const u8) = std.StringHashMap([]const u8).init(allocator),

    /// map of "package.fully.qualified.names" to output string lists (aka files)
    output_lists: std.AutoHashMap(*const descriptor.FileDescriptorProto, std.ArrayList([]const u8)) = std.AutoHashMap(*const descriptor.FileDescriptorProto, std.ArrayList([]const u8)).init(allocator),

    const Self = @This();

    pub fn processRequest(self: *Self) !void {
        for (self.req.proto_file.items) |file| {
            if (file.dependency.items.len > 0) {
                std.log.debug("file {?} depends on:", .{file.name});
                for (file.dependency.items) |dep| std.log.debug("- {?}", .{dep});
            }
            const t: descriptor.FileDescriptorProto = file;

            if (t.package) |package| {
                try self.known_packages.put(package.getSlice(), FullName{ .buf = package.getSlice() });
            } else {
                self.res.@"error" = pb.ManagedString{ .Owned = .{ .str = try std.fmt.allocPrint(allocator, "ERROR Package directive missing in {?s}\n", .{file.name.?.getSlice()}), .allocator = allocator } };
                return;
            }

            try self.imports_map.ensureUnusedCapacity(1000);
            var prefix = try std.ArrayList(u8).initCapacity(allocator, file.package.?.getSlice().len + 128);
            prefix.appendAssumeCapacity('.');
            prefix.appendSliceAssumeCapacity(file.package.?.getSlice());
            try self.registerMessages(file.name.?.getSlice(), &prefix, file.enum_type);
            try self.registerMessages(file.name.?.getSlice(), &prefix, file.message_type);
        }

        for (self.req.proto_file.items) |*file| {
            const name = FullName{ .buf = file.name.?.getSlice() };
            try self.printFileDeclarations(name, file);
        }

        var it = self.output_lists.iterator();
        while (it.next()) |entry| {
            var ret = plugin.CodeGeneratorResponse.File.init(allocator);

            const pb_name = try self.outputFileName(entry.key_ptr.*);
            ret.name = pb.ManagedString.move(pb_name, allocator);
            ret.content = pb.ManagedString.move(try std.mem.concat(allocator, u8, entry.value_ptr.*.items), allocator);
            try self.res.file.append(ret);
        }

        self.res.supported_features = @intFromEnum(plugin.CodeGeneratorResponse.Feature.FEATURE_PROTO3_OPTIONAL);
    }

    fn outputFileName(self: *Self, file: *const descriptor.FileDescriptorProto) !string {
        var n = file.name.?.getSlice();
        if (std.mem.endsWith(u8, n, ".proto")) n = n[0 .. n.len - ".proto".len];

        return try std.fmt.allocPrint(self.allocator, "{s}.pb.zig", .{n});
    }

    fn fileNameFromPackage(self: *Self, package: string) !string {
        return try std.fmt.allocPrint(allocator, "{s}.pb.zig", .{try self.packageNameToOutputFileName(package)});
    }

    fn packageNameToOutputFileName(_: *Self, name: string) !string {
        var r: []u8 = try allocator.alloc(u8, name.len);
        var n = name;
        if (std.mem.endsWith(u8, n, ".proto")) n = name[0 .. n.len - ".proto".len];
        for (n, 0..) |byte, i| {
            r[i] = switch (byte) {
                '.', '/', '\\' => '/',
                else => byte,
            };
        }
        return r[0..n.len];
    }

    fn getOutputList(self: *Self, file: *const descriptor.FileDescriptorProto) !*std.ArrayList([]const u8) {
        const entry = try self.output_lists.getOrPut(file);
        if (entry.found_existing) return entry.value_ptr;

        var list = std.ArrayList([]const u8).init(self.allocator);

        try list.append(try std.fmt.allocPrint(self.allocator,
            \\// Code generated by protoc-gen-zig
            \\ ///! package {?}
            \\const std = @import("std");
            \\const Allocator = std.mem.Allocator;
            \\const ArrayList = std.ArrayList;
            \\
            \\const protobuf = @import("protobuf");
            \\const ManagedString = protobuf.ManagedString;
            \\const fd = protobuf.fd;
            \\
            \\test {{
            \\    std.testing.refAllDeclsRecursive(@This());
            \\}}
            \\
        , .{file.package}));

        std.log.debug("Resolving {} deps", .{file.name.?});
        file_deps: for (file.dependency.items) |dep_name| {
            std.log.debug("looking for {}", .{dep_name});
            for (self.req.proto_file.items, 0..) |dep, index| {
                std.log.debug("   found {}", .{dep.name.?});
                if (!std.mem.eql(u8, dep_name.getSlice(), dep.name.?.getSlice()))
                    continue;

                // find whether an import is marked as public
                const is_public_dep = std.mem.indexOfScalar(i32, file.public_dependency.items, @intCast(index));
                const optional_pub_directive: []const u8 = if (is_public_dep) |_| "pub const" else "const";

                try list.append(try std.fmt.allocPrint(self.allocator, "/// import package {?}\n", .{dep.package}));
                // Generate a flat list of imports.
                // const google_protobuf_descriptor = @import("google/protobuf/descriptor.pb.zig");
                // This is not very nice and could trigger conflicts with other names in the code.
                // Ideally we should generate
                // const google = struct {
                //     pub const protobuf = struct {
                //         usingnamespace @import("google/protobuf/descriptor.pb.zig");
                //     };
                // };
                // This is a bit more involved because we need to merge different imports in one struct.
                const import_name = try self.importName(dep.name.?.getSlice());
                try list.append(try std.fmt.allocPrint(self.allocator, "{s} {!s} = @import(\"{!s}\");\n", .{
                    optional_pub_directive,
                    import_name,
                    import_name,
                }));
                continue :file_deps;
            } else {
                std.log.warn("Dependency of {?} not found: {}", .{ file.name, dep_name });
            }
        }

        entry.value_ptr.* = list;
        return entry.value_ptr;
    }

    /// resolves a path B relative to A
    fn resolvePath(self: *Self, a: string, b: string) !string {
        const aPath = std.fs.path.dirname(try self.fileNameFromPackage(a)) orelse "";
        const bPath = try self.fileNameFromPackage(b);

        // to resolve some escaping oddities, the windows path separator is canonicalized to /
        const resolvedRelativePath = try std.fs.path.relative(allocator, aPath, bPath);
        return std.mem.replaceOwned(u8, self.req.file_to_generate.allocator, resolvedRelativePath, "\\", "/");
    }

    pub fn printFileDeclarations(self: *Self, fqn: FullName, file: *descriptor.FileDescriptorProto) !void {
        const list = try self.getOutputList(file);

        try self.generateEnums(list, fqn, file.*, file.enum_type);
        try self.generateMessages(list, fqn, file.*, file.message_type);
    }

    fn generateEnums(ctx: *Self, list: *std.ArrayList(string), fqn: FullName, file: descriptor.FileDescriptorProto, enums: std.ArrayList(descriptor.EnumDescriptorProto)) !void {
        _ = file;

        _ = fqn;
        var enum_values = std.AutoHashMap(i32, void).init(ctx.allocator);
        defer enum_values.deinit();

        for (enums.items) |theEnum| {
            const e: descriptor.EnumDescriptorProto = theEnum;

            try list.append(try std.fmt.allocPrint(allocator, "\npub const {?s} = enum(i32) {{\n", .{e.name.?.getSlice()}));

            enum_values.clearRetainingCapacity();
            try enum_values.ensureTotalCapacity(@intCast(e.value.items.len));
            for (e.value.items) |elem| {
                const val = elem.number orelse 0;
                const res = try enum_values.getOrPut(val);
                if (res.found_existing) {
                    std.log.warn("ignoring duplicate name for enum value.", .{});
                } else {
                    try list.append(try std.fmt.allocPrint(allocator, "   {?s} = {},\n", .{ elem.name.?.getSlice(), val }));
                    res.key_ptr.* = val;
                }
            }

            try list.append("    _,\n};\n\n");
        }
    }

    fn getFieldName(_: *Self, field: descriptor.FieldDescriptorProto) !string {
        return escapeName(field.name.?.getSlice());
    }

    fn escapeName(name: string) !string {
        if (std.zig.Token.keywords.get(name) != null)
            return try std.fmt.allocPrint(allocator, "@\"{?s}\"", .{name})
        else
            return name;
    }

    fn fieldTypeFqn(ctx: *Self, parentFqn: FullName, file: descriptor.FileDescriptorProto, field: descriptor.FieldDescriptorProto) !string {
        if (field.type_name) |type_name| {
            const maybe_import = ctx.imports_map.get(type_name.getSlice());
            // Swallow the error, Zig will generate a better one later when compiling.
            if (maybe_import == null) {
                std.log.err("Unknown type: {}", .{type_name});
                return type_name.getSlice()[1..];
            }

            const fullTypeName = FullName{ .buf = type_name.getSlice()[1..] };

            const import = maybe_import.?;
            if (std.mem.eql(u8, import, file.name.?.getSlice())) {
                // We are in the file declaring this symbol, so no need to import.
                // But we may need to prefix in case of ambiguity
            } else {
                return try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ try ctx.importName(import), fullTypeName.name().buf });
            }

            const is_enum = std.mem.endsWith(u8, type_name.getSlice(), ".Enum");
            _ = is_enum; // autofix
            // if (is_enum) std.log.debug("{s}", .{type_name.getSlice()});

            if (fullTypeName.parent()) |parent| {
                if (parent.eql(parentFqn)) {
                    // if (is_enum) std.log.debug("return@0 {s} !", .{ fullTypeName.name().buf });
                    return fullTypeName.name().buf;
                }
                if (parent.eql(FullName{ .buf = file.package.?.getSlice() })) {
                    // if (is_enum) std.log.debug("return@1 {s} !", .{ fullTypeName.name().buf });
                    return fullTypeName.name().buf;
                }
            }

            var parent: ?FullName = fullTypeName.parent();
            const filePackage = FullName{ .buf = file.package.?.getSlice() };

            // iterate parents until we find a parent that matches the known_packages
            while (parent != null) {
                var it = ctx.known_packages.valueIterator();

                while (it.next()) |value| {

                    // it is in current package, return full name
                    if (filePackage.eql(parent.?)) {
                        const name = fullTypeName.buf[parent.?.buf.len + 1 ..];
                        // if (is_enum) std.log.debug("return@2: {s}", .{name});
                        return name;
                    }

                    // it is in different package. return fully qualified name including accessor
                    if (value.eql(parent.?)) {
                        const prop = try ctx.escapeFqn(parent.?.buf);
                        const name = fullTypeName.buf[prop.len + 1 ..];
                        // if (is_enum) std.log.debug("return@3 {s}.{s}", .{prop, name});
                        return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prop, name });
                    }
                }

                parent = parent.?.parent();
            }

            std.debug.print("Unknown type: {s} from {s} in {?s}\n", .{ fullTypeName.buf, parentFqn.buf, file.package.?.getSlice() });

            // if (is_enum) std.log.debug("return@4 !", .{});
            return try ctx.escapeFqn(field.type_name.?.getSlice());
        }
        @panic("field has no type");
    }

    fn escapeFqn(self: *Self, n: string) !string {
        var r: []u8 = try self.allocator.alloc(u8, n.len);
        for (n, 0..) |byte, i| {
            r[i] = switch (byte) {
                '.', '-', '/', '\\' => '_',
                else => byte,
            };
        }
        return r;
    }

    fn importName(self: *Self, name: string) !string {
        const n = name;
        // if (std.mem.endsWith(u8, n, ".proto")) n = n[0 .. n.len - ".proto".len];
        var r: []u8 = try self.allocator.alloc(u8, n.len);
        for (n, 0..) |byte, i| {
            r[i] = switch (byte) {
                '.', '-', '/', '\\' => '_',
                else => byte,
            };
        }
        std.log.debug("import name: {s} -> {s}", .{ name, r });
        return r;
    }

    fn isRepeated(field: descriptor.FieldDescriptorProto) bool {
        if (field.label) |l| {
            return l == .LABEL_REPEATED;
        } else {
            return false;
        }
    }

    fn isScalarNumeric(t: descriptor.FieldDescriptorProto.Type) bool {
        return switch (t) {
            .TYPE_DOUBLE, .TYPE_FLOAT, .TYPE_INT32, .TYPE_INT64, .TYPE_UINT32, .TYPE_UINT64, .TYPE_SINT32, .TYPE_SINT64, .TYPE_FIXED32, .TYPE_FIXED64, .TYPE_SFIXED32, .TYPE_SFIXED64, .TYPE_BOOL => true,
            else => false,
        };
    }

    fn isPacked(_: *Self, file: descriptor.FileDescriptorProto, field: descriptor.FieldDescriptorProto) bool {
        const default = if (is_proto3_file(file))
            if (field.type) |t|
                isScalarNumeric(t)
            else
                false
        else
            false;

        if (field.options) |o| {
            if (o.@"packed") |p| {
                return p;
            }
        }
        return default;
    }

    fn isOptional(file: descriptor.FileDescriptorProto, field: descriptor.FieldDescriptorProto) bool {
        if (is_proto3_file(file)) {
            return field.proto3_optional == true;
        }

        if (field.label) |l| {
            return l == .LABEL_OPTIONAL;
        } else {
            return false;
        }
    }

    fn getFieldType(ctx: *Self, fqn: FullName, file: descriptor.FileDescriptorProto, field: descriptor.FieldDescriptorProto, is_union: bool) !string {
        var prefix: string = "";
        var postfix: string = "";
        const repeated = isRepeated(field);
        const t = field.type.?;

        if (repeated) {
            prefix = "ArrayList(";
            postfix = ")";
        } else {
            // union are already optional
            if (ctx.isBasicType(field)) {
                if (isOptional(file, field) and !is_union) {
                    prefix = "?";
                }
            } else {
                // union are already optional
                prefix = if (is_union) "* const " else "?* const ";
            }
        }

        const infix: string = switch (t) {
            .TYPE_SINT32, .TYPE_SFIXED32, .TYPE_INT32 => "i32",
            .TYPE_UINT32, .TYPE_FIXED32 => "u32",
            .TYPE_INT64, .TYPE_SINT64, .TYPE_SFIXED64 => "i64",
            .TYPE_UINT64, .TYPE_FIXED64 => "u64",
            .TYPE_BOOL => "bool",
            .TYPE_DOUBLE => "f64",
            .TYPE_FLOAT => "f32",
            .TYPE_STRING, .TYPE_BYTES => "ManagedString",
            .TYPE_ENUM, .TYPE_MESSAGE => try ctx.fieldTypeFqn(fqn, file, field),
            else => {
                std.debug.print("Unrecognized type {}\n", .{t});
                @panic("Unrecognized type");
            },
        };

        return try std.mem.concat(allocator, u8, &.{ prefix, infix, postfix });
    }

    fn isBasicType(ctx: Self, field: descriptor.FieldDescriptorProto) bool {
        _ = ctx; // for now we don't use ctx but we need to to find simple types.
        // Repeated fields are just pointer.
        if (isRepeated(field)) return true;

        return switch (field.type.?) {
            .TYPE_SINT32, .TYPE_SFIXED32, .TYPE_INT32, .TYPE_UINT32, .TYPE_FIXED32, .TYPE_INT64, .TYPE_SINT64, .TYPE_SFIXED64, .TYPE_UINT64, .TYPE_FIXED64, .TYPE_BOOL, .TYPE_DOUBLE, .TYPE_FLOAT, .TYPE_STRING, .TYPE_BYTES, .TYPE_ENUM => true,
            // TODO: we could be more fine-grained here, and allow simple messages to be treated differently.
            .TYPE_MESSAGE => false,
            else => |t| {
                std.debug.print("Unrecognized type {}\n", .{t});
                @panic("Unrecognized type");
            },
        };
    }

    fn getFieldDefault(ctx: *Self, field: descriptor.FieldDescriptorProto, file: descriptor.FileDescriptorProto, nullable: bool) !?string {
        _ = ctx; // autofix
        // ArrayLists need to be initialized
        const repeated = isRepeated(field);
        if (repeated) return null;

        const is_proto3 = is_proto3_file(file);

        if (nullable and field.default_value == null) {
            return "null";
        }

        // proto3 does not support explicit default values, the default scalar values are used instead
        if (is_proto3) {
            return switch (field.type.?) {
                .TYPE_SINT32,
                .TYPE_SFIXED32,
                .TYPE_INT32,
                .TYPE_UINT32,
                .TYPE_FIXED32,
                .TYPE_INT64,
                .TYPE_SINT64,
                .TYPE_SFIXED64,
                .TYPE_UINT64,
                .TYPE_FIXED64,
                .TYPE_FLOAT,
                .TYPE_DOUBLE,
                => "0",
                .TYPE_BOOL => "false",
                .TYPE_STRING, .TYPE_BYTES => ".Empty",
                .TYPE_ENUM => "@enumFromInt(0)",
                else => null,
            };
        }

        if (field.default_value == null) return null;

        return switch (field.type.?) {
            .TYPE_SINT32, .TYPE_SFIXED32, .TYPE_INT32, .TYPE_UINT32, .TYPE_FIXED32, .TYPE_INT64, .TYPE_SINT64, .TYPE_SFIXED64, .TYPE_UINT64, .TYPE_FIXED64, .TYPE_BOOL => field.default_value.?.getSlice(),
            .TYPE_FLOAT => if (std.mem.eql(u8, field.default_value.?.getSlice(), "inf")) "std.math.inf(f32)" else if (std.mem.eql(u8, field.default_value.?.getSlice(), "-inf")) "-std.math.inf(f32)" else if (std.mem.eql(u8, field.default_value.?.getSlice(), "nan")) "std.math.nan(f32)" else field.default_value.?.getSlice(),
            .TYPE_DOUBLE => if (std.mem.eql(u8, field.default_value.?.getSlice(), "inf")) "std.math.inf(f64)" else if (std.mem.eql(u8, field.default_value.?.getSlice(), "-inf")) "-std.math.inf(f64)" else if (std.mem.eql(u8, field.default_value.?.getSlice(), "nan")) "std.math.nan(f64)" else field.default_value.?.getSlice(),
            .TYPE_STRING, .TYPE_BYTES => if (field.default_value.?.isEmpty())
                ".Empty"
            else
                try std.mem.concat(allocator, u8, &.{ "ManagedString.static(", try formatSliceEscapeImpl(field.default_value.?.getSlice()), ")" }),
            .TYPE_ENUM => try std.mem.concat(allocator, u8, &.{ ".", field.default_value.?.getSlice() }),
            else => null,
        };
    }

    fn getFieldTypeDescriptor(ctx: *Self, _: FullName, file: descriptor.FileDescriptorProto, field: descriptor.FieldDescriptorProto, is_union: bool) !string {
        _ = is_union;
        var prefix: string = "";

        var postfix: string = "";

        if (isRepeated(field)) {
            if (ctx.isPacked(file, field)) {
                prefix = ".{ .PackedList = ";
            } else {
                prefix = ".{ .List = ";
            }
            postfix = "}";
        }

        const infix: string = switch (field.type.?) {
            .TYPE_DOUBLE, .TYPE_SFIXED64, .TYPE_FIXED64 => ".{ .FixedInt = .I64 }",
            .TYPE_FLOAT, .TYPE_SFIXED32, .TYPE_FIXED32 => ".{ .FixedInt = .I32 }",
            .TYPE_ENUM, .TYPE_UINT32, .TYPE_UINT64, .TYPE_BOOL, .TYPE_INT32, .TYPE_INT64 => ".{ .Varint = .Simple }",
            .TYPE_SINT32, .TYPE_SINT64 => ".{ .Varint = .ZigZagOptimized }",
            .TYPE_STRING, .TYPE_BYTES => ".String",
            .TYPE_MESSAGE => if (ctx.isBasicType(field) or isRepeated(field)) ".{ .SubMessage = {} }" else ".{ .AllocMessage = {} }",
            else => {
                std.debug.print("Unrecognized type {}\n", .{field.type.?});
                @panic("Unrecognized type");
            },
        };

        return try std.mem.concat(allocator, u8, &.{ prefix, infix, postfix });
    }

    fn generateFieldDescriptor(ctx: *Self, list: *std.ArrayList(string), fqn: FullName, file: descriptor.FileDescriptorProto, message: descriptor.DescriptorProto, field: descriptor.FieldDescriptorProto, is_union: bool) !void {
        _ = message;
        const name = try ctx.getFieldName(field);
        const descStr = try ctx.getFieldTypeDescriptor(fqn, file, field, is_union);
        const format = "        .{s} = fd({?d}, {s}),\n";
        try list.append(try std.fmt.allocPrint(allocator, format, .{ name, field.number, descStr }));
    }

    fn generateFieldDeclaration(ctx: *Self, list: *std.ArrayList(string), fqn: FullName, file: descriptor.FileDescriptorProto, message: descriptor.DescriptorProto, field: descriptor.FieldDescriptorProto, is_union: bool) !void {
        _ = message;

        const type_str = try ctx.getFieldType(fqn, file, field, is_union);
        const field_name = try ctx.getFieldName(field);

        const nullable = type_str[0] == '?';

        if (try ctx.getFieldDefault(field, file, nullable)) |default_value| {
            try list.append(try std.fmt.allocPrint(allocator, "    {s}: {s} = {s},\n", .{ field_name, type_str, default_value }));
        } else {
            try list.append(try std.fmt.allocPrint(allocator, "    {s}: {s},\n", .{ field_name, type_str }));
        }
    }

    /// this function returns the amount of options available for a given "oneof" declaration
    ///
    /// since protobuf 3.14, optional values in proto3 are wrapped in a single-element
    /// oneof to enable optional behavior in most languages. since we have optional types
    /// in zig, we can not use it for a better end-user experience and for readability
    fn amountOfElementsInOneofUnion(_: *Self, message: descriptor.DescriptorProto, oneof_index: ?i32) u32 {
        if (oneof_index == null) return 0;

        var count: u32 = 0;
        for (message.field.items) |f| {
            if (oneof_index == f.oneof_index)
                count += 1;
        }

        return count;
    }

    fn registerMessages(self: *Self, file: []const u8, prefix: *std.ArrayList(u8), messages: anytype) !void {
        const original_len = prefix.items.len;
        defer prefix.shrinkRetainingCapacity(original_len);

        try prefix.append('.');

        for (messages.items) |msg| {
            const last_len = prefix.items.len;
            defer prefix.shrinkRetainingCapacity(last_len);

            try prefix.appendSlice(msg.name.?.getSlice());
            var fqn = prefix.items;
            const res = try self.imports_map.getOrPut(fqn);
            if (res.found_existing) {
                std.debug.assert(std.mem.eql(u8, file, res.value_ptr.*));
            } else {
                fqn = try allocator.dupe(u8, prefix.items);
                res.key_ptr.* = fqn;
                res.value_ptr.* = file;
                std.log.debug("{s} -> {s}", .{ fqn, file });
            }

            if (@hasField(@TypeOf(msg), "nested_type")) {
                try self.registerMessages(file, prefix, msg.nested_type);
            }
            if (@hasField(@TypeOf(msg), "enum_type")) {
                try self.registerMessages(file, prefix, msg.enum_type);
            }
        }
    }

    fn generateMessages(ctx: *Self, list: *std.ArrayList(string), fqn: FullName, file: descriptor.FileDescriptorProto, messages: std.ArrayList(descriptor.DescriptorProto)) !void {
        for (messages.items) |message| {
            const m: descriptor.DescriptorProto = message;
            const messageFqn = try fqn.append(allocator, m.name.?.getSlice());
            std.log.info("message {?} in {?} (pkg: {?}", .{ m.name, file.name, file.package });

            try list.append(try std.fmt.allocPrint(allocator, "\npub const {?} = struct {{\n", .{m.name}));

            // append all fields that are not part of a oneof
            for (m.field.items) |f| {
                if (f.oneof_index == null or ctx.amountOfElementsInOneofUnion(m, f.oneof_index) == 1) {
                    try ctx.generateFieldDeclaration(list, messageFqn, file, m, f, false);
                }
            }

            // print all oneof fields
            for (m.oneof_decl.items, 0..) |oneof, i| {
                const union_element_count = ctx.amountOfElementsInOneofUnion(m, @as(i32, @intCast(i)));
                if (union_element_count > 1) {
                    const oneof_name = oneof.name.?.getSlice();
                    try list.append(try std.fmt.allocPrint(allocator, "    {s}: ?union(enum) {{\n", .{try escapeName(oneof_name)}));

                    for (m.field.items) |field| {
                        const f: descriptor.FieldDescriptorProto = field;
                        if (f.oneof_index orelse -1 == @as(i32, @intCast(i))) {
                            const name = try ctx.getFieldName(f);
                            const typeStr = try ctx.getFieldType(messageFqn, file, f, true);
                            try list.append(try std.fmt.allocPrint(allocator, "      {?s}: {?s},\n", .{ name, typeStr }));
                        }
                    }

                    try list.append(
                        \\    pub const _union_desc = .{
                        \\
                    );

                    for (m.field.items) |field| {
                        const f: descriptor.FieldDescriptorProto = field;
                        if (f.oneof_index orelse -1 == @as(i32, @intCast(i))) {
                            try ctx.generateFieldDescriptor(list, messageFqn, file, m, f, true);
                        }
                    }

                    try list.append(
                        \\      };
                        \\    },
                        \\
                    );
                }
            }

            // field descriptors
            try list.append(
                \\
                \\    pub const _desc_table = .{
                \\
            );

            // first print fields
            for (m.field.items) |f| {
                if (f.oneof_index == null or ctx.amountOfElementsInOneofUnion(m, f.oneof_index) == 1) {
                    try ctx.generateFieldDescriptor(list, messageFqn, file, m, f, false);
                }
            }

            // print all oneof fields
            for (m.oneof_decl.items, 0..) |oneof, i| {
                // only emit unions that have more than one element
                const union_element_count = ctx.amountOfElementsInOneofUnion(m, @as(i32, @intCast(i)));
                if (union_element_count > 1) {
                    const oneof_name = oneof.name.?.getSlice();
                    try list.append(try std.fmt.allocPrint(allocator, "    .{s} = fd(null, .{{ .OneOf = std.meta.Child(std.meta.FieldType(@This(), .{s})) }}),\n", .{ oneof_name, oneof_name }));
                }
            }

            try list.append(
                \\    };
                \\
            );

            try ctx.generateEnums(list, messageFqn, file, m.enum_type);
            try ctx.generateMessages(list, messageFqn, file, m.nested_type);

            try list.append(try std.fmt.allocPrint(allocator,
                \\
                \\    pub usingnamespace protobuf.MessageMixins(@This());
                \\}};
                \\
            , .{}));
        }
    }
};

fn is_proto3_file(file: descriptor.FileDescriptorProto) bool {
    if (file.syntax) |syntax| return std.mem.eql(u8, syntax.getSlice(), "proto3");
    return false;
}

pub fn formatSliceEscapeImpl(
    str: string,
) !string {
    const charset = "0123456789ABCDEF";
    var buf: [4]u8 = undefined;

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    var writer = out.writer();

    try writer.writeByte('"');

    buf[0] = '\\';
    buf[1] = 'x';

    for (str) |c| {
        if (c == '"') {
            try writer.writeByte('\\');
            try writer.writeByte('"');
        } else if (c == '\\') {
            try writer.writeByte('\\');
            try writer.writeByte('\\');
        } else if (std.ascii.isPrint(c)) {
            try writer.writeByte(c);
        } else {
            buf[2] = charset[c >> 4];
            buf[3] = charset[c & 15];
            try writer.writeAll(&buf);
        }
    }
    try writer.writeByte('"');
    return out.toOwnedSlice();
}
