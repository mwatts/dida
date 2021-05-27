pub const meta = @import("dida/meta.zig");
pub const common = @import("dida/common.zig");
usingnamespace common;

// Field names are weird to be consistent with std.math.Order
pub const PartialOrder = enum {
    lt,
    eq,
    gt,
    none,

    pub fn isLessThanOrEqual(self: PartialOrder) bool {
        return switch (self) {
            .lt, .eq => true,
            .gt, .none => false,
        };
    }
};

pub const Timestamp = struct {
    coords: []const usize,

    pub fn initLeast(allocator: *Allocator, num_coords: usize) !Timestamp {
        var coords = try allocator.alloc(usize, num_coords);
        for (coords) |*coord| coord.* = 0;
        return Timestamp{ .coords = coords };
    }

    pub fn initGreatest(allocator: *Allocator, num_coords: usize) !Timestamp {
        var coords = try allocator.alloc(usize, num_coords);
        for (coords) |*coord| coord.* = std.math.maxInt(usize);
        return Timestamp{ .coords = coords };
    }

    pub fn pushCoord(self: Timestamp, allocator: *Allocator) !Timestamp {
        var new_coords = try allocator.alloc(usize, self.coords.len + 1);
        std.mem.copy(usize, new_coords, self.coords);
        new_coords[new_coords.len - 1] = 0;
        return Timestamp{ .coords = new_coords };
    }

    pub fn incrementCoord(self: Timestamp, allocator: *Allocator) !Timestamp {
        var new_coords = try std.mem.dupe(allocator, usize, self.coords[0..self.coords.len]);
        new_coords[new_coords.len - 1] += 1;
        return Timestamp{ .coords = new_coords };
    }

    pub fn popCoord(self: Timestamp, allocator: *Allocator) !Timestamp {
        release_assert(self.coords.len > 0, "Tried to call popCoord on a timestamp with length 0", .{});
        const new_coords = try std.mem.dupe(allocator, usize, self.coords[0 .. self.coords.len - 1]);
        return Timestamp{ .coords = new_coords };
    }

    pub fn leastUpperBound(allocator: *Allocator, self: Timestamp, other: Timestamp) !Timestamp {
        release_assert(self.coords.len == other.coords.len, "Tried to compute leastUpperBound of timestamps with different lengths: {} vs {}", .{ self.coords.len, other.coords.len });
        var output_coords = try allocator.alloc(usize, self.coords.len);
        for (self.coords) |self_coord, i| {
            const other_coord = other.coords[i];
            output_coords[i] = max(self_coord, other_coord);
        }
        return Timestamp{ .coords = output_coords };
    }

    pub fn causalOrder(self: Timestamp, other: Timestamp) PartialOrder {
        release_assert(self.coords.len == other.coords.len, "Tried to compute causalOrder of timestamps with different lengths: {} vs {}", .{ self.coords.len, other.coords.len });
        var lt: usize = 0;
        var gt: usize = 0;
        var eq: usize = 0;
        for (self.coords) |self_coord, i| {
            const other_coord = other.coords[i];
            switch (std.math.order(self_coord, other_coord)) {
                .lt => lt += 1,
                .eq => eq += 1,
                .gt => gt += 1,
            }
        }
        if (eq == self.coords.len) return .eq;
        if (lt + eq == self.coords.len) return .lt;
        if (gt + eq == self.coords.len) return .gt;
        return .none;
    }

    pub fn lexicalOrder(self: Timestamp, other: Timestamp) std.math.Order {
        release_assert(self.coords.len == other.coords.len, "Tried to compute lexicalOrder of timestamps with different lengths: {} vs {}", .{ self.coords.len, other.coords.len });
        for (self.coords) |self_coord, i| {
            const other_coord = other.coords[i];
            switch (std.math.order(self_coord, other_coord)) {
                .lt => return .lt,
                .eq => {},
                .gt => return .gt,
            }
        }
        return .eq;
    }

    pub fn dumpInto(writer: anytype, indent: u32, self: Timestamp) anyerror!void {
        try writer.writeAll("T[");
        for (self.coords) |coord, i| {
            try std.fmt.format(writer, "{}", .{coord});
            if (i != self.coords.len - 1)
                try writer.writeAll(", ");
        }
        try writer.writeAll("]");
    }
};

