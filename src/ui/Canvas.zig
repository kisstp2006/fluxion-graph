// SPDX-License-Identifier: BSD-2-Clause

//! What a view of a function's graph keeps from frame to frame: where the
//! canvas is moved to and how near, which nodes are picked, and what the
//! pointer is doing to it. One for each graph open; the graph itself is the
//! program's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const graph = @import("fluxion_graph");
const layout = @import("layout.zig");
const Point = layout.Point;

const Canvas = @This();

gpa: Allocator,
/// Where the canvas's nought is, from the view's top left.
pan: Point = .{ 60, 60 },
/// How many of the view's pixels a unit of the canvas is.
zoom: f32 = 1,
/// The picked nodes, by id.
selected: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
drag: Drag = .none,
/// The view's box on the surface last frame: x, y, width, height.
view: [4]f32 = .{ 0, 0, 0, 0 },
/// Where the pointer was last frame, in the view.
pointer: Point = .{ 0, 0 },
/// When the last press on nothing was, for a second one to open the
/// chooser.
last_press: f64 = -10,
last_press_at: Point = .{ 0, 0 },

pub const min_zoom = 0.2;
pub const max_zoom = 2.5;

pub const Drag = union(enum) {
    none,
    /// The canvas moved with the pointer.
    pan: struct { from: Point, pan: Point },
    /// The picked nodes moved with it, from where it was last frame.
    move: struct { last: Point, moved: bool = false },
    /// A link being drawn from a pin, to the pointer.
    link: layout.Hit.Pin,
    /// A box drawn to pick what is in it, in the canvas.
    box: struct { from: Point, to: Point },
};

pub fn init(gpa: Allocator) Canvas {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Canvas) void {
    self.selected.deinit(self.gpa);
}

/// A point of the view as a point of the canvas.
pub fn toCanvas(self: *const Canvas, p: Point) Point {
    return .{ (p[0] - self.pan[0]) / self.zoom, (p[1] - self.pan[1]) / self.zoom };
}

/// A point of the canvas as a point of the view.
pub fn toView(self: *const Canvas, p: Point) Point {
    return .{ p[0] * self.zoom + self.pan[0], p[1] * self.zoom + self.pan[1] };
}

/// Nearer or farther by `by`, the point `around` of the view staying where
/// it is.
pub fn zoomBy(self: *Canvas, by: f32, around: Point) void {
    const at = self.toCanvas(around);
    self.zoom = std.math.clamp(self.zoom * by, min_zoom, max_zoom);
    self.pan = .{ around[0] - at[0] * self.zoom, around[1] - at[1] * self.zoom };
}

pub fn isSelected(self: *const Canvas, id: u32) bool {
    return self.selected.contains(id);
}

pub fn select(self: *Canvas, id: u32) Allocator.Error!void {
    try self.selected.put(self.gpa, id, {});
}

/// Every node shown, as near as fits up to a zoom of one, in the middle of
/// the view.
pub fn frame(self: *Canvas, placed: []const layout.Placed) void {
    const box = layout.bounds(placed) orelse return;
    const w = self.view[2];
    const h = self.view[3];
    if (w <= 0 or h <= 0) return;
    const margin = 60;
    const size: Point = .{ box[1][0] - box[0][0] + 2 * margin, box[1][1] - box[0][1] + 2 * margin };
    self.zoom = std.math.clamp(@min(w / size[0], h / size[1], 1), min_zoom, max_zoom);
    const middle: Point = .{ (box[0][0] + box[1][0]) / 2, (box[0][1] + box[1][1]) / 2 };
    self.pan = .{ w / 2 - middle[0] * self.zoom, h / 2 - middle[1] * self.zoom };
}

const testing = std.testing;

test "a point goes to the canvas and back, and zooming keeps the point it is about" {
    var c: Canvas = .init(testing.allocator);
    defer c.deinit();
    c.pan = .{ 10, 20 };
    c.zoom = 2;
    try testing.expectEqual(Point{ 45, 40 }, c.toCanvas(.{ 100, 100 }));
    try testing.expectEqual(Point{ 100, 100 }, c.toView(.{ 45, 40 }));
    const before = c.toCanvas(.{ 300, 200 });
    c.zoomBy(1.1, .{ 300, 200 });
    const after = c.toCanvas(.{ 300, 200 });
    try testing.expectApproxEqAbs(before[0], after[0], 0.001);
    try testing.expectApproxEqAbs(before[1], after[1], 0.001);
    c.zoomBy(100, .{ 0, 0 });
    try testing.expectEqual(@as(f32, max_zoom), c.zoom);
}
