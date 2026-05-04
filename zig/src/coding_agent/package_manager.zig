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

pub const PackageCommand = enum { install, remove, update, list, config };

pub const ConfigKind = enum {
    extensions,
    skills,
    prompts,
    themes,

    pub fn fromString(value: []const u8) ?ConfigKind {
        if (std.mem.eql(u8, value, "extensions")) return .extensions;
        if (std.mem.eql(u8, value, "skills")) return .skills;
        if (std.mem.eql(u8, value, "prompts")) return .prompts;
        if (std.mem.eql(u8, value, "themes")) return .themes;
        return null;
    }

    pub fn settingsKey(self: ConfigKind) []const u8 {
        return switch (self) {
            .extensions => "extensions",
            .skills => "skills",
            .prompts => "prompts",
            .themes => "themes",
        };
    }
};

pub const ConfigToggleAction = enum { enable, disable };

pub const ConfigOptions = struct {
    /// When set, the config command performs a deterministic
    /// non-interactive toggle (used by tests and CLI parity); when
    /// absent, the command prints a deterministic listing and usage.
    toggle_kind: ?ConfigKind = null,
    toggle_pattern: ?[]u8 = null,
    toggle_action: ConfigToggleAction = .enable,

    fn deinit(self: *ConfigOptions, allocator: std.mem.Allocator) void {
        if (self.toggle_pattern) |value| allocator.free(value);
        self.* = .{};
    }
};

pub const UpdateTarget = union(enum) {
    all,
    self,
    source: []const u8,
};

