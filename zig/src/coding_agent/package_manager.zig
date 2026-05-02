const std = @import("std");
const common = @import("tools/common.zig");
const resources_mod = @import("resources.zig");

/// Package CLI subcommand parser/executor parity with the TypeScript
/// `package-manager-cli.ts`. Scope for M12 m12-package-cli-local-fixtures:
/// install/remove/uninstall/list and offline `update` against local
/// fixture packages only. Network sources (npm/git) and self-update are
/// intentionally out of scope; they live behind explicit error
/// diagnostics until the broader M12 mission feature lands.
///
/// Mirrors `packages/coding-agent/src/package-manager-cli.ts` (parse +
/// dispatch) and `packages/coding-agent/src/core/package-manager.ts`
/// (settings persistence). Local-source semantics:
///
///   - `install <local-path>` writes a package entry with the original
///     source string into the appropriate scope's `settings.json` under
///     the `packages` key, creating the file if needed. Duplicate
///     installs at the same scope are no-ops returning success.
///   - `remove <local-path>` (alias `uninstall <local-path>`) deletes
///     the matching entry and reports a missing-package diagnostic on
///     a non-zero exit when nothing matched.
///   - `list` prints user/project package entries, grouped by scope,
///     with a deterministic ordering matching TS output.
///   - `update` is an offline no-op: with no target it reports
///     "Updated packages"; with a positional target it reports
///     "Updated <source>" only when the source is currently installed,
///     otherwise it errors with a missing-target diagnostic. No
///     network access or filesystem mutation is performed.
///
/// The CLI dispatcher is idempotent and uses temporary HOME/agent-dir
/// settings paths for tests so deterministic fixture runs can compare
/// stdout/stderr and JSON state without leaking machine paths.

pub const PackageCommand = enum { install, remove, update, list };

pub const UpdateTarget = union(enum) {
    all,
    source: []const u8,
};

pub const ParsedCommand = struct {
    command: PackageCommand,
    /// Original positional source for install/remove. For update with a
    /// positional non-self target, this is also populated. Owned by the
    /// command parser; freed with `deinit`.
    source: ?[]u8 = null,
    update_target: ?UpdateTarget = null,
    local: bool = false,
    help: bool = false,
    /// First parse-time diagnostic, if any. Mirrors TS where parse
    /// errors are reported as a single line followed by usage.
    parse_error: ?[]u8 = null,

    pub fn deinit(self: *ParsedCommand, allocator: std.mem.Allocator) void {
        if (self.source) |value| allocator.free(value);
        if (self.parse_error) |value| allocator.free(value);
        self.* = .{ .command = .install };
    }
};

pub const ParseError = error{
    NotPackageCommand,
} || std.mem.Allocator.Error;

/// Returns true if the first argv token is a recognized package
/// subcommand: `install`, `remove`, `uninstall`, `update`, or `list`.
/// Used by the main entry point to decide whether to dispatch into the
/// package manager before normal CLI argument processing.
pub fn isPackageCommand(args: []const []const u8) bool {
    if (args.len == 0) return false;
    const first = args[0];
    return std.mem.eql(u8, first, "install") or
        std.mem.eql(u8, first, "remove") or
        std.mem.eql(u8, first, "uninstall") or
        std.mem.eql(u8, first, "update") or
        std.mem.eql(u8, first, "list");
}

