const std = @import("std");

pub fn build(b: *std.Build) void {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const optimize = std.builtin.OptimizeMode.ReleaseSmall;
    const test_target = b.standardTargetOptions(.{});

    const sdk_mod = b.createModule(.{
        .root_source_file = b.path("sdk/pi_extension_sdk.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .strip = true,
    });
    const plugin_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .strip = true,
    });
    plugin_mod.addImport("pi-extension-sdk", sdk_mod);

    const plugin = b.addExecutable(.{
        .name = "plugin",
        .root_module = plugin_mod,
    });
    plugin.entry = .disabled;
    plugin.rdynamic = true;
    plugin.export_memory = true;

    const install_plugin = b.addInstallArtifact(plugin, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
        .dest_sub_path = "plugin.wasm",
    });
    b.getInstallStep().dependOn(&install_plugin.step);

    const native_sdk_mod = b.createModule(.{
        .root_source_file = b.path("sdk/pi_extension_sdk.zig"),
        .target = test_target,
        .optimize = optimize,
    });
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/main.zig"),
        .target = test_target,
        .optimize = optimize,
    });
    test_mod.addImport("pi-extension-sdk", native_sdk_mod);
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run extension template tests");
    test_step.dependOn(&run_tests.step);
}
