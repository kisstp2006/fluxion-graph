// SPDX-License-Identifier: BSD-2-Clause

//! A function's graph drawn with fluxion-ui, and what the pointer and the
//! keys do to it.
//!
//! On a canvas with a grid, each node is a box: its header coloured by what
//! it does, its inputs down the left and its outputs down the right, each a
//! dot coloured by its type - the run white - and what an input no link
//! feeds is given beside its name. A link hangs from an output to an input,
//! in its output's colour. Nodes and links float over the canvas, cut off at
//! its edge.
//!
//! - The wheel goes nearer and farther, about the pointer; the middle button,
//!   or Alt and the left, moves the canvas.
//! - A press on a node picks it - with Shift, adds it or takes it out - and a
//!   drag moves what is picked.
//! - A drag from a pin draws a link: let go on another pin it is made, if the
//!   two fit; let go on nothing, it asks for a node to make there
//!   (`Outcome.choose`). A drag from an input a link feeds takes that link off
//!   its input, to be put elsewhere or let go of.
//! - A drag on nothing picks what is in its box; a second press there, or the
//!   right button, asks for a node.
//! - Delete takes out what is picked, but the entry; Ctrl+A picks all; F shows
//!   all.
//!
//! What a node is given on a pin, and which node to make, are the program's
//! to ask: the view says when (`Outcome`), and the graph is changed only by
//! `fluxion_graph.Graph`'s own calls - one step to undo each `Outcome` that
//! says `changed`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui_lib = @import("fluxion_ui");
const Ui = ui_lib.Ui;
const graph = @import("fluxion_graph");
const model = graph.model;
const catalog = graph.catalog;
const Graph = graph.Graph;

const layout = @import("layout.zig");
const Canvas = @import("Canvas.zig");
const Theme = @import("Theme.zig");
const Point = layout.Point;

const View = @This();

ids: Ids = .{},
theme: *const Theme = &Theme.dark,
metrics: layout.Metrics = .{},
/// The interface's font for the words, as an index into its measurer's
/// table.
font: u16 = 0,

pub const Ids = struct {
    canvas: []const u8 = "graph-canvas",
};

/// What the pointer or a key did that the program has to know of.
pub const Outcome = struct {
    /// The graph changed: one step to undo, and a file to write.
    changed: bool = false,
    /// Which nodes are picked changed: what an inspector shows.
    picked: bool = false,
    /// Asked for a node to be made here.
    choose: ?Choose = null,
};

pub const Choose = struct {
    /// Where it goes, on the canvas.
    at: Point,
    /// The pin a link was drawn from, to link the new node to.
    from: ?layout.Hit.Pin = null,
};

pub const Pointer = struct {
    /// On the surface, as the interface's boxes are.
    x: f32,
    y: f32,
    down: bool,
    pressed: bool,
    /// The right button, pressed this frame.
    secondary: bool = false,
    /// The middle button, held.
    middle: bool = false,
    /// How far the wheel turned this frame: up is nearer.
    wheel: f32 = 0,
    shift: bool = false,
    alt: bool = false,
    /// Seconds, on any clock that goes on: what tells a second press.
    now: f64 = 0,
};

pub const Key = enum { delete, select_all, frame_all };

/// Where the view is, from last frame's layout: call after the frame is laid
/// out.
pub fn measure(v: View, canvas: *Canvas, ui: *Ui) void {
    const box = ui.boxOf(v.ids.canvas) orelse return;
    canvas.view = .{ box.x, box.y, box.width, box.height };
}

// ---------------------------------------------------------------------------
// Drawing