pub const ParsedCommand = struct {
    command: PackageCommand,
    /// Original positional source for install/remove. For update with a
    /// positional non-self target, this is also populated. Owned by the
    /// command parser; freed with `deinit`.
    source: ?[]u8 = null,
    update_target: ?UpdateTarget = null,
    config_options: ConfigOptions = .{},
    local: bool = false,
    force: bool = false,
    help: bool = false,
    /// First parse-time diagnostic, if any. Mirrors TS where parse
    /// errors are reported as a single line followed by usage.
    parse_error: ?[]u8 = null,

    pub fn deinit(self: *ParsedCommand, allocator: std.mem.Allocator) void {
        if (self.source) |value| allocator.free(value);
        if (self.parse_error) |value| allocator.free(value);
        self.config_options.deinit(allocator);
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
        std.mem.eql(u8, first, "list") or
        std.mem.eql(u8, first, "config");
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
    } else if (std.mem.eql(u8, raw, "config")) {
        command = .config;
    } else {
        return error.NotPackageCommand;
    }

    var result: ParsedCommand = .{ .command = command };
    errdefer result.deinit(allocator);

    var positional_owned: ?[]u8 = null;
    errdefer if (positional_owned) |value| allocator.free(value);

    // Tracks --toggle <kind> <pattern> for `pi config`. Both args must be
    // present and the kind must resolve before the positional pattern is
    // accepted.
    var saw_toggle_flag = false;
    var pending_toggle_kind: ?ConfigKind = null;
    var pending_toggle_pattern_owned: ?[]u8 = null;
    errdefer if (pending_toggle_pattern_owned) |value| allocator.free(value);

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            result.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--local")) {
            if (command == .install or command == .remove or command == .config) {
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
        if (std.mem.eql(u8, arg, "--force")) {
            if (command == .update) {
                result.force = true;
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
        if (command == .config and std.mem.eql(u8, arg, "--toggle")) {
            saw_toggle_flag = true;
            const kind_arg_index = index + 1;
            const pattern_arg_index = index + 2;
            if (pattern_arg_index >= args.len) {
                if (result.parse_error == null) {
                    result.parse_error = try allocator.dupe(
                        u8,
                        "--toggle requires <kind> and <pattern> arguments.",
                    );
                }
                index = args.len; // stop scanning further
                continue;
            }
            const kind_arg = args[kind_arg_index];
            const pattern_arg = args[pattern_arg_index];
            const kind = ConfigKind.fromString(kind_arg) orelse {
                if (result.parse_error == null) {
                    result.parse_error = try std.fmt.allocPrint(
                        allocator,
                        "Unknown --toggle kind {s}. Expected extensions, skills, prompts, or themes.",
                        .{kind_arg},
                    );
                }
                index = pattern_arg_index;
                continue;
            };
            pending_toggle_kind = kind;
            if (pending_toggle_pattern_owned) |value| allocator.free(value);
            pending_toggle_pattern_owned = try allocator.dupe(u8, pattern_arg);
            index = pattern_arg_index;
            continue;
        }
        if (command == .config and (std.mem.eql(u8, arg, "--enable") or std.mem.eql(u8, arg, "--disable"))) {
            result.config_options.toggle_action = if (std.mem.eql(u8, arg, "--enable"))
                .enable
            else
                .disable;
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

    if (command == .config and saw_toggle_flag and result.parse_error == null) {
        if (pending_toggle_kind == null or pending_toggle_pattern_owned == null) {
            if (result.parse_error == null) {
                result.parse_error = try allocator.dupe(
                    u8,
                    "--toggle requires <kind> and <pattern> arguments.",
                );
            }
        } else {
            result.config_options.toggle_kind = pending_toggle_kind;
            result.config_options.toggle_pattern = pending_toggle_pattern_owned;
            pending_toggle_pattern_owned = null;
        }
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
            if (std.mem.eql(u8, value, "self") or std.mem.eql(u8, value, "pi")) {
                result.update_target = .self;
            } else {
                result.update_target = .{ .source = value };
            }
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
        .config => "config",
    };
}

pub fn packageCommandUsage(command: PackageCommand) []const u8 {
    return switch (command) {
        .install => "pi install <source> [-l]",
        .remove => "pi remove <source> [-l]",
        .update => "pi update [source|self|pi] [--force]",
        .list => "pi list",
        .config => "pi config [--toggle <kind> <pattern> --enable|--disable] [-l]",
    };
}

pub const ExecuteOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    /// When non-null, used instead of detecting npm/bun for self-update.
    /// Slice of argv strings; the first element is the executable.
    /// Set to an empty slice to simulate "no package manager found".
    self_update_command_override: ?[]const []const u8 = null,
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
        .config => executeConfig(allocator, io, command, options, stdout, stderr),
    };
}

fn executeConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: ParsedCommand,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    _ = stderr;

    // Bare `pi config`: print a deterministic listing of toggle kinds
    // plus an explicit note that interactive TUI release/binary
    // packaging is intentionally out of scope for this build.
    if (command.config_options.toggle_kind == null or command.config_options.toggle_pattern == null) {
        try stdout.writeAll(
            \\Configurable resource kinds: extensions, skills, prompts, themes.
            \\
            \\Use --toggle <kind> <pattern> --enable|--disable [-l] to persist
            \\an enable/disable pattern to the matching settings.json array.
            \\
            \\Note: release/binary packaging (self-update, packaged installers,
            \\bundled first-run UX) is not implemented in this build; only
            \\local-fixture-friendly toggles are supported here.
            \\
        );
        return .{ .exit_code = 0 };
    }

    const kind = command.config_options.toggle_kind.?;
    const pattern = command.config_options.toggle_pattern.?;
    const action = command.config_options.toggle_action;

    const settings_path = try settingsPathForScope(allocator, options, command.local);
    defer allocator.free(settings_path);

    var settings_object = try loadSettingsObject(allocator, io, settings_path);
    defer {
        const owner: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, owner);
    }

    const prefix: u8 = if (action == .enable) '+' else '-';
    const new_entry = try std.fmt.allocPrint(allocator, "{c}{s}", .{ prefix, pattern });
    errdefer allocator.free(new_entry);

    const array_ptr = try ensureKindArray(allocator, &settings_object, kind);

    // Filter out any previous +pattern/-pattern/!pattern/pattern entries
    // matching this exact pattern string. Mirrors the TS config selector
    // semantics where toggling replaces the previous decision.
    var idx: usize = 0;
    while (idx < array_ptr.items.len) {
        const item = array_ptr.items[idx];
        const matches = blk: {
            if (item != .string) break :blk false;
            const value = item.string;
            const stripped = if (value.len > 0 and (value[0] == '+' or value[0] == '-' or value[0] == '!'))
                value[1..]
            else
                value;
            break :blk std.mem.eql(u8, stripped, pattern);
        };
        if (matches) {
            const removed = array_ptr.orderedRemove(idx);
            common.deinitJsonValue(allocator, removed);
            continue;
        }
        idx += 1;
    }

    try array_ptr.append(.{ .string = new_entry });
    try writeSettingsObject(allocator, io, settings_path, settings_object);

    const action_label: []const u8 = if (action == .enable) "Enabled" else "Disabled";
    try stdout.print("{s} {s}: {s}\n", .{ action_label, kind.settingsKey(), pattern });
    return .{ .exit_code = 0 };
}

fn ensureKindArray(
    allocator: std.mem.Allocator,
    settings_object: *std.json.ObjectMap,
    kind: ConfigKind,
) !*std.json.Array {
    const key_str = kind.settingsKey();
    if (settings_object.getPtr(key_str)) |existing| {
        if (existing.* == .array) {
            return &existing.array;
        }
        const cleanup = existing.*;
        common.deinitJsonValue(allocator, cleanup);
        existing.* = .{ .array = std.json.Array.init(allocator) };
        return &existing.array;
    }
    const owned_key = try allocator.dupe(u8, key_str);
    errdefer allocator.free(owned_key);
    try settings_object.put(allocator, owned_key, .{ .array = std.json.Array.init(allocator) });
    return &settings_object.getPtr(key_str).?.array;
}

