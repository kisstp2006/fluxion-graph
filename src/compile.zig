// SPDX-License-Identifier: BSD-2-Clause

//! A graph made into Flux, and a map from each line of it back to the node
//! it came from: what a game's runtime compiles and runs as the Flux it
//! is, and what turns the Flux compiler's say about a line into a word
//! about a node.
//!
//! The struct is written as Flux writes one: its variables as fields, its
//! signals, and each function a method, its body the nodes along the run
//! links from its entry, in order.
//!
//! - **An action** - a call that changes something, a variable set, a
//!   signal emitted, a wait - is a statement, and the run goes on from its
//!   `then`. One that gives a value keeps it: `const n7 = ...;`.
//! - **An expression** - arithmetic, a comparison, a variable read, a call
//!   that changes nothing - is written into whatever uses its value, each
//!   time it is used, as an expression node of s&box's is worked out when its
//!   value is wanted.
//! - **Control** - a branch, a sequence, a loop, a return - is Flux's own.
//!
//! What a node is given on a pin no link feeds is written as a literal.
//! What cannot be written - a pin given nothing, a value that needs itself,
//! a run going round in a ring - is a `Problem` at the node, and the graph
//! is still written as far as it goes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = @import("fluxion_json");

const model = @import("model.zig");
const Function = model.Function;
const Node = model.Node;

/// A line of the Flux written, and what it came from: `node` 0 for one no
/// node made - the struct's head, a field.
pub const Line = struct {
    /// The function's place in `File.functions`; none for a line outside
    /// them.
    function: ?u32 = null,
    node: u32 = 0,
};

pub const Problem = struct {
    /// The function's place in `File.functions`; none for the struct's own.
    function: ?u32,
    /// The node; 0 for the function or the struct as a whole.
    node: u32,
    message: []const u8,
};

pub const Compiled = struct {
    text: []const u8,
    /// What each line came from: the first line's first.
    lines: []const Line,
    problems: []const Problem,

    /// What the line `number` - counted from 1, as a compiler says it -
    /// came from.
    pub fn lineAt(self: Compiled, number: u32) Line {
        if (number == 0 or number > self.lines.len) return .{};
        return self.lines[number - 1];
    }
};

pub const Options = struct {
    /// The file the graph was read from: the struct is named after it when
    /// the graph names none, as a Flux file's is - `BigDoor` for
    /// `big_door.fxgraph`.
    path: []const u8 = "",
};

/// Flux for `file`, all of it in `arena`.
pub fn compile(arena: Allocator, file: *const model.File, options: Options) Allocator.Error!Compiled {
    var w: Writer = .{ .arena = arena, .file = file };
    try w.structure(options);
    return .{ .text = w.out.items, .lines = w.lines.items, .problems = w.problems.items };
}

/// What the struct of a graph read from `path` is called when it names
/// none: its stem in words run together, each with a capital.
pub fn structName(arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    const stem = std.Io.Dir.path.stem(path);
    var out: std.ArrayList(u8) = .empty;
    var capital = true;
    for (stem) |c| {
        if (c == '_' or c == '-' or c == ' ' or c == '.') {
            capital = true;
            continue;
        }
        if (!std.ascii.isAlphanumeric(c)) continue;
        try out.append(arena, if (capital) std.ascii.toUpper(c) else c);
        capital = false;
    }
    if (out.items.len == 0 or std.ascii.isDigit(out.items[0])) try out.insertSlice(arena, 0, "Graph");
    return out.items;
}

/// The run's pins: what goes into an action, and what goes on from it.
pub const run_in = "run";
pub const run_out = "then";
/// A call's value.
pub const result_pin = "result";

/// An expression a node of `kind` is, its input pins written `{pin}`.
const Template = struct { kind: []const u8, text: []const u8 };