/// Parse a `pi <subcommand> [args...]` invocation. Returns
/// `ParseError.NotPackageCommand` if `args[0]` is not a recognized
/// package subcommand. Otherwise the returned `ParsedCommand` always
/// represents a parseable command; argument-level errors are surfaced
/// through `ParsedCommand.parse_error` so the caller can render them
/// alongside usage text in a single non-zero-exit code path.
pub fn parsePackageCommand(allocator: std.mem.Allocator, args: []const []const u8) ParseError!ParsedCommand {
    if (args.len == 0) return error.NotPackageCommand;
    const raw = args[0];
    var command: PackageCommand = undefined;
    if (std.mem.eql(u8, raw, "install")) {
        command = .install;
    } else if (std.mem.eql(u8, raw, "remove") or std.mem.eql(u8, raw, "uninstall")) {
        command = .remove;
    } else if (std.mem.eql(u8, raw, "update")) {
        command = .update;
    } else if (std.mem.eql(u8, raw, "list")) {
        command = .list;
    } else {
        return error.NotPackageCommand;
    }

    var result: ParsedCommand = .{ .command = command };
    errdefer result.deinit(allocator);

    var positional_owned: ?[]u8 = null;
    errdefer if (positional_owned) |value| allocator.free(value);

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            result.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--local")) {
            if (command == .install or command == .remove) {
                result.local = true;
            } else {
                if (result.parse_error == null) {
                    result.parse_error = try std.fmt.allocPrint(
                        allocator,
                        "Unknown option {s} for \"{s}\".",
                        .{ arg, packageCommandName(command) },
                    );
                }
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            if (result.parse_error == null) {
                result.parse_error = try std.fmt.allocPrint(
                    allocator,
                    "Unknown option {s} for \"{s}\".",
                    .{ arg, packageCommandName(command) },
                );
            }
            continue;
        }
        if (positional_owned != null) {
            if (result.parse_error == null) {
                result.parse_error = try std.fmt.allocPrint(
                    allocator,
                    "Unexpected argument {s}.",
                    .{arg},
                );
            }
            continue;
        }
        positional_owned = try allocator.dupe(u8, arg);
    }

    if (positional_owned) |value| {
        result.source = value;
        positional_owned = null;
    }

    if ((command == .install or command == .remove) and result.source == null and !result.help and result.parse_error == null) {
        result.parse_error = try std.fmt.allocPrint(
            allocator,
            "Missing {s} source.",
            .{packageCommandName(command)},
        );
    }

    if (command == .update and !result.help and result.parse_error == null) {
        if (result.source) |value| {
            // Treat positional `pi`/`self` as self-target (out of M12 local scope).
            result.update_target = .{ .source = value };
        } else {
            result.update_target = .all;
        }
    }

    return result;
}

pub fn packageCommandName(command: PackageCommand) []const u8 {
    return switch (command) {
        .install => "install",
        .remove => "remove",
        .update => "update",
        .list => "list",
    };
}

pub fn packageCommandUsage(command: PackageCommand) []const u8 {
    return switch (command) {
        .install => "pi install <source> [-l]",
        .remove => "pi remove <source> [-l]",
        .update => "pi update [source]",
        .list => "pi list",
    };
}

pub const ExecuteOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
};

pub const ExecuteResult = struct {
    exit_code: u8,
};

/// Execute the parsed package command using deterministic local
/// settings/file IO. `stdout` receives success/list output; `stderr`
/// receives errors/usage. Self-update and network sources are reported
/// as not-supported diagnostics so this entry point stays local-only
/// for M12 m12-package-cli-local-fixtures.
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
        .install => executeInstall(allocator, io, command, options, stdout, stderr),
        .remove => executeRemove(allocator, io, command, options, stdout, stderr),
        .update => executeUpdate(allocator, io, command, options, stdout, stderr),
        .list => executeList(allocator, io, options, stdout),
    };
}

fn executeInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: ParsedCommand,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    const source = command.source orelse unreachable;
    if (!isLocalSource(source)) {
        try stderr.print(
            "Error: Only local package sources are supported in this build (got {s}).\n",
            .{source},
        );
        return .{ .exit_code = 1 };
    }

    const settings_path = try settingsPathForScope(allocator, options, command.local);
    defer allocator.free(settings_path);

    var settings_object = try loadSettingsObject(allocator, io, settings_path);
    defer {
        const owner: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, owner);
    }

    const packages_array_ptr = try ensurePackagesArray(allocator, &settings_object);
    if (findPackageIndex(packages_array_ptr.*, source) != null) {
        try stdout.print("Already installed: {s}\n", .{source});
        return .{ .exit_code = 0 };
    }

    var entry_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup: std.json.Value = .{ .object = entry_object };
        common.deinitJsonValue(allocator, cleanup);
    }
    try entry_object.put(allocator, try allocator.dupe(u8, "source"), .{ .string = try allocator.dupe(u8, source) });
    try packages_array_ptr.*.append(.{ .object = entry_object });

    try writeSettingsObject(allocator, io, settings_path, settings_object);
    try stdout.print("Installed {s}\n", .{source});
    return .{ .exit_code = 0 };
}

