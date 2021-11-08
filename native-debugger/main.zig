const std = @import("std");
const zt = @import("zt");
const ig = @import("imgui");
const zg = zt.custom_components;

const dida = @import("../lib/dida.zig");
const dida_test = @import("../test/core.zig");

const global_allocator = std.heap.c_allocator;

pub fn main() !void {
    std.debug.print("Started!\n", .{});
    dida_test.testShardTotalBalance() catch |err|
        dida.util.dump(err);
    run();
}

pub fn run() void {
    var i: usize = 0;

    const Context = zt.App(void);
    var context = Context.begin(global_allocator, {});
    context.settings.energySaving = false;
    while (context.open) {
        context.beginFrame();
        const viewport = ig.igGetMainViewport();
        ig.igSetNextWindowPos(viewport.*.Pos, 0, .{});
        ig.igSetNextWindowSize(viewport.*.Size, 0);
        var open = true;
        if (ig.igBegin(
            "The window",
            &open,
            ig.ImGuiWindowFlags_NoDecoration |
                ig.ImGuiWindowFlags_NoBackground |
                ig.ImGuiWindowFlags_AlwaysAutoResize |
                ig.ImGuiWindowFlags_NoSavedSettings |
                ig.ImGuiWindowFlags_NoFocusOnAppearing |
                ig.ImGuiWindowFlags_NoNav,
        )) {
            if (ig.igButton("<<", .{}))
                i = 0;
            ig.igSameLine(0, 0);
            if (ig.igButton("<", .{}) and i > 0)
                i -= 1;
            ig.igSameLine(0, 0);
            var c_i = @intCast(c_int, i);
            if (ig.igDragInt("##i", &c_i, 1.0, 0, @intCast(c_int, debug_events.items.len - 1), "%d", 0))
                i = @intCast(usize, c_i);
            ig.igSameLine(0, 0);
            if (ig.igButton(">", .{}) and i < debug_events.items.len - 1)
                i += 1;
            ig.igSameLine(0, 0);
            if (ig.igButton(">>", .{}))
                i = debug_events.items.len - 1;
            const State = struct {
                prev_event: dida.debug.DebugEvent,
                next_event: ?dida.debug.DebugEvent,
                validation_errors: []const dida.debug.ValidationError,
                shard: dida.core.Shard,
            };
            inspect(global_allocator, "root", State{
                .prev_event = debug_events.items[i],
                .next_event = if (i + 1 == debug_events.items.len) null else debug_events.items[i + 1],
                .shard = shards.items[i],
                .validation_errors = validation_errors.items[i],
            });
            inspect(global_allocator, "events", debug_events);
            inspect(global_allocator, "ios_by_node", ios_by_node);
        }
        ig.igEnd();
        context.endFrame();
    }
    context.deinit();
}

fn inspect(allocator: *std.mem.Allocator, name: []const u8, thing: anytype) void {
    const T = @TypeOf(thing);
    if (treeNodeFmt("{s}", .{name})) {
        ig.igSameLine(0, 0);
        zg.ztText(": {s}", .{@typeName(T)});
        switch (@typeInfo(T)) {
            .Int => zg.ztText("{d} 0o{o} 0b{b}", .{ thing, thing, thing }),
            .Struct => |info| {
                if (comptime std.mem.startsWith(u8, @typeName(T), "std.array_list.ArrayList")) {
                    for (thing.items) |elem, i| {
                        inspect(allocator, zg.fmtTextForImgui("{}", .{i}), elem);
                    }
                } else if (comptime std.mem.startsWith(u8, @typeName(T), "std.hash_map.HashMap")) {
                    var iter = thing.iterator();
                    var i: usize = 0;
                    while (iter.next()) |entry| {
                        // TODO is there a better way to name these?
                        inspect(allocator, zg.fmtTextForImgui("{}", .{i}), T.KV{
                            .key = entry.key_ptr.*,
                            .value = entry.value_ptr.*,
                        });
                        i += 1;
                    }
                } else inline for (info.fields) |field_info| {
                    inspect(allocator, field_info.name, @field(thing, field_info.name));
                }
            },
            .Union => |info| {
                if (info.tag_type) |tag_type| {
                    inline for (@typeInfo(tag_type).Enum.fields) |field_info| {
                        if (std.meta.activeTag(thing) == @intToEnum(tag_type, field_info.value)) {
                            inspect(allocator, field_info.name, @field(thing, field_info.name));
                        }
                    }
                }
            },
            .Array => {
                for (thing) |elem, i| {
                    inspect(allocator, zg.fmtTextForImgui("{}", .{i}), elem);
                }
            },
            .Pointer => |info| {
                switch (info.size) {
                    .One => inspect(allocator, "*", thing.*),
                    .Many => zg.ztText("{any}", .{thing}),
                    .Slice => for (thing) |elem, i| {
                        inspect(allocator, zg.fmtTextForImgui("{}", .{i}), elem);
                    },
                    .C => zg.ztText("{any}", .{thing}),
                }
            },
            .Optional => {
                if (thing) |thing_not_null|
                    inspect(allocator, "?", thing_not_null)
                else
                    zg.ztText("null", .{});
            },
            else => zg.ztText("{any}", .{thing}),
        }
        ig.igTreePop();
    } else {
        ig.igSameLine(0, 0);
        if (@typeInfo(T) == .Pointer and
            @typeInfo(T).Pointer.size == .Slice and
            @typeInfo(T).Pointer.child == u8)
            zg.ztText(" = {s}", .{thing})
        else
            zg.ztText(" = {any}", .{thing});
    }
}

