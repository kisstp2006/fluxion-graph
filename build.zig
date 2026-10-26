// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const json = b.dependency("fluxion_json", .{ .target = target, .optimize = optimize });
    const script = b.dependency("fluxion_script", .{ .target = target, .optimize = optimize });

    // The graphs, what is in them, how they are written and the nodes there
    // are: no interface, so a game's runtime can read them as the editor
    // does. A program that has fluxion-script and fluxion-json already
    // builds `src/root.zig` over its own, so that a type is one type.
    const mod = b.addModule("fluxion_graph", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_json", .module = json.module("fluxion_json") },
            .{ .name = "fluxion_script", .module = script.module("fluxion_script") },
        },
    });

    const tests = b.addTest(.{ .name = "fluxion-graph-tests", .root_module = mod });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
