const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const cli = @import("cli/args.zig");
const bootstrap = @import("cli/bootstrap.zig");
const package_command_dispatch = @import("cli/package_command_dispatch.zig");
const cli_preflight = @import("cli/preflight.zig");
const extension_cli = @import("cli/extension_cli.zig");
const input_prep = @import("cli/input_prep.zig");
const runtime_prep = @import("cli/runtime_prep.zig");
const run_mode_dispatch = @import("cli/run_mode_dispatch.zig");
const output = @import("cli/output.zig");
const coding_agent = @import("coding_agent/root.zig");
const config_mod = @import("coding_agent/config/config.zig");
const resources_mod = @import("coding_agent/resources/resources.zig");
const tools_common = @import("coding_agent/tools/common.zig");
const tool_adapters = @import("coding_agent/interactive_mode/tool_adapters.zig");
const json_event_wire = @import("coding_agent/modes/json_event_wire.zig");
const builtin = @import("builtin");
const cli_test = if (builtin.is_test) @import("cli/test_harness.zig") else struct {};

const VERSION = "0.1.0";

const CliStdin = input_prep.CliStdin;
const effectiveToolSelection = bootstrap.effectiveToolSelection;
const offlineModeEnabled = bootstrap.offlineModeEnabled;
const prepareCliRuntime = runtime_prep.prepareCliRuntime;
const startupNetworkOperationsEnabled = bootstrap.startupNetworkOperationsEnabled;

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(init.gpa);
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();
    while (it.next()) |arg| {
        try argv.append(init.gpa, arg);
    }

    const exit_code = try runCliWithInput(init.gpa, init.io, init.environ_map, argv.items, null, null, stdout, stderr);
    try output.flushWriters(stdout, stderr);
    if (exit_code != 0) std.process.exit(exit_code);
}

pub fn runCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argv: []const []const u8,
    cwd_override: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var stdin_input = CliStdin{};
    return runCliWithInput(allocator, io, env_map, argv, cwd_override, &stdin_input, stdout, stderr);
}

fn runCliWithInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argv: []const []const u8,
    cwd_override: ?[]const u8,
    provided_stdin: ?*CliStdin,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (try package_command_dispatch.dispatchPackageCommand(
        allocator,
        io,
        env_map,
        argv,
        cwd_override,
        stdout,
        stderr,
    )) |exit_code| {
        return exit_code;
    }

    var options = bootstrap.parseArgs(allocator, argv) catch |err| {
        try stderr.print("Error: {s}\n\n", .{bootstrap.parseErrorMessage(err)});
        try output.printUsage(allocator, VERSION, stdout);
        return 1;
    };
    defer options.deinit(allocator);

    var prepared_extensions = extension_cli.PreparedExtensionCli.init(allocator);
    defer prepared_extensions.deinit();
    try prepared_extensions.loadFlagSidecars(io, options.extensions);

    if (options.help) {
        const help_flags = try prepared_extensions.snapshotHelpFlags(allocator);
        defer allocator.free(help_flags);
        const help_flag_diagnostics = try prepared_extensions.snapshotHelpDiagnostics(allocator);
        defer allocator.free(help_flag_diagnostics);
        try output.printUsageWithExtensionDiagnostics(allocator, VERSION, help_flags, help_flag_diagnostics, stdout);
        return 0;
    }

    if (options.version) {
        try output.printVersion(allocator, VERSION, stdout);
        return 0;
    }

    if (!try prepared_extensions.applyUnknownFlags(options.unknown_flags, stderr)) return 1;

    if (extension_cli.shouldRunRegistryDump(env_map, options.extensions)) {
        const paths = options.extensions.?;
        return try extension_cli.runExtensionRegistryDump(
            allocator,
            io,
            env_map,
            paths,
            prepared_extensions.rejectedFlagDiagnostics(),
            prepared_extensions.parsedCliFlagValues(),
            cwd_override,
            stdout,
            stderr,
        );
    }

    var effective_env_map = try prepareEffectiveEnvMap(allocator, env_map, &options);
    defer effective_env_map.deinit();

    if (options.@"export") |session_file| {
        const output_path = if (options.messages) |messages| if (messages.len > 0) messages[0] else null else null;
        return output.runSessionExport(allocator, io, &effective_env_map, cwd_override, session_file, output_path, stdout, stderr) catch |err| {
            try stderr.print("Error: {s}\n", .{output.exportErrorMessage(err)});
            return 1;
        };
    }

    var detected_stdin = if (provided_stdin) |stdin_override|
        CliStdin{
            .is_tty = stdin_override.is_tty,
            .content = stdin_override.content,
            .owns_content = false,
        }
    else
        try input_prep.detectCliStdin(allocator, io, options.mode);
    defer if (provided_stdin == null) detected_stdin.deinit(allocator);

    if (options.list_models) {
        return try output.printModelList(
            allocator,
            io,
            &effective_env_map,
            options.list_models_search,
            startupNetworkOperationsEnabled(&options, &effective_env_map),
            stdout,
        );
    }

    if (options.fork != null and
        (options.session != null or options.@"continue" or options.@"resume" or options.no_session))
    {
        try stderr.writeAll("Error: --fork cannot be combined with --session, --continue, --resume, or --no-session\n");
        return 1;
    }

    if ((options.mode == .rpc or options.mode == .ts_rpc) and options.messages != null) {
        try stderr.writeAll("Error: Prompt arguments are not supported in RPC mode\n");
        return 1;
    }

    if ((options.mode == .rpc or options.mode == .ts_rpc) and options.file_args != null) {
        try stderr.writeAll("Error: @file arguments are not supported in RPC mode\n");
        return 1;
    }

    const app_mode = bootstrap.resolveAppMode(options.mode, options.print, detected_stdin.is_tty);
    const selected_tools = bootstrap.effectiveToolSelection(&options);
    const cwd = if (cwd_override) |override| blk: {
        break :blk try allocator.dupe(u8, override);
    } else blk: {
        const real_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        defer allocator.free(real_cwd);
        break :blk try allocator.dupe(u8, real_cwd);
    };
    defer allocator.free(cwd);

    // M10 lifecycle ordering: surface a missing stored-cwd diagnostic BEFORE
    // `prepareCliRuntime` runs. `prepareCliRuntime` loads runtime config,
    // resource bundles, context files, the system prompt, and may select an
    // initial provider/model. Any of those steps can fail (invalid settings,
    // bad context files, unknown provider, etc.) and would otherwise
    // preempt the missing-cwd diagnostic that the user actually needs to
    // see. Mirrors TS `main.ts` ordering, which checks
    // `getMissingSessionCwdIssue` before constructing the runtime.
    //
    // The interactive path additionally prompts the user via the same
    // Continue/Cancel selector that the post-bootstrap guard uses; on
    // Continue we set `missing_cwd_already_confirmed` so the deeper
    // bootstrap path does not prompt twice.
    var preflight_continue_confirmed = false;
    {
        const preflight_session_dir = try cli_preflight.resolvePreRuntimeSessionDir(
            allocator,
            io,
            &effective_env_map,
            cwd,
            &options,
        );
        defer allocator.free(preflight_session_dir);

        const preflight_result = try cli_preflight.runMissingSessionCwdPreflight(
            allocator,
            io,
            &effective_env_map,
            cli_preflight.preRuntimeContext(cwd, preflight_session_dir, &options),
            app_mode == .interactive,
            stderr,
        );
        if (preflight_result.exit_code) |exit_code| return exit_code;
        preflight_continue_confirmed = preflight_result.continue_confirmed;
    }

    var prepared = try runtime_prep.prepareCliRuntime(allocator, io, &effective_env_map, cwd, &options, selected_tools);
    defer prepared.deinit(allocator);
    try output.writeResourceDiagnostics(stderr, prepared.resource_bundle.diagnostics);

    var initial_input = input_prep.prepareInitialInput(
        allocator,
        io,
        &effective_env_map,
        cwd,
        options.file_args,
        prepared.expanded_messages,
        detected_stdin.content,
        stderr,
        .{ .auto_resize_images = prepared.runtime_config.imageAutoResize() },
    ) catch |err| switch (err) {
        error.CliInputFailed => return 1,
        else => return err,
    };
    defer initial_input.deinit(allocator);

    return try run_mode_dispatch.dispatchRunMode(
        allocator,
        io,
        &effective_env_map,
        &options,
        &prepared,
        &initial_input,
        .{
            .cwd = cwd,
            .app_mode = app_mode,
            .selected_tools = selected_tools,
            .preflight_continue_confirmed = preflight_continue_confirmed,
            .version = VERSION,
        },
        stdout,
        stderr,
    );
}