pub fn draw(v: View, canvas: *const Canvas, ui: *Ui, arena: Allocator, f: *const model.Function, nodes: *const catalog.Catalog) Allocator.Error!void {
    ui.open(.{
        .id = v.ids.canvas,
        .width = .grow,
        .height = .grow,
        .background_color = v.theme.canvas,
        .clip = .both,
        .cursor = if (canvas.drag == .pan or canvas.drag == .move) .resize_all else null,
    });
    defer ui.close();
    v.grid(canvas, ui);
    const placed = try layout.place(arena, f, nodes, v.metrics);
    for (f.links.items) |l| {
        const from = layout.find(placed, l.from.node) orelse continue;
        const to = layout.find(placed, l.to.node) orelse continue;
        const a = from.pin(.output, l.from.pin, v.metrics) orelse continue;
        const b = to.pin(.input, l.to.pin, v.metrics) orelse continue;
        const pin = from.shape.outputs[layout.indexOf(from.shape.outputs, l.from.pin).?];
        v.wire(canvas, ui, canvas.toView(a), canvas.toView(b), v.theme.pinColor(pin.type, pin.run));
    }
    if (canvas.drag == .link) {
        const held = canvas.drag.link;
        if (layout.find(placed, held.node)) |one| if (one.pin(held.side, held.name, v.metrics)) |start| {
            const a = canvas.toView(start);
            const color = v.theme.pinColor(held.type, held.run);
            if (held.side == .output) v.wire(canvas, ui, a, canvas.pointer, color) else v.wire(canvas, ui, canvas.pointer, a, color);
        };
    }
    for (placed) |one| try v.node(canvas, ui, arena, f, one);
    if (canvas.drag == .box) {
        const box = canvas.drag.box;
        const a = canvas.toView(box.from);
        const b = canvas.toView(box.to);
        ui.empty(.{
            .floating = .{ .offset = .{ .x = @min(a[0], b[0]), .y = @min(a[1], b[1]) }, .z_index = 6, .clip = .target },
            .width = .fixed(@abs(b[0] - a[0])),
            .height = .fixed(@abs(b[1] - a[1])),
            .background_color = v.theme.box,
            .border = .all(v.theme.box_border, 1),
        });
    }
}

fn grid(v: View, canvas: *const Canvas, ui: *Ui) void {
    const w = canvas.view[2];
    const h = canvas.view[3];
    const step = 24 * canvas.zoom;
    if (step < 6 or w <= 0 or h <= 0) return;
    // Every fifth line stronger; counted from the canvas's nought.
    const first_x = @floor(-canvas.pan[0] / step);
    const first_y = @floor(-canvas.pan[1] / step);
    var i: f32 = first_x;
    while (canvas.pan[0] + i * step < w) : (i += 1) {
        const major = @mod(i, 5) == 0;
        ui.empty(.{ .floating = .{ .offset = .{ .x = canvas.pan[0] + i * step, .y = 0 }, .clip = .target }, .width = .fixed(1), .height = .fixed(h), .background_color = if (major) v.theme.grid_major else v.theme.grid });
    }
    i = first_y;
    while (canvas.pan[1] + i * step < h) : (i += 1) {
        const major = @mod(i, 5) == 0;
        ui.empty(.{ .floating = .{ .offset = .{ .x = 0, .y = canvas.pan[1] + i * step }, .clip = .target }, .width = .fixed(w), .height = .fixed(1), .background_color = if (major) v.theme.grid_major else v.theme.grid });
    }
}

/// A link from `a` to `b` in the view: short straight pieces along its
/// curve, each turned its way.
fn wire(v: View, canvas: *const Canvas, ui: *Ui, a: Point, b: Point, color: ui_lib.Color) void {
    _ = v;
    var points: [25]Point = undefined;
    const along = layout.curve(a, b, &points);
    const thick = @max(1.5, 2.5 * canvas.zoom);
    for (along[0 .. along.len - 1], along[1..]) |p, q| {
        const dx = q[0] - p[0];
        const dy = q[1] - p[1];
        const length = @sqrt(dx * dx + dy * dy) + thick * 0.5;
        if (length < 0.01) continue;
        const middle: Point = .{ (p[0] + q[0]) / 2, (p[1] + q[1]) / 2 };
        ui.empty(.{
            .floating = .{ .offset = .{ .x = middle[0] - length / 2, .y = middle[1] - thick / 2 }, .z_index = 1, .clip = .target },
            .width = .fixed(length),
            .height = .fixed(thick),
            .background_color = color,
            .rotate_shape = .{ .radians = std.math.atan2(dy, dx) },
        });
    }
}

