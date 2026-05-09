const std = @import("std");
const common = @import("../tools/common.zig");
const config_mod = @import("../config/config.zig");
const extension_manifest = @import("../extensions/extension_manifest.zig");
const extension_runtime = @import("../extensions/extension_runtime.zig");
const policy_key_mod = @import("../extensions/policy_key.zig");
const wasm_manifest = @import("../extensions/wasm/wasm_manifest.zig");
const resources_mod = @import("../resources/resources.zig");
const config_selector = @import("config_selector.zig");
const package_command_parser = @import("package_command_parser.zig");
const provenance_lockfile = @import("provenance_lockfile.zig");

/// Package CLI subcommand parser/executor parity with the TypeScript
/// `package-manager-cli.ts`. Local fixture behavior is preserved while
/// npm/git install and update paths shell out through package-manager
/// commands (overridden by tests to avoid real network work). Self-update
/// supports the CLI surface and deterministic test override; native Zig
/// builds without an override report that self-update is unsupported because
/// they cannot safely prove global package-manager ownership.
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
///   - `update` matches the TS command surface: all/extensions/source
///     targets update configured packages, local sources are no-ops, and
///     bare `update` also includes the self-update path.
///
/// The CLI dispatcher is idempotent and uses temporary HOME/agent-dir
/// settings paths for tests so deterministic fixture runs can compare
/// stdout/stderr and JSON state without leaking machine paths.
pub const PackageCommand = package_command_parser.PackageCommand;
pub const ConfigKind = config_selector.ConfigKind;
const ConfigSelectorState = config_selector.ConfigSelectorState;
const loadSelectorState = config_selector.loadSelectorState;
const saveSelectorState = config_selector.saveSelectorState;
const ProvenanceScope = provenance_lockfile.Scope;

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
    /// Optional command prefix used instead of `npm` for npm package installs
    /// and updates. Tests pass a local fixture command here to avoid real
    /// network/package-manager work.
    npm_command_override: ?[]const []const u8 = null,
    /// Optional command prefix used instead of `git` for git package installs
    /// and updates. Tests pass a local fixture command here to avoid real
    /// network/package-manager work.
    git_command_override: ?[]const []const u8 = null,
    /// When non-null, used instead of detecting npm/bun for self-update.
    /// Slice of argv strings; the first element is the executable.
    /// Set to an empty slice to simulate "no package manager found".
    self_update_command_override: ?[]const []const u8 = null,
    /// Package manager semantics to apply to `self_update_command_override`.
    /// Tests use shell/true/false command prefixes while still exercising
    /// npm/pnpm/yarn/bun uninstall/install argument planning.
    self_update_method_override: SelfUpdatePackageManager = .npm,
    /// Deterministic latest-release metadata for self-update planning. When
    /// null, latest metadata is treated as unavailable and self-update runs
    /// with the current package name, matching the TS fallback path.
    self_update_latest_release_override: ?LatestSelfUpdateRelease = null,
    /// Optional probe incremented only when latest-release metadata is
    /// consulted. Used by focused tests to prove --force skips the fetch path.
    self_update_latest_release_probe: ?*usize = null,
    /// Current package version used for deterministic self-update planning.
    current_version: []const u8 = "0.1.0",
    /// When true and no --toggle flag is given, bare `pi config` launches
    /// the interactive TUI config selector instead of the non-interactive
    /// listing. Defaults to false so tests always see the listing output.
    stdout_is_tty: bool = false,
    /// Required when stdout_is_tty is true; used to initialize the vaxis
    /// terminal backend. When null, TUI is disabled even if stdout_is_tty.
    env_map: ?*const std.process.Environ.Map = null,
    /// Test-only fault injection used to prove lifecycle state writes are
    /// transactional when the settings file cannot be replaced.
    fail_settings_write_for_testing: bool = false,
    /// Test-only fault injection used to prove lifecycle state writes are
    /// transactional when the provenance lockfile cannot be replaced.
    fail_lockfile_write_for_testing: bool = false,
};

pub const SelfUpdatePackageManager = enum { npm, pnpm, yarn, bun };

pub const LatestSelfUpdateRelease = struct {
    version: []const u8,
    package_name: ?[]const u8 = null,
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

    // Bare `pi config` (no --toggle flag): launch interactive TUI when
    // stdout is a TTY, otherwise print the non-interactive listing.
    if (command.config_options.toggle_kind == null or command.config_options.toggle_pattern == null) {
        if (options.stdout_is_tty) {
            if (options.env_map) |env_map| {
                const settings_path = try settingsPathForScope(allocator, options, command.local);
                defer allocator.free(settings_path);
                try config_selector.runConfigSelector(.{
                    .allocator = allocator,
                    .io = io,
                    .env_map = env_map,
                    .settings_path = settings_path,
                });
                return .{ .exit_code = 0 };
            }
        }
        // Non-TTY fallback: print deterministic listing.
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
    try writeSettingsObject(allocator, io, settings_path, settings_object, options);

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
    const source = command.source orelse unreachable;

    const settings_path = try settingsPathForScope(allocator, options, command.local);
    defer allocator.free(settings_path);

    var settings_object = try loadSettingsObject(allocator, io, settings_path);
    defer {
        const owner: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, owner);
    }
    try config_mod.validateExtensionPoliciesForSettingsWrite(allocator, settings_object, settings_path);

    const packages_array_ptr = try ensurePackagesArray(allocator, &settings_object);
    const persisted_source = try normalizePackageSourceForSettings(allocator, source, command.local, options.cwd, options.agent_dir);
    defer allocator.free(persisted_source);
    const existing_index = try findPackageIndex(allocator, packages_array_ptr.*, source, command.local, options);
    if (existing_index != null and !isLocalSource(source)) {
        try stdout.print("Already installed: {s}\n", .{source});
        return .{ .exit_code = 0 };
    }

    if (!isLocalSource(source)) {
        const installed = if (isNpmSource(source))
            try executeNpmInstall(allocator, io, source, command.local, options, stderr)
        else
            try executeGitInstall(allocator, io, source, command.local, options, stderr);
        if (!installed) return .{ .exit_code = 1 };
    }

    var wasm_install = try validateLocalPackageForInstall(allocator, io, source, command.local, options, .input, stderr);
    defer wasm_install.deinit(allocator);
    if (wasm_install == .invalid) {
        return .{ .exit_code = 1 };
    }

    const install_metadata = if (wasm_install == .valid)
        null
    else
        try createInstallMetadataForSource(allocator, io, source, persisted_source, command.local, options);
    defer if (install_metadata) |metadata| common.deinitJsonValue(allocator, metadata);

    if (existing_index != null) {
        if (wasm_install == .valid) {
            const scope = provenanceScope(command.local);
            const lockfile_path = try provenance_lockfile.lockfilePath(allocator, scope, options.cwd, options.agent_dir);
            defer allocator.free(lockfile_path);
            var locked_entry = lockedLocalWasmEntryForSource(
                allocator,
                io,
                source,
                command.local,
                options,
                .input,
                scope,
                lockfile_path,
            ) catch |err| {
                try stderr.print("Error: failed to read extension provenance for already installed package {s}: {s}\n", .{ source, @errorName(err) });
                return .{ .exit_code = 1 };
            };
            defer if (locked_entry) |*entry| entry.deinit(allocator);
            if (locked_entry == null) {
                try stderr.print(
                    "Error: package already installed but missing trusted provenance for {s}; run `pi update --extension {s}` to refresh trust explicitly.\n",
                    .{ source, source },
                );
                return .{ .exit_code = 1 };
            }
            if (!provenance_lockfile.entriesEqual(locked_entry.?, wasm_install.valid)) {
                try stderr.print(
                    "Error: package already installed but source changed for {s}; run `pi update --extension {s}` to refresh trust explicitly.\n",
                    .{ source, source },
                );
                return .{ .exit_code = 1 };
            }
        }
        const redacted_source = try redactDiagnosticValue(allocator, source);
        defer allocator.free(redacted_source);
        try stdout.print("Already installed: {s}\n", .{redacted_source});
        if (wasm_install == .valid) {
            try writeWasmInstallDetails(allocator, stdout, source, wasm_install.valid);
        }
        return .{ .exit_code = 0 };
    }

    if (install_metadata) |metadata| {
        try writeExtensionProvenanceLockEntry(allocator, io, command.local, options, metadata);
    }

    var entry_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    var entry_object_owned_by_settings = false;
    errdefer if (!entry_object_owned_by_settings) {
        const cleanup: std.json.Value = .{ .object = entry_object };
        common.deinitJsonValue(allocator, cleanup);
    };
    try entry_object.put(allocator, try allocator.dupe(u8, "source"), .{ .string = try allocator.dupe(u8, persisted_source) });
    if (install_metadata) |metadata| {
        try entry_object.put(allocator, try allocator.dupe(u8, "installMetadata"), try common.cloneJsonValue(allocator, metadata));
    }
    try packages_array_ptr.*.append(.{ .object = entry_object });
    entry_object_owned_by_settings = true;

    var lock_snapshot: ?FileSnapshot = null;
    defer if (lock_snapshot) |*snapshot| snapshot.deinit(allocator);
    var wrote_lock = false;
    errdefer if (wrote_lock) {
        if (lock_snapshot) |snapshot| restoreFileSnapshot(allocator, io, snapshot) catch {};
    };
    if (wasm_install == .valid) {
        const scope = provenanceScope(command.local);
        const lockfile_path = try provenance_lockfile.lockfilePath(allocator, scope, options.cwd, options.agent_dir);
        defer allocator.free(lockfile_path);
        lock_snapshot = try captureFileSnapshot(allocator, io, lockfile_path);
        try writeProvenanceEntry(allocator, io, scope, lockfile_path, wasm_install.valid, options);
        wrote_lock = true;

        var revalidated = try validateLocalPackageForInstall(allocator, io, source, command.local, options, .input, stderr);
        defer revalidated.deinit(allocator);
        if (revalidated != .valid or !provenance_lockfile.entriesEqual(wasm_install.valid, revalidated.valid)) {
            try restoreFileSnapshot(allocator, io, lock_snapshot.?);
            wrote_lock = false;
            try stderr.print("Error: package provenance changed during install; refusing to persist trust for {s}\n", .{source});
            return .{ .exit_code = 1 };
        }
    }

    try writeSettingsObject(allocator, io, settings_path, settings_object, options);
    wrote_lock = false;
    const redacted_source = try redactDiagnosticValue(allocator, source);
    defer allocator.free(redacted_source);
    try stdout.print("Installed {s}\n", .{redacted_source});
    if (wasm_install == .valid) {
        try writeWasmInstallDetails(allocator, stdout, source, wasm_install.valid);
    }
    return .{ .exit_code = 0 };
}

const LocalPathMode = enum { input, settings };

const LocalWasmInstallValidation = union(enum) {
    absent,
    invalid,
    valid: provenance_lockfile.LockEntry,

    fn deinit(self: *LocalWasmInstallValidation, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .valid => |*entry| entry.deinit(allocator),
            else => {},
        }
        self.* = .absent;
    }
};

const WasmPackagePolicyRequest = struct {
    policy_lookup_key: []u8,

    fn deinit(self: *WasmPackagePolicyRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.policy_lookup_key);
        self.* = undefined;
    }
};

const WasmPackageListMetadata = struct {
    extension_id: []u8,
    extension_version: []u8,
    tool_id: []u8,
    package_root: []u8,
    artifact_absolute_path: []u8,
    artifact_sha256: []u8,
    package_root_sha256: []u8,
    policy_lookup_key: []u8,
    scope: []u8,
    trust_status: []u8,

    fn deinit(self: *WasmPackageListMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.extension_id);
        allocator.free(self.extension_version);
        allocator.free(self.tool_id);
        allocator.free(self.package_root);
        allocator.free(self.artifact_absolute_path);
        allocator.free(self.artifact_sha256);
        allocator.free(self.package_root_sha256);
        allocator.free(self.policy_lookup_key);
        allocator.free(self.scope);
        allocator.free(self.trust_status);
        self.* = undefined;
    }
};

const EXTENSION_PROVENANCE_LOCKFILE_NAME = "extensions.lock.json";
const EXTENSION_PROVENANCE_LOCK_SCHEMA_VERSION = "pi-extension-lock.v0";

fn createInstallMetadataForSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_source: []const u8,
    persisted_source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
) !?std.json.Value {
    if (!isLocalSource(persisted_source)) return null;
    const package_root = computeInstalledPath(allocator, persisted_source, is_project, options.cwd, options.agent_dir) catch return null;
    defer allocator.free(package_root);
    if (!pathExists(io, package_root)) return null;

    const package_root_real = realpathAlloc(allocator, package_root) catch try allocator.dupe(u8, package_root);
    defer allocator.free(package_root_real);
    const package_root_sha256 = try wasm_manifest.computePackageRootSha256(allocator, package_root);
    defer allocator.free(package_root_sha256);

    const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    const manifest_text = std.Io.Dir.readFileAlloc(.cwd(), io, manifest_path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (manifest_text) |value| allocator.free(value);

    var entry = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = entry });
    const key = try std.fmt.allocPrint(allocator, "local:{s}", .{package_root_real});
    try entry.put(allocator, try allocator.dupe(u8, "key"), .{ .string = key });
    try entry.put(allocator, try allocator.dupe(u8, "scope"), .{ .string = try allocator.dupe(u8, if (is_project) "project" else "user") });

    var source = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = source });
    try source.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, if (isLocalSource(persisted_source)) "local" else "package") });
    try source.put(allocator, try allocator.dupe(u8, "identity"), .{ .string = try allocator.dupe(u8, package_root_real) });
    try source.put(allocator, try allocator.dupe(u8, "specifier"), .{ .string = try allocator.dupe(u8, persisted_source) });
    try source.put(allocator, try allocator.dupe(u8, "inputSpecifier"), .{ .string = try allocator.dupe(u8, input_source) });
    try entry.put(allocator, try allocator.dupe(u8, "source"), .{ .object = source });

    try entry.put(allocator, try allocator.dupe(u8, "packageRoot"), .{ .string = try allocator.dupe(u8, package_root_real) });
    try entry.put(allocator, try allocator.dupe(u8, "manifestPath"), .{ .string = try allocator.dupe(u8, if (manifest_text != null) manifest_path else package_root) });

    var manifest = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = manifest });
    if (manifest_text) |text| {
        const schema_version = manifestSchemaVersion(allocator, text) catch null;
        if (schema_version) |version| {
            defer allocator.free(version);
            if (std.mem.eql(u8, version, extension_manifest.SCHEMA_VERSION)) {
                const sources = [_]extension_manifest.ManifestSource{.{
                    .package_root = package_root,
                    .manifest_path = manifest_path,
                    .manifest_text = text,
                    .source_scope = if (is_project) "project-install" else "user-install",
                    .precedence_rank = if (is_project) 1 else 0,
                }};
                var manifest_set = try installManifestSetForMetadata(allocator, io, options, is_project, sources[0]);
                defer manifest_set.deinit(allocator);
                const record = manifestRecordForPath(manifest_set.records, manifest_path) orelse return null;
                try manifest.put(allocator, try allocator.dupe(u8, "kind"), .{ .string = try allocator.dupe(u8, "pi-extension-package") });
                try manifest.put(allocator, try allocator.dupe(u8, "schemaVersion"), .{ .string = try allocator.dupe(u8, record.manifest.schema_version) });
                try manifest.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, record.manifest.id) });
                try manifest.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, record.manifest.name) });
                try manifest.put(allocator, try allocator.dupe(u8, "version"), .{ .string = try allocator.dupe(u8, record.manifest.version) });
                try manifest.put(allocator, try allocator.dupe(u8, "runtime"), .{ .string = try allocator.dupe(u8, record.manifest.runtime_kind.jsonName()) });
                try entry.put(allocator, try allocator.dupe(u8, "runtime"), .{ .string = try allocator.dupe(u8, record.manifest.runtime_kind.jsonName()) });
                try entry.put(allocator, try allocator.dupe(u8, "declarations"), try installManifestDeclarationsValue(allocator, record.manifest));
                try entry.put(allocator, try allocator.dupe(u8, "installGraph"), try installGraphValue(allocator, manifest_set));
            } else {
                try manifest.put(allocator, try allocator.dupe(u8, "kind"), .{ .string = try allocator.dupe(u8, "resource-package") });
                try manifest.put(allocator, try allocator.dupe(u8, "schemaVersion"), .{ .string = try allocator.dupe(u8, version) });
            }
        } else {
            try manifest.put(allocator, try allocator.dupe(u8, "kind"), .{ .string = try allocator.dupe(u8, "resource-package") });
        }
    } else {
        try manifest.put(allocator, try allocator.dupe(u8, "kind"), .{ .string = try allocator.dupe(u8, "resource-package") });
    }
    try entry.put(allocator, try allocator.dupe(u8, "manifest"), .{ .object = manifest });

    var digests = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = digests });
    try digests.put(allocator, try allocator.dupe(u8, "packageRootSha256"), .{ .string = try allocator.dupe(u8, package_root_sha256) });
    if (manifest_text) |text| {
        const manifest_sha256 = try sha256HexAlloc(allocator, text);
        defer allocator.free(manifest_sha256);
        try digests.put(allocator, try allocator.dupe(u8, "manifestSha256"), .{ .string = try allocator.dupe(u8, manifest_sha256) });
    }
    try entry.put(allocator, try allocator.dupe(u8, "digests"), .{ .object = digests });
    return .{ .object = entry };
}

fn installManifestSetForMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    is_project: bool,
    current_source: extension_manifest.ManifestSource,
) !extension_manifest.ManifestSet {
    var owned_sources = std.ArrayList(InstallManifestSource).empty;
    defer freeInstallManifestSources(allocator, &owned_sources);
    try collectInstalledUnifiedManifestSourcesForScope(allocator, io, options, false, &owned_sources);
    try collectInstalledUnifiedManifestSourcesForScope(allocator, io, options, true, &owned_sources);
    try owned_sources.append(allocator, .{
        .package_root = try allocator.dupe(u8, current_source.package_root),
        .manifest_path = try allocator.dupe(u8, current_source.manifest_path),
        .manifest_text = try allocator.dupe(u8, current_source.manifest_text),
        .source_scope = if (is_project) "project-install" else "user-install",
        .precedence_rank = if (is_project) 1 else 0,
    });

    const manifest_sources = try allocator.alloc(extension_manifest.ManifestSource, owned_sources.items.len);
    defer allocator.free(manifest_sources);
    for (owned_sources.items, 0..) |entry, idx| manifest_sources[idx] = entry.asManifestSource();
    return extension_manifest.resolveManifestSources(allocator, manifest_sources);
}

fn manifestRecordForPath(records: []const extension_manifest.ManifestRecord, manifest_path: []const u8) ?*const extension_manifest.ManifestRecord {
    for (records) |*record| {
        if (std.mem.eql(u8, record.manifest.manifest_path, manifest_path)) return record;
    }
    return null;
}

fn installManifestDeclarationsValue(allocator: std.mem.Allocator, manifest: extension_manifest.NormalizedManifest) !std.json.Value {
    var declarations = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = declarations });
    try declarations.put(allocator, try allocator.dupe(u8, "tools"), try common.cloneJsonValue(allocator, manifest.tools));
    try declarations.put(allocator, try allocator.dupe(u8, "hooks"), try common.cloneJsonValue(allocator, manifest.hooks));
    try declarations.put(allocator, try allocator.dupe(u8, "capabilities"), try common.cloneJsonValue(allocator, manifest.capabilities));
    try declarations.put(allocator, try allocator.dupe(u8, "permissions"), try common.cloneJsonValue(allocator, manifest.permissions));
    try declarations.put(allocator, try allocator.dupe(u8, "dependencies"), try common.cloneJsonValue(allocator, manifest.dependencies));
    try declarations.put(allocator, try allocator.dupe(u8, "workflows"), try common.cloneJsonValue(allocator, manifest.workflows));
    return .{ .object = declarations };
}

fn installGraphValue(allocator: std.mem.Allocator, manifest_set: extension_manifest.ManifestSet) !std.json.Value {
    const snapshot_text = try manifest_set.registrySnapshotJson(allocator);
    defer allocator.free(snapshot_text);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, snapshot_text, .{});
    defer parsed.deinit();
    return common.cloneJsonValue(allocator, parsed.value);
}

fn writeExtensionProvenanceLockEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    is_project: bool,
    options: ExecuteOptions,
    entry: std.json.Value,
) !void {
    if (entry != .object) return;
    const entry_key = jsonStringField(entry.object, "key") orelse return;
    const lock_path = try extensionProvenanceLockfilePath(allocator, is_project, options);
    defer allocator.free(lock_path);
    var entries = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = entries });
    const lock_text = std.Io.Dir.readFileAlloc(.cwd(), io, lock_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (lock_text) |value| allocator.free(value);
    if (lock_text) |text| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch null;
        if (parsed) |*parsed_value| {
            defer parsed_value.deinit();
            if (parsed_value.value == .object) {
                if (parsed_value.value.object.get("entries")) |old_entries| {
                    if (old_entries == .array) {
                        for (old_entries.array.items) |old_entry| {
                            if (old_entry != .object) continue;
                            const old_key = jsonStringField(old_entry.object, "key") orelse continue;
                            if (std.mem.eql(u8, old_key, entry_key)) continue;
                            try entries.append(try common.cloneJsonValue(allocator, old_entry));
                        }
                    }
                }
            }
        }
    }
    try entries.append(try common.cloneJsonValue(allocator, entry));

    var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = root });
    try root.put(allocator, try allocator.dupe(u8, "schemaVersion"), .{ .string = try allocator.dupe(u8, EXTENSION_PROVENANCE_LOCK_SCHEMA_VERSION) });
    try root.put(allocator, try allocator.dupe(u8, "entries"), .{ .array = entries });
    const value = std.json.Value{ .object = root };
    defer common.deinitJsonValue(allocator, value);
    const serialized = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    try common.writeFileAbsolute(io, lock_path, serialized, true);
}