const expressions = [_]Template{
    .{ .kind = "math.add", .text = "({a} + {b})" },
    .{ .kind = "math.subtract", .text = "({a} - {b})" },
    .{ .kind = "math.multiply", .text = "({a} * {b})" },
    .{ .kind = "math.divide", .text = "({a} / {b})" },
    .{ .kind = "math.modulo", .text = "({a} % {b})" },
    .{ .kind = "math.negate", .text = "(-{value})" },
    .{ .kind = "compare.equal", .text = "({a} == {b})" },
    .{ .kind = "compare.not_equal", .text = "({a} != {b})" },
    .{ .kind = "compare.less", .text = "({a} < {b})" },
    .{ .kind = "compare.less_equal", .text = "({a} <= {b})" },
    .{ .kind = "compare.greater", .text = "({a} > {b})" },
    .{ .kind = "compare.greater_equal", .text = "({a} >= {b})" },
    .{ .kind = "logic.and", .text = "({a} and {b})" },
    .{ .kind = "logic.or", .text = "({a} or {b})" },
    .{ .kind = "logic.not", .text = "(!{value})" },
    .{ .kind = "make.vec2", .text = "vec2({x}, {y})" },
    .{ .kind = "make.vec3", .text = "vec3({x}, {y}, {z})" },
    .{ .kind = "make.color", .text = "color({r}, {g}, {b}, {a})" },
    .{ .kind = "convert.to_float", .text = "float({value})" },
    .{ .kind = "convert.to_int", .text = "int({value})" },
    .{ .kind = "self", .text = "self" },
    .{ .kind = "self.entity", .text = "self.entity" },
};

/// The words Flux keeps for itself, which no name may be.
const keywords = [_][]const u8{
    "and",   "await",   "break",  "catch",  "const", "continue", "else",   "enum",
    "error", "extends", "false",  "fn",     "for",   "if",       "in",     "is",
    "null",  "or",      "orelse", "return", "self",  "signal",   "struct", "switch",
    "test",  "true",    "try",    "var",    "while",
};

/// Whether Flux takes `name` as a name.
pub fn isName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    for (keywords) |k| if (std.mem.eql(u8, k, name)) return false;
    return true;
}

