// SPDX-License-Identifier: BSD-2-Clause

//! Nodes of a function made a function of their own, and a call of it put
//! where they were: what a graph drawn too big is tidied into, as a piece of
//! Flux is made a function.
//!
//! What the links that cross the nodes' edge become:
//!
//! - **A value coming in** is a parameter, one for each pin it comes from,
//!   named after the pin it went into.
//! - **A value going out** is what the function gives back: one at most.
//! - **The run coming in** goes into the call: into one node of them only.
//! - **The run going out** goes on from the call's `then`: to one node only.
//!
//! Nodes no run goes into, with a value going out, are an expression: the
//! function gives it back, and its call is worked out where its value is
//! used, as the nodes were.

const std = @import("std");
const Allocator = std.mem.Allocator;

const model = @import("model.zig");
const Graph = @import("Graph.zig");
const catalog = @import("catalog.zig");
const compile = @import("compile.zig");
const Function = model.Function;
const End = model.End;

pub const Error = Graph.EditError || Graph.LinkError || error{
    /// None of the nodes but the entry, which stays.
    Nothing,
    /// The run comes into more than one of the nodes.
    SeveralWaysIn,
    /// The run goes on from them to more than one node.
    SeveralWaysOut,
    /// More than one of their values is used outside them.
    SeveralResults,
    /// A local of the function is used by them and by the rest: it cannot
    /// be the new function's alone.
    SharedLocal,
};