fn extensionProvenanceLockfilePath(
    allocator: std.mem.Allocator,
    is_project: bool,
    options: ExecuteOptions,
) ![]u8 {
    if (is_project) return std.fs.path.join(allocator, &[_][]const u8{ options.cwd, ".pi", EXTENSION_PROVENANCE_LOCKFILE_NAME });
    return std.fs.path.join(allocator, &[_][]const u8{ options.agent_dir, EXTENSION_PROVENANCE_LOCKFILE_NAME });
}

fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (@import("builtin").os.tag == .windows) {
        return std.fs.path.resolve(allocator, &.{path}) catch allocator.dupe(u8, path);
    }
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = std.c.realpath(z_path.ptr, &buffer) orelse return error.FileNotFound;
    return allocator.dupe(u8, std.mem.span(resolved));
}

fn sha256HexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, hex[0..]);
}

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch return false;
    return true;
}

fn validateLocalPackageForInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
    mode: LocalPathMode,
    stderr: *std.Io.Writer,
) !LocalWasmInstallValidation {
    if (!isLocalSource(source)) return .absent;

    const package_root = switch (mode) {
        .input => try resolveLocalPathFromCwd(allocator, options.cwd, source),
        .settings => try resolveLocalPathFromScopeBase(allocator, source, is_project, options.cwd, options.agent_dir),
    };
    defer allocator.free(package_root);

    const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    const manifest_text = std.Io.Dir.readFileAlloc(.cwd(), io, manifest_path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return err,
    };
    defer allocator.free(manifest_text);

    const schema_version = manifestSchemaVersion(allocator, manifest_text) catch null;
    if (schema_version) |version| {
        defer allocator.free(version);
        if (std.mem.eql(u8, version, extension_manifest.SCHEMA_VERSION)) {
            const valid = try validateUnifiedExtensionPackageForInstall(
                allocator,
                io,
                source,
                is_project,
                options,
                package_root,
                manifest_path,
                manifest_text,
                stderr,
            );
            return if (valid) .absent else .invalid;
        }
    }

    return validateLocalWasmPackageForInstall(allocator, io, package_root, manifest_path, is_project, stderr, options);
}

fn validateLocalWasmPackageForInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_root: []const u8,
    manifest_path: []const u8,
    is_project: bool,
    stderr: *std.Io.Writer,
    options: ExecuteOptions,
) !LocalWasmInstallValidation {
    var approved_capabilities: ?[]wasm_manifest.Capability = null;
    defer {
        if (approved_capabilities) |capabilities| allocator.free(capabilities);
    }

    if (try readWasmPackagePolicyRequest(allocator, io, package_root, manifest_path)) |request_value| {
        var request = request_value;
        defer request.deinit(allocator);
        var effective_settings = try loadEffectiveSettingsForPackageInstall(allocator, io, options);
        defer effective_settings.deinit(allocator);
        const policy = (try resolveFinalWasmExtensionPolicy(allocator, io, effective_settings, package_root)) orelse
            lookupExtensionPolicy(effective_settings, request.policy_lookup_key);
        if (policy) |resolved_policy| {
            approved_capabilities = try approvedCapabilitiesFromExtensionPolicy(allocator, resolved_policy);
        }
    }

    const capabilities = approved_capabilities orelse wasm_manifest.CANONICAL_CAPABILITIES[0..];
    var result = try wasm_manifest.validateManifestFileWithOptions(allocator, io, package_root, .{
        .approved_capabilities = capabilities,
    });
    defer result.deinit(allocator);
    if (result == .invalid) {
        try writeWasmValidationDiagnostics(allocator, stderr, result.invalid);
        return .invalid;
    }
    const source_identity = try allocator.dupe(u8, result.valid.package_root);
    defer allocator.free(source_identity);
    return .{ .valid = try provenance_lockfile.createWasmLockEntry(allocator, provenanceScope(is_project), source_identity, &result.valid) };
}

fn manifestSchemaVersion(allocator: std.mem.Allocator, manifest_text: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("schemaVersion") orelse return null;
    if (value != .string) return null;
    return try allocator.dupe(u8, value.string);
}

const InstallManifestSource = struct {
    package_root: []u8,
    manifest_path: []u8,
    manifest_text: []u8,
    source_scope: []const u8,
    precedence_rank: u16,

    fn asManifestSource(self: InstallManifestSource) extension_manifest.ManifestSource {
        return .{
            .package_root = self.package_root,
            .manifest_path = self.manifest_path,
            .manifest_text = self.manifest_text,
            .source_scope = self.source_scope,
            .precedence_rank = self.precedence_rank,
        };
    }

    fn deinit(self: *InstallManifestSource, allocator: std.mem.Allocator) void {
        allocator.free(self.package_root);
        allocator.free(self.manifest_path);
        allocator.free(self.manifest_text);
        self.* = undefined;
    }
};

fn freeInstallManifestSources(allocator: std.mem.Allocator, list: *std.ArrayList(InstallManifestSource)) void {
    for (list.items) |*entry| entry.deinit(allocator);
    list.deinit(allocator);
}

fn collectInstalledUnifiedManifestSourcesForScope(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    is_project: bool,
    out: *std.ArrayList(InstallManifestSource),
) !void {
    var entries = try collectScopePackageEntries(allocator, io, options, is_project);
    defer freeListEntries(allocator, &entries);

    for (entries.items) |entry| {
        if (!isLocalSource(entry.source)) continue;
        const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ entry.installed_path, wasm_manifest.MANIFEST_FILE_NAME });
        errdefer allocator.free(manifest_path);
        const manifest_text = std.Io.Dir.readFileAlloc(.cwd(), io, manifest_path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(manifest_path);
                continue;
            },
            else => return err,
        };
        errdefer allocator.free(manifest_text);

        const schema_version = manifestSchemaVersion(allocator, manifest_text) catch null;
        if (schema_version) |version| {
            defer allocator.free(version);
            if (!std.mem.eql(u8, version, extension_manifest.SCHEMA_VERSION)) {
                allocator.free(manifest_path);
                allocator.free(manifest_text);
                continue;
            }
        } else {
            allocator.free(manifest_path);
            allocator.free(manifest_text);
            continue;
        }

        try out.append(allocator, .{
            .package_root = try allocator.dupe(u8, entry.installed_path),
            .manifest_path = manifest_path,
            .manifest_text = manifest_text,
            .source_scope = if (is_project) "project-installed" else "user-installed",
            .precedence_rank = if (is_project) 2 else 3,
        });
    }
}

fn validateUnifiedExtensionPackageForInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
    package_root: []const u8,
    manifest_path: []const u8,
    manifest_text: []const u8,
    stderr: *std.Io.Writer,
) !bool {
    var owned_sources = std.ArrayList(InstallManifestSource).empty;
    defer freeInstallManifestSources(allocator, &owned_sources);

    try collectInstalledUnifiedManifestSourcesForScope(allocator, io, options, false, &owned_sources);
    try collectInstalledUnifiedManifestSourcesForScope(allocator, io, options, true, &owned_sources);
    try owned_sources.append(allocator, .{
        .package_root = try allocator.dupe(u8, package_root),
        .manifest_path = try allocator.dupe(u8, manifest_path),
        .manifest_text = try allocator.dupe(u8, manifest_text),
        .source_scope = if (is_project) "project-install" else "user-install",
        .precedence_rank = if (is_project) 1 else 0,
    });

    const manifest_sources = try allocator.alloc(extension_manifest.ManifestSource, owned_sources.items.len);
    defer allocator.free(manifest_sources);
    for (owned_sources.items, 0..) |entry, idx| manifest_sources[idx] = entry.asManifestSource();

    var manifest_set = try extension_manifest.resolveManifestSources(allocator, manifest_sources);
    defer manifest_set.deinit(allocator);
    var effective_settings = try loadEffectiveSettingsForPackageInstall(allocator, io, options);
    defer effective_settings.deinit(allocator);

    var accepted = true;
    for (manifest_set.diagnostics) |diagnostic| {
        try writeUnifiedInstallDiagnostic(stderr, diagnostic);
        accepted = false;
    }
    for (manifest_set.records) |record| {
        if (!std.mem.eql(u8, record.manifest.manifest_path, manifest_path)) continue;
        if (!record.active) {
            const reason = record.inactive_reason orelse "inactive";
            try stderr.print("Error: {s}: install.package_inactive: package \"{s}\" inactive before load ({s})\n", .{
                record.manifest.manifest_path,
                record.manifest.id,
                reason,
            });
            accepted = false;
        }
        if (!record.manifest.runtime_kind.executable()) {
            try stderr.print("Error: {s}: install.unsupported_runtime: runtime \"{s}\" is not executable for package \"{s}\"\n", .{
                record.manifest.manifest_path,
                record.manifest.runtime_kind.jsonName(),
                record.manifest.id,
            });
            accepted = false;
        }
        if (try packageHasDeniedPermissions(allocator, record, stderr)) accepted = false;
        if (try packageHasUnapprovedRequestedPermissions(allocator, record, effective_settings, is_project, stderr)) accepted = false;
    }

    if (!accepted) {
        try stderr.print("Error: install rejected {s} before load\n", .{source});
        return false;
    }
    return true;
}

fn writeUnifiedInstallDiagnostic(stderr: *std.Io.Writer, diagnostic: extension_manifest.Diagnostic) !void {
    try stderr.print("Error: severity={s} code={s} packageId={s} runtime={s} capabilityId={s} policySource={s} phase={s} correlationId={s} spanId={s} manifest={s} path={s}: {s}\n", .{
        diagnostic.severity,
        diagnostic.code,
        diagnostic.package_id orelse "unknown",
        diagnostic.runtime orelse "unknown",
        diagnostic.capability_id orelse "none",
        diagnostic.policy_source orelse "none",
        diagnostic.phase,
        diagnostic.correlation_id,
        diagnostic.span_id,
        diagnostic.manifest_path,
        diagnostic.path,
        diagnostic.message,
    });
}

fn packageHasDeniedPermissions(
    allocator: std.mem.Allocator,
    record: extension_manifest.ManifestRecord,
    stderr: *std.Io.Writer,
) !bool {
    if (record.manifest.permissions != .array) return false;
    var denied = false;
    for (record.manifest.permissions.array.items, 0..) |permission, idx| {
        if (!jsonObjectPolicyDenied(permission)) continue;
        const permission_id = jsonObjectString(permission, "id") orelse jsonObjectString(permission, "permission") orelse jsonObjectString(permission, "grant") orelse "unknown";
        const policy_source = jsonObjectString(permission, "policySource") orelse "manifest";
        const correlation_id = try std.fmt.allocPrint(allocator, "install:{s}", .{record.manifest.id});
        defer allocator.free(correlation_id);
        const span_id = try std.fmt.allocPrint(allocator, "install.policy_denied_permission:$.permissions[{d}]", .{idx});
        defer allocator.free(span_id);
        try stderr.print(
            "Error: severity=error code=install.policy_denied_permission packageId={s} runtime={s} capabilityId={s} policySource={s} phase=install correlationId={s} spanId={s} manifest={s} path=$.permissions[{d}]: permission \"{s}\" denied by {s} policy for package \"{s}\"\n",
            .{
                record.manifest.id,
                record.manifest.runtime_kind.jsonName(),
                permission_id,
                policy_source,
                correlation_id,
                span_id,
                record.manifest.manifest_path,
                idx,
                permission_id,
                policy_source,
                record.manifest.id,
            },
        );
        denied = true;
    }
    return denied;
}

fn packageHasUnapprovedRequestedPermissions(
    allocator: std.mem.Allocator,
    record: extension_manifest.ManifestRecord,
    effective_settings: config_mod.Settings,
    is_project: bool,
    stderr: *std.Io.Writer,
) !bool {
    if (record.manifest.permissions != .array) return false;
    const policy_key = try unifiedManifestPolicyLookupKey(allocator, record, is_project);
    defer allocator.free(policy_key);
    const policy = lookupExtensionPolicy(effective_settings, policy_key) orelse
        lookupExtensionPolicy(effective_settings, record.manifest.id);

    var denied = false;
    for (record.manifest.permissions.array.items, 0..) |permission, idx| {
        if (jsonObjectPolicyDenied(permission)) continue;
        const permission_id = jsonObjectString(permission, "id") orelse jsonObjectString(permission, "permission") orelse jsonObjectString(permission, "grant") orelse continue;
        const approved = if (policy) |resolved| extensionPolicyApprovesGrant(resolved, permission_id) else false;
        if (approved) continue;
        const policy_source: []const u8 = if (policy == null) "merged-default-deny" else "merged";
        const correlation_id = try std.fmt.allocPrint(allocator, "install:{s}", .{record.manifest.id});
        defer allocator.free(correlation_id);
        const span_id = try std.fmt.allocPrint(allocator, "install.policy_denied_permission:$.permissions[{d}]", .{idx});
        defer allocator.free(span_id);
        try stderr.print(
            "Error: severity=error code=install.policy_denied_permission packageId={s} runtime={s} capabilityId={s} policySource={s} phase=install correlationId={s} spanId={s} manifest={s} path=$.permissions[{d}]: permission \"{s}\" is not approved by merged policy for package \"{s}\" (policyKey={s})\n",
            .{
                record.manifest.id,
                record.manifest.runtime_kind.jsonName(),
                permission_id,
                policy_source,
                correlation_id,
                span_id,
                record.manifest.manifest_path,
                idx,
                permission_id,
                record.manifest.id,
                policy_key,
            },
        );
        denied = true;
    }
    return denied;
}

fn unifiedManifestPolicyLookupKey(
    allocator: std.mem.Allocator,
    record: extension_manifest.ManifestRecord,
    is_project: bool,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}:manifest:{s}:{s}:{s}:{s}:{s}",
        .{
            record.manifest.runtime_kind.jsonName(),
            if (is_project) "project" else "user",
            record.manifest.id,
            record.manifest.version,
            record.manifest.package_root,
            record.manifest.manifest_path,
        },
    );
}

fn extensionPolicyApprovesGrant(policy: config_mod.ExtensionPolicy, grant: []const u8) bool {
    if (policy.enabled) |enabled| if (!enabled) return false;
    if (policy.approved) |approved| if (!approved) return false;
    const approved_grants = policy.approved_grants orelse return false;
    for (approved_grants) |approved_grant| {
        if (std.mem.eql(u8, approved_grant, grant)) return true;
    }
    return false;
}

fn jsonObjectPolicyDenied(value: std.json.Value) bool {
    if (value != .object) return false;
    if (value.object.get("policyDenied")) |policy_denied| {
        if (policy_denied == .bool and policy_denied.bool) return true;
    }
    if (value.object.get("policy")) |policy| {
        if (policy == .object) {
            if (policy.object.get("approved")) |approved| {
                if (approved == .bool and !approved.bool) return true;
            }
        }
    }
    return false;
}

fn jsonObjectString(value: std.json.Value, field: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field_value = value.object.get(field) orelse return null;
    if (field_value != .string) return null;
    return field_value.string;
}

fn jsonStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn readWasmPackagePolicyRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_root: []const u8,
    manifest_path: []const u8,
) !?WasmPackagePolicyRequest {
    const manifest_text = std.Io.Dir.readFileAlloc(.cwd(), io, manifest_path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(manifest_text);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;
    const schema_version = jsonStringField(root, "schemaVersion") orelse return null;
    const id = jsonStringField(root, "id") orelse return null;
    const version = jsonStringField(root, "version") orelse return null;
    const artifact = root.get("artifact") orelse return null;
    if (artifact != .object) return null;
    const artifact_path = jsonStringField(artifact.object, "path") orelse return null;

    const policy_lookup_key = try policy_key_mod.wasmManifestPolicyLookupKey(allocator, .{
        .schema_version = schema_version,
        .id = id,
        .version = version,
        .package_root = package_root,
        .manifest_path = manifest_path,
        .artifact_path = artifact_path,
    });
    return .{ .policy_lookup_key = policy_lookup_key };
}

fn loadEffectiveSettingsForPackageInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
) !config_mod.Settings {
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", options.agent_dir);
    return config_mod.loadMergedSettingsForPreflight(allocator, io, &env_map, options.cwd);
}

fn resolveFinalWasmExtensionPolicy(
    allocator: std.mem.Allocator,
    io: std.Io,
    effective_settings: config_mod.Settings,
    package_root: []const u8,
) !?config_mod.ExtensionPolicy {
    var manifest_result = try wasm_manifest.validateManifestFileWithOptions(allocator, io, package_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer manifest_result.deinit(allocator);
    if (manifest_result != .valid) return null;
    const identity_key = try policy_key_mod.wasmPolicyLookupKey(allocator, extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid));
    defer allocator.free(identity_key);
    return lookupExtensionPolicy(effective_settings, identity_key);
}

fn lookupExtensionPolicy(settings: config_mod.Settings, identity_key: []const u8) ?config_mod.ExtensionPolicy {
    var policies = settings.extension_policies orelse return null;
    var iterator = policies.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, identity_key)) return entry.value_ptr.*;
    }
    return null;
}

fn approvedCapabilitiesFromExtensionPolicy(
    allocator: std.mem.Allocator,
    policy: config_mod.ExtensionPolicy,
) ![]wasm_manifest.Capability {
    const approved_grants = policy.approved_grants orelse return allocator.alloc(wasm_manifest.Capability, 0);
    var capabilities = std.ArrayList(wasm_manifest.Capability).empty;
    errdefer capabilities.deinit(allocator);
    for (approved_grants) |grant| {
        if (wasm_manifest.parseCapability(grant)) |capability| {
            try capabilities.append(allocator, capability);
        }
    }
    return capabilities.toOwnedSlice(allocator);
}

fn wasmPolicyLookupKeyFromLockEntry(
    allocator: std.mem.Allocator,
    entry: provenance_lockfile.LockEntry,
) ![]u8 {
    const schema_version = entry.manifest_schema_version orelse wasm_manifest.SCHEMA_VERSION;
    const extension_id = entry.manifest_id orelse "";
    const extension_name = entry.manifest_name orelse extension_id;
    const extension_version = entry.manifest_version orelse "";
    const artifact_path = entry.artifact_path orelse "";
    const artifact_absolute_path = entry.artifact_absolute_path orelse "";
    const artifact_sha256 = entry.artifact_sha256 orelse "";
    const tool_id = entry.manifest_tool_id orelse "";
    const handoff = extension_runtime.WasmManifestHandoff{
        .policy_scope = entry.scope.jsonName(),
        .package_root = entry.package_root,
        .manifest_path = entry.manifest_path,
        .schema_version = schema_version,
        .id = extension_id,
        .name = extension_name,
        .version = extension_version,
        .description = "",
        .artifact_kind = .wasm_component,
        .artifact_path = artifact_path,
        .artifact_absolute_path = artifact_absolute_path,
        .artifact_sha256 = artifact_sha256,
        .package_root_sha256 = entry.package_root_sha256,
        .tool_id = tool_id,
        .tool_description = "",
        .input_schema_json = "{}",
        .output_schema_json = "{}",
    };
    return policy_key_mod.wasmPolicyLookupKey(allocator, handoff);
}

fn writeWasmInstallDetails(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    source: []const u8,
    entry: provenance_lockfile.LockEntry,
) !void {
    const policy_key = try wasmPolicyLookupKeyFromLockEntry(allocator, entry);
    defer allocator.free(policy_key);
    const redacted_source = try redactDiagnosticValue(allocator, source);
    defer allocator.free(redacted_source);
    const redacted_root = try redactDiagnosticValue(allocator, entry.package_root);
    defer allocator.free(redacted_root);
    const redacted_artifact = try redactDiagnosticValue(allocator, entry.artifact_absolute_path orelse "");
    defer allocator.free(redacted_artifact);
    const redacted_policy = try redactDiagnosticValue(allocator, policy_key);
    defer allocator.free(redacted_policy);

    try stdout.print("  extension: {s}@{s}\n", .{ entry.manifest_id orelse "<unknown>", entry.manifest_version orelse "<unknown>" });
    try stdout.print("  tool: {s}\n", .{entry.manifest_tool_id orelse "<unknown>"});
    try stdout.print("  scope: {s}\n", .{entry.scope.jsonName()});
    try stdout.writeAll("  runtime: wasm\n");
    try stdout.writeAll("  trust: locked\n");
    try stdout.print("  source: {s}\n", .{redacted_source});
    try stdout.print("  package root: {s}\n", .{redacted_root});
    try stdout.print("  artifact: {s}\n", .{redacted_artifact});
    try stdout.print("  package root sha256: {s}\n", .{entry.package_root_sha256});
    if (entry.artifact_sha256) |artifact_sha256| {
        try stdout.print("  artifact sha256: {s}\n", .{artifact_sha256});
    }
    try stdout.print("  approval target: {s}\n", .{redacted_policy});
    try stdout.writeAll("  next: add a matching extensionPolicies entry before normal tool use.\n");
}