const Writer = struct {
    arena: Allocator,
    file: *const model.File,
    out: std.ArrayList(u8) = .empty,
    lines: std.ArrayList(Line) = .empty,
    problems: std.ArrayList(Problem) = .empty,
    depth: usize = 0,

    // The function being written.
    at: ?u32 = null,
    function: *const Function = undefined,
    /// The actions on the way to the one being written: one met again is a
    /// ring.
    running: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The actions written, whose values are held from there on.
    made: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The loops being written inside: their captures are there.
    looping: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// The expressions being worked out: one met again needs itself.
    evaluating: std.AutoHashMapUnmanaged(u32, void) = .empty,

    fn line(w: *Writer, node: u32, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        for (0..w.depth) |_| try w.out.appendSlice(w.arena, "    ");
        try w.out.print(w.arena, fmt ++ "\n", args);
        try w.lines.append(w.arena, .{ .function = w.at, .node = node });
    }

    fn problem(w: *Writer, node: u32, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try w.problems.append(w.arena, .{ .function = w.at, .node = node, .message = try std.fmt.allocPrint(w.arena, fmt, args) });
    }

    /// `name`, or a problem and a name Flux takes in its place.
    fn named(w: *Writer, node: u32, name: []const u8) Allocator.Error![]const u8 {
        if (isName(name)) return name;
        try w.problem(node, "\"{s}\" is not a name Flux takes", .{name});
        return "_unnamed";
    }

    fn structure(w: *Writer, options: Options) Allocator.Error!void {
        const file = w.file;
        const name = if (file.name.len > 0) try w.named(0, file.name) else try structName(w.arena, options.path);
        try w.line(0, "// Made from {s} by fluxion-graph: the graph is what to change.", .{if (options.path.len > 0) options.path else "a graph"});
        for (file.imports.items) |m| try w.line(0, "const {s} = @import({s});", .{ try w.named(0, m.name), try quote(w.arena, m.path) });
        try w.doc(0, file.doc);
        try w.line(0, "struct {s} {{", .{name});
        w.depth += 1;
        for (file.variables.items) |v| try w.variable(v);
        for (file.signals.items) |s| {
            try w.doc(0, s.doc);
            try w.line(0, "signal {s}({s});", .{ try w.named(0, s.name), try w.params(s.params.items) });
        }
        for (file.functions.items, 0..) |*f, i| {
            w.at = @intCast(i);
            w.function = f;
            try w.method(f);
            w.at = null;
        }
        w.depth -= 1;
        try w.line(0, "}}", .{});
    }

    fn doc(w: *Writer, node: u32, words: []const u8) Allocator.Error!void {
        if (words.len == 0) return;
        var it = std.mem.splitScalar(u8, words, '\n');
        while (it.next()) |part| try w.line(node, "/// {s}", .{part});
    }

    fn variable(w: *Writer, v: model.Variable) Allocator.Error!void {
        try w.doc(0, v.doc);
        var head: std.ArrayList(u8) = .empty;
        if (v.exported) try head.appendSlice(w.arena, "@export ");
        for (v.annotations.items) |a| {
            try head.print(w.arena, "@{s}", .{try w.named(0, a.name)});
            if (a.args.items.len > 0) {
                try head.append(w.arena, '(');
                for (a.args.items, 0..) |arg, i| {
                    if (i > 0) try head.appendSlice(w.arena, ", ");
                    try head.appendSlice(w.arena, try w.literal(0, arg, ""));
                }
                try head.append(w.arena, ')');
            }
            try head.append(w.arena, ' ');
        }
        const name = try w.named(0, v.name);
        if (v.default == .null) {
            try w.line(0, "{s}var {s}: {s};", .{ head.items, name, v.type });
        } else {
            try w.line(0, "{s}var {s}: {s} = {s};", .{ head.items, name, v.type, try w.literal(0, v.default, v.type) });
        }
    }

    fn params(w: *Writer, list: []const model.Param) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (list, 0..) |p, i| {
            if (i > 0) try out.appendSlice(w.arena, ", ");
            try out.print(w.arena, "{s}: {s}", .{ try w.named(0, p.name), p.type });
        }
        return out.items;
    }

    fn method(w: *Writer, f: *const Function) Allocator.Error!void {
        w.running.clearRetainingCapacity();
        w.made.clearRetainingCapacity();
        w.looping.clearRetainingCapacity();
        w.evaluating.clearRetainingCapacity();
        try w.doc(0, f.doc);
        const listed = try w.params(f.params.items);
        const name = try w.named(0, f.name);
        const result = if (f.result.len > 0) try std.fmt.allocPrint(w.arena, " {s}", .{f.result}) else "";
        try w.line(0, "fn {s}(self{s}{s}){s} {{", .{ name, if (listed.len > 0) ", " else "", listed, result });
        w.depth += 1;
        const entry = for (f.nodes.items) |*n| {
            if (std.mem.eql(u8, n.kind, model.entry_kind)) break n;
        } else null;
        if (entry) |n| try w.chain(n.id, run_out) else try w.problem(0, "{s} has no entry", .{f.name});
        w.depth -= 1;
        try w.line(0, "}}", .{});
    }

    // ---------------------------------------------------------------------
    // The run
    // ---------------------------------------------------------------------

    /// The actions on from the output `pin` of node `from`, in order.
    fn chain(w: *Writer, from: u32, pin: []const u8) Allocator.Error!void {
        const next = w.runFrom(from, pin) orelse return;
        try w.action(next);
    }

    /// The node the run from `from`'s `pin` goes on to.
    fn runFrom(w: *Writer, from: u32, pin: []const u8) ?*const Node {
        for (w.function.links.items) |l| {
            if (l.from.node == from and std.mem.eql(u8, l.from.pin, pin)) return w.function.node(l.to.node);
        }
        return null;
    }

    fn isLinkedFrom(w: *Writer, node: u32, pin: []const u8) bool {
        for (w.function.links.items) |l| if (l.from.node == node and std.mem.eql(u8, l.from.pin, pin)) return true;
        return false;
    }

    fn action(w: *Writer, n: *const Node) Allocator.Error!void {
        if (w.running.contains(n.id)) return w.problem(n.id, "the run comes back round to here: a loop is a loop node", .{});
        try w.running.put(w.arena, n.id, {});
        defer _ = w.running.remove(n.id);
        const kind = n.kind;
        if (eql(kind, "call")) {
            const call = n.call orelse return w.problem(n.id, "a call that names nothing to call", .{});
            if (!call.action) return w.problem(n.id, "{s} changes nothing, so it is not run: use its value", .{call.name});
            const text = try w.callText(n, call);
            if (call.gives and w.isLinkedFrom(n.id, result_pin)) {
                try w.line(n.id, "const n{d} = {s};", .{ n.id, text });
                try w.made.put(w.arena, n.id, {});
            } else if (call.gives) {
                try w.line(n.id, "_ = {s};", .{text});
            } else try w.line(n.id, "{s};", .{text});
            return w.chain(n.id, run_out);
        }
        if (eql(kind, "var.set")) {
            try w.line(n.id, "self.{s} = {s};", .{ try w.named(n.id, n.member), try w.input(n, "value") });
            return w.chain(n.id, run_out);
        }
        if (eql(kind, "signal.emit")) {
            const signal = for (w.file.signals.items) |*s| {
                if (eql(s.name, n.member)) break s;
            } else return w.problem(n.id, "the graph has no signal {s}", .{n.member});
            var args: std.ArrayList(u8) = .empty;
            for (signal.params.items, 0..) |p, i| {
                if (i > 0) try args.appendSlice(w.arena, ", ");
                try args.appendSlice(w.arena, try w.input(n, p.name));
            }
            try w.line(n.id, "self.{s}.emit({s});", .{ try w.named(n.id, n.member), args.items });
            return w.chain(n.id, run_out);
        }
        if (eql(kind, "flow.wait")) {
            try w.line(n.id, "await wait({s});", .{try w.input(n, "seconds")});
            return w.chain(n.id, run_out);
        }
        if (eql(kind, "flow.print")) {
            try w.line(n.id, "print({s});", .{try w.input(n, "value")});
            return w.chain(n.id, run_out);
        }
        if (eql(kind, "flow.branch")) {
            try w.line(n.id, "if ({s}) {{", .{try w.input(n, "condition")});
            try w.block(n.id, "true");
            if (w.runFrom(n.id, "false") != null) {
                try w.line(n.id, "}} else {{", .{});
                try w.block(n.id, "false");
            }
            return w.line(n.id, "}}", .{});
        }
        if (eql(kind, "flow.sequence")) {
            // `then_0`, `then_1`... in the order of their numbers.
            var at: u32 = 0;
            var buffer: [24]u8 = undefined;
            while (at < 64) : (at += 1) {
                const pin = std.fmt.bufPrint(&buffer, "then_{d}", .{at}) catch unreachable;
                try w.chain(n.id, pin);
            }
            return;
        }
        if (eql(kind, "flow.for_each")) {
            try w.line(n.id, "for ({s}) |item{d}, index{d}| {{", .{ try w.input(n, "list"), n.id, n.id });
            try w.loopBody(n);
            try w.line(n.id, "}}", .{});
            return w.chain(n.id, run_out);
        }
        if (eql(kind, "flow.repeat")) {
            try w.line(n.id, "for (0..{s}) |index{d}| {{", .{ try w.input(n, "count"), n.id });
            try w.loopBody(n);
            try w.line(n.id, "}}", .{});
            return w.chain(n.id, run_out);
        }
        if (eql(kind, "flow.while")) {
            try w.line(n.id, "while ({s}) {{", .{try w.input(n, "condition")});
            try w.block(n.id, "body");
            try w.line(n.id, "}}", .{});
            return w.chain(n.id, run_out);
        }
        if (eql(kind, "flow.return")) {
            if (w.function.result.len > 0) return w.line(n.id, "return {s};", .{try w.input(n, "value")});
            return w.line(n.id, "return;", .{});
        }
        return w.problem(n.id, "{s} is not a node that runs", .{kind});
    }

    fn block(w: *Writer, from: u32, pin: []const u8) Allocator.Error!void {
        w.depth += 1;
        defer w.depth -= 1;
        try w.chain(from, pin);
    }

    fn loopBody(w: *Writer, n: *const Node) Allocator.Error!void {
        try w.looping.put(w.arena, n.id, {});
        defer _ = w.looping.remove(n.id);
        try w.block(n.id, "body");
    }

    // ---------------------------------------------------------------------
    // Values
    // ---------------------------------------------------------------------

    /// What the input `pin` of `n` is given: what a link brings, else the
    /// value written on the node.
    fn input(w: *Writer, n: *const Node, pin: []const u8) Allocator.Error![]const u8 {
        for (w.function.links.items) |l| {
            if (l.to.node == n.id and eql(l.to.pin, pin)) return w.output(l.from.node, l.from.pin);
        }
        if (n.valueOf(pin)) |value| return w.literal(n.id, value, "");
        try w.problem(n.id, "{s} is given nothing", .{pin});
        return "null";
    }

    /// The value the output `pin` of node `id` gives.
    fn output(w: *Writer, id: u32, pin: []const u8) Allocator.Error![]const u8 {
        const n = w.function.node(id) orelse {
            try w.problem(0, "a link comes from node {d}, which is not there", .{id});
            return "null";
        };
        const kind = n.kind;
        if (eql(kind, model.entry_kind)) {
            for (w.function.params.items) |p| if (eql(p.name, pin)) return w.named(id, p.name);
            try w.problem(id, "{s} has no parameter {s}", .{ w.function.name, pin });
            return "null";
        }
        if (eql(kind, "flow.for_each") or eql(kind, "flow.repeat")) {
            if (!w.looping.contains(id)) {
                try w.problem(id, "{s} is used outside the loop", .{pin});
                return "null";
            }
            if (eql(pin, "item") and eql(kind, "flow.for_each")) return std.fmt.allocPrint(w.arena, "item{d}", .{id});
            if (eql(pin, "index")) return std.fmt.allocPrint(w.arena, "index{d}", .{id});
            try w.problem(id, "a loop gives no {s}", .{pin});
            return "null";
        }
        if (eql(kind, "call")) if (n.call) |call| if (call.action) {
            if (!w.made.contains(id)) {
                try w.problem(id, "its {s} is used before it runs", .{pin});
                return "null";
            }
            return std.fmt.allocPrint(w.arena, "n{d}", .{id});
        };

        // An expression: worked out here, each time it is used.
        if (w.evaluating.contains(id)) {
            try w.problem(id, "its value needs itself", .{});
            return "null";
        }
        try w.evaluating.put(w.arena, id, {});
        defer _ = w.evaluating.remove(id);
        if (eql(kind, "call")) {
            const call = n.call orelse {
                try w.problem(id, "a call that names nothing to call", .{});
                return "null";
            };
            return w.callText(n, call);
        }
        if (eql(kind, "var.get")) return std.fmt.allocPrint(w.arena, "self.{s}", .{try w.named(id, n.member)});
        if (eql(kind, "literal")) {
            const value = n.valueOf("value") orelse {
                try w.problem(id, "the value is given nothing", .{});
                return "null";
            };
            return w.literal(id, value, n.type);
        }
        for (expressions) |t| if (eql(t.kind, kind)) return w.fill(n, t.text);
        try w.problem(id, "{s} is not a node that gives a value", .{kind});
        return "null";
    }

    /// `template` with each `{pin}` given what the pin is given.
    fn fill(w: *Writer, n: *const Node, template: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var rest = template;
        while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
            const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse break;
            try out.appendSlice(w.arena, rest[0..open]);
            try out.appendSlice(w.arena, try w.input(n, rest[open + 1 .. close]));
            rest = rest[close + 1 ..];
        }
        try out.appendSlice(w.arena, rest);
        return out.items;
    }

    fn callText(w: *Writer, n: *const Node, call: model.Call) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        if (call.waits) try out.appendSlice(w.arena, "await ");
        const name = try w.named(n.id, call.name);
        switch (call.on) {
            .none => {},
            .self => try out.appendSlice(w.arena, "self."),
            .entity => try out.appendSlice(w.arena, "self.entity."),
            .component => try out.print(w.arena, "self.entity.get({s}).", .{try w.named(n.id, call.of)}),
            .global => try out.print(w.arena, "{s}.", .{try w.named(n.id, call.of)}),
            .target => try out.print(w.arena, "{s}.", .{try w.input(n, "target")}),
        }
        try out.print(w.arena, "{s}(", .{name});
        for (call.args.items, 0..) |arg, i| {
            if (i > 0) try out.appendSlice(w.arena, ", ");
            try out.appendSlice(w.arena, try w.input(n, arg));
        }
        try out.append(w.arena, ')');
        return out.items;
    }

    /// `value` as Flux writes it, as a value of `type` where one is said:
    /// a number a float, two numbers a `vec2`, a `color` from its text.
    fn literal(w: *Writer, node: u32, value: json.Value, @"type": []const u8) Allocator.Error![]const u8 {
        const a = w.arena;
        switch (value) {
            .null => return "null",
            .bool => |b| return if (b) "true" else "false",
            .int => |i| return if (eql(@"type", "float")) std.fmt.allocPrint(a, "{d}.0", .{i}) else std.fmt.allocPrint(a, "{d}", .{i}),
            .float => |f| return float(a, f),
            .string => |s| {
                const quoted = try quote(a, s);
                return if (eql(@"type", "color")) std.fmt.allocPrint(a, "color({s})", .{quoted}) else quoted;
            },
            .array => |list| {
                const items = list.items();
                const numbers = for (items) |item| {
                    if (item != .int and item != .float) break false;
                } else items.len > 0;
                var out: std.ArrayList(u8) = .empty;
                const head = if (numbers and eql(@"type", "color")) "color(" else if (numbers and items.len == 2 and !isList(@"type")) "vec2(" else if (numbers and items.len == 3 and !isList(@"type")) "vec3(" else "[";
                try out.appendSlice(a, head);
                for (items, 0..) |item, i| {
                    if (i > 0) try out.appendSlice(a, ", ");
                    const as_float = !std.mem.eql(u8, head, "[");
                    try out.appendSlice(a, try w.literal(node, item, if (as_float) "float" else elementOf(@"type")));
                }
                try out.appendSlice(a, if (eql(head, "[")) "]" else ")");
                return out.items;
            },
            .object => |object| {
                var out: std.ArrayList(u8) = .empty;
                try out.append(a, '{');
                for (object.keys(), object.values(), 0..) |key, item, i| {
                    if (i > 0) try out.appendSlice(a, ", ");
                    try out.print(a, "{s}: {s}", .{ try quote(a, key), try w.literal(node, item, "") });
                }
                try out.append(a, '}');
                return out.items;
            },
        }
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isList(@"type": []const u8) bool {
    return @"type".len > 0 and @"type"[0] == '[';
}

/// What a list type's items are: `int` of `[int]`.
fn elementOf(@"type": []const u8) []const u8 {
    if (!isList(@"type") or @"type".len < 2) return "";
    return @"type"[1 .. @"type".len - 1];
}

/// A float as Flux reads one back the same: with its point.
fn float(arena: Allocator, f: f64) Allocator.Error![]const u8 {
    if (std.math.isNan(f)) return "math.nan";
    if (std.math.isInf(f)) return if (f > 0) "math.inf" else "(-math.inf)";
    const text = try std.fmt.allocPrint(arena, "{d}", .{f});
    for (text) |c| if (c == '.' or c == 'e') return text;
    return std.fmt.allocPrint(arena, "{s}.0", .{text});
}

/// Text in quotes, as Flux reads it back the same.
fn quote(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        '{' => try out.appendSlice(arena, "\\{"),
        '}' => try out.appendSlice(arena, "\\}"),
        0...8, 11, 12, 14...31, 127 => try out.print(arena, "\\x{X:0>2}", .{c}),
        else => try out.append(arena, c),
    };
    try out.append(arena, '"');
    return out.items;
}

