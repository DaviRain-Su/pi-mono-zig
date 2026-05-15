const std = @import("std");
const package_command_parser = @import("package_command_parser.zig");
const package_settings_store = @import("package_settings_store.zig");
const self_update = @import("self_update.zig");

pub const PackageCommand = package_command_parser.PackageCommand;
pub const ConfigKind = package_settings_store.ConfigKind;
pub const ConfigToggleAction = package_command_parser.ConfigToggleAction;
pub const ConfigOptions = package_command_parser.ConfigOptions;
pub const UpdateTarget = package_command_parser.UpdateTarget;
pub const ParsedCommand = package_command_parser.ParsedCommand;
pub const ParseError = package_command_parser.ParseError;
pub const isPackageCommand = package_command_parser.isPackageCommand;
pub const parsePackageCommand = package_command_parser.parsePackageCommand;
pub const packageCommandName = package_command_parser.packageCommandName;
pub const packageCommandUsage = package_command_parser.packageCommandUsage;

pub const ExecuteOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    npm_command_override: ?[]const []const u8 = null,
    git_command_override: ?[]const []const u8 = null,
    self_update_command_override: ?[]const []const u8 = null,
    self_update_method_override: SelfUpdatePackageManager = .npm,
    self_update_latest_release_override: ?LatestSelfUpdateRelease = null,
    self_update_latest_release_probe: ?*usize = null,
    current_version: []const u8 = "0.1.0",
    stdout_is_tty: bool = false,
    env_map: ?*const std.process.Environ.Map = null,
    fail_settings_write_for_testing: bool = false,
    fail_lockfile_write_for_testing: bool = false,
    fail_policy_write_for_testing: bool = false,
};

pub const SelfUpdatePackageManager = self_update.SelfUpdatePackageManager;
pub const LatestSelfUpdateRelease = self_update.LatestSelfUpdateRelease;
pub const ExecuteResult = self_update.ExecuteResult;

pub fn executePackageCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: ParsedCommand,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    if (command.help) {
        try writePackageCommandHelp(stdout, command.command);
        return .{ .exit_code = 0 };
    }

    if (command.parse_error) |message| {
        try stderr.print("Error: {s}\nUsage: {s}\n", .{ message, packageCommandUsage(command.command) });
        return .{ .exit_code = 1 };
    }

    return switch (command.command) {
        .install, .remove => unsupportedPackageCommand(stderr),
        .list => executeList(stdout),
        .config => executeConfig(command, stdout),
        .update => executeUpdate(allocator, io, command, options, stdout, stderr),
    };
}

fn executeUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: ParsedCommand,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    const target = command.update_target orelse .all;
    return switch (target) {
        .self => self_update.executeSelfUpdate(allocator, io, command.force, selfUpdateOptions(options), stdout, stderr),
        .all => if (command.update_self)
            self_update.executeSelfUpdate(allocator, io, command.force, selfUpdateOptions(options), stdout, stderr)
        else
            unsupportedPackageCommand(stderr),
        .extensions, .source => unsupportedPackageCommand(stderr),
    };
}

fn executeList(stdout: *std.Io.Writer) !ExecuteResult {
    try stdout.writeAll("Extension packages are not supported by the Zig runtime.\n");
    return .{ .exit_code = 0 };
}

fn executeConfig(command: ParsedCommand, stdout: *std.Io.Writer) !ExecuteResult {
    _ = command;
    try stdout.writeAll(
        \\Configurable resource package toggles are not supported by the Zig runtime.
        \\
    );
    return .{ .exit_code = 0 };
}

fn unsupportedPackageCommand(stderr: *std.Io.Writer) !ExecuteResult {
    try stderr.writeAll("Error: extension package management is not supported by the Zig runtime.\n");
    return .{ .exit_code = 1 };
}

fn selfUpdateOptions(options: ExecuteOptions) self_update.ExecuteOptions {
    return .{
        .self_update_command_override = options.self_update_command_override,
        .self_update_method_override = options.self_update_method_override,
        .self_update_latest_release_override = options.self_update_latest_release_override,
        .self_update_latest_release_probe = options.self_update_latest_release_probe,
        .current_version = options.current_version,
    };
}

fn writePackageCommandHelp(stdout: *std.Io.Writer, command: PackageCommand) !void {
    switch (command) {
        .install => try stdout.writeAll(
            \\Usage:
            \\  pi install <source> [-l]
            \\
            \\Extension package installation is not supported by the Zig runtime.
            \\
        ),
        .remove => try stdout.writeAll(
            \\Usage:
            \\  pi remove <source> [-l]
            \\
            \\Extension package removal is not supported by the Zig runtime.
            \\
        ),
        .update => try stdout.writeAll(
            \\Usage:
            \\  pi update self [--force]
            \\
            \\Only self-update is supported by the Zig runtime. Extension package updates are disabled.
            \\
        ),
        .list => try stdout.writeAll(
            \\Usage:
            \\  pi list
            \\
            \\Extension packages are not supported by the Zig runtime.
            \\
        ),
        .config => try stdout.writeAll(
            \\Usage:
            \\  pi config
            \\
            \\Extension package resource toggles are not supported by the Zig runtime.
            \\
        ),
    }
}
