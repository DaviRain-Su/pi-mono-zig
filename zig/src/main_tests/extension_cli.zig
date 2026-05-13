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

test "runCli extension boolean/string flags accepts registered local Bun fixture" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "ext-flags ok");

    const fixture_path = try cli_test.makeAbsoluteTestPath(allocator, "test/fixtures/extensions/flag-fixture/extension.ts");
    defer allocator.free(fixture_path);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home");
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");
    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const agent_dir = try cli_test.makeTmpPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const project_dir = try cli_test.makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{
            "--extension",  fixture_path,
            "--no-session", "--provider",
            "faux",         "--print",
            "--plan",       "--model-alias",
            "claude-haiku", "hello",
        },
        project_dir,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("ext-flags ok\n", stdout_capture.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "extensions skipped: unapproved") != null);
}

test "runCli M11 extension registry dump emits live registry snapshot for explicit --extension" {
    // Live Bun JSONL register_* protocol parity coverage. Drives a
    // deterministic /bin/sh stub as the host runtime via the
    // PI_M11_EXTENSION_HOST_RUNTIME override so the test is hermetic
    // and does not depend on a working `bun` install. The shell
    // mirrors what a Bun-hosted fixture extension would emit.
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M11_EXTENSION_REGISTRY_DUMP", "1");
    try env_map.put("PI_M11_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M11_EXTENSION_READY_TIMEOUT_MS", "1500");
    try env_map.put("PI_M11_EXTENSION_DRAIN_TIMEOUT_MS", "1500");

    // The /bin/sh entry point is a small inline script that reads the
    // initialize frame and emits ready + register_* frames mirroring
    // the registration-fixture sidecar contents. The first --extension
    // argument is interpreted by /bin/sh as the script path. Construct
    // a temp .sh file that contains the body so the host argv has
    // exactly one explicit --extension entry.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script_body =
        "IFS= read -r init\n" ++
        "printf '{\"type\":\"ready\"}\\n'\n" ++
        "printf '{\"type\":\"register_tool\",\"name\":\"say-hello\",\"label\":\"Say Hello\",\"description\":\"Greets the world\",\"extensionPath\":\"fixture/extension.ts\"}\\n'\n" ++
        "printf '{\"type\":\"register_command\",\"name\":\"say-hello\",\"description\":\"Slash\",\"extensionPath\":\"fixture/extension.ts\"}\\n'\n" ++
        "printf '{\"type\":\"register_shortcut\",\"shortcut\":\"ctrl+h\",\"command\":\"say-hello\",\"extensionPath\":\"fixture/extension.ts\"}\\n'\n" ++
        "printf '{\"type\":\"register_flag\",\"name\":\"plan\",\"valueType\":\"boolean\",\"default\":true,\"extensionPath\":\"fixture/extension.ts\"}\\n'\n" ++
        "printf '{\"type\":\"register_flag\",\"name\":\"model-alias\",\"valueType\":\"string\",\"default\":\"claude-haiku\",\"extensionPath\":\"fixture/extension.ts\"}\\n'\n" ++
        "printf '{\"type\":\"register_provider\",\"name\":\"fake-provider\",\"displayName\":\"Fake\",\"api\":\"openai-completions\",\"models\":[{\"id\":\"fake-1\",\"name\":\"Fake 1\"}],\"extensionPath\":\"fixture/extension.ts\"}\\n'\n" ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ext-stub.sh", .data = script_body });
    const ext_path = try cli_test.makeTmpPath(allocator, tmp, "ext-stub.sh");
    defer allocator.free(ext_path);

    // Also need a flags sidecar so the CLI accepts --plan and
    // --model-alias before extension load. The registry dump path
    // applies the parsed CLI values into the live registry.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "ext-stub.sh.flags.json",
        .data =
        \\{ "flags": [
        \\  { "name": "plan", "type": "boolean" },
        \\  { "name": "model-alias", "type": "string" }
        \\] }
        ,
    });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{
            "--extension",
            ext_path,
            "--plan",
            "--model-alias",
            "claude-opus",
        },
        "/tmp",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const out = stdout_capture.writer.buffered();
    // Live register_* frames produced observable runtime registry output.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"say-hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"shortcut\":\"ctrl+h\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"fake-provider\"") != null);
    // Parsed CLI flag value plumbed into runtime ExtensionState and
    // reflected through getFlag in the snapshot.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"value\":\"claude-opus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"default\":\"claude-haiku\"") != null);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "runCli M8 extension registry dump includes rejected flag diagnostics" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M11_EXTENSION_REGISTRY_DUMP", "1");
    try env_map.put("PI_M11_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M11_EXTENSION_READY_TIMEOUT_MS", "1500");
    try env_map.put("PI_M11_EXTENSION_DRAIN_TIMEOUT_MS", "20");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script_body =
        "IFS= read -r init\n" ++
        "printf '{\"type\":\"ready\"}\\n'\n" ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "first.sh", .data = script_body });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "second.ts", .data = script_body });
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "first.sh.flags.json",
        .data =
        \\{ "flags": [
        \\  { "name": "plan", "type": "boolean" },
        \\  { "name": "model", "type": "string" }
        \\] }
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "second.ts.flags.json",
        .data =
        \\{ "flags": [
        \\  { "name": "plan", "type": "string" }
        \\] }
        ,
    });
    const first_path = try cli_test.makeTmpPath(allocator, tmp, "first.sh");
    defer allocator.free(first_path);
    const second_path = try cli_test.makeTmpPath(allocator, tmp, "second.ts");
    defer allocator.free(second_path);
    const agent_dir = try cli_test.makeTmpPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    const first_policy_key = try temporaryTypeScriptPolicyKey(allocator, first_path);
    defer allocator.free(first_policy_key);
    const second_policy_key = try temporaryTypeScriptPolicyKey(allocator, second_path);
    defer allocator.free(second_policy_key);
    const settings = try settingsWithTemporaryExtensionPolicies(allocator, &.{ first_policy_key, second_policy_key }, &.{"tool.use"});
    defer allocator.free(settings);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/settings.json", .data = settings });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--extension", first_path, "--extension", second_path },
        "/tmp",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const out = stdout_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"extensionFlagDiagnostics\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"code\":\"extension_flag.builtin_collision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"code\":\"extension_flag.owner_collision\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"flag\":\"model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"flag\":\"plan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"owner\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"source\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"reason\":\"collides with built-in option\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"reason\":\"collides with another extension flag owner\"") != null);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "runCli M11 extension registry dump surfaces shutdown failure without losing snapshot" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M11_EXTENSION_REGISTRY_DUMP", "1");
    try env_map.put("PI_M11_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M11_EXTENSION_READY_TIMEOUT_MS", "1500");
    try env_map.put("PI_M11_EXTENSION_DRAIN_TIMEOUT_MS", "1500");
    try env_map.put("PI_M11_EXTENSION_SHUTDOWN_TIMEOUT_MS", "50");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script_body =
        "IFS= read -r init\n" ++
        "exec 0<&-\n" ++
        "printf '{\"type\":\"ready\"}\\n'\n" ++
        "printf '{\"type\":\"register_tool\",\"name\":\"shutdown-visible\",\"label\":\"Shutdown Visible\",\"description\":\"Survives failed shutdown\",\"extensionPath\":\"fixture/extension.ts\"}\\n'\n" ++
        "while true; do sleep 1; done\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "shutdown-failure.sh", .data = script_body });
    const ext_path = try cli_test.makeTmpPath(allocator, tmp, "shutdown-failure.sh");
    defer allocator.free(ext_path);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--extension", ext_path },
        "/tmp",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    const out = stdout_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"shutdown-visible\"") != null);
    const err = stderr_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, err, "Error: extension host shutdown failed: BrokenPipe") != null);
}

