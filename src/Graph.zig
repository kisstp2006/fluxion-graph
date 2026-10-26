// SPDX-License-Identifier: BSD-2-Clause

//! A graph being read, changed and written: its `File`, and the memory all of
//! it lives in. What is taken out stays there till the graph goes - a graph
//! is a file's worth - so whatever an editor held of it, an undo step's
//! names, is still good.
//!
//! ```zig
//! var graph: Graph = try .read(gpa, bytes, null);
//! defer graph.deinit();
//! const update = try graph.addFunction("update", .event);
//! const turn = try graph.addNode(update, "call:Transform2D.rotate", .{ 240, 0 });
//! try graph.connect(update, .{ .node = model.entry_id, .pin = "then" }, .{ .node = turn, .pin = "run" });
//! const text = try graph.write(gpa);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("fluxion_json");

const model = @import("model.zig");
const File = model.File;
const Function = model.Function;
const Node = model.Node;
const Link = model.Link;
const End = model.End;

const Graph = @This();

arena: *std.heap.ArenaAllocator,
file: File,

pub const ReadError = json.Error || CheckError || error{
    /// JSON, and no graph: it does not say `fluxion_graph`.
    NotAGraph,
    /// A graph a newer version of the format wrote.
    NewerVersion,
};

pub const CheckError = error{
    /// Two of the struct's variables, signals and functions are called the
    /// same.
    NameTaken,
    /// Two nodes of a function have one id, or one has an id its function
    /// has not given yet.
    BadNodeId,
    /// A function has no entry node, or more than one.
    BadEntry,
    /// A link names a node its function has not got, or is there twice.
    BadLink,
};

/// An empty graph: a struct with nothing in it.
pub fn init(gpa: Allocator) Allocator.Error!Graph {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    return .{ .arena = arena, .file = .{ .fluxion_graph = model.version } };
}

/// The graph `bytes` say, JSON or CBOR. A file that does not hang together
/// - see `CheckError` - is refused, not mended.
pub fn read(gpa: Allocator, bytes: []const u8, diagnostics: ?*json.Diagnostics) ReadError!Graph {
    const parsed = try json.parseAs(File, gpa, bytes, .{ .diagnostics = diagnostics });
    const graph: Graph = .{ .arena = parsed.arena, .file = parsed.value };
    errdefer graph.deinit();
    if (graph.file.fluxion_graph == 0) return error.NotAGraph;
    if (graph.file.fluxion_graph > model.version) return error.NewerVersion;
    try graph.check();
    return graph;
}

pub fn deinit(self: Graph) void {
    const gpa = self.arena.child_allocator;
    self.arena.deinit();
    gpa.destroy(self.arena);
}

/// The graph as its file says it, `gpa`'s: the same graph is the same text,
/// so a file is written again only when it changed.
pub fn write(self: *const Graph, gpa: Allocator) json.StringifyError![]u8 {
    return json.stringify(gpa, self.file, .{ .indent = 2 });
}

pub fn allocator(self: *const Graph) Allocator {
    return self.arena.allocator();
}

/// Whether it hangs together: see `CheckError`.
pub fn check(self: *const Graph) CheckError!void {
    const file = &self.file;
    for (file.imports.items, 0..) |m, i| {
        for (file.imports.items[i + 1 ..]) |other| if (std.mem.eql(u8, other.name, m.name)) return error.NameTaken;
        if (self.taken(m.name)) return error.NameTaken;
    }
    for (file.variables.items, 0..) |v, i| try self.unique(v.name, .{ .variable = i });
    for (file.signals.items, 0..) |s, i| try self.unique(s.name, .{ .signal = i });
    for (file.functions.items, 0..) |*f, i| {
        try self.unique(f.name, .{ .function = i });
        var entries: usize = 0;
        for (f.nodes.items, 0..) |n, at| {
            if (n.id == 0 or n.id >= f.next_id) return error.BadNodeId;
            for (f.nodes.items[at + 1 ..]) |other| if (other.id == n.id) return error.BadNodeId;
            if (std.mem.eql(u8, n.kind, model.entry_kind)) entries += 1;
        }
        if (entries != 1) return error.BadEntry;
        for (f.links.items, 0..) |l, at| {
            if (f.node(l.from.node) == null or f.node(l.to.node) == null) return error.BadLink;
            for (f.links.items[at + 1 ..]) |other| if (other.eql(l)) return error.BadLink;
        }
    }
}

const Place = union(enum) { variable: usize, signal: usize, function: usize };

