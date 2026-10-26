// SPDX-License-Identifier: BSD-2-Clause

//! The kinds of node there are, for an editor to offer and to draw: each
//! with its pins, and the node it makes.
//!
//! None of the engine's is written here. They come from
//! `flux.service.catalog` - what Flux's completions offer - and from the
//! graph's own variables, signals and functions, beside the kinds the
//! compiler knows itself (`core`). So what the engine, the project's Flux or
//! a plugin gives scripts is a node, and nothing is listed twice.
//!
//! - **A method** of the host's or of a Flux struct is an action: it runs in
//!   order. A built-in function that changes nothing - `clamp`, `vec2` - is
//!   an expression, worked out where its value is used; so is a Flux
//!   function marked `@pure`.
//! - **A field** is two nodes: one reads it, one sets it.
//! - **A hook** - `update`, `input` - is an event: it starts a function.
//! - **A function's `@node("Category", "icon")`** puts it in a group of the
//!   chooser's, with an icon.
//!
//! A type is written as Flux writes one; empty is any.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flux = @import("fluxion_script");
const service = flux.service;

const model = @import("model.zig");
const compile = @import("compile.zig");

pub const Pin = struct {
    name: []const u8,
    /// As Flux writes a type; empty for any.
    type: []const u8 = "",
    /// One the run goes along: `run`, `then`, a branch's ways.
    run: bool = false,
    /// What it is when given nothing, as Flux writes it.
    default: ?[]const u8 = null,
};

/// What a node made from an entry is: `model.Node`'s own fields.
pub const Made = struct {
    kind: []const u8,
    member: []const u8 = "",
    type: []const u8 = "",
    call: ?model.Call = null,
};

pub const Entry = struct {
    /// What it is known by - `flow.branch`, `var.get:speed`,
    /// `call:component:Transform2D.rotate` - and what `keyOf` gives a node
    /// made from it.
    key: []const u8,
    title: []const u8,
    /// The group a chooser shows it in.
    category: []const u8,
    icon: []const u8 = "",
    doc: ?[]const u8 = null,
    inputs: []const Pin = &.{},
    outputs: []const Pin = &.{},
    made: Made,
    /// A file the graph has to import for it, by the name its call gives
    /// it: added with the node.
    import: ?model.Import = null,
    /// It is no node: a function the engine calls, made with these
    /// parameters.
    event: ?[]const model.Param = null,

    pub fn input(self: *const Entry, name: []const u8) ?*const Pin {
        for (self.inputs) |*p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }

    pub fn output(self: *const Entry, name: []const u8) ?*const Pin {
        for (self.outputs) |*p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
};

pub const Catalog = struct {
    entries: []const Entry,

    pub fn find(self: *const Catalog, key: []const u8) ?*const Entry {
        for (self.entries) |*e| if (std.mem.eql(u8, e.key, key)) return e;
        return null;
    }
};

pub const Options = struct {
    /// The host's types that are components on an entity: their methods
    /// and fields are offered on the graph's own entity.
    components: []const []const u8 = &.{},
    /// The host's type `self.entity` is.
    entity: []const u8 = "Entity",
};

const run_in: Pin = .{ .name = compile.run_in, .run = true };
const run_out: Pin = .{ .name = compile.run_out, .run = true };

/// Every kind there is for `file`, from what `found` says scripts have.
pub fn build(arena: Allocator, found: service.Catalog, file: ?*const model.File, options: Options) Allocator.Error!Catalog {
    var b: Builder = .{ .arena = arena };
    try b.core();
    for (found.hooks) |h| try b.hook(h);
    for (found.builtins) |*f| try b.builtin(f);
    for (found.globals) |g| if (found.typeNamed(g.type)) |t| try b.members(t, .{ .on = .global, .of = g.name, .category = g.name });
    for (found.types) |*t| {
        if (t.kind != .host) continue;
        if (contains(options.components, t.name)) {
            try b.members(t, .{ .on = .component, .of = t.name, .category = t.name });
            // The component of another entity, whose members are then on it.
            try b.add(.{
                .key = try std.fmt.allocPrint(arena, "entity.component:{s}", .{t.name}),
                .title = try std.fmt.allocPrint(arena, "{s} of", .{t.name}),
                .category = t.name,
                .inputs = try b.pins(&.{.{ .name = "entity", .type = options.entity }}),
                .outputs = try b.pins(&.{.{ .name = "out", .type = t.name }}),
                .made = .{ .kind = "entity.component", .type = t.name },
            });
        } else if (std.mem.eql(u8, t.name, options.entity)) {
            try b.members(t, .{ .on = .entity, .of = t.name, .category = "Entity" });
        }
        // On a value of it a link brings: another entity's component, an
        // input event.
        try b.members(t, .{ .on = .target, .of = t.name, .category = t.name });
    }
    for (found.values) |*t| try b.value(t);
    for (found.types) |*t| if (t.kind == .@"enum") try b.enumeration(t.name, t.values, t.name);
    for (found.modules) |*m| try b.module(m);
    if (file) |f| try b.own(f);
    return .{ .entries = b.list.items };
}

/// What a node is known by: its entry's `key`.
pub fn keyOf(arena: Allocator, node: *const model.Node) Allocator.Error![]const u8 {
    const kind = node.kind;
    if (std.mem.eql(u8, kind, "call") or std.mem.eql(u8, kind, "member.get") or std.mem.eql(u8, kind, "member.set")) {
        const call = node.call orelse return kind;
        const head = if (std.mem.eql(u8, kind, "call")) "call" else if (std.mem.eql(u8, kind, "member.get")) "get" else "set";
        // On a value of any type: one entry, the name the node's own.
        if (call.on == .target and std.mem.eql(u8, call.of, "any")) return std.fmt.allocPrint(arena, "{s}:target:any", .{head});
        return callKey(arena, head, call.on, call.of, call.name);
    }
    if (std.mem.eql(u8, kind, "var.get") or std.mem.eql(u8, kind, "var.set") or std.mem.eql(u8, kind, "signal.emit") or
        std.mem.eql(u8, kind, "local.get") or std.mem.eql(u8, kind, "local.set") or std.mem.eql(u8, kind, "function.ref"))
        return std.fmt.allocPrint(arena, "{s}:{s}", .{ kind, node.member });
    if (std.mem.eql(u8, kind, "enum.member")) return std.fmt.allocPrint(arena, "enum.member:{s}.{s}", .{ node.type, node.member });
    if (std.mem.eql(u8, kind, "entity.component")) return std.fmt.allocPrint(arena, "entity.component:{s}", .{node.type});
    if (std.mem.eql(u8, kind, "make.struct")) return std.fmt.allocPrint(arena, "make:{s}", .{if (node.call) |c| c.of else ""});
    if (std.mem.eql(u8, kind, "literal")) return std.fmt.allocPrint(arena, "literal:{s}", .{node.type});
    return kind;
}

fn callKey(arena: Allocator, head: []const u8, on: model.Call.On, of: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}:{t}:{s}{s}{s}", .{ head, on, of, if (of.len > 0) "." else "", name });
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The type of a value a built-in value type's node is called on, as a
/// pin's: a list's `[any]`, a map's `[any: any]`.
fn valueType(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "list")) return "[any]";
    if (std.mem.eql(u8, name, "map")) return "[any: any]";
    return name;
}

