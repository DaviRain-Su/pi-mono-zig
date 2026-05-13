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
