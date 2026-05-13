const common = @import("common.zig");

const std = common.std;
const ai = common.ai;
const agent = common.agent;
const cli = common.cli;
const bootstrap = common.bootstrap;
const input_prep = common.input_prep;
const runtime_prep = common.runtime_prep;
const cli_test = common.cli_test;
const main = common.main;
const coding_agent = common.coding_agent;
const config_mod = common.config_mod;
const resources_mod = common.resources_mod;
const tools_common = common.tools_common;
const extension_runtime = common.extension_runtime;
const tool_adapters = common.tool_adapters;
const json_event_wire = common.json_event_wire;
const json_format = common.json_format;

const writeJsonStringValue = common.writeJsonStringValue;
const CliStdin = common.CliStdin;
const VERSION = common.VERSION;
const effectiveToolSelection = common.effectiveToolSelection;
const prepareCliRuntime = common.prepareCliRuntime;
const prepareEffectiveEnvMap = common.prepareEffectiveEnvMap;
const runCli = common.runCli;
const runCliWithInput = common.runCliWithInput;
const startupNetworkOperationsEnabled = common.startupNetworkOperationsEnabled;
const LifecyclePackageFixture = common.LifecyclePackageFixture;
const readSettingsPackageSources = common.readSettingsPackageSources;
const freeOwnedStringSlice = common.freeOwnedStringSlice;
const expectInstalledPackageSources = common.expectInstalledPackageSources;
const settingsWithInstalledPackagePolicies = common.settingsWithInstalledPackagePolicies;
const temporaryTypeScriptPolicyKey = common.temporaryTypeScriptPolicyKey;
const settingsWithTemporaryExtensionPolicies = common.settingsWithTemporaryExtensionPolicies;
const expectPackageConfigSources = common.expectPackageConfigSources;
const expectLoadedExtensionsMatchInstalledPackages = common.expectLoadedExtensionsMatchInstalledPackages;
const loadedExtensionForSource = common.loadedExtensionForSource;
const expectLoadedExtensionManifestMetadata = common.expectLoadedExtensionManifestMetadata;
const expectRegistrySnapshotsMatchLoadedPackages = common.expectRegistrySnapshotsMatchLoadedPackages;
const expectInstallLockSettingsMetadataMatchesLoadedRegistry = common.expectInstallLockSettingsMetadataMatchesLoadedRegistry;
const settingsPackageEntry = common.settingsPackageEntry;
const lockEntryForKey = common.lockEntryForKey;
const packageSnapshotForId = common.packageSnapshotForId;
const compositionNodeForPackageId = common.compositionNodeForPackageId;
const jsonArrayField = common.jsonArrayField;
const jsonObjectField = common.jsonObjectField;
const expectJsonStringFieldValue = common.expectJsonStringFieldValue;
const expectJsonFieldEqual = common.expectJsonFieldEqual;
const expectFileContains = common.expectFileContains;
const writeAbsoluteTestFile = common.writeAbsoluteTestFile;
const packagePolicyKey = common.packagePolicyKey;
const packageHostScript = common.packageHostScript;
const makeManifestSources = common.makeManifestSources;
const freeManifestSources = common.freeManifestSources;
const jsonObjectWithString = common.jsonObjectWithString;
const expectToolResultContainsMain = common.expectToolResultContainsMain;
const findToolByName = common.findToolByName;

