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

test "runCli persists and continues sessions across runs" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-session");
    defer allocator.free(cwd);

    var first_env = std.process.Environ.Map.init(allocator);
    defer first_env.deinit();
    try first_env.put("PI_FAUX_RESPONSE", "first reply");

    var first_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer first_stdout.deinit();
    var first_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer first_stderr.deinit();

    const first_exit = try runCli(
        allocator,
        std.testing.io,
        &first_env,
        &.{ "--provider", "faux", "--print", "first prompt" },
        cwd,
        &first_stdout.writer,
        &first_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), first_exit);

    var second_env = std.process.Environ.Map.init(allocator);
    defer second_env.deinit();
    try second_env.put("PI_FAUX_RESPONSE", "second reply");

    var second_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer second_stdout.deinit();
    var second_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer second_stderr.deinit();

    const second_exit = try runCli(
        allocator,
        std.testing.io,
        &second_env,
        &.{ "--provider", "faux", "--print", "--continue", "second prompt" },
        cwd,
        &second_stdout.writer,
        &second_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), second_exit);

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();

    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), context.messages.len);
    try std.testing.expectEqualStrings("first prompt", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("first reply", context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("second prompt", context.messages[2].user.content[0].text.text);
    try std.testing.expectEqualStrings("second reply", context.messages[3].assistant.content[0].text.text);
}

test "runCli resume loads the latest session" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-resume");
    defer allocator.free(cwd);

    var first_env = std.process.Environ.Map.init(allocator);
    defer first_env.deinit();
    try first_env.put("PI_FAUX_RESPONSE", "first reply");

    var first_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer first_stdout.deinit();
    var first_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer first_stderr.deinit();

    const first_exit = try runCli(
        allocator,
        std.testing.io,
        &first_env,
        &.{ "--provider", "faux", "--print", "first prompt" },
        cwd,
        &first_stdout.writer,
        &first_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), first_exit);

    var second_env = std.process.Environ.Map.init(allocator);
    defer second_env.deinit();
    try second_env.put("PI_FAUX_RESPONSE", "resumed reply");

    var second_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer second_stdout.deinit();
    var second_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer second_stderr.deinit();

    const second_exit = try runCli(
        allocator,
        std.testing.io,
        &second_env,
        &.{ "--provider", "faux", "--print", "--resume", "second prompt" },
        cwd,
        &second_stdout.writer,
        &second_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), second_exit);

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();

    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), context.messages.len);
    try std.testing.expectEqualStrings("first prompt", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("first reply", context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("second prompt", context.messages[2].user.content[0].text.text);
    try std.testing.expectEqualStrings("resumed reply", context.messages[3].assistant.content[0].text.text);
}

test "runCli no-session keeps runs ephemeral" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-no-session");
    defer allocator.free(cwd);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "ephemeral reply");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "--no-session", "hello" },
        cwd,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("ephemeral reply\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir);
    defer if (session_file) |path| allocator.free(path);
    try std.testing.expect(session_file == null);
}

test "runCli stores sessions in overridden session directory" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-session-dir");
    defer allocator.free(cwd);
    const overridden_session_dir = try cli_test.makeTmpPath(allocator, tmp, "custom-sessions");
    defer allocator.free(overridden_session_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "stored in custom session dir");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--session-dir", overridden_session_dir, "--print", "hello" },
        cwd,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("stored in custom session dir\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, overridden_session_dir)).?;
    defer allocator.free(session_file);
    try std.testing.expect(std.mem.startsWith(u8, session_file, overridden_session_dir));
}