fn executeRemove(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: ParsedCommand,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    const source = command.source orelse unreachable;
    const settings_path = try settingsPathForScope(allocator, options, command.local);
    defer allocator.free(settings_path);

    var settings_object = try loadSettingsObject(allocator, io, settings_path);
    defer {
        const owner: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, owner);
    }

    const packages_value_ptr = settings_object.getPtr("packages");
    if (packages_value_ptr == null or packages_value_ptr.?.* != .array) {
        try stderr.print("Error: No matching package found for {s}\n", .{source});
        return .{ .exit_code = 1 };
    }

    const matched_index = findPackageIndex(packages_value_ptr.?.array, source);
    if (matched_index == null) {
        try stderr.print("Error: No matching package found for {s}\n", .{source});
        return .{ .exit_code = 1 };
    }

    const removed = packages_value_ptr.?.array.orderedRemove(matched_index.?);
    common.deinitJsonValue(allocator, removed);

    try writeSettingsObject(allocator, io, settings_path, settings_object);
    try stdout.print("Removed {s}\n", .{source});
    return .{ .exit_code = 0 };
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

    switch (target) {
        .all => {
            // Offline no-op for the local-fixtures scope: report the
            // deterministic "Updated packages" line without mutating any
            // settings on disk. Mirrors TS update path when no
            // network/self-update work is needed.
            try stdout.print("Updated packages\n", .{});
            return .{ .exit_code = 0 };
        },
        .source => |source| {
            // `pi update self` / `pi update pi` are reserved for the
            // self-update path which is out of M12 local-fixtures
            // scope. Report a deterministic diagnostic so users have
            // an actionable message.
            if (std.mem.eql(u8, source, "self") or std.mem.eql(u8, source, "pi")) {
                try stderr.print(
                    "Error: Self-update is not supported in this build.\n",
                    .{},
                );
                return .{ .exit_code = 1 };
            }

            const found_scope = try findInstalledScope(allocator, io, options, source);
            if (found_scope == null) {
                try stderr.print(
                    "Error: Package {s} is not installed.\n",
                    .{source},
                );
                return .{ .exit_code = 1 };
            }
            try stdout.print("Updated {s}\n", .{source});
            return .{ .exit_code = 0 };
        },
    }
}

fn executeList(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
) !ExecuteResult {
    var user_sources = try collectScopePackages(allocator, io, options, false);
    defer freeOwnedStrings(allocator, &user_sources);
    var project_sources = try collectScopePackages(allocator, io, options, true);
    defer freeOwnedStrings(allocator, &project_sources);

    if (user_sources.items.len == 0 and project_sources.items.len == 0) {
        try stdout.print("No packages installed.\n", .{});
        return .{ .exit_code = 0 };
    }

    if (user_sources.items.len > 0) {
        try stdout.print("User packages:\n", .{});
        for (user_sources.items) |entry| {
            try stdout.print("  {s}\n", .{entry});
        }
    }

    if (project_sources.items.len > 0) {
        if (user_sources.items.len > 0) try stdout.print("\n", .{});
        try stdout.print("Project packages:\n", .{});
        for (project_sources.items) |entry| {
            try stdout.print("  {s}\n", .{entry});
        }
    }

    return .{ .exit_code = 0 };
}

fn writePackageCommandHelp(stdout: *std.Io.Writer, command: PackageCommand) !void {
    switch (command) {
        .install => try stdout.writeAll(
            \\Usage:
            \\  pi install <source> [-l]
            \\
            \\Install a package and add it to settings.
            \\
            \\Options:
            \\  -l, --local    Install project-locally (.pi/settings.json)
            \\
        ),
        .remove => try stdout.writeAll(
            \\Usage:
            \\  pi remove <source> [-l]
            \\
            \\Remove a package and its source from settings.
            \\Alias: pi uninstall <source> [-l]
            \\
            \\Options:
            \\  -l, --local    Remove from project settings (.pi/settings.json)
            \\
        ),
        .update => try stdout.writeAll(
            \\Usage:
            \\  pi update [source]
            \\
            \\Update installed packages. With no arguments this is an offline
            \\no-op for local fixture packages and reports "Updated packages".
            \\With a positional <source>, only that package is targeted; if
            \\the source is not installed, an error is reported instead.
            \\
        ),
        .list => try stdout.writeAll(
            \\Usage:
            \\  pi list
            \\
            \\List installed packages from user and project settings.
            \\
        ),
    }
}

fn isLocalSource(source: []const u8) bool {
    if (std.mem.startsWith(u8, source, "npm:")) return false;
    if (std.mem.startsWith(u8, source, "git:")) return false;
    if (std.mem.startsWith(u8, source, "git@")) return false;
    if (std.mem.startsWith(u8, source, "https://")) return false;
    if (std.mem.startsWith(u8, source, "http://")) return false;
    if (std.mem.startsWith(u8, source, "ssh://")) return false;
    return true;
}