/// Whether `name` is the one at `place` alone: a struct's fields, signals
/// and methods are one set of names.
fn unique(self: *const Graph, name: []const u8, place: Place) CheckError!void {
    const file = &self.file;
    for (file.variables.items, 0..) |v, i| if (!std.meta.eql(place, Place{ .variable = i }) and std.mem.eql(u8, v.name, name)) return error.NameTaken;
    for (file.signals.items, 0..) |s, i| if (!std.meta.eql(place, Place{ .signal = i }) and std.mem.eql(u8, s.name, name)) return error.NameTaken;
    for (file.functions.items, 0..) |f, i| if (!std.meta.eql(place, Place{ .function = i }) and std.mem.eql(u8, f.name, name)) return error.NameTaken;
}

fn taken(self: *const Graph, name: []const u8) bool {
    const file = &self.file;
    for (file.variables.items) |v| if (std.mem.eql(u8, v.name, name)) return true;
    for (file.signals.items) |s| if (std.mem.eql(u8, s.name, name)) return true;
    for (file.functions.items) |f| if (std.mem.eql(u8, f.name, name)) return true;
    return false;
}

pub const EditError = json.EditError || error{NameTaken};

// -------------------------------------------------------------------------
// The struct
// -------------------------------------------------------------------------

pub fn function(self: *const Graph, name: []const u8) ?*Function {
    for (self.file.functions.items) |*f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

/// A function with only its entry node, given the first id.
pub fn addFunction(self: *Graph, name: []const u8, kind: Function.Kind) EditError!*Function {
    if (self.taken(name)) return error.NameTaken;
    const gpa = self.allocator();
    const made = try self.file.functions.addOne(gpa);
    made.* = .{ .name = try gpa.dupe(u8, name), .kind = kind };
    _ = try self.addNode(made, model.entry_kind, .{ 0, 0 });
    return made;
}

/// A file the graph uses, by the name its calls give it.
pub fn addImport(self: *Graph, name: []const u8, path: []const u8) EditError!void {
    if (self.taken(name)) return error.NameTaken;
    for (self.file.imports.items) |m| if (std.mem.eql(u8, m.name, name)) return error.NameTaken;
    const gpa = self.allocator();
    try self.file.imports.append(gpa, .{ .name = try gpa.dupe(u8, name), .path = try gpa.dupe(u8, path) });
}

pub fn removeFunction(self: *Graph, name: []const u8) bool {
    for (self.file.functions.items, 0..) |f, at| {
        if (!std.mem.eql(u8, f.name, name)) continue;
        _ = self.file.functions.orderedRemove(at);
        return true;
    }
    return false;
}

/// A variable of the struct: `variable`'s words are copied.
pub fn addVariable(self: *Graph, variable: model.Variable) EditError!*model.Variable {
    if (self.taken(variable.name)) return error.NameTaken;
    const gpa = self.allocator();
    const made = try self.file.variables.addOne(gpa);
    made.* = variable;
    made.name = try gpa.dupe(u8, variable.name);
    made.type = try gpa.dupe(u8, variable.type);
    made.doc = try gpa.dupe(u8, variable.doc);
    made.default = try self.clone(variable.default);
    made.annotations = .empty;
    for (variable.annotations.items) |a| {
        var args: std.ArrayList(json.Value) = .empty;
        for (a.args.items) |arg| try args.append(gpa, try self.clone(arg));
        try made.annotations.append(gpa, .{ .name = try gpa.dupe(u8, a.name), .args = args });
    }
    return made;
}

/// A variable of `f`'s own: `variable`'s words are copied. A name its
/// parameters or its other locals have is taken.
pub fn addLocal(self: *Graph, f: *Function, variable: model.Variable) EditError!void {
    for (f.params.items) |p| if (std.mem.eql(u8, p.name, variable.name)) return error.NameTaken;
    for (f.locals.items) |l| if (std.mem.eql(u8, l.name, variable.name)) return error.NameTaken;
    const gpa = self.allocator();
    try f.locals.append(gpa, .{ .name = try gpa.dupe(u8, variable.name), .type = try gpa.dupe(u8, variable.type), .default = try self.clone(variable.default) });
}

/// A signal of the struct's own, with `params`.
pub fn addSignal(self: *Graph, name: []const u8, params: []const model.Param) EditError!*model.Signal {
    if (self.taken(name)) return error.NameTaken;
    const gpa = self.allocator();
    const made = try self.file.signals.addOne(gpa);
    made.* = .{ .name = try gpa.dupe(u8, name) };
    for (params) |p| try made.params.append(gpa, .{ .name = try gpa.dupe(u8, p.name), .type = try gpa.dupe(u8, p.type) });
    return made;
}

// -------------------------------------------------------------------------
// A function's nodes and links
// -------------------------------------------------------------------------

/// A node of `kind` at `at`, given an id its function never gave before.
pub fn addNode(self: *Graph, f: *Function, kind: []const u8, at: [2]f32) Allocator.Error!u32 {
    const gpa = self.allocator();
    const id = f.next_id;
    try f.nodes.append(gpa, .{ .id = id, .kind = try gpa.dupe(u8, kind), .at = at });
    f.next_id += 1;
    return id;
}

/// Take a node out, and its links with it. The entry stays: false for it,
/// and for a node that is not there.
pub fn removeNode(f: *Function, id: u32) bool {
    for (f.nodes.items, 0..) |n, at| {
        if (n.id != id) continue;
        if (std.mem.eql(u8, n.kind, model.entry_kind)) return false;
        _ = f.nodes.orderedRemove(at);
        var i: usize = 0;
        while (i < f.links.items.len) {
            const l = f.links.items[i];
            if (l.from.node == id or l.to.node == id) _ = f.links.orderedRemove(i) else i += 1;
        }
        return true;
    }
    return false;
}

pub const LinkError = Allocator.Error || error{
    /// One of its ends is a node the function has not got.
    NoSuchNode,
    /// The two are linked already.
    AlreadyLinked,
    /// From a node to itself.
    ToItself,
};

/// Link an output pin to an input pin. Which pins a node has, and what may
/// go into what, is the catalog's to say: see `check`.
pub fn connect(self: *Graph, f: *Function, from: End, to: End) LinkError!void {
    if (f.node(from.node) == null or f.node(to.node) == null) return error.NoSuchNode;
    if (from.node == to.node) return error.ToItself;
    const made: Link = .{ .from = from, .to = to };
    for (f.links.items) |l| if (l.eql(made)) return error.AlreadyLinked;
    const gpa = self.allocator();
    try f.links.append(gpa, .{
        .from = .{ .node = from.node, .pin = try gpa.dupe(u8, from.pin) },
        .to = .{ .node = to.node, .pin = try gpa.dupe(u8, to.pin) },
    });
}

/// Take a link out: false for one that is not there.
pub fn disconnect(f: *Function, link: Link) bool {
    for (f.links.items, 0..) |l, at| {
        if (!l.eql(link)) continue;
        _ = f.links.orderedRemove(at);
        return true;
    }
    return false;
}

/// What the input `pin` of node `id` is given while no link feeds it: a
/// copy of `value`, in place of what it was given before.
pub fn setValue(self: *Graph, f: *Function, id: u32, pin: []const u8, value: json.Value) (json.EditError || error{NoSuchNode})!void {
    const n = f.node(id) orelse return error.NoSuchNode;
    const kept = try self.clone(value);
    for (n.values.items) |*v| if (std.mem.eql(u8, v.pin, pin)) {
        v.value = kept;
        return;
    };
    const gpa = self.allocator();
    try n.values.append(gpa, .{ .pin = try gpa.dupe(u8, pin), .value = kept });
}

/// What `pin` was given let go of: false where it was given nothing.
pub fn clearValue(f: *Function, id: u32, pin: []const u8) bool {
    const n = f.node(id) orelse return false;
    for (n.values.items, 0..) |v, at| if (std.mem.eql(u8, v.pin, pin)) {
        _ = n.values.orderedRemove(at);
        return true;
    };
    return false;
}

/// `value`, however deep, in the graph's memory.
fn clone(self: *Graph, value: json.Value) json.EditError!json.Value {
    const doc: json.Document = .{ .arena = self.arena };
    return doc.clone(value);
}

const testing = std.testing;

/// The graph of a door that turns while it is open, in a few lines.
fn door(gpa: Allocator) !Graph {
    var graph: Graph = try .init(gpa);
    errdefer graph.deinit();
    graph.file.name = "Door";
    _ = try graph.addVariable(.{ .name = "speed", .type = "float", .default = .{ .float = 2 }, .exported = true });
    _ = try graph.addSignal("opened", &.{.{ .name = "by", .type = "Entity" }});
    const update = try graph.addFunction("update", .event);
    try update.params.append(graph.allocator(), .{ .name = "dt", .type = "float" });
    const turn = try graph.addNode(update, "call:Transform2D.rotate", .{ 240, 0 });
    const times = try graph.addNode(update, "math.multiply", .{ 120, 80 });
    try graph.connect(update, .{ .node = 1, .pin = "then" }, .{ .node = turn, .pin = "run" });
    try graph.connect(update, .{ .node = times, .pin = "out" }, .{ .node = turn, .pin = "by" });
    try graph.setValue(update, times, "b", .{ .float = 0.5 });
    return graph;
}

test "a graph written and read back is the same graph, written the same" {
    var graph = try door(testing.allocator);
    defer graph.deinit();
    const text = try graph.write(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "{\n  \"fluxion_graph\": 1,"));

    var again: Graph = try .read(testing.allocator, text, null);
    defer again.deinit();
    const update = again.function("update").?;
    try testing.expectEqual(Function.Kind.event, update.kind);
    try testing.expectEqual(@as(usize, 3), update.nodes.items.len);
    try testing.expectEqual(@as(usize, 2), update.links.items.len);
    try testing.expectEqual(@as(f64, 0.5), update.node(3).?.valueOf("b").?.float);
    try testing.expect(again.file.variables.items[0].exported);
    const written = try again.write(testing.allocator);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(text, written);
}