fn treeNodeFmt(comptime fmt: []const u8, args: anytype) bool {
    const text = zg.fmtTextForImgui(fmt, args);
    return ig.igTreeNode_Str(text);
}

var shards = std.ArrayList(dida.core.Shard).init(global_allocator);
var debug_events = std.ArrayList(dida.debug.DebugEvent).init(global_allocator);
var validation_errors = std.ArrayList([]const dida.debug.ValidationError).init(global_allocator);
const IxAndEvent = struct {
    ix: usize,
    event: dida.debug.DebugEvent,
};
const Direction = union(enum) { In: usize, Out };
const IO = struct {
    ix: usize,
    direction: Direction,
    changes: []dida.core.Change,
};
var events_by_node = dida.util.DeepHashMap(dida.core.Node, std.ArrayList(IxAndEvent)).init(global_allocator);
var ios_by_node = dida.util.DeepHashMap(dida.core.Node, std.ArrayList(IO)).init(global_allocator);

// Called from dida.debug
pub fn emitDebugEvent(shard: *const dida.core.Shard, debug_event: dida.debug.DebugEvent) void {
    tryEmitDebugEvent(shard, debug_event) catch
        dida.util.panic("OOM", .{});
}
var ix: usize = 0;
pub fn tryEmitDebugEvent(shard: *const dida.core.Shard, debug_event: dida.debug.DebugEvent) error{OutOfMemory}!void {
    _ = shard;
    _ = debug_event;
    //dida.util.dump(ix);
    //dida.util.dump(.{ .ix = ix, .event = debug_event });
    try shards.append(try dida.util.deepClone(shard.*, global_allocator));
    try debug_events.append(try dida.util.deepClone(debug_event, global_allocator));
    try validation_errors.append(dida.debug.validate(global_allocator, shard));
    const node: ?dida.core.Node = switch (debug_event) {
        .PushInput => |e| e.node,
        .FlushInput => |e| e.node,
        .AdvanceInput => |e| e.node,
        .EmitChangeBatch => |e| e.from_node,
        .ProcessChangeBatch => |e| e.node_input.node,
        .QueueFrontierUpdate => |e| e.node_input.node,
        .ApplyFrontierUpdate => |e| e.node,
        .ProcessFrontierUpdates => null,
        .ProcessFrontierUpdate => |e| e.node,
        .ProcessFrontierUpdateReaction => |e| e.node,
        .PopOutput => |e| e.node,
        .DoWork => null,
    };
    if (node != null) {
        const entry = try events_by_node.getOrPutValue(node.?, std.ArrayList(IxAndEvent).init(global_allocator));
        try entry.value_ptr.append(.{
            .ix = ix,
            .event = try dida.util.deepClone(debug_event, global_allocator),
        });
    }
    const changes: ?[]dida.core.Change = switch (debug_event) {
        .EmitChangeBatch => |e| e.change_batch.changes,
        .ProcessChangeBatch => |e| e.change_batch.changes,
        else => null,
    };
    const direction: ?Direction = switch (debug_event) {
        .PushInput,
        .FlushInput,
        .AdvanceInput,
        .ProcessFrontierUpdate,
        .ProcessFrontierUpdateReaction,
        .PopOutput,
        .EmitChangeBatch,
        .ApplyFrontierUpdate,
        => .Out,
        .ProcessChangeBatch => |e| .{ .In = e.node_input.input_ix },
        .QueueFrontierUpdate => |e| .{ .In = e.node_input.input_ix },
        .ProcessFrontierUpdates, .DoWork => null,
    };
    if (changes != null) {
        const entry = try ios_by_node.getOrPutValue(node.?, std.ArrayList(IO).init(global_allocator));
        try entry.value_ptr.append(.{
            .ix = ix,
            .direction = direction.?,
            .changes = try dida.util.deepClone(changes.?, global_allocator),
        });
    }
    //if (ix == 10000) run();
    ix += 1;
}