fn prepareEffectiveEnvMap(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    options: *const cli.Args,
) !std.process.Environ.Map {
    var effective_env_map = try env_map.clone(allocator);
    errdefer effective_env_map.deinit();

    if (offlineModeEnabled(options, env_map)) {
        try effective_env_map.put("PI_OFFLINE", "1");
        try effective_env_map.put("PI_SKIP_VERSION_CHECK", "1");
    }

    return effective_env_map;
}

test "main help text includes expected CLI options" {
    const allocator = std.testing.allocator;
    const help = try cli.helpText(allocator, VERSION);
    defer allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "--model <model>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--provider <provider>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--api-key <key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--thinking <level>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--continue, -c") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--resume, -r") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--session <id|path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--fork <id|path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--session-dir <dir>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-session") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--models <patterns>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--list-models [search]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--print, -p") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--mode, -mode <mode>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "rpc, json-rpc") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--tools, -t <names>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-tools, -nt") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-builtin-tools, -nbt") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-context-files, -nc") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--export <file>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--offline") != null);
}

test "effectiveToolSelection disables built-in tools when requested" {
    const allocator = std.testing.allocator;

    var no_builtin_args = try cli.parseArgs(allocator, &.{"--no-builtin-tools"});
    defer no_builtin_args.deinit(allocator);
    const no_builtin_selection = effectiveToolSelection(&no_builtin_args);
    try std.testing.expect(!no_builtin_selection.allowsBuiltin("read"));
    try std.testing.expect(no_builtin_selection.allowsExtension("ext-echo"));

    var explicit_args = try cli.parseArgs(allocator, &.{
        "--no-builtin-tools",
        "--tools",
        "read,ls",
    });
    defer explicit_args.deinit(allocator);
    const explicit_selection = effectiveToolSelection(&explicit_args);
    try std.testing.expect(!explicit_selection.allowsBuiltin("read"));
    try std.testing.expect(!explicit_selection.allowsBuiltin("ls"));
    try std.testing.expect(!explicit_selection.allowsExtension("ext-echo"));
    try std.testing.expect(explicit_selection.allowsExtension("read"));

    var app_context = coding_agent.interactive_mode.AppContext.init("/tmp", std.testing.io);
    var built_tools = try coding_agent.interactive_mode.buildAgentToolsWithSelection(allocator, &app_context, no_builtin_selection);
    defer built_tools.deinit();
    try std.testing.expectEqual(@as(usize, 0), built_tools.items.len);
}

test "startup network operations respect CLI offline flag and environment" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var default_args = try cli.parseArgs(allocator, &.{});
    defer default_args.deinit(allocator);
    try std.testing.expect(startupNetworkOperationsEnabled(&default_args, &env_map));

    var offline_args = try cli.parseArgs(allocator, &.{"--offline"});
    defer offline_args.deinit(allocator);
    try std.testing.expect(!startupNetworkOperationsEnabled(&offline_args, &env_map));

    try env_map.put("PI_OFFLINE", "true");
    try std.testing.expect(!startupNetworkOperationsEnabled(&default_args, &env_map));
}

test "prepareEffectiveEnvMap sets offline environment overrides" {
    const allocator = std.testing.allocator;

    var base_env_map = std.process.Environ.Map.init(allocator);
    defer base_env_map.deinit();
    try base_env_map.put("HOME", "/tmp/home");

    var offline_args = try cli.parseArgs(allocator, &.{"--offline"});
    defer offline_args.deinit(allocator);

    var effective_env_map = try prepareEffectiveEnvMap(allocator, &base_env_map, &offline_args);
    defer effective_env_map.deinit();

    try std.testing.expectEqualStrings("/tmp/home", effective_env_map.get("HOME").?);
    try std.testing.expectEqualStrings("1", effective_env_map.get("PI_OFFLINE").?);
    try std.testing.expectEqualStrings("1", effective_env_map.get("PI_SKIP_VERSION_CHECK").?);
    try std.testing.expect(base_env_map.get("PI_OFFLINE") == null);
    try std.testing.expect(base_env_map.get("PI_SKIP_VERSION_CHECK") == null);
}

test "prepareEffectiveEnvMap promotes PI_OFFLINE into PI_SKIP_VERSION_CHECK" {
    const allocator = std.testing.allocator;

    var base_env_map = std.process.Environ.Map.init(allocator);
    defer base_env_map.deinit();
    try base_env_map.put("PI_OFFLINE", "true");

    var default_args = try cli.parseArgs(allocator, &.{});
    defer default_args.deinit(allocator);

    var effective_env_map = try prepareEffectiveEnvMap(allocator, &base_env_map, &default_args);
    defer effective_env_map.deinit();

    try std.testing.expectEqualStrings("1", effective_env_map.get("PI_OFFLINE").?);
    try std.testing.expectEqualStrings("1", effective_env_map.get("PI_SKIP_VERSION_CHECK").?);
}