/// An annotation's argument as its text, without its quotes.
fn unquoted(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') return text[1 .. text.len - 1];
    return text;
}

/// A file's name as its import calls it: `weather` for `res://sky/weather.flux`.
pub fn importName(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const stem = std.Io.Dir.path.stem(path);
    var out: std.ArrayList(u8) = .empty;
    for (stem) |c| try out.append(arena, if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '_');
    if (out.items.len == 0 or std.ascii.isDigit(out.items[0])) try out.insertSlice(arena, 0, "file_");
    return out.items;
}

const Where = struct {
    on: model.Call.On,
    of: []const u8,
    category: []const u8,
    import: ?model.Import = null,
};

const Builder = struct {
    arena: Allocator,
    list: std.ArrayList(Entry) = .empty,

    fn add(b: *Builder, entry: Entry) Allocator.Error!void {
        try b.list.append(b.arena, entry);
    }

    fn has(b: *const Builder, key: []const u8) bool {
        for (b.list.items) |e| if (std.mem.eql(u8, e.key, key)) return true;
        return false;
    }

    fn pins(b: *Builder, given: []const Pin) Allocator.Error![]const Pin {
        return b.arena.dupe(Pin, given);
    }

    /// The kinds the compiler knows itself.
    fn core(b: *Builder) Allocator.Error!void {
        const any_a: Pin = .{ .name = "a" };
        const any_b: Pin = .{ .name = "b" };
        const out: Pin = .{ .name = "out" };
        const out_bool: Pin = .{ .name = "out", .type = "bool" };
        const binary = [_]struct { []const u8, []const u8, []const u8 }{
            .{ "math.add", "Add", "Math" },           .{ "math.subtract", "Subtract", "Math" },
            .{ "math.multiply", "Multiply", "Math" }, .{ "math.divide", "Divide", "Math" },
            .{ "math.modulo", "Remainder", "Math" },
        };
        for (binary) |op| try b.add(.{ .key = op[0], .title = op[1], .category = op[2], .inputs = try b.pins(&.{ any_a, any_b }), .outputs = try b.pins(&.{out}), .made = .{ .kind = op[0] } });
        const compares = [_]struct { []const u8, []const u8 }{
            .{ "compare.equal", "Equal" },     .{ "compare.not_equal", "Not equal" },
            .{ "compare.less", "Less" },       .{ "compare.less_equal", "Less or equal" },
            .{ "compare.greater", "Greater" }, .{ "compare.greater_equal", "Greater or equal" },
        };
        for (compares) |op| try b.add(.{ .key = op[0], .title = op[1], .category = "Compare", .inputs = try b.pins(&.{ any_a, any_b }), .outputs = try b.pins(&.{out_bool}), .made = .{ .kind = op[0] } });
        const flag_a: Pin = .{ .name = "a", .type = "bool" };
        const flag_b: Pin = .{ .name = "b", .type = "bool" };
        try b.add(.{ .key = "logic.and", .title = "And", .category = "Logic", .inputs = try b.pins(&.{ flag_a, flag_b }), .outputs = try b.pins(&.{out_bool}), .made = .{ .kind = "logic.and" } });
        try b.add(.{ .key = "logic.or", .title = "Or", .category = "Logic", .inputs = try b.pins(&.{ flag_a, flag_b }), .outputs = try b.pins(&.{out_bool}), .made = .{ .kind = "logic.or" } });
        try b.add(.{ .key = "logic.not", .title = "Not", .category = "Logic", .inputs = try b.pins(&.{.{ .name = "value", .type = "bool" }}), .outputs = try b.pins(&.{out_bool}), .made = .{ .kind = "logic.not" } });
        try b.add(.{ .key = "math.negate", .title = "Negate", .category = "Math", .inputs = try b.pins(&.{.{ .name = "value" }}), .outputs = try b.pins(&.{out}), .made = .{ .kind = "math.negate" } });
        const number = "float";
        try b.add(.{ .key = "make.vec2", .title = "Make vec2", .category = "Make", .inputs = try b.pins(&.{ .{ .name = "x", .type = number }, .{ .name = "y", .type = number } }), .outputs = try b.pins(&.{.{ .name = "out", .type = "vec2" }}), .made = .{ .kind = "make.vec2" } });
        try b.add(.{ .key = "make.vec3", .title = "Make vec3", .category = "Make", .inputs = try b.pins(&.{ .{ .name = "x", .type = number }, .{ .name = "y", .type = number }, .{ .name = "z", .type = number } }), .outputs = try b.pins(&.{.{ .name = "out", .type = "vec3" }}), .made = .{ .kind = "make.vec3" } });
        try b.add(.{ .key = "make.color", .title = "Make color", .category = "Make", .inputs = try b.pins(&.{ .{ .name = "r", .type = number }, .{ .name = "g", .type = number }, .{ .name = "b", .type = number }, .{ .name = "a", .type = number, .default = "1.0" } }), .outputs = try b.pins(&.{.{ .name = "out", .type = "color" }}), .made = .{ .kind = "make.color" } });
        try b.add(.{ .key = "convert.to_float", .title = "To float", .category = "Convert", .inputs = try b.pins(&.{.{ .name = "value" }}), .outputs = try b.pins(&.{.{ .name = "out", .type = "float" }}), .made = .{ .kind = "convert.to_float" } });
        try b.add(.{ .key = "convert.to_int", .title = "To int", .category = "Convert", .inputs = try b.pins(&.{.{ .name = "value" }}), .outputs = try b.pins(&.{.{ .name = "out", .type = "int" }}), .made = .{ .kind = "convert.to_int" } });
        try b.add(.{ .key = "self", .title = "Self", .category = "Values", .outputs = try b.pins(&.{.{ .name = "out" }}), .made = .{ .kind = "self" } });
        try b.add(.{ .key = "self.entity", .title = "Entity", .category = "Values", .outputs = try b.pins(&.{.{ .name = "out", .type = "Entity" }}), .made = .{ .kind = "self.entity" } });
        for ([_][]const u8{ "float", "int", "bool", "string", "vec2", "vec3", "color" }) |t| {
            try b.add(.{ .key = try std.fmt.allocPrint(b.arena, "literal:{s}", .{t}), .title = t, .category = "Values", .outputs = try b.pins(&.{.{ .name = "out", .type = t }}), .made = .{ .kind = "literal", .type = t } });
        }

        const any_value: Pin = .{ .name = "value" };
        try b.add(.{ .key = "logic.orelse", .title = "Or else", .category = "Values", .doc = "The value, or the other where it is null.", .inputs = try b.pins(&.{ any_a, any_b }), .outputs = try b.pins(&.{out}), .made = .{ .kind = "logic.orelse" } });
        try b.add(.{ .key = "value.unwrap", .title = "Not null", .category = "Values", .doc = "The value, stopping the script where it is null.", .inputs = try b.pins(&.{any_value}), .outputs = try b.pins(&.{out}), .made = .{ .kind = "value.unwrap" } });
        try b.add(.{ .key = "value.catch", .title = "Catch", .category = "Values", .doc = "The value, or the fallback where it is an error.", .inputs = try b.pins(&.{ any_value, .{ .name = "fallback" } }), .outputs = try b.pins(&.{out}), .made = .{ .kind = "value.catch" } });
        try b.add(.{ .key = "compare.in", .title = "Is in", .category = "Compare", .doc = "Whether a list holds it, a map has the key, or the text contains it.", .inputs = try b.pins(&.{ any_a, any_b }), .outputs = try b.pins(&.{out_bool}), .made = .{ .kind = "compare.in" } });
        try b.add(.{ .key = "compare.is_null", .title = "Is null", .category = "Compare", .inputs = try b.pins(&.{any_value}), .outputs = try b.pins(&.{out_bool}), .made = .{ .kind = "compare.is_null" } });
        try b.add(.{ .key = "value.is", .title = "Is a", .category = "Compare", .doc = "Whether the value is of the node's type.", .inputs = try b.pins(&.{any_value}), .outputs = try b.pins(&.{out_bool}), .made = .{ .kind = "value.is" } });
        try b.add(.{ .key = "make.text", .title = "Text", .category = "Make", .doc = "Words with values in them: each {name} a pin.", .outputs = try b.pins(&.{.{ .name = "out", .type = "string" }}), .made = .{ .kind = "make.text" } });
        try b.add(.{ .key = "literal:null", .title = "null", .category = "Values", .outputs = try b.pins(&.{.{ .name = "out" }}), .made = .{ .kind = "literal", .type = "null" } });
        try b.add(.{ .key = "flow.await", .title = "Await", .category = "Flow", .doc = "Waits for a task, a signal or a number of seconds, and gives what it ends with.", .inputs = try b.pins(&.{ run_in, any_value }), .outputs = try b.pins(&.{ run_out, .{ .name = compile.result_pin } }), .made = .{ .kind = "flow.await" } });
        try b.add(.{ .key = "flow.switch", .title = "Switch", .category = "Flow", .doc = "A run for each case the node says, and one for the rest.", .inputs = try b.pins(&.{ run_in, any_value }), .outputs = try b.pins(&.{ .{ .name = "else", .run = true }, run_out }), .made = .{ .kind = "flow.switch", .call = .{ .name = "switch" } } });
        try b.add(.{ .key = "flow.break", .title = "Break", .category = "Flow", .inputs = try b.pins(&.{run_in}), .made = .{ .kind = "flow.break" } });
        try b.add(.{ .key = "flow.continue", .title = "Continue", .category = "Flow", .inputs = try b.pins(&.{run_in}), .made = .{ .kind = "flow.continue" } });
        // On a value whose type is known only as it runs - another entity's
        // script, what a map holds: by the name the node says.
        try b.add(.{ .key = "call:target:any", .title = "Call a method", .category = "Values", .doc = "Calls the method the node names on the value, with the arguments the node names.", .inputs = try b.pins(&.{ run_in, .{ .name = "target" } }), .outputs = try b.pins(&.{ run_out, .{ .name = compile.result_pin } }), .made = .{ .kind = "call", .call = .{ .on = .target, .of = "any", .name = "", .gives = true } } });
        try b.add(.{ .key = "get:target:any", .title = "Get a field", .category = "Values", .doc = "The field the node names, of the value.", .inputs = try b.pins(&.{.{ .name = "target" }}), .outputs = try b.pins(&.{.{ .name = "out" }}), .made = .{ .kind = "member.get", .call = .{ .on = .target, .of = "any", .name = "", .action = false } } });
        try b.add(.{ .key = "set:target:any", .title = "Set a field", .category = "Values", .doc = "Sets the field the node names, of the value.", .inputs = try b.pins(&.{ run_in, .{ .name = "target" }, .{ .name = "value" } }), .outputs = try b.pins(&.{run_out}), .made = .{ .kind = "member.set", .call = .{ .on = .target, .of = "any", .name = "", .action = true } } });
        try b.add(.{ .key = "flow.branch", .title = "Branch", .category = "Flow", .inputs = try b.pins(&.{ run_in, .{ .name = "condition", .type = "bool" } }), .outputs = try b.pins(&.{ .{ .name = "true", .run = true }, .{ .name = "false", .run = true } }), .made = .{ .kind = "flow.branch" } });
        try b.add(.{ .key = "flow.sequence", .title = "Sequence", .category = "Flow", .inputs = try b.pins(&.{run_in}), .outputs = try b.pins(&.{ .{ .name = "then_0", .run = true }, .{ .name = "then_1", .run = true } }), .made = .{ .kind = "flow.sequence" } });
        try b.add(.{ .key = "flow.for_each", .title = "For each", .category = "Flow", .inputs = try b.pins(&.{ run_in, .{ .name = "list" } }), .outputs = try b.pins(&.{ .{ .name = "body", .run = true }, .{ .name = "item" }, .{ .name = "index", .type = "int" }, run_out }), .made = .{ .kind = "flow.for_each" } });
        try b.add(.{ .key = "flow.repeat", .title = "Repeat", .category = "Flow", .inputs = try b.pins(&.{ run_in, .{ .name = "count", .type = "int" } }), .outputs = try b.pins(&.{ .{ .name = "body", .run = true }, .{ .name = "index", .type = "int" }, run_out }), .made = .{ .kind = "flow.repeat" } });
        try b.add(.{ .key = "flow.while", .title = "While", .category = "Flow", .inputs = try b.pins(&.{ run_in, .{ .name = "condition", .type = "bool" } }), .outputs = try b.pins(&.{ .{ .name = "body", .run = true }, run_out }), .made = .{ .kind = "flow.while" } });
        try b.add(.{ .key = "flow.wait", .title = "Wait", .category = "Flow", .inputs = try b.pins(&.{ run_in, .{ .name = "seconds", .type = "float" } }), .outputs = try b.pins(&.{run_out}), .made = .{ .kind = "flow.wait" } });
        try b.add(.{ .key = "flow.print", .title = "Print", .category = "Flow", .inputs = try b.pins(&.{ run_in, .{ .name = "value" } }), .outputs = try b.pins(&.{run_out}), .made = .{ .kind = "flow.print" } });
        try b.add(.{ .key = "flow.return", .title = "Return", .category = "Flow", .inputs = try b.pins(&.{ run_in, .{ .name = "value" } }), .made = .{ .kind = "flow.return" } });
    }

    fn params(b: *Builder, given: []const service.CatalogParam) Allocator.Error![]const model.Param {
        const out = try b.arena.alloc(model.Param, given.len);
        for (given, out) |p, *into| into.* = .{ .name = p.name, .type = p.type };
        return out;
    }

    fn hook(b: *Builder, h: anytype) Allocator.Error!void {
        var outputs: std.ArrayList(Pin) = .empty;
        try outputs.append(b.arena, run_out);
        for (h.params) |p| try outputs.append(b.arena, .{ .name = p.name, .type = p.type });
        try b.add(.{
            .key = try std.fmt.allocPrint(b.arena, "event:{s}", .{h.name}),
            .title = h.name,
            .category = "Events",
            .doc = h.doc,
            .outputs = outputs.items,
            .made = .{ .kind = model.entry_kind },
            .event = try b.params(h.params),
        });
    }

    fn builtin(b: *Builder, f: *const service.CatalogMember) Allocator.Error!void {
        // The ones that change something, or stop: run in order.
        const acts = std.mem.eql(u8, f.name, "print") or std.mem.eql(u8, f.name, "assert") or std.mem.eql(u8, f.name, "panic") or f.waits;
        try b.call(f, .{ .on = .none, .of = "", .category = "Functions" }, acts);
    }

    /// The members of a value of `t` at `where`: each method a call, each
    /// field a read and a set, each signal of a Flux struct's an emit.
    fn members(b: *Builder, t: *const service.CatalogType, where: Where) Allocator.Error!void {
        for (t.members) |*m| switch (m.kind) {
            .method => try b.call(m, where, m.annotation("pure") == null),
            .function => if (where.on == .global or where.on == .none) try b.call(m, where, m.annotation("pure") == null),
            .field => {
                try b.member(m, where, "get");
                try b.member(m, where, "set");
            },
            .signal => {},
        };
    }

    fn call(b: *Builder, f: *const service.CatalogMember, where: Where, action: bool) Allocator.Error!void {
        return b.callOn(f, where, where.of, action);
    }

    /// A call on `where`, its `target` pin - for one on a value a link
    /// brings - of the type `target`.
    fn callOn(b: *Builder, f: *const service.CatalogMember, where: Where, target: []const u8, action: bool) Allocator.Error!void {
        const a = b.arena;
        var inputs: std.ArrayList(Pin) = .empty;
        var outputs: std.ArrayList(Pin) = .empty;
        if (action) try inputs.append(a, run_in);
        if (where.on == .target) try inputs.append(a, .{ .name = "target", .type = target });
        var args: std.ArrayList([]const u8) = .empty;
        for (f.params) |p| {
            // A rest of values - `print(values: any...)` - is one pin.
            const t = if (std.mem.endsWith(u8, p.type, "...")) p.type[0 .. p.type.len - 3] else p.type;
            try inputs.append(a, .{ .name = p.name, .type = t, .default = p.default });
            try args.append(a, p.name);
        }
        if (action) try outputs.append(a, run_out);
        if (f.type.len > 0) try outputs.append(a, .{ .name = compile.result_pin, .type = f.type });
        var category = where.category;
        var icon: []const u8 = "";
        if (f.annotation("node")) |said| {
            if (said.len > 0) category = unquoted(said[0]);
            if (said.len > 1) icon = unquoted(said[1]);
        }
        try b.add(.{
            .key = try callKey(a, "call", where.on, where.of, f.name),
            .title = f.name,
            .category = category,
            .icon = icon,
            .doc = f.doc,
            .inputs = inputs.items,
            .outputs = outputs.items,
            .made = .{ .kind = "call", .call = .{ .on = where.on, .of = where.of, .name = f.name, .args = args, .gives = f.type.len > 0, .action = action, .waits = f.waits } },
            .import = where.import,
        });
    }

    fn member(b: *Builder, f: *const service.CatalogMember, where: Where, comptime head: []const u8) Allocator.Error!void {
        return b.memberOn(f, where, where.of, head);
    }

    fn memberOn(b: *Builder, f: *const service.CatalogMember, where: Where, target: []const u8, comptime head: []const u8) Allocator.Error!void {
        const a = b.arena;
        const sets = comptime std.mem.eql(u8, head, "set");
        var inputs: std.ArrayList(Pin) = .empty;
        var outputs: std.ArrayList(Pin) = .empty;
        if (sets) try inputs.append(a, run_in);
        if (where.on == .target) try inputs.append(a, .{ .name = "target", .type = target });
        if (sets) {
            try inputs.append(a, .{ .name = "value", .type = f.type });
            try outputs.append(a, run_out);
        } else try outputs.append(a, .{ .name = "out", .type = f.type });
        try b.add(.{
            .key = try callKey(a, head, where.on, where.of, f.name),
            .title = try std.fmt.allocPrint(a, "{s} {s}", .{ if (sets) "Set" else "Get", f.name }),
            .category = where.category,
            .doc = f.doc,
            .inputs = inputs.items,
            .outputs = outputs.items,
            .made = .{ .kind = if (sets) "member.set" else "member.get", .call = .{ .on = where.on, .of = where.of, .name = f.name, .action = sets } },
            .import = where.import,
        });
    }

    /// What a value built into the language has, on a value a link
    /// brings: a list's `push` and `len`, a signal's `connect`.
    fn value(b: *Builder, t: *const service.CatalogType) Allocator.Error!void {
        const of = valueType(t.name);
        const category = try std.fmt.allocPrint(b.arena, "{c}{s}", .{ std.ascii.toUpper(t.name[0]), t.name[1..] });
        for (t.members) |*m| switch (m.kind) {
            // What a list or a string gives back changes nothing of it -
            // but `push`, `pop` and the rest of what gives nothing, which
            // run in order.
            .method => try b.callOn(m, .{ .on = .target, .of = t.name, .category = category }, of, m.type.len == 0 or std.mem.eql(u8, m.name, "pop") or std.mem.eql(u8, m.name, "remove") or std.mem.eql(u8, t.name, "signal")),
            .field => try b.memberOn(m, .{ .on = .target, .of = t.name, .category = category }, of, "get"),
            else => {},
        };
    }

    /// Each member of an enum, as a value.
    fn enumeration(b: *Builder, name: []const u8, values: []const []const u8, category: []const u8) Allocator.Error!void {
        for (values) |member_name| try b.add(.{
            .key = try std.fmt.allocPrint(b.arena, "enum.member:{s}.{s}", .{ name, member_name }),
            .title = try std.fmt.allocPrint(b.arena, "{s}.{s}", .{ name, member_name }),
            .category = category,
            .outputs = try b.pins(&.{.{ .name = "out", .type = name }}),
            .made = .{ .kind = "enum.member", .type = name, .member = member_name },
        });
    }

    /// What a file a graph may import declares, or a module built in: its
    /// functions and constants on the name its import gives it, its
    /// structs made and their methods on a value of theirs, and its enums'
    /// members.
    fn module(b: *Builder, m: *const service.CatalogModule) Allocator.Error!void {
        const name = if (m.builtin) m.path else try importName(b.arena, m.path);
        const import: model.Import = .{ .name = name, .path = m.path };
        for (m.functions) |*f| try b.call(f, .{ .on = .global, .of = name, .category = name, .import = import }, if (m.builtin) f.waits else f.annotation("pure") == null);
        for (m.constants) |*c| try b.member(c, .{ .on = .global, .of = name, .category = name, .import = import }, "get");
        for (m.types) |*t| {
            const of = try std.fmt.allocPrint(b.arena, "{s}.{s}", .{ name, t.name });
            if (t.kind == .@"enum") {
                try b.enumeration(of, t.values, name);
                continue;
            }
            try b.maker(t, of, import);
            for (t.members) |*f| switch (f.kind) {
                .method => try b.call(f, .{ .on = .target, .of = of, .category = of, .import = import }, f.annotation("pure") == null),
                .field => {
                    try b.member(f, .{ .on = .target, .of = of, .category = of, .import = import }, "get");
                    try b.member(f, .{ .on = .target, .of = of, .category = of, .import = import }, "set");
                },
                else => {},
            };
        }
    }

    /// A struct made: each field a pin, given or left at its default.
    fn maker(b: *Builder, t: *const service.CatalogType, of: []const u8, import: ?model.Import) Allocator.Error!void {
        const a = b.arena;
        var inputs: std.ArrayList(Pin) = .empty;
        var fields: std.ArrayList([]const u8) = .empty;
        for (t.members) |m| if (m.kind == .field) {
            try inputs.append(a, .{ .name = m.name, .type = m.type, .default = "" });
            try fields.append(a, m.name);
        };
        try b.add(.{
            .key = try std.fmt.allocPrint(a, "make:{s}", .{of}),
            .title = try std.fmt.allocPrint(a, "Make {s}", .{t.name}),
            .category = of,
            .doc = t.doc,
            .inputs = inputs.items,
            .outputs = try b.pins(&.{.{ .name = "out", .type = of }}),
            .made = .{ .kind = "make.struct", .call = .{ .on = .none, .of = of, .name = t.name, .args = fields, .action = false } },
            .import = import,
        });
    }

    /// The graph's own: its variables read and set, its signals emitted,
    /// its functions called and given as values, each function's own
    /// variables.
    fn own(b: *Builder, file: *const model.File) Allocator.Error!void {
        const a = b.arena;
        for (file.functions.items) |f| {
            try b.add(.{ .key = try std.fmt.allocPrint(a, "function.ref:{s}", .{f.name}), .title = try std.fmt.allocPrint(a, "{s} as a value", .{f.name}), .category = "Functions", .doc = "The function, to connect to a signal or to call later.", .outputs = try b.pins(&.{.{ .name = "out", .type = "fn" }}), .made = .{ .kind = "function.ref", .member = f.name } });
            for (f.locals.items) |l| {
                if (b.has(try std.fmt.allocPrint(a, "local.get:{s}", .{l.name}))) continue;
                try b.add(.{ .key = try std.fmt.allocPrint(a, "local.get:{s}", .{l.name}), .title = try std.fmt.allocPrint(a, "Get {s}", .{l.name}), .category = "Locals", .outputs = try b.pins(&.{.{ .name = "out", .type = l.type }}), .made = .{ .kind = "local.get", .member = l.name } });
                try b.add(.{ .key = try std.fmt.allocPrint(a, "local.set:{s}", .{l.name}), .title = try std.fmt.allocPrint(a, "Set {s}", .{l.name}), .category = "Locals", .inputs = try b.pins(&.{ run_in, .{ .name = "value", .type = l.type } }), .outputs = try b.pins(&.{run_out}), .made = .{ .kind = "local.set", .member = l.name } });
            }
        }
        for (file.variables.items) |v| {
            try b.add(.{ .key = try std.fmt.allocPrint(a, "var.get:{s}", .{v.name}), .title = try std.fmt.allocPrint(a, "Get {s}", .{v.name}), .category = "Variables", .doc = if (v.doc.len > 0) v.doc else null, .outputs = try b.pins(&.{.{ .name = "out", .type = v.type }}), .made = .{ .kind = "var.get", .member = v.name } });
            try b.add(.{ .key = try std.fmt.allocPrint(a, "var.set:{s}", .{v.name}), .title = try std.fmt.allocPrint(a, "Set {s}", .{v.name}), .category = "Variables", .doc = if (v.doc.len > 0) v.doc else null, .inputs = try b.pins(&.{ run_in, .{ .name = "value", .type = v.type } }), .outputs = try b.pins(&.{run_out}), .made = .{ .kind = "var.set", .member = v.name } });
        }
        for (file.signals.items) |s| {
            var inputs: std.ArrayList(Pin) = .empty;
            try inputs.append(a, run_in);
            for (s.params.items) |p| try inputs.append(a, .{ .name = p.name, .type = p.type });
            try b.add(.{ .key = try std.fmt.allocPrint(a, "signal.emit:{s}", .{s.name}), .title = try std.fmt.allocPrint(a, "Emit {s}", .{s.name}), .category = "Signals", .doc = if (s.doc.len > 0) s.doc else null, .inputs = inputs.items, .outputs = try b.pins(&.{run_out}), .made = .{ .kind = "signal.emit", .member = s.name } });
        }
        for (file.functions.items) |f| {
            if (f.kind == .event) continue;
            var inputs: std.ArrayList(Pin) = .empty;
            var outputs: std.ArrayList(Pin) = .empty;
            var args: std.ArrayList([]const u8) = .empty;
            try inputs.append(a, run_in);
            for (f.params.items) |p| {
                try inputs.append(a, .{ .name = p.name, .type = p.type });
                try args.append(a, p.name);
            }
            try outputs.append(a, run_out);
            if (f.result.len > 0) try outputs.append(a, .{ .name = compile.result_pin, .type = f.result });
            try b.add(.{
                .key = try callKey(a, "call", .self, "", f.name),
                .title = f.name,
                .category = "Functions",
                .doc = if (f.doc.len > 0) f.doc else null,
                .inputs = inputs.items,
                .outputs = outputs.items,
                .made = .{ .kind = "call", .call = .{ .on = .self, .name = f.name, .args = args, .gives = f.result.len > 0 } },
            });
        }
    }
};

