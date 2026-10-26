// SPDX-License-Identifier: BSD-2-Clause

//! How a graph is drawn: the canvas, a node, its header by what it does, and
//! a pin and its links by the type of what goes along them. A program gives
//! its own to match the rest of it.

const std = @import("std");
const ui_lib = @import("fluxion_ui");
const Color = ui_lib.Color;

const Theme = @This();

canvas: Color,
grid: Color,
grid_major: Color,
node: Color,
node_border: Color,
selected: Color,
/// A node of a kind the catalog does not know now: a plugin's, missing.
unknown: Color,
text: Color,
dim_text: Color,
/// What a pin given nothing shows it holds.
value_text: Color,
box: Color,
box_border: Color,
/// The run: its pins and its links.
run: Color,
/// A pin of a type `typed` has no colour for.
other: Color,
/// Each type's colour, as Flux writes the type.
typed: []const Typed,
/// The header of each kind of node, by the catalog's category or the
/// node's kind: the first that fits.
headers: []const Header,
header: Color,
/// A box drawn round nodes, its header, and its edge.
comment: Color = .bytes(90, 110, 140, 46),
comment_header: Color = .bytes(90, 110, 140, 150),
comment_border: Color = .bytes(130, 150, 180, 120),
/// The edge of a node the game ran just now, as bright as it was lately.
running: Color = .bytes(120, 220, 255, 255),

pub const Typed = struct { type: []const u8, color: Color };
pub const Header = struct {
    /// A category - `Events`, `Flow` - or a kind's first part - `math`.
    of: []const u8,
    color: Color,
};

/// The colour of a pin of `type`: an optional's as its type's, a list's as
/// its items', anything else by its name.
pub fn pinColor(self: *const Theme, @"type": []const u8, run: bool) Color {
    if (run) return self.run;
    var t = @"type";
    while (t.len > 0 and (t[0] == '?' or t[0] == '!')) t = t[1..];
    if (t.len > 2 and t[0] == '[' and t[t.len - 1] == ']') t = t[1 .. t.len - 1];
    for (self.typed) |entry| if (std.mem.eql(u8, entry.type, t)) return entry.color;
    if (t.len == 0 or std.mem.eql(u8, t, "any")) return self.other;
    // The rest - the engine's types, a script's structs - each a colour of
    // its own, the same every time.
    const hue: f32 = @floatFromInt(std.hash.Wyhash.hash(7, t) % 360);
    return hsv(hue, 0.45, 0.85);
}

pub fn headerColor(self: *const Theme, category: []const u8, kind: []const u8) Color {
    for (self.headers) |h| if (std.mem.eql(u8, h.of, category)) return h.color;
    const head = if (std.mem.indexOfScalar(u8, kind, '.')) |dot| kind[0..dot] else kind;
    for (self.headers) |h| if (std.mem.eql(u8, h.of, head)) return h.color;
    return self.header;
}

fn hsv(h: f32, s: f32, v: f32) Color {
    const c = v * s;
    const x = c * (1 - @abs(@mod(h / 60, 2) - 1));
    const m = v - c;
    const rgb: [3]f32 = if (h < 60) .{ c, x, 0 } else if (h < 120) .{ x, c, 0 } else if (h < 180) .{ 0, c, x } else if (h < 240) .{ 0, x, c } else if (h < 300) .{ x, 0, c } else .{ c, 0, x };
    return .{ .r = rgb[0] + m, .g = rgb[1] + m, .b = rgb[2] + m, .a = 1 };
}

pub const dark: Theme = .{
    .canvas = .bytes(24, 25, 28, 255),
    .grid = .bytes(255, 255, 255, 10),
    .grid_major = .bytes(255, 255, 255, 22),
    .node = .bytes(38, 40, 45, 240),
    .node_border = .bytes(0, 0, 0, 160),
    .selected = .bytes(255, 176, 64, 255),
    .unknown = .bytes(180, 60, 60, 255),
    .text = .bytes(225, 228, 232, 255),
    .dim_text = .bytes(150, 155, 162, 255),
    .value_text = .bytes(190, 200, 140, 255),
    .box = .bytes(255, 176, 64, 28),
    .box_border = .bytes(255, 176, 64, 140),
    .run = .bytes(235, 235, 235, 255),
    .other = .bytes(150, 150, 150, 255),
    .typed = &.{
        .{ .type = "float", .color = .bytes(130, 200, 90, 255) },
        .{ .type = "int", .color = .bytes(70, 190, 170, 255) },
        .{ .type = "bool", .color = .bytes(210, 80, 80, 255) },
        .{ .type = "string", .color = .bytes(230, 110, 200, 255) },
        .{ .type = "vec2", .color = .bytes(240, 200, 60, 255) },
        .{ .type = "vec3", .color = .bytes(240, 160, 40, 255) },
        .{ .type = "color", .color = .bytes(120, 120, 255, 255) },
        .{ .type = "Entity", .color = .bytes(80, 160, 255, 255) },
    },
    .headers = &.{
        .{ .of = "Events", .color = .bytes(150, 40, 40, 255) },
        .{ .of = "entry", .color = .bytes(150, 40, 40, 255) },
        .{ .of = "Flow", .color = .bytes(70, 74, 82, 255) },
        .{ .of = "flow", .color = .bytes(70, 74, 82, 255) },
        .{ .of = "Variables", .color = .bytes(150, 100, 40, 255) },
        .{ .of = "var", .color = .bytes(150, 100, 40, 255) },
        .{ .of = "Signals", .color = .bytes(130, 60, 150, 255) },
        .{ .of = "signal", .color = .bytes(130, 60, 150, 255) },
        .{ .of = "math", .color = .bytes(60, 110, 60, 255) },
        .{ .of = "compare", .color = .bytes(60, 110, 60, 255) },
        .{ .of = "logic", .color = .bytes(60, 110, 60, 255) },
        .{ .of = "make", .color = .bytes(60, 100, 110, 255) },
        .{ .of = "convert", .color = .bytes(60, 100, 110, 255) },
        .{ .of = "literal", .color = .bytes(60, 100, 110, 255) },
    },
    .header = .bytes(45, 85, 140, 255),
};
