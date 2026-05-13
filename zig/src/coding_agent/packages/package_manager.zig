const std = @import("std");
const common = @import("../tools/common.zig");
const config_mod = @import("../config/config.zig");
const extension_manifest = @import("../extensions/extension_manifest.zig");
const extension_runtime = @import("../extensions/extension_runtime.zig");
const native_manifest = @import("../extensions/native/native_manifest.zig");
const policy_key_mod = @import("../extensions/policy_key.zig");
const wasm_manifest = @import("../extensions/wasm/wasm_manifest.zig");
const resources_mod = @import("../resources/resources.zig");
const config_selector = @import("config_selector.zig");
const package_command_parser = @import("package_command_parser.zig");
const package_process_runner = @import("package_process_runner.zig");
const package_settings_store = @import("package_settings_store.zig");
const package_sources = @import("package_sources.zig");
const provenance_lockfile = @import("provenance_lockfile.zig");
const self_update = @import("self_update.zig");

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
pub const ConfigKind = package_settings_store.ConfigKind;
const ProvenanceScope = provenance_lockfile.Scope;
const collectScopePackages = package_settings_store.collectScopePackages;
const LocalPathMode = package_sources.LocalPathMode;
const computeInstalledPath = package_sources.computeInstalledPath;
const ensurePackagesArray = package_settings_store.ensurePackagesArray;
const findPackageIndex = package_settings_store.findPackageIndex;
const gitInstallPath = package_sources.gitInstallPath;
const isGitSource = package_sources.isGitSource;
const isLocalSource = package_sources.isLocalSource;
const isNpmSource = package_sources.isNpmSource;
const loadSettingsObject = package_settings_store.loadSettingsObject;
const localProvenanceKeyForSource = package_sources.localProvenanceKeyForSource;
const normalizePackageSourceForSettings = package_sources.normalizePackageSourceForSettings;
const npmPackageName = package_sources.npmPackageName;
const packageSourcesMatchForScope = package_sources.packageSourcesMatchForScope;
const packageSourceFromItem = package_settings_store.packageSourceFromItem;
const parseGitSource = package_sources.parseGitSource;
const resolveLocalPathFromCwd = package_sources.resolveLocalPathFromCwd;
const resolveLocalPathFromScopeBase = package_sources.resolveLocalPathFromScopeBase;
const settingsPathForScope = package_settings_store.settingsPathForScope;
const executeGitInstall = package_process_runner.executeGitInstall;
const executeGitUpdate = package_process_runner.executeGitUpdate;
const executeNpmInstall = package_process_runner.executeNpmInstall;
const executeNpmUpdate = package_process_runner.executeNpmUpdate;

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
    /// Test-only fault injection used to prove lifecycle state writes are
    /// transactional when digest-bound policy cleanup cannot be persisted.
    fail_policy_write_for_testing: bool = false,
};

pub const SelfUpdatePackageManager = self_update.SelfUpdatePackageManager;
pub const LatestSelfUpdateRelease = self_update.LatestSelfUpdateRelease;
pub const ExecuteResult = self_update.ExecuteResult;