// ---------------------------------------------------------------------------
// Checking links

/// What is wrong with how `file`'s nodes are linked, by what `catalog`
/// says of their pins: a pin a node has not got, a run linked to a value,
/// a value of one type into a pin of another, an input fed twice, a run
/// going two ways. A node of a kind the catalog does not know - a plugin's,
/// missing now - is said once, and its links are left alone.
pub fn check(arena: Allocator, file: *const model.File, catalog: *const Catalog) Allocator.Error![]const compile.Problem {
    var problems: std.ArrayList(compile.Problem) = .empty;
    for (file.functions.items, 0..) |*f, at| {
        const function: u32 = @intCast(at);
        for (f.nodes.items) |*n| {
            if (std.mem.eql(u8, n.kind, model.entry_kind)) continue;
            if (catalog.find(try keyOf(arena, n)) == null) try problems.append(arena, .{ .function = function, .node = n.id, .message = try std.fmt.allocPrint(arena, "{s} is not a node there is now", .{try keyOf(arena, n)}) });
        }
        for (f.links.items, 0..) |l, i| {
            const from = f.node(l.from.node) orelse continue;
            const to = f.node(l.to.node) orelse continue;
            const out = (try pinOf(arena, f, catalog, from, l.from.pin, .output)) orelse {
                if (try knows(arena, catalog, from)) try problems.append(arena, .{ .function = function, .node = from.id, .message = try std.fmt.allocPrint(arena, "it has no output {s}", .{l.from.pin}) });
                continue;
            };
            const in = (try pinOf(arena, f, catalog, to, l.to.pin, .input)) orelse {
                if (try knows(arena, catalog, to)) try problems.append(arena, .{ .function = function, .node = to.id, .message = try std.fmt.allocPrint(arena, "it has no input {s}", .{l.to.pin}) });
                continue;
            };
            if (out.run != in.run) {
                try problems.append(arena, .{ .function = function, .node = to.id, .message = try std.fmt.allocPrint(arena, "{s} is {s}, and {s} is {s}", .{ l.to.pin, if (in.run) "a run" else "a value", l.from.pin, if (out.run) "a run" else "a value" }) });
                continue;
            }
            if (!out.run and !fits(out.type, in.type)) try problems.append(arena, .{ .function = function, .node = to.id, .message = try std.fmt.allocPrint(arena, "{s} takes {s}, and is given {s}", .{ l.to.pin, in.type, out.type }) });
            for (f.links.items[i + 1 ..]) |other| {
                if (!in.run and other.to.eql(l.to)) try problems.append(arena, .{ .function = function, .node = to.id, .message = try std.fmt.allocPrint(arena, "{s} is given two values", .{l.to.pin}) });
                if (out.run and other.from.eql(l.from)) try problems.append(arena, .{ .function = function, .node = from.id, .message = try std.fmt.allocPrint(arena, "the run from {s} goes two ways: a sequence runs one after another", .{l.from.pin}) });
            }
        }
    }
    return problems.items;
}