fn executeInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: ParsedCommand,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    _ = stderr;
    const source = command.source orelse unreachable;

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
        .self => {
            return executeSelfUpdate(allocator, io, command.force, options, stdout, stderr);
        },
        .source => |source| {
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

const package_name = "@mariozechner/pi";

/// Detect whether npm or bun is available in PATH and return the update
/// command argv as a heap-allocated slice of heap-allocated strings.
/// Returns null when no supported package manager is found.
/// Caller owns all allocations.
fn detectSelfUpdateCommand(allocator: std.mem.Allocator, io: std.Io) !?[][]u8 {
    const candidates = [_]struct { pm: []const u8, install_args: []const []const u8 }{
        .{ .pm = "npm", .install_args = &.{ "npm", "install", "-g", package_name } },
        .{ .pm = "bun", .install_args = &.{ "bun", "install", "-g", package_name } },
    };
    for (candidates) |candidate| {
        const which_result = std.process.run(allocator, io, .{
            .argv = &.{ "which", candidate.pm },
            .stdout_limit = .limited(256),
            .stderr_limit = .limited(256),
        }) catch continue;
        defer allocator.free(which_result.stdout);
        defer allocator.free(which_result.stderr);
        const found = switch (which_result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (found) {
            const argv = try allocator.alloc([]u8, candidate.install_args.len);
            errdefer allocator.free(argv);
            var i: usize = 0;
            errdefer for (argv[0..i]) |arg| allocator.free(arg);
            for (candidate.install_args) |arg| {
                argv[i] = try allocator.dupe(u8, arg);
                i += 1;
            }
            return argv;
        }
    }
    return null;
}

fn executeSelfUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    force: bool,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    _ = force; // Version check skipped: always run when requested.

    // Resolve argv: use test override when present, otherwise detect.
    var detected_argv: ?[][]u8 = null;
    defer if (detected_argv) |argv| {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    };

    const argv: []const []const u8 = if (options.self_update_command_override) |override| blk: {
        if (override.len == 0) {
            // Empty override means "no package manager found".
            try stderr.print(
                "error: pi cannot self-update this installation.\nRun: npm install -g {s}\n",
                .{package_name},
            );
            return .{ .exit_code = 1 };
        }
        break :blk override;
    } else blk: {
        detected_argv = try detectSelfUpdateCommand(allocator, io);
        if (detected_argv == null) {
            try stderr.print(
                "error: pi cannot self-update this installation.\nRun: npm install -g {s}\n",
                .{package_name},
            );
            return .{ .exit_code = 1 };
        }
        break :blk detected_argv.?;
    };

    // Build display string: space-join argv.
    var display_buf: std.ArrayList(u8) = .empty;
    defer display_buf.deinit(allocator);
    for (argv, 0..) |arg, i| {
        if (i > 0) try display_buf.append(allocator, ' ');
        try display_buf.appendSlice(allocator, arg);
    }
    const display = display_buf.items;

    // Spawn the update command and collect output.
    const result = std.process.run(allocator, io, .{
        .argv = argv,
    }) catch |err| {
        try stderr.print(
            "Error: Failed to spawn update command: {s}\nIf this keeps failing, run this command yourself: {s}\n",
            .{ @errorName(err), display },
        );
        return .{ .exit_code = 1 };
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => {},
        .signal => |sig| {
            try stderr.print(
                "Error: {s} terminated by signal {d}\nIf this keeps failing, run this command yourself: {s}\n",
                .{ display, sig, display },
            );
            return .{ .exit_code = 1 };
        },
        else => {
            try stderr.print(
                "Error: {s} terminated abnormally\nIf this keeps failing, run this command yourself: {s}\n",
                .{ display, display },
            );
            return .{ .exit_code = 1 };
        },
    }
    const exit_code: u8 = switch (result.term) {
        .exited => |code| @intCast(code),
        else => unreachable,
    };

    if (exit_code != 0) {
        try stderr.print(
            "Error: {s} exited with {d}\nIf this keeps failing, run this command yourself: {s}\n",
            .{ display, exit_code, display },
        );
        return .{ .exit_code = 1 };
    }

    try stdout.print("Updated pi\n", .{});
    return .{ .exit_code = 0 };
}

fn executeList(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
) !ExecuteResult {
    var user_entries = try collectScopePackageEntries(allocator, io, options, false);
    defer freeListEntries(allocator, &user_entries);
    var project_entries = try collectScopePackageEntries(allocator, io, options, true);
    defer freeListEntries(allocator, &project_entries);

    if (user_entries.items.len == 0 and project_entries.items.len == 0) {
        try stdout.print("No packages installed.\n", .{});
        return .{ .exit_code = 0 };
    }

    if (user_entries.items.len > 0) {
        try stdout.print("User packages:\n", .{});
        for (user_entries.items) |entry| {
            if (entry.filtered) {
                try stdout.print("  {s} (filtered)\n", .{entry.source});
            } else {
                try stdout.print("  {s}\n", .{entry.source});
            }
            try stdout.print("    {s}\n", .{entry.installed_path});
        }
    }

    if (project_entries.items.len > 0) {
        if (user_entries.items.len > 0) try stdout.print("\n", .{});
        try stdout.print("Project packages:\n", .{});
        for (project_entries.items) |entry| {
            if (entry.filtered) {
                try stdout.print("  {s} (filtered)\n", .{entry.source});
            } else {
                try stdout.print("  {s}\n", .{entry.source});
            }
            try stdout.print("    {s}\n", .{entry.installed_path});
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
            \\Examples:
            \\  pi install npm:@foo/bar
            \\  pi install git:github.com/user/repo
            \\  pi install git@github.com:user/repo
            \\  pi install https://github.com/user/repo
            \\  pi install ssh://git@github.com/user/repo
            \\  pi install ./local/path
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
            \\  pi update [source|self|pi] [--force]
            \\
            \\Update installed packages or self-update pi.
            \\
            \\  pi update             Update all installed packages (offline no-op for local sources)
            \\  pi update self        Self-update pi via npm or bun
            \\  pi update pi          Alias for pi update self
            \\  pi update <source>    Update a specific installed package
            \\
            \\Options:
            \\  --force    Skip version check, always run update
            \\
            \\Self-update requires npm or bun to be installed. On failure, a manual
            \\instruction is printed showing the command you can run yourself.
            \\
        ),
        .list => try stdout.writeAll(
            \\Usage:
            \\  pi list
            \\
            \\List installed packages from user and project settings.
            \\
        ),
        .config => try stdout.writeAll(
            \\Usage:
            \\  pi config [--toggle <kind> <pattern> --enable|--disable] [-l]
            \\
            \\Manage package resource toggles in settings.json.
            \\
            \\Kinds:
            \\  extensions, skills, prompts, themes
            \\
            \\Options:
            \\  --toggle <kind> <pattern>    Persist an enable/disable pattern
            \\  --enable                     Persist a +pattern entry (default)
            \\  --disable                    Persist a -pattern entry
            \\  -l, --local                  Operate on project settings (.pi/settings.json)
            \\
            \\Note: release/binary packaging (self-update, packaged installers,
            \\bundled first-run UX) is not implemented in this build; only
            \\local-fixture-friendly toggles are supported here.
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

/// Strips the npm: prefix and version specifier to get the package name.
/// e.g. "npm:@scope/pkg@1.0.0" → "@scope/pkg", "npm:my-pkg" → "my-pkg"
fn npmPackageName(spec: []const u8) []const u8 {
    if (spec.len == 0) return spec;
    if (spec[0] == '@') {
        const at_index = std.mem.lastIndexOfScalar(u8, spec, '@') orelse return spec;
        if (std.mem.indexOfScalar(u8, spec, '/')) |slash_index| {
            if (at_index > slash_index) return spec[0..at_index];
        }
        return spec;
    }
    const at_index = std.mem.lastIndexOfScalar(u8, spec, '@') orelse return spec;
    return spec[0..at_index];
}

/// Returns the normalized form of a git source for hashing (used by gitInstallPath).
fn normalizeGitSource(source: []const u8) []const u8 {
    if (std.mem.startsWith(u8, source, "git:")) return source["git:".len..];
    return source;
}

/// Computes the expected on-disk install path for a package source.
/// For local sources, resolves relative paths from cwd.
/// For npm sources, returns the node_modules directory path.
/// For git sources, returns a SHA256-derived directory path.
/// Caller owns the returned slice.
fn computeInstalledPath(
    allocator: std.mem.Allocator,
    source: []const u8,
    is_project: bool,
    cwd: []const u8,
    agent_dir: []const u8,
) ![]u8 {
    if (isLocalSource(source)) {
        if (std.fs.path.isAbsolute(source)) {
            return allocator.dupe(u8, source);
        }
        return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, source });
    }
    if (std.mem.startsWith(u8, source, "npm:")) {
        const spec = std.mem.trim(u8, source["npm:".len..], " ");
        const pkg_name = npmPackageName(spec);
        const base = if (is_project)
            try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "packages", "npm", "node_modules" })
        else
            try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "packages", "npm", "node_modules" });
        defer allocator.free(base);
        return std.fs.path.join(allocator, &[_][]const u8{ base, pkg_name });
    }
    // git and URL-based sources: hash the normalized form
    const normalized = normalizeGitSource(source);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(normalized, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const hex_str = try std.fmt.allocPrint(allocator, "{s}", .{hex[0..]});
    defer allocator.free(hex_str);
    const base = if (is_project)
        try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "packages", "git" })
    else
        try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "packages", "git" });
    defer allocator.free(base);
    return std.fs.path.join(allocator, &[_][]const u8{ base, hex_str });
}