fn writeWasmValidationDiagnostics(
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
    diagnostics: []const wasm_manifest.Diagnostic,
) !void {
    if (diagnostics.len == 0) {
        try stderr.writeAll("Error: invalid Wasm extension package\n");
        return;
    }
    for (diagnostics) |diagnostic| {
        const path = try redactDiagnosticValue(allocator, diagnostic.path);
        defer allocator.free(path);
        const message = try redactDiagnosticValue(allocator, diagnostic.message);
        defer allocator.free(message);
        try stderr.print("Error: {s}: {s}\n", .{ path, message });
        if (diagnostic.principal) |principal| {
            const policy_key = try redactDiagnosticValue(allocator, principal.policy_lookup_key);
            defer allocator.free(policy_key);
            try stderr.print("  extension: {s}\n  tool: {s}\n  runtime: {s}\n  approval target: {s}\n", .{
                principal.extension_id,
                principal.tool_id,
                principal.runtime_kind,
                policy_key,
            });
        }
        if (diagnostic.capability) |capability| {
            try stderr.print("  capability: {s}\n", .{capability.jsonName()});
        }
        if (diagnostic.source) |source| {
            const manifest_path = try redactDiagnosticValue(allocator, source.manifest_path);
            defer allocator.free(manifest_path);
            const package_root = try redactDiagnosticValue(allocator, source.package_root);
            defer allocator.free(package_root);
            const artifact_path = try redactDiagnosticValue(allocator, source.artifact_path);
            defer allocator.free(artifact_path);
            try stderr.print("  manifest: {s}\n  package root: {s}\n  artifact: {s}\n", .{
                manifest_path,
                package_root,
                artifact_path,
            });
        }
    }
}

fn redactDiagnosticValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < value.len) {
        if (startsWithIgnoreCase(value[index..], "Bearer ")) {
            try out.writer.writeAll("Bearer [REDACTED]");
            index = skipUntilDelimiter(value, index + "Bearer ".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "api_key=")) {
            try out.writer.writeAll("api_key=[REDACTED]");
            index = skipUntilDelimiter(value, index + "api_key=".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "access_token=")) {
            try out.writer.writeAll("access_token=[REDACTED]");
            index = skipUntilDelimiter(value, index + "access_token=".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "token=")) {
            try out.writer.writeAll("token=[REDACTED]");
            index = skipUntilDelimiter(value, index + "token=".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "x-api-key:")) {
            try out.writer.writeAll("x-api-key: [REDACTED]");
            index = skipUntilDelimiter(value, index + "x-api-key:".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "sk-")) {
            try out.writer.writeAll("[REDACTED]");
            index = skipUntilDelimiter(value, index);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "secret")) {
            try out.writer.writeAll("[REDACTED]");
            index += "secret".len;
            continue;
        }
        try out.writer.writeByte(value[index]);
        index += 1;
    }
    return out.toOwnedSlice();
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn skipUntilDelimiter(value: []const u8, start: usize) usize {
    var index = start;
    while (index < value.len) : (index += 1) {
        switch (value[index]) {
            ' ', '\t', '\r', '\n', '&', '"', '\'', ',', ')' => return index,
            else => {},
        }
    }
    return index;
}

const FileSnapshot = struct {
    path: []u8,
    existed: bool,
    bytes: ?[]u8 = null,

    fn deinit(self: *FileSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.bytes) |bytes| allocator.free(bytes);
        self.* = undefined;
    }
};

fn captureFileSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !FileSnapshot {
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{
            .path = try allocator.dupe(u8, path),
            .existed = false,
            .bytes = null,
        },
        else => return err,
    };
    return .{
        .path = try allocator.dupe(u8, path),
        .existed = true,
        .bytes = bytes,
    };
}

fn restoreFileSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    snapshot: FileSnapshot,
) !void {
    if (!snapshot.existed) {
        std.Io.Dir.deleteFileAbsolute(io, snapshot.path) catch {};
        return;
    }
    if (snapshot.bytes) |bytes| {
        try common.writeFileAbsolute(io, snapshot.path, bytes, true);
    }
    _ = allocator;
}

fn provenanceScope(is_project: bool) ProvenanceScope {
    return if (is_project) .project else .user;
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

    const matched_index = try findPackageIndex(allocator, packages_value_ptr.?.array, source, command.local, options);
    if (matched_index == null) {
        try stderr.print("Error: No matching package found for {s}\n", .{source});
        return .{ .exit_code = 1 };
    }
    const matched_source = try packageSourceFromItem(allocator, packages_value_ptr.?.array.items[matched_index.?]);
    defer allocator.free(matched_source);

    const scope = provenanceScope(command.local);
    const lockfile_path = try provenance_lockfile.lockfilePath(allocator, scope, options.cwd, options.agent_dir);
    defer allocator.free(lockfile_path);
    var settings_snapshot = try captureFileSnapshot(allocator, io, settings_path);
    defer settings_snapshot.deinit(allocator);
    var lock_snapshot = try captureFileSnapshot(allocator, io, lockfile_path);
    defer lock_snapshot.deinit(allocator);

    const removed = packages_value_ptr.?.array.orderedRemove(matched_index.?);
    common.deinitJsonValue(allocator, removed);

    writeSettingsObject(allocator, io, settings_path, settings_object, options) catch |err| {
        try restoreFileSnapshot(allocator, io, settings_snapshot);
        return err;
    };
    removeLocalWasmProvenanceForSource(allocator, io, source, command.local, options, .input, lockfile_path) catch |err| {
        try restoreFileSnapshot(allocator, io, settings_snapshot);
        try restoreFileSnapshot(allocator, io, lock_snapshot);
        try stderr.print("Error: failed to remove extension provenance for {s}: {s}\n", .{ source, @errorName(err) });
        return .{ .exit_code = 1 };
    };
    removeLocalWasmProvenanceForSource(allocator, io, matched_source, command.local, options, .settings, lockfile_path) catch |err| {
        try restoreFileSnapshot(allocator, io, settings_snapshot);
        try restoreFileSnapshot(allocator, io, lock_snapshot);
        try stderr.print("Error: failed to remove extension provenance for {s}: {s}\n", .{ source, @errorName(err) });
        return .{ .exit_code = 1 };
    };
    const redacted_source = try redactDiagnosticValue(allocator, source);
    defer allocator.free(redacted_source);
    try stdout.print("Removed {s}\n  scope: {s}\n", .{ redacted_source, scope.jsonName() });
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
            const extensions_result = try executeExtensionUpdates(allocator, io, options, null, stderr);
            if (extensions_result.exit_code != 0) return extensions_result;
            try stdout.print("Updated packages\n", .{});
            return executeSelfUpdate(allocator, io, command.force, options, stdout, stderr);
        },
        .self => {
            return executeSelfUpdate(allocator, io, command.force, options, stdout, stderr);
        },
        .extensions => {
            const extensions_result = try executeExtensionUpdates(allocator, io, options, null, stderr);
            if (extensions_result.exit_code != 0) return extensions_result;
            try stdout.print("Updated packages\n", .{});
            return .{ .exit_code = 0 };
        },
        .source => |source| {
            const extensions_result = try executeExtensionUpdates(allocator, io, options, source, stderr);
            if (extensions_result.exit_code != 0) return extensions_result;
            try stdout.print("Updated {s}\n", .{source});
            return .{ .exit_code = 0 };
        },
    }
}

const UpdateSource = struct {
    source: []u8,
    is_project: bool,

    fn deinit(self: *UpdateSource, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        self.* = undefined;
    }
};

fn freeUpdateSources(allocator: std.mem.Allocator, list: *std.ArrayList(UpdateSource)) void {
    for (list.items) |*entry| entry.deinit(allocator);
    list.deinit(allocator);
}

fn collectUpdateSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    source_filter: ?[]const u8,
) !std.ArrayList(UpdateSource) {
    var result: std.ArrayList(UpdateSource) = .empty;
    errdefer freeUpdateSources(allocator, &result);

    var user_sources = try collectScopePackages(allocator, io, options, false);
    defer freeOwnedStrings(allocator, &user_sources);
    for (user_sources.items) |entry| {
        if (source_filter) |filter| {
            if (!try packageSourcesMatchForScope(allocator, entry, filter, false, options)) continue;
        }
        try result.append(allocator, .{
            .source = try allocator.dupe(u8, entry),
            .is_project = false,
        });
    }

    var project_sources = try collectScopePackages(allocator, io, options, true);
    defer freeOwnedStrings(allocator, &project_sources);
    for (project_sources.items) |entry| {
        if (source_filter) |filter| {
            if (!try packageSourcesMatchForScope(allocator, entry, filter, true, options)) continue;
        }
        try result.append(allocator, .{
            .source = try allocator.dupe(u8, entry),
            .is_project = true,
        });
    }

    return result;
}

fn executeExtensionUpdates(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    source_filter: ?[]const u8,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    var sources = try collectUpdateSources(allocator, io, options, source_filter);
    defer freeUpdateSources(allocator, &sources);

    if (source_filter) |source| {
        if (sources.items.len == 0) {
            if (try findSuggestedConfiguredSource(allocator, io, options, source)) |suggestion| {
                defer allocator.free(suggestion);
                try stderr.print("Error: No matching package found for {s}. Did you mean {s}?\n", .{ source, suggestion });
            } else {
                try stderr.print("Error: No matching package found for {s}\n", .{source});
            }
            return .{ .exit_code = 1 };
        }
    }

    const user_lock_path = try provenance_lockfile.lockfilePath(allocator, .user, options.cwd, options.agent_dir);
    defer allocator.free(user_lock_path);
    const project_lock_path = try provenance_lockfile.lockfilePath(allocator, .project, options.cwd, options.agent_dir);
    defer allocator.free(project_lock_path);
    var user_lock_snapshot = try captureFileSnapshot(allocator, io, user_lock_path);
    defer user_lock_snapshot.deinit(allocator);
    var project_lock_snapshot = try captureFileSnapshot(allocator, io, project_lock_path);
    defer project_lock_snapshot.deinit(allocator);

    for (sources.items) |entry| {
        const updated = if (isNpmSource(entry.source))
            try executeNpmUpdate(allocator, io, entry.source, entry.is_project, options, stderr)
        else if (isGitSource(entry.source))
            try executeGitUpdate(allocator, io, entry.source, entry.is_project, options, stderr)
        else
            true;
        if (!updated) {
            try restoreFileSnapshot(allocator, io, user_lock_snapshot);
            try restoreFileSnapshot(allocator, io, project_lock_snapshot);
            return .{ .exit_code = 1 };
        }
        if (isLocalSource(entry.source)) {
            var wasm_update = try validateLocalPackageForInstall(allocator, io, entry.source, entry.is_project, options, .settings, stderr);
            defer wasm_update.deinit(allocator);
            if (wasm_update == .invalid) {
                try stderr.print("Error: failed to update extension {s}\n", .{entry.source});
                try restoreFileSnapshot(allocator, io, user_lock_snapshot);
                try restoreFileSnapshot(allocator, io, project_lock_snapshot);
                return .{ .exit_code = 1 };
            }
            if (wasm_update == .valid) {
                const scope = provenanceScope(entry.is_project);
                const lockfile_path = if (entry.is_project) project_lock_path else user_lock_path;
                writeProvenanceEntry(allocator, io, scope, lockfile_path, wasm_update.valid, options) catch |err| {
                    try restoreFileSnapshot(allocator, io, user_lock_snapshot);
                    try restoreFileSnapshot(allocator, io, project_lock_snapshot);
                    try stderr.print("Error: failed to update extension provenance for {s}: {s}\n", .{ entry.source, @errorName(err) });
                    return .{ .exit_code = 1 };
                };
            }
        }
    }

    return .{ .exit_code = 0 };
}

fn findSuggestedConfiguredSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    source: []const u8,
) !?[]u8 {
    var all_sources = try collectUpdateSources(allocator, io, options, null);
    defer freeUpdateSources(allocator, &all_sources);

    const trimmed = std.mem.trim(u8, source, " ");
    for (all_sources.items) |entry| {
        if (isNpmSource(entry.source)) {
            const spec = std.mem.trim(u8, entry.source["npm:".len..], " ");
            if (std.mem.eql(u8, trimmed, spec) or std.mem.eql(u8, trimmed, npmPackageName(spec))) {
                return try allocator.dupe(u8, entry.source);
            }
        } else if (isGitSource(entry.source)) {
            var info = (try parseGitSource(allocator, entry.source)) orelse continue;
            defer info.deinit(allocator);
            const shorthand = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ info.host, info.path });
            defer allocator.free(shorthand);
            if (std.mem.eql(u8, trimmed, shorthand)) {
                return try allocator.dupe(u8, entry.source);
            }
            if (info.ref) |ref| {
                const shorthand_with_ref = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ shorthand, ref });
                defer allocator.free(shorthand_with_ref);
                if (std.mem.eql(u8, trimmed, shorthand_with_ref)) {
                    return try allocator.dupe(u8, entry.source);
                }
            }
        }
    }
    return null;
}

const package_name = "@earendil-works/pi-coding-agent";

const ParsedPackageVersion = struct {
    major: u64,
    minor: u64,
    patch: u64,
    prerelease: ?[]const u8 = null,
};

fn parsePackageVersion(version: []const u8) ?ParsedPackageVersion {
    const trimmed = std.mem.trim(u8, version, " \t\r\n");
    const without_prefix = if (std.mem.startsWith(u8, trimmed, "v")) trimmed[1..] else trimmed;
    const build_index = std.mem.indexOfScalar(u8, without_prefix, '+') orelse without_prefix.len;
    const without_build = without_prefix[0..build_index];
    const prerelease_index = std.mem.indexOfScalar(u8, without_build, '-');
    const core = if (prerelease_index) |index| without_build[0..index] else without_build;
    const prerelease = if (prerelease_index) |index| without_build[index + 1 ..] else null;

    var parts = std.mem.splitScalar(u8, core, '.');
    const major_text = parts.next() orelse return null;
    const minor_text = parts.next() orelse return null;
    const patch_text = parts.next() orelse return null;
    if (parts.next() != null) return null;
    if (major_text.len == 0 or minor_text.len == 0 or patch_text.len == 0) return null;

    return .{
        .major = std.fmt.parseInt(u64, major_text, 10) catch return null,
        .minor = std.fmt.parseInt(u64, minor_text, 10) catch return null,
        .patch = std.fmt.parseInt(u64, patch_text, 10) catch return null,
        .prerelease = if (prerelease) |value| if (value.len == 0) null else value else null,
    };
}

fn comparePackageVersions(left_version: []const u8, right_version: []const u8) ?i8 {
    const left = parsePackageVersion(left_version) orelse return null;
    const right = parsePackageVersion(right_version) orelse return null;
    if (left.major != right.major) return if (left.major > right.major) 1 else -1;
    if (left.minor != right.minor) return if (left.minor > right.minor) 1 else -1;
    if (left.patch != right.patch) return if (left.patch > right.patch) 1 else -1;
    if (left.prerelease == null and right.prerelease == null) return 0;
    if (left.prerelease == null) return 1;
    if (right.prerelease == null) return -1;
    return switch (std.mem.order(u8, left.prerelease.?, right.prerelease.?)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn isNewerPackageVersion(candidate_version: []const u8, current_version: []const u8) bool {
    if (comparePackageVersions(candidate_version, current_version)) |comparison| {
        return comparison > 0;
    }
    return !std.mem.eql(
        u8,
        std.mem.trim(u8, candidate_version, " \t\r\n"),
        std.mem.trim(u8, current_version, " \t\r\n"),
    );
}

const GitSourceInfo = struct {
    repo: []u8,
    host: []u8,
    path: []u8,
    ref: ?[]u8 = null,

    fn deinit(self: *GitSourceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.repo);
        allocator.free(self.host);
        allocator.free(self.path);
        if (self.ref) |value| allocator.free(value);
        self.* = undefined;
    }
};

const PackageTool = enum { npm, git };
const GitRefSplit = struct {
    repo_part: []const u8,
    ref: ?[]const u8,
};

fn isNpmSource(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "npm:");
}

fn isGitSource(source: []const u8) bool {
    if (std.mem.startsWith(u8, source, "git:")) return true;
    if (std.mem.startsWith(u8, source, "https://")) return true;
    if (std.mem.startsWith(u8, source, "http://")) return true;
    if (std.mem.startsWith(u8, source, "ssh://")) return true;
    if (std.mem.startsWith(u8, source, "git://")) return true;
    return false;
}

fn trimGitSuffix(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".git")) return path[0 .. path.len - ".git".len];
    return path;
}

fn splitRef(source: []const u8) GitRefSplit {
    if (std.mem.startsWith(u8, source, "git@")) {
        const colon = std.mem.indexOfScalar(u8, source, ':') orelse return .{ .repo_part = source, .ref = null };
        const after_colon = source[colon + 1 ..];
        const at = std.mem.indexOfScalar(u8, after_colon, '@') orelse return .{ .repo_part = source, .ref = null };
        if (at == 0 or at + 1 >= after_colon.len) return .{ .repo_part = source, .ref = null };
        return .{
            .repo_part = source[0 .. colon + 1 + at],
            .ref = after_colon[at + 1 ..],
        };
    }

    if (std.mem.indexOf(u8, source, "://")) |_| {
        const scheme_end = std.mem.indexOf(u8, source, "://").? + "://".len;
        const path_start = std.mem.indexOfScalarPos(u8, source, scheme_end, '/') orelse return .{ .repo_part = source, .ref = null };
        const path = source[path_start + 1 ..];
        const at = std.mem.indexOfScalar(u8, path, '@') orelse return .{ .repo_part = source, .ref = null };
        if (at == 0 or at + 1 >= path.len) return .{ .repo_part = source, .ref = null };
        return .{
            .repo_part = source[0 .. path_start + 1 + at],
            .ref = path[at + 1 ..],
        };
    }

    const slash = std.mem.indexOfScalar(u8, source, '/') orelse return .{ .repo_part = source, .ref = null };
    const path = source[slash + 1 ..];
    const at = std.mem.indexOfScalar(u8, path, '@') orelse return .{ .repo_part = source, .ref = null };
    if (at == 0 or at + 1 >= path.len) return .{ .repo_part = source, .ref = null };
    return .{
        .repo_part = source[0 .. slash + 1 + at],
        .ref = path[at + 1 ..],
    };
}

fn parseGitSource(allocator: std.mem.Allocator, source: []const u8) !?GitSourceInfo {
    const without_prefix = if (std.mem.startsWith(u8, source, "git:")) source["git:".len..] else source;
    if (!std.mem.startsWith(u8, source, "git:") and
        !(std.mem.startsWith(u8, without_prefix, "https://") or
            std.mem.startsWith(u8, without_prefix, "http://") or
            std.mem.startsWith(u8, without_prefix, "ssh://") or
            std.mem.startsWith(u8, without_prefix, "git://")))
    {
        return null;
    }

    const split = splitRef(without_prefix);
    const repo_part = split.repo_part;
    const ref_owned = if (split.ref) |value| try allocator.dupe(u8, value) else null;
    errdefer if (ref_owned) |value| allocator.free(value);

    var repo_owned: []u8 = undefined;
    var host_slice: []const u8 = undefined;
    var path_slice: []const u8 = undefined;

    if (std.mem.startsWith(u8, repo_part, "git@")) {
        const colon = std.mem.indexOfScalar(u8, repo_part, ':') orelse return null;
        host_slice = repo_part["git@".len..colon];
        path_slice = repo_part[colon + 1 ..];
        repo_owned = try allocator.dupe(u8, repo_part);
    } else if (std.mem.indexOf(u8, repo_part, "://")) |_| {
        const scheme_end = std.mem.indexOf(u8, repo_part, "://").? + "://".len;
        const path_start = std.mem.indexOfScalarPos(u8, repo_part, scheme_end, '/') orelse return null;
        host_slice = repo_part[scheme_end..path_start];
        if (std.mem.indexOfScalar(u8, host_slice, '@')) |at| host_slice = host_slice[at + 1 ..];
        path_slice = repo_part[path_start + 1 ..];
        repo_owned = try allocator.dupe(u8, repo_part);
    } else {
        const slash = std.mem.indexOfScalar(u8, repo_part, '/') orelse return null;
        host_slice = repo_part[0..slash];
        path_slice = repo_part[slash + 1 ..];
        if (std.mem.indexOfScalar(u8, host_slice, '.') == null and !std.mem.eql(u8, host_slice, "localhost")) return null;
        repo_owned = try std.fmt.allocPrint(allocator, "https://{s}", .{repo_part});
    }
    errdefer allocator.free(repo_owned);

    const normalized_path = trimGitSuffix(std.mem.trim(u8, path_slice, "/"));
    if (host_slice.len == 0 or normalized_path.len == 0 or std.mem.indexOfScalar(u8, normalized_path, '/') == null) return null;

    return .{
        .repo = repo_owned,
        .host = try allocator.dupe(u8, host_slice),
        .path = try allocator.dupe(u8, normalized_path),
        .ref = ref_owned,
    };
}