test "runCli webview captures prepared launch context without leaking secrets" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/notes.txt", .data = "file body" });

    const project_dir = try cli_test.makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_WEBVIEW_CAPTURE_LAUNCH_CONTEXT", "1");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var stdin_input = CliStdin{
        .is_tty = false,
        .content = "stdin draft\n",
    };

    const exit_code = try runCliWithInput(
        allocator,
        std.testing.io,
        &env_map,
        &.{
            "--webview",
            "--provider",
            "faux",
            "--model",
            "faux-1",
            "--api-key",
            "sentinel-webview-secret",
            "--no-session",
            "--tools",
            "read",
            "@notes.txt",
            "positional prompt",
            "follow up",
        },
        project_dir,
        &stdin_input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const out = stdout_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"mode\":\"webview\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"provider\":\"faux\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"model\":\"faux-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"noSession\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"toolAllowlist\":[\"read\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "stdin draft") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "file body") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "positional prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"initialMessages\":[\"follow up\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"apiKeyPresent\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sentinel-webview-secret") == null);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "runCli webview missing credentials reaches auth-required launch context" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project");

    const project_dir = try cli_test.makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_WEBVIEW_CAPTURE_LAUNCH_CONTEXT", "1");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--webview", "--provider", "openai", "--no-session" },
        project_dir,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const out = stdout_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"mode\":\"webview\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"provider\":\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"authStatus\":\"missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"apiKeyPresent\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "OPENAI_API_KEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "auth.json") == null);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "runCli webview session flags preserve canonical session selection" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.createDirPath(std.testing.io, "sessions");

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try cli_test.makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    const session_dir = try cli_test.makeTmpPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    var seed_env = std.process.Environ.Map.init(allocator);
    defer seed_env.deinit();
    try seed_env.put("HOME", home_dir);
    try seed_env.put("PI_FAUX_RESPONSE", "seed answer");

    var seed_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer seed_stdout.deinit();
    var seed_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer seed_stderr.deinit();
    const seed_exit = try runCli(
        allocator,
        std.testing.io,
        &seed_env,
        &.{ "--provider", "faux", "--print", "--session-dir", session_dir, "seed prompt" },
        project_dir,
        &seed_stdout.writer,
        &seed_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), seed_exit);
    try std.testing.expectEqualStrings("seed answer\n", seed_stdout.writer.buffered());

    const source_session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(source_session_file);

    var webview_env = std.process.Environ.Map.init(allocator);
    defer webview_env.deinit();
    try webview_env.put("HOME", home_dir);
    try webview_env.put("PI_WEBVIEW_CAPTURE_LAUNCH_CONTEXT", "1");

    const cases = [_]struct {
        args: []const []const u8,
        expected_file: []const u8,
    }{
        .{ .args = &.{ "--webview", "--provider", "faux", "--session-dir", session_dir, "--session", source_session_file }, .expected_file = source_session_file },
        .{ .args = &.{ "--webview", "--provider", "faux", "--session-dir", session_dir, "--continue" }, .expected_file = source_session_file },
        .{ .args = &.{ "--webview", "--provider", "faux", "--session-dir", session_dir, "--resume" }, .expected_file = source_session_file },
    };

    for (cases) |case| {
        var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
        defer stdout_capture.deinit();
        var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
        defer stderr_capture.deinit();

        const exit_code = try runCli(
            allocator,
            std.testing.io,
            &webview_env,
            case.args,
            project_dir,
            &stdout_capture.writer,
            &stderr_capture.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "\"mode\":\"webview\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), case.expected_file) != null);
        try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "\"noSession\":false") != null);
        try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
    }

    var fork_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer fork_stdout.deinit();
    var fork_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer fork_stderr.deinit();
    const fork_exit = try runCli(
        allocator,
        std.testing.io,
        &webview_env,
        &.{ "--webview", "--provider", "faux", "--session-dir", session_dir, "--fork", source_session_file },
        project_dir,
        &fork_stdout.writer,
        &fork_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), fork_exit);
    const fork_out = fork_stdout.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, fork_out, "\"mode\":\"webview\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fork_out, "\"sessionFile\":null") == null);
    try std.testing.expect(std.mem.indexOf(u8, fork_out, source_session_file) == null);
    try std.testing.expectEqualStrings("", fork_stderr.writer.buffered());
}

test "runCli rejects incompatible webview mode combinations before runtime dispatch" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_WEBVIEW_CAPTURE_LAUNCH_CONTEXT", "1");

    const cases = [_]struct {
        args: []const []const u8,
        expected: []const u8,
    }{
        .{ .args = &.{ "--webview", "--print", "hello" }, .expected = "--webview cannot be combined with --print" },
        .{ .args = &.{ "--webview", "--mode", "json", "hello" }, .expected = "--webview cannot be combined with --mode json" },
        .{ .args = &.{ "--webview", "--mode", "rpc" }, .expected = "--webview cannot be combined with --mode rpc" },
        .{ .args = &.{ "--webview", "--mode", "json-rpc" }, .expected = "--webview cannot be combined with --mode json-rpc" },
    };

    for (cases) |case| {
        var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
        defer stdout_capture.deinit();
        var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
        defer stderr_capture.deinit();

        const exit_code = try runCli(
            allocator,
            std.testing.io,
            &env_map,
            case.args,
            "/tmp/project",
            &stdout_capture.writer,
            &stderr_capture.writer,
        );

        try std.testing.expectEqual(@as(u8, 1), exit_code);
        try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
        try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), case.expected) != null);
    }
}

test "runCli package and early-exit paths preempt webview startup" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "project");

    const agent_dir = try cli_test.makeTmpPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const project_dir = try cli_test.makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    try env_map.put("PI_WEBVIEW_CAPTURE_LAUNCH_CONTEXT", "1");

    const cases = [_]struct {
        args: []const []const u8,
        expected: []const u8,
    }{
        .{ .args = &.{ "--webview", "--help" }, .expected = "--webview" },
        .{ .args = &.{ "--webview", "--version" }, .expected = "pi version" },
        .{ .args = &.{ "install", "--help", "--webview" }, .expected = "Usage:\n  pi install <source> [-l]" },
    };

    for (cases) |case| {
        var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
        defer stdout_capture.deinit();
        var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
        defer stderr_capture.deinit();

        const exit_code = try runCli(
            allocator,
            std.testing.io,
            &env_map,
            case.args,
            project_dir,
            &stdout_capture.writer,
            &stderr_capture.writer,
        );

        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), case.expected) != null);
        try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "\"mode\":\"webview\"") == null);
        try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
    }
}

test "runCli non-webview print ignores webview launch capture hook" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_WEBVIEW_CAPTURE_LAUNCH_CONTEXT", "1");
    try env_map.put("PI_FAUX_RESPONSE", "plain print");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "hello" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("plain print\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}