const testing = std.testing;
const Graph = @import("Graph.zig");

test "a struct's name, from its file's when the graph says none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("BigDoor", try structName(arena.allocator(), "res://doors/big_door.fxgraph"));
    try testing.expectEqualStrings("Graph2", try structName(arena.allocator(), "2.fxgraph"));
    try testing.expect(isName("speed") and !isName("2d") and !isName("while") and !isName("a-b"));
}

/// A door that turns by its speed each frame, and once it has turned far
/// enough says so and waits a second.
fn door(gpa: Allocator) !Graph {
    var graph: Graph = try .init(gpa);
    errdefer graph.deinit();
    const a = graph.allocator();
    _ = try graph.addVariable(.{ .name = "speed", .type = "float", .default = .{ .float = 2 }, .exported = true });
    var range: model.Annotation = .{ .name = "range" };
    try range.args.append(testing.allocator, .{ .int = 0 });
    try range.args.append(testing.allocator, .{ .int = 10 });
    defer range.args.deinit(testing.allocator);
    var annotations: std.ArrayList(model.Annotation) = .empty;
    defer annotations.deinit(testing.allocator);
    try annotations.append(testing.allocator, range);
    _ = try graph.addVariable(.{ .name = "turned", .type = "float", .annotations = annotations });
    _ = try graph.addSignal("opened", &.{.{ .name = "by", .type = "string" }});

    const update = try graph.addFunction("update", .event);
    try update.params.append(a, .{ .name = "dt", .type = "float" });
    // turned = turned + dt * speed
    const set = try graph.addNode(update, "var.set", .{ 200, 0 });
    update.node(set).?.member = "turned";
    const add = try graph.addNode(update, "math.add", .{ 100, 80 });
    const turned = try graph.addNode(update, "var.get", .{ 0, 80 });
    update.node(turned).?.member = "turned";
    const times = try graph.addNode(update, "math.multiply", .{ 0, 160 });
    const speed = try graph.addNode(update, "var.get", .{ -100, 160 });
    update.node(speed).?.member = "speed";
    try graph.connect(update, .{ .node = 1, .pin = run_out }, .{ .node = set, .pin = run_in });
    try graph.connect(update, .{ .node = add, .pin = "out" }, .{ .node = set, .pin = "value" });
    try graph.connect(update, .{ .node = turned, .pin = "out" }, .{ .node = add, .pin = "a" });
    try graph.connect(update, .{ .node = times, .pin = "out" }, .{ .node = add, .pin = "b" });
    try graph.connect(update, .{ .node = 1, .pin = "dt" }, .{ .node = times, .pin = "a" });
    try graph.connect(update, .{ .node = speed, .pin = "out" }, .{ .node = times, .pin = "b" });
    // if turned > 90: emit opened("me"), then wait a second
    const branch = try graph.addNode(update, "flow.branch", .{ 400, 0 });
    const more = try graph.addNode(update, "compare.greater", .{ 300, 80 });
    try graph.setValue(update, more, "b", .{ .float = 90 });
    try graph.connect(update, .{ .node = turned, .pin = "out" }, .{ .node = more, .pin = "a" });
    try graph.connect(update, .{ .node = set, .pin = run_out }, .{ .node = branch, .pin = run_in });
    try graph.connect(update, .{ .node = more, .pin = "out" }, .{ .node = branch, .pin = "condition" });
    const emit = try graph.addNode(update, "signal.emit", .{ 600, 0 });
    update.node(emit).?.member = "opened";
    try graph.setValue(update, emit, "by", .{ .string = "me" });
    try graph.connect(update, .{ .node = branch, .pin = "true" }, .{ .node = emit, .pin = run_in });
    const rotate = try graph.addNode(update, "call", .{ 800, 0 });
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(a, "by");
    update.node(rotate).?.call = .{ .on = .component, .of = "Transform2D", .name = "rotate", .args = args };
    try graph.setValue(update, rotate, "by", .{ .float = 0.5 });
    try graph.connect(update, .{ .node = emit, .pin = run_out }, .{ .node = rotate, .pin = run_in });
    return graph;
}