/// Returns true when the settings JSON object for a package has any
/// non-empty filter arrays (extensions, skills, prompts, themes).
fn hasFilterFields(obj: std.json.ObjectMap) bool {
    const filter_keys = [_][]const u8{ "extensions", "skills", "prompts", "themes" };
    for (filter_keys) |key| {
        if (obj.get(key)) |v| {
            if (v == .array and v.array.items.len > 0) return true;
        }
    }
    return false;
}

/// Rich per-package info for the list command.
const ListEntry = struct {
    source: []u8,
    installed_path: []u8,
    filtered: bool,

    fn deinit(self: *ListEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.installed_path);
        self.* = undefined;
    }
};

fn freeListEntries(allocator: std.mem.Allocator, list: *std.ArrayList(ListEntry)) void {
    for (list.items) |*entry| entry.deinit(allocator);
    list.deinit(allocator);
}

fn collectScopePackageEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    is_project: bool,
) !std.ArrayList(ListEntry) {
    var result: std.ArrayList(ListEntry) = .empty;
    errdefer freeListEntries(allocator, &result);

    const settings_path = try settingsPathForScope(allocator, options, is_project);
    defer allocator.free(settings_path);

    var settings_object = try loadSettingsObject(allocator, io, settings_path);
    defer {
        const cleanup: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, cleanup);
    }

    const packages_value = settings_object.get("packages") orelse return result;
    if (packages_value != .array) return result;

    for (packages_value.array.items) |item| {
        const source_str: []const u8 = switch (item) {
            .string => |s| s,
            .object => |obj| blk: {
                const sv = obj.get("source") orelse continue;
                if (sv != .string) continue;
                break :blk sv.string;
            },
            else => continue,
        };
        const filtered: bool = switch (item) {
            .object => |obj| hasFilterFields(obj),
            else => false,
        };

        const source_owned = try allocator.dupe(u8, source_str);
        errdefer allocator.free(source_owned);
        const installed_path = try computeInstalledPath(allocator, source_str, is_project, options.cwd, options.agent_dir);
        errdefer allocator.free(installed_path);

        try result.append(allocator, .{
            .source = source_owned,
            .installed_path = installed_path,
            .filtered = filtered,
        });
    }
    return result;
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