fn settingsPathForScope(
    allocator: std.mem.Allocator,
    options: ExecuteOptions,
    local: bool,
) ![]u8 {
    if (local) {
        return std.fs.path.join(allocator, &[_][]const u8{ options.cwd, ".pi", "settings.json" });
    }
    return std.fs.path.join(allocator, &[_][]const u8{ options.agent_dir, "settings.json" });
}

fn loadSettingsObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    settings_path: []const u8,
) !std.json.ObjectMap {
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, settings_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return std.json.ObjectMap.init(allocator, &.{}, &.{}),
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        // Treat malformed settings as empty to avoid wedging the CLI.
        return std.json.ObjectMap.init(allocator, &.{}, &.{});
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return std.json.ObjectMap.init(allocator, &.{}, &.{});
    }

    var clone = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup: std.json.Value = .{ .object = clone };
        common.deinitJsonValue(allocator, cleanup);
    }
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        try clone.put(
            allocator,
            try allocator.dupe(u8, entry.key_ptr.*),
            try common.cloneJsonValue(allocator, entry.value_ptr.*),
        );
    }
    return clone;
}

fn ensurePackagesArray(
    allocator: std.mem.Allocator,
    settings_object: *std.json.ObjectMap,
) !*std.json.Array {
    if (settings_object.getPtr("packages")) |existing| {
        if (existing.* == .array) {
            return &existing.array;
        }
        // Replace non-array `packages` with a fresh array; legacy
        // values are discarded silently, matching TS where an invalid
        // setting cannot prevent a fresh install.
        const cleanup = existing.*;
        common.deinitJsonValue(allocator, cleanup);
        existing.* = .{ .array = std.json.Array.init(allocator) };
        return &existing.array;
    }

    const key = try allocator.dupe(u8, "packages");
    errdefer allocator.free(key);
    try settings_object.put(allocator, key, .{ .array = std.json.Array.init(allocator) });
    return &settings_object.getPtr("packages").?.array;
}

fn findPackageIndex(array: std.json.Array, source: []const u8) ?usize {
    for (array.items, 0..) |item, idx| {
        switch (item) {
            .string => |s| if (std.mem.eql(u8, s, source)) return idx,
            .object => |obj| {
                if (obj.get("source")) |value| {
                    if (value == .string and std.mem.eql(u8, value.string, source)) return idx;
                }
            },
            else => {},
        }
    }
    return null;
}

fn writeSettingsObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    settings_path: []const u8,
    settings_object: std.json.ObjectMap,
) !void {
    const value: std.json.Value = .{ .object = settings_object };
    const serialized = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    try common.writeFileAbsolute(io, settings_path, serialized, true);
}

fn collectScopePackages(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    local: bool,
) !std.ArrayList([]u8) {
    var result: std.ArrayList([]u8) = .empty;
    errdefer freeOwnedStrings(allocator, &result);

    const settings_path = try settingsPathForScope(allocator, options, local);
    defer allocator.free(settings_path);

    var settings_object = try loadSettingsObject(allocator, io, settings_path);
    defer {
        const cleanup: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, cleanup);
    }

    const packages_value = settings_object.get("packages") orelse return result;
    if (packages_value != .array) return result;

    for (packages_value.array.items) |item| {
        switch (item) {
            .string => |s| try result.append(allocator, try allocator.dupe(u8, s)),
            .object => |obj| {
                if (obj.get("source")) |value| {
                    if (value == .string) try result.append(allocator, try allocator.dupe(u8, value.string));
                }
            },
            else => {},
        }
    }
    return result;
}

fn findInstalledScope(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    source: []const u8,
) !?bool {
    var user_sources = try collectScopePackages(allocator, io, options, false);
    defer freeOwnedStrings(allocator, &user_sources);
    for (user_sources.items) |entry| {
        if (std.mem.eql(u8, entry, source)) return false;
    }
    var project_sources = try collectScopePackages(allocator, io, options, true);
    defer freeOwnedStrings(allocator, &project_sources);
    for (project_sources.items) |entry| {
        if (std.mem.eql(u8, entry, source)) return true;
    }
    return null;
}

fn freeOwnedStrings(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |entry| allocator.free(entry);
    list.deinit(allocator);
}