/// The nodes `ids` of the function at `function` in `g.file.functions` made
/// the function `name`, and a call of it put in their place: the call's id.
/// What their pins are is `nodes`'s to say. A function added moves the
/// others, so `function` is a place, not a pointer.
pub fn collapse(g: *Graph, arena: Allocator, function: usize, ids: []const u32, name: []const u8, nodes: *const catalog.Catalog) Error!u32 {
    const gpa = g.allocator();
    var f = &g.file.functions.items[function];

    var inside: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    for (ids) |id| {
        const n = f.node(id) orelse continue;
        if (std.mem.eql(u8, n.kind, model.entry_kind)) continue;
        try inside.put(arena, id, {});
    }
    if (inside.count() == 0) return error.Nothing;

    // The links across the edge.
    var values_in: std.ArrayList(model.Link) = .empty;
    var values_out: std.ArrayList(model.Link) = .empty;
    var runs_in: std.ArrayList(model.Link) = .empty;
    var runs_out: std.ArrayList(model.Link) = .empty;
    for (f.links.items) |l| {
        const from_in = inside.contains(l.from.node);
        const to_in = inside.contains(l.to.node);
        if (from_in == to_in) continue;
        const run = try isRun(arena, f, nodes, l);
        const list = if (to_in) (if (run) &runs_in else &values_in) else (if (run) &runs_out else &values_out);
        try list.append(arena, l);
    }
    for (runs_in.items[@min(1, runs_in.items.len)..]) |l| if (!l.to.eql(runs_in.items[0].to)) return error.SeveralWaysIn;
    for (runs_out.items[@min(1, runs_out.items.len)..]) |l| if (!l.to.eql(runs_out.items[0].to)) return error.SeveralWaysOut;
    for (values_out.items[@min(1, values_out.items.len)..]) |l| if (!l.from.eql(values_out.items[0].from)) return error.SeveralResults;
    const pure = runs_in.items.len == 0 and runs_out.items.len == 0;

    // Its locals go with them, where the rest has none of them.
    var locals: std.ArrayList(model.Variable) = .empty;
    for (f.nodes.items) |n| {
        if (!isLocal(n.kind) or !inside.contains(n.id)) continue;
        for (f.nodes.items) |other| if (isLocal(other.kind) and !inside.contains(other.id) and std.mem.eql(u8, other.member, n.member)) return error.SharedLocal;
        for (f.locals.items) |l| if (std.mem.eql(u8, l.name, n.member) and !hasLocal(locals.items, l.name)) try locals.append(arena, l);
    }

    // A parameter for each pin a value comes in from.
    const Param = struct { from: End, name: []const u8, type: []const u8 };
    var params: std.ArrayList(Param) = .empty;
    for (values_in.items) |l| {
        if (paramOf(Param, params.items, l.from) != null) continue;
        const from = f.node(l.from.node).?;
        const pin = try catalog.pinOf(arena, f, nodes, from, l.from.pin, .output);
        var named = l.to.pin;
        var n: usize = 2;
        while (paramNamed(Param, params.items, named)) : (n += 1) named = try std.fmt.allocPrint(arena, "{s}_{d}", .{ l.to.pin, n });
        try params.append(arena, .{ .from = l.from, .name = named, .type = typeOf(pin) });
    }
    const result: ?End = if (values_out.items.len > 0) values_out.items[0].from else null;
    const result_type = if (result) |r| typeOf(try catalog.pinOf(arena, f, nodes, f.node(r.node).?, r.pin, .output)) else "";

    var lo: [2]f32 = .{ std.math.floatMax(f32), std.math.floatMax(f32) };
    var hi: [2]f32 = .{ -std.math.floatMax(f32), -std.math.floatMax(f32) };
    for (inside.keys()) |id| {
        const at = f.node(id).?.at;
        lo = .{ @min(lo[0], at[0]), @min(lo[1], at[1]) };
        hi = .{ @max(hi[0], at[0]), @max(hi[1], at[1]) };
    }

    // The function, its nodes where they were from its entry.
    const made_fn = try g.addFunction(name, .function);
    f = &g.file.functions.items[function];
    for (params.items) |p| try made_fn.params.append(gpa, .{ .name = try gpa.dupe(u8, p.name), .type = try gpa.dupe(u8, p.type) });
    made_fn.result = try gpa.dupe(u8, result_type);
    for (locals.items) |l| try g.addLocal(made_fn, l);
    const entry: u32 = 1;
    const shift: [2]f32 = .{ 240 - lo[0], -lo[1] };
    var moved: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (inside.keys()) |id| {
        const n = f.node(id).?;
        try moved.put(arena, id, try g.addCopy(made_fn, n, .{ n.at[0] + shift[0], n.at[1] + shift[1] }));
    }
    for (f.links.items) |l| {
        const from = moved.get(l.from.node) orelse continue;
        const to = moved.get(l.to.node) orelse continue;
        try g.connect(made_fn, .{ .node = from, .pin = l.from.pin }, .{ .node = to, .pin = l.to.pin });
    }
    if (runs_in.items.len > 0) try g.connect(made_fn, .{ .node = entry, .pin = compile.run_out }, .{ .node = moved.get(runs_in.items[0].to.node).?, .pin = runs_in.items[0].to.pin });
    for (values_in.items) |l| {
        const p = paramOf(Param, params.items, l.from).?;
        try g.connect(made_fn, .{ .node = entry, .pin = p.name }, .{ .node = moved.get(l.to.node).?, .pin = l.to.pin });
    }
    if (result) |r| {
        const back = try g.addNode(made_fn, "flow.return", .{ hi[0] + shift[0] + 280, 0 });
        try g.connect(made_fn, .{ .node = moved.get(r.node).?, .pin = r.pin }, .{ .node = back, .pin = "value" });
        if (pure) try g.connect(made_fn, .{ .node = entry, .pin = compile.run_out }, .{ .node = back, .pin = compile.run_in });
        for (runs_out.items) |l| try g.connect(made_fn, .{ .node = moved.get(l.from.node).?, .pin = l.from.pin }, .{ .node = back, .pin = compile.run_in });
    }

    // Its call, where they were.
    const call = try g.addNode(f, "call", lo);
    var args: std.ArrayList([]const u8) = .empty;
    for (made_fn.params.items) |p| try args.append(gpa, p.name);
    f.node(call).?.call = .{ .on = .self, .name = made_fn.name, .args = args, .gives = result != null, .action = !pure };
    for (runs_in.items) |l| connectOnce(g, f, l.from, .{ .node = call, .pin = compile.run_in }) catch |err| return err;
    if (runs_out.items.len > 0) try g.connect(f, .{ .node = call, .pin = compile.run_out }, runs_out.items[0].to);
    for (params.items) |p| try g.connect(f, p.from, .{ .node = call, .pin = p.name });
    for (values_out.items) |l| try g.connect(f, .{ .node = call, .pin = compile.result_pin }, l.to);
    for (inside.keys()) |id| _ = Graph.removeNode(f, id);
    for (locals.items) |l| {
        for (f.locals.items, 0..) |mine, i| if (std.mem.eql(u8, mine.name, l.name)) {
            _ = f.locals.orderedRemove(i);
            break;
        };
    }
    return call;
}

