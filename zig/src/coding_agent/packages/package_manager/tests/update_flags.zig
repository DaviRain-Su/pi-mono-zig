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