test "runCli M11 extension registry dump shows unregisterProvider removing the provider" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_M11_EXTENSION_REGISTRY_DUMP", "1");
    try env_map.put("PI_M11_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M11_EXTENSION_READY_TIMEOUT_MS", "1500");
    try env_map.put("PI_M11_EXTENSION_DRAIN_TIMEOUT_MS", "1500");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script_body =
        "IFS= read -r init\n" ++
        "printf '{\"type\":\"ready\"}\\n'\n" ++
        "printf '{\"type\":\"register_provider\",\"name\":\"fake-provider\",\"displayName\":\"Fake\",\"api\":\"openai-completions\",\"models\":[{\"id\":\"fake-1\",\"name\":\"Fake 1\"}],\"extensionPath\":\"fixture/extension.ts\"}\\n'\n" ++
        "printf '{\"type\":\"unregister_provider\",\"name\":\"fake-provider\"}\\n'\n" ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "unreg.sh", .data = script_body });
    const ext_path = try cli_test.makeTmpPath(allocator, tmp, "unreg.sh");
    defer allocator.free(ext_path);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--extension", ext_path },
        "/tmp",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const out = stdout_capture.writer.buffered();
    // The provider was registered then unregistered; the snapshot must
    // expose an empty providers list.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"providers\":[]") != null);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "runCli help with --extension lists fixture extension flags" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const fixture_path = try cli_test.makeAbsoluteTestPath(allocator, "test/fixtures/extensions/flag-fixture/extension.ts");
    defer allocator.free(fixture_path);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--extension", fixture_path, "--help" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const help_text = stdout_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, help_text, "Extension CLI Flags:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "--plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "Enable plan mode (fixture flag)") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "--model-alias <value>") != null);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "runCli help with --extension surfaces rejected flag diagnostics" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "extension.ts", .data = "export default {};" });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "extension.ts.flags.json",
        .data =
        \\{ "flags": [
        \\  { "name": "model", "type": "string" },
        \\  { "name": "approved-flag", "type": "boolean", "description": "Approved fixture flag" }
        \\] }
        ,
    });
    const ext_path = try cli_test.makeTmpPath(allocator, tmp, "extension.ts");
    defer allocator.free(ext_path);

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--extension", ext_path, "--help" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const help_text = stdout_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, help_text, "Extension CLI Flags:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "--approved-flag") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "Extension CLI Flag Diagnostics:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "extension_flag.builtin_collision") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "flag=--model") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "owner=") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "source=") != null);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}