test "a graph is written as the Flux struct it draws, each line kept with the node it came from" {
    var graph = try door(testing.allocator);
    defer graph.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const made = try compile(arena.allocator(), &graph.file, .{ .path = "res://doors/swing_door.fxgraph" });
    try testing.expectEqual(@as(usize, 0), made.problems.len);
    try testing.expectEqualStrings(
        \\// Made from res://doors/swing_door.fxgraph by fluxion-graph: the graph is what to change.
        \\struct SwingDoor {
        \\    @export var speed: float = 2.0;
        \\    @range(0, 10) var turned: float;
        \\    signal opened(by: string);
        \\    fn update(self, dt: float) {
        \\        self.turned = (self.turned + (dt * self.speed));
        \\        if ((self.turned > 90.0)) {
        \\            self.opened.emit("me");
        \\            self.entity.get(Transform2D).rotate(0.5);
        \\        }
        \\    }
        \\}
        \\
    , made.text);
    // The set, the branch, the emit and the call, each at its line.
    try testing.expectEqual(@as(u32, 2), made.lineAt(7).node);
    try testing.expectEqual(@as(u32, 7), made.lineAt(8).node);
    try testing.expectEqual(@as(u32, 9), made.lineAt(9).node);
    try testing.expectEqual(@as(u32, 10), made.lineAt(10).node);
    try testing.expectEqual(@as(?u32, 0), made.lineAt(7).function);
    try testing.expectEqual(@as(?u32, null), made.lineAt(3).function);
}

