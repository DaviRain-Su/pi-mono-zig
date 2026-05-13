const std = @import("std");
const common = @import("../../tools/common.zig");
const config_selector = @import("../config_selector.zig");
const extension_manifest = @import("../../extensions/extension_manifest.zig");
const extension_runtime = @import("../../extensions/extension_runtime.zig");
const native_manifest = @import("../../extensions/native/native_manifest.zig");
const package_manager = @import("../package_manager.zig");
const package_settings_store = @import("../package_settings_store.zig");
const package_sources = @import("../package_sources.zig");
const policy_key_mod = @import("../../extensions/policy_key.zig");
const provenance_lockfile = @import("../provenance_lockfile.zig");
const resources_mod = @import("../../resources/resources.zig");
const self_update = @import("../self_update.zig");
const wasm_manifest = @import("../../extensions/wasm/wasm_manifest.zig");

const ConfigSelectorState = config_selector.ConfigSelectorState;
const ExecuteOptions = package_manager.ExecuteOptions;
const ExecuteResult = package_manager.ExecuteResult;
const executePackageCommand = package_manager.executePackageCommand;
const gitInstallPath = package_sources.gitInstallPath;
const loadSelectorState = config_selector.loadSelectorState;
const loadSettingsObject = package_settings_store.loadSettingsObject;
const normalizePackageSourceForSettings = package_sources.normalizePackageSourceForSettings;
const package_name = self_update.package_name;
const parsePackageCommand = package_manager.parsePackageCommand;
const saveSelectorState = config_selector.saveSelectorState;

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

fn nativeTestHostOs() []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .macos => "macos",
        .windows => "windows",
        else => "linux",
    };
}

fn nativeTestHostArch() []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => @tagName(builtin.cpu.arch),
    };
}

fn nativeTestLibrarySuffix() []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .macos => ".dylib",
        .windows => ".dll",
        else => ".so",
    };
}

fn writeNativeDynamicPackageFixture(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    package_relative_path: []const u8,
    package_id: []const u8,
    tool_name: []const u8,
    artifact_bytes: []const u8,
) ![]u8 {
    const native_dir = try std.fs.path.join(allocator, &.{ package_relative_path, "native" });
    defer allocator.free(native_dir);
    try tmp.dir.createDirPath(std.testing.io, native_dir);
    const artifact_rel = try std.fmt.allocPrint(allocator, "native/plugin{s}", .{nativeTestLibrarySuffix()});
    errdefer allocator.free(artifact_rel);
    const artifact_sub_path = try std.fs.path.join(allocator, &.{ package_relative_path, artifact_rel });
    defer allocator.free(artifact_sub_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = artifact_sub_path, .data = artifact_bytes });

    const manifest = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": "pi-extension.v1",
        \\  "id": "{s}",
        \\  "name": "Native Dynamic Fixture",
        \\  "version": "0.1.0",
        \\  "description": "Native dynamic package fixture.",
        \\  "runtime": {{
        \\    "kind": "native",
        \\    "entrypoint": {{ "descriptor": "native://dynamic/{s}" }},
        \\    "limits": {{ "timeoutMs": 1000, "outputBytes": 4096, "toolScopes": ["{s}"] }}
        \\  }},
        \\  "artifacts": [
        \\    {{ "kind": "native-dynamic", "os": "{s}", "arch": "{s}", "path": "{s}" }}
        \\  ],
        \\  "tools": [
        \\    {{ "name": "{s}", "description": "Native fixture tool.", "inputSchema": {{}}, "outputSchema": {{}} }}
        \\  ],
        \\  "capabilities": {{ "exports": [{{ "id": "{s}", "kind": "tool", "version": "0.1.0" }}], "imports": [] }},
        \\  "permissions": [{{ "id": "file.read" }}]
        \\}}
    , .{ package_id, package_id, tool_name, nativeTestHostOs(), nativeTestHostArch(), artifact_rel, tool_name, tool_name });
    defer allocator.free(manifest);
    const manifest_path = try std.fs.path.join(allocator, &.{ package_relative_path, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = manifest });
    return artifact_rel;
}