fn knows(arena: Allocator, catalog: *const Catalog, n: *const model.Node) Allocator.Error!bool {
    if (std.mem.eql(u8, n.kind, model.entry_kind)) return true;
    return catalog.find(try keyOf(arena, n)) != null;
}

/// A pin of `n`: its entry's, or for the entry its function's `then` and
/// parameters. A sequence has as many runs as are linked.
fn pinOf(arena: Allocator, f: *const model.Function, catalog: *const Catalog, n: *const model.Node, name: []const u8, side: enum { input, output }) Allocator.Error!?Pin {
    if (std.mem.eql(u8, n.kind, model.entry_kind)) {
        if (side == .input) return null;
        if (std.mem.eql(u8, name, compile.run_out)) return run_out;
        for (f.params.items) |p| if (std.mem.eql(u8, p.name, name)) return .{ .name = p.name, .type = p.type };
        return null;
    }
    if (side == .output and std.mem.eql(u8, n.kind, "flow.sequence") and std.mem.startsWith(u8, name, "then_")) return .{ .name = name, .run = true };
    if (side == .output and std.mem.eql(u8, n.kind, "flow.switch") and std.mem.startsWith(u8, name, "case_")) return .{ .name = name, .run = true };
    if (side == .input and std.mem.eql(u8, n.kind, "call")) if (n.call) |call| if (call.on == .target and std.mem.eql(u8, call.of, "any")) {
        for (call.args.items) |arg| if (std.mem.eql(u8, arg, name)) return .{ .name = name };
    };
    if (side == .input and std.mem.eql(u8, n.kind, "make.text")) {
        for (try compile.textPins(arena, n.member)) |pin| if (std.mem.eql(u8, pin, name)) return .{ .name = name };
        return null;
    }
    const entry = catalog.find(try keyOf(arena, n)) orelse return null;
    return if (side == .input) if (entry.input(name)) |p| p.* else null else if (entry.output(name)) |p| p.* else null;
}