test "runCli lists models and applies optional search" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-key");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--list-models", "sonnet" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "claude-sonnet-4-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "gpt-5.4") == null);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "runCli prints faux response end to end" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "hello from cli");

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
    try std.testing.expectEqualStrings("hello from cli\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "VAL-CROSS-010 settings backed package lifecycle e2e uses normal startup reload shutdown" {
    const allocator = std.testing.allocator;
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

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
        \\{"pi":{"extensions":["extensions/host.py"]}}
    ;
    const process_script_path = try std.fs.path.join(allocator, &.{ process_root, "extensions/host.py" });
    defer allocator.free(process_script_path);
    const wasm_script_path = try std.fs.path.join(allocator, &.{ wasm_root, "extensions/host.py" });
    defer allocator.free(wasm_script_path);
    const native_script_path = try std.fs.path.join(allocator, &.{ native_root, "extensions/host.py" });
    defer allocator.free(native_script_path);
    const workflow_script_path = try std.fs.path.join(allocator, &.{ workflow_root, "extensions/host.py" });
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
        \\{"schemaVersion":"pi-extension.v1","id":"process.pkg","name":"Process Runtime Package","version":"1.0.0","runtime":{"kind":"process_jsonl","entrypoint":{"argv":["python3","extensions/host.py"]}},"tools":[{"name":"process.cross","description":"Process package tool","inputSchema":{"type":"object","required":["value"],"properties":{"value":{"type":"string"}},"additionalProperties":false}}],"hooks":[{"event":"input","hookId":"process.input","priority":-30,"declarationOrder":0}],"capabilities":{"exports":[{"id":"process.cross","kind":"tool","version":"1.0.0"}]}}
    ;
    const wasm_manifest_text =
        \\{"schemaVersion":"pi-extension.v1","id":"wasm.pkg","name":"WASM Runtime Package","version":"1.0.0","runtime":{"kind":"wasm","entrypoint":{"artifactPath":"wasm/plugin.wasm"}},"dependencies":[{"id":"process.pkg","version":"^1.0.0"}],"tools":[{"name":"wasm.cross","description":"WASM package tool","inputSchema":{"type":"object","required":["value"],"properties":{"value":{"type":"string"}},"additionalProperties":false}}],"hooks":[{"event":"input","hookId":"wasm.input","priority":-20,"declarationOrder":0}],"capabilities":{"exports":[{"id":"wasm.cross","kind":"tool","version":"1.0.0"}]}}
    ;
    const native_manifest_text =
        \\{"schemaVersion":"pi-extension.v1","id":"native.pkg","name":"Native Runtime Package","version":"1.0.0","runtime":{"kind":"native","entrypoint":{"descriptor":"native_static_descriptor"}},"dependencies":[{"id":"wasm.pkg","version":"^1.0.0"}],"tools":[{"name":"native.cross","description":"Native package tool","inputSchema":{"type":"object","required":["value"],"properties":{"value":{"type":"string"}},"additionalProperties":false}}],"hooks":[{"event":"input","hookId":"native.input","priority":-10,"declarationOrder":0}],"capabilities":{"exports":[{"id":"native.cross","kind":"tool","version":"1.0.0"}]}}
    ;
    const workflow_manifest_text =
        \\{"schemaVersion":"pi-extension.v1","id":"workflow.pkg","name":"Workflow Package","version":"1.0.0","runtime":{"kind":"process_jsonl","entrypoint":{"argv":["python3","extensions/host.py"]}},"dependencies":[{"id":"native.pkg","version":"^1.0.0"}],"capabilities":{"imports":[{"id":"process.cross","kind":"tool","version":"^1.0.0"},{"id":"wasm.cross","kind":"tool","version":"^1.0.0"},{"id":"native.cross","kind":"tool","version":"^1.0.0"}]},"workflows":[{"id":"workflow.cross","description":"Settings backed mixed workflow","exposure":{"tool":"workflow.cross"},"inputSchema":{"type":"object","required":["issue"],"properties":{"issue":{"type":"string"}},"additionalProperties":false},"outputSchema":{"type":"object"},"steps":[{"id":"process","kind":"side_effect","input":{"value":"workflow-process"},"replayMode":"recorded","selectedCapability":"process.cross"},{"id":"wasm","kind":"side_effect","input":{"value":"workflow-wasm"},"replayMode":"recorded","selectedCapability":"wasm.cross"},{"id":"native","kind":"side_effect","input":{"value":"workflow-native"},"replayMode":"recorded","selectedCapability":"native.cross"}]}]}
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
        .{ .root = process_root, .source = "./process-pkg", .script_rel = "extensions/host.py", .script_abs = process_script_path, .manifest = process_manifest, .initial_script = process_script_v1, .manifest_id = "process.pkg", .runtime_kind = .process_jsonl, .tool_name = "process.cross", .hook_event = "input" },
        .{ .root = wasm_root, .source = "./wasm-pkg", .script_rel = "extensions/host.py", .script_abs = wasm_script_path, .manifest = wasm_manifest_text, .initial_script = wasm_script, .manifest_id = "wasm.pkg", .runtime_kind = .wasm, .tool_name = "wasm.cross", .hook_event = "input" },
        .{ .root = native_root, .source = "./native-pkg", .script_rel = "extensions/host.py", .script_abs = native_script_path, .manifest = native_manifest_text, .initial_script = native_script, .manifest_id = "native.pkg", .runtime_kind = .native, .tool_name = "native.cross", .hook_event = "input" },
        .{ .root = workflow_root, .source = "./workflow-pkg", .script_rel = "extensions/host.py", .script_abs = workflow_script_path, .manifest = workflow_manifest_text, .initial_script = workflow_script, .manifest_id = "workflow.pkg", .runtime_kind = .process_jsonl, .workflow_id = "workflow.cross" },
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
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use }) },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

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
    try session_bootstrap.session.prompt("run installed package lifecycle");

    try expectToolResultContainsMain(session_bootstrap.session.agent.getMessages(), "process.cross", "process:v1:process-input");
    try expectToolResultContainsMain(session_bootstrap.session.agent.getMessages(), "wasm.cross", "wasm:v1:wasm-input");
    try expectToolResultContainsMain(session_bootstrap.session.agent.getMessages(), "native.cross", "native:v1:native-input");
    try expectToolResultContainsMain(session_bootstrap.session.agent.getMessages(), "workflow.cross", "workflow-native");
    try expectFileContains(allocator, process_capture, "\"type\":\"extension_event\"");
    try expectFileContains(allocator, process_capture, "run installed package lifecycle");

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/process-pkg/extensions/host.py", .data = process_script_v2 });
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
    try registration.appendResponses(&[_]faux.FauxResponseStep{
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
        if (!host.hasRegisteredHook("input")) continue;
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

const LifecyclePackageFixture = struct {
    root: []const u8,
    source: []const u8,
    script_rel: []const u8,
    script_abs: []const u8,
    manifest: []const u8,
    initial_script: []const u8,
    manifest_id: []const u8,
    runtime_kind: coding_agent.extension_manifest.RuntimeKind,
    tool_name: ?[]const u8 = null,
    hook_event: ?[]const u8 = null,
    workflow_id: ?[]const u8 = null,
};

fn readSettingsPackageSources(allocator: std.mem.Allocator, settings_text: []const u8) ![][]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, settings_text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const packages = parsed.value.object.get("packages") orelse return error.ExpectedSettingsPackages;
    try std.testing.expect(packages == .array);

    var sources = std.ArrayList([]u8).empty;
    errdefer freeOwnedStringSlice(allocator, sources.items);
    for (packages.array.items) |entry| {
        switch (entry) {
            .string => |source| try sources.append(allocator, try allocator.dupe(u8, source)),
            .object => |object| {
                const source_value = object.get("source") orelse return error.ExpectedSettingsPackageSource;
                try std.testing.expect(source_value == .string);
                try sources.append(allocator, try allocator.dupe(u8, source_value.string));
            },
            else => return error.ExpectedSettingsPackageSource,
        }
    }
    return try sources.toOwnedSlice(allocator);
}

fn freeOwnedStringSlice(allocator: std.mem.Allocator, values: []const []u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn expectInstalledPackageSources(actual: []const []u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |actual_source, expected_source| {
        try std.testing.expectEqualStrings(expected_source, actual_source);
    }
}

fn settingsWithInstalledPackagePolicies(
    allocator: std.mem.Allocator,
    installed_settings_text: []const u8,
    policy_keys: [4][]const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, installed_settings_text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    var root = try tools_common.cloneJsonValue(allocator, parsed.value);
    defer tools_common.deinitJsonValue(allocator, root);
    try std.testing.expect(root == .object);

    var policies = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer tools_common.deinitJsonValue(allocator, .{ .object = policies });
    for (policy_keys, 0..) |policy_key, index| {
        _ = index;
        var policy = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer tools_common.deinitJsonValue(allocator, .{ .object = policy });
        try policy.put(allocator, try allocator.dupe(u8, "approved"), .{ .bool = true });
        var grants = std.json.Array.init(allocator);
        errdefer tools_common.deinitJsonValue(allocator, .{ .array = grants });
        try grants.append(.{ .string = try allocator.dupe(u8, "tool.use") });
        try policy.put(allocator, try allocator.dupe(u8, "approvedGrants"), .{ .array = grants });
        var limits = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer tools_common.deinitJsonValue(allocator, .{ .object = limits });
        try limits.put(allocator, try allocator.dupe(u8, "timeoutMs"), .{ .integer = 500 });
        try policy.put(allocator, try allocator.dupe(u8, "resourceLimits"), .{ .object = limits });
        try policies.put(allocator, try allocator.dupe(u8, policy_key), .{ .object = policy });
    }
    if (root.object.getPtr("extensionPolicies")) |existing| {
        tools_common.deinitJsonValue(allocator, existing.*);
        existing.* = .{ .object = policies };
    } else {
        try root.object.put(allocator, try allocator.dupe(u8, "extensionPolicies"), .{ .object = policies });
    }
    return std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 });
}

fn writeJsonStringValue(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = value }, .{});
    defer allocator.free(encoded);
    try writer.writeAll(encoded);
}

fn expectPackageConfigSources(packages: ?[]const resources_mod.PackageSourceConfig, installed_sources: []const []u8) !void {
    const package_config = packages orelse return error.ExpectedSettingsPackages;
    try std.testing.expectEqual(installed_sources.len, package_config.len);
    for (package_config, installed_sources) |package_source, installed_source| {
        try std.testing.expectEqualStrings(installed_source, package_source.source);
    }
}