test "runCli fork creates a new session from an existing session id" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-fork");
    defer allocator.free(cwd);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);

    var first_env = std.process.Environ.Map.init(allocator);
    defer first_env.deinit();
    try first_env.put("PI_FAUX_RESPONSE", "seed reply");

    var first_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer first_stdout.deinit();
    var first_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer first_stderr.deinit();

    const first_exit = try runCli(
        allocator,
        std.testing.io,
        &first_env,
        &.{ "--provider", "faux", "--print", "seed prompt" },
        cwd,
        &first_stdout.writer,
        &first_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), first_exit);

    const original_session_path = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(original_session_path);

    const source_path = try allocator.dupe(u8, original_session_path);
    defer allocator.free(source_path);

    var source_manager = try coding_agent.SessionManager.open(allocator, std.testing.io, source_path, cwd);
    defer source_manager.deinit();
    const source_session_id = try allocator.dupe(u8, source_manager.getSessionId());
    defer allocator.free(source_session_id);

    var second_env = std.process.Environ.Map.init(allocator);
    defer second_env.deinit();
    try second_env.put("PI_FAUX_RESPONSE", "fork reply");

    var second_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer second_stdout.deinit();
    var second_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer second_stderr.deinit();

    const second_exit = try runCli(
        allocator,
        std.testing.io,
        &second_env,
        &.{ "--provider", "faux", "--print", "--fork", source_session_id, "fork prompt" },
        cwd,
        &second_stdout.writer,
        &second_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), second_exit);

    const forked_session_path = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(forked_session_path);
    try std.testing.expect(!std.mem.eql(u8, source_path, forked_session_path));

    var original_manager = try coding_agent.SessionManager.open(allocator, std.testing.io, source_path, cwd);
    defer original_manager.deinit();
    var original_context = try original_manager.buildSessionContext(allocator);
    defer original_context.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), original_context.messages.len);
    try std.testing.expectEqualStrings("seed prompt", original_context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("seed reply", original_context.messages[1].assistant.content[0].text.text);

    var forked_manager = try coding_agent.SessionManager.open(allocator, std.testing.io, forked_session_path, cwd);
    defer forked_manager.deinit();
    var forked_context = try forked_manager.buildSessionContext(allocator);
    defer forked_context.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), forked_context.messages.len);
    try std.testing.expectEqualStrings("seed prompt", forked_context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("seed reply", forked_context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("fork prompt", forked_context.messages[2].user.content[0].text.text);
    try std.testing.expectEqualStrings("fork reply", forked_context.messages[3].assistant.content[0].text.text);
}

test "cli executable continue resumes the latest session while preserving older sessions" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const project_dir = try cli_test.makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ project_dir, ".pi", "sessions" });
    defer allocator.free(session_dir);

    var first = try cli_test.runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--print", "first prompt" },
        &.{.{ "PI_FAUX_RESPONSE", "first reply" }},
    );
    defer first.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), first.exit_code);
    try std.testing.expectEqualStrings("first reply\n", first.stdout);
    try std.testing.expectEqualStrings("", first.stderr);

    const original_session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(original_session_file);

    const original_session_before_continue = try std.testing.allocator.dupe(u8, original_session_file);
    defer std.testing.allocator.free(original_session_before_continue);

    const original_bytes_before_continue = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, original_session_before_continue, allocator, .unlimited);
    defer allocator.free(original_bytes_before_continue);
    var original_line_count_before_continue: usize = 0;
    for (original_bytes_before_continue) |byte| {
        if (byte == '\n') original_line_count_before_continue += 1;
    }

    var second = try cli_test.runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--print", "--continue", "second prompt" },
        &.{.{ "PI_FAUX_RESPONSE", "second reply" }},
    );
    defer second.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), second.exit_code);
    try std.testing.expectEqualStrings("second reply\n", second.stdout);
    try std.testing.expectEqualStrings("", second.stderr);

    const original_session_after_continue = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(original_session_after_continue);
    try std.testing.expectEqualStrings(original_session_before_continue, original_session_after_continue);

    const original_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, original_session_after_continue, allocator, .unlimited);
    defer allocator.free(original_bytes);
    var original_line_count: usize = 0;
    for (original_bytes) |byte| {
        if (byte == '\n') original_line_count += 1;
    }
    try std.testing.expectEqual(original_line_count_before_continue + 2, original_line_count);

    var original_manager = try coding_agent.SessionManager.open(allocator, std.testing.io, original_session_after_continue, project_dir);
    defer original_manager.deinit();

    var original_context = try original_manager.buildSessionContext(allocator);
    defer original_context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), original_context.messages.len);
    try std.testing.expectEqualStrings("first prompt", original_context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("first reply", original_context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("second prompt", original_context.messages[2].user.content[0].text.text);
    try std.testing.expectEqualStrings("second reply", original_context.messages[3].assistant.content[0].text.text);

    var third = try cli_test.runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--print", "third prompt" },
        &.{.{ "PI_FAUX_RESPONSE", "third reply" }},
    );
    defer third.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), third.exit_code);
    try std.testing.expectEqualStrings("third reply\n", third.stdout);
    try std.testing.expectEqualStrings("", third.stderr);

    const latest_session_before_continue = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(latest_session_before_continue);
    try std.testing.expect(!std.mem.eql(u8, original_session_before_continue, latest_session_before_continue));

    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, session_dir, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var iterator = dir.iterate();
    var session_file_count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        session_file_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), session_file_count);

    const latest_session_path = try std.testing.allocator.dupe(u8, latest_session_before_continue);
    defer std.testing.allocator.free(latest_session_path);

    var fourth = try cli_test.runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--print", "--continue", "fourth prompt" },
        &.{.{ "PI_FAUX_RESPONSE", "fourth reply" }},
    );
    defer fourth.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), fourth.exit_code);
    try std.testing.expectEqualStrings("fourth reply\n", fourth.stdout);
    try std.testing.expectEqualStrings("", fourth.stderr);

    const latest_session_after_continue = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(latest_session_after_continue);
    try std.testing.expectEqualStrings(latest_session_path, latest_session_after_continue);

    var latest_manager = try coding_agent.SessionManager.open(allocator, std.testing.io, latest_session_after_continue, project_dir);
    defer latest_manager.deinit();

    var latest_context = try latest_manager.buildSessionContext(allocator);
    defer latest_context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), latest_context.messages.len);
    try std.testing.expectEqualStrings("third prompt", latest_context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("third reply", latest_context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("fourth prompt", latest_context.messages[2].user.content[0].text.text);
    try std.testing.expectEqualStrings("fourth reply", latest_context.messages[3].assistant.content[0].text.text);
}

test "runCli preserves context when continuing with a different provider" {
    const allocator = std.testing.allocator;
    const faux = ai.providers.faux;

    ai.api_registry.resetToBuiltIns();
    defer ai.api_registry.resetToBuiltIns();

    const openai_registration = try faux.registerFauxProvider(allocator, .{
        .api = "openai-responses",
        .provider = "openai",
        .models = &[_]faux.FauxModelDefinition{.{
            .id = "gpt-5.4",
            .name = "GPT-5.4",
            .reasoning = true,
        }},
    });
    defer openai_registration.unregister();

    const openai_blocks = [_]faux.FauxContentBlock{
        faux.fauxText("I will remember marigold."),
    };
    try openai_registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(openai_blocks[0..], .{}) },
    });

    const anthropic_registration = try faux.registerFauxProvider(allocator, .{
        .api = "anthropic-messages",
        .provider = "anthropic",
        .models = &[_]faux.FauxModelDefinition{.{
            .id = "claude-opus-4-7",
            .name = "Claude Opus 4.7",
            .reasoning = true,
        }},
    });
    defer anthropic_registration.unregister();
    try anthropic_registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = struct {
            fn respond(
                factory_allocator: std.mem.Allocator,
                context: ai.Context,
                _: ?ai.types.StreamOptions,
                call_count: *usize,
                model: ai.Model,
            ) !faux.FauxAssistantMessage {
                try std.testing.expectEqual(@as(usize, 1), call_count.*);
                try std.testing.expectEqualStrings("anthropic", model.provider);
                try std.testing.expectEqualStrings("claude-opus-4-7", model.id);
                try std.testing.expectEqual(@as(usize, 3), context.messages.len);
                try std.testing.expectEqualStrings("Remember this token: marigold", context.messages[0].user.content[0].text.text);
                try std.testing.expectEqualStrings("I will remember marigold.", context.messages[1].assistant.content[0].text.text);
                try std.testing.expectEqualStrings("openai", context.messages[1].assistant.provider);
                try std.testing.expectEqualStrings("What token did I ask you to remember?", context.messages[2].user.content[0].text.text);

                const blocks = try factory_allocator.alloc(faux.FauxContentBlock, 1);
                blocks[0] = faux.fauxText("You asked me to remember marigold.");
                return faux.fauxAssistantMessage(blocks, .{});
            }
        }.respond },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-multi-provider");
    defer allocator.free(cwd);

    var first_env = std.process.Environ.Map.init(allocator);
    defer first_env.deinit();
    try first_env.put("OPENAI_API_KEY", "test-openai-key");

    var first_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer first_stdout.deinit();
    var first_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer first_stderr.deinit();

    const first_exit = try runCli(
        allocator,
        std.testing.io,
        &first_env,
        &.{ "--provider", "openai", "--print", "Remember this token: marigold" },
        cwd,
        &first_stdout.writer,
        &first_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), first_exit);
    try std.testing.expectEqualStrings("I will remember marigold.\n", first_stdout.written());
    try std.testing.expectEqualStrings("", first_stderr.written());

    var second_env = std.process.Environ.Map.init(allocator);
    defer second_env.deinit();
    try second_env.put("ANTHROPIC_API_KEY", "test-anthropic-key");

    var second_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer second_stdout.deinit();
    var second_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer second_stderr.deinit();

    const second_exit = try runCli(
        allocator,
        std.testing.io,
        &second_env,
        &.{ "--provider", "anthropic", "--print", "--continue", "What token did I ask you to remember?" },
        cwd,
        &second_stdout.writer,
        &second_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), second_exit);
    try std.testing.expectEqualStrings("You asked me to remember marigold.\n", second_stdout.written());
    try std.testing.expectEqualStrings("", second_stderr.written());

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();

    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), context.messages.len);
    try std.testing.expectEqualStrings("Remember this token: marigold", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("I will remember marigold.", context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("openai", context.messages[1].assistant.provider);
    try std.testing.expectEqualStrings("What token did I ask you to remember?", context.messages[2].user.content[0].text.text);
    try std.testing.expectEqualStrings("You asked me to remember marigold.", context.messages[3].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("anthropic", context.messages[3].assistant.provider);
    try std.testing.expectEqualStrings("anthropic", context.model.?.provider);
    try std.testing.expectEqualStrings("claude-opus-4-7", context.model.?.model_id);
}

test "runCli missing-cwd preflight wins over runtime_prep failures (M10 ordering)" {
    // Regression for M10 scrutiny round 2: the missing stored-cwd diagnostic
    // must win over `prepareCliRuntime` / `resolveProviderConfig` failures.
    // Without the early preflight ordering fix, a non-interactive `--continue`
    // with an unknown provider would surface the unrelated provider error
    // instead of the missing-cwd diagnostic the user actually needs to see.
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "stored");
    try tmp.dir.createDirPath(std.testing.io, "launch");
    try tmp.dir.createDirPath(std.testing.io, "sessions");

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const stored_cwd = try cli_test.makeTmpPath(allocator, tmp, "stored");
    defer allocator.free(stored_cwd);
    const launch_cwd = try cli_test.makeTmpPath(allocator, tmp, "launch");
    defer allocator.free(launch_cwd);
    const session_dir = try cli_test.makeTmpPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    // Seed a session whose stored cwd will be removed below.
    {
        var seed_env = std.process.Environ.Map.init(allocator);
        defer seed_env.deinit();
        try seed_env.put("HOME", home_dir);
        try seed_env.put("PI_FAUX_RESPONSE", "seed reply");

        var seed_stdout: std.Io.Writer.Allocating = .init(allocator);
        defer seed_stdout.deinit();
        var seed_stderr: std.Io.Writer.Allocating = .init(allocator);
        defer seed_stderr.deinit();
        const seed_exit = try runCli(
            allocator,
            std.testing.io,
            &seed_env,
            &.{
                "--provider",
                "faux",
                "--print",
                "--session-dir",
                session_dir,
                "seed prompt",
            },
            stored_cwd,
            &seed_stdout.writer,
            &seed_stderr.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), seed_exit);
    }

    // Capture session bytes, then delete the stored cwd so the next resume
    // attempt sees a missing-cwd issue.
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);
    const before_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(before_bytes);
    try tmp.dir.deleteTree(std.testing.io, "stored");

    var run_env = std.process.Environ.Map.init(allocator);
    defer run_env.deinit();
    try run_env.put("HOME", home_dir);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &run_env,
        &.{
            "--provider",
            "definitely-not-a-real-provider",
            "--print",
            "--continue",
            "--session-dir",
            session_dir,
            "second prompt",
        },
        launch_cwd,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    const stderr_text = stderr_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, "Stored session working directory does not exist:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, stored_cwd) != null);
    // Confirm the unknown provider error did NOT preempt the missing-cwd
    // diagnostic.
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, "definitely-not-a-real-provider") == null);

    // The session file must remain byte-identical: a rejected non-interactive
    // resume must never mutate the persisted session.
    const after_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(after_bytes);
    try std.testing.expectEqualSlices(u8, before_bytes, after_bytes);
}