fn node(v: View, canvas: *const Canvas, ui: *Ui, arena: Allocator, f: *const model.Function, one: layout.Placed) Allocator.Error!void {
    const m = v.metrics;
    const z = canvas.zoom;
    const at = canvas.toView(one.node.at);
    const theme = v.theme;
    const picked = canvas.isSelected(one.node.id);
    const font: u16 = @intFromFloat(@max(4, @round(m.font_size * z)));
    const small: u16 = @intFromFloat(@max(4, @round(m.font_size * 0.9 * z)));
    const words = z >= 0.35;

    ui.open(.{
        .floating = .{ .offset = .{ .x = at[0], .y = at[1] }, .z_index = 2, .clip = .target },
        .width = .fixed(one.size[0] * z),
        .height = .fixed(one.size[1] * z),
        .direction = .top_to_bottom,
        .background_color = theme.node,
        .corner_radius = .all(6 * z),
        .border = .all(if (picked) theme.selected else theme.node_border, if (picked) 2 else 1),
    });
    {
        ui.open(.{
            .width = .grow,
            .height = .fixed(m.header * z),
            .padding = .xy(@intFromFloat(m.pad * z), 0),
            .align_y = .center,
            .background_color = if (one.shape.known) theme.headerColor(one.shape.category, one.node.kind) else theme.unknown,
            .corner_radius = .{ .top_left = 6 * z, .top_right = 6 * z },
        });
        if (words) ui.text(one.shape.title, .{ .font_size = font, .color = theme.text, .wrap = .none, .font = v.font });
        ui.close();
        const rows = @max(one.shape.inputs.len, one.shape.outputs.len);
        for (0..rows) |i| {
            ui.open(.{ .width = .grow, .height = .fixed(m.row * z), .padding = .xy(@intFromFloat((m.pad + m.pin) * z), 0), .align_y = .center });
            if (i < one.shape.inputs.len and words) {
                const pin = one.shape.inputs[i];
                ui.text(layout.label(pin), .{ .font_size = small, .color = theme.dim_text, .wrap = .none, .font = v.font });
                if (!pin.run and !linkedInto(f, one.node.id, pin.name)) {
                    if (try valueText(arena, one.node, pin)) |shown| ui.text(shown, .{ .font_size = small, .color = theme.value_text, .wrap = .none, .font = v.font });
                }
            }
            ui.empty(.{ .width = .grow });
            if (i < one.shape.outputs.len and words) ui.text(layout.label(one.shape.outputs[i]), .{ .font_size = small, .color = theme.dim_text, .wrap = .none, .font = v.font });
            ui.close();
        }
    }
    ui.close();

    // The dots, half over the edge.
    const dot = m.pin * z;
    inline for (.{ layout.Side.input, layout.Side.output }) |side| {
        const pins = if (side == .input) one.shape.inputs else one.shape.outputs;
        for (pins, 0..) |pin, i| {
            const p = canvas.toView(layout.pinPoint(one.node.at, one.size, side, i, m));
            const linked = if (side == .input) linkedInto(f, one.node.id, pin.name) else linkedFrom(f, one.node.id, pin.name);
            const color = theme.pinColor(pin.type, pin.run);
            ui.empty(.{
                .floating = .{ .offset = .{ .x = p[0] - dot / 2, .y = p[1] - dot / 2 }, .z_index = 3, .clip = .target },
                .width = .fixed(dot),
                .height = .fixed(dot),
                .background_color = if (linked) color else theme.node,
                .border = .all(color, @intFromFloat(@max(1, @round(1.5 * z)))),
                .corner_radius = if (pin.run) .all(1) else .all(dot / 2),
                .rotate_shape = if (pin.run) .{ .radians = std.math.pi / 4.0 } else null,
            });
        }
    }
}

fn linkedInto(f: *const model.Function, id: u32, pin: []const u8) bool {
    for (f.links.items) |l| if (l.to.node == id and std.mem.eql(u8, l.to.pin, pin)) return true;
    return false;
}

fn linkedFrom(f: *const model.Function, id: u32, pin: []const u8) bool {
    for (f.links.items) |l| if (l.from.node == id and std.mem.eql(u8, l.from.pin, pin)) return true;
    return false;
}

/// What an input no link feeds is given, short: its value, or its default.
fn valueText(arena: Allocator, n: *const model.Node, pin: catalog.Pin) Allocator.Error!?[]const u8 {
    if (n.valueOf(pin.name)) |value| {
        var out: std.Io.Writer.Allocating = .init(arena);
        out.writer.print("{f}", .{graph_json.fmt(value, .{})}) catch return error.OutOfMemory;
        const text = out.written();
        return if (text.len > 18) try std.fmt.allocPrint(arena, "{s}...", .{text[0..15]}) else text;
    }
    return pin.default;
}