pub const Frontier = struct {
    allocator: *Allocator,
    // Invariant: non-empty
    // Invariant: timestamps don't overlap - for any two timestamps A and B in timestamps `A.causalOrder(B) == .none`
    timestamps: ArrayList(Timestamp),

    pub fn initLeast(allocator: *Allocator, num_timestamp_coords: usize) !Frontier {
        const timestamp = try Timestamp.initLeast(allocator, num_timestamp_coords);
        var timestamps = ArrayList(Timestamp).init(allocator);
        try timestamps.append(timestamp);
        return Frontier{
            .allocator = allocator,
            .timestamps = timestamps,
        };
    }

    pub fn initGreatest(allocator: *Allocator, num_timestamp_coords: usize) !Frontier {
        const timestamp = try Timestamp.initGreatest(allocator, num_timestamp_coords);
        var timestamps = ArrayList(Timestamp).init(allocator);
        try timestamps.append(timestamp);
        return Frontier{
            .allocator = allocator,
            .timestamps = timestamps,
        };
    }

    pub fn clone(self: Frontier) !Frontier {
        return Frontier{
            .allocator = self.allocator,
            .timestamps = try self.timestamps.clone(),
        };
    }

    pub fn causalOrder(self: Frontier, timestamp: Timestamp) PartialOrder {
        for (self.timestamps.items) |other_timestamp| {
            const order = other_timestamp.causalOrder(timestamp);
            switch (order) {
                .none => {},
                .lt => return .lt,
                .gt => return .gt,
                .eq => return .eq,
            }
        }
        return .none;
    }

    pub fn advance(self: *Frontier, timestamp: Timestamp) !void {
        var good_ix: usize = 0;
        for (self.timestamps.items) |other_timestamp, bad_ix| {
            switch (other_timestamp.causalOrder(timestamp)) {
                .lt => {
                    // overwrite this timestamp
                },
                .eq => {
                    release_assert(good_ix == bad_ix, "If timestamp is already in frontier, then it can't have been greater than any other timestamp in frontier", .{});
                    return;
                },
                .gt => panic("Frontier went backwards, from {} to {}", .{ other_timestamp, timestamp }),
                .none => {
                    // keep this timestamp
                    self.timestamps.items[good_ix] = other_timestamp;
                    good_ix += 1;
                },
            }
        }
        self.timestamps.shrinkRetainingCapacity(good_ix);
        try self.timestamps.append(timestamp);
    }

    pub fn retreat(self: *Frontier, timestamp: Timestamp) !void {
        var good_ix: usize = 0;
        for (self.timestamps.items) |other_timestamp, bad_ix| {
            switch (other_timestamp.causalOrder(timestamp)) {
                .gt => {
                    // overwrite this timestamp
                },
                .eq => {
                    release_assert(good_ix == bad_ix, "If timestamp is already in frontier, then it can't have been greater than any other timestamp in frontier", .{});
                    return;
                },
                .lt => {
                    // TODO should panic for symmetry with advance but I'm being lazy in processFrontierAdvance
                    release_assert(good_ix == bad_ix, "If timestamp is less than one in frontier, then it can't have been greater than any other timestamp in frontier", .{});
                    return;
                },
                .none => {
                    // keep this timestamp
                    self.timestamps.items[good_ix] = other_timestamp;
                    good_ix += 1;
                },
            }
        }
        self.timestamps.shrinkRetainingCapacity(good_ix);
        try self.timestamps.append(timestamp);
    }
};

pub const Value = union(enum) {
    String: []const u8,
    Number: f64,
};

pub const Row = struct {
    values: []const Value,
};

pub const Change = struct {
    row: Row,
    timestamp: Timestamp,
    diff: isize,
};

pub const ChangeBatchBuilder = struct {
    allocator: *Allocator,
    changes: ArrayList(Change),

    pub fn init(allocator: *Allocator) ChangeBatchBuilder {
        return ChangeBatchBuilder{
            .allocator = allocator,
            .changes = ArrayList(Change).init(allocator),
        };
    }

    pub fn finishAndClear(self: *ChangeBatchBuilder) !ChangeBatch {
        release_assert(self.changes.items.len > 0, "Refusing to build an empty change batch", .{});

        std.sort.sort(Change, self.changes.items, {}, struct {
            fn lessThan(_: void, a: Change, b: Change) bool {
                return meta.deepCompare(a, b) == .lt;
            }
        }.lessThan);

        // Coalesce changes with identical rows and timestamps
        var prev_i: usize = 0;
        for (self.changes.items[1..]) |change, i| {
            const prev_change = &self.changes.items[prev_i];
            if (meta.deepEqual(prev_change.row, change.row) and meta.deepEqual(prev_change.timestamp, change.timestamp)) {
                prev_change.diff += change.diff;
            } else {
                prev_i += 1;
                self.changes.items[prev_i] = change;
            }
        }
        self.changes.shrink(prev_i + 1);

        var lower_bound = try Frontier.initLeast(self.allocator, self.changes.items[0].timestamp.coords.len);
        for (self.changes.items) |change| {
            try lower_bound.retreat(change.timestamp);
        }

        return ChangeBatch{
            .lower_bound = lower_bound,
            .changes = self.changes.toOwnedSlice(),
        };
    }
};

pub const ChangeBatch = struct {
    // Invariant: for every change in changes, lower_bound.causalOrder(change).isLessThanOrEqual()
    lower_bound: Frontier,
    // Invariant: non-empty,
    // Invariant: sorted by row/timestamp
    // Invariant: no two changes with same row/timestamp
    changes: []Change,
};

pub const Index = struct {
    allocator: *Allocator,
    change_batches: ArrayList(ChangeBatch),

    pub fn init(allocator: *Allocator) Index {
        return .{
            .allocator = allocator,
            .change_batches = ArrayList(ChangeBatch).init(allocator),
        };
    }

    pub fn getBagAsOf(self: *Index, allocator: *Allocator, timestamp: Timestamp) !Bag {
        var bag = Bag.init(allocator);
        for (self.change_batches.items) |change_batch| {
            if (change_batch.lower_bound.causalOrder(timestamp).isLessThanOrEqual()) {
                for (change_batch.changes) |change| {
                    if (change.timestamp.causalOrder(timestamp).isLessThanOrEqual()) {
                        try bag.update(change.row, change.diff);
                    }
                }
            }
        }
        return bag;
    }
};