test "runCli webview missing-cwd preflight runs before provider and launch side effects" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "stored");
    try tmp.dir.createDirPath(std.testing.io, "launch");
    try tmp.dir.createDirPath(std.testing.io, "sessions");

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const stored_cwd = try cli_test.makeTmpPath(allocator, tmp, "stored");
    defer allocator.free(stored_cwd);
    const launch_cwd = try cli_test.makeTmpPath(allocator, tmp, "launch");
    defer allocator.free(launch_cwd);
    const session_dir = try cli_test.makeTmpPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    {
        var seed_env = std.process.Environ.Map.init(allocator);
        defer seed_env.deinit();
        try seed_env.put("HOME", home_dir);
        try seed_env.put("PI_FAUX_RESPONSE", "seed reply");

        var seed_stdout: std.Io.Writer.Allocating = .init(allocator);
        defer seed_stdout.deinit();
        var seed_stderr: std.Io.Writer.Allocating = .init(allocator);
        defer seed_stderr.deinit();
        const seed_exit = try runCli(
            allocator,
            std.testing.io,
            &seed_env,
            &.{ "--provider", "faux", "--print", "--session-dir", session_dir, "seed prompt" },
            stored_cwd,
            &seed_stdout.writer,
            &seed_stderr.writer,
        );
        try std.testing.expectEqual(@as(u8, 0), seed_exit);
    }

    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);
    const before_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(before_bytes);
    try tmp.dir.deleteTree(std.testing.io, "stored");

    var run_env = std.process.Environ.Map.init(allocator);
    defer run_env.deinit();
    try run_env.put("HOME", home_dir);
    try run_env.put("PI_WEBVIEW_CAPTURE_LAUNCH_CONTEXT", "1");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &run_env,
        &.{
            "--webview",
            "--provider",
            "definitely-not-a-real-provider",
            "--continue",
            "--session-dir",
            session_dir,
        },
        launch_cwd,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
    const stderr_text = stderr_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, "Stored session working directory does not exist:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, stored_cwd) != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, "definitely-not-a-real-provider") == null);

    const after_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .unlimited);
    defer allocator.free(after_bytes);
    try std.testing.expectEqualSlices(u8, before_bytes, after_bytes);
}