/// Whether a value of type `given` goes into a pin of type `wanted`: any
/// either way, the same, an int where a float is, a `T` where a `?T` is.
pub fn fits(given: []const u8, wanted: []const u8) bool {
    if (given.len == 0 or wanted.len == 0) return true;
    if (std.mem.eql(u8, given, "any") or std.mem.eql(u8, wanted, "any")) return true;
    if (std.mem.eql(u8, given, wanted)) return true;
    if (std.mem.eql(u8, given, "int") and std.mem.eql(u8, wanted, "float")) return true;
    if (wanted[0] == '?') return fits(given, wanted[1..]);
    // A built-in value's methods take any list, or any map.
    if (std.mem.eql(u8, wanted, "[any]") and given[0] == '[' and std.mem.indexOfScalar(u8, given, ':') == null) return true;
    if (std.mem.eql(u8, wanted, "[any: any]") and given[0] == '[' and std.mem.indexOfScalar(u8, given, ':') != null) return true;
    return false;
}

const testing = std.testing;
const Graph = @import("Graph.zig");

/// What a host could say scripts have: a component, a global, a hook, a
/// built-in, and a file with an annotated function.
fn sample(arena: Allocator) !service.Catalog {
    const rotate: service.CatalogMember = .{ .name = "rotate", .kind = .method, .params = try arena.dupe(service.CatalogParam, &.{.{ .name = "by", .type = "float" }}) };
    const angle: service.CatalogMember = .{ .name = "angle", .kind = .field, .type = "float" };
    const find: service.CatalogMember = .{ .name = "find", .kind = .method, .type = "?Entity", .params = try arena.dupe(service.CatalogParam, &.{.{ .name = "name", .type = "string" }}) };
    const rain: service.CatalogMember = .{ .name = "rain", .kind = .function, .type = "bool", .params = try arena.dupe(service.CatalogParam, &.{.{ .name = "amount", .type = "float" }}), .annotations = try arena.dupe(service.CatalogAnnotation, &.{.{ .name = "node", .args = &.{ "\"Weather\"", "\"cloud\"" } }}) };
    return .{
        .types = try arena.dupe(service.CatalogType, &.{
            .{ .name = "Transform2D", .kind = .host, .members = try arena.dupe(service.CatalogMember, &.{ rotate, angle }) },
            .{ .name = "App", .kind = .host, .members = try arena.dupe(service.CatalogMember, &.{find}) },
        }),
        .globals = try arena.dupe(service.CatalogGlobal, &.{.{ .name = "app", .type = "App" }}),
        .hooks = try arena.dupe(service.CatalogHook, &.{.{ .name = "update", .params = try arena.dupe(service.CatalogParam, &.{.{ .name = "dt", .type = "float" }}) }}),
        .builtins = try arena.dupe(service.CatalogMember, &.{.{ .name = "clamp", .kind = .function, .type = "float", .params = try arena.dupe(service.CatalogParam, &.{ .{ .name = "x", .type = "float" }, .{ .name = "lo", .type = "float" }, .{ .name = "hi", .type = "float" } }) }}),
        .modules = try arena.dupe(service.CatalogModule, &.{.{ .path = "res://sky/weather.flux", .functions = try arena.dupe(service.CatalogMember, &.{rain}) }}),
    };
}