fn commandPrefix(options: ExecuteOptions, kind: PackageTool) []const []const u8 {
    return switch (kind) {
        .npm => options.npm_command_override orelse &.{"npm"},
        .git => options.git_command_override orelse &.{"git"},
    };
}

fn runExternalCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    prefix: []const []const u8,
    args: []const []const u8,
    cwd: ?[]const u8,
    stderr: *std.Io.Writer,
) !bool {
    var argv = try allocator.alloc([]const u8, prefix.len + args.len);
    defer allocator.free(argv);
    @memcpy(argv[0..prefix.len], prefix);
    @memcpy(argv[prefix.len..], args);

    var display: std.ArrayList(u8) = .empty;
    defer display.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try display.append(allocator, ' ');
        try display.appendSlice(allocator, arg);
    }

    const result = (if (cwd) |path|
        std.process.run(allocator, io, .{
            .argv = argv,
            .cwd = .{ .path = path },
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        })
    else
        std.process.run(allocator, io, .{
            .argv = argv,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        })) catch |err| {
        try stderr.print("Error: Failed to run {s}: {s}\n", .{ display.items, @errorName(err) });
        return false;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) return true;
            try stderr.print("Error: {s} exited with code {d}\n", .{ display.items, code });
            if (result.stderr.len > 0) try stderr.print("{s}", .{result.stderr});
            return false;
        },
        .signal => |signal| {
            try stderr.print("Error: {s} terminated by signal {d}\n", .{ display.items, signal });
            return false;
        },
        else => {
            try stderr.print("Error: {s} terminated abnormally\n", .{display.items});
            return false;
        },
    }
}

fn ensureNpmProject(allocator: std.mem.Allocator, io: std.Io, install_root: []const u8) !void {
    try std.Io.Dir.createDirPath(.cwd(), io, install_root);

    const gitignore_path = try std.fs.path.join(allocator, &.{ install_root, ".gitignore" });
    defer allocator.free(gitignore_path);
    const gitignore_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), io, gitignore_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (!gitignore_exists) try common.writeFileAbsolute(io, gitignore_path, "*\n!.gitignore\n", true);

    const package_json_path = try std.fs.path.join(allocator, &.{ install_root, "package.json" });
    defer allocator.free(package_json_path);
    const package_json_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), io, package_json_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (!package_json_exists) try common.writeFileAbsolute(io, package_json_path, "{\n  \"name\": \"pi-extensions\",\n  \"private\": true\n}\n", true);
}

fn npmInstallRoot(allocator: std.mem.Allocator, options: ExecuteOptions, is_project: bool) ![]u8 {
    if (is_project) return std.fs.path.join(allocator, &.{ options.cwd, ".pi", "packages", "npm" });
    return std.fs.path.join(allocator, &.{ options.agent_dir, "packages", "npm" });
}

fn executeNpmInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
    stderr: *std.Io.Writer,
) !bool {
    const spec = std.mem.trim(u8, source["npm:".len..], " ");
    const prefix = commandPrefix(options, .npm);
    const install_root = try npmInstallRoot(allocator, options, is_project);
    defer allocator.free(install_root);
    try ensureNpmProject(allocator, io, install_root);
    return runExternalCommand(allocator, io, prefix, &.{ "install", spec, "--prefix", install_root }, null, stderr);
}

fn executeNpmUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
    stderr: *std.Io.Writer,
) !bool {
    const spec = std.mem.trim(u8, source["npm:".len..], " ");
    const pkg_name = npmPackageName(spec);
    const latest_spec = try std.fmt.allocPrint(allocator, "{s}@latest", .{pkg_name});
    defer allocator.free(latest_spec);
    const prefix = commandPrefix(options, .npm);
    const install_root = try npmInstallRoot(allocator, options, is_project);
    defer allocator.free(install_root);
    try ensureNpmProject(allocator, io, install_root);
    return runExternalCommand(allocator, io, prefix, &.{ "install", latest_spec, "--prefix", install_root }, null, stderr);
}

fn gitInstallRoot(allocator: std.mem.Allocator, options: ExecuteOptions, is_project: bool) ![]u8 {
    if (is_project) return std.fs.path.join(allocator, &.{ options.cwd, ".pi", "packages", "git" });
    return std.fs.path.join(allocator, &.{ options.agent_dir, "packages", "git" });
}

fn gitInstallPath(allocator: std.mem.Allocator, options: ExecuteOptions, source: []const u8, is_project: bool) ![]u8 {
    const root = try gitInstallRoot(allocator, options, is_project);
    defer allocator.free(root);
    const normalized = std.mem.trim(u8, normalizeGitSource(source), " ");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(normalized, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const hex = try std.fmt.allocPrint(allocator, "{s}", .{digest_hex[0..]});
    defer allocator.free(hex);
    return std.fs.path.join(allocator, &.{ root, hex });
}

fn executeGitInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
    stderr: *std.Io.Writer,
) !bool {
    var info = (try parseGitSource(allocator, source)) orelse {
        try stderr.print("Error: Unsupported git source: {s}\n", .{source});
        return false;
    };
    defer info.deinit(allocator);

    const target_dir = try gitInstallPath(allocator, options, source, is_project);
    defer allocator.free(target_dir);
    const target_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), io, target_dir, .{}) catch break :blk false;
        break :blk true;
    };
    if (target_exists) return true;

    const root = try gitInstallRoot(allocator, options, is_project);
    defer allocator.free(root);
    try std.Io.Dir.createDirPath(.cwd(), io, root);
    const gitignore_path = try std.fs.path.join(allocator, &.{ root, ".gitignore" });
    defer allocator.free(gitignore_path);
    const gitignore_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), io, gitignore_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (!gitignore_exists) try common.writeFileAbsolute(io, gitignore_path, "*\n!.gitignore\n", true);

    const parent = std.fs.path.dirname(target_dir) orelse root;
    try std.Io.Dir.createDirPath(.cwd(), io, parent);
    const prefix = commandPrefix(options, .git);
    if (!try runExternalCommand(allocator, io, prefix, &.{ "clone", info.repo, target_dir }, null, stderr)) return false;
    if (info.ref) |ref| {
        if (!try runExternalCommand(allocator, io, prefix, &.{ "checkout", ref }, target_dir, stderr)) return false;
    }
    return true;
}

fn executeGitUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
    stderr: *std.Io.Writer,
) !bool {
    var info = (try parseGitSource(allocator, source)) orelse return true;
    defer info.deinit(allocator);
    if (info.ref != null) return true;

    const target_dir = try gitInstallPath(allocator, options, source, is_project);
    defer allocator.free(target_dir);
    const target_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), io, target_dir, .{}) catch break :blk false;
        break :blk true;
    };
    if (!target_exists) return executeGitInstall(allocator, io, source, is_project, options, stderr);

    const prefix = commandPrefix(options, .git);
    return runExternalCommand(allocator, io, prefix, &.{ "pull", "--ff-only" }, target_dir, stderr);
}

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

const SelfUpdatePlan = struct {
    package_name: []const u8,
    should_run: bool,
};

const SelfUpdateCommandStep = struct {
    argv: []const []const u8,
    display: []u8,

    fn deinit(self: *SelfUpdateCommandStep, allocator: std.mem.Allocator) void {
        allocator.free(self.argv);
        allocator.free(self.display);
        self.* = undefined;
    }
};

const SelfUpdateCommand = struct {
    steps: []SelfUpdateCommandStep,
    display: []u8,

    fn deinit(self: *SelfUpdateCommand, allocator: std.mem.Allocator) void {
        for (self.steps) |*step| step.deinit(allocator);
        allocator.free(self.steps);
        allocator.free(self.display);
        self.* = undefined;
    }
};

fn appendDisplayArg(allocator: std.mem.Allocator, output: *std.ArrayList(u8), arg: []const u8) !void {
    if (std.mem.indexOfAny(u8, arg, " \t\r\n") == null) {
        try output.appendSlice(allocator, arg);
        return;
    }
    try output.append(allocator, '"');
    try output.appendSlice(allocator, arg);
    try output.append(allocator, '"');
}

fn makeSelfUpdateCommandStep(
    allocator: std.mem.Allocator,
    prefix: []const []const u8,
    args: []const []const u8,
) !SelfUpdateCommandStep {
    var argv = try allocator.alloc([]const u8, prefix.len + args.len);
    errdefer allocator.free(argv);
    @memcpy(argv[0..prefix.len], prefix);
    @memcpy(argv[prefix.len..], args);

    var display_buf: std.ArrayList(u8) = .empty;
    errdefer display_buf.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try display_buf.append(allocator, ' ');
        try appendDisplayArg(allocator, &display_buf, arg);
    }

    return .{
        .argv = argv,
        .display = try display_buf.toOwnedSlice(allocator),
    };
}

fn appendSelfUpdateInstallStep(
    allocator: std.mem.Allocator,
    steps: *std.ArrayList(SelfUpdateCommandStep),
    method: SelfUpdatePackageManager,
    prefix: []const []const u8,
    update_package_name: []const u8,
) !void {
    const step = switch (method) {
        .npm => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "install", "-g", update_package_name }),
        .pnpm => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "install", "-g", update_package_name }),
        .yarn => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "global", "add", update_package_name }),
        .bun => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "install", "-g", update_package_name }),
    };
    try steps.append(allocator, step);
}

fn appendSelfUpdateUninstallStep(
    allocator: std.mem.Allocator,
    steps: *std.ArrayList(SelfUpdateCommandStep),
    method: SelfUpdatePackageManager,
    prefix: []const []const u8,
    installed_package_name: []const u8,
) !void {
    const step = switch (method) {
        .npm => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "uninstall", "-g", installed_package_name }),
        .pnpm => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "remove", "-g", installed_package_name }),
        .yarn => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "global", "remove", installed_package_name }),
        .bun => try makeSelfUpdateCommandStep(allocator, prefix, &.{ "uninstall", "-g", installed_package_name }),
    };
    try steps.append(allocator, step);
}

fn makeSelfUpdateCommand(
    allocator: std.mem.Allocator,
    method: SelfUpdatePackageManager,
    prefix: []const []const u8,
    update_package_name: []const u8,
) !SelfUpdateCommand {
    var steps: std.ArrayList(SelfUpdateCommandStep) = .empty;
    errdefer {
        for (steps.items) |*step| step.deinit(allocator);
        steps.deinit(allocator);
    }

    if (!std.mem.eql(u8, update_package_name, package_name)) {
        try appendSelfUpdateUninstallStep(allocator, &steps, method, prefix, package_name);
    }
    try appendSelfUpdateInstallStep(allocator, &steps, method, prefix, update_package_name);

    const owned_steps = try steps.toOwnedSlice(allocator);
    errdefer {
        for (owned_steps) |*step| step.deinit(allocator);
        allocator.free(owned_steps);
    }

    var display_buf: std.ArrayList(u8) = .empty;
    errdefer display_buf.deinit(allocator);
    for (owned_steps, 0..) |step, index| {
        if (index > 0) try display_buf.appendSlice(allocator, " && ");
        try display_buf.appendSlice(allocator, step.display);
    }

    return .{
        .steps = owned_steps,
        .display = try display_buf.toOwnedSlice(allocator),
    };
}

fn getSelfUpdatePlan(force: bool, options: ExecuteOptions) SelfUpdatePlan {
    if (force) {
        return .{ .package_name = package_name, .should_run = true };
    }

    if (options.self_update_latest_release_probe) |probe| {
        probe.* += 1;
    }

    const release = options.self_update_latest_release_override orelse
        return .{ .package_name = package_name, .should_run = true };
    const release_package_name = if (release.package_name) |name| blk: {
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        break :blk if (trimmed.len > 0) trimmed else package_name;
    } else package_name;

    if (!std.mem.eql(u8, release_package_name, package_name) or
        isNewerPackageVersion(release.version, options.current_version))
    {
        return .{ .package_name = release_package_name, .should_run = true };
    }

    return .{ .package_name = package_name, .should_run = false };
}

fn executeSelfUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    force: bool,
    options: ExecuteOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ExecuteResult {
    // Resolve argv: use test override when present. Without an override,
    // native Zig builds cannot safely prove the executable is managed by a
    // writable global package manager the way the TypeScript Node entrypoint
    // can, so surface the same user-facing unsupported diagnostic instead of
    // running an unsafe global install command.
    const command_prefix: []const []const u8 = if (options.self_update_command_override) |override| blk: {
        if (override.len == 0) {
            // Empty override means "no package manager found".
            try stderr.print(
                "error: pi cannot self-update this installation.\nRun: npm install -g {s}\n",
                .{package_name},
            );
            return .{ .exit_code = 1 };
        }
        break :blk override;
    } else {
        try stderr.print(
            "error: pi cannot self-update this installation.\nUpdate {s} using the package manager, wrapper, or source checkout that provides this installation.\n",
            .{package_name},
        );
        return .{ .exit_code = 1 };
    };

    const plan = getSelfUpdatePlan(force, options);
    if (!plan.should_run) {
        try stdout.print("pi is already up to date (v{s})\n", .{options.current_version});
        return .{ .exit_code = 0 };
    }

    var command = try makeSelfUpdateCommand(
        allocator,
        options.self_update_method_override,
        command_prefix,
        plan.package_name,
    );
    defer command.deinit(allocator);

    // Spawn the update command and collect output.
    for (command.steps) |step| {
        const result = std.process.run(allocator, io, .{
            .argv = step.argv,
        }) catch |err| {
            try stderr.print(
                "Error: Failed to spawn update command: {s}\nIf this keeps failing, run this command yourself: {s}\n",
                .{ @errorName(err), command.display },
            );
            return .{ .exit_code = 1 };
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| {
                if (code != 0) {
                    try stderr.print(
                        "Error: {s} exited with {d}\nIf this keeps failing, run this command yourself: {s}\n",
                        .{ step.display, code, command.display },
                    );
                    return .{ .exit_code = 1 };
                }
            },
            .signal => |sig| {
                try stderr.print(
                    "Error: {s} terminated by signal {d}\nIf this keeps failing, run this command yourself: {s}\n",
                    .{ step.display, sig, command.display },
                );
                return .{ .exit_code = 1 };
            },
            else => {
                try stderr.print(
                    "Error: {s} terminated abnormally\nIf this keeps failing, run this command yourself: {s}\n",
                    .{ step.display, command.display },
                );
                return .{ .exit_code = 1 };
            },
        }
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
            const redacted_source = try redactDiagnosticValue(allocator, entry.source);
            defer allocator.free(redacted_source);
            const redacted_installed_path = try redactDiagnosticValue(allocator, entry.installed_path);
            defer allocator.free(redacted_installed_path);
            if (entry.filtered) {
                try stdout.print("  {s} (filtered)\n", .{redacted_source});
            } else {
                try stdout.print("  {s}\n", .{redacted_source});
            }
            try stdout.print("    {s}\n", .{redacted_installed_path});
            try writeListEntryMetadata(allocator, stdout, entry);
        }
    }

    if (project_entries.items.len > 0) {
        if (user_entries.items.len > 0) try stdout.print("\n", .{});
        try stdout.print("Project packages:\n", .{});
        for (project_entries.items) |entry| {
            const redacted_source = try redactDiagnosticValue(allocator, entry.source);
            defer allocator.free(redacted_source);
            const redacted_installed_path = try redactDiagnosticValue(allocator, entry.installed_path);
            defer allocator.free(redacted_installed_path);
            if (entry.filtered) {
                try stdout.print("  {s} (filtered)\n", .{redacted_source});
            } else {
                try stdout.print("  {s}\n", .{redacted_source});
            }
            try stdout.print("    {s}\n", .{redacted_installed_path});
            try writeListEntryMetadata(allocator, stdout, entry);
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
            \\  pi update [source|self|pi] [--self] [--extensions] [--extension <source>] [--force]
            \\
            \\Update installed packages or self-update pi.
            \\
            \\  pi update                     Update all installed packages (offline no-op for local sources)
            \\  pi update self                Self-update pi via npm or bun
            \\  pi update pi                  Alias for pi update self
            \\  pi update <source>            Update a specific installed package
            \\  pi update --self              Self-update pi only
            \\  pi update --extensions        Update all extensions only (skip self-update)
            \\  pi update --extension <src>   Update a single extension by source
            \\  pi update --self --extensions Update both pi and all extensions
            \\
            \\Options:
            \\  --self                Self-update pi via npm or bun
            \\  --extensions          Update all installed extensions
            \\  --extension <source>  Update a single installed extension by source
            \\  --force               Skip version check, always run update
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
    return !isNpmSource(source) and !isGitSource(source);
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
        return resolveLocalPathFromScopeBase(allocator, source, is_project, cwd, agent_dir);
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
    if (try parseGitSource(allocator, source)) |info_value| {
        var info = info_value;
        defer info.deinit(allocator);
        const base = if (is_project)
            try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "packages", "git" })
        else
            try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "packages", "git" });
        defer allocator.free(base);
        const normalized = std.mem.trim(u8, normalizeGitSource(source), " ");
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(normalized, &digest, .{});
        const digest_hex = std.fmt.bytesToHex(digest, .lower);
        const hex = try std.fmt.allocPrint(allocator, "{s}", .{digest_hex[0..]});
        defer allocator.free(hex);
        return std.fs.path.join(allocator, &[_][]const u8{ base, hex });
    }
    return allocator.dupe(u8, source);
}

fn localBaseDirForScope(
    allocator: std.mem.Allocator,
    is_project: bool,
    cwd: []const u8,
    agent_dir: []const u8,
) ![]u8 {
    if (is_project) return std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi" });
    return allocator.dupe(u8, agent_dir);
}

fn expandHomePath(allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
    if (input.len == 0 or input[0] != '~') return null;
    if (input.len > 1 and input[1] != '/') return null;
    const home_ptr = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_ptr);
    if (input.len == 1) return try allocator.dupe(u8, home);
    return try std.fs.path.join(allocator, &[_][]const u8{ home, input[2..] });
}

fn resolveLocalPathFromCwd(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    source: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (try expandHomePath(allocator, trimmed)) |expanded| return expanded;
    if (std.fs.path.isAbsolute(trimmed)) return allocator.dupe(u8, trimmed);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, trimmed });
}

fn resolveLocalPathFromScopeBase(
    allocator: std.mem.Allocator,
    source: []const u8,
    is_project: bool,
    cwd: []const u8,
    agent_dir: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (try expandHomePath(allocator, trimmed)) |expanded| return expanded;
    if (std.fs.path.isAbsolute(trimmed)) return allocator.dupe(u8, trimmed);
    const base_dir = try localBaseDirForScope(allocator, is_project, cwd, agent_dir);
    defer allocator.free(base_dir);
    return std.fs.path.resolve(allocator, &[_][]const u8{ base_dir, trimmed });
}

fn normalizePackageSourceForSettings(
    allocator: std.mem.Allocator,
    source: []const u8,
    is_project: bool,
    cwd: []const u8,
    agent_dir: []const u8,
) ![]u8 {
    if (!isLocalSource(source)) return allocator.dupe(u8, source);

    const base_dir = try localBaseDirForScope(allocator, is_project, cwd, agent_dir);
    defer allocator.free(base_dir);
    const resolved = try resolveLocalPathFromCwd(allocator, cwd, source);
    defer allocator.free(resolved);
    const relative = try std.fs.path.relative(allocator, cwd, null, base_dir, resolved);
    if (relative.len == 0) {
        allocator.free(relative);
        return allocator.dupe(u8, ".");
    }
    return relative;
}

fn packageSourcesMatchForScope(
    allocator: std.mem.Allocator,
    configured_source: []const u8,
    input_source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
) !bool {
    if (std.mem.eql(u8, configured_source, input_source)) return true;
    if (isLocalSource(configured_source) and isLocalSource(input_source)) {
        const configured_path = try resolveLocalPathFromScopeBase(
            allocator,
            configured_source,
            is_project,
            options.cwd,
            options.agent_dir,
        );
        defer allocator.free(configured_path);
        const input_path = try resolveLocalPathFromCwd(allocator, options.cwd, input_source);
        defer allocator.free(input_path);
        const configured_identity = try realpathOrResolved(allocator, configured_path);
        defer allocator.free(configured_identity);
        const input_identity = try realpathOrResolved(allocator, input_path);
        defer allocator.free(input_identity);
        return std.mem.eql(u8, configured_identity, input_identity);
    }
    return false;
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
    wasm_metadata: ?WasmPackageListMetadata = null,

    fn deinit(self: *ListEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.installed_path);
        if (self.wasm_metadata) |*metadata| metadata.deinit(allocator);
        self.* = undefined;
    }
};

