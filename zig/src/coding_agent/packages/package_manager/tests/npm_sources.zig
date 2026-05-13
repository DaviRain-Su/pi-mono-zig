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
