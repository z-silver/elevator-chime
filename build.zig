const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const no_bin = b.option(bool, "no-bin", "Skip emitting binary") orelse false;

    const optimize = b.standardOptimizeOption(.{});

    const vm = b.addExecutable(.{
        .name = "elevator-chime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_cmd = b.addRunArtifact(vm);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const chaff = b.addExecutable(.{
        .name = "chaff",
        .root_source_file = b.path("src/chaff.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (no_bin) {
        b.getInstallStep().dependOn(&vm.step);
        b.getInstallStep().dependOn(&chaff.step);
    } else {
        b.installArtifact(vm);
        b.installArtifact(chaff);
    }
    const compile_cmd = b.addRunArtifact(chaff);
    compile_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        compile_cmd.addArgs(args);
    }
    const compile_step = b.step("chaff", "Compile a program written in chaff assembly syntax");
    compile_step.dependOn(&compile_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