fn expectLoadedExtensionsMatchInstalledPackages(
    allocator: std.mem.Allocator,
    extensions: []const resources_mod.LoadedExtension,
    fixtures: []const LifecyclePackageFixture,
    installed_sources: []const []u8,
) !void {
    try std.testing.expectEqual(fixtures.len, installed_sources.len);
    for (fixtures, installed_sources) |fixture, installed_source| {
        const extension = loadedExtensionForSource(extensions, installed_source) orelse return error.ExpectedLoadedPackageExtension;
        try std.testing.expectEqualStrings(fixture.script_abs, extension.path);
        try std.testing.expectEqualStrings("package", @tagName(extension.source_info.origin));
        try std.testing.expectEqualStrings("project", @tagName(extension.source_info.scope));
        try std.testing.expectEqualStrings(installed_source, extension.source_info.source);
        try std.testing.expect(extension.source_info.base_dir != null);
        try std.testing.expectEqualStrings(fixture.root, extension.source_info.base_dir.?);
        try expectLoadedExtensionManifestMetadata(allocator, extension.*, fixture);
    }
}

fn loadedExtensionForSource(
    extensions: []const resources_mod.LoadedExtension,
    source: []const u8,
) ?*const resources_mod.LoadedExtension {
    for (extensions) |*extension| {
        if (std.mem.eql(u8, extension.source_info.source, source)) return extension;
    }
    return null;
}

fn expectLoadedExtensionManifestMetadata(
    allocator: std.mem.Allocator,
    extension: resources_mod.LoadedExtension,
    fixture: LifecyclePackageFixture,
) !void {
    const package_root = extension.source_info.base_dir orelse return error.ExpectedLoadedPackageExtension;
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, "pi-extension.json" });
    defer allocator.free(manifest_path);
    const manifest_text = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, manifest_path, allocator, .limited(256 * 1024));
    defer allocator.free(manifest_text);
    var sources = [_]coding_agent.extension_manifest.ManifestSource{.{
        .package_root = package_root,
        .manifest_path = manifest_path,
        .manifest_text = manifest_text,
        .source_scope = "project-installed-settings",
        .precedence_rank = 0,
    }};
    var manifest_set = try coding_agent.extension_manifest.resolveManifestSources(allocator, sources[0..]);
    defer manifest_set.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), manifest_set.records.len);
    try std.testing.expectEqualStrings(fixture.manifest_id, manifest_set.records[0].manifest.id);
    try std.testing.expectEqual(fixture.runtime_kind, manifest_set.records[0].manifest.runtime_kind);
}

fn expectRegistrySnapshotsMatchLoadedPackages(
    allocator: std.mem.Allocator,
    hosts: []const coding_agent.extension_runtime.RuntimeAdapter,
    extensions: []const resources_mod.LoadedExtension,
    fixtures: []const LifecyclePackageFixture,
    installed_sources: []const []u8,
) !void {
    for (fixtures, installed_sources) |fixture, installed_source| {
        const extension = loadedExtensionForSource(extensions, installed_source) orelse return error.ExpectedLoadedPackageExtension;
        var found = false;
        for (hosts) |host| {
            const snapshot = try host.snapshotRegistryJson(allocator);
            defer allocator.free(snapshot);
            if (std.mem.indexOf(u8, snapshot, extension.path) == null) continue;
            if (fixture.tool_name) |tool_name| try std.testing.expect(std.mem.indexOf(u8, snapshot, tool_name) != null);
            if (fixture.hook_event) |hook_event| try std.testing.expect(std.mem.indexOf(u8, snapshot, hook_event) != null);
            if (fixture.workflow_id) |workflow_id| try std.testing.expect(std.mem.indexOf(u8, snapshot, workflow_id) != null);
            found = true;
            break;
        }
        try std.testing.expect(found);
    }
}

fn expectInstallLockSettingsMetadataMatchesLoadedRegistry(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    extensions: []const resources_mod.LoadedExtension,
    startup_manifest_registry_snapshot: []const u8,
    fixtures: []const LifecyclePackageFixture,
    installed_sources: []const []u8,
) !void {
    const settings_path = try std.fs.path.join(allocator, &.{ project_dir, ".pi/settings.json" });
    defer allocator.free(settings_path);
    const settings_text = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, settings_path, allocator, .unlimited);
    defer allocator.free(settings_text);
    var settings = try std.json.parseFromSlice(std.json.Value, allocator, settings_text, .{});
    defer settings.deinit();

    const lock_path = try std.fs.path.join(allocator, &.{ project_dir, ".pi/extensions.lock.json" });
    defer allocator.free(lock_path);
    const lock_text = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, lock_path, allocator, .unlimited);
    defer allocator.free(lock_text);
    var lock = try std.json.parseFromSlice(std.json.Value, allocator, lock_text, .{});
    defer lock.deinit();

    var startup_snapshot = try std.json.parseFromSlice(std.json.Value, allocator, startup_manifest_registry_snapshot, .{});
    defer startup_snapshot.deinit();
    const startup_packages = jsonArrayField(startup_snapshot.value, "packages");
    try std.testing.expect(startup_packages.len == fixtures.len);

    for (fixtures, installed_sources) |fixture, installed_source| {
        const extension = loadedExtensionForSource(extensions, installed_source) orelse return error.ExpectedLoadedPackageExtension;
        const provenance = extension.source_info.provenance orelse return error.ExpectedLoadedPackageProvenance;
        const settings_entry = settingsPackageEntry(settings.value, installed_source) orelse return error.ExpectedSettingsPackageSource;
        const install_metadata = jsonObjectField(settings_entry, "installMetadata") orelse return error.ExpectedInstallMetadata;
        try expectJsonStringFieldValue(install_metadata, "key", provenance.lock_entry_key);
        try expectJsonStringFieldValue(install_metadata, "packageRoot", provenance.package_root);

        const lock_entry = lockEntryForKey(lock.value, provenance.lock_entry_key) orelse return error.ExpectedProvenanceLockEntry;
        try expectJsonStringFieldValue(lock_entry, "key", provenance.lock_entry_key);
        try expectJsonStringFieldValue(lock_entry, "packageRoot", provenance.package_root);
        const source = jsonObjectField(lock_entry, "source") orelse return error.ExpectedProvenanceSource;
        try expectJsonStringFieldValue(source, "identity", provenance.source_identity);
        const digests = jsonObjectField(lock_entry, "digests") orelse return error.ExpectedProvenanceDigests;
        try expectJsonStringFieldValue(digests, "packageRootSha256", provenance.package_root_sha256);
        const install_digests = jsonObjectField(install_metadata, "digests") orelse return error.ExpectedProvenanceDigests;
        try expectJsonFieldEqual(allocator, install_digests, digests, "packageRootSha256");
        try expectJsonFieldEqual(allocator, install_digests, digests, "manifestSha256");

        const manifest = jsonObjectField(lock_entry, "manifest") orelse return error.ExpectedManifestMetadata;
        try expectJsonStringFieldValue(manifest, "id", fixture.manifest_id);
        try expectJsonStringFieldValue(manifest, "runtime", fixture.runtime_kind.jsonName());
        const loaded_package = packageSnapshotForId(startup_packages, fixture.manifest_id) orelse return error.ExpectedLoadedRegistryPackage;
        try expectJsonFieldEqual(allocator, manifest, loaded_package, "id");
        try expectJsonFieldEqual(allocator, manifest, loaded_package, "version");
        try expectJsonFieldEqual(allocator, manifest, loaded_package, "schemaVersion");
        const loaded_runtime = jsonObjectField(loaded_package, "runtime") orelse return error.ExpectedRuntimeMetadata;
        try expectJsonStringFieldValue(loaded_runtime, "kind", fixture.runtime_kind.jsonName());
        try expectJsonStringFieldValue(loaded_runtime, "adapter", fixture.runtime_kind.adapterName());

        const lock_declarations = jsonObjectField(lock_entry, "declarations") orelse return error.ExpectedDeclarationMetadata;
        const loaded_declarations = jsonObjectField(loaded_package, "declarations") orelse return error.ExpectedDeclarationMetadata;
        inline for (.{ "tools", "hooks", "capabilities", "permissions", "dependencies", "workflows" }) |field| {
            try expectJsonFieldEqual(allocator, lock_declarations, loaded_declarations, field);
        }
    }

    const final_extension = loadedExtensionForSource(extensions, installed_sources[installed_sources.len - 1]) orelse return error.ExpectedLoadedPackageExtension;
    const final_provenance = final_extension.source_info.provenance orelse return error.ExpectedLoadedPackageProvenance;
    const final_lock_entry = lockEntryForKey(lock.value, final_provenance.lock_entry_key) orelse return error.ExpectedProvenanceLockEntry;
    const install_graph = jsonObjectField(final_lock_entry, "installGraph") orelse return error.ExpectedInstallGraphMetadata;
    const install_composition = jsonObjectField(install_graph, "composition") orelse return error.ExpectedInstallGraphMetadata;
    const startup_composition = jsonObjectField(startup_snapshot.value, "composition") orelse return error.ExpectedInstallGraphMetadata;
    inline for (.{ "activeNodes", "edges", "selectedProviders", "activationOrder" }) |field| {
        try expectJsonFieldEqual(allocator, install_composition, startup_composition, field);
    }
}

