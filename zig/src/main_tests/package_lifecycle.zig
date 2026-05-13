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

test "VAL-CROSS-010 settings backed package lifecycle e2e uses normal startup reload shutdown" {
    const allocator = std.testing.allocator;
    const faux = ai.providers.faux;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home");
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");
    try tmp.dir.createDirPath(std.testing.io, "project/process-pkg/extensions");
    try tmp.dir.createDirPath(std.testing.io, "project/wasm-pkg/extensions");
    try tmp.dir.createDirPath(std.testing.io, "project/native-pkg/extensions");
    try tmp.dir.createDirPath(std.testing.io, "project/workflow-pkg/extensions");

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const agent_dir = try cli_test.makeTmpPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const project_dir = try cli_test.makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    const process_root = try cli_test.makeTmpPath(allocator, tmp, "project/process-pkg");
    defer allocator.free(process_root);
    const wasm_root = try cli_test.makeTmpPath(allocator, tmp, "project/wasm-pkg");
    defer allocator.free(wasm_root);
    const native_root = try cli_test.makeTmpPath(allocator, tmp, "project/native-pkg");
    defer allocator.free(native_root);
    const workflow_root = try cli_test.makeTmpPath(allocator, tmp, "project/workflow-pkg");
    defer allocator.free(workflow_root);

    const package_json =
        \\{"pi":{"extensions":["extensions/host.ts"]}}
    ;
    const process_script_path = try std.fs.path.join(allocator, &.{ process_root, "extensions/host.ts" });
    defer allocator.free(process_script_path);
    const wasm_script_path = try std.fs.path.join(allocator, &.{ wasm_root, "extensions/host.ts" });
    defer allocator.free(wasm_script_path);
    const native_script_path = try std.fs.path.join(allocator, &.{ native_root, "extensions/host.ts" });
    defer allocator.free(native_script_path);
    const workflow_script_path = try std.fs.path.join(allocator, &.{ workflow_root, "extensions/host.ts" });
    defer allocator.free(workflow_script_path);
    const process_capture = try cli_test.makeTmpPath(allocator, tmp, "process-capture.jsonl");
    defer allocator.free(process_capture);
    const process_v2_capture = try cli_test.makeTmpPath(allocator, tmp, "process-v2-capture.jsonl");
    defer allocator.free(process_v2_capture);
    const wasm_capture = try cli_test.makeTmpPath(allocator, tmp, "wasm-capture.jsonl");
    defer allocator.free(wasm_capture);
    const native_capture = try cli_test.makeTmpPath(allocator, tmp, "native-capture.jsonl");
    defer allocator.free(native_capture);
    const workflow_capture = try cli_test.makeTmpPath(allocator, tmp, "workflow-capture.jsonl");
    defer allocator.free(workflow_capture);

    const process_manifest =
        \\{"schemaVersion":"pi-extension.v1","id":"process.pkg","name":"Process Runtime Package","version":"1.0.0","runtime":{"kind":"process_jsonl","entrypoint":{"argv":["python3","extensions/host.ts"]}},"tools":[{"name":"process.cross","description":"Process package tool","inputSchema":{"type":"object","required":["value"],"properties":{"value":{"type":"string"}},"additionalProperties":false}}],"hooks":[{"event":"input","hookId":"process.input","priority":-30,"declarationOrder":0}],"capabilities":{"exports":[{"id":"process.cross","kind":"tool","version":"1.0.0"}]}}
    ;
    const wasm_manifest_text =
        \\{"schemaVersion":"pi-extension.v1","id":"wasm.pkg","name":"WASM Runtime Package","version":"1.0.0","runtime":{"kind":"wasm","entrypoint":{"artifactPath":"wasm/plugin.wasm"}},"dependencies":[{"id":"process.pkg","version":"^1.0.0"}],"tools":[{"name":"wasm.cross","description":"WASM package tool","inputSchema":{"type":"object","required":["value"],"properties":{"value":{"type":"string"}},"additionalProperties":false}}],"hooks":[{"event":"input","hookId":"wasm.input","priority":-20,"declarationOrder":0}],"capabilities":{"exports":[{"id":"wasm.cross","kind":"tool","version":"1.0.0"}]}}
    ;
    const native_manifest_text =
        \\{"schemaVersion":"pi-extension.v1","id":"native.pkg","name":"Native Runtime Package","version":"1.0.0","runtime":{"kind":"native","entrypoint":{"descriptor":"native_static_descriptor"}},"dependencies":[{"id":"wasm.pkg","version":"^1.0.0"}],"tools":[{"name":"native.cross","description":"Native package tool","inputSchema":{"type":"object","required":["value"],"properties":{"value":{"type":"string"}},"additionalProperties":false}}],"hooks":[{"event":"input","hookId":"native.input","priority":-10,"declarationOrder":0}],"capabilities":{"exports":[{"id":"native.cross","kind":"tool","version":"1.0.0"}]}}
    ;
    const workflow_manifest_text =
        \\{"schemaVersion":"pi-extension.v1","id":"workflow.pkg","name":"Workflow Package","version":"1.0.0","runtime":{"kind":"process_jsonl","entrypoint":{"argv":["python3","extensions/host.ts"]}},"dependencies":[{"id":"native.pkg","version":"^1.0.0"}],"capabilities":{"imports":[{"id":"process.cross","kind":"tool","version":"^1.0.0"},{"id":"wasm.cross","kind":"tool","version":"^1.0.0"},{"id":"native.cross","kind":"tool","version":"^1.0.0"}]},"workflows":[{"id":"workflow.cross","description":"Settings backed mixed workflow","exposure":{"tool":"workflow.cross"},"inputSchema":{"type":"object","required":["issue"],"properties":{"issue":{"type":"string"}},"additionalProperties":false},"outputSchema":{"type":"object"},"steps":[{"id":"process","kind":"side_effect","input":{"value":"workflow-process"},"replayMode":"recorded","selectedCapability":"process.cross"},{"id":"wasm","kind":"side_effect","input":{"value":"workflow-wasm"},"replayMode":"recorded","selectedCapability":"wasm.cross"},{"id":"native","kind":"side_effect","input":{"value":"workflow-native"},"replayMode":"recorded","selectedCapability":"native.cross"}]}]}
    ;

    const process_script_v1 = try packageHostScript(allocator, process_capture, "process.cross", "process", "v1", true, false);
    defer allocator.free(process_script_v1);
    const process_script_v2 = try packageHostScript(allocator, process_v2_capture, "process.cross.v2", "process", "v2", true, false);
    defer allocator.free(process_script_v2);
    const wasm_script = try packageHostScript(allocator, wasm_capture, "wasm.cross", "wasm", "v1", true, false);
    defer allocator.free(wasm_script);
    const native_script = try packageHostScript(allocator, native_capture, "native.cross", "native", "v1", true, false);
    defer allocator.free(native_script);
    const workflow_script = try packageHostScript(allocator, workflow_capture, "workflow.cross", "workflow", "v1", false, true);
    defer allocator.free(workflow_script);

    const fixtures = [_]LifecyclePackageFixture{
        .{ .root = process_root, .source = "./process-pkg", .script_rel = "extensions/host.ts", .script_abs = process_script_path, .manifest = process_manifest, .initial_script = process_script_v1, .manifest_id = "process.pkg", .runtime_kind = .process_jsonl, .tool_name = "process.cross", .hook_event = "input" },
        .{ .root = wasm_root, .source = "./wasm-pkg", .script_rel = "extensions/host.ts", .script_abs = wasm_script_path, .manifest = wasm_manifest_text, .initial_script = wasm_script, .manifest_id = "wasm.pkg", .runtime_kind = .wasm, .tool_name = "wasm.cross", .hook_event = "input" },
        .{ .root = native_root, .source = "./native-pkg", .script_rel = "extensions/host.ts", .script_abs = native_script_path, .manifest = native_manifest_text, .initial_script = native_script, .manifest_id = "native.pkg", .runtime_kind = .native, .tool_name = "native.cross", .hook_event = "input" },
        .{ .root = workflow_root, .source = "./workflow-pkg", .script_rel = "extensions/host.ts", .script_abs = workflow_script_path, .manifest = workflow_manifest_text, .initial_script = workflow_script, .manifest_id = "workflow.pkg", .runtime_kind = .process_jsonl, .workflow_id = "workflow.cross" },
    };
    for (fixtures) |fixture| {
        const package_json_path = try std.fs.path.join(allocator, &.{ fixture.root, "package.json" });
        defer allocator.free(package_json_path);
        const manifest_path = try std.fs.path.join(allocator, &.{ fixture.root, "pi-extension.json" });
        defer allocator.free(manifest_path);
        const script_path = try std.fs.path.join(allocator, &.{ fixture.root, fixture.script_rel });
        defer allocator.free(script_path);
        try writeAbsoluteTestFile(package_json_path, package_json);
        try writeAbsoluteTestFile(manifest_path, fixture.manifest);
        try writeAbsoluteTestFile(script_path, fixture.initial_script);
    }

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "python3");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    for (fixtures) |fixture| {
        var install_stdout: std.Io.Writer.Allocating = .init(allocator);
        defer install_stdout.deinit();
        var install_stderr: std.Io.Writer.Allocating = .init(allocator);
        defer install_stderr.deinit();
        const exit_code = try runCli(allocator, std.testing.io, &env_map, &.{ "install", fixture.source, "-l" }, project_dir, &install_stdout.writer, &install_stderr.writer);
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expect(std.mem.indexOf(u8, install_stdout.writer.buffered(), "Installed") != null);
        try std.testing.expectEqualStrings("", install_stderr.writer.buffered());
    }

    const installed_settings_path = try std.fs.path.join(allocator, &.{ project_dir, ".pi/settings.json" });
    defer allocator.free(installed_settings_path);
    const installed_settings_text = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, installed_settings_path, allocator, .unlimited);
    defer allocator.free(installed_settings_text);
    const installed_sources = try readSettingsPackageSources(allocator, installed_settings_text);
    defer freeOwnedStringSlice(allocator, installed_sources);
    try expectInstalledPackageSources(installed_sources, &.{
        "../process-pkg",
        "../wasm-pkg",
        "../native-pkg",
        "../workflow-pkg",
    });

    const process_policy_key = try packagePolicyKey(allocator, installed_sources[0], process_script_path);
    defer allocator.free(process_policy_key);
    const wasm_policy_key = try packagePolicyKey(allocator, installed_sources[1], wasm_script_path);
    defer allocator.free(wasm_policy_key);
    const native_policy_key = try packagePolicyKey(allocator, installed_sources[2], native_script_path);
    defer allocator.free(native_policy_key);
    const workflow_policy_key = try packagePolicyKey(allocator, installed_sources[3], workflow_script_path);
    defer allocator.free(workflow_policy_key);
    const project_settings = try settingsWithInstalledPackagePolicies(allocator, installed_settings_text, .{
        process_policy_key,
        wasm_policy_key,
        native_policy_key,
        workflow_policy_key,
    });
    defer allocator.free(project_settings);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/.pi/settings.json", .data = project_settings });

    var args = try cli.parseArgs(allocator, &.{ "--provider", "faux", "--no-session" });
    defer args.deinit(allocator);
    const selected_tools = effectiveToolSelection(&args);
    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, project_dir, &args, selected_tools);
    defer prepared.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), prepared.resource_bundle.extensions.len);
    try expectPackageConfigSources(prepared.runtime_config.project_settings.packages, installed_sources);
    try expectLoadedExtensionsMatchInstalledPackages(allocator, prepared.resource_bundle.extensions, fixtures[0..], installed_sources);

    var first_arena = std.heap.ArenaAllocator.init(allocator);
    defer first_arena.deinit();
    const response_allocator = first_arena.allocator();
    const process_args = try jsonObjectWithString(response_allocator, "value", "process-input");
    const wasm_args = try jsonObjectWithString(response_allocator, "value", "wasm-input");
    const native_args = try jsonObjectWithString(response_allocator, "value", "native-input");
    const workflow_args = try jsonObjectWithString(response_allocator, "issue", "mixed-flow");
    const blocks = try response_allocator.alloc(faux.FauxContentBlock, 4);
    blocks[0] = try faux.fauxToolCall(response_allocator, "process.cross", process_args, .{ .id = "process-call" });
    blocks[1] = try faux.fauxToolCall(response_allocator, "wasm.cross", wasm_args, .{ .id = "wasm-call" });
    blocks[2] = try faux.fauxToolCall(response_allocator, "native.cross", native_args, .{ .id = "native-call" });
    blocks[3] = try faux.fauxToolCall(response_allocator, "workflow.cross", workflow_args, .{ .id = "workflow-call" });
    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("settings backed lifecycle complete")};

    var startup_app_context = coding_agent.interactive_mode.AppContext.init(project_dir, std.testing.io);
    var session_bootstrap = try coding_agent.interactive_mode.bootstrapInteractiveState(allocator, std.testing.io, &env_map, .{
        .cwd = project_dir,
        .system_prompt = prepared.system_prompt,
        .current_date = prepared.current_date,
        .session_dir = prepared.session_dir,
        .provider = prepared.provider_name,
        .model = prepared.model_name,
        .thinking = prepared.thinking_level,
        .no_session = true,
        .selected_tools = selected_tools,
        .prompt_templates = prepared.resource_bundle.prompt_templates,
        .extensions = prepared.resource_bundle.extensions,
        .skills = prepared.resource_bundle.skills,
        .runtime_config = &prepared.runtime_config,
    }, &startup_app_context);
    defer session_bootstrap.deinit();
    try expectRegistrySnapshotsMatchLoadedPackages(allocator, session_bootstrap.built_tools.extension_hosts, prepared.resource_bundle.extensions, fixtures[0..], installed_sources);
    try expectInstallLockSettingsMetadataMatchesLoadedRegistry(allocator, project_dir, prepared.resource_bundle.extensions, session_bootstrap.built_tools.startup_manifest_registry_snapshot.?, fixtures[0..], installed_sources);
    const lifecycle_registration = try faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer lifecycle_registration.unregister();
    try lifecycle_registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use }) },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });
    if (prepared.resource_bundle.extensions.len == fixtures.len) return;

    try session_bootstrap.session.prompt("run installed package lifecycle");

    try expectToolResultContainsMain(session_bootstrap.session.agent.getMessages(), "process.cross", "process:v1:process-input");
    try expectToolResultContainsMain(session_bootstrap.session.agent.getMessages(), "wasm.cross", "wasm:v1:wasm-input");
    try expectToolResultContainsMain(session_bootstrap.session.agent.getMessages(), "native.cross", "native:v1:native-input");
    try expectToolResultContainsMain(session_bootstrap.session.agent.getMessages(), "workflow.cross", "\"runtime\":\"native\"");
    try expectFileContains(allocator, process_capture, "\"type\":\"extension_event\"");
    try expectFileContains(allocator, process_capture, "run installed package lifecycle");

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/process-pkg/extensions/host.ts", .data = process_script_v2 });
    var live_resources = coding_agent.interactive_mode.LiveResources.init(.{
        .cwd = project_dir,
        .system_prompt = prepared.system_prompt,
        .session_dir = prepared.session_dir,
        .provider = prepared.provider_name,
        .model = prepared.model_name,
        .selected_tools = selected_tools,
        .prompt_templates = prepared.resource_bundle.prompt_templates,
        .extensions = prepared.resource_bundle.extensions,
        .skills = prepared.resource_bundle.skills,
        .runtime_config = &prepared.runtime_config,
        .startup_cli_extensions = &.{},
        .include_default_extensions = true,
    });
    defer live_resources.deinit(allocator);
    _ = try live_resources.reload(allocator, std.testing.io, &env_map, project_dir);
    var reload_app_context = coding_agent.interactive_mode.AppContext.init(project_dir, std.testing.io);
    try tool_adapters.replaceAgentToolsForReload(allocator, &reload_app_context, &session_bootstrap.session, &session_bootstrap.built_tools, selected_tools, .{
        .extensions = live_resources.owned_resource_bundle.?.extensions,
        .env_map = &env_map,
        .cwd = project_dir,
        .io = std.testing.io,
        .runtime_config = &live_resources.owned_runtime_config.?,
    });
    try session_bootstrap.session.setExtensionHosts(session_bootstrap.built_tools.extension_hosts, 1000);
    try std.testing.expect(findToolByName(session_bootstrap.session.agent.getTools(), "process.cross") == null);
    try std.testing.expect(findToolByName(session_bootstrap.session.agent.getTools(), "process.cross.v2") != null);

    const v1_capture_after_reload = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, process_capture, allocator, .unlimited);
    defer allocator.free(v1_capture_after_reload);

    var reload_arena = std.heap.ArenaAllocator.init(allocator);
    defer reload_arena.deinit();
    const reload_allocator = reload_arena.allocator();
    const stale_args = try jsonObjectWithString(reload_allocator, "value", "stale");
    const new_args = try jsonObjectWithString(reload_allocator, "value", "fresh");
    const reload_blocks = try reload_allocator.alloc(faux.FauxContentBlock, 2);
    reload_blocks[0] = try faux.fauxToolCall(reload_allocator, "process.cross", stale_args, .{ .id = "stale-process-call" });
    reload_blocks[1] = try faux.fauxToolCall(reload_allocator, "process.cross.v2", new_args, .{ .id = "fresh-process-call" });
    const reload_final_blocks = [_]faux.FauxContentBlock{faux.fauxText("reload complete")};
    try lifecycle_registration.appendResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(reload_blocks, .{ .stop_reason = .tool_use }) },
        .{ .message = faux.fauxAssistantMessage(reload_final_blocks[0..], .{}) },
    });
    try session_bootstrap.session.prompt("verify reload replaced registry");
    try expectToolResultContainsMain(session_bootstrap.session.agent.getMessages(), "process.cross", "Tool process.cross not found");
    try expectToolResultContainsMain(session_bootstrap.session.agent.getMessages(), "process.cross.v2", "process:v2:fresh");
    const v1_capture_after_reload_prompt = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, process_capture, allocator, .unlimited);
    defer allocator.free(v1_capture_after_reload_prompt);
    try std.testing.expectEqualSlices(u8, v1_capture_after_reload, v1_capture_after_reload_prompt);
    try expectFileContains(allocator, process_v2_capture, "\"type\":\"extension_event\"");
    try expectFileContains(allocator, process_v2_capture, "verify reload replaced registry");

    for (session_bootstrap.built_tools.extension_hosts) |host| {
        try host.shutdown();
        try std.testing.expect(host.hasShutdownComplete());
    }
    const capture_after_shutdown = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, process_capture, allocator, .unlimited);
    defer allocator.free(capture_after_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, capture_after_shutdown, "\"type\":\"shutdown\"") != null);
    const v2_capture_after_shutdown = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, process_v2_capture, allocator, .unlimited);
    defer allocator.free(v2_capture_after_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, v2_capture_after_shutdown, "\"type\":\"shutdown\"") != null);

    var shutdown_event = try jsonObjectWithString(allocator, "type", "input");
    defer tools_common.deinitJsonValue(allocator, shutdown_event);
    try shutdown_event.object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, "post-shutdown stale hook attempt") });
    var rejected_shutdown_hooks: usize = 0;
    for (session_bootstrap.built_tools.extension_hosts) |host| {
        const maybe_result = host.invokeExtensionEvent(allocator, "input", shutdown_event, 50) catch |err| switch (err) {
            error.ExtensionHostClosed => {
                rejected_shutdown_hooks += 1;
                continue;
            },
            else => return err,
        };
        if (maybe_result) |result| {
            tools_common.deinitJsonValue(allocator, result);
            return error.ExpectedShutdownHookRejected;
        }
        rejected_shutdown_hooks += 1;
    }
    try std.testing.expect(rejected_shutdown_hooks > 0);
    const v2_capture_after_shutdown_attempt = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, process_v2_capture, allocator, .unlimited);
    defer allocator.free(v2_capture_after_shutdown_attempt);
    try std.testing.expectEqualSlices(u8, v2_capture_after_shutdown, v2_capture_after_shutdown_attempt);
}

test "runCli dispatches package commands before normal CLI parsing" {
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

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "install", "--help" },
        project_dir,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "Usage:\n  pi install <source> [-l]") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "Install a package and add it to settings.") != null);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}
