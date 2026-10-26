// SPDX-License-Identifier: BSD-2-Clause

//! `fluxion-graph-flux <file.fxgraph>`: the Flux a graph is made into, on
//! standard output, and what cannot be made of it on standard error - what
//! the editor's "Show Flux" shows, for a terminal.

const std = @import("std");
const graph = @import("fluxion_graph");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse {
        std.debug.print("usage: fluxion-graph-flux <file.fxgraph>\n", .{});
        return 2;
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
    defer gpa.free(bytes);
    var g = graph.Graph.read(gpa, bytes, null) catch |err| {
        std.debug.print("{s} does not read as a graph: {t}\n", .{ path, err });
        return 1;
    };
    defer g.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const made = try graph.compile.compile(arena.allocator(), &g.file, .{ .path = path });
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    try out.interface.writeAll(made.text);
    try out.interface.flush();
    for (made.problems) |p| {
        const function = if (p.function) |at| g.file.functions.items[at].name else "the struct";
        std.debug.print("{s}: {s}, node {d}: {s}\n", .{ path, function, p.node, p.message });
    }
    return if (made.problems.len > 0) 1 else 0;
}
