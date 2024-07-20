const std = @import("std");

pub fn build(b: *std.Build) void {
    const hf_hub_dep = b.dependency("hf_hub", .{});
    const hf_hub_module = hf_hub_dep.module("hf_hub");

    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "hf_hub_example",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("hf_hub", hf_hub_module);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