fn writeListEntryMetadata(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    entry: ListEntry,
) !void {
    const metadata = entry.wasm_metadata orelse return;
    const redacted_root = try redactDiagnosticValue(allocator, metadata.package_root);
    defer allocator.free(redacted_root);
    const redacted_artifact = try redactDiagnosticValue(allocator, metadata.artifact_absolute_path);
    defer allocator.free(redacted_artifact);
    const redacted_policy = try redactDiagnosticValue(allocator, metadata.policy_lookup_key);
    defer allocator.free(redacted_policy);
    try stdout.print("    scope: {s}\n", .{metadata.scope});
    try stdout.writeAll("    runtime: wasm\n");
    try stdout.print("    trust: {s}\n", .{metadata.trust_status});
    try stdout.print("    extension: {s}@{s}\n", .{ metadata.extension_id, metadata.extension_version });
    try stdout.print("    tool: {s}\n", .{metadata.tool_id});
    try stdout.print("    package root: {s}\n", .{redacted_root});
    try stdout.print("    artifact: {s}\n", .{redacted_artifact});
    try stdout.print("    package root sha256: {s}\n", .{metadata.package_root_sha256});
    try stdout.print("    artifact sha256: {s}\n", .{metadata.artifact_sha256});
    try stdout.print("    approval target: {s}\n", .{redacted_policy});
}

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
        var wasm_metadata = try loadWasmPackageListMetadata(allocator, io, options, source_str, is_project);
        errdefer if (wasm_metadata) |*metadata| metadata.deinit(allocator);

        try result.append(allocator, .{
            .source = source_owned,
            .installed_path = installed_path,
            .filtered = filtered,
            .wasm_metadata = wasm_metadata,
        });
    }
    return result;
}

fn loadWasmPackageListMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    source: []const u8,
    is_project: bool,
) !?WasmPackageListMetadata {
    if (!isLocalSource(source)) return null;
    const key = try localProvenanceKeyForSource(allocator, source, is_project, options, .settings);
    defer allocator.free(key);
    const lockfile_path = try provenance_lockfile.lockfilePath(allocator, provenanceScope(is_project), options.cwd, options.agent_dir);
    defer allocator.free(lockfile_path);
    var loaded = try provenance_lockfile.readLockfile(allocator, io, provenanceScope(is_project), lockfile_path, "list");
    defer loaded.deinit(allocator);
    if (loaded.diagnostic != null) return null;
    for (loaded.entries) |entry| {
        if (!std.mem.eql(u8, entry.key, key)) continue;
        if (entry.manifest_kind.len == 0 or !std.mem.eql(u8, entry.manifest_kind, "wasm-extension")) return null;
        const policy_key = try wasmPolicyLookupKeyFromLockEntry(allocator, entry);
        errdefer allocator.free(policy_key);
        const trust_status = try localWasmTrustStatusForList(allocator, io, options, source, is_project, entry);
        errdefer allocator.free(trust_status);
        return .{
            .extension_id = try allocator.dupe(u8, entry.manifest_id orelse "<unknown>"),
            .extension_version = try allocator.dupe(u8, entry.manifest_version orelse "<unknown>"),
            .tool_id = try allocator.dupe(u8, entry.manifest_tool_id orelse "<unknown>"),
            .package_root = try allocator.dupe(u8, entry.package_root),
            .artifact_absolute_path = try allocator.dupe(u8, entry.artifact_absolute_path orelse ""),
            .artifact_sha256 = try allocator.dupe(u8, entry.artifact_sha256 orelse ""),
            .package_root_sha256 = try allocator.dupe(u8, entry.package_root_sha256),
            .policy_lookup_key = policy_key,
            .scope = try allocator.dupe(u8, entry.scope.jsonName()),
            .trust_status = trust_status,
        };
    }
    return null;
}

fn localWasmTrustStatusForList(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    source: []const u8,
    is_project: bool,
    locked_entry: provenance_lockfile.LockEntry,
) ![]u8 {
    var current = try computeLocalWasmLockEntryNoDiagnostics(allocator, io, source, is_project, options, .settings);
    defer current.deinit(allocator);
    return switch (current) {
        .absent => allocator.dupe(u8, "locked"),
        .invalid => allocator.dupe(u8, "invalid"),
        .valid => |entry| if (provenance_lockfile.entriesEqual(locked_entry, entry))
            allocator.dupe(u8, "locked")
        else
            allocator.dupe(u8, "drifted"),
    };
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

fn findPackageIndex(
    allocator: std.mem.Allocator,
    array: std.json.Array,
    source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
) !?usize {
    for (array.items, 0..) |item, idx| {
        switch (item) {
            .string => |s| if (try packageSourcesMatchForScope(allocator, s, source, is_project, options)) return idx,
            .object => |obj| {
                if (obj.get("source")) |value| {
                    if (value == .string) {
                        if (try packageSourcesMatchForScope(allocator, value.string, source, is_project, options)) return idx;
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

fn packageSourceFromItem(allocator: std.mem.Allocator, item: std.json.Value) ![]u8 {
    return switch (item) {
        .string => |source| allocator.dupe(u8, source),
        .object => |object| blk: {
            const value = object.get("source") orelse return error.InvalidPackageSource;
            if (value != .string) return error.InvalidPackageSource;
            break :blk allocator.dupe(u8, value.string);
        },
        else => error.InvalidPackageSource,
    };
}

fn realpathOrResolved(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (@import("builtin").os.tag == .windows) {
        return std.fs.path.resolve(allocator, &.{path}) catch allocator.dupe(u8, path);
    }
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = std.c.realpath(z_path.ptr, &buffer) orelse return allocator.dupe(u8, path);
    return allocator.dupe(u8, std.mem.span(resolved));
}

fn localProvenanceKeyForSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
    mode: LocalPathMode,
) ![]u8 {
    const resolved = switch (mode) {
        .input => try resolveLocalPathFromCwd(allocator, options.cwd, source),
        .settings => try resolveLocalPathFromScopeBase(allocator, source, is_project, options.cwd, options.agent_dir),
    };
    defer allocator.free(resolved);
    const identity = try realpathOrResolved(allocator, resolved);
    defer allocator.free(identity);
    return std.fmt.allocPrint(allocator, "local:{s}", .{identity});
}

fn computeLocalWasmLockEntryNoDiagnostics(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
    mode: LocalPathMode,
) !LocalWasmInstallValidation {
    if (!isLocalSource(source)) return .absent;

    const package_root = switch (mode) {
        .input => try resolveLocalPathFromCwd(allocator, options.cwd, source),
        .settings => try resolveLocalPathFromScopeBase(allocator, source, is_project, options.cwd, options.agent_dir),
    };
    defer allocator.free(package_root);

    const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    _ = std.Io.Dir.statFile(.cwd(), io, manifest_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return err,
    };

    var result = try wasm_manifest.validateManifestFileWithOptions(allocator, io, package_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer result.deinit(allocator);
    if (result == .invalid) return .invalid;
    const source_identity = try allocator.dupe(u8, result.valid.package_root);
    defer allocator.free(source_identity);
    return .{ .valid = try provenance_lockfile.createWasmLockEntry(allocator, provenanceScope(is_project), source_identity, &result.valid) };
}

fn lockedLocalWasmEntryForSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
    mode: LocalPathMode,
    scope: ProvenanceScope,
    lockfile_path: []const u8,
) !?provenance_lockfile.LockEntry {
    if (!isLocalSource(source)) return null;
    const key = try localProvenanceKeyForSource(allocator, source, is_project, options, mode);
    defer allocator.free(key);
    var loaded = try provenance_lockfile.readLockfile(allocator, io, scope, lockfile_path, "install");
    defer loaded.deinit(allocator);
    if (loaded.diagnostic != null) return error.MalformedLockfile;
    for (loaded.entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return try entry.clone(allocator);
    }
    return null;
}

fn removeLocalWasmProvenanceForSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
    mode: LocalPathMode,
    lockfile_path: []const u8,
) !void {
    if (!isLocalSource(source)) return;
    const key = try localProvenanceKeyForSource(allocator, source, is_project, options, mode);
    defer allocator.free(key);
    _ = try removeProvenanceEntry(allocator, io, provenanceScope(is_project), lockfile_path, key, options);
}

fn writeSettingsObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    settings_path: []const u8,
    settings_object: std.json.ObjectMap,
    options: ExecuteOptions,
) !void {
    if (options.fail_settings_write_for_testing) return error.InjectedSettingsWriteFailure;
    try config_mod.validateExtensionPoliciesForSettingsWrite(allocator, settings_object, settings_path);
    const value: std.json.Value = .{ .object = settings_object };
    const serialized = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    try common.writeFileAbsolute(io, settings_path, serialized, true);
}

fn writeProvenanceEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    scope: ProvenanceScope,
    lockfile_path: []const u8,
    entry: provenance_lockfile.LockEntry,
    options: ExecuteOptions,
) !void {
    if (options.fail_lockfile_write_for_testing) return error.InjectedLockfileWriteFailure;
    try provenance_lockfile.writeEntry(allocator, io, scope, lockfile_path, entry);
}

fn removeProvenanceEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    scope: ProvenanceScope,
    lockfile_path: []const u8,
    key: []const u8,
    options: ExecuteOptions,
) !bool {
    if (options.fail_lockfile_write_for_testing) return error.InjectedLockfileWriteFailure;
    return try provenance_lockfile.removeEntry(allocator, io, scope, lockfile_path, key);
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

fn readOptionalTestFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn lockfilePathForTest(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    agent_dir: []const u8,
    is_project: bool,
) ![]u8 {
    if (is_project) return std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "extensions.lock.json" });
    return std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "extensions.lock.json" });
}

fn readFirstPackageSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const settings = try readSettings(allocator, path);
    defer allocator.free(settings);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, settings, .{});
    defer parsed.deinit();
    const packages = parsed.value.object.get("packages").?.array;
    const first = packages.items[0];
    return switch (first) {
        .string => |source| try allocator.dupe(u8, source),
        .object => |object| try allocator.dupe(u8, object.get("source").?.string),
        else => error.InvalidPackageSource,
    };
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

fn fakeNetworkOptions(cwd: []const u8, agent_dir: []const u8) ExecuteOptions {
    return .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .npm_command_override = &.{"/usr/bin/true"},
        .git_command_override = &.{"/usr/bin/true"},
        .self_update_command_override = &.{"/usr/bin/true"},
    };
}

fn makeSelfUpdateRecorderScript(
    allocator: std.mem.Allocator,
    log_path: []const u8,
    fail_install: bool,
) ![]u8 {
    if (fail_install) {
        return std.fmt.allocPrint(
            allocator,
            "printf '%s %s\\n' \"$0\" \"$*\" >> \"{s}\"; if [ \"$0\" = install ]; then exit 7; fi",
            .{log_path},
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "printf '%s %s\\n' \"$0\" \"$*\" >> \"{s}\"",
        .{log_path},
    );
}

fn readSelfUpdateLog(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(1024 * 1024));
}

fn writeWasmPackageFixture(
    tmp: anytype,
    package_relative_path: []const u8,
    capability: []const u8,
    write_artifact: bool,
) !void {
    const wasm_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ package_relative_path, "wasm" });
    defer std.testing.allocator.free(wasm_dir);
    try tmp.dir.createDirPath(std.testing.io, wasm_dir);
    if (write_artifact) {
        const artifact_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ package_relative_path, "wasm/example-tool.wasm" });
        defer std.testing.allocator.free(artifact_path);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = artifact_path, .data = "\x00asm" });
    }
    const manifest_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ package_relative_path, wasm_manifest.MANIFEST_FILE_NAME });
    defer std.testing.allocator.free(manifest_path);
    const manifest = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "schemaVersion": "pi-extension.v0",
        \\  "id": "com.example.policy",
        \\  "name": "Policy Example",
        \\  "version": "0.1.0",
        \\  "description": "Policy fixture.",
        \\  "artifact": {{ "kind": "wasm-component", "path": "wasm/example-tool.wasm" }},
        \\  "tool": {{
        \\    "id": "example.policy",
        \\    "description": "Policy tool.",
        \\    "inputSchema": {{}},
        \\    "outputSchema": {{}}
        \\  }},
        \\  "capabilities": ["{s}"]
        \\}}
    , .{capability});
    defer std.testing.allocator.free(manifest);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = manifest });
}

fn writePolicySettings(
    allocator: std.mem.Allocator,
    settings_path: []const u8,
    policy_key: []const u8,
    approved_grant: []const u8,
    include_resource_limits: bool,
) !void {
    const grants_json = try std.fmt.allocPrint(allocator, "\"{s}\"", .{approved_grant});
    defer allocator.free(grants_json);
    try writePolicySettingsGrantList(allocator, settings_path, policy_key, grants_json, include_resource_limits);
}

fn writePolicySettingsGrantList(
    allocator: std.mem.Allocator,
    settings_path: []const u8,
    policy_key: []const u8,
    approved_grants_json: []const u8,
    include_resource_limits: bool,
) !void {
    const quoted_key = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = policy_key }, .{});
    defer allocator.free(quoted_key);
    const resource_limits = if (include_resource_limits) ", \"resourceLimits\": { \"timeoutMs\": 1000 }" else "";
    const settings = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "extensionPolicies": {{
        \\    {s}: {{ "approvedGrants": [{s}]{s} }}
        \\  }}
        \\}}
    , .{ quoted_key, approved_grants_json, resource_limits });
    defer allocator.free(settings);
    try common.writeFileAbsolute(std.testing.io, settings_path, settings, true);
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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const expected_source = try normalizePackageSourceForSettings(allocator, "./fixtures/pkg", false, cwd, agent_dir);
    defer allocator.free(expected_source);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"packages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings, expected_source) != null);
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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const expected_source = try normalizePackageSourceForSettings(allocator, "./fixtures/pkg", true, cwd, agent_dir);
    defer allocator.free(expected_source);
    try std.testing.expect(std.mem.indexOf(u8, project_settings, expected_source) != null);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const expected_user_source = try normalizePackageSourceForSettings(allocator, "./fixtures/user-pkg", false, cwd, agent_dir);
    defer allocator.free(expected_user_source);
    const expected_project_source = try normalizePackageSourceForSettings(allocator, "./fixtures/project-pkg", true, cwd, agent_dir);
    defer allocator.free(expected_project_source);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "User packages:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, expected_user_source) != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Project packages:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, expected_project_source) != null);
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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    try std.testing.expectEqualStrings("Removed ./fixtures/pkg\n  scope: user\n", stdout_buf.items);

    const updated = try readSettings(allocator, settings_path);
    defer allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "./fixtures/pkg") == null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "\"defaultProvider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "\"openai\"") != null);
}

test "settings writes preserve valid extensionPolicies and reject malformed policies" {
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
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-a.ts": {
        \\      "approvedGrants": ["agent.delegate"],
        \\      "resourceLimits": { "outputLines": 4 }
        \\    }
        \\  }
        \\}
    , true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/pkg" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const valid_updated = try readSettings(allocator, settings_path);
    defer allocator.free(valid_updated);
    try std.testing.expect(std.mem.indexOf(u8, valid_updated, "\"extensionPolicies\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, valid_updated, "\"agent.delegate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, valid_updated, "\"outputLines\"") != null);
    const expected_source = try normalizePackageSourceForSettings(allocator, "./fixtures/pkg", false, cwd, agent_dir);
    defer allocator.free(expected_source);
    try std.testing.expect(std.mem.indexOf(u8, valid_updated, expected_source) != null);

    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-a.ts": { "approvedGrants": ["network"] }
        \\  }
        \\}
    , true);
    const before_invalid_write = try readSettings(allocator, settings_path);
    defer allocator.free(before_invalid_write);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    try std.testing.expectError(
        error.InvalidExtensionPolicies,
        runCommand(allocator, &.{ "install", "./fixtures/pkg-b" }, options, &stdout_buf, &stderr_buf),
    );

    const after_invalid_write = try readSettings(allocator, settings_path);
    defer allocator.free(after_invalid_write);
    try std.testing.expectEqualStrings(before_invalid_write, after_invalid_write);
}

test "wasm package install preserves default-deny without approved grants" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-denied", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-denied" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", stderr_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Installed ./fixtures/wasm-denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "extension: com.example.policy@0.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "tool: example.policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "runtime: wasm") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "trust: locked") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "approval target: wasm:") != null);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    try std.testing.expect(std.mem.indexOf(u8, settings, "wasm-denied") != null);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const list_result = try runCommand(allocator, &.{"list"}, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), list_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "runtime: wasm") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "scope: user") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "trust: locked") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "approval target: wasm:") != null);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const reinstall_result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-denied" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), reinstall_result.exit_code);
    try std.testing.expectEqualStrings("", stderr_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Already installed: ./fixtures/wasm-denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "approval target: wasm:") != null);

    const settings_after_reinstall = try readSettings(allocator, settings_path);
    defer allocator.free(settings_after_reinstall);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, settings_after_reinstall, "\"source\""));
    const lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(lockfile_path);
    const lockfile = try readSettings(allocator, lockfile_path);
    defer allocator.free(lockfile);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, lockfile, "\"key\""));
}

test "VAL-PKG-009-014-015-017 local wasm update is explicit and list is read-only after drift" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-update", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .self_update_command_override = &.{"/usr/bin/true"},
    };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const install_result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-update" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), install_result.exit_code);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    const lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(lockfile_path);
    const lock_before_drift = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_before_drift);

    const artifact_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-update/wasm/example-tool.wasm" });
    defer allocator.free(artifact_path);
    try common.writeFileAbsolute(std.testing.io, artifact_path, "\x00asmUPDATED", true);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const list_result = try runCommand(allocator, &.{"list"}, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), list_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "trust: drifted") != null);
    const lock_after_list = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after_list);
    try std.testing.expectEqualStrings(lock_before_drift, lock_after_list);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const reinstall_result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-update" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), reinstall_result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "already installed") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "pi update --extension") != null);
    const lock_after_reinstall = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after_reinstall);
    try std.testing.expectEqualStrings(lock_before_drift, lock_after_reinstall);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const update_result = try runCommand(allocator, &.{ "update", "--extension", "./fixtures/wasm-update" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), update_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Updated ./fixtures/wasm-update") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    const lock_after_update = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after_update);
    try std.testing.expect(!std.mem.eql(u8, lock_before_drift, lock_after_update));
}

test "VAL-PKG-010 failed local wasm update preserves previous trusted provenance" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-failed-update", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const install_result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-failed-update" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), install_result.exit_code);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings_before = try readSettings(allocator, settings_path);
    defer allocator.free(settings_before);
    const lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(lockfile_path);
    const lock_before = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_before);

    const artifact_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-failed-update/wasm/example-tool.wasm" });
    defer allocator.free(artifact_path);
    try std.Io.Dir.deleteFileAbsolute(std.testing.io, artifact_path);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const update_result = try runCommand(allocator, &.{ "update", "./fixtures/wasm-failed-update" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), update_result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "artifact file was not found") != null);

    const settings_after = try readSettings(allocator, settings_path);
    defer allocator.free(settings_after);
    const lock_after = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after);
    try std.testing.expectEqualStrings(settings_before, settings_after);
    try std.testing.expectEqualStrings(lock_before, lock_after);
}

test "VAL-PKG-019 batch local wasm update failure rolls back earlier refreshed provenance" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-batch-a", "file.read", true);
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-batch-b", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    _ = try runCommand(allocator, &.{ "install", "./fixtures/wasm-batch-a" }, options, &stdout_buf, &stderr_buf);
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    _ = try runCommand(allocator, &.{ "install", "./fixtures/wasm-batch-b" }, options, &stdout_buf, &stderr_buf);

    const lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(lockfile_path);
    const lock_before = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_before);

    const artifact_a = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-batch-a/wasm/example-tool.wasm" });
    defer allocator.free(artifact_a);
    try common.writeFileAbsolute(std.testing.io, artifact_a, "\x00asmUPDATED-A", true);
    const artifact_b = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-batch-b/wasm/example-tool.wasm" });
    defer allocator.free(artifact_b);
    try std.Io.Dir.deleteFileAbsolute(std.testing.io, artifact_b);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const update_result = try runCommand(allocator, &.{ "update", "--extensions" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), update_result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "wasm-batch-b") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "artifact file was not found") != null);

    const lock_after = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after);
    try std.testing.expectEqualStrings(lock_before, lock_after);
}

test "wasm package install honors pre-artifact manifest approved grants" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-pre", "file.read", false);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-pre" });
    defer allocator.free(package_root);
    const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    const policy_key = try policy_key_mod.wasmManifestPolicyLookupKey(allocator, .{
        .schema_version = wasm_manifest.SCHEMA_VERSION,
        .id = "com.example.policy",
        .version = "0.1.0",
        .package_root = package_root,
        .manifest_path = manifest_path,
        .artifact_path = "wasm/example-tool.wasm",
    });
    defer allocator.free(policy_key);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try writePolicySettings(allocator, settings_path, policy_key, "file.read", false);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-pre" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "artifact file was not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "denied_capability") == null);

    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"packages\"") == null);
}

test "wasm package install rejects unsupported native dynamic artifacts without state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/native-dynamic/bin");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/native-dynamic/bin/plugin.dylib",
        .data = "native",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/native-dynamic/pi-extension.json",
        .data =
        \\{
        \\  "schemaVersion": "pi-extension.v0",
        \\  "id": "com.example.native-dynamic",
        \\  "name": "Native Dynamic",
        \\  "version": "0.1.0",
        \\  "description": "Unsupported native package.",
        \\  "artifact": { "kind": "native-dylib", "path": "bin/plugin.dylib" },
        \\  "tool": {
        \\    "id": "example.native",
        \\    "description": "Unsupported native tool.",
        \\    "inputSchema": {},
        \\    "outputSchema": {}
        \\  },
        \\  "capabilities": []
        \\}
        ,
    });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/native-dynamic" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "unsupported artifact kind") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "native-dylib") != null);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), std.testing.io, settings_path, .{}));
    const lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(lockfile_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), std.testing.io, lockfile_path, .{}));
}