fn addPolicyToSettings(
    allocator: std.mem.Allocator,
    settings_path: []const u8,
    policy_key: []const u8,
    approved_grant: []const u8,
) !void {
    var settings_object = try loadSettingsObject(allocator, std.testing.io, settings_path);
    defer {
        const cleanup: std.json.Value = .{ .object = settings_object };
        common.deinitJsonValue(allocator, cleanup);
    }

    const policies_ptr = blk: {
        if (settings_object.getPtr("extensionPolicies")) |existing| {
            if (existing.* == .object) break :blk &existing.object;
            const old = existing.*;
            existing.* = .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
            common.deinitJsonValue(allocator, old);
            break :blk &existing.object;
        }
        try settings_object.put(
            allocator,
            try allocator.dupe(u8, "extensionPolicies"),
            .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) },
        );
        break :blk &settings_object.getPtr("extensionPolicies").?.object;
    };

    var approved_grants = std.json.Array.init(allocator);
    errdefer common.deinitJsonValue(allocator, .{ .array = approved_grants });
    try approved_grants.append(.{ .string = try allocator.dupe(u8, approved_grant) });

    var policy = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = policy });
    try common.putValue(allocator, &policy, "approvedGrants", .{ .array = approved_grants });
    try policies_ptr.put(
        allocator,
        try allocator.dupe(u8, policy_key),
        .{ .object = policy },
    );

    try package_settings_store.writeSettingsObject(allocator, std.testing.io, settings_path, settings_object, .{});
}

fn nativePolicyKeyForPackage(
    allocator: std.mem.Allocator,
    package_root: []const u8,
    scope: provenance_lockfile.Scope,
) ![]u8 {
    var manifest_result = try native_manifest.validateManifestFile(allocator, std.testing.io, package_root);
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    var lock_entry = try provenance_lockfile.createNativeLockEntry(allocator, scope, manifest_result.valid.package_root, &manifest_result.valid);
    defer lock_entry.deinit(allocator);
    return provenance_lockfile.nativePolicyLookupKeyFromLockEntry(allocator, lock_entry);
}

test "native dynamic package install validates artifact schema and writes selected artifact provenance" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/native-dynamic/native");
    const artifact_rel = try std.fmt.allocPrint(allocator, "native/plugin{s}", .{nativeTestLibrarySuffix()});
    defer allocator.free(artifact_rel);
    const artifact_sub_path = try std.fs.path.join(allocator, &.{ "repo/fixtures/native-dynamic", artifact_rel });
    defer allocator.free(artifact_sub_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = artifact_sub_path, .data = "native-dynamic-bytes" });

    const manifest = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": "pi-extension.v1",
        \\  "id": "com.example.native-dynamic",
        \\  "name": "Native Dynamic",
        \\  "version": "0.1.0",
        \\  "description": "Native dynamic package.",
        \\  "runtime": {{
        \\    "kind": "native",
        \\    "entrypoint": {{ "descriptor": "native://dynamic/com.example.native-dynamic" }},
        \\    "limits": {{ "timeoutMs": 1000, "outputBytes": 4096, "toolScopes": ["native.echo"] }}
        \\  }},
        \\  "artifacts": [
        \\    {{ "kind": "native-dynamic", "os": "{s}", "arch": "{s}", "path": "{s}" }}
        \\  ],
        \\  "tools": [
        \\    {{ "name": "native.echo", "description": "Echo.", "inputSchema": {{}}, "outputSchema": {{}} }}
        \\  ],
        \\  "capabilities": {{ "exports": [{{ "id": "native.echo", "kind": "tool", "version": "0.1.0" }}], "imports": [] }},
        \\  "permissions": [{{ "id": "file.read" }}]
        \\}}
    , .{ nativeTestHostOs(), nativeTestHostArch(), artifact_rel });
    defer allocator.free(manifest);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/fixtures/native-dynamic/pi-extension.json", .data = manifest });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const install_result = try runCommand(allocator, &.{ "install", "./fixtures/native-dynamic" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), install_result.exit_code);
    try std.testing.expectEqualStrings("", stderr_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Installed ./fixtures/native-dynamic") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "runtime: native") != null);
    const expected_stdout_os = try std.fmt.allocPrint(allocator, "artifact os: {s}", .{nativeTestHostOs()});
    defer allocator.free(expected_stdout_os);
    const expected_stdout_arch = try std.fmt.allocPrint(allocator, "artifact arch: {s}", .{nativeTestHostArch()});
    defer allocator.free(expected_stdout_arch);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, expected_stdout_os) != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, expected_stdout_arch) != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "approval target: native:locked:user:") != null);

    const lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(lockfile_path);
    const lockfile = try readSettings(allocator, lockfile_path);
    defer allocator.free(lockfile);
    try std.testing.expect(std.mem.indexOf(u8, lockfile, "\"kind\": \"native-extension\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lockfile, "\"kind\": \"native-dynamic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, lockfile, "\"manifestSha256\"") != null);
    const expected_lock_os = try std.fmt.allocPrint(allocator, "\"os\": \"{s}\"", .{nativeTestHostOs()});
    defer allocator.free(expected_lock_os);
    const expected_lock_arch = try std.fmt.allocPrint(allocator, "\"arch\": \"{s}\"", .{nativeTestHostArch()});
    defer allocator.free(expected_lock_arch);
    try std.testing.expect(std.mem.indexOf(u8, lockfile, expected_lock_os) != null);
    try std.testing.expect(std.mem.indexOf(u8, lockfile, expected_lock_arch) != null);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const list_result = try runCommand(allocator, &.{"list"}, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), list_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "runtime: native") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "trust: locked") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "policy: denied") != null);
}