test "what cannot be written is said at its node, and the rest is written all the same" {
    var graph: Graph = try .init(testing.allocator);
    defer graph.deinit();
    graph.file.name = "Broken";
    const ready = try graph.addFunction("ready", .event);
    // A print given nothing; a value that needs itself; a run in a ring.
    const say = try graph.addNode(ready, "flow.print", .{ 0, 0 });
    try graph.connect(ready, .{ .node = 1, .pin = run_out }, .{ .node = say, .pin = run_in });
    const add = try graph.addNode(ready, "math.add", .{ 0, 0 });
    const twice = try graph.addNode(ready, "math.add", .{ 0, 0 });
    try graph.connect(ready, .{ .node = add, .pin = "out" }, .{ .node = twice, .pin = "a" });
    try graph.connect(ready, .{ .node = twice, .pin = "out" }, .{ .node = add, .pin = "a" });
    try graph.setValue(ready, add, "b", .{ .int = 1 });
    try graph.setValue(ready, twice, "b", .{ .int = 1 });
    const set = try graph.addNode(ready, "var.set", .{ 0, 0 });
    ready.node(set).?.member = "x";
    try graph.connect(ready, .{ .node = say, .pin = run_out }, .{ .node = set, .pin = run_in });
    try graph.connect(ready, .{ .node = add, .pin = "out" }, .{ .node = set, .pin = "value" });
    try graph.connect(ready, .{ .node = set, .pin = run_out }, .{ .node = say, .pin = run_in });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const made = try compile(arena.allocator(), &graph.file, .{});
    var said: [3]bool = @splat(false);
    for (made.problems) |p| {
        try testing.expectEqual(@as(?u32, 0), p.function);
        if (p.node == say and std.mem.indexOf(u8, p.message, "given nothing") != null) said[0] = true;
        if (std.mem.indexOf(u8, p.message, "needs itself") != null) said[1] = true;
        if (p.node == say and std.mem.indexOf(u8, p.message, "round") != null) said[2] = true;
    }
    try testing.expect(said[0] and said[1] and said[2]);
    try testing.expect(std.mem.indexOf(u8, made.text, "struct Broken {") != null);
}