pub const Bag = struct {
    row_counts: DeepHashMap(Row, isize),

    pub fn init(allocator: *Allocator) Bag {
        return .{
            .row_counts = DeepHashMap(Row, isize).init(allocator),
        };
    }

    pub fn update(self: *Bag, row: Row, diff: isize) !void {
        const entry = try self.row_counts.getOrPutValue(row, 0);
        entry.value += diff;
        if (entry.value == 0) self.row_counts.removeAssertDiscard(row);
    }
};

pub const Node = struct {
    id: usize,
};

pub const NodeInput = struct {
    node: Node,
    input_ix: usize,
};

pub const NodeSpec = union(enum) {
    Input: InputSpec,
    Map: MapSpec,
    Index: IndexSpec,
    Join: JoinSpec,
    Output: OutputSpec,
    TimestampPush: TimestampPushSpec,
    TimestampIncrement: TimestampIncrementSpec,
    TimestampPop: TimestampPopSpec,
    Union: UnionSpec,
    Distinct: DistinctSpec,

    pub const InputSpec = struct {
        num_timestamp_coords: usize,
    };

    pub const MapSpec = struct {
        input: Node,
        function: fn (row: Row) error{OutOfMemory}!Row,
    };

    pub const IndexSpec = struct {
        input: Node,
    };

    pub const JoinSpec = struct {
        inputs: [2]Node,
        key_columns: usize,
    };

    pub const OutputSpec = struct {
        input: Node,
    };

    pub const TimestampPushSpec = struct {
        input: Node,
    };

    pub const TimestampIncrementSpec = struct {
        // Initially null, will be set later to a future edge
        input: ?Node,
    };

    pub const TimestampPopSpec = struct {
        input: Node,
    };

    pub const UnionSpec = struct {
        inputs: [2]Node,
    };

    pub const DistinctSpec = struct {
        input: Node,
    };

    // Chain casts from *Node to *[1]Node to []Node
    fn ptrToSlice(input: *const Node) []const Node {
        const one_input: *const [1]Node = input;
        return one_input;
    }

    pub fn getInputs(self: *const NodeSpec) []const Node {
        return switch (self.*) {
            .Input => |_| &[_]Node{},
            .Map => |*spec| ptrToSlice(&spec.input),
            .Index => |*spec| ptrToSlice(&spec.input),
            .Output => |*spec| ptrToSlice(&spec.input),
            .TimestampPush => |*spec| ptrToSlice(&spec.input),
            .TimestampIncrement => |*spec| ptrToSlice(&spec.input.?),
            .TimestampPop => |*spec| ptrToSlice(&spec.input),
            .Distinct => |*spec| ptrToSlice(&spec.input),
            .Join => |*spec| &spec.inputs,
            .Union => |*spec| &spec.inputs,
        };
    }

    pub fn hasIndex(self: NodeSpec) bool {
        return switch (self) {
            .Index, .Distinct => true,
            else => false,
        };
    }
};

pub const NodeState = union(enum) {
    Input: InputState,
    Map,
    Index: IndexState,
    Join,
    Output: OutputState,
    TimestampPush,
    TimestampIncrement,
    TimestampPop,
    Union,
    Distinct: DistinctState,

    pub const InputState = struct {
        unflushed_changes: ChangeBatchBuilder,
    };

    pub const IndexState = struct {
        index: Index,
        // These are waiting for the frontier to advance before they are added to the index
        pending_changes: ArrayList(Change),
    };

    pub const OutputState = struct {
        unpopped_change_batches: ArrayList(ChangeBatch),
    };

    pub const DistinctState = struct {
        index: Index,
        // These are times in the future at which the output might change even if there is no new input.
        // To calculate:
        // * Take the leastUpperBound of the timestamps of every possible subset of changes in the input.
        // * Filter out timestamps that are before the output frontier of this node.
        pending_timestamps: DeepHashSet(Timestamp),
    };

    pub fn init(allocator: *Allocator, node_spec: NodeSpec) NodeState {
        return switch (node_spec) {
            .Input => |input_spec| .{
                .Input = .{
                    .unflushed_changes = ChangeBatchBuilder.init(allocator),
                },
            },
            .Map => .Map,
            .Index => .{
                .Index = .{
                    .index = Index.init(allocator),
                    .pending_changes = ArrayList(Change).init(allocator),
                },
            },
            .Join => .Join,
            .Output => .{
                .Output = .{
                    .unpopped_change_batches = ArrayList(ChangeBatch).init(allocator),
                },
            },
            .TimestampPush => .TimestampPush,
            .TimestampIncrement => .TimestampIncrement,
            .TimestampPop => .TimestampPop,
            .Union => .Union,
            .Distinct => .{
                .Distinct = .{
                    .index = Index.init(allocator),
                    .pending_timestamps = DeepHashSet(Timestamp).init(allocator),
                },
            },
        };
    }

    pub fn getIndex(self: *NodeState) ?*Index {
        // TODO unsure if this is correct way to get payload pointer
        return switch (self.*) {
            .Index => |*state| &state.index,
            .Distinct => |*state| &state.index,
            else => null,
        };
    }
};

