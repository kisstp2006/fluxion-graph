// SPDX-License-Identifier: BSD-2-Clause

//! Where a graph's nodes and pins are, in the canvas's own units: a node's
//! size from its pins and the width of its words, each pin's point on its
//! edge, what is under a point, and the curve a link draws. Arithmetic only,
//! so the view draws and the pointer finds the same places.

const std = @import("std");
const Allocator = std.mem.Allocator;
const graph = @import("fluxion_graph");
const model = graph.model;
const catalog = graph.catalog;

pub const Point = [2]f32;

/// How big things are at a zoom of one, and how words are measured.
pub const Metrics = struct {
    font_size: f32 = 13,
    header: f32 = 26,
    row: f32 = 22,
    /// A pin's dot, across.
    pin: f32 = 10,
    pad: f32 = 10,
    /// The room between an input's words and an output's.
    middle: f32 = 24,
    min_width: f32 = 110,
    measure: Measure = .{},
};

/// How wide words are at a font size: the interface's measurer, or an
/// average character's width where there is none.
pub const Measure = struct {
    context: ?*const anyopaque = null,
    width: ?*const fn (context: ?*const anyopaque, text: []const u8, font_size: f32) f32 = null,

    pub fn of(self: Measure, text: []const u8, font_size: f32) f32 {
        if (self.width) |w| return w(self.context, text, font_size);
        return @as(f32, @floatFromInt(text.len)) * font_size * 0.55;
    }
};

/// A node as it is drawn: its words and its pins, from its entry in the
/// catalog - or, for one the catalog does not know, from its links.
pub const Shape = struct {
    title: []const u8,
    category: []const u8 = "",
    inputs: []const catalog.Pin,
    outputs: []const catalog.Pin,
    known: bool = true,
};

pub fn shapeOf(arena: Allocator, f: *const model.Function, nodes: *const catalog.Catalog, n: *const model.Node) Allocator.Error!Shape {
    if (std.mem.eql(u8, n.kind, model.entry_kind)) {
        const outputs = try arena.alloc(catalog.Pin, f.params.items.len + 1);
        outputs[0] = .{ .name = graph.compile.run_out, .run = true };
        for (f.params.items, outputs[1..]) |p, *pin| pin.* = .{ .name = p.name, .type = p.type };
        return .{ .title = f.name, .category = if (f.kind == .event) "Events" else "Functions", .inputs = &.{}, .outputs = outputs };
    }
    if (nodes.find(try catalog.keyOf(arena, n))) |e| {
        var shape: Shape = .{ .title = e.title, .category = e.category, .inputs = e.inputs, .outputs = e.outputs };
        // Pins the node says itself: a switch's cases, a text's values.
        if (std.mem.eql(u8, n.kind, "flow.switch")) if (n.call) |call| {
            const outputs = try arena.alloc(catalog.Pin, call.args.items.len + e.outputs.len);
            for (call.args.items, 0..) |_, i| outputs[i] = .{ .name = try std.fmt.allocPrint(arena, "case_{d}", .{i}), .run = true };
            @memcpy(outputs[call.args.items.len..], e.outputs);
            shape.outputs = outputs;
        };
        if (std.mem.eql(u8, n.kind, "make.text")) {
            const names = try graph.compile.textPins(arena, n.member);
            const inputs = try arena.alloc(catalog.Pin, names.len);
            for (names, inputs) |name, *pin| pin.* = .{ .name = name };
            shape.inputs = inputs;
        }
        return shape;
    }
    // Not known now: its pins as its links and values name them, so what it
    // was is still seen, and can be taken out.
    var inputs: std.ArrayList(catalog.Pin) = .empty;
    var outputs: std.ArrayList(catalog.Pin) = .empty;
    for (f.links.items) |l| {
        if (l.to.node == n.id and !has(inputs.items, l.to.pin)) try inputs.append(arena, .{ .name = l.to.pin });
        if (l.from.node == n.id and !has(outputs.items, l.from.pin)) try outputs.append(arena, .{ .name = l.from.pin });
    }
    for (n.values.items) |v| if (!has(inputs.items, v.pin)) try inputs.append(arena, .{ .name = v.pin });
    return .{ .title = try catalog.keyOf(arena, n), .inputs = inputs.items, .outputs = outputs.items, .known = false };
}

fn has(pins: []const catalog.Pin, name: []const u8) bool {
    for (pins) |p| if (std.mem.eql(u8, p.name, name)) return true;
    return false;
}