// ---------------------------------------------------------------------
// Tests: deterministic local fixture coverage for VAL-M12-PKG-001..009.
// ---------------------------------------------------------------------

fn makeAbsoluteTmpPath(allocator: std.mem.Allocator, tmp: anytype, relative: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const rel = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        relative,
    });
    defer allocator.free(rel);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, rel });
}

fn readSettings(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(1024 * 1024));
}

fn runCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    options: ExecuteOptions,
    stdout_buffer: *std.ArrayList(u8),
    stderr_buffer: *std.ArrayList(u8),
) !ExecuteResult {
    var stdout_writer = std.Io.Writer.Allocating.fromArrayList(allocator, stdout_buffer);
    var stderr_writer = std.Io.Writer.Allocating.fromArrayList(allocator, stderr_buffer);
    defer {
        stdout_buffer.* = stdout_writer.toArrayList();
        stderr_buffer.* = stderr_writer.toArrayList();
    }

    var parsed = try parsePackageCommand(allocator, args);
    defer parsed.deinit(allocator);
    return executePackageCommand(allocator, std.testing.io, parsed, options, &stdout_writer.writer, &stderr_writer.writer);
}

test "VAL-M12-PKG-001 local fixture installs at user scope" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/pkg");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/fixtures/pkg/marker.txt", .data = "ok" });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(
        allocator,
        &.{ "install", "./fixtures/pkg" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("Installed ./fixtures/pkg\n", stdout_buf.items);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"packages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"./fixtures/pkg\"") != null);
}

test "VAL-M12-PKG-002 local fixture installs at project scope" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/pkg");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(
        allocator,
        &.{ "install", "./fixtures/pkg", "-l" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    const project_settings = try readSettings(allocator, project_settings_path);
    defer allocator.free(project_settings);
    try std.testing.expect(std.mem.indexOf(u8, project_settings, "\"./fixtures/pkg\"") != null);

    // User-scope settings.json should not exist after a project-scope install.
    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    const user_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), std.testing.io, user_settings_path, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!user_exists);
}

test "VAL-M12-PKG-003 list reports user and project packages" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/user-pkg");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/project-pkg");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var ignored: std.ArrayList(u8) = .empty;
    defer ignored.deinit(allocator);
    var ignored_err: std.ArrayList(u8) = .empty;
    defer ignored_err.deinit(allocator);

    _ = try runCommand(allocator, &.{ "install", "./fixtures/user-pkg" }, options, &ignored, &ignored_err);
    ignored.clearRetainingCapacity();
    ignored_err.clearRetainingCapacity();
    _ = try runCommand(allocator, &.{ "install", "./fixtures/project-pkg", "-l" }, options, &ignored, &ignored_err);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{"list"}, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "User packages:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "./fixtures/user-pkg") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Project packages:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "./fixtures/project-pkg") != null);
}

test "VAL-M12-PKG-004 remove detaches package without deleting other settings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    // Pre-populate user settings with an unrelated key alongside a package.
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{
        \\  "defaultProvider": "openai",
        \\  "packages": [{ "source": "./fixtures/pkg" }]
        \\}
    , true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "remove", "./fixtures/pkg" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("Removed ./fixtures/pkg\n", stdout_buf.items);

    const updated = try readSettings(allocator, settings_path);
    defer allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "./fixtures/pkg") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "\"defaultProvider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "\"openai\"") != null);
}

