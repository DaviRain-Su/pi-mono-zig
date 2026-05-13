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