/// Two runs that came in from one pin come into the call once.
fn connectOnce(g: *Graph, f: *Function, from: End, to: End) Error!void {
    g.connect(f, from, to) catch |err| switch (err) {
        error.AlreadyLinked => {},
        else => return err,
    };
}

fn isRun(arena: Allocator, f: *const Function, nodes: *const catalog.Catalog, l: model.Link) Allocator.Error!bool {
    if (try catalog.pinOf(arena, f, nodes, f.node(l.from.node).?, l.from.pin, .output)) |p| return p.run;
    if (try catalog.pinOf(arena, f, nodes, f.node(l.to.node).?, l.to.pin, .input)) |p| return p.run;
    return false;
}

fn isLocal(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "local.get") or std.mem.eql(u8, kind, "local.set");
}

fn hasLocal(list: []const model.Variable, name: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l.name, name)) return true;
    return false;
}

fn typeOf(pin: ?catalog.Pin) []const u8 {
    const p = pin orelse return "any";
    return if (p.type.len > 0) p.type else "any";
}

fn paramOf(comptime Param: type, params: []const Param, from: End) ?Param {
    for (params) |p| if (p.from.eql(from)) return p;
    return null;
}

fn paramNamed(comptime Param: type, params: []const Param, name: []const u8) bool {
    for (params) |p| if (std.mem.eql(u8, p.name, name)) return true;
    return false;
}

const testing = std.testing;

fn none() @import("fluxion_script").service.Catalog {
    return .{ .types = &.{}, .globals = &.{}, .hooks = &.{}, .builtins = &.{}, .modules = &.{} };
}

