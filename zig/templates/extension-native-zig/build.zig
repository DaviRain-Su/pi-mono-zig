const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const platform_dir = b.fmt("native/{s}-{s}", .{ @tagName(target.result.os.tag), @tagName(target.result.cpu.arch) });

    const sdk_mod = b.createModule(.{
        .root_source_file = b.path("sdk/pi_native_extension_sdk.zig"),
        .target = target,
        .optimize = optimize,
    });
    const library_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    library_mod.addImport("pi-native-extension-sdk", sdk_mod);

    const library = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "pi_native_template_echo",
        .root_module = library_mod,
    });
    const install_library = b.addInstallArtifact(library, .{
        .dest_dir = .{ .override = .{ .custom = platform_dir } },
    });
    b.getInstallStep().dependOn(&install_library.step);

    const test_sdk_mod = b.createModule(.{
        .root_source_file = b.path("sdk/pi_native_extension_sdk.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("pi-native-extension-sdk", test_sdk_mod);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run native extension template tests");
    test_step.dependOn(&run_tests.step);

    const validate_step = b.step("validate", "Run local native author validation before install");
    validate_step.dependOn(&run_tests.step);
}