test "VAL-TRUST invalid wasm manifest diagnostics are redacted and leave no trust state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/pi-secret-invalid");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/pi-secret-invalid/pi-extension.json",
        .data =
        \\{
        \\  "schemaVersion": "pi-extension.v0?token=pi-test-secret",
        \\  "id": "com.example.invalid",
        \\  "name": "Invalid",
        \\  "version": "0.1.0",
        \\  "description": "Invalid secret-bearing manifest.",
        \\  "artifact": { "kind": "wasm-component", "path": "wasm/plugin.wasm" },
        \\  "tool": {
        \\    "id": "example.invalid",
        \\    "description": "Invalid tool.",
        \\    "inputSchema": {},
        \\    "outputSchema": {}
        \\  },
        \\  "capabilities": []
        \\}
        ,
    });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/pi-secret-invalid" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "unsupported schema version") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "token=[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "pi-test-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "Installed") == null);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), std.testing.io, settings_path, .{}));
    const lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(lockfile_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), std.testing.io, lockfile_path, .{}));
}

test "VAL-TRUST path aliases share canonical same-scope identity without crossing scopes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-canonical", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    const real_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-canonical" });
    defer allocator.free(real_root);
    const alias_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-canonical-alias" });
    defer allocator.free(alias_root);
    try std.Io.Dir.symLinkAbsolute(std.testing.io, real_root, alias_root, .{});

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const install_real = try runCommand(allocator, &.{ "install", "./fixtures/wasm-canonical" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), install_real.exit_code);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const install_alias_same_scope = try runCommand(allocator, &.{ "install", "./fixtures/wasm-canonical-alias" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), install_alias_same_scope.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Already installed") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    const user_settings = try readSettings(allocator, user_settings_path);
    defer allocator.free(user_settings);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, user_settings, "\"source\""));
    const user_lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(user_lockfile_path);
    const user_lockfile = try readSettings(allocator, user_lockfile_path);
    defer allocator.free(user_lockfile);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, user_lockfile, "\"key\""));

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const install_alias_project_scope = try runCommand(allocator, &.{ "install", "./fixtures/wasm-canonical-alias", "-l" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), install_alias_project_scope.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Installed") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "scope: project") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    const project_settings = try readSettings(allocator, project_settings_path);
    defer allocator.free(project_settings);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, project_settings, "\"source\""));
    const project_lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, true);
    defer allocator.free(project_lockfile_path);
    const project_lockfile = try readSettings(allocator, project_lockfile_path);
    defer allocator.free(project_lockfile);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, project_lockfile, "\"key\""));
}

test "VAL-TRUST lifecycle write failures preserve settings and provenance atomically" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-atomic-a", "file.read", true);
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-atomic-b", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const install_a = try runCommand(allocator, &.{ "install", "./fixtures/wasm-atomic-a" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), install_a.exit_code);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(lockfile_path);
    const settings_before_failed_install = try readSettings(allocator, settings_path);
    defer allocator.free(settings_before_failed_install);
    const lock_before_failed_install = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_before_failed_install);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    var fail_settings_options = options;
    fail_settings_options.fail_settings_write_for_testing = true;
    try std.testing.expectError(
        error.InjectedSettingsWriteFailure,
        runCommand(allocator, &.{ "install", "./fixtures/wasm-atomic-b" }, fail_settings_options, &stdout_buf, &stderr_buf),
    );
    const settings_after_failed_install = try readSettings(allocator, settings_path);
    defer allocator.free(settings_after_failed_install);
    const lock_after_failed_install = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after_failed_install);
    try std.testing.expectEqualStrings(settings_before_failed_install, settings_after_failed_install);
    try std.testing.expectEqualStrings(lock_before_failed_install, lock_after_failed_install);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    var fail_lock_options = options;
    fail_lock_options.fail_lockfile_write_for_testing = true;
    const failed_remove = try runCommand(allocator, &.{ "remove", "./fixtures/wasm-atomic-a" }, fail_lock_options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), failed_remove.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "InjectedLockfileWriteFailure") != null);
    const settings_after_failed_remove = try readSettings(allocator, settings_path);
    defer allocator.free(settings_after_failed_remove);
    const lock_after_failed_remove = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after_failed_remove);
    try std.testing.expectEqualStrings(settings_before_failed_install, settings_after_failed_remove);
    try std.testing.expectEqualStrings(lock_before_failed_install, lock_after_failed_remove);
}

test "wasm package install honors final artifact approved grants" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-final", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-final" });
    defer allocator.free(package_root);
    var manifest_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, package_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const final_key = try policy_key_mod.wasmPolicyLookupKey(allocator, extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid));
    defer allocator.free(final_key);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try writePolicySettings(allocator, settings_path, final_key, "file.read", false);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-final" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Installed ./fixtures/wasm-final") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "approval target: wasm:") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    const expected_source = try normalizePackageSourceForSettings(allocator, "./fixtures/wasm-final", false, cwd, agent_dir);
    defer allocator.free(expected_source);
    try std.testing.expect(std.mem.indexOf(u8, settings, expected_source) != null);
}

test "VAL-INSTALL-001 successful wasm install writes provenance lock before settings trust" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-lock", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-lock" });
    defer allocator.free(package_root);
    var manifest_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, package_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const final_key = try policy_key_mod.wasmPolicyLookupKey(allocator, extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid));
    defer allocator.free(final_key);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try writePolicySettings(allocator, settings_path, final_key, "file.read", false);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-lock" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(lockfile_path);
    const lockfile = try readSettings(allocator, lockfile_path);
    defer allocator.free(lockfile);
    try std.testing.expect(std.mem.indexOf(u8, lockfile, "\"schemaVersion\": \"pi-extension-lock.v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lockfile, "\"kind\": \"wasm-extension\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lockfile, "\"artifact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lockfile, manifest_result.valid.artifact_sha256) != null);
    try std.testing.expect(std.mem.indexOf(u8, lockfile, manifest_result.valid.package_root_sha256) != null);
    try std.testing.expect(std.mem.indexOf(u8, lockfile, "\"scope\": \"user\"") != null);
}

test "VAL-INSTALL-009 remove deletes matching wasm provenance lock entry" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-remove", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-remove" });
    defer allocator.free(package_root);
    var manifest_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, package_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer manifest_result.deinit(allocator);
    const final_key = try policy_key_mod.wasmPolicyLookupKey(allocator, extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid));
    defer allocator.free(final_key);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try writePolicySettings(allocator, settings_path, final_key, "file.read", false);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    _ = try runCommand(allocator, &.{ "install", "./fixtures/wasm-remove" }, options, &stdout_buf, &stderr_buf);
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();

    const remove_result = try runCommand(allocator, &.{ "remove", "./fixtures/wasm-remove" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), remove_result.exit_code);

    const lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(lockfile_path);
    const lockfile = try readOptionalTestFile(allocator, lockfile_path);
    defer if (lockfile) |bytes| allocator.free(bytes);
    if (lockfile) |bytes| {
        try std.testing.expect(std.mem.indexOf(u8, bytes, "wasm-remove") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, manifest_result.valid.artifact_sha256) == null);
    }
}

test "VAL-PKG-011-012-013-020 wasm remove is scoped, preserves collateral, and diagnostics are read-only" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-shared", "file.read", true);
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-other", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    _ = try runCommand(allocator, &.{ "install", "./fixtures/wasm-shared" }, options, &stdout_buf, &stderr_buf);
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    _ = try runCommand(allocator, &.{ "install", "./fixtures/wasm-shared", "-l" }, options, &stdout_buf, &stderr_buf);
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    _ = try runCommand(allocator, &.{ "install", "./fixtures/wasm-other" }, options, &stdout_buf, &stderr_buf);
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();

    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    const user_lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(user_lockfile_path);
    const project_lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, true);
    defer allocator.free(project_lockfile_path);

    const remove_user = try runCommand(allocator, &.{ "remove", "./fixtures/wasm-shared" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), remove_user.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Removed ./fixtures/wasm-shared") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "scope: user") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    const user_settings_after_remove = try readSettings(allocator, user_settings_path);
    defer allocator.free(user_settings_after_remove);
    try std.testing.expect(std.mem.indexOf(u8, user_settings_after_remove, "wasm-shared") == null);
    try std.testing.expect(std.mem.indexOf(u8, user_settings_after_remove, "wasm-other") != null);

    const project_settings_after_remove = try readSettings(allocator, project_settings_path);
    defer allocator.free(project_settings_after_remove);
    try std.testing.expect(std.mem.indexOf(u8, project_settings_after_remove, "wasm-shared") != null);

    const user_lock_after_remove = try readSettings(allocator, user_lockfile_path);
    defer allocator.free(user_lock_after_remove);
    try std.testing.expect(std.mem.indexOf(u8, user_lock_after_remove, "wasm-shared") == null);
    try std.testing.expect(std.mem.indexOf(u8, user_lock_after_remove, "wasm-other") != null);
    const project_lock_after_remove = try readSettings(allocator, project_lockfile_path);
    defer allocator.free(project_lock_after_remove);
    try std.testing.expect(std.mem.indexOf(u8, project_lock_after_remove, "wasm-shared") != null);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const list_result = try runCommand(allocator, &.{"list"}, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), list_result.exit_code);
    const user_header = std.mem.indexOf(u8, stdout_buf.items, "User packages:") orelse return error.ExpectedUserPackagesHeader;
    const project_header = std.mem.indexOf(u8, stdout_buf.items, "Project packages:") orelse return error.ExpectedProjectPackagesHeader;
    try std.testing.expect(user_header < project_header);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items[user_header..project_header], "wasm-other") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items[project_header..], "wasm-shared") != null);

    const user_settings_before_diagnostic = try readSettings(allocator, user_settings_path);
    defer allocator.free(user_settings_before_diagnostic);
    const user_lock_before_diagnostic = try readSettings(allocator, user_lockfile_path);
    defer allocator.free(user_lock_before_diagnostic);
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const first_missing = try runCommand(allocator, &.{ "remove", "./fixtures/wasm-shared" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), first_missing.exit_code);
    const first_missing_stderr = try allocator.dupe(u8, stderr_buf.items);
    defer allocator.free(first_missing_stderr);
    try std.testing.expect(std.mem.indexOf(u8, first_missing_stderr, "No matching package found") != null);
    const user_settings_after_diagnostic = try readSettings(allocator, user_settings_path);
    defer allocator.free(user_settings_after_diagnostic);
    const user_lock_after_diagnostic = try readSettings(allocator, user_lockfile_path);
    defer allocator.free(user_lock_after_diagnostic);
    try std.testing.expectEqualStrings(user_settings_before_diagnostic, user_settings_after_diagnostic);
    try std.testing.expectEqualStrings(user_lock_before_diagnostic, user_lock_after_diagnostic);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const second_missing = try runCommand(allocator, &.{ "remove", "./fixtures/wasm-shared" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), second_missing.exit_code);
    try std.testing.expectEqualStrings(first_missing_stderr, stderr_buf.items);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const remove_project = try runCommand(allocator, &.{ "remove", "./fixtures/wasm-shared", "-l" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), remove_project.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "scope: project") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    const user_settings_after_project_remove = try readSettings(allocator, user_settings_path);
    defer allocator.free(user_settings_after_project_remove);
    try std.testing.expect(std.mem.indexOf(u8, user_settings_after_project_remove, "wasm-other") != null);
    const project_lock_after_project_remove = try readSettings(allocator, project_lockfile_path);
    defer allocator.free(project_lock_after_project_remove);
    try std.testing.expect(std.mem.indexOf(u8, project_lock_after_project_remove, "wasm-shared") == null);
}

test "wasm project install ignores unrelated malformed global policy" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-invalid-policy", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-invalid-policy" });
    defer allocator.free(package_root);
    var manifest_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, package_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const final_key = try policy_key_mod.wasmPolicyLookupKey(allocator, extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid));
    defer allocator.free(final_key);
    const quoted_key = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = final_key }, .{});
    defer allocator.free(quoted_key);
    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    const settings = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "extensionPolicies": {{
        \\    {s}: {{
        \\      "approvedGrants": ["file.read"],
        \\      "resourceLimits": {{ "timeoutMs": 9007199254740992 }}
        \\    }}
        \\  }}
        \\}}
    , .{quoted_key});
    defer allocator.free(settings);
    try common.writeFileAbsolute(std.testing.io, user_settings_path, settings, true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-invalid-policy", "-l" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Installed ./fixtures/wasm-invalid-policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "scope: project") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    const project_settings_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), std.testing.io, project_settings_path, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(project_settings_exists);
    const project_settings = try readSettings(allocator, project_settings_path);
    defer allocator.free(project_settings);
    try std.testing.expect(std.mem.indexOf(u8, project_settings, "wasm-invalid-policy") != null);
}

test "wasm project install uses effective global pre-artifact approved grants" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-merged-pre", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-merged-pre" });
    defer allocator.free(package_root);
    const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    const policy_key = try policy_key_mod.wasmManifestPolicyLookupKey(allocator, .{
        .schema_version = wasm_manifest.SCHEMA_VERSION,
        .id = "com.example.policy",
        .version = "0.1.0",
        .package_root = package_root,
        .manifest_path = manifest_path,
        .artifact_path = "wasm/example-tool.wasm",
    });
    defer allocator.free(policy_key);
    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    try writePolicySettings(allocator, user_settings_path, policy_key, "file.read", false);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-merged-pre", "-l" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Installed ./fixtures/wasm-merged-pre") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "approval target: wasm:") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    const project_settings = try readSettings(allocator, project_settings_path);
    defer allocator.free(project_settings);
    const expected_source = try normalizePackageSourceForSettings(allocator, "./fixtures/wasm-merged-pre", true, cwd, agent_dir);
    defer allocator.free(expected_source);
    try std.testing.expect(std.mem.indexOf(u8, project_settings, expected_source) != null);
}

test "wasm project install uses effective global final artifact approved grants" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-merged-final", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-merged-final" });
    defer allocator.free(package_root);
    var manifest_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, package_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const final_key = try policy_key_mod.wasmPolicyLookupKey(allocator, extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid));
    defer allocator.free(final_key);
    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    try writePolicySettings(allocator, user_settings_path, final_key, "file.read", false);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-merged-final", "-l" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Installed ./fixtures/wasm-merged-final") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "approval target: wasm:") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);
}

test "wasm project install persists pre-artifact package despite unapproved policy" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-merged-pre-denied", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-merged-pre-denied" });
    defer allocator.free(package_root);
    const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    const policy_key = try policy_key_mod.wasmManifestPolicyLookupKey(allocator, .{
        .schema_version = wasm_manifest.SCHEMA_VERSION,
        .id = "com.example.policy",
        .version = "0.1.0",
        .package_root = package_root,
        .manifest_path = manifest_path,
        .artifact_path = "wasm/example-tool.wasm",
    });
    defer allocator.free(policy_key);
    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    try writePolicySettings(allocator, user_settings_path, policy_key, "file.read", false);
    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    try writePolicySettings(allocator, project_settings_path, policy_key, "file.write", false);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-merged-pre-denied", "-l" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "denied_capability") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "file.read") != null);
}

test "wasm project install persists final package despite unapproved policy" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-merged-final-denied", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-merged-final-denied" });
    defer allocator.free(package_root);
    var manifest_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, package_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const final_key = try policy_key_mod.wasmPolicyLookupKey(allocator, extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid));
    defer allocator.free(final_key);
    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    try writePolicySettings(allocator, user_settings_path, final_key, "file.read", false);
    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    try writePolicySettingsGrantList(allocator, project_settings_path, final_key, "", false);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-merged-final-denied", "-l" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "denied_capability") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "file.read") != null);
}

test "wasm package install reports approval target without treating sibling grants as approval" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-sibling", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-sibling" });
    defer allocator.free(package_root);
    const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    const policy_key = try policy_key_mod.wasmManifestPolicyLookupKey(allocator, .{
        .schema_version = wasm_manifest.SCHEMA_VERSION,
        .id = "com.example.policy",
        .version = "0.1.0",
        .package_root = package_root,
        .manifest_path = manifest_path,
        .artifact_path = "wasm/example-tool.wasm",
    });
    defer allocator.free(policy_key);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try writePolicySettings(allocator, settings_path, policy_key, "file.write", true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-sibling" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "denied_capability") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "file.read") != null);
}

test "unified package install validates manifest graph before load" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/provider");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/consumer");

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/provider/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"provider.pkg\",\"name\":\"Provider\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"index.ts\"},\"capabilities\":{\"exports\":[{\"id\":\"cap.install\",\"kind\":\"tool\",\"version\":\"1.0.0\"}]}}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/provider/index.ts",
        .data = "export default {};",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/consumer/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"consumer.pkg\",\"name\":\"Consumer\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"index.ts\"},\"capabilities\":{\"imports\":[{\"id\":\"cap.install\",\"kind\":\"tool\",\"version\":\"^1.0.0\"}]}}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/consumer/index.ts",
        .data = "export default {};",
    });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const missing_result = try runCommand(allocator, &.{ "install", "./fixtures/consumer" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), missing_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "graph.missing_capability_import") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "install rejected ./fixtures/consumer before load") != null);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const provider_result = try runCommand(allocator, &.{ "install", "./fixtures/provider" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), provider_result.exit_code);
    try std.testing.expectEqualStrings("Installed ./fixtures/provider\n", stdout_buf.items);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const consumer_result = try runCommand(allocator, &.{ "install", "./fixtures/consumer" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), consumer_result.exit_code);
    try std.testing.expectEqualStrings("Installed ./fixtures/consumer\n", stdout_buf.items);
    try std.testing.expectEqualStrings("", stderr_buf.items);
}

