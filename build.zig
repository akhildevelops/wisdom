const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //Huggingface
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

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