const graph_json = @import("fluxion_json");

// ---------------------------------------------------------------------------
// The pointer and the keys

pub fn pointer(v: View, canvas: *Canvas, g: *Graph, arena: Allocator, f: *model.Function, nodes: *const catalog.Catalog, p: Pointer) Allocator.Error!Outcome {
    var outcome: Outcome = .{};
    const local: Point = .{ p.x - canvas.view[0], p.y - canvas.view[1] };
    const inside = local[0] >= 0 and local[1] >= 0 and local[0] < canvas.view[2] and local[1] < canvas.view[3];
    canvas.pointer = local;
    const at = canvas.toCanvas(local);
    const placed = try layout.place(arena, f, nodes, v.metrics);

    if (inside and p.wheel != 0) canvas.zoomBy(std.math.pow(f32, 1.1, p.wheel), local);

    switch (canvas.drag) {
        .pan => |held| {
            if (p.down or p.middle) {
                canvas.pan = .{ held.pan[0] + local[0] - held.from[0], held.pan[1] + local[1] - held.from[1] };
            } else canvas.drag = .none;
            return outcome;
        },
        .move => |*held| {
            if (p.down) {
                const by: Point = .{ at[0] - held.last[0], at[1] - held.last[1] };
                if (by[0] != 0 or by[1] != 0) {
                    for (canvas.selected.keys()) |id| if (f.node(id)) |n| {
                        n.at = .{ n.at[0] + by[0], n.at[1] + by[1] };
                    };
                    held.moved = true;
                }
                held.last = at;
            } else {
                outcome.changed = held.moved;
                canvas.drag = .none;
            }
            return outcome;
        },
        .link => |held| {
            if (p.down) return outcome;
            canvas.drag = .none;
            switch (layout.hit(placed, at, v.metrics)) {
                .pin => |there| outcome.changed = try connect(g, f, held, there),
                else => if (inside) {
                    outcome.choose = .{ .at = at, .from = held };
                },
            }
            return outcome;
        },
        .box => |*held| {
            if (p.down) {
                held.to = at;
                return outcome;
            }
            var picked: std.ArrayList(u32) = .empty;
            defer picked.deinit(canvas.gpa);
            try layout.inside(placed, held.from, held.to, &picked, canvas.gpa);
            for (picked.items) |id| try canvas.select(id);
            outcome.picked = true;
            canvas.drag = .none;
            return outcome;
        },
        .none => {},
    }
    if (!inside) return outcome;

    if (p.middle or (p.pressed and p.alt)) {
        canvas.drag = .{ .pan = .{ .from = local, .pan = canvas.pan } };
        return outcome;
    }
    const under = layout.hit(placed, at, v.metrics);
    if (p.secondary and under == .none) {
        outcome.choose = .{ .at = at };
        return outcome;
    }
    if (!p.pressed) return outcome;
    switch (under) {
        .pin => |pin| {
            // An input a link feeds gives the link up, to be put elsewhere.
            if (pin.side == .input) if (feeding(f, pin)) |link| {
                _ = Graph.disconnect(f, link);
                outcome.changed = true;
                const from = layout.find(placed, link.from.node).?;
                const index = layout.indexOf(from.shape.outputs, link.from.pin) orelse return outcome;
                const out = from.shape.outputs[index];
                canvas.drag = .{ .link = .{ .node = link.from.node, .side = .output, .index = index, .name = out.name, .run = out.run, .type = out.type } };
                return outcome;
            };
            canvas.drag = .{ .link = pin };
        },
        .node => |id| {
            if (p.shift) {
                if (canvas.isSelected(id)) _ = canvas.selected.orderedRemove(id) else try canvas.select(id);
            } else if (!canvas.isSelected(id)) {
                canvas.selected.clearRetainingCapacity();
                try canvas.select(id);
            }
            outcome.picked = true;
            canvas.drag = .{ .move = .{ .last = at } };
        },
        .none => {
            const again = p.now - canvas.last_press < 0.4 and @abs(local[0] - canvas.last_press_at[0]) < 6 and @abs(local[1] - canvas.last_press_at[1]) < 6;
            canvas.last_press = p.now;
            canvas.last_press_at = local;
            if (again) {
                outcome.choose = .{ .at = at };
                return outcome;
            }
            if (!p.shift and canvas.selected.count() > 0) {
                canvas.selected.clearRetainingCapacity();
                outcome.picked = true;
            }
            canvas.drag = .{ .box = .{ .from = at, .to = at } };
        },
    }
    return outcome;
}