test "what is no graph, a newer one, and one that does not hang together are refused" {
    try testing.expectError(error.NotAGraph, Graph.read(testing.allocator, "{}", null));
    try testing.expectError(error.NewerVersion, Graph.read(testing.allocator, "{ \"fluxion_graph\": 99 }", null));
    const entry = "{ \"id\": 1, \"kind\": \"entry\" }";
    try testing.expectError(error.BadNodeId, Graph.read(testing.allocator, "{ \"fluxion_graph\": 1, \"functions\": [ { \"name\": \"f\", \"next_id\": 2, \"nodes\": [ " ++ entry ++ ", " ++ entry ++ " ] } ] }", null));
    try testing.expectError(error.BadEntry, Graph.read(testing.allocator, "{ \"fluxion_graph\": 1, \"functions\": [ { \"name\": \"f\" } ] }", null));
    try testing.expectError(error.BadLink, Graph.read(testing.allocator, "{ \"fluxion_graph\": 1, \"functions\": [ { \"name\": \"f\", \"next_id\": 2, \"nodes\": [ " ++ entry ++ " ], \"links\": [ { \"from\": { \"node\": 1, \"pin\": \"then\" }, \"to\": { \"node\": 7, \"pin\": \"run\" } } ] } ] }", null));
    try testing.expectError(error.NameTaken, Graph.read(testing.allocator, "{ \"fluxion_graph\": 1, \"variables\": [ { \"name\": \"f\", \"type\": \"int\" } ], \"signals\": [ { \"name\": \"f\" } ] }", null));
}