fn settingsWriteOptions(options: ExecuteOptions) package_settings_store.WriteOptions {
    return .{ .fail_settings_write_for_testing = options.fail_settings_write_for_testing };
}

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
    const enabled = action == .enable;

    const settings_path = try settingsPathForScope(allocator, options, command.local);
    defer allocator.free(settings_path);

    var settings_object = try loadSettingsObject(allocator, io, settings_path);
    defer {
        const owner: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, owner);
    }

    try package_settings_store.setConfigKindPattern(allocator, &settings_object, kind, pattern, enabled);
    try package_settings_store.writeSettingsObject(allocator, io, settings_path, settings_object, settingsWriteOptions(options));

    const action_label: []const u8 = if (action == .enable) "Enabled" else "Disabled";
    try stdout.print("{s} {s}: {s}\n", .{ action_label, kind.settingsKey(), pattern });
    return .{ .exit_code = 0 };
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
    try common.putString(allocator, &entry_object, "source", persisted_source);
    if (install_metadata) |metadata| {
        try common.putValue(allocator, &entry_object, "installMetadata", try common.cloneJsonValue(allocator, metadata));
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

    try package_settings_store.writeSettingsObject(allocator, io, settings_path, settings_object, settingsWriteOptions(options));
    wrote_lock = false;
    const redacted_source = try redactDiagnosticValue(allocator, source);
    defer allocator.free(redacted_source);
    try stdout.print("Installed {s}\n", .{redacted_source});
    if (wasm_install == .valid) {
        try writeWasmInstallDetails(allocator, stdout, source, wasm_install.valid);
    }
    return .{ .exit_code = 0 };
}

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
    runtime_kind: []u8,
    package_root: []u8,
    artifact_absolute_path: []u8,
    artifact_sha256: []u8,
    artifact_os: ?[]u8 = null,
    artifact_arch: ?[]u8 = null,
    package_root_sha256: []u8,
    policy_lookup_key: []u8,
    policy_status: []u8,
    scope: []u8,
    trust_status: []u8,

    fn deinit(self: *WasmPackageListMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.extension_id);
        allocator.free(self.extension_version);
        allocator.free(self.tool_id);
        allocator.free(self.runtime_kind);
        allocator.free(self.package_root);
        allocator.free(self.artifact_absolute_path);
        allocator.free(self.artifact_sha256);
        if (self.artifact_os) |value| allocator.free(value);
        if (self.artifact_arch) |value| allocator.free(value);
        allocator.free(self.package_root_sha256);
        allocator.free(self.policy_lookup_key);
        allocator.free(self.policy_status);
        allocator.free(self.scope);
        allocator.free(self.trust_status);
        self.* = undefined;
    }
};

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

    const package_root_real = try package_sources.realpathOrResolved(allocator, package_root);
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
    try common.putValue(allocator, &entry, "key", .{ .string = key });
    try common.putString(allocator, &entry, "scope", if (is_project) "project" else "user");

    var source = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = source });
    try common.putString(allocator, &source, "type", if (isLocalSource(persisted_source)) "local" else "package");
    try common.putString(allocator, &source, "identity", package_root_real);
    try common.putString(allocator, &source, "specifier", persisted_source);
    try common.putString(allocator, &source, "inputSpecifier", input_source);
    try common.putValue(allocator, &entry, "source", .{ .object = source });

    try common.putString(allocator, &entry, "packageRoot", package_root_real);
    try common.putString(allocator, &entry, "manifestPath", if (manifest_text != null) manifest_path else package_root);

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
                try common.putString(allocator, &manifest, "kind", "pi-extension-package");
                try common.putString(allocator, &manifest, "schemaVersion", record.manifest.schema_version);
                try common.putString(allocator, &manifest, "id", record.manifest.id);
                try common.putString(allocator, &manifest, "name", record.manifest.name);
                try common.putString(allocator, &manifest, "version", record.manifest.version);
                try common.putString(allocator, &manifest, "runtime", record.manifest.runtime_kind.jsonName());
                try common.putString(allocator, &entry, "runtime", record.manifest.runtime_kind.jsonName());
                try common.putValue(allocator, &entry, "declarations", try installManifestDeclarationsValue(allocator, record.manifest));
                try common.putValue(allocator, &entry, "installGraph", try installGraphValue(allocator, manifest_set));
            } else {
                try common.putString(allocator, &manifest, "kind", "resource-package");
                try common.putString(allocator, &manifest, "schemaVersion", version);
            }
        } else {
            try common.putString(allocator, &manifest, "kind", "resource-package");
        }
    } else {
        try common.putString(allocator, &manifest, "kind", "resource-package");
    }
    try common.putValue(allocator, &entry, "manifest", .{ .object = manifest });

    var digests = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = digests });
    try common.putString(allocator, &digests, "packageRootSha256", package_root_sha256);
    if (manifest_text) |text| {
        const manifest_sha256 = try sha256HexAlloc(allocator, text);
        defer allocator.free(manifest_sha256);
        try common.putString(allocator, &digests, "manifestSha256", manifest_sha256);
    }
    try common.putValue(allocator, &entry, "digests", .{ .object = digests });
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
    try common.putValue(allocator, &declarations, "tools", try common.cloneJsonValue(allocator, manifest.tools));
    try common.putValue(allocator, &declarations, "hooks", try common.cloneJsonValue(allocator, manifest.hooks));
    try common.putValue(allocator, &declarations, "capabilities", try common.cloneJsonValue(allocator, manifest.capabilities));
    try common.putValue(allocator, &declarations, "permissions", try common.cloneJsonValue(allocator, manifest.permissions));
    try common.putValue(allocator, &declarations, "dependencies", try common.cloneJsonValue(allocator, manifest.dependencies));
    try common.putValue(allocator, &declarations, "workflows", try common.cloneJsonValue(allocator, manifest.workflows));
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
    const lock_path = try provenance_lockfile.lockfilePath(allocator, provenanceScope(is_project), options.cwd, options.agent_dir);
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
    try common.putString(allocator, &root, "schemaVersion", provenance_lockfile.LOCK_SCHEMA_VERSION);
    try common.putValue(allocator, &root, "entries", .{ .array = entries });
    const value = std.json.Value{ .object = root };
    defer common.deinitJsonValue(allocator, value);
    const serialized = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    try common.writeFileAbsolute(io, lock_path, serialized, true);
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
            if (native_manifest.isNativeDynamicManifestText(allocator, manifest_text)) {
                return validateLocalNativePackageForInstall(allocator, io, package_root, is_project, stderr);
            }
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

fn validateLocalNativePackageForInstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_root: []const u8,
    is_project: bool,
    stderr: *std.Io.Writer,
) !LocalWasmInstallValidation {
    var result = try native_manifest.validateManifestFile(allocator, io, package_root);
    defer result.deinit(allocator);
    if (result == .invalid) {
        try writeNativeValidationDiagnostics(allocator, stderr, result.invalid);
        return .invalid;
    }
    const source_identity = try allocator.dupe(u8, result.valid.package_root);
    defer allocator.free(source_identity);
    return .{ .valid = try provenance_lockfile.createNativeLockEntry(allocator, provenanceScope(is_project), source_identity, &result.valid) };
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
        if (record.manifest.runtime_kind == .native) {
            if (try packageNativeLibraryMissing(allocator, io, record, stderr)) accepted = false;
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

fn packageNativeLibraryMissing(
    allocator: std.mem.Allocator,
    io: std.Io,
    record: extension_manifest.ManifestRecord,
    stderr: *std.Io.Writer,
) !bool {
    const entrypoint = record.manifest.runtime_entrypoint;
    if (entrypoint != .object) return false;
    const dl = entrypoint.object.get("dynamic_library_path") orelse return false;
    if (dl != .string or dl.string.len == 0) return false;
    const lib_path = try std.fs.path.join(allocator, &.{ record.manifest.package_root, dl.string });
    defer allocator.free(lib_path);
    if (pathExists(io, lib_path)) return false;
    try stderr.print("Error: {s}: install.native_library_missing: dynamic library \"{s}\" not found for package \"{s}\"\n", .{
        record.manifest.manifest_path,
        lib_path,
        record.manifest.id,
    });
    return true;
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

fn policyLookupKeyFromLockEntry(
    allocator: std.mem.Allocator,
    entry: provenance_lockfile.LockEntry,
) ![]u8 {
    if (std.mem.eql(u8, entry.manifest_kind, "native-extension")) {
        return provenance_lockfile.nativePolicyLookupKeyFromLockEntry(allocator, entry);
    }
    return wasmPolicyLookupKeyFromLockEntry(allocator, entry);
}

fn runtimeNameFromLockEntry(entry: provenance_lockfile.LockEntry) []const u8 {
    if (std.mem.eql(u8, entry.manifest_kind, "native-extension")) return "native";
    return "wasm";
}

fn writeWasmInstallDetails(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    source: []const u8,
    entry: provenance_lockfile.LockEntry,
) !void {
    const policy_key = try policyLookupKeyFromLockEntry(allocator, entry);
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
    try stdout.print("  runtime: {s}\n", .{runtimeNameFromLockEntry(entry)});
    try stdout.writeAll("  trust: locked\n");
    try stdout.print("  source: {s}\n", .{redacted_source});
    try stdout.print("  package root: {s}\n", .{redacted_root});
    try stdout.print("  artifact: {s}\n", .{redacted_artifact});
    try stdout.print("  package root sha256: {s}\n", .{entry.package_root_sha256});
    if (entry.artifact_sha256) |artifact_sha256| {
        try stdout.print("  artifact sha256: {s}\n", .{artifact_sha256});
    }
    if (entry.artifact_os) |os| try stdout.print("  artifact os: {s}\n", .{os});
    if (entry.artifact_arch) |arch| try stdout.print("  artifact arch: {s}\n", .{arch});
    try stdout.print("  approval target: {s}\n", .{redacted_policy});
    try stdout.writeAll("  next: add a matching extensionPolicies entry before normal tool use.\n");
}

fn writeNativeValidationDiagnostics(
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
    diagnostics: []const native_manifest.Diagnostic,
) !void {
    if (diagnostics.len == 0) {
        try stderr.writeAll("Error: invalid native extension package\n");
        return;
    }
    for (diagnostics) |diagnostic| {
        const path = try redactDiagnosticValue(allocator, diagnostic.path);
        defer allocator.free(path);
        const message = try redactDiagnosticValue(allocator, diagnostic.message);
        defer allocator.free(message);
        try stderr.print("Error: native manifest {s}: {s}\n", .{ path, message });
    }
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

    var policy_cleanup = try collectPolicyCleanupForLocalSource(
        allocator,
        io,
        source,
        matched_source,
        command.local,
        options,
        scope,
        lockfile_path,
    );
    defer policy_cleanup.deinit(allocator);
    if (options.fail_policy_write_for_testing and hasMatchingExtensionPolicyEntry(settings_object, policy_cleanup)) {
        return error.InjectedPolicyWriteFailure;
    }
    _ = try removeMatchingExtensionPolicyEntries(allocator, &settings_object, policy_cleanup);

    const removed = packages_value_ptr.?.array.orderedRemove(matched_index.?);
    common.deinitJsonValue(allocator, removed);

    package_settings_store.writeSettingsObject(allocator, io, settings_path, settings_object, settingsWriteOptions(options)) catch |err| {
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

const PolicyCleanupPlan = struct {
    exact_keys: std.ArrayList([]u8) = .empty,
    native_prefixes: std.ArrayList([]u8) = .empty,

    fn deinit(self: *PolicyCleanupPlan, allocator: std.mem.Allocator) void {
        package_settings_store.freeOwnedStrings(allocator, &self.exact_keys);
        package_settings_store.freeOwnedStrings(allocator, &self.native_prefixes);
        self.* = undefined;
    }
};

fn collectPolicyCleanupForLocalSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_source: []const u8,
    matched_source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
    scope: ProvenanceScope,
    lockfile_path: []const u8,
) !PolicyCleanupPlan {
    var plan = PolicyCleanupPlan{};
    errdefer plan.deinit(allocator);
    try appendPolicyCleanupForSource(allocator, io, &plan, input_source, is_project, options, .input, scope, lockfile_path);
    if (!std.mem.eql(u8, input_source, matched_source)) {
        try appendPolicyCleanupForSource(allocator, io, &plan, matched_source, is_project, options, .settings, scope, lockfile_path);
    }
    return plan;
}

fn appendPolicyCleanupForSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    plan: *PolicyCleanupPlan,
    source: []const u8,
    is_project: bool,
    options: ExecuteOptions,
    mode: LocalPathMode,
    scope: ProvenanceScope,
    lockfile_path: []const u8,
) !void {
    var entry = try lockedLocalWasmEntryForSource(allocator, io, source, is_project, options, mode, scope, lockfile_path);
    defer if (entry) |*locked| locked.deinit(allocator);
    if (entry == null) return;
    const exact_key = try policyLookupKeyFromLockEntry(allocator, entry.?);
    errdefer allocator.free(exact_key);
    try appendUniqueOwnedString(allocator, &plan.exact_keys, exact_key);
    if (std.mem.eql(u8, entry.?.manifest_kind, "native-extension")) {
        const prefix = try nativePolicyLookupPrefixFromLockEntry(allocator, entry.?);
        errdefer allocator.free(prefix);
        try appendUniqueOwnedString(allocator, &plan.native_prefixes, prefix);
    }
}

fn appendUniqueOwnedString(allocator: std.mem.Allocator, list: *std.ArrayList([]u8), owned: []u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, owned)) {
            allocator.free(owned);
            return;
        }
    }
    try list.append(allocator, owned);
}

