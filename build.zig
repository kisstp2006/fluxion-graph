// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const json = b.dependency("fluxion_json", .{ .target = target, .optimize = optimize });

    // The graphs, what is in them and how they are written: no interface,
    // so a game's runtime can read them as the editor does.
    const mod = b.addModule("fluxion_graph", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_json", .module = json.module("fluxion_json") },
        },
    });

    const tests = b.addTest(.{ .name = "fluxion-graph-tests", .root_module = mod });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