/// The link that feeds the value input `pin`, if one does: a run input is
/// reached from many, and gives none up.
fn feeding(f: *const model.Function, pin: layout.Hit.Pin) ?model.Link {
    if (pin.run) return null;
    for (f.links.items) |l| if (l.to.node == pin.node and std.mem.eql(u8, l.to.pin, pin.name)) return l;
    return null;
}

/// The link between two pins, either way round, if they fit: an output to
/// an input of another node, a run to a run and a value to a value of a
/// type it goes into. What the input was given, or where the run went, is
/// let go of first. Whether it was made.
pub fn connect(g: *Graph, f: *model.Function, a: layout.Hit.Pin, b: layout.Hit.Pin) Allocator.Error!bool {
    if (a.side == b.side or a.node == b.node or a.run != b.run) return false;
    const out = if (a.side == .output) a else b;
    const in = if (a.side == .output) b else a;
    if (!out.run and !catalog.fits(out.type, in.type)) return false;
    const from: model.End = .{ .node = out.node, .pin = out.name };
    const to: model.End = .{ .node = in.node, .pin = in.name };
    var i: usize = 0;
    while (i < f.links.items.len) {
        const l = f.links.items[i];
        const replaced = if (out.run) l.from.eql(from) else l.to.eql(to);
        if (replaced) _ = f.links.orderedRemove(i) else i += 1;
    }
    g.connect(f, from, to) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return true;
}

pub fn key(v: View, canvas: *Canvas, arena: Allocator, f: *model.Function, nodes: *const catalog.Catalog, k: Key) Allocator.Error!Outcome {
    var outcome: Outcome = .{};
    switch (k) {
        .delete => {
            for (canvas.selected.keys()) |id| {
                if (Graph.removeNode(f, id)) outcome.changed = true;
            }
            canvas.selected.clearRetainingCapacity();
            outcome.picked = true;
        },
        .select_all => {
            for (f.nodes.items) |n| try canvas.select(n.id);
            outcome.picked = true;
        },
        .frame_all => canvas.frame(try layout.place(arena, f, nodes, v.metrics)),
    }
    return outcome;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const Fixture = struct {
    graph: Graph,
    arena: std.heap.ArenaAllocator,
    nodes: catalog.Catalog,
    canvas: Canvas,

    fn init(self: *Fixture) !void {
        self.graph = try .init(testing.allocator);
        self.arena = .init(testing.allocator);
        const service = @import("fluxion_script").service;
        const none: service.Catalog = .{ .types = &.{}, .globals = &.{}, .hooks = &.{}, .builtins = &.{}, .modules = &.{} };
        _ = try self.graph.addVariable(.{ .name = "speed", .type = "float" });
        self.nodes = try catalog.build(self.arena.allocator(), none, &self.graph.file, .{});
        self.canvas = .init(testing.allocator);
        self.canvas.view = .{ 0, 0, 800, 600 };
        self.canvas.pan = .{ 0, 0 };
    }

    fn deinit(self: *Fixture) void {
        self.canvas.deinit();
        self.arena.deinit();
        self.graph.deinit();
    }

    fn press(self: *Fixture, v: View, f: *model.Function, at: Point, down: bool, pressed: bool) !Outcome {
        return v.pointer(&self.canvas, &self.graph, self.arena.allocator(), f, &self.nodes, .{ .x = at[0], .y = at[1], .down = down, .pressed = pressed, .now = 1 });
    }
};

test "a drag from an output to an input links them; one into a value input that is fed takes the old link's place" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const v: View = .{};
    const f = try fx.graph.addFunction("update", .event);
    try f.params.append(fx.graph.allocator(), .{ .name = "dt", .type = "float" });
    const set = try fx.graph.addNode(f, "var.set", .{ 300, 0 });
    f.node(set).?.member = "speed";
    const placed = try layout.place(fx.arena.allocator(), f, &fx.nodes, v.metrics);

    // then -> run
    const then = layout.find(placed, 1).?.pin(.output, "then", v.metrics).?;
    const run = layout.find(placed, set).?.pin(.input, "run", v.metrics).?;
    _ = try fx.press(v, f, then, true, true);
    try testing.expect(fx.canvas.drag == .link);
    const made = try fx.press(v, f, run, false, false);
    try testing.expect(made.changed);
    try testing.expectEqual(@as(usize, 1), f.links.items.len);

    // dt -> value, and a press on value picks the link up again.
    const dt = layout.find(placed, 1).?.pin(.output, "dt", v.metrics).?;
    const value = layout.find(placed, set).?.pin(.input, "value", v.metrics).?;
    _ = try fx.press(v, f, dt, true, true);
    _ = try fx.press(v, f, value, false, false);
    try testing.expectEqual(@as(usize, 2), f.links.items.len);
    const taken = try fx.press(v, f, value, true, true);
    try testing.expect(taken.changed and f.links.items.len == 1);
    // Let go on nothing: a node is asked for, linked from dt.
    const asked = try fx.press(v, f, .{ 700, 500 }, false, false);
    try testing.expectEqualStrings("dt", asked.choose.?.from.?.name);

    // A run does not go into a value.
    try testing.expect(!try connect(&fx.graph, f, .{ .node = 1, .side = .output, .index = 0, .name = "then", .run = true, .type = "" }, .{ .node = set, .side = .input, .index = 2, .name = "value", .run = false, .type = "float" }));
}