test "the nodes there are come from what scripts have: a component's methods and fields on the entity, a global's, a hook as an event, a file's function in its @node group, and the graph's own" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var graph: Graph = try .init(testing.allocator);
    defer graph.deinit();
    _ = try graph.addVariable(.{ .name = "speed", .type = "float" });
    _ = try graph.addSignal("opened", &.{.{ .name = "by", .type = "string" }});
    const heal = try graph.addFunction("heal", .function);
    try heal.params.append(graph.allocator(), .{ .name = "amount", .type = "int" });
    heal.result = "bool";

    const catalog = try build(arena, try sample(arena), &graph.file, .{ .components = &.{"Transform2D"} });

    const rotate = catalog.find("call:component:Transform2D.rotate").?;
    try testing.expectEqualStrings("Transform2D", rotate.category);
    try testing.expect(rotate.input("run").?.run and rotate.output("then").?.run);
    try testing.expectEqualStrings("float", rotate.input("by").?.type);
    try testing.expect(catalog.find("call:target:Transform2D.rotate").?.input("target") != null);
    try testing.expectEqualStrings("float", catalog.find("get:component:Transform2D.angle").?.output("out").?.type);
    try testing.expect(catalog.find("set:component:Transform2D.angle").?.input("value") != null);
    try testing.expectEqualStrings("?Entity", catalog.find("call:global:app.find").?.output("result").?.type);
    const update = catalog.find("event:update").?;
    try testing.expectEqualStrings("dt", update.event.?[0].name);
    // Built in, it changes nothing: worked out where it is used.
    const clamp = catalog.find("call:none:clamp").?;
    try testing.expect(clamp.input("run") == null and !clamp.made.call.?.action);
    const rain = catalog.find("call:global:weather.rain").?;
    try testing.expectEqualStrings("Weather", rain.category);
    try testing.expectEqualStrings("cloud", rain.icon);
    try testing.expectEqualStrings("res://sky/weather.flux", rain.import.?.path);
    try testing.expect(catalog.find("var.set:speed") != null);
    try testing.expectEqualStrings("by", catalog.find("signal.emit:opened").?.inputs[1].name);
    try testing.expectEqualStrings("bool", catalog.find("call:self:heal").?.output("result").?.type);
}