fn settingsPackageEntry(settings: std.json.Value, source: []const u8) ?std.json.Value {
    const packages = jsonArrayField(settings, "packages");
    for (packages) |entry| {
        if (entry == .object) {
            const source_value = entry.object.get("source") orelse continue;
            if (source_value == .string and std.mem.eql(u8, source_value.string, source)) return entry;
        }
    }
    return null;
}

fn lockEntryForKey(lock: std.json.Value, key: []const u8) ?std.json.Value {
    const entries = jsonArrayField(lock, "entries");
    for (entries) |entry| {
        if (entry != .object) continue;
        const value = entry.object.get("key") orelse continue;
        if (value == .string and std.mem.eql(u8, value.string, key)) return entry;
    }
    return null;
}

fn packageSnapshotForId(packages: []const std.json.Value, id: []const u8) ?std.json.Value {
    for (packages) |entry| {
        if (entry != .object) continue;
        const value = entry.object.get("id") orelse continue;
        if (value == .string and std.mem.eql(u8, value.string, id)) return entry;
    }
    return null;
}

fn jsonArrayField(value: std.json.Value, field: []const u8) []const std.json.Value {
    if (value != .object) return &.{};
    const field_value = value.object.get(field) orelse return &.{};
    if (field_value != .array) return &.{};
    return field_value.array.items;
}

fn jsonObjectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const field_value = value.object.get(field) orelse return null;
    if (field_value != .object) return null;
    return field_value;
}

fn expectJsonStringFieldValue(value: std.json.Value, field: []const u8, expected: []const u8) !void {
    if (value != .object) return error.ExpectedJsonObject;
    const field_value = value.object.get(field) orelse return error.ExpectedJsonField;
    try std.testing.expect(field_value == .string);
    try std.testing.expectEqualStrings(expected, field_value.string);
}

fn expectJsonFieldEqual(allocator: std.mem.Allocator, left: std.json.Value, right: std.json.Value, field: []const u8) !void {
    if (left != .object or right != .object) return error.ExpectedJsonObject;
    const left_field = left.object.get(field) orelse return error.ExpectedJsonField;
    const right_field = right.object.get(field) orelse return error.ExpectedJsonField;
    const left_json = try std.json.Stringify.valueAlloc(allocator, left_field, .{});
    defer allocator.free(left_json);
    const right_json = try std.json.Stringify.valueAlloc(allocator, right_field, .{});
    defer allocator.free(right_json);
    try std.testing.expectEqualStrings(left_json, right_json);
}

fn expectFileContains(allocator: std.mem.Allocator, path: []const u8, needle: []const u8) !void {
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .unlimited);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, needle) != null);
}

fn writeAbsoluteTestFile(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{ .sub_path = path, .data = data });
}

fn packagePolicyKey(allocator: std.mem.Allocator, source: []const u8, script_path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "typescript:package:project:{s}:extensions/host.py:{s}",
        .{ source, script_path },
    );
}

fn packageHostScript(
    allocator: std.mem.Allocator,
    capture_path: []const u8,
    tool_name: []const u8,
    runtime_label: []const u8,
    version: []const u8,
    register_hook: bool,
    register_workflow: bool,
) ![]u8 {
    const hook_frame = if (register_hook)
        "emit({'type':'register_hook','event':'input','hookId':'" ++ "input" ++ "','priority':0,'declarationOrder':0,'extensionPath':sys.argv[0]})\n"
    else
        "";
    const workflow_frame = if (register_workflow)
        "emit({'type':'register_workflow','id':'workflow.cross','description':'Settings backed mixed workflow','toolName':'workflow.cross','inputSchema':{'type':'object','required':['issue'],'properties':{'issue':{'type':'string'}},'additionalProperties':False},'outputSchema':{'type':'object'},'steps':[{'id':'process','kind':'side_effect','input':{'value':'workflow-process'},'selectedCapability':'process.cross','replayMode':'recorded'},{'id':'wasm','kind':'side_effect','input':{'value':'workflow-wasm'},'selectedCapability':'wasm.cross','replayMode':'recorded'},{'id':'native','kind':'side_effect','input':{'value':'workflow-native'},'selectedCapability':'native.cross','replayMode':'recorded'}],'extensionPath':sys.argv[0]})\n"
    else
        "";
    return try std.fmt.allocPrint(allocator,
        \\import json
        \\import sys
        \\
        \\capture = open("{s}", "a", encoding="utf-8")
        \\init = sys.stdin.readline()
        \\capture.write(init)
        \\capture.flush()
        \\
        \\def emit(value):
        \\    print(json.dumps(value, separators=(",", ":")), flush=True)
        \\
        \\TOOL_NAME = "{s}"
        \\RUNTIME = "{s}"
        \\VERSION = "{s}"
        \\emit({{'type':'ready'}})
        \\emit({{'type':'register_tool','name':TOOL_NAME,'label':TOOL_NAME,'description':RUNTIME + ' package tool','parameters':{{'type':'object','required':['value'],'properties':{{'value':{{'type':'string'}}}},'additionalProperties':False}},'extensionPath':sys.argv[0]}})
        \\{s}{s}
        \\for line in sys.stdin:
        \\    capture.write(line)
        \\    capture.flush()
        \\    try:
        \\        frame = json.loads(line)
        \\    except Exception:
        \\        continue
        \\    if frame.get('type') == 'shutdown':
        \\        emit({{'type':'shutdown_complete'}})
        \\        break
        \\    if frame.get('type') == 'extension_event':
        \\        event = frame.get('event') or {{}}
        \\        text = event.get('text', '')
        \\        emit({{'type':'extension_event_result','eventId':frame.get('eventId'),'result':{{'text':text + '|' + RUNTIME,'runtime':RUNTIME,'version':VERSION}}}})
        \\        continue
        \\    if frame.get('type') == 'tool_call' and frame.get('toolName') == TOOL_NAME:
        \\        value = (frame.get('input') or {{}}).get('value', '')
        \\        emit({{'type':'tool_result','toolCallId':frame.get('toolCallId'),'content':[{{'type':'text','text':RUNTIME + ':' + VERSION + ':' + value}}],'details':{{'runtime':RUNTIME,'version':VERSION,'toolName':TOOL_NAME}}}})
        \\
    , .{ capture_path, tool_name, runtime_label, version, hook_frame, workflow_frame });
}

fn makeManifestSources(
    allocator: std.mem.Allocator,
    fixtures: []const LifecyclePackageFixture,
    source_scope: []const u8,
) ![]coding_agent.extension_manifest.ManifestSource {
    const sources = try allocator.alloc(coding_agent.extension_manifest.ManifestSource, fixtures.len);
    errdefer allocator.free(sources);
    for (fixtures, 0..) |fixture, index| {
        const manifest_path = try std.fs.path.join(allocator, &.{ fixture.root, "pi-extension.json" });
        errdefer allocator.free(manifest_path);
        const manifest_text = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, manifest_path, allocator, .limited(256 * 1024));
        errdefer allocator.free(manifest_text);
        sources[index] = .{
            .package_root = fixture.root,
            .manifest_path = manifest_path,
            .manifest_text = manifest_text,
            .source_scope = source_scope,
            .precedence_rank = @intCast(index),
        };
    }
    return sources;
}