test "native dynamic package install rejects missing selected artifacts without state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/native-missing/native");
    const artifact_rel = try std.fmt.allocPrint(allocator, "native/missing{s}", .{nativeTestLibrarySuffix()});
    defer allocator.free(artifact_rel);
    const manifest = try std.fmt.allocPrint(allocator,
        \\{{"schemaVersion":"pi-extension.v1","id":"com.example.native-missing","name":"Native Missing","version":"0.1.0","runtime":{{"kind":"native","entrypoint":{{"descriptor":"native://dynamic/com.example.native-missing"}}}},"artifacts":[{{"kind":"native-dynamic","os":"{s}","arch":"{s}","path":"{s}"}}],"tools":[{{"name":"native.echo","inputSchema":{{}},"outputSchema":{{}}}}],"capabilities":{{"exports":[],"imports":[]}}}}
    , .{ nativeTestHostOs(), nativeTestHostArch(), artifact_rel });
    defer allocator.free(manifest);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/fixtures/native-missing/pi-extension.json", .data = manifest });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/native-missing" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expectEqualStrings("", stdout_buf.items);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "artifact file was not found") != null);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), std.testing.io, settings_path, .{}));
    const lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(lockfile_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), std.testing.io, lockfile_path, .{}));
}

test "VAL-NATIVE-PKG-015-016 native update refreshes explicitly and failed update preserves lock" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    const artifact_rel = try writeNativeDynamicPackageFixture(
        allocator,
        &tmp,
        "repo/fixtures/native-update",
        "com.example.native-update",
        "native.update",
        "native-v1",
    );
    defer allocator.free(artifact_rel);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const package_root = try std.fs.path.join(allocator, &.{ cwd, "fixtures/native-update" });
    defer allocator.free(package_root);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const initial_policy_key = try nativePolicyKeyForPackage(allocator, package_root, .user);
    defer allocator.free(initial_policy_key);
    try addPolicyToSettings(allocator, settings_path, initial_policy_key, "file.read");

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const install_result = try runCommand(allocator, &.{ "install", "./fixtures/native-update" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), install_result.exit_code);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    const lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(lockfile_path);
    const lock_before_drift = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_before_drift);

    const artifact_path = try std.fs.path.join(allocator, &.{ package_root, artifact_rel });
    defer allocator.free(artifact_path);
    try common.writeFileAbsolute(std.testing.io, artifact_path, "native-v2", true);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const list_drift = try runCommand(allocator, &.{"list"}, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), list_drift.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "runtime: native") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "trust: drifted") != null);
    const lock_after_list = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after_list);
    try std.testing.expectEqualStrings(lock_before_drift, lock_after_list);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const reinstall_result = try runCommand(allocator, &.{ "install", "./fixtures/native-update" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), reinstall_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "pi update --extension") != null);
    const lock_after_reinstall = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after_reinstall);
    try std.testing.expectEqualStrings(lock_before_drift, lock_after_reinstall);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const update_result = try runCommand(allocator, &.{ "update", "--extension", "./fixtures/native-update" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), update_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Updated ./fixtures/native-update") != null);
    const lock_after_update = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after_update);
    try std.testing.expect(!std.mem.eql(u8, lock_before_drift, lock_after_update));

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const list_after_update = try runCommand(allocator, &.{"list"}, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), list_after_update.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "trust: locked") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "policy: denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, initial_policy_key) == null);

    try std.Io.Dir.deleteFileAbsolute(std.testing.io, artifact_path);
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const failed_update = try runCommand(allocator, &.{ "update", "--extension", "./fixtures/native-update" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), failed_update.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "artifact file was not found") != null);
    const lock_after_failed_update = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after_failed_update);
    try std.testing.expectEqualStrings(lock_after_update, lock_after_failed_update);
}