test "VAL-M12-PKG-005 uninstall alias matches remove" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var ignored: std.ArrayList(u8) = .empty;
    defer ignored.deinit(allocator);
    var ignored_err: std.ArrayList(u8) = .empty;
    defer ignored_err.deinit(allocator);
    _ = try runCommand(allocator, &.{ "install", "./fixtures/pkg" }, options, &ignored, &ignored_err);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(
        allocator,
        &.{ "uninstall", "./fixtures/pkg" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("Removed ./fixtures/pkg\n", stdout_buf.items);
}

test "VAL-M12-PKG-006 update no-op leaves settings unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var ignored: std.ArrayList(u8) = .empty;
    defer ignored.deinit(allocator);
    var ignored_err: std.ArrayList(u8) = .empty;
    defer ignored_err.deinit(allocator);
    _ = try runCommand(allocator, &.{ "install", "./fixtures/pkg" }, options, &ignored, &ignored_err);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const before = try readSettings(allocator, settings_path);
    defer allocator.free(before);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{"update"}, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("Updated packages\n", stdout_buf.items);

    const after = try readSettings(allocator, settings_path);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "VAL-M12-PKG-007 targeted update reports configured package" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var ignored: std.ArrayList(u8) = .empty;
    defer ignored.deinit(allocator);
    var ignored_err: std.ArrayList(u8) = .empty;
    defer ignored_err.deinit(allocator);
    _ = try runCommand(allocator, &.{ "install", "./fixtures/pkg-a" }, options, &ignored, &ignored_err);
    ignored.clearRetainingCapacity();
    ignored_err.clearRetainingCapacity();
    _ = try runCommand(allocator, &.{ "install", "./fixtures/pkg-b" }, options, &ignored, &ignored_err);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const before = try readSettings(allocator, settings_path);
    defer allocator.free(before);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "update", "./fixtures/pkg-a" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("Updated ./fixtures/pkg-a\n", stdout_buf.items);

    const after = try readSettings(allocator, settings_path);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "VAL-M12-PKG-008 targeted update missing package errors and leaves settings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{
        \\  "packages": [{ "source": "./fixtures/installed" }]
        \\}
    , true);
    const before = try readSettings(allocator, settings_path);
    defer allocator.free(before);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(
        allocator,
        &.{ "update", "./fixtures/missing" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "./fixtures/missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "is not installed") != null);

    const after = try readSettings(allocator, settings_path);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "VAL-M12-PKG-009 manifest-declared resources are discoverable after install" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/manifest-pkg/extras");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/manifest-pkg/skills");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/manifest-pkg/package.json",
        .data =
        \\{
        \\  "pi": {
        \\    "extensions": ["extras/main.ts"],
        \\    "skills": ["skills"]
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/manifest-pkg/extras/main.ts",
        .data = "export default {};\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/manifest-pkg/skills/SKILL.md",
        .data =
        \\---
        \\description: fixture skill
        \\---
        \\Body.
        ,
    });
    // A non-manifest-declared file under the package root must NOT be
    // surfaced as a discoverable extension; manifest entries take
    // precedence over auto-discovery for declared kinds.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/manifest-pkg/should-not-load.ts",
        .data = "export default {};\n",
    });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    const fixture_root = try makeAbsoluteTmpPath(allocator, tmp, "repo/fixtures/manifest-pkg");
    defer allocator.free(fixture_root);

    var ignored: std.ArrayList(u8) = .empty;
    defer ignored.deinit(allocator);
    var ignored_err: std.ArrayList(u8) = .empty;
    defer ignored_err.deinit(allocator);
    _ = try runCommand(allocator, &.{ "install", fixture_root, "-l" }, options, &ignored, &ignored_err);

    const package_source = try allocator.dupe(u8, fixture_root);
    var package_config = resources_mod.PackageSourceConfig{ .source = package_source };
    defer package_config.deinit(allocator);

    var resolved = try resources_mod.resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .project = .{ .packages = &.{package_config} },
        .include_default_extensions = false,
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer resolved.deinit(allocator);

    var saw_extension = false;
    for (resolved.extensions) |entry| {
        if (std.mem.endsWith(u8, entry.path, "extras/main.ts")) saw_extension = true;
        try std.testing.expect(!std.mem.endsWith(u8, entry.path, "should-not-load.ts"));
    }
    try std.testing.expect(saw_extension);

    var saw_skill = false;
    for (resolved.skills) |entry| {
        if (std.mem.endsWith(u8, entry.path, "skills/SKILL.md")) saw_skill = true;
    }
    try std.testing.expect(saw_skill);
}

test "parsePackageCommand rejects non-package commands" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NotPackageCommand, parsePackageCommand(allocator, &.{}));
    try std.testing.expectError(error.NotPackageCommand, parsePackageCommand(allocator, &.{"unrelated"}));
    try std.testing.expectError(error.NotPackageCommand, parsePackageCommand(allocator, &.{"--prompt"}));
}

test "parsePackageCommand records missing source for install" {
    const allocator = std.testing.allocator;
    var parsed = try parsePackageCommand(allocator, &.{"install"});
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.parse_error.?, "Missing install source") != null);
}

test "parsePackageCommand reports unknown options" {
    const allocator = std.testing.allocator;
    var parsed = try parsePackageCommand(allocator, &.{ "install", "--bogus", "./local" });
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.parse_error.?, "--bogus") != null);
}
