const c = @import("common.zig");
const std = c.std;
const common = c.common;
const config_selector = c.config_selector;
const extension_manifest = c.extension_manifest;
const extension_runtime = c.extension_runtime;
const native_manifest = c.native_manifest;
const package_manager = c.package_manager;
const package_settings_store = c.package_settings_store;
const package_sources = c.package_sources;
const policy_key_mod = c.policy_key_mod;
const provenance_lockfile = c.provenance_lockfile;
const resources_mod = c.resources_mod;
const self_update = c.self_update;
const wasm_manifest = c.wasm_manifest;

const ConfigSelectorState = c.ConfigSelectorState;
const ExecuteOptions = c.ExecuteOptions;
const ExecuteResult = c.ExecuteResult;
const executePackageCommand = c.executePackageCommand;
const gitInstallPath = c.gitInstallPath;
const loadSelectorState = c.loadSelectorState;
const loadSettingsObject = c.loadSettingsObject;
const normalizePackageSourceForSettings = c.normalizePackageSourceForSettings;
const package_name = c.package_name;
const parsePackageCommand = c.parsePackageCommand;
const saveSelectorState = c.saveSelectorState;

const makeAbsoluteTmpPath = c.makeAbsoluteTmpPath;
const readSettings = c.readSettings;
const readOptionalTestFile = c.readOptionalTestFile;
const lockfilePathForTest = c.lockfilePathForTest;
const readFirstPackageSource = c.readFirstPackageSource;
const runCommand = c.runCommand;
const fakeNetworkOptions = c.fakeNetworkOptions;
const makeSelfUpdateRecorderScript = c.makeSelfUpdateRecorderScript;
const readSelfUpdateLog = c.readSelfUpdateLog;
const writeWasmPackageFixture = c.writeWasmPackageFixture;
const writePolicySettings = c.writePolicySettings;
const writePolicySettingsGrantList = c.writePolicySettingsGrantList;

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