fn nativePolicyLookupPrefixFromLockEntry(
    allocator: std.mem.Allocator,
    entry: provenance_lockfile.LockEntry,
) ![]u8 {
    const schema_version = entry.manifest_schema_version orelse native_manifest.SCHEMA_VERSION;
    const extension_id = entry.manifest_id orelse "";
    const extension_version = entry.manifest_version orelse "";
    return std.fmt.allocPrint(
        allocator,
        "native:locked:{s}:{s}:{s}:{s}:{s}:native:",
        .{
            entry.scope.jsonName(),
            entry.source_identity,
            schema_version,
            extension_id,
            extension_version,
        },
    );
}

fn policyKeyMatchesCleanup(key: []const u8, plan: PolicyCleanupPlan) bool {
    for (plan.exact_keys.items) |exact| {
        if (std.mem.eql(u8, key, exact)) return true;
    }
    for (plan.native_prefixes.items) |prefix| {
        if (std.mem.startsWith(u8, key, prefix)) return true;
    }
    return false;
}

fn hasMatchingExtensionPolicyEntry(settings_object: std.json.ObjectMap, plan: PolicyCleanupPlan) bool {
    const policies_value = settings_object.get("extensionPolicies") orelse return false;
    if (policies_value != .object) return false;
    var iterator = policies_value.object.iterator();
    while (iterator.next()) |entry| {
        if (policyKeyMatchesCleanup(entry.key_ptr.*, plan)) return true;
    }
    return false;
}