test "nodes in the run are made a function: what comes in its parameters, what goes out its result, and its call where they were" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: Graph = try .init(testing.allocator);
    defer g.deinit();
    _ = try g.addVariable(.{ .name = "total", .type = "float" });
    const update = try g.addFunction("update", .event);
    try update.params.append(g.allocator(), .{ .name = "dt", .type = "float" });
    // total = total + dt * 2; print(total * 2); print("done")
    const set = try g.addNode(update, "var.set", .{ 300, 0 });
    update.node(set).?.member = "total";
    const add = try g.addNode(update, "math.add", .{ 200, 80 });
    const get = try g.addNode(update, "var.get", .{ 100, 80 });
    update.node(get).?.member = "total";
    const times = try g.addNode(update, "math.multiply", .{ 100, 160 });
    try g.setValue(update, times, "b", .{ .float = 2 });
    const say = try g.addNode(update, "flow.print", .{ 500, 0 });
    const doubled = try g.addNode(update, "math.multiply", .{ 400, 80 });
    try g.setValue(update, doubled, "b", .{ .float = 2 });
    const done = try g.addNode(update, "flow.print", .{ 700, 0 });
    try g.setValue(update, done, "value", .{ .string = "done" });
    try g.connect(update, .{ .node = 1, .pin = "then" }, .{ .node = set, .pin = "run" });
    try g.connect(update, .{ .node = add, .pin = "out" }, .{ .node = set, .pin = "value" });
    try g.connect(update, .{ .node = get, .pin = "out" }, .{ .node = add, .pin = "a" });
    try g.connect(update, .{ .node = times, .pin = "out" }, .{ .node = add, .pin = "b" });
    try g.connect(update, .{ .node = 1, .pin = "dt" }, .{ .node = times, .pin = "a" });
    try g.connect(update, .{ .node = set, .pin = "then" }, .{ .node = say, .pin = "run" });
    try g.connect(update, .{ .node = get, .pin = "out" }, .{ .node = doubled, .pin = "a" });
    try g.connect(update, .{ .node = doubled, .pin = "out" }, .{ .node = say, .pin = "value" });
    try g.connect(update, .{ .node = say, .pin = "then" }, .{ .node = done, .pin = "run" });
    const before = try compile.compile(arena, &g.file, .{});
    try testing.expectEqual(@as(usize, 0), before.problems.len);

    // The set and what feeds it; the total read goes on to be used outside.
    const nodes = try catalog.build(arena, none(), &g.file, .{});
    const call = try collapse(&g, arena, 0, &.{ 1, set, add, get, times }, "accumulate", &nodes);
    const after = try compile.compile(arena, &g.file, .{});
    try testing.expectEqual(@as(usize, 0), after.problems.len);
    try testing.expectEqualStrings(
        \\// Made from a graph by fluxion-graph: the graph is what to change.
        \\struct Graph {
        \\    var total: float;
        \\    fn update(self, dt: float) {
        \\        const n9 = self.accumulate(dt);
        \\        print((n9 * 2.0));
        \\        print("done");
        \\    }
        \\    fn accumulate(self, a: float) float {
        \\        self.total = (self.total + (a * 2.0));
        \\        return self.total;
        \\    }
        \\}
        \\
    , after.text);
    try testing.expectEqual(@as(u32, 9), call);
    try testing.expectEqual(@as(usize, 5), g.file.functions.items[0].nodes.items.len);
}

test "nodes no run goes into are an expression; what cannot be one function is said" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: Graph = try .init(testing.allocator);
    defer g.deinit();
    const ready = try g.addFunction("ready", .event);
    const say = try g.addNode(ready, "flow.print", .{ 300, 0 });
    const add = try g.addNode(ready, "math.add", .{ 100, 80 });
    try g.setValue(ready, add, "a", .{ .int = 1 });
    try g.setValue(ready, add, "b", .{ .int = 2 });
    const neg = try g.addNode(ready, "math.negate", .{ 200, 80 });
    try g.connect(ready, .{ .node = 1, .pin = "then" }, .{ .node = say, .pin = "run" });
    try g.connect(ready, .{ .node = add, .pin = "out" }, .{ .node = neg, .pin = "value" });
    try g.connect(ready, .{ .node = neg, .pin = "out" }, .{ .node = say, .pin = "value" });
    const other = try g.addNode(ready, "flow.print", .{ 300, 200 });
    try g.connect(ready, .{ .node = add, .pin = "out" }, .{ .node = other, .pin = "value" });

    const nodes = try catalog.build(arena, none(), &g.file, .{});
    try testing.expectError(error.Nothing, collapse(&g, arena, 0, &.{1}, "f", &nodes));
    try testing.expectError(error.SeveralResults, collapse(&g, arena, 0, &.{ add, neg }, "f", &nodes));
    try testing.expectError(error.NameTaken, collapse(&g, arena, 0, &.{neg}, "ready", &nodes));
    _ = try collapse(&g, arena, 0, &.{neg}, "flipped", &nodes);
    const made = try compile.compile(arena, &g.file, .{});
    try testing.expect(std.mem.indexOf(u8, made.text,
        \\        print(self.flipped((1 + 2)));
    ) != null);
    try testing.expect(std.mem.indexOf(u8, made.text,
        \\    fn flipped(self, value: any) any {
        \\        return (-value);
        \\    }
    ) != null);
}