test "VAL-M12-PKG-010 convention resource discovery follows package conventions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/convention-pkg/extensions");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/convention-pkg/skills/example");
    // No `pi` block in package.json: resource discovery must fall back to
    // convention-named directories under the package root.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/convention-pkg/package.json",
        .data =
        \\{ "name": "convention-pkg", "version": "0.0.0" }
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/convention-pkg/extensions/main.ts",
        .data = "export default {};\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/convention-pkg/skills/example/SKILL.md",
        .data =
        \\---
        \\description: convention skill
        \\---
        \\Body.
        ,
    });
    // A file outside any supported convention directory must NOT be
    // discovered as an extension. This proves convention-based discovery
    // does not blanket-scan unrelated package files.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/convention-pkg/stray.ts",
        .data = "export default {};\n",
    });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    const fixture_root = try makeAbsoluteTmpPath(allocator, tmp, "repo/fixtures/convention-pkg");
    defer allocator.free(fixture_root);

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
        if (std.mem.endsWith(u8, entry.path, "extensions/main.ts")) saw_extension = true;
        try std.testing.expect(!std.mem.endsWith(u8, entry.path, "stray.ts"));
    }
    try std.testing.expect(saw_extension);

    var saw_skill = false;
    for (resolved.skills) |entry| {
        if (std.mem.endsWith(u8, entry.path, "example/SKILL.md")) saw_skill = true;
    }
    try std.testing.expect(saw_skill);
}

test "VAL-M12-PKG-011 package resource filtering keeps only matching entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/filter-pkg/extensions");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/filter-pkg/package.json",
        .data =
        \\{ "name": "filter-pkg", "version": "0.0.0" }
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/filter-pkg/extensions/keep.ts",
        .data = "export default {};\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/filter-pkg/extensions/skip.ts",
        .data = "export default {};\n",
    });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    const fixture_root = try makeAbsoluteTmpPath(allocator, tmp, "repo/fixtures/filter-pkg");
    defer allocator.free(fixture_root);

    const package_source = try allocator.dupe(u8, fixture_root);
    const filter_extensions = try allocator.alloc([]u8, 1);
    filter_extensions[0] = try allocator.dupe(u8, "extensions/keep.ts");
    var package_config = resources_mod.PackageSourceConfig{
        .source = package_source,
        .extensions = filter_extensions,
    };
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

    var saw_keep = false;
    for (resolved.extensions) |entry| {
        if (std.mem.endsWith(u8, entry.path, "extensions/keep.ts")) saw_keep = true;
        try std.testing.expect(!std.mem.endsWith(u8, entry.path, "extensions/skip.ts"));
    }
    try std.testing.expect(saw_keep);
}