test "cross-runtime local packages install and reload from startup manifests" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/process");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/wasm");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/native");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/workflow");

    const process_manifest =
        \\{"schemaVersion":"pi-extension.v1","id":"process.pkg","name":"Process Runtime Package","version":"1.0.0","runtime":{"kind":"process_jsonl","entrypoint":{"argv":["python3","-u","index.py"]}},"tools":[{"name":"process.echo","description":"Process echo","inputSchema":{"type":"object"}}],"hooks":[{"event":"input","hookId":"process.input","priority":-30,"declarationOrder":0}],"capabilities":{"exports":[{"id":"process.echo","kind":"tool","version":"1.0.0"}]}}
    ;
    const wasm_manifest_text =
        \\{"schemaVersion":"pi-extension.v1","id":"wasm.pkg","name":"WASM Runtime Package","version":"1.0.0","runtime":{"kind":"wasm","entrypoint":{"artifactPath":"wasm/plugin.wasm"}},"dependencies":[{"id":"process.pkg","version":"^1.0.0"}],"tools":[{"name":"builtin.truncateHead","description":"WASM truncate","inputSchema":{"type":"object"}}],"hooks":[{"event":"input","hookId":"wasm.input","priority":-20,"declarationOrder":0}],"capabilities":{"exports":[{"id":"builtin.truncateHead","kind":"tool","version":"1.0.0"}]}}
    ;
    const native_manifest_text =
        \\{"schemaVersion":"pi-extension.v1","id":"native.pkg","name":"Native Runtime Package","version":"1.0.0","runtime":{"kind":"native","entrypoint":{"descriptor":"native_static_descriptor"}},"dependencies":[{"id":"wasm.pkg","version":"^1.0.0"}],"tools":[{"name":"native.fixture.echo","description":"Native echo","inputSchema":{"type":"object"}}],"hooks":[{"event":"input","hookId":"native.input","priority":-10,"declarationOrder":0}],"capabilities":{"exports":[{"id":"native.fixture.echo","kind":"tool","version":"1.0.0"}]}}
    ;
    const workflow_manifest_text =
        \\{"schemaVersion":"pi-extension.v1","id":"workflow.pkg","name":"Workflow Package","version":"1.0.0","runtime":{"kind":"process_jsonl","entrypoint":{"argv":["python3","-u","workflow.py"]}},"dependencies":[{"id":"native.pkg","version":"^1.0.0"}],"capabilities":{"imports":[{"id":"process.echo","kind":"tool","version":"^1.0.0"},{"id":"builtin.truncateHead","kind":"tool","version":"^1.0.0"},{"id":"native.fixture.echo","kind":"tool","version":"^1.0.0"}]},"workflows":[{"id":"workflow.cross","description":"Cross-runtime workflow","exposure":{"tool":"workflow.cross"},"inputSchema":{"type":"object"},"outputSchema":{"type":"object"},"steps":[{"id":"process","kind":"side_effect","selectedCapability":"process.echo"},{"id":"wasm","kind":"side_effect","selectedCapability":"builtin.truncateHead"},{"id":"native","kind":"side_effect","selectedCapability":"native.fixture.echo"}]}]}
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/fixtures/process/pi-extension.json", .data = process_manifest });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/fixtures/wasm/pi-extension.json", .data = wasm_manifest_text });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/fixtures/native/pi-extension.json", .data = native_manifest_text });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/fixtures/workflow/pi-extension.json", .data = workflow_manifest_text });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    for ([_][]const u8{ "process", "wasm", "native", "workflow" }) |fixture_name| {
        stdout_buf.clearRetainingCapacity();
        stderr_buf.clearRetainingCapacity();
        const source = try std.fmt.allocPrint(allocator, "./fixtures/{s}", .{fixture_name});
        defer allocator.free(source);
        const result = try runCommand(allocator, &.{ "install", source, "-l" }, options, &stdout_buf, &stderr_buf);
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Installed ./fixtures/") != null);
        try std.testing.expectEqualStrings("", stderr_buf.items);
    }

    const settings_path = try std.fs.path.join(allocator, &.{ cwd, ".pi", "settings.json" });
    defer allocator.free(settings_path);
    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    for ([_][]const u8{ "process", "wasm", "native", "workflow" }) |fixture_name| {
        const needle = try std.fmt.allocPrint(allocator, "fixtures/{s}", .{fixture_name});
        defer allocator.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, settings, needle) != null);
    }

    const process_root = try std.fs.path.join(allocator, &.{ cwd, "fixtures", "process" });
    defer allocator.free(process_root);
    const wasm_root = try std.fs.path.join(allocator, &.{ cwd, "fixtures", "wasm" });
    defer allocator.free(wasm_root);
    const native_root = try std.fs.path.join(allocator, &.{ cwd, "fixtures", "native" });
    defer allocator.free(native_root);
    const workflow_root = try std.fs.path.join(allocator, &.{ cwd, "fixtures", "workflow" });
    defer allocator.free(workflow_root);
    const process_manifest_path = try std.fs.path.join(allocator, &.{ process_root, "pi-extension.json" });
    defer allocator.free(process_manifest_path);
    const wasm_manifest_path = try std.fs.path.join(allocator, &.{ wasm_root, "pi-extension.json" });
    defer allocator.free(wasm_manifest_path);
    const native_manifest_path = try std.fs.path.join(allocator, &.{ native_root, "pi-extension.json" });
    defer allocator.free(native_manifest_path);
    const workflow_manifest_path = try std.fs.path.join(allocator, &.{ workflow_root, "pi-extension.json" });
    defer allocator.free(workflow_manifest_path);

    var startup_set = try extension_manifest.resolveManifestSources(allocator, &.{
        .{ .package_root = process_root, .manifest_path = process_manifest_path, .manifest_text = process_manifest, .source_scope = "project-auto", .precedence_rank = 0 },
        .{ .package_root = wasm_root, .manifest_path = wasm_manifest_path, .manifest_text = wasm_manifest_text, .source_scope = "project-auto", .precedence_rank = 1 },
        .{ .package_root = native_root, .manifest_path = native_manifest_path, .manifest_text = native_manifest_text, .source_scope = "project-auto", .precedence_rank = 2 },
        .{ .package_root = workflow_root, .manifest_path = workflow_manifest_path, .manifest_text = workflow_manifest_text, .source_scope = "project-auto", .precedence_rank = 3 },
    });
    defer startup_set.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), startup_set.diagnostics.len);
    const startup_snapshot = try startup_set.registrySnapshotJson(allocator);
    defer allocator.free(startup_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, startup_snapshot, "\"activationOrder\":[\"process.pkg\",\"wasm.pkg\",\"native.pkg\",\"workflow.pkg\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_snapshot, "\"id\":\"workflow.cross\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, startup_snapshot, "\"selectedCapability\":\"native.fixture.echo\"") != null);
}

test "unified package install rejects denied permission and unsupported runtime" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/denied");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/future");

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/denied/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"denied.pkg\",\"name\":\"Denied\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"index.ts\"},\"permissions\":[{\"id\":\"network\",\"policyDenied\":true,\"policySource\":\"project\"}]}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/denied/index.ts",
        .data = "export default {};",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/future/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"future.pkg\",\"name\":\"Future\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"future\",\"entrypoint\":{\"contract\":\"next\"}}}",
    });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const denied_result = try runCommand(allocator, &.{ "install", "./fixtures/denied" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), denied_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "install.policy_denied_permission") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "severity=error") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "packageId=denied.pkg") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "runtime=typescript") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "capabilityId=network") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "phase=install") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "correlationId=install:denied.pkg") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "spanId=install.policy_denied_permission:$.permissions[0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "permission \"network\" denied by project policy") != null);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const future_result = try runCommand(allocator, &.{ "install", "./fixtures/future" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), future_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "install.unsupported_runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "runtime \"future\" is not executable") != null);
}

test "unified package install validates requested permissions against merged policy" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/policy");

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/policy/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"policy.pkg\",\"name\":\"Policy\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"index.ts\"},\"permissions\":[{\"id\":\"file.read\"}]}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/policy/index.ts",
        .data = "export default {};",
    });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const denied_result = try runCommand(allocator, &.{ "install", "./fixtures/policy" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), denied_result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "code=install.policy_denied_permission") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "packageId=policy.pkg") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "runtime=typescript") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "capabilityId=file.read") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "policySource=merged-default-deny") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "phase=install") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "correlationId=install:policy.pkg") != null);

    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/policy" });
    defer allocator.free(package_root);
    const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    const policy_key = try std.fmt.allocPrint(allocator, "typescript:manifest:user:policy.pkg:1.0.0:{s}:{s}", .{ package_root, manifest_path });
    defer allocator.free(policy_key);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try writePolicySettings(allocator, settings_path, policy_key, "file.read", false);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const allowed_result = try runCommand(allocator, &.{ "install", "./fixtures/policy" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), allowed_result.exit_code);
    try std.testing.expectEqualStrings("Installed ./fixtures/policy\n", stdout_buf.items);
    try std.testing.expectEqualStrings("", stderr_buf.items);
}

test "unified project package install honors project policy override denial" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/project-policy");

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/project-policy/pi-extension.json",
        .data = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"project.policy.pkg\",\"name\":\"Project Policy\",\"version\":\"1.0.0\",\"runtime\":{\"kind\":\"typescript\",\"entrypoint\":\"index.ts\"},\"permissions\":[{\"id\":\"file.read\"}]}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/project-policy/index.ts",
        .data = "export default {};",
    });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/project-policy" });
    defer allocator.free(package_root);
    const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    const policy_key = try std.fmt.allocPrint(allocator, "typescript:manifest:project:project.policy.pkg:1.0.0:{s}:{s}", .{ package_root, manifest_path });
    defer allocator.free(policy_key);

    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    try writePolicySettings(allocator, user_settings_path, policy_key, "file.read", false);
    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    try writePolicySettingsGrantList(allocator, project_settings_path, policy_key, "", false);

    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const denied_result = try runCommand(allocator, &.{ "install", "./fixtures/project-policy", "-l" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), denied_result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "code=install.policy_denied_permission") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "packageId=project.policy.pkg") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "policySource=merged") != null);
}

test "wasm project install rejects approved grants from malformed resource limits policy" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-invalid-policy", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-invalid-policy" });
    defer allocator.free(package_root);
    var manifest_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, package_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const final_key = try policy_key_mod.wasmPolicyLookupKey(allocator, extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid));
    defer allocator.free(final_key);
    const quoted_key = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = final_key }, .{});
    defer allocator.free(quoted_key);
    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    const settings = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "extensionPolicies": {{
        \\    {s}: {{
        \\      "approvedGrants": ["file.read"],
        \\      "resourceLimits": {{ "timeoutMs": 9007199254740992 }}
        \\    }}
        \\  }}
        \\}}
    , .{quoted_key});
    defer allocator.free(settings);
    try common.writeFileAbsolute(std.testing.io, user_settings_path, settings, true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-invalid-policy", "-l" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Installed ./fixtures/wasm-invalid-policy") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "approval target: wasm:") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    const project_settings_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), std.testing.io, project_settings_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (project_settings_exists) {
        const project_settings = try readSettings(allocator, project_settings_path);
        defer allocator.free(project_settings);
        try std.testing.expect(std.mem.indexOf(u8, project_settings, "wasm-invalid-policy") != null);
    }
}

test "wasm project policy override keeps pre-artifact grants default-denied when unapproved" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-merged-pre-denied", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-merged-pre-denied" });
    defer allocator.free(package_root);
    const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    const policy_key = try policy_key_mod.wasmManifestPolicyLookupKey(allocator, .{
        .schema_version = wasm_manifest.SCHEMA_VERSION,
        .id = "com.example.policy",
        .version = "0.1.0",
        .package_root = package_root,
        .manifest_path = manifest_path,
        .artifact_path = "wasm/example-tool.wasm",
    });
    defer allocator.free(policy_key);
    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    try writePolicySettings(allocator, user_settings_path, policy_key, "file.read", false);
    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    try writePolicySettings(allocator, project_settings_path, policy_key, "file.write", false);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-merged-pre-denied", "-l" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "denied_capability") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "file.read") != null);
}

test "wasm project policy override keeps final artifact grants default-denied when unapproved" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-merged-final-denied", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-merged-final-denied" });
    defer allocator.free(package_root);
    var manifest_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, package_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const final_key = try policy_key_mod.wasmPolicyLookupKey(allocator, extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid));
    defer allocator.free(final_key);
    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    try writePolicySettings(allocator, user_settings_path, final_key, "file.read", false);
    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    try writePolicySettingsGrantList(allocator, project_settings_path, final_key, "", false);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-merged-final-denied", "-l" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "denied_capability") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "file.read") != null);
}

test "wasm package install rejects sibling grants and resource limits as approval" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try writeWasmPackageFixture(&tmp, "repo/fixtures/wasm-sibling", "file.read", true);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "fixtures/wasm-sibling" });
    defer allocator.free(package_root);
    const manifest_path = try std.fs.path.join(allocator, &[_][]const u8{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    const policy_key = try policy_key_mod.wasmManifestPolicyLookupKey(allocator, .{
        .schema_version = wasm_manifest.SCHEMA_VERSION,
        .id = "com.example.policy",
        .version = "0.1.0",
        .package_root = package_root,
        .manifest_path = manifest_path,
        .artifact_path = "wasm/example-tool.wasm",
    });
    defer allocator.free(policy_key);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try writePolicySettings(allocator, settings_path, policy_key, "file.write", true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/wasm-sibling" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "denied_capability") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "file.read") != null);

    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"packages\"") == null);
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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    try std.testing.expectEqualStrings("Removed ./fixtures/pkg\n  scope: user\n", stdout_buf.items);
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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    try std.testing.expectEqualStrings("Updated packages\nUpdated pi\n", stdout_buf.items);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "No matching package found") != null);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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

test "VAL-PKG-105 npm install invokes configured package command without real network" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const record_path = try makeAbsoluteTmpPath(allocator, tmp, "npm-install-args.txt");
    defer allocator.free(record_path);
    const script = try std.fmt.allocPrint(allocator, "printf '%s\\n' \"$@\" > '{s}'", .{record_path});
    defer allocator.free(script);
    const npm_command = [_][]const u8{ "/bin/sh", "-c", script, "fake-npm" };
    const options = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .npm_command_override = npm_command[0..],
        .git_command_override = &.{"/usr/bin/true"},
        .self_update_command_override = &.{"/usr/bin/true"},
    };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "npm:@scope/pkg" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const record = try readSettings(allocator, record_path);
    defer allocator.free(record);
    const expected_root = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "packages", "npm" });
    defer allocator.free(expected_root);
    const expected = try std.fmt.allocPrint(allocator, "install\n@scope/pkg\n--prefix\n{s}\n", .{expected_root});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, record);
    try std.testing.expect(std.mem.indexOf(u8, record, "packages/npm") != null);
}

test "VAL-PKG-106 npm update --extension invokes latest install without self-update" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const record_path = try makeAbsoluteTmpPath(allocator, tmp, "npm-update-args.txt");
    defer allocator.free(record_path);
    const script = try std.fmt.allocPrint(allocator, "printf '%s\\n' \"$@\" > '{s}'", .{record_path});
    defer allocator.free(script);
    const npm_command = [_][]const u8{ "/bin/sh", "-c", script, "fake-npm" };
    const options = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .npm_command_override = npm_command[0..],
        .git_command_override = &.{"/usr/bin/true"},
        .self_update_command_override = &.{"/usr/bin/true"},
    };

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{ "packages": ["npm:@scope/pkg"] }
    , true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "update", "--extension", "npm:@scope/pkg" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("Updated npm:@scope/pkg\n", stdout_buf.items);

    const record = try readSettings(allocator, record_path);
    defer allocator.free(record);
    const expected_root = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "packages", "npm" });
    defer allocator.free(expected_root);
    const expected = try std.fmt.allocPrint(allocator, "install\n@scope/pkg@latest\n--prefix\n{s}\n", .{expected_root});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, record);
    try std.testing.expect(std.mem.indexOf(u8, record, "packages/npm") != null);
}

test "VAL-PKG-108 npm project install and update use package resource root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const record_path = try makeAbsoluteTmpPath(allocator, tmp, "npm-project-args.txt");
    defer allocator.free(record_path);
    const script = try std.fmt.allocPrint(allocator, "printf '%s\\n' \"$@\" >> '{s}'; printf -- '--\\n' >> '{s}'", .{ record_path, record_path });
    defer allocator.free(script);
    const npm_command = [_][]const u8{ "/bin/sh", "-c", script, "fake-npm" };
    const options = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .npm_command_override = npm_command[0..],
        .git_command_override = &.{"/usr/bin/true"},
        .self_update_command_override = &.{"/usr/bin/true"},
    };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const source = "npm:@scope/project-pkg";
    const install_result = try runCommand(allocator, &.{ "install", source, "-l" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), install_result.exit_code);
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const update_result = try runCommand(allocator, &.{ "update", "--extension", source }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), update_result.exit_code);

    const expected_root = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "packages", "npm" });
    defer allocator.free(expected_root);
    const expected = try std.fmt.allocPrint(
        allocator,
        "install\n@scope/project-pkg\n--prefix\n{s}\n--\ninstall\n@scope/project-pkg@latest\n--prefix\n{s}\n--\n",
        .{ expected_root, expected_root },
    );
    defer allocator.free(expected);
    const record = try readSettings(allocator, record_path);
    defer allocator.free(record);
    try std.testing.expectEqualStrings(expected, record);
    try std.testing.expect(std.mem.indexOf(u8, record, ".pi/packages/npm") != null);
}

test "VAL-PKG-107 duplicate --extension is rejected like TypeScript" {
    const allocator = std.testing.allocator;
    var parsed = try parsePackageCommand(allocator, &.{ "update", "--extension", "npm:one", "--extension", "npm:two" });
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.parse_error.?, "--extension can only be provided once") != null);
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
    const options = fakeNetworkOptions(cwd, agent_dir);

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

test "VAL-PKG-111 git:git@ SSH source accepted" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);

    const result = try runCommand(
        allocator,
        &.{ "install", "git:git@github.com:user/repo.git" },
        options,
        &buf_a,
        &buf_b,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "Installed git:git@github.com:user/repo.git") != null);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"git:git@github.com:user/repo.git\"") != null);
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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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

test "VAL-PKG-116 git install uses package resource roots for user and project scopes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const record_path = try makeAbsoluteTmpPath(allocator, tmp, "git-install-args.txt");
    defer allocator.free(record_path);
    const script = try std.fmt.allocPrint(allocator, "printf '%s\\n' \"$@\" >> '{s}'; printf -- '--\\n' >> '{s}'", .{ record_path, record_path });
    defer allocator.free(script);
    const git_command = [_][]const u8{ "/bin/sh", "-c", script, "fake-git" };
    const options = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .npm_command_override = &.{"/usr/bin/true"},
        .git_command_override = git_command[0..],
        .self_update_command_override = &.{"/usr/bin/true"},
    };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const user_source = "git:github.com/user/repo";
    const project_source = "git:github.com/user/project-repo";
    const user_result = try runCommand(allocator, &.{ "install", user_source }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), user_result.exit_code);
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const project_result = try runCommand(allocator, &.{ "install", project_source, "-l" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), project_result.exit_code);

    const user_target = try gitInstallPath(allocator, options, user_source, false);
    defer allocator.free(user_target);
    const project_target = try gitInstallPath(allocator, options, project_source, true);
    defer allocator.free(project_target);
    const expected = try std.fmt.allocPrint(
        allocator,
        "clone\nhttps://github.com/user/repo\n{s}\n--\nclone\nhttps://github.com/user/project-repo\n{s}\n--\n",
        .{ user_target, project_target },
    );
    defer allocator.free(expected);

    const record = try readSettings(allocator, record_path);
    defer allocator.free(record);
    try std.testing.expectEqualStrings(expected, record);
    try std.testing.expect(std.mem.indexOf(u8, user_target, "packages/git") != null);
    try std.testing.expect(std.mem.indexOf(u8, project_target, ".pi/packages/git") != null);
}

test "VAL-PKG-117 git update runs in package resource target directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const record_path = try makeAbsoluteTmpPath(allocator, tmp, "git-update-args.txt");
    defer allocator.free(record_path);
    const script = try std.fmt.allocPrint(allocator, "pwd > '{s}'; printf -- '--\\n' >> '{s}'; printf '%s\\n' \"$@\" >> '{s}'", .{ record_path, record_path, record_path });
    defer allocator.free(script);
    const git_command = [_][]const u8{ "/bin/sh", "-c", script, "fake-git" };
    const options = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .npm_command_override = &.{"/usr/bin/true"},
        .git_command_override = git_command[0..],
        .self_update_command_override = &.{"/usr/bin/true"},
    };

    const source = "git:github.com/user/repo";
    const target = try gitInstallPath(allocator, options, source, false);
    defer allocator.free(target);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, target);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{ "packages": ["git:github.com/user/repo"] }
    , true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "update", "--extension", source }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const record = try readSettings(allocator, record_path);
    defer allocator.free(record);
    const expected = try std.fmt.allocPrint(allocator, "{s}\n--\npull\n--ff-only\n", .{target});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, record);
    try std.testing.expect(std.mem.indexOf(u8, record, "packages/git") != null);
}

test "VAL-PKG-118 persisted https git source is resource-loader discoverable" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const source = "https://github.com/user/resource-pkg";
    const result = try runCommand(allocator, &.{ "install", source }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const persisted_source = try readFirstPackageSource(allocator, settings_path);
    defer allocator.free(persisted_source);
    try std.testing.expectEqualStrings(source, persisted_source);

    const install_path = try gitInstallPath(allocator, options, persisted_source, false);
    defer allocator.free(install_path);
    const extension_dir = try std.fs.path.join(allocator, &[_][]const u8{ install_path, "extensions" });
    defer allocator.free(extension_dir);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, extension_dir);
    const extension_path = try std.fs.path.join(allocator, &[_][]const u8{ extension_dir, "main.ts" });
    defer allocator.free(extension_path);
    try common.writeFileAbsolute(std.testing.io, extension_path, "export default {};\n", true);

    var package_config = resources_mod.PackageSourceConfig{ .source = try allocator.dupe(u8, persisted_source) };
    defer package_config.deinit(allocator);
    var resolved = try resources_mod.resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .global = .{ .packages = &.{package_config} },
        .include_default_extensions = false,
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), resolved.extensions.len);
    try std.testing.expect(std.mem.endsWith(u8, resolved.extensions[0].path, "extensions/main.ts"));
}

test "VAL-PKG-119 normalized local package sources are resource-loader discoverable" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/user-pkg/extensions");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/project-pkg/extensions");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/user-pkg/extensions/user.ts",
        .data = "export default {};\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/project-pkg/extensions/project.ts",
        .data = "export default {};\n",
    });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const user_result = try runCommand(allocator, &.{ "install", "./fixtures/user-pkg" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), user_result.exit_code);
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const project_result = try runCommand(allocator, &.{ "install", "./fixtures/project-pkg", "-l" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), project_result.exit_code);

    const user_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_settings_path);
    const user_source = try readFirstPackageSource(allocator, user_settings_path);
    defer allocator.free(user_source);
    const expected_user_source = try normalizePackageSourceForSettings(allocator, "./fixtures/user-pkg", false, cwd, agent_dir);
    defer allocator.free(expected_user_source);
    try std.testing.expectEqualStrings(expected_user_source, user_source);

    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    const project_source = try readFirstPackageSource(allocator, project_settings_path);
    defer allocator.free(project_source);
    const expected_project_source = try normalizePackageSourceForSettings(allocator, "./fixtures/project-pkg", true, cwd, agent_dir);
    defer allocator.free(expected_project_source);
    try std.testing.expectEqualStrings(expected_project_source, project_source);

    var user_package = resources_mod.PackageSourceConfig{ .source = try allocator.dupe(u8, user_source) };
    defer user_package.deinit(allocator);
    var project_package = resources_mod.PackageSourceConfig{ .source = try allocator.dupe(u8, project_source) };
    defer project_package.deinit(allocator);
    var resolved = try resources_mod.resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .global = .{ .packages = &.{user_package} },
        .project = .{ .packages = &.{project_package} },
        .include_default_extensions = false,
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer resolved.deinit(allocator);

    var saw_user = false;
    var saw_project = false;
    for (resolved.extensions) |entry| {
        if (std.mem.endsWith(u8, entry.path, "extensions/user.ts")) saw_user = true;
        if (std.mem.endsWith(u8, entry.path, "extensions/project.ts")) saw_project = true;
    }
    try std.testing.expect(saw_user);
    try std.testing.expect(saw_project);
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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const options = fakeNetworkOptions(cwd, agent_dir);

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

