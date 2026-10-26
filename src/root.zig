// SPDX-License-Identifier: BSD-2-Clause

//! Fluxion Graph - scripts drawn as graphs of nodes, which compile to Flux and
//! run on its VM as Flux written by hand does. See README.md.

pub const model = @import("model.zig");
pub const Graph = @import("Graph.zig");
pub const compile = @import("compile.zig");
pub const catalog = @import("catalog.zig");

pub const extension = model.extension;
pub const version = model.version;

test {
    _ = model;
    _ = Graph;
    _ = compile;
    _ = catalog;
}
