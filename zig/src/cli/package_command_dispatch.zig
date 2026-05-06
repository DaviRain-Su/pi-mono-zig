const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("../coding_agent/config/config.zig");
const package_manager = @import("../coding_agent/packages/package_manager.zig");
const cli_test = if (builtin.is_test) @import("test_harness.zig") else struct {};

/// Dispatch package-management subcommands (`pi install`, `pi remove`,
/// `pi uninstall`, `pi update`, `pi list`, `pi config`) before the standard CLI
/// parser runs. The package commands have their own positional and option
/// grammar that the regular parser would misclassify as prompt text or
/// top-level flags.
pub fn dispatchPackageCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argv: []const []const u8,
    cwd_override: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !?u8 {
    if (!package_manager.isPackageCommand(argv)) return null;

    var package_command = package_manager.parsePackageCommand(allocator, argv) catch |err| switch (err) {
        error.NotPackageCommand => unreachable,
        else => return err,
    };
    defer package_command.deinit(allocator);

    const cwd = try resolveCwd(allocator, io, cwd_override);
    defer allocator.free(cwd);

    const agent_dir = try config_mod.resolveAgentDir(allocator, env_map);
    defer allocator.free(agent_dir);

    const stdout_is_tty = std.Io.File.stdout().isTty(io) catch false;
    const result = try package_manager.executePackageCommand(
        allocator,
        io,
        package_command,
        .{
            .cwd = cwd,
            .agent_dir = agent_dir,
            .stdout_is_tty = stdout_is_tty,
            .env_map = env_map,
        },
        stdout,
        stderr,
    );
    return result.exit_code;
}

fn resolveCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd_override: ?[]const u8,
) ![]u8 {
    if (cwd_override) |override| {
        return allocator.dupe(u8, override);
    }

    const real_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(real_cwd);
    return allocator.dupe(u8, real_cwd);
}

test "dispatchPackageCommand returns null for non-package argv" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try dispatchPackageCommand(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--print", "install" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(?u8, null), exit_code);
    try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "dispatchPackageCommand preserves cwd override and agent-dir package scopes" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "project");

    const agent_dir = try cli_test.makeTmpPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const project_dir = try cli_test.makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const local_exit = try dispatchPackageCommand(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "install", "--local", "./local-fixture" },
        project_dir,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(?u8, 0), local_exit);

    const user_exit = try dispatchPackageCommand(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "install", "./user-fixture" },
        project_dir,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(?u8, 0), user_exit);
    try std.testing.expectEqualStrings(
        "Installed ./local-fixture\nInstalled ./user-fixture\n",
        stdout_capture.writer.buffered(),
    );
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    const local_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ project_dir, ".pi", "settings.json" });
    defer allocator.free(local_settings_path);
    const local_settings = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, local_settings_path, allocator, .unlimited);
    defer allocator.free(local_settings);
    try std.testing.expect(std.mem.indexOf(u8, local_settings, "\"source\": \"./local-fixture\"") != null);

    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    const user_settings = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, user_settings_path, allocator, .unlimited);
    defer allocator.free(user_settings);
    try std.testing.expect(std.mem.indexOf(u8, user_settings, "\"source\": \"./user-fixture\"") != null);
}