test "VAL-M12-PKG-012 package command --help text covers each subcommand" {
    const allocator = std.testing.allocator;

    const subcommands = [_]struct { args: []const []const u8, must_contain: []const []const u8 }{
        .{
            .args = &.{ "install", "--help" },
            .must_contain = &.{ "pi install <source>", "-l, --local" },
        },
        .{
            .args = &.{ "remove", "--help" },
            .must_contain = &.{ "pi remove <source>", "Alias: pi uninstall" },
        },
        .{
            .args = &.{ "uninstall", "--help" },
            .must_contain = &.{ "pi remove <source>", "Alias: pi uninstall" },
        },
        .{
            .args = &.{ "update", "--help" },
            .must_contain = &.{ "pi update [source|self|pi]", "Self-update", "--force" },
        },
        .{
            .args = &.{ "list", "--help" },
            .must_contain = &.{ "pi list", "List installed packages" },
        },
        .{
            .args = &.{ "config", "--help" },
            .must_contain = &.{ "pi config", "--toggle <kind> <pattern>", "release/binary packaging" },
        },
    };

    for (subcommands) |spec| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

        const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
        defer allocator.free(cwd);
        const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
        defer allocator.free(agent_dir);

        var stdout_buf: std.ArrayList(u8) = .empty;
        defer stdout_buf.deinit(allocator);
        var stderr_buf: std.ArrayList(u8) = .empty;
        defer stderr_buf.deinit(allocator);

        const result = try runCommand(
            allocator,
            spec.args,
            .{ .cwd = cwd, .agent_dir = agent_dir },
            &stdout_buf,
            &stderr_buf,
        );
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        for (spec.must_contain) |needle| {
            if (std.mem.indexOf(u8, stdout_buf.items, needle) == null) {
                std.debug.print("missing '{s}' in {s} help: {s}\n", .{ needle, spec.args[0], stdout_buf.items });
                return error.TestExpectedHelpEntry;
            }
        }
    }
}

test "VAL-M12-PKG-014 config --toggle persists pattern in scoped settings.json" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    // Pre-populate user settings with an unrelated key to assert we
    // never wipe other settings while writing the toggle.
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{
        \\  "defaultProvider": "openai"
        \\}
    , true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result_disable = try runCommand(
        allocator,
        &.{ "config", "--toggle", "extensions", "extras/main.ts", "--disable" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result_disable.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Disabled extensions: extras/main.ts") != null);

    const after_disable = try readSettings(allocator, settings_path);
    defer allocator.free(after_disable);
    try std.testing.expect(std.mem.indexOf(u8, after_disable, "\"-extras/main.ts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_disable, "\"defaultProvider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_disable, "\"openai\"") != null);

    // Toggling enable for the same pattern must replace the disable
    // entry rather than accumulate stale entries.
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const result_enable = try runCommand(
        allocator,
        &.{ "config", "--toggle", "extensions", "extras/main.ts", "--enable" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result_enable.exit_code);

    const after_enable = try readSettings(allocator, settings_path);
    defer allocator.free(after_enable);
    try std.testing.expect(std.mem.indexOf(u8, after_enable, "\"+extras/main.ts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_enable, "\"-extras/main.ts\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, after_enable, "\"defaultProvider\"") != null);
}

test "VAL-M12-PKG-014 config --toggle -l writes project-scope settings only" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

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
        &.{ "config", "--toggle", "skills", "example", "--disable", "-l" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    const project = try readSettings(allocator, project_settings_path);
    defer allocator.free(project);
    try std.testing.expect(std.mem.indexOf(u8, project, "\"skills\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, project, "\"-example\"") != null);

    // User-scope settings.json must not exist after a project-scope toggle.
    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    const user_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), std.testing.io, user_settings_path, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!user_exists);
}

// ---------------------------------------------------------------------------
// Remote source tests (VAL-PKG-101..115, VAL-PKG-150..153)
// ---------------------------------------------------------------------------

test "VAL-PKG-101 npm scoped package accepted and persisted" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
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
        &.{ "install", "npm:@scope/package" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", stderr_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Installed npm:@scope/package") != null);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"npm:@scope/package\"") != null);
}

test "VAL-PKG-102 npm unscoped package accepted and persisted" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
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
        &.{ "install", "npm:my-package" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Installed npm:my-package") != null);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"npm:my-package\"") != null);
}

