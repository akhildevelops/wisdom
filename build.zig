const std = @import("std");

pub fn build(b: *std.Build) void {
    // Build Options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //Huggingface Module and Commandline
    const hf_module = b.addModule("hf_hub", .{ .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = "huggingface/lib.zig" } } });
    const exe = b.addExecutable(.{
        .name = "hf_hub",
        .root_source_file = b.path("src/cmd.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.root_module.addImport("hf_hub", hf_module);
    b.installArtifact(exe);

    //Tests
    const hf_test = b.addTest(.{
        .name = "hf_test",
        .root_source_file = b.path("huggingface/artifacts.zig"),
    });
    const test_run = b.addRunArtifact(hf_test);
    const test_step = b.step("test", "Run Test");
    test_step.dependOn(&test_run.step);
}