test "a node is known by its entry's key, and made from it compiles" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var graph: Graph = try .init(testing.allocator);
    defer graph.deinit();
    graph.file.name = "Spinner";
    const catalog = try build(arena, try sample(arena), &graph.file, .{ .components = &.{"Transform2D"} });
    const update = try graph.addFunction("update", .event);
    try update.params.append(graph.allocator(), .{ .name = "dt", .type = "float" });

    // angle = angle + dt
    const entry = catalog.find("set:component:Transform2D.angle").?;
    const set = try graph.addNode(update, entry.made.kind, .{ 0, 0 });
    update.node(set).?.call = entry.made.call;
    const read = catalog.find("get:component:Transform2D.angle").?;
    const get = try graph.addNode(update, read.made.kind, .{ 0, 0 });
    update.node(get).?.call = read.made.call;
    const add = try graph.addNode(update, "math.add", .{ 0, 0 });
    try graph.connect(update, .{ .node = 1, .pin = "then" }, .{ .node = set, .pin = "run" });
    try graph.connect(update, .{ .node = add, .pin = "out" }, .{ .node = set, .pin = "value" });
    try graph.connect(update, .{ .node = get, .pin = "out" }, .{ .node = add, .pin = "a" });
    try graph.connect(update, .{ .node = 1, .pin = "dt" }, .{ .node = add, .pin = "b" });
    try testing.expectEqualStrings(entry.key, try keyOf(arena, update.node(set).?));
    try testing.expectEqual(@as(usize, 0), (try check(arena, &graph.file, &catalog)).len);

    const made = try compile.compile(arena, &graph.file, .{});
    try testing.expectEqual(@as(usize, 0), made.problems.len);
    try testing.expect(std.mem.indexOf(u8, made.text, "self.entity.get(Transform2D).angle = (self.entity.get(Transform2D).angle + dt);") != null);
}