/// A pin's label: its name, but a run's `run` and `then`, which say nothing
/// the dot does not.
pub fn label(pin: catalog.Pin) []const u8 {
    if (pin.run and (std.mem.eql(u8, pin.name, graph.compile.run_in) or std.mem.eql(u8, pin.name, graph.compile.run_out))) return "";
    return pin.name;
}

/// Its width and height.
pub fn size(shape: Shape, m: Metrics) Point {
    const small = m.font_size * 0.9;
    var widest_in: f32 = 0;
    var widest_out: f32 = 0;
    for (shape.inputs) |p| widest_in = @max(widest_in, m.measure.of(label(p), small));
    for (shape.outputs) |p| widest_out = @max(widest_out, m.measure.of(label(p), small));
    const rows: f32 = @floatFromInt(@max(shape.inputs.len, shape.outputs.len));
    const body = 2 * m.pad + 2 * m.pin + widest_in + widest_out + m.middle;
    const title = 2 * m.pad + m.measure.of(shape.title, m.font_size);
    return .{ @max(m.min_width, body, title), m.header + rows * m.row + m.pad * 0.5 };
}

pub const Side = enum { input, output };

/// Where the pin `index` of `side` is, on a node at `at` of `node_size`.
pub fn pinPoint(at: Point, node_size: Point, side: Side, index: usize, m: Metrics) Point {
    const y = at[1] + m.header + (@as(f32, @floatFromInt(index)) + 0.5) * m.row;
    return .{ if (side == .input) at[0] else at[0] + node_size[0], y };
}

pub fn indexOf(pins: []const catalog.Pin, name: []const u8) ?usize {
    for (pins, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return i;
    return null;
}

/// What is at a point of the canvas.
pub const Hit = union(enum) {
    none,
    node: u32,
    pin: Pin,

    pub const Pin = struct { node: u32, side: Side, index: usize, name: []const u8, run: bool, type: []const u8 };
};

/// A node, laid out: what `hit` and the view go by.
pub const Placed = struct {
    node: *const model.Node,
    shape: Shape,
    size: Point,

    pub fn contains(self: Placed, p: Point) bool {
        const at = self.node.at;
        return p[0] >= at[0] and p[0] < at[0] + self.size[0] and p[1] >= at[1] and p[1] < at[1] + self.size[1];
    }

    pub fn pin(self: Placed, side: Side, name: []const u8, m: Metrics) ?Point {
        const pins = if (side == .input) self.shape.inputs else self.shape.outputs;
        const index = indexOf(pins, name) orelse return null;
        return pinPoint(self.node.at, self.size, side, index, m);
    }
};

/// Every node of `f`, laid out, in the order drawn: the last on top.
pub fn place(arena: Allocator, f: *const model.Function, nodes: *const catalog.Catalog, m: Metrics) Allocator.Error![]Placed {
    const out = try arena.alloc(Placed, f.nodes.items.len);
    for (f.nodes.items, out) |*n, *p| {
        const shape = try shapeOf(arena, f, nodes, n);
        p.* = .{ .node = n, .shape = shape, .size = size(shape, m) };
    }
    return out;
}

pub fn find(placed: []const Placed, id: u32) ?Placed {
    for (placed) |p| if (p.node.id == id) return p;
    return null;
}

/// The pin or the node at `p`, the topmost first: a pin a little past its
/// node's edge too, so its dot is easy to hit.
pub fn hit(placed: []const Placed, p: Point, m: Metrics) Hit {
    var at = placed.len;
    const reach = m.row * 0.5;
    while (at > 0) {
        at -= 1;
        const one = placed[at];
        inline for (.{ Side.input, Side.output }) |side| {
            const pins = if (side == .input) one.shape.inputs else one.shape.outputs;
            for (pins, 0..) |pin, i| {
                const point = pinPoint(one.node.at, one.size, side, i, m);
                if (@abs(p[0] - point[0]) <= reach and @abs(p[1] - point[1]) <= reach) return .{ .pin = .{ .node = one.node.id, .side = side, .index = i, .name = pin.name, .run = pin.run, .type = pin.type } };
            }
        }
        if (one.contains(p)) return .{ .node = one.node.id };
    }
    return .none;
}

/// The nodes inside the box from `a` to `b`, either way round.
pub fn inside(placed: []const Placed, a: Point, b: Point, into: *std.ArrayList(u32), gpa: Allocator) Allocator.Error!void {
    const lo: Point = .{ @min(a[0], b[0]), @min(a[1], b[1]) };
    const hi: Point = .{ @max(a[0], b[0]), @max(a[1], b[1]) };
    for (placed) |one| {
        const at = one.node.at;
        if (at[0] < hi[0] and at[0] + one.size[0] > lo[0] and at[1] < hi[1] and at[1] + one.size[1] > lo[1]) try into.append(gpa, one.node.id);
    }
}

/// The points along the curve from an output at `from` to an input at
/// `to`: leaving and coming in level, as wires hang.
pub fn curve(from: Point, to: Point, into: []Point) []Point {
    const reach = @max(40, @abs(to[0] - from[0]) * 0.5);
    const c1: Point = .{ from[0] + reach, from[1] };
    const c2: Point = .{ to[0] - reach, to[1] };
    const n = into.len - 1;
    for (into, 0..) |*p, i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const u = 1 - t;
        const a = u * u * u;
        const b = 3 * u * u * t;
        const c = 3 * u * t * t;
        const d = t * t * t;
        p.* = .{ a * from[0] + b * c1[0] + c * c2[0] + d * to[0], a * from[1] + b * c1[1] + c * c2[1] + d * to[1] };
    }
    return into;
}