fn freeManifestSources(allocator: std.mem.Allocator, sources: []coding_agent.extension_manifest.ManifestSource) void {
    for (sources) |source| {
        allocator.free(@constCast(source.manifest_path));
        allocator.free(@constCast(source.manifest_text));
    }
    allocator.free(sources);
}

fn jsonObjectWithString(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
    return .{ .object = object };
}

fn expectToolResultContainsMain(messages: []const agent.AgentMessage, tool_name: []const u8, expected: []const u8) !void {
    for (messages) |message| {
        if (message != .tool_result) continue;
        if (!std.mem.eql(u8, message.tool_result.tool_name, tool_name)) continue;
        for (message.tool_result.content) |block| {
            if (block != .text) continue;
            if (std.mem.indexOf(u8, block.text.text, expected) != null) return;
        }
    }
    return error.ExpectedToolResultNotFound;
}

fn findToolByName(tools: []const agent.AgentTool, name: []const u8) ?agent.AgentTool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

test "runCli resolves provider-prefixed model without explicit provider" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "provider inferred");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--model", "faux/faux-1", "--print", "hello" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("provider inferred\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "CLI positional messages remain separate through initial input prep" {
    const allocator = std.testing.allocator;

    var args = try cli.parseArgs(allocator, &.{ "first prompt", "second prompt", "third prompt" });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), args.messages.?.len);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var prepared_input = try input_prep.prepareInitialInput(
        allocator,
        std.testing.io,
        &env_map,
        "/tmp/project",
        null,
        args.messages.?,
        null,
        &stderr_capture.writer,
        .{},
    );
    defer prepared_input.deinit(allocator);

    try std.testing.expectEqualStrings("first prompt", prepared_input.prompt.?);
    try std.testing.expectEqual(@as(usize, 2), prepared_input.messages.len);
    try std.testing.expectEqualStrings("second prompt", prepared_input.messages[0]);
    try std.testing.expectEqualStrings("third prompt", prepared_input.messages[1]);
}

test "prepareCliRuntime resolves model thinking suffix" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var args = try cli.parseArgs(allocator, &.{ "--model", "faux/faux-1:high" });
    defer args.deinit(allocator);

    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, "/tmp/project", &args, .{});
    defer prepared.deinit(allocator);

    try std.testing.expectEqualStrings("faux", prepared.provider_name);
    try std.testing.expectEqualStrings("faux-1", prepared.model_name.?);
    try std.testing.expectEqual(agent.ThinkingLevel.high, prepared.thinking_level);
    try std.testing.expect(prepared.model_error == null);
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

test "runCli auto-switches to print mode for piped stdin" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "hello from stdin");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var stdin_input = CliStdin{
        .is_tty = false,
        .content = "prompt from pipe",
    };

    const exit_code = try runCliWithInput(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux" },
        "/tmp/project",
        &stdin_input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("hello from stdin\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "runCli exports session files to html and jsonl" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-export");
    defer allocator.free(cwd);
    try std.Io.Dir.createDirAbsolute(std.testing.io, cwd, .default_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "export reply");

    var create_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer create_stdout.deinit();
    var create_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer create_stderr.deinit();

    const create_exit = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "export prompt" },
        cwd,
        &create_stdout.writer,
        &create_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), create_exit);

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    const html_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "exported.html" });
    defer allocator.free(html_path);
    const jsonl_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "exported.jsonl" });
    defer allocator.free(jsonl_path);

    var html_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer html_stdout.deinit();
    var html_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer html_stderr.deinit();
    const html_exit = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--export", session_file, html_path },
        cwd,
        &html_stdout.writer,
        &html_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), html_exit);
    try std.testing.expect(std.mem.indexOf(u8, html_stdout.writer.buffered(), "Exported to:") != null);
    try std.testing.expectEqualStrings("", html_stderr.writer.buffered());

    const html_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, html_path, allocator, .limited(1024 * 1024));
    defer allocator.free(html_bytes);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "export prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "export reply") != null);

    var jsonl_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer jsonl_stdout.deinit();
    var jsonl_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer jsonl_stderr.deinit();
    const jsonl_exit = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--export", session_file, jsonl_path },
        cwd,
        &jsonl_stdout.writer,
        &jsonl_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), jsonl_exit);
    try std.testing.expectEqualStrings("", jsonl_stderr.writer.buffered());

    const exported_jsonl = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, jsonl_path, allocator, .limited(1024 * 1024));
    defer allocator.free(exported_jsonl);
    try std.testing.expect(std.mem.indexOf(u8, exported_jsonl, "\"export prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported_jsonl, "\"export reply\"") != null);
}

test "runCli injects @file text into the initial prompt" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-file-text");
    defer allocator.free(cwd);
    try std.Io.Dir.createDirAbsolute(std.testing.io, cwd, .default_dir);
    const note_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "note.txt" });
    defer allocator.free(note_path);
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = note_path,
        .data = "alpha beta",
    });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "text file injected");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var stdin_input = CliStdin{};

    const exit_code = try runCliWithInput(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "@note.txt", "Question?" },
        cwd,
        &stdin_input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("text file injected\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();

    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    const user_text = context.messages[0].user.content[0].text.text;
    try std.testing.expect(std.mem.startsWith(u8, user_text, "<file name=\""));
    try std.testing.expect(std.mem.indexOf(u8, user_text, "alpha beta") != null);
    try std.testing.expect(std.mem.endsWith(u8, user_text, "</file>\nQuestion?"));
    try std.testing.expectEqualStrings("text file injected", context.messages[1].assistant.content[0].text.text);
}

test "runCli injects image file arguments into the initial prompt" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-file-image");
    defer allocator.free(cwd);
    try std.Io.Dir.createDirAbsolute(std.testing.io, cwd, .default_dir);
    const image_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "screenshot.png" });
    defer allocator.free(image_path);
    // Minimal valid PNG (8-byte signature + IHDR for a 2x2 image). The M14
    // file_image processor reads dimensions from IHDR before attaching the
    // image; an unparseable header would trigger the deterministic omission
    // path instead.
    const minimal_png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d,
        0x24,
    };
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = image_path,
        .data = &minimal_png,
    });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "image file injected");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var stdin_input = CliStdin{};

    const exit_code = try runCliWithInput(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "@screenshot.png", "Describe it" },
        cwd,
        &stdin_input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("image file injected\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();

    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqual(@as(usize, 2), context.messages[0].user.content.len);
    const user_text = context.messages[0].user.content[0].text.text;
    try std.testing.expect(std.mem.startsWith(u8, user_text, "<file name=\""));
    try std.testing.expect(std.mem.endsWith(u8, user_text, "\"></file>\nDescribe it"));
    try std.testing.expectEqualStrings("image/png", context.messages[0].user.content[1].image.mime_type);
    try std.testing.expect(context.messages[0].user.content[1].image.data.len > 0);
    try std.testing.expectEqualStrings("image file injected", context.messages[1].assistant.content[0].text.text);
}

// VAL-M14-IMAGE-008: when the file_image processor cannot resize an image
// below the inline byte limit, the CLI must omit the attachment and inject
// the deterministic omission text into the user message instead. Regression
// for the M14 file image normalization parity surface.
test "runCli omits oversized image with deterministic message when processor returns null" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-file-image-omit");
    defer allocator.free(cwd);
    try std.Io.Dir.createDirAbsolute(std.testing.io, cwd, .default_dir);
    const image_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "huge.png" });
    defer allocator.free(image_path);
    // Valid PNG header reporting 8000x8000 dimensions; well above the
    // default 2000x2000 max so the default processor returns null.
    const huge_png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x1f, 0x40, 0x00, 0x00, 0x1f, 0x40,
        0x08, 0x06, 0x00, 0x00, 0x00,
    };
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = image_path,
        .data = &huge_png,
    });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "ack");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var stdin_input = CliStdin{};

    const exit_code = try runCliWithInput(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "@huge.png", "what is this" },
        cwd,
        &stdin_input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();
    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqual(@as(usize, 1), context.messages[0].user.content.len);
    const user_text = context.messages[0].user.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, user_text, "[Image omitted: could not be resized below the inline image size limit.]") != null);
    try std.testing.expect(std.mem.endsWith(u8, user_text, "what is this"));
}