test "VAL-PKG-103 npm source install/remove round-trips correctly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    // Pre-populate with unrelated key to verify preservation.
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{ "defaultProvider": "openai" }
    , true);

    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);

    const r_install = try runCommand(allocator, &.{ "install", "npm:@foo/bar" }, options, &buf_a, &buf_b);
    try std.testing.expectEqual(@as(u8, 0), r_install.exit_code);

    buf_a.clearRetainingCapacity();
    buf_b.clearRetainingCapacity();
    const r_remove = try runCommand(allocator, &.{ "remove", "npm:@foo/bar" }, options, &buf_a, &buf_b);
    try std.testing.expectEqual(@as(u8, 0), r_remove.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "Removed npm:@foo/bar") != null);

    const after = try readSettings(allocator, settings_path);
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "npm:@foo/bar") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"defaultProvider\"") != null);
}

test "VAL-PKG-104 npm duplicate install is a no-op" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);

    _ = try runCommand(allocator, &.{ "install", "npm:@scope/pkg" }, options, &buf_a, &buf_b);
    buf_a.clearRetainingCapacity();
    buf_b.clearRetainingCapacity();

    const r2 = try runCommand(allocator, &.{ "install", "npm:@scope/pkg" }, options, &buf_a, &buf_b);
    try std.testing.expectEqual(@as(u8, 0), r2.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "Already installed") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "npm:@scope/pkg") != null);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    // Only one entry should exist.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, settings, "npm:@scope/pkg"));
}

test "VAL-PKG-110 git:github.com prefix source accepted" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "git:github.com/user/repo" }, options, &buf_a, &buf_b);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "Installed git:github.com/user/repo") != null);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"git:github.com/user/repo\"") != null);
}

test "VAL-PKG-111 git@ SSH source accepted" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);

    const result = try runCommand(
        allocator,
        &.{ "install", "git@github.com:user/repo.git" },
        options,
        &buf_a,
        &buf_b,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "Installed git@github.com:user/repo.git") != null);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"git@github.com:user/repo.git\"") != null);
}

test "VAL-PKG-112 https:// git URL source accepted" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);

    const result = try runCommand(
        allocator,
        &.{ "install", "https://github.com/user/repo" },
        options,
        &buf_a,
        &buf_b,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "Installed https://github.com/user/repo") != null);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"https://github.com/user/repo\"") != null);
}

test "VAL-PKG-113 ssh:// git URL source accepted" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);

    const result = try runCommand(
        allocator,
        &.{ "install", "ssh://git@github.com/user/repo" },
        options,
        &buf_a,
        &buf_b,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "Installed ssh://git@github.com/user/repo") != null);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"ssh://git@github.com/user/repo\"") != null);
}

test "VAL-PKG-114 git source install/remove round-trips correctly" {
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
        \\{ "defaultProvider": "openai" }
    , true);

    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);

    _ = try runCommand(allocator, &.{ "install", "git:github.com/user/mypkg" }, options, &buf_a, &buf_b);
    buf_a.clearRetainingCapacity();
    buf_b.clearRetainingCapacity();

    const r_remove = try runCommand(allocator, &.{ "remove", "git:github.com/user/mypkg" }, options, &buf_a, &buf_b);
    try std.testing.expectEqual(@as(u8, 0), r_remove.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "Removed git:github.com/user/mypkg") != null);

    const after = try readSettings(allocator, settings_path);
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "git:github.com/user/mypkg") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"defaultProvider\"") != null);
}

test "VAL-PKG-115 git source duplicate install is a no-op" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);

    _ = try runCommand(allocator, &.{ "install", "git:github.com/user/repo" }, options, &buf_a, &buf_b);
    buf_a.clearRetainingCapacity();
    buf_b.clearRetainingCapacity();

    const r2 = try runCommand(allocator, &.{ "install", "git:github.com/user/repo" }, options, &buf_a, &buf_b);
    try std.testing.expectEqual(@as(u8, 0), r2.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "Already installed") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "git:github.com/user/repo") != null);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, settings, "git:github.com/user/repo"));
}

test "VAL-PKG-150 list shows installed path for each package" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/my-pkg");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    // Install using the absolute fixture path so the resolved path is deterministic.
    const pkg_path = try makeAbsoluteTmpPath(allocator, tmp, "repo/fixtures/my-pkg");
    defer allocator.free(pkg_path);

    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);

    _ = try runCommand(allocator, &.{ "install", pkg_path }, options, &buf_a, &buf_b);
    buf_a.clearRetainingCapacity();
    buf_b.clearRetainingCapacity();

    const result = try runCommand(allocator, &.{"list"}, options, &buf_a, &buf_b);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    // Source line must appear.
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, pkg_path) != null);
    // Installed path line (indented, same as source for absolute local path) must appear.
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "    ") != null);
}

test "VAL-PKG-151 list shows (filtered) indicator for filtered packages" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    // Manually write settings with one filtered and one unfiltered package.
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{
        \\  "packages": [
        \\    { "source": "npm:@foo/filtered-pkg", "extensions": ["ext/main.ts"] },
        \\    { "source": "npm:@bar/plain-pkg" }
        \\  ]
        \\}
    , true);

    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);

    const result = try runCommand(allocator, &.{"list"}, options, &buf_a, &buf_b);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "npm:@foo/filtered-pkg (filtered)") != null);
    // Plain package must NOT have the "(filtered)" tag.
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "npm:@bar/plain-pkg") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "npm:@bar/plain-pkg (filtered)") == null);
}

