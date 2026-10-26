// SPDX-License-Identifier: BSD-2-Clause

//! What a graph is, as its file says it: one struct of Flux's, drawn - its
//! variables, its signals, and its functions, each a graph of nodes and the
//! links between their pins. `Graph` reads, writes and changes one.
//!
//! The model knows names, not meanings. A node's `kind` is what the catalog
//! calls it - `flow.branch`, `call:Transform2D.translate` - and a link joins
//! two pins by their names; which pins a kind has, and which are a run's
//! and which a value's, is the catalog's to say. So a file keeps every node
//! a newer catalog, or a plugin missing just now, has, and a catalog that
//! changes the order of a kind's pins breaks no link.
//!
//! A type is written as Flux writes one - `float`, `vec2`, `Entity`,
//! `[int]`, `?Texture` - and a value as a scene writes one: JSON.

const std = @import("std");
const json = @import("fluxion_json");

/// What a graph's file ends in.
pub const extension = ".fxgraph";

/// The version of the format this writes, and the newest it reads.
pub const version: u32 = 1;

/// A graph as its file holds it: what `Graph.file` is.
pub const File = struct {
    /// What the file is, and in which version of the format. First, so a
    /// look at the start of a file tells; none in JSON that is no graph.
    fluxion_graph: u32 = 0,
    /// The struct the graph is: empty for the one named after the file, as
    /// a Flux file's - `BigDoor` in `big_door.fxgraph`.
    name: []const u8 = "",
    doc: []const u8 = "",
    variables: std.ArrayList(Variable) = .empty,
    signals: std.ArrayList(Signal) = .empty,
    functions: std.ArrayList(Function) = .empty,
};

/// A field of the struct.
pub const Variable = struct {
    name: []const u8,
    /// As Flux writes a type.
    type: []const u8,
    /// What it starts as; null for its type's zero.
    default: json.Value = .null,
    /// Shown in the Inspector and saved with a scene: Flux's `@export`.
    exported: bool = false,
    /// Its other annotations: `@range(0, 10)`, `@group("Movement")`.
    annotations: std.ArrayList(Annotation) = .empty,
    doc: []const u8 = "",
};

pub const Annotation = struct {
    name: []const u8,
    args: std.ArrayList(json.Value) = .empty,
};

/// A signal of the struct's own.
pub const Signal = struct {
    name: []const u8,
    params: std.ArrayList(Param) = .empty,
    doc: []const u8 = "",
};

pub const Param = struct {
    name: []const u8,
    type: []const u8,
};

/// A method of the struct, and the graph of nodes that is its body.
pub const Function = struct {
    name: []const u8,
    kind: Kind = .function,
    /// What it is given besides the struct it is called on.
    params: std.ArrayList(Param) = .empty,
    /// What it gives back, as Flux writes a type; empty for nothing.
    result: []const u8 = "",
    doc: []const u8 = "",
    nodes: std.ArrayList(Node) = .empty,
    links: std.ArrayList(Link) = .empty,
    /// Boxes drawn round nodes, with words in them.
    comments: std.ArrayList(Comment) = .empty,
    /// The id the next node is given: one is never given twice, so an id a
    /// link or an editor's undo holds names one node.
    next_id: u32 = 1,

    pub fn node(self: *const Function, id: u32) ?*Node {
        for (self.nodes.items) |*n| if (n.id == id) return n;
        return null;
    }

    pub const Kind = enum {
        /// What the engine calls - `update`, `input` - or a signal's
        /// handler: where a graph starts.
        event,
        /// A function of its own, which nodes and scripts call.
        function,
    };
};

/// The node every function starts with: its `params` are its outputs.
pub const entry_kind = "entry";

pub const Node = struct {
    /// Its own in its function, never given again.
    id: u32,
    /// What it does, as the catalog names it.
    kind: []const u8,
    /// Where it is on the canvas.
    at: [2]f32 = .{ 0, 0 },
    /// What its inputs no link feeds are given, by pin.
    values: std.ArrayList(PinValue) = .empty,

    /// What the input `pin` is given, if anything is.
    pub fn valueOf(self: *const Node, pin: []const u8) ?json.Value {
        for (self.values.items) |v| if (std.mem.eql(u8, v.pin, pin)) return v.value;
        return null;
    }
};

pub const PinValue = struct {
    pin: []const u8,
    value: json.Value,
};

/// From an output pin to an input pin: a run going on, or a value given.
pub const Link = struct {
    from: End,
    to: End,

    pub fn eql(a: Link, b: Link) bool {
        return a.from.eql(b.from) and a.to.eql(b.to);
    }
};

pub const End = struct {
    node: u32,
    pin: []const u8,

    pub fn eql(a: End, b: End) bool {
        return a.node == b.node and std.mem.eql(u8, a.pin, b.pin);
    }
};

pub const Comment = struct {
    at: [2]f32,
    size: [2]f32,
    text: []const u8 = "",
};