test "VAL-UPSYNC-001 self_update package identity uses renamed package scope" {
    try std.testing.expectEqualStrings("@earendil-works/pi-coding-agent", package_name);
}

test "VAL-UPSYNC-001 forced self_update skips latest release fetch and installs current package" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const log_path = try makeAbsoluteTmpPath(allocator, tmp, "self-update.log");
    defer allocator.free(log_path);
    const recorder = try makeSelfUpdateRecorderScript(allocator, log_path, false);
    defer allocator.free(recorder);

    var latest_probe_count: usize = 0;
    const options = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .self_update_command_override = &.{ "/bin/sh", "-c", recorder },
        .self_update_latest_release_override = .{
            .version = "0.1.0",
            .package_name = "@example/renamed-package",
        },
        .self_update_latest_release_probe = &latest_probe_count,
        .current_version = "0.1.0",
    };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(
        allocator,
        &.{ "update", "self", "--force" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqual(@as(usize, 0), latest_probe_count);
    try std.testing.expectEqualStrings("", stderr_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Updated pi") != null);

    const log = try readSelfUpdateLog(allocator, log_path);
    defer allocator.free(log);
    try std.testing.expectEqualStrings("install -g @earendil-works/pi-coding-agent\n", log);
}

test "VAL-UPSYNC-001 latest packageName change plans uninstall old then install new" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const log_path = try makeAbsoluteTmpPath(allocator, tmp, "self-update.log");
    defer allocator.free(log_path);
    const recorder = try makeSelfUpdateRecorderScript(allocator, log_path, false);
    defer allocator.free(recorder);

    var latest_probe_count: usize = 0;
    const options = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .self_update_command_override = &.{ "/bin/sh", "-c", recorder },
        .self_update_latest_release_override = .{
            .version = "1.2.3",
            .package_name = "@earendil-works/pi-coding-agent-next",
        },
        .self_update_latest_release_probe = &latest_probe_count,
        .current_version = "1.2.3",
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
    try std.testing.expectEqual(@as(usize, 1), latest_probe_count);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    const log = try readSelfUpdateLog(allocator, log_path);
    defer allocator.free(log);
    try std.testing.expectEqualStrings(
        "uninstall -g @earendil-works/pi-coding-agent\ninstall -g @earendil-works/pi-coding-agent-next\n",
        log,
    );
}

test "VAL-UPSYNC-001 same latest package and version skips self_update command" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const log_path = try makeAbsoluteTmpPath(allocator, tmp, "self-update.log");
    defer allocator.free(log_path);
    const recorder = try makeSelfUpdateRecorderScript(allocator, log_path, false);
    defer allocator.free(recorder);

    var latest_probe_count: usize = 0;
    const options = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .self_update_command_override = &.{ "/bin/sh", "-c", recorder },
        .self_update_latest_release_override = .{
            .version = "2.0.0",
            .package_name = "@earendil-works/pi-coding-agent",
        },
        .self_update_latest_release_probe = &latest_probe_count,
        .current_version = "2.0.0",
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
    try std.testing.expectEqual(@as(usize, 1), latest_probe_count);
    try std.testing.expectEqualStrings("", stderr_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "already up to date") != null);

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), std.testing.io, log_path, .{}));
}

test "VAL-UPSYNC-001 unsupported native self_update prints current package name" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    const options = ExecuteOptions{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .self_update_latest_release_override = .{
            .version = "9.9.9",
            .package_name = "@example/renamed-package",
        },
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
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "self-update this installation") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "@earendil-works/pi-coding-agent") != null);
}

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

// ---------------------------------------------------------------------------
// Update flags tests (VAL-PKG-130..139)
// ---------------------------------------------------------------------------

test "VAL-PKG-131 --extensions flag resolves update_target to .extensions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    // Verify parsed update_target.
    var parsed = try parsePackageCommand(allocator, &.{ "update", "--extensions" });
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.parse_error == null);
    try std.testing.expect(parsed.update_target != null);
    try std.testing.expect(parsed.update_target.? == .extensions);

    // Verify execution: prints "Updated packages", no self-update output.
    const options = fakeNetworkOptions(cwd, agent_dir);
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    const result = try runCommand(allocator, &.{ "update", "--extensions" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Updated packages") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);
}

test "VAL-PKG-132 --extension <source> updates a single package" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    // Verify parsing: update_target must be .{ .source = "npm:@foo/bar" }.
    var parsed = try parsePackageCommand(allocator, &.{ "update", "--extension", "npm:@foo/bar" });
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.parse_error == null);
    try std.testing.expect(parsed.update_target != null);
    switch (parsed.update_target.?) {
        .source => |src| try std.testing.expectEqualStrings("npm:@foo/bar", src),
        else => return error.TestUnexpectedResult,
    }

    // Install the package first, then update it.
    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);
    _ = try runCommand(allocator, &.{ "install", "npm:@foo/bar" }, options, &buf_a, &buf_b);
    buf_a.clearRetainingCapacity();
    buf_b.clearRetainingCapacity();

    const result = try runCommand(
        allocator,
        &.{ "update", "--extension", "npm:@foo/bar" },
        options,
        &buf_a,
        &buf_b,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "Updated npm:@foo/bar") != null);
}

test "VAL-PKG-133 --extension without value reports error" {
    const allocator = std.testing.allocator;

    var parsed = try parsePackageCommand(allocator, &.{ "update", "--extension" });
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.parse_error.?, "Missing value for --extension") != null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    const result = try runCommand(allocator, &.{ "update", "--extension" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "--extension") != null);
}

test "VAL-PKG-134 --extension combined with --self or --extensions reports conflict" {
    const allocator = std.testing.allocator;

    // --extension + --self
    var parsed_self = try parsePackageCommand(allocator, &.{ "update", "--extension", "npm:foo", "--self" });
    defer parsed_self.deinit(allocator);
    try std.testing.expect(parsed_self.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed_self.parse_error.?, "--extension") != null);

    // --extension + --extensions
    var parsed_ext = try parsePackageCommand(allocator, &.{ "update", "--extension", "npm:foo", "--extensions" });
    defer parsed_ext.deinit(allocator);
    try std.testing.expect(parsed_ext.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed_ext.parse_error.?, "--extension") != null);

    // Verify exit code 1 on execute.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    const r = try runCommand(
        allocator,
        &.{ "update", "--extension", "npm:foo", "--self" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
}

test "VAL-PKG-135 --extension combined with positional source reports conflict" {
    const allocator = std.testing.allocator;

    var parsed = try parsePackageCommand(allocator, &.{ "update", "npm:foo", "--extension", "npm:bar" });
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.parse_error != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.parse_error.?, "--extension") != null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    const r = try runCommand(
        allocator,
        &.{ "update", "npm:foo", "--extension", "npm:bar" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
}

test "VAL-PKG-136 --self --extensions resolves to update-all with both outputs" {
    const allocator = std.testing.allocator;

    // Verify parsing: update_target = .all, update_self = true.
    var parsed = try parsePackageCommand(allocator, &.{ "update", "--self", "--extensions" });
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.parse_error == null);
    try std.testing.expect(parsed.update_target != null);
    try std.testing.expect(parsed.update_target.? == .all);
    try std.testing.expect(parsed.update_self == true);

    // Verify execution: both self-update and extension update outputs.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
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
        &.{ "update", "--self", "--extensions" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Updated pi") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Updated packages") != null);
}

// ---------------------------------------------------------------------------
// Config selector tests (VAL-PKG-140..143)
// ---------------------------------------------------------------------------

test "VAL-PKG-140 bare pi config exits 0 and shows configurable kinds" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{"config"}, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    // Must list all configurable kinds.
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "extensions") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "prompts") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "themes") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);
}

test "VAL-PKG-141 config selector shows current enable/disable state from settings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    // Pre-populate settings with enabled and disabled entries.
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{
        \\  "extensions": ["+foo", "-bar"]
        \\}
    , true);

    // Toggle foo to disabled (replaces +foo with -foo) and verify state.
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    const result = try runCommand(
        allocator,
        &.{ "config", "--toggle", "extensions", "foo", "--disable" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const after = try readSettings(allocator, settings_path);
    defer allocator.free(after);
    // foo must be disabled now (not enabled).
    try std.testing.expect(std.mem.indexOf(u8, after, "\"-foo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"+foo\"") == null);
    // bar still disabled.
    try std.testing.expect(std.mem.indexOf(u8, after, "\"-bar\"") != null);
}

test "VAL-PKG-142 config selector toggle replaces stale entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{ "extensions": ["+my-ext"] }
    , true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    // Toggle to disabled: should replace +my-ext with -my-ext.
    const result = try runCommand(
        allocator,
        &.{ "config", "--toggle", "extensions", "my-ext", "--disable" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const after = try readSettings(allocator, settings_path);
    defer allocator.free(after);
    // Only one entry for my-ext, and it must be -my-ext.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, after, "my-ext"));
    try std.testing.expect(std.mem.indexOf(u8, after, "\"-my-ext\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"+my-ext\"") == null);
}

test "VAL-PKG-143 config selector respects --local scope" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    const result = try runCommand(
        allocator,
        &.{ "config", "--toggle", "extensions", "proj-ext", "--enable", "-l" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    // Project settings must have the toggle.
    const project_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_path);
    const project = try readSettings(allocator, project_path);
    defer allocator.free(project);
    try std.testing.expect(std.mem.indexOf(u8, project, "\"+proj-ext\"") != null);

    // User settings must NOT exist.
    const user_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_path);
    const user_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), std.testing.io, user_path, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!user_exists);
}

// ---------------------------------------------------------------------------
// Local source regression tests (VAL-PKG-160..168)
// ---------------------------------------------------------------------------

test "VAL-PKG-160 local path install still works at user scope" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/pkg");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Installed ./fixtures/pkg") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    const expected_source = try normalizePackageSourceForSettings(allocator, "./fixtures/pkg", false, cwd, agent_dir);
    defer allocator.free(expected_source);
    try std.testing.expect(std.mem.indexOf(u8, settings, expected_source) != null);
}

test "VAL-PKG-161 local path install still works at project scope with -l" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/pkg");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

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

    const project_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_path);
    const project = try readSettings(allocator, project_path);
    defer allocator.free(project);
    const expected_source = try normalizePackageSourceForSettings(allocator, "./fixtures/pkg", true, cwd, agent_dir);
    defer allocator.free(expected_source);
    try std.testing.expect(std.mem.indexOf(u8, project, expected_source) != null);

    // User settings must not exist.
    const user_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(user_path);
    const user_exists = blk: {
        _ = std.Io.Dir.statFile(.cwd(), std.testing.io, user_path, .{}) catch break :blk false;
        break :blk true;
    };
    try std.testing.expect(!user_exists);
}

test "VAL-PKG-162 local path remove still works and preserves other settings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{
        \\  "defaultProvider": "anthropic",
        \\  "packages": [{ "source": "./fixtures/pkg" }]
        \\}
    , true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    const result = try runCommand(
        allocator,
        &.{ "remove", "./fixtures/pkg" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Removed ./fixtures/pkg") != null);

    const after = try readSettings(allocator, settings_path);
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "./fixtures/pkg") == null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"defaultProvider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"anthropic\"") != null);
}

test "VAL-PKG-163 remove of non-existent local path reports error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    const result = try runCommand(
        allocator,
        &.{ "remove", "./nonexistent" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "./nonexistent") != null);
    try std.testing.expectEqualStrings("", stdout_buf.items);
}

test "VAL-PKG-164 pi uninstall alias still works for remove" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Removed ./fixtures/pkg") != null);
}

test "VAL-PKG-165 local path duplicate install is a no-op" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    var buf_a: std.ArrayList(u8) = .empty;
    defer buf_a.deinit(allocator);
    var buf_b: std.ArrayList(u8) = .empty;
    defer buf_b.deinit(allocator);

    _ = try runCommand(allocator, &.{ "install", "./fixtures/pkg" }, options, &buf_a, &buf_b);
    buf_a.clearRetainingCapacity();
    buf_b.clearRetainingCapacity();

    const r2 = try runCommand(allocator, &.{ "install", "./fixtures/pkg" }, options, &buf_a, &buf_b);
    try std.testing.expectEqual(@as(u8, 0), r2.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "Already installed") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf_a.items, "./fixtures/pkg") != null);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const settings = try readSettings(allocator, settings_path);
    defer allocator.free(settings);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, settings, "./fixtures/pkg"));
}

test "VAL-PKG-166 update no-op for local packages leaves settings unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Updated packages") != null);

    const after = try readSettings(allocator, settings_path);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "VAL-PKG-167 targeted update of installed local source confirms without mutation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

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
    const result = try runCommand(
        allocator,
        &.{ "update", "./fixtures/pkg" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Updated ./fixtures/pkg") != null);

    const after = try readSettings(allocator, settings_path);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "VAL-PKG-168 targeted update of missing source reports error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{ "packages": [{ "source": "./fixtures/installed" }] }
    , true);

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
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "./fixtures/missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "No matching package found") != null);
    try std.testing.expectEqualStrings("", stdout_buf.items);
}

test "VAL-PKG-170 help text for update documents all flags" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    const result = try runCommand(allocator, &.{ "update", "--help" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "--self") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "--extensions") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "--extension") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "--force") != null);
}

test "VAL-PKG-172 unknown flag on any command reports error with usage" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    const cwd = try makeAbsoluteTmpPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = fakeNetworkOptions(cwd, agent_dir);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    const result = try runCommand(
        allocator,
        &.{ "install", "--bogus", "npm:foo" },
        options,
        &stdout_buf,
        &stderr_buf,
    );
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "--bogus") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "pi install") != null);
    try std.testing.expectEqualStrings("", stdout_buf.items);
}

// ---------------------------------------------------------------------------
// Config selector state machine tests (VAL-PKG-140..143 programmatic driver).
// These test the pure state machine without starting a real terminal.
// ---------------------------------------------------------------------------

test "ConfigSelectorState moveDown wraps from last to first" {
    const allocator = std.testing.allocator;
    var state = ConfigSelectorState{ .entries = .empty };
    defer state.deinit(allocator);

    const p0 = try allocator.dupe(u8, "foo");
    errdefer allocator.free(p0);
    const p1 = try allocator.dupe(u8, "bar");
    errdefer allocator.free(p1);
    try state.entries.append(allocator, .{ .kind = .extensions, .pattern = p0, .enabled = true });
    try state.entries.append(allocator, .{ .kind = .extensions, .pattern = p1, .enabled = false });

    state.selected = 1;
    state.moveDown();
    try std.testing.expectEqual(@as(usize, 0), state.selected);
}

test "ConfigSelectorState moveUp wraps from first to last" {
    const allocator = std.testing.allocator;
    var state = ConfigSelectorState{ .entries = .empty };
    defer state.deinit(allocator);

    const p0 = try allocator.dupe(u8, "foo");
    errdefer allocator.free(p0);
    const p1 = try allocator.dupe(u8, "bar");
    errdefer allocator.free(p1);
    try state.entries.append(allocator, .{ .kind = .extensions, .pattern = p0, .enabled = true });
    try state.entries.append(allocator, .{ .kind = .extensions, .pattern = p1, .enabled = false });

    state.selected = 0;
    state.moveUp();
    try std.testing.expectEqual(@as(usize, 1), state.selected);
}

test "ConfigSelectorState toggleSelected inverts enabled and marks changed" {
    const allocator = std.testing.allocator;
    var state = ConfigSelectorState{ .entries = .empty };
    defer state.deinit(allocator);

    const pat = try allocator.dupe(u8, "my-ext");
    errdefer allocator.free(pat);
    try state.entries.append(allocator, .{ .kind = .extensions, .pattern = pat, .enabled = true });

    try std.testing.expect(!state.hasChanges());
    state.toggleSelected();
    try std.testing.expect(state.hasChanges());
    try std.testing.expect(!state.entries.items[0].enabled);
    try std.testing.expect(state.entries.items[0].changed);
}

test "ConfigSelectorState hasChanges false when no toggle applied" {
    const allocator = std.testing.allocator;
    var state = ConfigSelectorState{ .entries = .empty };
    defer state.deinit(allocator);

    const pat = try allocator.dupe(u8, "ext1");
    errdefer allocator.free(pat);
    try state.entries.append(allocator, .{ .kind = .extensions, .pattern = pat, .enabled = true });

    try std.testing.expect(!state.hasChanges());
}

test "loadSelectorState parses enabled and disabled entries from settings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);

    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{
        \\  "extensions": ["+foo", "-bar"],
        \\  "skills": ["+my-skill"]
        \\}
    , true);

    var state = try loadSelectorState(allocator, std.testing.io, settings_path);
    defer state.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), state.entries.items.len);

    // First entry: +foo → enabled
    try std.testing.expectEqualStrings("foo", state.entries.items[0].pattern);
    try std.testing.expect(state.entries.items[0].enabled);
    try std.testing.expect(state.entries.items[0].kind == .extensions);

    // Second entry: -bar → disabled
    try std.testing.expectEqualStrings("bar", state.entries.items[1].pattern);
    try std.testing.expect(!state.entries.items[1].enabled);

    // Third entry: +my-skill → enabled
    try std.testing.expectEqualStrings("my-skill", state.entries.items[2].pattern);
    try std.testing.expect(state.entries.items[2].enabled);
    try std.testing.expect(state.entries.items[2].kind == .skills);
}

test "loadSelectorState returns empty state for missing settings file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const missing_path = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent/nonexistent.json");
    defer allocator.free(missing_path);

    var state = try loadSelectorState(allocator, std.testing.io, missing_path);
    defer state.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), state.entries.items.len);
}

test "saveSelectorState writes changed entries and replaces stale entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);

    // Start with +foo enabled in settings.
    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{ "extensions": ["+foo"] }
    , true);

    // Build a state with foo toggled to disabled.
    var state = ConfigSelectorState{ .entries = .empty };
    defer state.deinit(allocator);
    const pat = try allocator.dupe(u8, "foo");
    errdefer allocator.free(pat);
    try state.entries.append(allocator, .{
        .kind = .extensions,
        .pattern = pat,
        .enabled = false,
        .changed = true,
    });

    try saveSelectorState(allocator, std.testing.io, settings_path, &state);

    const after = try readSettings(allocator, settings_path);
    defer allocator.free(after);

    // Must have exactly one entry: -foo.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, after, "foo"));
    try std.testing.expect(std.mem.indexOf(u8, after, "\"-foo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"+foo\"") == null);
}

test "saveSelectorState does not write unchanged entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);

    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{ "extensions": ["+foo"] }
    , true);
    const before = try readSettings(allocator, settings_path);
    defer allocator.free(before);

    // Build a state with foo NOT changed.
    var state = ConfigSelectorState{ .entries = .empty };
    defer state.deinit(allocator);
    const pat = try allocator.dupe(u8, "foo");
    errdefer allocator.free(pat);
    try state.entries.append(allocator, .{
        .kind = .extensions,
        .pattern = pat,
        .enabled = true,
        .changed = false, // unchanged
    });

    try saveSelectorState(allocator, std.testing.io, settings_path, &state);

    const after = try readSettings(allocator, settings_path);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "config selector simulate navigate+toggle+save flow persists to settings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);

    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{ "extensions": ["+ext-a", "-ext-b"] }
    , true);

    var state = try loadSelectorState(allocator, std.testing.io, settings_path);
    defer state.deinit(allocator);

    // Verify initial state: ext-a enabled, ext-b disabled.
    try std.testing.expectEqual(@as(usize, 2), state.entries.items.len);
    try std.testing.expect(state.entries.items[0].enabled); // ext-a
    try std.testing.expect(!state.entries.items[1].enabled); // ext-b

    // Simulate: moveDown to select ext-b (index 1), toggle it enabled.
    state.moveDown();
    try std.testing.expectEqual(@as(usize, 1), state.selected);
    state.toggleSelected();
    try std.testing.expect(state.entries.items[1].enabled);
    try std.testing.expect(state.hasChanges());

    // Simulate Enter: save.
    try saveSelectorState(allocator, std.testing.io, settings_path, &state);

    const after = try readSettings(allocator, settings_path);
    defer allocator.free(after);

    // ext-b must now be +ext-b.
    try std.testing.expect(std.mem.indexOf(u8, after, "\"+ext-b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "\"-ext-b\"") == null);
    // ext-a must remain +ext-a (unchanged).
    try std.testing.expect(std.mem.indexOf(u8, after, "\"+ext-a\"") != null);
}

test "config selector simulate esc flow does not persist changes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);

    try common.writeFileAbsolute(std.testing.io, settings_path,
        \\{ "extensions": ["+ext-a"] }
    , true);
    const before = try readSettings(allocator, settings_path);
    defer allocator.free(before);

    var state = try loadSelectorState(allocator, std.testing.io, settings_path);
    defer state.deinit(allocator);

    // Toggle (simulate space key).
    state.toggleSelected();
    try std.testing.expect(state.hasChanges());

    // Simulate Esc: do NOT call saveSelectorState.
    // Settings file must be unchanged.
    const after = try readSettings(allocator, settings_path);
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}