pub const GraphBuilder = struct {
    allocator: *Allocator,
    node_specs: ArrayList(NodeSpec),

    pub fn init(allocator: *Allocator) GraphBuilder {
        return GraphBuilder{
            .allocator = allocator,
            .node_specs = ArrayList(NodeSpec).init(allocator),
        };
    }

    pub fn addNode(self: *GraphBuilder, node_spec: NodeSpec) !Node {
        const node = Node{ .id = self.node_specs.items.len };
        try self.node_specs.append(node_spec);
        return node;
    }

    pub fn finishAndClear(self: *GraphBuilder) !Graph {
        const num_nodes = self.node_specs.items.len;

        // Collect downstream nodes
        var downstream_node_inputs = try self.allocator.alloc(ArrayList(NodeInput), num_nodes);
        for (self.node_specs.items) |_, node_id| {
            downstream_node_inputs[node_id] = ArrayList(NodeInput).init(self.allocator);
        }
        for (self.node_specs.items) |node_spec, node_id| {
            for (node_spec.getInputs()) |input_node, input_ix| {
                try downstream_node_inputs[input_node.id].append(.{ .node = .{ .id = node_id }, .input_ix = input_ix });
            }
        }

        // Figure out how many timestamp coords each node has
        var num_timestamp_coords = try self.allocator.alloc(?usize, num_nodes);
        for (num_timestamp_coords) |*num| num.* = null;
        var updated = DeepHashSet(Node).init(self.allocator);
        for (self.node_specs.items) |node_spec, node_id| {
            if (node_spec == .Input) {
                num_timestamp_coords[node_id] = node_spec.Input.num_timestamp_coords;
                try updated.put(.{ .id = node_id }, {});
            }
        }
        while (updated.iterator().next()) |entry| {
            const node = entry.key;
            updated.removeAssertDiscard(node);
            for (downstream_node_inputs[node.id].items) |downstream_node_input| {
                if (num_timestamp_coords[downstream_node_input.node.id] == null) {
                    num_timestamp_coords[downstream_node_input.node.id] = switch (self.node_specs.items[downstream_node_input.node.id]) {
                        .TimestampPush => |spec| num_timestamp_coords[node.id].? + 1,
                        .TimestampPop => |spec| num_timestamp_coords[node.id].? - 1,
                        else => num_timestamp_coords[node.id],
                    };
                    try updated.put(downstream_node_input.node, {});
                }
            }
        }

        // Validate graph
        for (self.node_specs.items) |node_spec, node_id| {
            for (node_spec.getInputs()) |input_node, input_ix| {
                release_assert(input_node.id < num_nodes, "All input nodes must exist", .{});
                if (node_spec == .TimestampIncrement) {
                    release_assert(input_node.id > node_id, "TimestampIncrement nodes must have a later node as input", .{});
                } else {
                    release_assert(input_node.id < node_id, "All nodes (other than TimestampIncrement) must have an earlier node as input", .{});
                }
                switch (node_spec) {
                    .Join => |join| release_assert(
                        self.node_specs.items[input_node.id].hasIndex(),
                        "Inputs to Join node must be contain an index",
                        .{},
                    ),
                    .Distinct => |distinct| release_assert(
                        self.node_specs.items[input_node.id].hasIndex(),
                        "Input to Distinct node must contain an index",
                        .{},
                    ),
                    else => {},
                }
                const this_input_num = num_timestamp_coords[input_node.id].?;
                const first_input_num = num_timestamp_coords[node_spec.getInputs()[0].id].?;
                release_assert(
                    this_input_num == first_input_num,
                    "Number of timestamp coordinates must match for all inputs to node {}. Input 0 has {} but input {} has {}.",
                    .{ node_id, first_input_num, input_ix, this_input_num },
                );
            }
        }

        // Freeze
        var frozen_downstream_node_inputs = try self.allocator.alloc([]NodeInput, self.node_specs.items.len);
        for (downstream_node_inputs) |*node_inputs, node_id|
            frozen_downstream_node_inputs[node_id] = node_inputs.toOwnedSlice();
        var frozen_num_timestamp_coords = try self.allocator.alloc(usize, self.node_specs.items.len);
        for (frozen_num_timestamp_coords) |*num, i| num.* = num_timestamp_coords[i].?;

        return Graph{
            .allocator = self.allocator,
            .node_specs = self.node_specs.toOwnedSlice(),
            .num_timestamp_coords = frozen_num_timestamp_coords,
            .downstream_node_inputs = frozen_downstream_node_inputs,
        };
    }
};

pub const Graph = struct {
    allocator: *Allocator,
    node_specs: []const NodeSpec,
    num_timestamp_coords: []usize,
    downstream_node_inputs: []const []const NodeInput,
};

