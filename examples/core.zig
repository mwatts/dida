const std = @import("std");
const dida = @import("../lib/dida.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{
    .safety = true,
    .never_unmap = true,
}){};
const allocator = &gpa.allocator;

pub fn main() !void {
    defer _ = gpa.detectLeaks();

    var graph_builder = dida.core.GraphBuilder.init(allocator);
    const subgraph_0 = dida.core.Subgraph{ .id = 0 };
    const subgraph_1 = try graph_builder.addSubgraph(subgraph_0);

    const edges = try graph_builder.addNode(subgraph_0, .Input);
    const edges_1 = try graph_builder.addNode(subgraph_1, .{ .TimestampPush = .{ .input = edges } });
    const reach_future = try graph_builder.addNode(subgraph_1, .{ .TimestampIncrement = .{ .input = null } });
    const reach_index = try graph_builder.addNode(subgraph_1, .{ .Index = .{ .input = reach_future } });
    const distinct_reach_index = try graph_builder.addNode(subgraph_1, .{ .Distinct = .{ .input = reach_index } });
    var swapped_edges_mapper = dida.core.NodeSpec.MapSpec.Mapper{
        .map_fn = (struct {
            fn swap(_: *dida.core.NodeSpec.MapSpec.Mapper, input: dida.core.Row) error{OutOfMemory}!dida.core.Row {
                var output_values = try allocator.alloc(dida.core.Value, 2);
                output_values[0] = input.values[1];
                output_values[1] = input.values[0];
                return dida.core.Row{ .values = output_values };
            }
        }).swap,
    };
    const swapped_edges = try graph_builder.addNode(subgraph_1, .{
        .Map = .{
            .input = edges_1,
            .mapper = &swapped_edges_mapper,
        },
    });
    const swapped_edges_index = try graph_builder.addNode(subgraph_1, .{ .Index = .{ .input = swapped_edges } });
    const joined = try graph_builder.addNode(subgraph_1, .{
        .Join = .{
            .inputs = .{
                distinct_reach_index,
                swapped_edges_index,
            },
            .key_columns = 1,
        },
    });
    var without_middle_mapper = dida.core.NodeSpec.MapSpec.Mapper{
        .map_fn = (struct {
            fn drop_middle(_: *dida.core.NodeSpec.MapSpec.Mapper, input: dida.core.Row) error{OutOfMemory}!dida.core.Row {
                var output_values = try allocator.alloc(dida.core.Value, 2);
                output_values[0] = input.values[2];
                output_values[1] = input.values[1];
                return dida.core.Row{ .values = output_values };
            }
        }).drop_middle,
    };
    const without_middle = try graph_builder.addNode(subgraph_1, .{
        .Map = .{
            .input = joined,
            .mapper = &without_middle_mapper,
        },
    });
    const reach = try graph_builder.addNode(subgraph_1, .{ .Union = .{ .inputs = .{ edges_1, without_middle } } });
    graph_builder.connectLoop(reach, reach_future);
    const reach_pop = try graph_builder.addNode(subgraph_0, .{ .TimestampPop = .{ .input = distinct_reach_index } });
    const reach_out = try graph_builder.addNode(subgraph_0, .{ .Output = .{ .input = reach_pop } });

    var reducer = dida.core.NodeSpec.ReduceSpec.Reducer{
        .reduce_fn = (struct {
            fn concat(_: *dida.core.NodeSpec.ReduceSpec.Reducer, reduced_value: dida.core.Value, row: dida.core.Row, count: usize) !dida.core.Value {
                var string = std.ArrayList(u8).init(allocator);
                try string.appendSlice(reduced_value.String);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    try string.appendSlice(row.values[1].String);
                }
                return dida.core.Value{ .String = string.toOwnedSlice() };
            }
        }).concat,
    };
    const reach_summary = try graph_builder.addNode(subgraph_1, .{ .Reduce = .{
        .input = distinct_reach_index,
        .key_columns = 1,
        .init_value = .{ .String = "" },
        .reducer = &reducer,
    } });
    const reach_summary_out = try graph_builder.addNode(subgraph_1, .{ .Output = .{ .input = reach_summary } });

    const graph = try graph_builder.finishAndReset();

    var shard = try dida.core.Shard.init(allocator, &graph);

    const timestamp0 = dida.core.Timestamp{ .coords = &[_]u64{0} };
    const timestamp1 = dida.core.Timestamp{ .coords = &[_]u64{1} };
    const timestamp2 = dida.core.Timestamp{ .coords = &[_]u64{2} };

    const ab = dida.core.Row{ .values = &[_]dida.core.Value{ .{ .String = "a" }, .{ .String = "b" } } };
    const bc = dida.core.Row{ .values = &[_]dida.core.Value{ .{ .String = "b" }, .{ .String = "c" } } };
    const bd = dida.core.Row{ .values = &[_]dida.core.Value{ .{ .String = "b" }, .{ .String = "d" } } };
    const ca = dida.core.Row{ .values = &[_]dida.core.Value{ .{ .String = "c" }, .{ .String = "a" } } };
    try shard.pushInput(edges, .{ .row = ab, .timestamp = timestamp0, .diff = 1 });
    try shard.pushInput(edges, .{ .row = bc, .timestamp = timestamp0, .diff = 1 });
    try shard.pushInput(edges, .{ .row = bd, .timestamp = timestamp0, .diff = 1 });
    try shard.pushInput(edges, .{ .row = ca, .timestamp = timestamp0, .diff = 1 });
    try shard.pushInput(edges, .{ .row = bc, .timestamp = timestamp1, .diff = -1 });
    try shard.flushInput(edges);

    try shard.advanceInput(edges, timestamp1);
    while (shard.hasWork()) {
        // dida.common.dump(shard);
        try shard.doWork();

        while (shard.popOutput(reach_out)) |change_batch| {
            dida.common.dump(change_batch);
        }
        while (shard.popOutput(reach_summary_out)) |change_batch| {
            dida.common.dump(change_batch);
        }
    }

    std.debug.print("Advancing!\n", .{});

    try shard.advanceInput(edges, timestamp2);
    while (shard.hasWork()) {
        // dida.common.dump(shard);
        try shard.doWork();

        while (shard.popOutput(reach_out)) |change_batch| {
            dida.common.dump(change_batch);
        }
        while (shard.popOutput(reach_summary_out)) |change_batch| {
            dida.common.dump(change_batch);
        }
    }

    // dida.common.dump(shard);
}