test "VAL-PKG-152 list groups user and project packages with headers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);

    _ = try runCommand(allocator, &.{ "install", "npm:@user/pkg" }, options, &buf_a, &buf_b);
    buf_a.clearRetainingCapacity();
    buf_b.clearRetainingCapacity();
    _ = try runCommand(allocator, &.{ "install", "npm:@project/pkg", "-l" }, options, &buf_a, &buf_b);
    buf_a.clearRetainingCapacity();
    buf_b.clearRetainingCapacity();

    const result = try runCommand(allocator, &.{"list"}, options, &buf_a, &buf_b);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "User packages:") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "npm:@user/pkg") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "Project packages:") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "npm:@project/pkg") != null);
}

test "VAL-PKG-153 list prints No packages installed. when empty" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);

    const result = try runCommand(allocator, &.{"list"}, options, &buf_a, &buf_b);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("No packages installed.\n", buf_a.items);
}

test "VAL-M12-PKG-015 release and binary packaging surfaces stay excluded" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    // `pi update self` with no package manager available must surface
    // a deterministic diagnostic. Use an empty command override to
    // simulate "no package manager found" without network access.
    const options_no_pm = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .self_update_command_override = &.{},
    };
    const result_self = try runCommand(
        allocator,
        &.{ "update", "self" },
        options_no_pm,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 1), result_self.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "self-update this installation") != null);
    try std.testing.expectEqualStrings("", stdout_buf.items);

    // Bare `pi config` and `pi config --help` must both document that
    // release/binary packaging is intentionally not implemented in this
    // build so users do not assume the surface exists.
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const result_config_bare = try runCommand(
        allocator,
        &.{"config"},
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result_config_bare.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "release/binary packaging") != null);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const result_config_help = try runCommand(
        allocator,
        &.{ "config", "--help" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result_config_help.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "release/binary packaging") != null);
}

// ---------------------------------------------------------------------------
// Self-update tests (VAL-PKG-120, VAL-PKG-121, VAL-PKG-122, VAL-PKG-123)
// ---------------------------------------------------------------------------

test "VAL-PKG-120 self_update pi update self triggers self-update path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    // Use /usr/bin/true as the update command: it always exits 0.
    const options = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .self_update_command_override = &.{"/usr/bin/true"},
    };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(
        allocator,
        &.{ "update", "self" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Updated pi") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);
}

test "VAL-PKG-121 self_update pi update pi treated as self-update alias" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    // Use /usr/bin/true as the update command.
    const options = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .self_update_command_override = &.{"/usr/bin/true"},
    };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    // "pi" alias must behave identically to "self".
    const result = try runCommand(
        allocator,
        &.{ "update", "pi" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Updated pi") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);
}

test "VAL-PKG-122 self_update --force flag parsed and sets force=true with update_target=self" {
    const allocator = std.testing.allocator;

    // Test that --force is parsed correctly without error.
    var parsed = try parsePackageCommand(allocator, &.{ "update", "self", "--force" });
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.parse_error == null);
    try std.testing.expect(parsed.force == true);
    try std.testing.expect(parsed.update_target != null);
    try std.testing.expect(parsed.update_target.? == .self);
}

test "VAL-PKG-122 self_update --force rejected on non-update commands" {
    const allocator = std.testing.allocator;

    var parsed_install = try parsePackageCommand(allocator, &.{ "install", "./pkg", "--force" });
    defer parsed_install.deinit(allocator);
    try std.testing.expect(parsed_install.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed_install.parse_error.?, "--force") != null);

    var parsed_list = try parsePackageCommand(allocator, &.{ "list", "--force" });
    defer parsed_list.deinit(allocator);
    try std.testing.expect(parsed_list.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed_list.parse_error.?, "--force") != null);
}

test "VAL-PKG-123 self_update fallback printed on command failure" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    // Use /bin/false as the update command: always exits non-zero.
    const options = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .self_update_command_override = &.{"/bin/false"},
    };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(
        allocator,
        &.{ "update", "self" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    // Fallback instruction must mention the manual command.
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "If this keeps failing, run this command yourself") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "/bin/false") != null);
    try std.testing.expectEqualStrings("", stdout_buf.items);
}

test "VAL-PKG-120 self_update no package manager prints diagnostic" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    // Empty override = no package manager found.
    const options = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .self_update_command_override = &.{},
    };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(
        allocator,
        &.{ "update", "self" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "self-update this installation") != null);
    // Manual fallback command must be shown.
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, package_name) != null);
    try std.testing.expectEqualStrings("", stdout_buf.items);
}