pub const Shard = struct {
    allocator: *Allocator,
    graph: Graph,
    node_states: []NodeState,
    // Tracks where change batches might appear:
    // * For Input, node_capabilities[node.id] reflects possible changes from the outside world. It is set by calling Shard.advanceInput. Shard.pushInput will reject changes with timestamps less than node_frontiers[node.id].
    // * For other nodes, node_capabilities[node.id] reflects the lower_bound of any unprocessed_change_batches queued on their inputs
    node_capabilities: []DeepHashMap(Timestamp, usize),
    // Invariant: for any future change emitted from node, node_frontiers[node.id].compare(change.timestamp) != .lt
    node_frontiers: []Frontier,
    unprocessed_change_batches: ArrayList(ChangeBatchAtNodeInput),
    unprocessed_frontier_advances: DeepHashSet(Node),

    const ChangeBatchAtNodeInput = struct {
        change_batch: ChangeBatch,
        node_input: NodeInput,
    };

    pub fn init(allocator: *Allocator, graph: Graph) !Shard {
        const num_nodes = graph.node_specs.len;

        var node_states = try allocator.alloc(NodeState, num_nodes);
        for (node_states) |*node_state, node_id|
            node_state.* = NodeState.init(allocator, graph.node_specs[node_id]);

        var node_capabilities = try allocator.alloc(DeepHashMap(Timestamp, usize), num_nodes);
        for (node_capabilities) |*node_capability, node_id| {
            node_capability.* = DeepHashMap(Timestamp, usize).init(allocator);
            if (graph.node_specs[node_id] == .Input) {
                const timestamp = try Timestamp.initLeast(allocator, graph.num_timestamp_coords[node_id]);
                try node_capability.put(timestamp, 1);
            }
        }

        var node_frontiers = try allocator.alloc(Frontier, num_nodes);
        for (node_frontiers) |*node_frontier, node_id| {
            node_frontier.* = try Frontier.initLeast(allocator, graph.num_timestamp_coords[node_id]);
        }

        var shard = Shard{
            .allocator = allocator,
            .graph = graph,
            .node_states = node_states,
            .node_capabilities = node_capabilities,
            .node_frontiers = node_frontiers,
            .unprocessed_change_batches = ArrayList(ChangeBatchAtNodeInput).init(allocator),
            .unprocessed_frontier_advances = DeepHashSet(Node).init(allocator),
        };

        // Advance any internal frontiers that might not start at 0
        for (graph.node_specs) |_, node_id| {
            try shard.unprocessed_frontier_advances.put(.{ .id = node_id }, {});
        }
        while (shard.hasWork()) try shard.doWork();

        return shard;
    }

    pub fn pushInput(self: *Shard, node: Node, change: Change) !void {
        // Check that node capabilities allow this input
        var iter = self.node_capabilities[node.id].iterator();
        while (iter.next()) |entry|
            release_assert(
                change.timestamp.causalOrder(entry.key) != .lt,
                "May not push inputs that are less than the Input node frontier set by Shard.advanceInput",
                .{},
            );

        try self.node_states[node.id].Input.unflushed_changes.changes.append(change);
    }

    pub fn flushInput(self: *Shard, node: Node) !void {
        var unflushed_changes = &self.node_states[node.id].Input.unflushed_changes;
        if (unflushed_changes.changes.items.len > 0) {
            const change_batch = try unflushed_changes.finishAndClear();
            try self.emitChangeBatch(node, change_batch);
        }
    }

    pub fn advanceInput(self: *Shard, node: Node, timestamp: Timestamp) !void {
        // Have to flush input so that there aren't any pending changes with timestamps less than the new frontier
        try self.flushInput(node);

        // Remove lesser timestamps
        var timestamp_counts = &self.node_capabilities[node.id];
        var dominated_timestamps = ArrayList(Timestamp).init(self.allocator);
        var iter = timestamp_counts.iterator();
        while (iter.next()) |entry| {
            if (entry.key.causalOrder(timestamp).isLessThanOrEqual()) {
                try dominated_timestamps.append(entry.key);
            }
        }
        for (dominated_timestamps.items) |dominated_timestamp| {
            timestamp_counts.removeAssertDiscard(dominated_timestamp);
        }

        // Add new timestamp
        try timestamp_counts.put(timestamp, 1);

        try self.unprocessed_frontier_advances.put(node, {});
    }

    pub fn emitChangeBatch(self: *Shard, from_node: Node, change_batch: ChangeBatch) !void {
        for (self.graph.downstream_node_inputs[from_node.id]) |to_node_input| {
            try self.unprocessed_change_batches.append(.{
                .change_batch = change_batch,
                .node_input = to_node_input,
            });
            var capability = &self.node_capabilities[to_node_input.node.id];
            for (change_batch.lower_bound.timestamps.items) |timestamp| {
                var count = try capability.getOrPutValue(timestamp, 0);
                count.value += 1;
            }
            // Capabilities changed so frontier needs to be updated
            try self.unprocessed_frontier_advances.put(to_node_input.node, {});
        }
    }

    pub fn popChangeBatch(self: *Shard) !?ChangeBatchAtNodeInput {
        if (self.unprocessed_change_batches.popOrNull()) |change_batch_at_node_input| {
            const change_batch = change_batch_at_node_input.change_batch;
            const node_input = change_batch_at_node_input.node_input;
            var capability = &self.node_capabilities[node_input.node.id];
            for (change_batch.lower_bound.timestamps.items) |timestamp| {
                var count = capability.getEntry(timestamp).?;
                count.value -= 1;
                if (count.value == 0) {
                    capability.removeAssertDiscard(timestamp);
                }
            }
            // Capabilities changed so frontier needs to be updated
            try self.unprocessed_frontier_advances.put(node_input.node, {});
            return change_batch_at_node_input;
        } else {
            return null;
        }
    }

    pub fn popFrontierAdvance(self: *Shard) ?Node {
        var iter = self.unprocessed_frontier_advances.iterator();
        if (iter.next()) |entry| {
            const node = entry.key;
            self.unprocessed_frontier_advances.removeAssertDiscard(node);
            return node;
        } else {
            return null;
        }
    }

    pub fn processChangeBatch(self: *Shard, change_batch: ChangeBatch, node_input: NodeInput) !void {
        const node_spec = self.graph.node_specs[node_input.node.id];
        const node_state = &self.node_states[node_input.node.id];
        switch (node_spec) {
            .Input => panic("Input nodes should not have work pending on their input", .{}),
            .Map => |map| {
                var output_change_batch = ChangeBatchBuilder.init(self.allocator);
                for (change_batch.changes) |change| {
                    var output_change = change; // copy
                    output_change.row = try map.function(change.row);
                    try output_change_batch.changes.append(output_change);
                }
                try self.emitChangeBatch(node_input.node, try output_change_batch.finishAndClear());
            },
            .Index => {
                // These won't be emitted until the frontier passes them
                try node_state.Index.pending_changes.appendSlice(change_batch.changes);
            },
            .Join => |join| {
                const index = self.node_states[join.inputs[1 - node_input.input_ix].id].getIndex().?;
                var output_change_batch = ChangeBatchBuilder.init(self.allocator);
                for (change_batch.changes) |change| {
                    const this_key = change.row.values[0..join.key_columns];
                    for (index.change_batches.items) |other_change_batch| {
                        for (other_change_batch.changes) |other_change| {
                            const other_key = other_change.row.values[0..join.key_columns];
                            if (meta.deepEqual(this_key, other_key)) {
                                const values = switch (node_input.input_ix) {
                                    0 => &[2][]const Value{ change.row.values, other_change.row.values },
                                    1 => &[2][]const Value{ other_change.row.values, change.row.values },
                                    else => panic("Bad input_ix for join: {}", .{node_input.input_ix}),
                                };
                                const output_change = Change{
                                    .row = .{ .values = try std.mem.concat(self.allocator, Value, values) },
                                    .diff = change.diff * other_change.diff,
                                    .timestamp = try Timestamp.leastUpperBound(self.allocator, change.timestamp, other_change.timestamp),
                                };
                                try output_change_batch.changes.append(output_change);
                            }
                        }
                    }
                }
                if (output_change_batch.changes.items.len > 0) {
                    try self.emitChangeBatch(node_input.node, try output_change_batch.finishAndClear());
                }
            },
            .Output => {
                try node_state.Output.unpopped_change_batches.append(change_batch);
            },
            .TimestampPush => {
                var output_change_batch = ChangeBatchBuilder.init(self.allocator);
                for (change_batch.changes) |change| {
                    var output_change = change; // copy
                    output_change.timestamp = try change.timestamp.pushCoord(self.allocator);
                    try output_change_batch.changes.append(output_change);
                }
                try self.emitChangeBatch(node_input.node, try output_change_batch.finishAndClear());
            },
            .TimestampIncrement => {
                var output_change_batch = ChangeBatchBuilder.init(self.allocator);
                for (change_batch.changes) |change| {
                    var output_change = change; // copy
                    output_change.timestamp = try change.timestamp.incrementCoord(self.allocator);
                    try output_change_batch.changes.append(output_change);
                }
                try self.emitChangeBatch(node_input.node, try output_change_batch.finishAndClear());
            },
            .TimestampPop => {
                var output_change_batch = ChangeBatchBuilder.init(self.allocator);
                for (change_batch.changes) |change| {
                    var output_change = change; // copy
                    output_change.timestamp = try change.timestamp.popCoord(self.allocator);
                    try output_change_batch.changes.append(output_change);
                }
                try self.emitChangeBatch(node_input.node, try output_change_batch.finishAndClear());
            },
            .Union => {
                // Pass straight through
                try self.emitChangeBatch(node_input.node, change_batch);
            },
            .Distinct => |distinct| {
                // Figure out which new timestamps are pending
                // TODO is there a faster way to do this?
                for (change_batch.changes) |change| {
                    // change.timestamp is pending
                    try node_state.Distinct.pending_timestamps.put(change.timestamp, {});

                    // for any other_timestamp in pending_timestamps, leastUpperBound(change.timestamp, other_timestamp) is pending
                    var buffer = ArrayList(Timestamp).init(self.allocator);
                    var iter = node_state.Distinct.pending_timestamps.iterator();
                    while (iter.next()) |entry| {
                        const timestamp = try Timestamp.leastUpperBound(
                            self.allocator,
                            change.timestamp,
                            entry.key,
                        );
                        try buffer.append(timestamp);
                    }
                    for (buffer.items) |timestamp| {
                        try node_state.Distinct.pending_timestamps.put(timestamp, {});
                    }
                }
            },
        }
    }

    pub fn processFrontierAdvance(self: *Shard, node: Node) !void {
        const node_spec = self.graph.node_specs[node.id];
        const node_state = &self.node_states[node.id];
        var old_frontier = &self.node_frontiers[node.id];
        var new_frontier = try Frontier.initGreatest(self.allocator, self.graph.num_timestamp_coords[node.id]);

        // Check upstream frontiers
        {
            for (node_spec.getInputs()) |input_node| {
                const upstream_frontier = self.node_frontiers[input_node.id];
                for (upstream_frontier.timestamps.items) |input_timestamp| {
                    const output_timestamp = switch (self.graph.node_specs[node.id]) {
                        .TimestampPush => try input_timestamp.pushCoord(self.allocator),
                        .TimestampIncrement => try input_timestamp.incrementCoord(self.allocator),
                        .TimestampPop => try input_timestamp.popCoord(self.allocator),
                        else => input_timestamp,
                    };
                    try new_frontier.retreat(output_timestamp);
                }
            }
        }

        // Check capabilities
        {
            var iter = self.node_capabilities[node.id].iterator();
            while (iter.next()) |entry| {
                const input_timestamp = entry.key;
                const output_timestamp = switch (self.graph.node_specs[node.id]) {
                    .TimestampPush => try input_timestamp.pushCoord(self.allocator),
                    .TimestampIncrement => try input_timestamp.incrementCoord(self.allocator),
                    .TimestampPop => try input_timestamp.popCoord(self.allocator),
                    else => input_timestamp,
                };
                try new_frontier.retreat(output_timestamp);
            }
        }

        // Index-specific stuff
        if (node_spec == .Index) {
            // If this node contains an index, might be able to produce an output batch
            // This has to happen BEFORE we take these pending changes into account for the output frontier
            var change_batch_builder = ChangeBatchBuilder.init(self.allocator);
            var pending_changes = ArrayList(Change).init(self.allocator);
            for (node_state.Index.pending_changes.items) |change| {
                if (new_frontier.causalOrder(change.timestamp) == .gt) {
                    try change_batch_builder.changes.append(change);
                } else {
                    try pending_changes.append(change);
                }
            }
            node_state.Index.pending_changes = pending_changes;
            if (change_batch_builder.changes.items.len > 0) {
                const change_batch = try change_batch_builder.finishAndClear();
                try node_state.Index.index.change_batches.append(change_batch);
                try self.emitChangeBatch(node, change_batch);
            }

            // Check any pending changes in the index
            for (node_state.Index.pending_changes.items) |change|
                try new_frontier.retreat(change.timestamp);
        }

        // Distinct-specific stuff
        if (node_spec == .Distinct) {

            // Going to emit a result for any timestamp that is before the input frontier
            var timestamps_to_emit = ArrayList(Timestamp).init(self.allocator);
            const input_frontier = self.node_frontiers[node_spec.Distinct.input.id];
            {
                var iter = node_state.Distinct.pending_timestamps.iterator();
                while (iter.next()) |entry| {
                    if (input_frontier.causalOrder(entry.key) == .gt)
                        try timestamps_to_emit.append(entry.key);
                }
            }
            // Remove emitted timestamps from pending timestamps
            for (timestamps_to_emit.items) |timestamp| {
                node_state.Distinct.pending_timestamps.removeAssertDiscard(timestamp);
            }

            // Sort timestamps
            std.sort.sort(Timestamp, timestamps_to_emit.items, {}, struct {
                fn lessThan(_: void, a: Timestamp, b: Timestamp) bool {
                    return a.lexicalOrder(b) == .lt;
                }
            }.lessThan);

            // Compute changes at each timestamp.
            // Lexical order is a complete extension of causal order so we can be sure that for each timestamp all previous timestamps have already been handled.
            // TODO think hard about what should happen if input counts are negative
            var change_batch_builder = ChangeBatchBuilder.init(self.allocator);
            const input_index = self.node_states[node_spec.Distinct.input.id].getIndex().?;
            const output_index = self.node_states[node.id].getIndex().?;
            for (timestamps_to_emit.items) |timestamp| {
                const old_bag = try output_index.getBagAsOf(self.allocator, timestamp);
                var new_bag = try input_index.getBagAsOf(self.allocator, timestamp);
                // Count things that are in new_bag
                {
                    var iter = new_bag.row_counts.iterator();
                    while (iter.next()) |new_entry| {
                        const diff = 1 - (old_bag.row_counts.get(new_entry.key) orelse 0);
                        if (diff != 0)
                            try change_batch_builder.changes.append(.{
                                .row = new_entry.key,
                                .diff = diff,
                                .timestamp = timestamp,
                            });
                    }
                }
                // Count things that are in old_bag and not in new_bag
                {
                    var iter = old_bag.row_counts.iterator();
                    while (iter.next()) |old_entry| {
                        if (!new_bag.row_counts.contains(old_entry.key)) {
                            const diff = -old_entry.value;
                            try change_batch_builder.changes.append(.{
                                .row = old_entry.key,
                                .diff = diff,
                                .timestamp = timestamp,
                            });
                        }
                    }
                }
            }

            // Emit changes
            if (change_batch_builder.changes.items.len > 0) {
                const change_batch = try change_batch_builder.finishAndClear();
                try output_index.change_batches.append(change_batch);
                try self.emitChangeBatch(node, change_batch);
            }

            // Add any remaining pending timestamps to new frontier
            {
                var iter = node_state.Distinct.pending_timestamps.iterator();
                while (iter.next()) |entry|
                    try new_frontier.retreat(entry.key);
            }
        }

        // Check if frontier changed
        std.sort.sort(Timestamp, old_frontier.timestamps.items, {}, struct {
            fn lessThan(_: void, a: Timestamp, b: Timestamp) bool {
                return a.lexicalOrder(b) == .lt;
            }
        }.lessThan);
        std.sort.sort(Timestamp, new_frontier.timestamps.items, {}, struct {
            fn lessThan(_: void, a: Timestamp, b: Timestamp) bool {
                return a.lexicalOrder(b) == .lt;
            }
        }.lessThan);
        const updated = !meta.deepEqual(old_frontier.timestamps.items, new_frontier.timestamps.items);

        old_frontier.* = new_frontier;

        // If frontier changed, need to update everything downstream
        if (updated) {
            for (self.graph.downstream_node_inputs[node.id]) |downstream_node_input| {
                try self.unprocessed_frontier_advances.put(downstream_node_input.node, {});
            }
        }
    }

    pub fn hasWork(self: Shard) bool {
        return (self.unprocessed_change_batches.items.len > 0) or
            (self.unprocessed_frontier_advances.count() > 0);
    }

    pub fn doWork(self: *Shard) !void {
        // Must always handle change batches before frontier advances, otherwise we might see changes arrive that are older than the current frontier
        if (try self.popChangeBatch()) |change_batch_at_node_input| {
            try self.processChangeBatch(change_batch_at_node_input.change_batch, change_batch_at_node_input.node_input);
        } else if (self.popFrontierAdvance()) |node| {
            try self.processFrontierAdvance(node);
        }
    }

    pub fn popOutput(self: *Shard, node: Node) ?ChangeBatch {
        return self.node_states[node.id].Output.unpopped_change_batches.popOrNull();
    }

    pub fn dumpInto(writer: anytype, indent: u32, self: Shard) anyerror!void {
        try writer.writeAll("Shard{\n");

        for (self.graph.node_specs) |node_spec, node_id| {
            try writer.writeByteNTimes(' ', indent + 4);
            try std.fmt.format(writer, "{}: {{\n", .{node_id});

            try writer.writeByteNTimes(' ', indent + 8);
            try writer.writeAll("spec: ");
            try meta.dumpInto(writer, indent + 8, node_spec);
            try writer.writeAll(",\n");

            try writer.writeByteNTimes(' ', indent + 8);
            try writer.writeAll("state: ");
            try meta.dumpInto(writer, indent + 8, self.node_states[node_id]);
            try writer.writeAll(",\n");

            try writer.writeByteNTimes(' ', indent + 8);
            try writer.writeAll("caps: {\n");
            {
                var iter = self.node_capabilities[node_id].iterator();
                while (iter.next()) |entry| {
                    try writer.writeByteNTimes(' ', indent + 12);
                    try meta.dumpInto(writer, indent + 16, entry.key);
                    try std.fmt.format(writer, ": {},\n", .{entry.value});
                }
            }
            try writer.writeByteNTimes(' ', indent + 8);
            try writer.writeAll("},\n");

            try writer.writeByteNTimes(' ', indent + 8);
            try writer.writeAll("frontier: ");
            try meta.dumpInto(writer, indent + 12, self.node_frontiers[node_id].timestamps.items);
            try writer.writeAll(",\n");

            try writer.writeByteNTimes(' ', indent + 8);
            try std.fmt.format(writer, "unprocessed_frontier_update: {},\n", .{self.unprocessed_frontier_advances.contains(.{ .id = node_id })});

            try writer.writeByteNTimes(' ', indent + 8);
            try writer.writeAll("unprocessed_change_batches: [\n");
            {
                for (self.unprocessed_change_batches.items) |change_batch_at_node_input| {
                    if (change_batch_at_node_input.node_input.node.id == node_id) {
                        try writer.writeByteNTimes(' ', indent + 12);
                        try meta.dumpInto(writer, indent + 12, change_batch_at_node_input.change_batch);
                        try writer.writeAll(",\n");
                    }
                }
            }
            try writer.writeByteNTimes(' ', indent + 8);
            try writer.writeAll("],\n");

            try writer.writeByteNTimes(' ', indent + 4);
            try writer.writeAll("},\n");
        }

        try writer.writeByteNTimes(' ', indent);
        try writer.writeAll("}\n");
    }
};