/// The box round every node, for showing them all.
pub fn bounds(placed: []const Placed) ?[2]Point {
    if (placed.len == 0) return null;
    var lo: Point = .{ std.math.floatMax(f32), std.math.floatMax(f32) };
    var hi: Point = .{ -std.math.floatMax(f32), -std.math.floatMax(f32) };
    for (placed) |one| {
        lo = .{ @min(lo[0], one.node.at[0]), @min(lo[1], one.node.at[1]) };
        hi = .{ @max(hi[0], one.node.at[0] + one.size[0]), @max(hi[1], one.node.at[1] + one.size[1]) };
    }
    return .{ lo, hi };
}

const testing = std.testing;

test "a node is as big as its pins and words, a pin is on its edge, and a point finds the pin before the node" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var g: graph.Graph = try .init(testing.allocator);
    defer g.deinit();
    const update = try g.addFunction("update", .event);
    try update.params.append(g.allocator(), .{ .name = "dt", .type = "float" });
    const add = try g.addNode(update, "math.add", .{ 300, 100 });
    // A catalog with only what the compiler knows.
    const service = @import("fluxion_script").service;
    const none: service.Catalog = .{ .types = &.{}, .globals = &.{}, .hooks = &.{}, .builtins = &.{}, .modules = &.{} };
    const b = try catalog.build(arena, none, &g.file, .{});

    const m: Metrics = .{};
    const placed = try place(arena, update, &b, m);
    const entry = find(placed, 1).?;
    try testing.expectEqual(@as(usize, 2), entry.shape.outputs.len);
    const sum = find(placed, add).?;
    try testing.expect(sum.size[0] >= m.min_width);
    try testing.expectEqual(@as(f32, 2 * m.row + m.header + m.pad * 0.5), sum.size[1]);
    const a = sum.pin(.input, "a", m).?;
    try testing.expectEqual(@as(f32, 300), a[0]);
    try testing.expectEqual(@as(f32, 100 + m.header + m.row * 0.5), a[1]);
    const out = sum.pin(.output, "out", m).?;
    try testing.expectEqual(300 + sum.size[0], out[0]);

    try testing.expectEqualStrings("a", hit(placed, .{ a[0] - 3, a[1] + 2 }, m).pin.name);
    try testing.expectEqual(add, hit(placed, .{ 300 + 40, 100 + 5 }, m).node);
    try testing.expect(hit(placed, .{ -500, -500 }, m) == .none);

    var picked: std.ArrayList(u32) = .empty;
    defer picked.deinit(testing.allocator);
    try inside(placed, .{ 250, 50 }, .{ 900, 400 }, &picked, testing.allocator);
    try testing.expectEqualSlices(u32, &.{add}, picked.items);
}

test "a link's curve leaves its output and comes into its input level" {
    var points: [9]Point = undefined;
    const c = curve(.{ 0, 0 }, .{ 200, 100 }, &points);
    try testing.expectEqual(Point{ 0, 0 }, c[0]);
    try testing.expectEqual(Point{ 200, 100 }, c[8]);
    try testing.expectApproxEqAbs(@as(f32, 0), c[1][1], 6);
    try testing.expectApproxEqAbs(@as(f32, 100), c[7][1], 6);
}
