const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // const mode = b.standardReleaseOptions();

    // exe.setBuildMode(mode);
    //exe.addPackagePath("json", "libs/zig-json/src/main.zig");
    // exe.addPackagePath("glob", "libs/zig-glob/src/main.zig");

    const libglob = b.dependency("glob-zig", .{
        // These are the arguments to the dependency. It expects a target and optimization level.
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zink",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // my_remote_dep exposes a Zig module we wish to depend on.
    exe.root_module.addImport("glob", libglob.module("glob"));

    // _ = b.createModule("glob", libglob.module("glob"));
    // b.addImport(libglob.artifact("glob"));
    // exe.linkLibrary(libglob.artifact("glob"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });

    const run_unit_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_unit_tests.step);
}