test "loops give their items inside, an action's value is held, and literals are written as Flux reads them" {
    var graph: Graph = try .init(testing.allocator);
    defer graph.deinit();
    graph.file.name = "Counter";
    const a = graph.allocator();
    try graph.addImport("tools", "tools.flux");
    try testing.expectError(error.NameTaken, graph.addImport("tools", "other.flux"));
    _ = try graph.addVariable(.{ .name = "tint", .type = "color", .default = .{ .string = "#FF8000" } });
    var at: json.Document = try .init(testing.allocator);
    defer at.deinit();
    const where = try at.array();
    try where.append(1);
    try where.append(2.5);
    _ = try graph.addVariable(.{ .name = "at", .type = "vec2", .default = where });
    const count = try graph.addFunction("count", .function);
    count.result = "int";
    try count.params.append(a, .{ .name = "names", .type = "[string]" });
    const each = try graph.addNode(count, "flow.for_each", .{ 0, 0 });
    try graph.connect(count, .{ .node = 1, .pin = run_out }, .{ .node = each, .pin = run_in });
    try graph.connect(count, .{ .node = 1, .pin = "names" }, .{ .node = each, .pin = "list" });
    const find = try graph.addNode(count, "call", .{ 0, 0 });
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(a, "name");
    count.node(find).?.call = .{ .on = .global, .of = "app", .name = "find", .args = args, .gives = true };
    try graph.connect(count, .{ .node = each, .pin = "body" }, .{ .node = find, .pin = run_in });
    try graph.connect(count, .{ .node = each, .pin = "item" }, .{ .node = find, .pin = "name" });
    const say = try graph.addNode(count, "flow.print", .{ 0, 0 });
    try graph.connect(count, .{ .node = find, .pin = run_out }, .{ .node = say, .pin = run_in });
    try graph.connect(count, .{ .node = find, .pin = result_pin }, .{ .node = say, .pin = "value" });
    const done = try graph.addNode(count, "flow.return", .{ 0, 0 });
    try graph.connect(count, .{ .node = each, .pin = run_out }, .{ .node = done, .pin = run_in });
    try graph.setValue(count, done, "value", .{ .int = 7 });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const made = try compile(arena.allocator(), &graph.file, .{});
    try testing.expectEqual(@as(usize, 0), made.problems.len);
    try testing.expectEqualStrings(
        \\// Made from a graph by fluxion-graph: the graph is what to change.
        \\const tools = @import("tools.flux");
        \\struct Counter {
        \\    var tint: color = color("#FF8000");
        \\    var at: vec2 = vec2(1.0, 2.5);
        \\    fn count(self, names: [string]) int {
        \\        for (names) |item2, index2| {
        \\            const n3 = app.find(item2);
        \\            print(n3);
        \\        }
        \\        return 7;
        \\    }
        \\}
        \\
    , made.text);
}