test "a press picks a node and a drag moves what is picked; a box picks what is in it; Delete takes it out, but the entry" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const v: View = .{};
    const f = try fx.graph.addFunction("ready", .event);
    const a = try fx.graph.addNode(f, "flow.print", .{ 300, 100 });
    const b = try fx.graph.addNode(f, "flow.print", .{ 300, 300 });

    const changed = blk: {
        _ = try fx.press(v, f, .{ 320, 105 }, true, true);
        try testing.expect(fx.canvas.isSelected(a) and !fx.canvas.isSelected(b));
        _ = try fx.press(v, f, .{ 340, 125 }, true, false);
        break :blk try fx.press(v, f, .{ 340, 125 }, false, false);
    };
    try testing.expect(changed.changed);
    try testing.expectEqual(model.Function.node(f, a).?.at, Point{ 320, 120 });

    // A box from nothing round both.
    _ = try fx.press(v, f, .{ 200, 50 }, true, true);
    try testing.expectEqual(@as(usize, 0), fx.canvas.selected.count());
    _ = try fx.press(v, f, .{ 700, 500 }, true, false);
    _ = try fx.press(v, f, .{ 700, 500 }, false, false);
    try testing.expect(fx.canvas.isSelected(a) and fx.canvas.isSelected(b));

    _ = try v.key(&fx.canvas, fx.arena.allocator(), f, &fx.nodes, .select_all);
    const gone = try v.key(&fx.canvas, fx.arena.allocator(), f, &fx.nodes, .delete);
    try testing.expect(gone.changed);
    try testing.expectEqual(@as(usize, 1), f.nodes.items.len);
}

test "a frame of the view draws the nodes with their words and dots, and the links between them" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const v: View = .{};
    const f = try fx.graph.addFunction("ready", .event);
    const say = try fx.graph.addNode(f, "flow.print", .{ 300, 100 });
    try fx.graph.connect(f, .{ .node = 1, .pin = "then" }, .{ .node = say, .pin = "run" });
    try fx.graph.setValue(f, say, "value", .{ .string = "hi" });

    var ui: Ui = .init(testing.allocator);
    defer ui.deinit();
    ui.setMeasurer(.monospace(0.5, 1.0));
    ui.begin(.init(800, 600));
    try v.draw(&fx.canvas, &ui, fx.arena.allocator(), f, &fx.nodes);
    const drawn = try ui.end();
    v.measure(&fx.canvas, &ui);
    try testing.expectEqual(@as(f32, 800), fx.canvas.view[2]);

    var saw_title = false;
    var saw_value = false;
    var turned: usize = 0;
    for (drawn) |c| switch (c.config) {
        .text => |t| {
            if (std.mem.eql(u8, t.text, "Print")) saw_title = true;
            if (std.mem.eql(u8, t.text, "\"hi\"")) saw_value = true;
        },
        .rectangle => turned += 1,
        else => {},
    };
    try testing.expect(saw_title and saw_value);
    // The link's pieces, the nodes, their dots and the grid.
    try testing.expect(turned > 30);
}