// VAL-M14-IMAGE-010: when `images.autoResize` is set to `false` in
// settings.json the file image is attached without dimension/byte gating,
// even when the default processor would otherwise omit it. Mirrors TS
// `processFileArguments({ autoResizeImages: false })`.
test "runCli respects images.autoResize=false and attaches oversized image bytes" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-file-image-no-resize");
    defer allocator.free(cwd);
    try std.Io.Dir.createDirAbsolute(std.testing.io, cwd, .default_dir);
    const project_pi = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi" });
    defer allocator.free(project_pi);
    try std.Io.Dir.createDirAbsolute(std.testing.io, project_pi, .default_dir);
    const project_settings = try std.fs.path.join(allocator, &[_][]const u8{ project_pi, "settings.json" });
    defer allocator.free(project_settings);
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = project_settings,
        .data = "{\"images\":{\"autoResize\":false}}",
    });

    const image_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "huge.png" });
    defer allocator.free(image_path);
    const huge_png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x1f, 0x40, 0x00, 0x00, 0x1f, 0x40,
        0x08, 0x06, 0x00, 0x00, 0x00,
    };
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = image_path,
        .data = &huge_png,
    });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "noresize");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var stdin_input = CliStdin{};

    const exit_code = try runCliWithInput(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "@huge.png", "describe" },
        cwd,
        &stdin_input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();
    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages[0].user.content.len);
    try std.testing.expectEqualStrings("image/png", context.messages[0].user.content[1].image.mime_type);
    const user_text = context.messages[0].user.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, user_text, "[Image omitted") == null);
    try std.testing.expect(std.mem.endsWith(u8, user_text, "describe"));
}

test "cli executable print mode writes assistant text to stdout without interactive escape codes" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try cli_test.runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--print", "hello" },
        &.{.{ "PI_FAUX_RESPONSE", "hello from cli binary" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("hello from cli binary\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(!cli_test.hasAnsiEscape(result.stdout));
    try std.testing.expect(!cli_test.hasAnsiEscape(result.stderr));
}

test "cli executable print mode json writes valid JSON lines to stdout" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try cli_test.runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--mode", "json", "--print", "hello" },
        &.{.{ "PI_FAUX_RESPONSE", "json from cli binary" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(!cli_test.hasAnsiEscape(result.stdout));

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var line_count: usize = 0;
    var saw_agent_start = false;
    var saw_agent_end = false;
    var saw_response_text = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        try json_event_wire.validateAgentEventJson(allocator, parsed.value);

        const event_type = parsed.value.object.get("type").?.string;
        if (std.mem.eql(u8, event_type, "agent_start")) saw_agent_start = true;
        if (std.mem.eql(u8, event_type, "agent_end")) saw_agent_end = true;
        if (std.mem.indexOf(u8, line, "json from cli binary") != null) saw_response_text = true;
    }

    try std.testing.expect(line_count >= 3);
    try std.testing.expect(saw_agent_start);
    try std.testing.expect(saw_agent_end);
    try std.testing.expect(saw_response_text);
}

test "cli executable --mode rpc uses TS-compatible JSONL get_state" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try cli_test.runCliExecutableWithInput(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--no-session", "--mode", "rpc" },
        "{\"id\":\"state\",\"type\":\"get_state\"}\n",
        &.{},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(!cli_test.hasAnsiEscape(result.stdout));
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"id\":\"state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"type\":\"response\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"command\":\"get_state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"jsonrpc\"") == null);
}

test "cli executable -mode rpc uses TS-compatible JSONL get_state" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try cli_test.runCliExecutableWithInput(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--no-session", "-mode", "rpc" },
        "{\"id\":\"state_short\",\"type\":\"get_state\"}\n",
        &.{},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(!cli_test.hasAnsiEscape(result.stdout));
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"id\":\"state_short\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"type\":\"response\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"command\":\"get_state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"jsonrpc\"") == null);
}

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

test "runCli rejects conflicting fork flags" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--fork", "session-123", "--resume", "--print", "hello" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "--fork cannot be combined") != null);
}

test "runCli rejects prompt arguments in RPC modes before runtime routing" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const cases = [_][]const u8{ "rpc", "ts-rpc" };
    for (cases) |mode| {
        var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
        defer stdout_capture.deinit();
        var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
        defer stderr_capture.deinit();

        const exit_code = try runCli(
            allocator,
            std.testing.io,
            &env_map,
            &.{ "--mode", mode, "hello" },
            "/tmp/project",
            &stdout_capture.writer,
            &stderr_capture.writer,
        );

        try std.testing.expectEqual(@as(u8, 1), exit_code);
        try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
        try std.testing.expectEqualStrings("Error: Prompt arguments are not supported in RPC mode\n", stderr_capture.writer.buffered());
    }
}

test "runCli rejects file arguments in RPC modes before runtime routing" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const cases = [_][]const u8{ "rpc", "ts-rpc" };
    for (cases) |mode| {
        var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
        defer stdout_capture.deinit();
        var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
        defer stderr_capture.deinit();

        const exit_code = try runCli(
            allocator,
            std.testing.io,
            &env_map,
            &.{ "--mode", mode, "@missing.txt" },
            "/tmp/project",
            &stdout_capture.writer,
            &stderr_capture.writer,
        );

        try std.testing.expectEqual(@as(u8, 1), exit_code);
        try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
        try std.testing.expectEqualStrings("Error: @file arguments are not supported in RPC mode\n", stderr_capture.writer.buffered());
    }
}

test "runCli rejects unregistered unknown long flag with sanitized diagnostic" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--bogus-flag", "--print", "hello" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "Unknown option: --bogus-flag") != null);
}

test "runCli accepts registered extension boolean and string flags from local Bun fixture" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "ext-flags ok");

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
        &.{
            "--extension",  fixture_path,
            "--no-session", "--provider",
            "faux",         "--print",
            "--plan",       "--model-alias",
            "claude-haiku", "hello",
        },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("ext-flags ok\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
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
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "second.ts", .data = "export default {};" });
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

test "prepareCliRuntime loads defaults resources context and prompt templates" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/skills/reviewer");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/prompts");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/themes");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1",
        \\  "defaultThinkingLevel": "minimal",
        \\  "sessionDir": "~/sessions"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/settings.json",
        .data =
        \\{
        \\  "theme": "night"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/AGENTS.md",
        .data = "Project instructions from AGENTS.md",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/skills/reviewer/SKILL.md",
        .data =
        \\---
        \\description: Review code changes
        \\---
        \\Use the review checklist.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/prompts/fix.md",
        .data = "Fix $ARGUMENTS please.",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/themes/night.json",
        .data =
        \\{
        \\  "name": "night",
        \\  "tokens": {
        \\    "assistant": { "fg": "cyan" }
        \\  }
        \\}
        ,
    });

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{
        "--tools",
        "read,ls",
        "/fix parser bug",
    });
    defer args.deinit(allocator);

    const selected_tools = effectiveToolSelection(&args);
    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, selected_tools);
    defer prepared.deinit(allocator);

    try std.testing.expectEqualStrings("faux", prepared.provider_name);
    try std.testing.expectEqualStrings("faux-1", prepared.model_name.?);
    try std.testing.expectEqual(agent.ThinkingLevel.minimal, prepared.thinking_level);
    try std.testing.expectEqualStrings("night", prepared.resource_bundle.selectedTheme().name);
    try std.testing.expectEqual(@as(usize, 1), prepared.expanded_messages.len);
    try std.testing.expectEqualStrings("Fix parser bug please.", prepared.expanded_messages[0]);
    try std.testing.expect(prepared.context_files.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "Project instructions from AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "<available_skills>") != null);

    const expected_session_dir = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, "sessions" });
    defer allocator.free(expected_session_dir);
    try std.testing.expectEqualStrings(expected_session_dir, prepared.session_dir);
}

