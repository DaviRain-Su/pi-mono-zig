const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const vaxis_mod = vaxis_dep.module("vaxis");

    const vaxis_widgets = b.addModule("vaxis-widgets", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    vaxis_widgets.addImport("vaxis", vaxis_mod);

    const lib = b.addLibrary(.{
        .name = "vaxis-widgets",
        .root_module = vaxis_widgets,
    });
    b.installArtifact(lib);

    const test_step = b.step("test", "Run unit tests");
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("vaxis", vaxis_mod);
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}