test "links are checked by what the catalog says of their pins" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var graph: Graph = try .init(testing.allocator);
    defer graph.deinit();
    const catalog = try build(arena, try sample(arena), &graph.file, .{ .components = &.{"Transform2D"} });
    const ready = try graph.addFunction("ready", .event);
    const branch = try graph.addNode(ready, "flow.branch", .{ 0, 0 });
    const text = try graph.addNode(ready, "literal", .{ 0, 0 });
    ready.node(text).?.type = "string";
    const other = try graph.addNode(ready, "literal", .{ 0, 0 });
    ready.node(other).?.type = "bool";
    const lost = try graph.addNode(ready, "call", .{ 0, 0 });
    ready.node(lost).?.call = .{ .on = .global, .of = "gone", .name = "away" };
    try graph.connect(ready, .{ .node = 1, .pin = "then" }, .{ .node = branch, .pin = "condition" });
    try graph.connect(ready, .{ .node = text, .pin = "out" }, .{ .node = branch, .pin = "condition" });
    try graph.connect(ready, .{ .node = other, .pin = "out" }, .{ .node = branch, .pin = "nothing" });

    const problems = try check(arena, &graph.file, &catalog);
    var said: [4]bool = @splat(false);
    for (problems) |p| {
        if (std.mem.indexOf(u8, p.message, "a value, and then is a run") != null) said[0] = true;
        if (std.mem.indexOf(u8, p.message, "takes bool, and is given string") != null) said[1] = true;
        if (std.mem.indexOf(u8, p.message, "no input nothing") != null) said[2] = true;
        if (p.node == lost and std.mem.indexOf(u8, p.message, "not a node there is") != null) said[3] = true;
    }
    try testing.expect(said[0] and said[1] and said[2] and said[3]);
    try testing.expect(fits("int", "float") and fits("Entity", "?Entity") and !fits("string", "bool"));
}
