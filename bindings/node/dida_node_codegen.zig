usingnamespace @import("./dida_node_common.zig");

pub fn main() !void {
    var writer = std.io.getStdOut().writer();
    try writer.writeAll("const dida = require('./dida.node');\n\n");
    inline for (types_with_js_constructors) |T| {
        try generateConstructor(writer, T);
    }
}

fn generateConstructor(writer: anytype, comptime Type: type) !void {
    const info = @typeInfo(Type);
    switch (comptime serdeStrategy(Type)) {
        .External => {
            inline for (info.Struct.decls) |decl_info| {
                if (decl_info.is_pub and decl_info.data == .Fn) {
                    if (std.mem.eql(u8, decl_info.name, "init")) {
                        const fn_decl_info = decl_info.data.Fn;
                        const fn_info = @typeInfo(fn_decl_info.fn_type).Fn;
                        // First arg is allocator
                        const args = fn_info.args[1..];

                        // TODO fn_decl_info.arg_names.len is empty
                        //      See https://github.com/ziglang/zig/issues/8259
                        var arg_names: [args.len][]const u8 = undefined;
                        for (arg_names) |*arg_name, i| {
                            arg_name.* = try dida.common.format(allocator, "arg{}", .{i});
                        }

                        try std.fmt.format(
                            writer,
                            \\function {}({}) {{
                            \\    this.external = dida.{}_init({}).external;
                            \\}}
                            \\
                        ,
                            .{
                                @typeName(Type),
                                try std.mem.join(allocator, ", ", &arg_names),
                                @typeName(Type),
                                try std.mem.join(allocator, ", ", &arg_names),
                            },
                        );
                    }
                }
            }
            inline for (info.Struct.decls) |decl_info| {
                if (decl_info.is_pub and decl_info.data == .Fn) {
                    // TODO not sure why this condition needs to be separated out to satisfy compiler
                    if (!std.mem.eql(u8, decl_info.name, "init")) {
                        const fn_decl_info = decl_info.data.Fn;
                        const fn_info = @typeInfo(fn_decl_info.fn_type).Fn;
                        // First arg is self
                        const args = fn_info.args[1..];

                        // TODO fn_decl_info.arg_names.len is empty
                        //      See https://github.com/ziglang/zig/issues/8259
                        var arg_names: [args.len][]const u8 = undefined;
                        for (arg_names) |*arg_name, i| {
                            arg_name.* = try dida.common.format(allocator, "arg{}", .{i});
                        }

                        try std.fmt.format(
                            writer,
                            \\{}.prototype.{} = function {}({}) {{
                            \\    return dida.{}_{}(this, {});
                            \\}}
                            \\
                        ,
                            .{
                                @typeName(Type),
                                decl_info.name,
                                decl_info.name,
                                try std.mem.join(allocator, ", ", &arg_names),
                                @typeName(Type),
                                decl_info.name,
                                try std.mem.join(allocator, ", ", &arg_names),
                            },
                        );
                    }
                }
            }
            try writer.writeAll("\n");
        },
        else => {
            switch (info) {
                .Struct => |struct_info| {
                    try std.fmt.format(writer, "function {}(", .{@typeName(Type)});
                    inline for (struct_info.fields) |field_info| {
                        try std.fmt.format(writer, "{}, ", .{field_info.name});
                    }
                    try writer.writeAll(") {\n");
                    inline for (struct_info.fields) |field_info| {
                        try std.fmt.format(writer, "    this.{} = {};\n", .{ field_info.name, field_info.name });
                    }
                    try writer.writeAll("}\n\n");
                },
                .Union => |union_info| {
                    if (union_info.tag_type) |tag_type| {
                        // TODO name payload args instead of using `arguments[i]`
                        try std.fmt.format(writer, "const {} = {{\n", .{@typeName(Type)});
                        inline for (union_info.fields) |field_info| {
                            const payload = switch (field_info.field_type) {
                                []const u8, f64 => "arguments[0]",
                                void => "undefined",
                                else => payload: {
                                    const num_args = @typeInfo(field_info.field_type).Struct.fields.len;
                                    var args: [num_args][]const u8 = undefined;
                                    for (args) |*arg, arg_ix| arg.* = try dida.common.format(allocator, "arguments[{}]", .{arg_ix});
                                    break :payload try dida.common.format(allocator, "new {}({})", .{ @typeName(field_info.field_type), try std.mem.join(allocator, ", ", &args) });
                                },
                            };
                            try std.fmt.format(
                                writer,
                                \\    {}: function () {{
                                \\        this.tag = "{}";
                                \\        this.payload = {};
                                \\    }},
                                \\
                            ,
                                .{ field_info.name, field_info.name, payload },
                            );
                        }
                        try writer.writeAll("};\n\n");
                    } else {
                        @compileError("Can't know how to make constructor for non-tagged union type " ++ @typeName(Type));
                    }
                },
                else => @compileError("Don't know how to make constructor for type " ++ @typeName(Type)),
            }
        },
    }
}