test "prepareCliRuntime appends repeatable CLI system prompts in order" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1"
        \\}
        ,
    });

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{
        "--append-system-prompt",
        "First appended chunk.",
        "--append-system-prompt",
        "Second appended chunk.",
    });
    defer args.deinit(allocator);

    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, .{});
    defer prepared.deinit(allocator);

    const first_index_opt = std.mem.indexOf(u8, prepared.system_prompt, "First appended chunk.");
    const second_index_opt = std.mem.indexOf(u8, prepared.system_prompt, "Second appended chunk.");
    try std.testing.expect(first_index_opt != null);
    try std.testing.expect(second_index_opt != null);
    try std.testing.expect(first_index_opt.? < second_index_opt.?);
}

test "prepareCliRuntime wires CLI resource overrides and discovery toggles" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/extensions");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/skills/default-reviewer");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/prompts");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/themes");
    try tmp.dir.createDirPath(std.testing.io, "repo/cli-skills/reviewer");
    try tmp.dir.createDirPath(std.testing.io, "repo/cli-prompts");

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1",
        \\  "sessionDir": "~/sessions"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/settings.json",
        .data =
        \\{
        \\  "theme": "night"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/extensions/default-extension.ts",
        .data = "export default {};",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/skills/default-reviewer/SKILL.md",
        .data =
        \\---
        \\description: Default review skill
        \\---
        \\Use the default review checklist.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/prompts/fix.md",
        .data = "Default fix $ARGUMENTS.",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/themes/night.json",
        .data =
        \\{
        \\  "name": "night",
        \\  "tokens": {
        \\    "assistant": { "fg": "cyan" }
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/cli-extension.ts",
        .data = "export default {};",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/cli-skills/reviewer/SKILL.md",
        .data =
        \\---
        \\description: CLI review skill
        \\---
        \\Use the CLI review checklist.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/cli-prompts/fix.md",
        .data = "CLI fix $ARGUMENTS.",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/cli-night.json",
        .data =
        \\{
        \\  "name": "night",
        \\  "tokens": {
        \\    "assistant": { "fg": "magenta" }
        \\  }
        \\}
        ,
    });

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{
        "--no-extensions",
        "--extension",
        "cli-extension.ts",
        "--no-skills",
        "--skill",
        "cli-skills",
        "--no-prompt-templates",
        "--prompt-template",
        "cli-prompts",
        "--no-themes",
        "--theme",
        "cli-night.json",
        "/fix parser bug",
    });
    defer args.deinit(allocator);

    const selected_tools = effectiveToolSelection(&args);
    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, selected_tools);
    defer prepared.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), prepared.resource_bundle.extensions.len);
    try std.testing.expect(std.mem.indexOf(u8, prepared.resource_bundle.extensions[0].path, "cli-extension.ts") != null);
    try std.testing.expectEqual(@as(usize, 1), prepared.resource_bundle.skills.len);
    try std.testing.expectEqualStrings("reviewer", prepared.resource_bundle.skills[0].name);
    try std.testing.expectEqual(@as(usize, 1), prepared.resource_bundle.prompt_templates.len);
    try std.testing.expectEqualStrings("fix", prepared.resource_bundle.prompt_templates[0].name);
    try std.testing.expectEqual(@as(usize, 1), prepared.expanded_messages.len);
    try std.testing.expectEqualStrings("CLI fix parser bug.", prepared.expanded_messages[0]);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "CLI review skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "Default review skill") == null);
    try std.testing.expectEqualStrings("night", prepared.resource_bundle.selectedTheme().name);

    const styled = try prepared.resource_bundle.selectedTheme().applyAlloc(allocator, .assistant, "Pi:");
    defer allocator.free(styled);
    try std.testing.expectEqualStrings("Pi:", styled);
}

test "prepareCliRuntime skips context file discovery when requested" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/AGENTS.md",
        .data = "Project instructions from AGENTS.md",
    });

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{
        "--no-context-files",
        "--verbose",
        "hello",
    });
    defer args.deinit(allocator);

    try std.testing.expect(args.verbose);

    const selected_tools = effectiveToolSelection(&args);
    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, selected_tools);
    defer prepared.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), prepared.context_files.len);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "Project instructions from AGENTS.md") == null);
}

test "prepareCliRuntime selects default model from configured api key" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/auth.json",
        .data =
        \\{
        \\  "kimi": { "type": "api_key", "key": "stored-kimi-key" }
        \\}
        ,
    });

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, .{});
    defer prepared.deinit(allocator);

    try std.testing.expectEqualStrings("kimi", prepared.provider_name);
    try std.testing.expectEqualStrings("kimi-k2.6", prepared.model_name.?);
}

test "prepareCliRuntime selects kimi-coding from KIMI_API_KEY" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("KIMI_API_KEY", "kimi-key");

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, .{});
    defer prepared.deinit(allocator);

    try std.testing.expectEqualStrings("kimi-coding", prepared.provider_name);
    try std.testing.expectEqualStrings("kimi-for-coding", prepared.model_name.?);
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

test "resolvePreflightSessionDir prefers --session-dir over env and settings" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "explicit");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{ "sessionDir": "/tmp/should-be-ignored-by-cli-flag" }
        ,
    });

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);
    const explicit_dir = try cli_test.makeTmpPath(allocator, tmp, "explicit");
    defer allocator.free(explicit_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_SESSION_DIR", "/tmp/should-be-ignored-by-cli-flag-too");

    var args = try cli.parseArgs(allocator, &.{ "--session-dir", explicit_dir });
    defer args.deinit(allocator);

    const resolved = try runtime_prep.resolvePreflightSessionDir(allocator, std.testing.io, &env_map, repo_dir, &args);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(explicit_dir, resolved);
}

test "resolvePreflightSessionDir uses PI_CODING_AGENT_SESSION_DIR when no flag" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "envvar-sessions");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);
    const env_dir = try cli_test.makeTmpPath(allocator, tmp, "envvar-sessions");
    defer allocator.free(env_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_SESSION_DIR", env_dir);

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    const resolved = try runtime_prep.resolvePreflightSessionDir(allocator, std.testing.io, &env_map, repo_dir, &args);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(env_dir, resolved);
}

test "resolvePreflightSessionDir falls back to default cwd/.pi/sessions" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    const resolved = try runtime_prep.resolvePreflightSessionDir(allocator, std.testing.io, &env_map, repo_dir, &args);
    defer allocator.free(resolved);
    const expected = try std.fs.path.join(allocator, &[_][]const u8{ repo_dir, ".pi", "sessions" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, resolved);
}

test "resolvePreflightSessionDir and effectiveSessionDir agree when env and settings both present" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "envvar-sessions");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    // Settings sessionDir must NOT win when env is also present; both
    // resolvers must pick the env-derived directory.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{ "sessionDir": "/tmp/should-be-ignored-by-env-var" }
        ,
    });

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);
    const env_dir = try cli_test.makeTmpPath(allocator, tmp, "envvar-sessions");
    defer allocator.free(env_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_SESSION_DIR", env_dir);

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    const preflight_resolved = try runtime_prep.resolvePreflightSessionDir(
        allocator,
        std.testing.io,
        &env_map,
        repo_dir,
        &args,
    );
    defer allocator.free(preflight_resolved);

    var runtime = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, repo_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    const runtime_resolved = try runtime.effectiveSessionDir(allocator, &env_map, repo_dir);
    defer allocator.free(runtime_resolved);

    try std.testing.expectEqualStrings(env_dir, preflight_resolved);
    try std.testing.expectEqualStrings(env_dir, runtime_resolved);
    try std.testing.expectEqualStrings(preflight_resolved, runtime_resolved);
}