fn removeMatchingExtensionPolicyEntries(
    allocator: std.mem.Allocator,
    settings_object: *std.json.ObjectMap,
    plan: PolicyCleanupPlan,
) !usize {
    const policies_value = settings_object.getPtr("extensionPolicies") orelse return 0;
    if (policies_value.* != .object) return 0;

    var replacement = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup: std.json.Value = .{ .object = replacement };
        common.deinitJsonValue(allocator, cleanup);
    }

    var removed_count: usize = 0;
    var iterator = policies_value.object.iterator();
    while (iterator.next()) |entry| {
        if (policyKeyMatchesCleanup(entry.key_ptr.*, plan)) {
            removed_count += 1;
            continue;
        }
        try replacement.put(
            allocator,
            try allocator.dupe(u8, entry.key_ptr.*),
            try common.cloneJsonValue(allocator, entry.value_ptr.*),
        );
    }

    const old = policies_value.*;
    policies_value.* = .{ .object = replacement };
    common.deinitJsonValue(allocator, old);
    return removed_count;
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
    const self_update_options = selfUpdateOptions(options);

    switch (target) {
        .all => {
            const extensions_result = try executeExtensionUpdates(allocator, io, options, null, stderr);
            if (extensions_result.exit_code != 0) return extensions_result;
            try stdout.print("Updated packages\n", .{});
            return self_update.executeSelfUpdate(allocator, io, command.force, self_update_options, stdout, stderr);
        },
        .self => {
            return self_update.executeSelfUpdate(allocator, io, command.force, self_update_options, stdout, stderr);
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

fn selfUpdateOptions(options: ExecuteOptions) self_update.ExecuteOptions {
    return .{
        .self_update_command_override = options.self_update_command_override,
        .self_update_method_override = options.self_update_method_override,
        .self_update_latest_release_override = options.self_update_latest_release_override,
        .self_update_latest_release_probe = options.self_update_latest_release_probe,
        .current_version = options.current_version,
    };
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
    defer package_settings_store.freeOwnedStrings(allocator, &user_sources);
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
    defer package_settings_store.freeOwnedStrings(allocator, &project_sources);
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

const package_name = self_update.package_name;

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
    try stdout.print("    runtime: {s}\n", .{metadata.runtime_kind});
    try stdout.print("    trust: {s}\n", .{metadata.trust_status});
    try stdout.print("    extension: {s}@{s}\n", .{ metadata.extension_id, metadata.extension_version });
    try stdout.print("    tool: {s}\n", .{metadata.tool_id});
    try stdout.print("    package root: {s}\n", .{redacted_root});
    try stdout.print("    artifact: {s}\n", .{redacted_artifact});
    if (metadata.artifact_os) |os| try stdout.print("    artifact os: {s}\n", .{os});
    if (metadata.artifact_arch) |arch| try stdout.print("    artifact arch: {s}\n", .{arch});
    try stdout.print("    package root sha256: {s}\n", .{metadata.package_root_sha256});
    try stdout.print("    artifact sha256: {s}\n", .{metadata.artifact_sha256});
    try stdout.print("    policy: {s}\n", .{metadata.policy_status});
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
        if (entry.manifest_kind.len == 0 or !(std.mem.eql(u8, entry.manifest_kind, "wasm-extension") or std.mem.eql(u8, entry.manifest_kind, "native-extension"))) return null;
        const policy_key = try policyLookupKeyFromLockEntry(allocator, entry);
        errdefer allocator.free(policy_key);
        const policy_status = try localPackagePolicyStatusForList(allocator, io, options, policy_key);
        errdefer allocator.free(policy_status);
        const trust_status = try localWasmTrustStatusForList(allocator, io, options, source, is_project, entry);
        errdefer allocator.free(trust_status);
        return .{
            .extension_id = try allocator.dupe(u8, entry.manifest_id orelse "<unknown>"),
            .extension_version = try allocator.dupe(u8, entry.manifest_version orelse "<unknown>"),
            .tool_id = try allocator.dupe(u8, entry.manifest_tool_id orelse "<unknown>"),
            .runtime_kind = try allocator.dupe(u8, runtimeNameFromLockEntry(entry)),
            .package_root = try allocator.dupe(u8, entry.package_root),
            .artifact_absolute_path = try allocator.dupe(u8, entry.artifact_absolute_path orelse ""),
            .artifact_sha256 = try allocator.dupe(u8, entry.artifact_sha256 orelse ""),
            .artifact_os = if (entry.artifact_os) |value| try allocator.dupe(u8, value) else null,
            .artifact_arch = if (entry.artifact_arch) |value| try allocator.dupe(u8, value) else null,
            .package_root_sha256 = try allocator.dupe(u8, entry.package_root_sha256),
            .policy_lookup_key = policy_key,
            .policy_status = policy_status,
            .scope = try allocator.dupe(u8, entry.scope.jsonName()),
            .trust_status = trust_status,
        };
    }
    return null;
}

fn localPackagePolicyStatusForList(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ExecuteOptions,
    policy_key: []const u8,
) ![]u8 {
    var effective_settings = try loadEffectiveSettingsForPackageInstall(allocator, io, options);
    defer effective_settings.deinit(allocator);
    const policy = lookupExtensionPolicy(effective_settings, policy_key) orelse return allocator.dupe(u8, "denied");
    if (policy.enabled) |enabled| if (!enabled) return allocator.dupe(u8, "denied");
    if (policy.approved) |approved| if (!approved) return allocator.dupe(u8, "denied");
    return allocator.dupe(u8, "authorized");
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
    const manifest_text = std.Io.Dir.readFileAlloc(.cwd(), io, manifest_path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return err,
    };
    defer allocator.free(manifest_text);

    if (native_manifest.isNativeDynamicManifestText(allocator, manifest_text)) {
        var native_result = try native_manifest.validateManifestText(allocator, package_root, manifest_text);
        defer native_result.deinit(allocator);
        if (native_result == .invalid) return .invalid;
        const source_identity = try allocator.dupe(u8, native_result.valid.package_root);
        defer allocator.free(source_identity);
        return .{ .valid = try provenance_lockfile.createNativeLockEntry(allocator, provenanceScope(is_project), source_identity, &native_result.valid) };
    }

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

test {
    _ = @import("package_manager/tests.zig");
}