test "a node taken out takes its links with it, its id is not given again, and the entry stays" {
    var graph = try door(testing.allocator);
    defer graph.deinit();
    const update = graph.function("update").?;
    try testing.expect(removeNode(update, 3));
    try testing.expectEqual(@as(usize, 1), update.links.items.len);
    try testing.expectEqual(@as(u32, 4), try graph.addNode(update, "flow.branch", .{ 0, 0 }));
    try testing.expect(!removeNode(update, 1));
    try testing.expect(!removeNode(update, 3));
}

test "a link needs both its nodes, two of them, and is made once; a pin's value is replaced and let go of" {
    var graph = try door(testing.allocator);
    defer graph.deinit();
    const update = graph.function("update").?;
    try testing.expectError(error.NoSuchNode, graph.connect(update, .{ .node = 9, .pin = "out" }, .{ .node = 2, .pin = "by" }));
    try testing.expectError(error.ToItself, graph.connect(update, .{ .node = 2, .pin = "then" }, .{ .node = 2, .pin = "run" }));
    try testing.expectError(error.AlreadyLinked, graph.connect(update, .{ .node = 1, .pin = "then" }, .{ .node = 2, .pin = "run" }));
    try testing.expect(disconnect(update, .{ .from = .{ .node = 1, .pin = "then" }, .to = .{ .node = 2, .pin = "run" } }));
    try testing.expectEqual(@as(usize, 1), update.links.items.len);

    try graph.setValue(update, 3, "b", .{ .int = 4 });
    try testing.expectEqual(@as(i64, 4), update.node(3).?.valueOf("b").?.int);
    try testing.expectEqual(@as(usize, 1), update.node(3).?.values.items.len);
    try testing.expect(clearValue(update, 3, "b"));
    try testing.expect(update.node(3).?.valueOf("b") == null);
}

test "a name is the struct's once, whatever it names" {
    var graph = try door(testing.allocator);
    defer graph.deinit();
    try testing.expectError(error.NameTaken, graph.addFunction("speed", .function));
    try testing.expectError(error.NameTaken, graph.addSignal("update", &.{}));
    try testing.expectError(error.NameTaken, graph.addVariable(.{ .name = "opened", .type = "int" }));
    try testing.expect(graph.removeFunction("update"));
    _ = try graph.addSignal("update", &.{});
}
