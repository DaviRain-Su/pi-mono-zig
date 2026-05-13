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
