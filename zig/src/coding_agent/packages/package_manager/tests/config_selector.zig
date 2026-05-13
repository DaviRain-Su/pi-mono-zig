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