test "VAL-NATIVE-PKG-017-018-033-034 native remove after drift clears scoped lock and stale policies" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    const target_artifact_rel = try writeNativeDynamicPackageFixture(
        allocator,
        &tmp,
        "repo/fixtures/native-remove",
        "com.example.native-remove",
        "native.remove",
        "native-remove-v1",
    );
    defer allocator.free(target_artifact_rel);
    const other_artifact_rel = try writeNativeDynamicPackageFixture(
        allocator,
        &tmp,
        "repo/fixtures/native-other",
        "com.example.native-other",
        "native.other",
        "native-other-v1",
    );
    defer allocator.free(other_artifact_rel);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const target_root = try std.fs.path.join(allocator, &.{ cwd, "fixtures/native-remove" });
    defer allocator.free(target_root);
    const other_root = try std.fs.path.join(allocator, &.{ cwd, "fixtures/native-other" });
    defer allocator.free(other_root);
    const target_initial_policy = try nativePolicyKeyForPackage(allocator, target_root, .user);
    defer allocator.free(target_initial_policy);
    const other_policy = try nativePolicyKeyForPackage(allocator, other_root, .user);
    defer allocator.free(other_policy);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    _ = try runCommand(allocator, &.{ "install", "./fixtures/native-remove" }, options, &stdout_buf, &stderr_buf);
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    _ = try runCommand(allocator, &.{ "install", "./fixtures/native-other" }, options, &stdout_buf, &stderr_buf);
    try addPolicyToSettings(allocator, settings_path, target_initial_policy, "file.read");
    try addPolicyToSettings(allocator, settings_path, other_policy, "file.read");

    const target_artifact_path = try std.fs.path.join(allocator, &.{ target_root, target_artifact_rel });
    defer allocator.free(target_artifact_path);
    try common.writeFileAbsolute(std.testing.io, target_artifact_path, "native-remove-v2", true);
    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const update_result = try runCommand(allocator, &.{ "update", "--extension", "./fixtures/native-remove" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), update_result.exit_code);
    const target_updated_policy = try nativePolicyKeyForPackage(allocator, target_root, .user);
    defer allocator.free(target_updated_policy);
    try std.testing.expect(!std.mem.eql(u8, target_initial_policy, target_updated_policy));

    try common.writeFileAbsolute(std.testing.io, target_artifact_path, "native-remove-v3-drift", true);
    const lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(lockfile_path);
    const lock_before_remove = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_before_remove);
    try std.testing.expect(std.mem.indexOf(u8, lock_before_remove, "com.example.native-remove") != null);
    try std.testing.expect(std.mem.indexOf(u8, lock_before_remove, "com.example.native-other") != null);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const remove_result = try runCommand(allocator, &.{ "remove", "./fixtures/native-remove" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), remove_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Removed ./fixtures/native-remove") != null);
    try std.testing.expectEqualStrings("", stderr_buf.items);

    const settings_after_remove = try readSettings(allocator, settings_path);
    defer allocator.free(settings_after_remove);
    try std.testing.expect(std.mem.indexOf(u8, settings_after_remove, "native-remove") == null);
    try std.testing.expect(std.mem.indexOf(u8, settings_after_remove, target_initial_policy) == null);
    try std.testing.expect(std.mem.indexOf(u8, settings_after_remove, target_updated_policy) == null);
    try std.testing.expect(std.mem.indexOf(u8, settings_after_remove, "native-other") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings_after_remove, other_policy) != null);

    const lock_after_remove = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after_remove);
    try std.testing.expect(std.mem.indexOf(u8, lock_after_remove, "com.example.native-remove") == null);
    try std.testing.expect(std.mem.indexOf(u8, lock_after_remove, "com.example.native-other") != null);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const reinstall_result = try runCommand(allocator, &.{ "install", "./fixtures/native-remove" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), reinstall_result.exit_code);
    const target_reinstall_policy = try nativePolicyKeyForPackage(allocator, target_root, .user);
    defer allocator.free(target_reinstall_policy);
    try std.testing.expect(!std.mem.eql(u8, target_updated_policy, target_reinstall_policy));

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    const list_after_reinstall = try runCommand(allocator, &.{"list"}, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), list_after_reinstall.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "runtime: native") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "policy: denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, target_initial_policy) == null);
}

test "VAL-NATIVE-PKG-037 native lifecycle write failures preserve settings lock and policy atomically" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    const artifact_a = try writeNativeDynamicPackageFixture(
        allocator,
        &tmp,
        "repo/fixtures/native-atomic-a",
        "com.example.native-atomic-a",
        "native.atomicA",
        "native-atomic-a",
    );
    defer allocator.free(artifact_a);
    const artifact_b = try writeNativeDynamicPackageFixture(
        allocator,
        &tmp,
        "repo/fixtures/native-atomic-b",
        "com.example.native-atomic-b",
        "native.atomicB",
        "native-atomic-b",
    );
    defer allocator.free(artifact_b);

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    const install_a = try runCommand(allocator, &.{ "install", "./fixtures/native-atomic-a" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), install_a.exit_code);

    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const package_root_a = try std.fs.path.join(allocator, &.{ cwd, "fixtures/native-atomic-a" });
    defer allocator.free(package_root_a);
    const policy_key_a = try nativePolicyKeyForPackage(allocator, package_root_a, .user);
    defer allocator.free(policy_key_a);
    try addPolicyToSettings(allocator, settings_path, policy_key_a, "file.read");
    const lockfile_path = try lockfilePathForTest(allocator, cwd, agent_dir, false);
    defer allocator.free(lockfile_path);

    const settings_before = try readSettings(allocator, settings_path);
    defer allocator.free(settings_before);
    const lock_before = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_before);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    var fail_settings_options = options;
    fail_settings_options.fail_settings_write_for_testing = true;
    try std.testing.expectError(
        error.InjectedSettingsWriteFailure,
        runCommand(allocator, &.{ "install", "./fixtures/native-atomic-b" }, fail_settings_options, &stdout_buf, &stderr_buf),
    );
    const settings_after_failed_install = try readSettings(allocator, settings_path);
    defer allocator.free(settings_after_failed_install);
    const lock_after_failed_install = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after_failed_install);
    try std.testing.expectEqualStrings(settings_before, settings_after_failed_install);
    try std.testing.expectEqualStrings(lock_before, lock_after_failed_install);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    var fail_lock_options = options;
    fail_lock_options.fail_lockfile_write_for_testing = true;
    const failed_lock_remove = try runCommand(allocator, &.{ "remove", "./fixtures/native-atomic-a" }, fail_lock_options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), failed_lock_remove.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "InjectedLockfileWriteFailure") != null);
    const settings_after_failed_lock = try readSettings(allocator, settings_path);
    defer allocator.free(settings_after_failed_lock);
    const lock_after_failed_lock = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after_failed_lock);
    try std.testing.expectEqualStrings(settings_before, settings_after_failed_lock);
    try std.testing.expectEqualStrings(lock_before, lock_after_failed_lock);

    stdout_buf.clearRetainingCapacity();
    stderr_buf.clearRetainingCapacity();
    var fail_policy_options = options;
    fail_policy_options.fail_policy_write_for_testing = true;
    try std.testing.expectError(
        error.InjectedPolicyWriteFailure,
        runCommand(allocator, &.{ "remove", "./fixtures/native-atomic-a" }, fail_policy_options, &stdout_buf, &stderr_buf),
    );
    const settings_after_failed_policy = try readSettings(allocator, settings_path);
    defer allocator.free(settings_after_failed_policy);
    const lock_after_failed_policy = try readSettings(allocator, lockfile_path);
    defer allocator.free(lock_after_failed_policy);
    try std.testing.expectEqualStrings(settings_before, settings_after_failed_policy);
    try std.testing.expectEqualStrings(lock_before, lock_after_failed_policy);
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

test "native extension install rejects missing dynamic_library_path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const manifest_text =
        \\{ "schemaVersion": "pi-extension.v1", "id": "com.example.native-missing", "name": "Native Missing", "version": "1.0.0", "description": "Missing lib.", "runtime": { "kind": "native", "entrypoint": { "dynamic_library_path": "libmissing.dylib" } }, "tools": [{ "name": "missing.tool", "description": "T", "inputSchema": { "type": "object" } }], "permissions": [] }
    ;
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/native-missing");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/fixtures/native-missing/pi-extension.json", .data = manifest_text });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/native-missing" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "native_library_missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_buf.items, "libmissing.dylib") != null);
}

test "native extension install succeeds when dynamic_library_path exists" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    const manifest_text =
        \\{ "schemaVersion": "pi-extension.v1", "id": "com.example.native-present", "name": "Native Present", "version": "1.0.0", "description": "Present lib.", "runtime": { "kind": "native", "entrypoint": { "dynamic_library_path": "libpresent.dylib" } }, "tools": [{ "name": "present.tool", "description": "T", "inputSchema": { "type": "object" } }], "permissions": [] }
    ;
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/native-present");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/fixtures/native-present/pi-extension.json", .data = manifest_text });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/fixtures/native-present/libpresent.dylib", .data = "native" });

    const cwd = try makeAbsoluteTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeAbsoluteTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const options = ExecuteOptions{ .cwd = cwd, .agent_dir = agent_dir };

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    const result = try runCommand(allocator, &.{ "install", "./fixtures/native-present" }, options, &stdout_buf, &stderr_buf);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_buf.items, "Installed") != null);
}
