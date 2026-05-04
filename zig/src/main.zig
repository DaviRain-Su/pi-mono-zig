const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const cli = @import("cli/args.zig");
const bootstrap = @import("cli/bootstrap.zig");
const input_prep = @import("cli/input_prep.zig");
const runtime_prep = @import("cli/runtime_prep.zig");
const output = @import("cli/output.zig");
const coding_agent = @import("coding_agent/root.zig");
const config_mod = @import("coding_agent/config.zig");
const json_event_wire = @import("coding_agent/json_event_wire.zig");
const extension_host_mod = @import("coding_agent/extension_host.zig");
const extension_flags_mod = @import("coding_agent/extension_flags.zig");
const extension_registry_mod = @import("coding_agent/extension_registry.zig");

const VERSION = "0.1.0";

const AppMode = bootstrap.AppMode;
const CliStdin = input_prep.CliStdin;
const PreparedInitialInput = input_prep.PreparedInitialInput;
const PreparedCliRuntime = runtime_prep.PreparedCliRuntime;
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
    var it = init.minimal.args.iterate();
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
    // Dispatch package-management subcommands (`pi install`, `pi remove`,
    // `pi uninstall`, `pi update`, `pi list`) before the standard CLI
    // parser runs. The package commands have their own positional and
    // option grammar that the regular `parseArgs` would misclassify
    // (positional sources would be consumed as prompt text). Mirrors
    // TypeScript `main.ts` which runs `handlePackageCommand` before the
    // standard prompt/agent path. Only the `local-fixtures-first` slice
    // is implemented here for M12 m12-package-cli-local-fixtures; npm/git
    // sources and self-update return deterministic out-of-scope errors.
    if (coding_agent.package_manager.isPackageCommand(argv)) {
        var package_command = coding_agent.package_manager.parsePackageCommand(allocator, argv) catch |err| switch (err) {
            error.NotPackageCommand => unreachable,
            else => return err,
        };
        defer package_command.deinit(allocator);
        const cwd = if (cwd_override) |override| blk: {
            break :blk try allocator.dupe(u8, override);
        } else blk: {
            const real_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
            defer allocator.free(real_cwd);
            break :blk try allocator.dupe(u8, real_cwd);
        };
        defer allocator.free(cwd);
        const agent_dir = try config_mod.resolveAgentDir(allocator, env_map);
        defer allocator.free(agent_dir);
        const stdout_is_tty = std.Io.File.stdout().isTty(io) catch false;
        const result = try coding_agent.package_manager.executePackageCommand(
            allocator,
            io,
            package_command,
            .{
                .cwd = cwd,
                .agent_dir = agent_dir,
                .stdout_is_tty = stdout_is_tty,
                .env_map = env_map,
            },
            stdout,
            stderr,
        );
        return result.exit_code;
    }

    var options = bootstrap.parseArgs(allocator, argv) catch |err| {
        try stderr.print("Error: {s}\n\n", .{bootstrap.parseErrorMessage(err)});
        try output.printUsage(allocator, VERSION, stdout);
        return 1;
    };
    defer options.deinit(allocator);

    // Build the extension flag registry from local Bun-fixture manifest
    // sidecars next to each `--extension <path>` entry. This is the
    // deterministic compatibility hook for M11 extension CLI flag
    // passthrough; live Bun JSONL flag registration is handled by the
    // sibling registration-surfaces feature.
    var extension_flag_registry = extension_flags_mod.Registry.init(allocator);
    defer extension_flag_registry.deinit();
    if (options.extensions) |paths| {
        try extension_flags_mod.loadFromExtensionPaths(&extension_flag_registry, io, paths);
    }

    if (options.help) {
        const ext_flags_snapshot = try extension_flag_registry.snapshotForHelp(allocator);
        defer allocator.free(ext_flags_snapshot);
        const help_flags = try allocator.alloc(cli.ExtensionFlagInfo, ext_flags_snapshot.len);
        defer allocator.free(help_flags);
        for (ext_flags_snapshot, 0..) |flag, idx| {
            help_flags[idx] = .{
                .name = flag.name,
                .description = flag.description,
                .type_kind = switch (flag.type_kind) {
                    .boolean => .boolean,
                    .string => .string,
                },
                .extension_path = flag.extension_path,
            };
        }
        try output.printUsageWithExtensions(allocator, VERSION, help_flags, stdout);
        return 0;
    }

    if (options.version) {
        try output.printVersion(allocator, VERSION, stdout);
        return 0;
    }

    // Validate any unknown long flags against the extension flag
    // registry. Unregistered flags are surfaced as TS-compatible
    // `Unknown option(s):` diagnostics; registered flags are accepted.
    // Parsed flag values (boolean true / explicit string) are
    // collected here so the M11 live Bun host registry dump path
    // below can plumb them into the runtime registry, mirroring TS
    // `extensionState.flags[name] = value`.
    var parsed_flag_owned_names = std.ArrayList([]u8).empty;
    var parsed_flag_owned_strings = std.ArrayList([]u8).empty;
    var parsed_extension_flag_values = std.ArrayList(extension_registry_mod.ParsedCliFlag).empty;
    defer {
        parsed_extension_flag_values.deinit(allocator);
        for (parsed_flag_owned_names.items) |s| allocator.free(s);
        parsed_flag_owned_names.deinit(allocator);
        for (parsed_flag_owned_strings.items) |s| allocator.free(s);
        parsed_flag_owned_strings.deinit(allocator);
    }
    if (options.unknown_flags) |unknown_flags| {
        const parsed = try allocator.alloc(extension_flags_mod.ParsedUnknownFlag, unknown_flags.len);
        defer allocator.free(parsed);
        for (unknown_flags, 0..) |raw, idx| {
            parsed[idx] = .{
                .name = raw.name,
                .value = switch (raw.value) {
                    .boolean => |b| .{ .boolean = b },
                    .string => |s| .{ .string = s },
                },
            };
        }

        var apply_result = try extension_flags_mod.applyUnknownFlags(
            allocator,
            &extension_flag_registry,
            parsed,
        );
        defer apply_result.deinit(allocator);

        if (apply_result.diagnostics.len > 0) {
            var saw_error = false;
            for (apply_result.diagnostics) |diagnostic| {
                if (diagnostic.severity == .@"error") saw_error = true;
                try stderr.print("Error: {s}\n", .{diagnostic.message});
            }
            if (saw_error) return 1;
        }

        for (apply_result.values) |entry| {
            const name_owned = try allocator.dupe(u8, entry.name);
            try parsed_flag_owned_names.append(allocator, name_owned);
            switch (entry.value) {
                .boolean => |b| {
                    try parsed_extension_flag_values.append(allocator, .{
                        .name = name_owned,
                        .value = .{ .boolean = b },
                    });
                },
                .string => |s| {
                    const value_owned = try allocator.dupe(u8, s);
                    try parsed_flag_owned_strings.append(allocator, value_owned);
                    try parsed_extension_flag_values.append(allocator, .{
                        .name = name_owned,
                        .value = .{ .string = value_owned },
                    });
                },
            }
        }
    }

    // M11 explicit --extension end-to-end: when the registry-dump env
    // var is enabled and at least one --extension path is provided,
    // start the configured Bun-hosted extension runtime, drain its
    // live register_* JSONL frames into the runtime registry, plumb
    // parsed CLI flag values through host.applyCliFlagValues, and
    // print the deterministic registry snapshot to stdout. This is
    // the deterministic CLI hook used by VAL-M11-EXT-007/008/012/etc
    // to observe live extension contributions without relying on
    // sidecar manifests.
    if (options.extensions) |paths| if (paths.len > 0) {
        if (env_map.get("PI_M11_EXTENSION_REGISTRY_DUMP")) |dump_value| {
            if (isEnabledValue(dump_value)) {
                const exit_code = try runExtensionRegistryDump(
                    allocator,
                    io,
                    env_map,
                    paths,
                    parsed_extension_flag_values.items,
                    cwd_override,
                    stdout,
                    stderr,
                );
                return exit_code;
            }
        }
    };

    var effective_env_map = try prepareEffectiveEnvMap(allocator, env_map, &options);
    defer effective_env_map.deinit();

    if (options.@"export") |session_file| {
        return output.runSessionExport(allocator, io, &effective_env_map, cwd_override, session_file, options.prompt, stdout, stderr) catch |err| {
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

    if ((options.mode == .rpc or options.mode == .ts_rpc) and options.prompt != null) {
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
        const preflight_session_dir = try runtime_prep.resolvePreflightSessionDir(
            allocator,
            io,
            &effective_env_map,
            cwd,
            &options,
        );
        defer allocator.free(preflight_session_dir);

        const preflight_options: coding_agent.RunInteractiveModeOptions = .{
            .cwd = cwd,
            // The preflight only inspects session files / stored cwd. The
            // system_prompt and provider strings below are placeholders that
            // are never used during preflight resolution.
            .system_prompt = "",
            .session_dir = preflight_session_dir,
            .provider = "faux",
            .session = options.session,
            .@"continue" = options.@"continue",
            .@"resume" = options.@"resume",
            .fork = options.fork,
            .no_session = options.no_session,
        };

        if (try coding_agent.interactive_mode.preflightInteractiveMissingCwd(
            allocator,
            io,
            preflight_options,
        )) |captured_preflight| {
            var captured_preflight_mut = captured_preflight;
            defer captured_preflight_mut.deinit(allocator);

            if (app_mode != .interactive) {
                const message = try coding_agent.formatMissingSessionCwdError(allocator, captured_preflight_mut.issue());
                defer allocator.free(message);
                try stderr.print("Error: {s}\n", .{message});
                try stderr.flush();
                return 1;
            }

            const choice = try coding_agent.runMissingCwdSelector(
                allocator,
                io,
                &effective_env_map,
                captured_preflight_mut.issue(),
            );
            switch (choice) {
                .cancel => {
                    try stderr.writeAll("Resume cancelled\n");
                    try stderr.flush();
                    return 0;
                },
                .continue_in_fallback => {
                    preflight_continue_confirmed = true;
                },
            }
        }
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
        prepared.expanded_prompt,
        detected_stdin.content,
        stderr,
        .{ .auto_resize_images = prepared.runtime_config.imageAutoResize() },
    ) catch |err| switch (err) {
        error.CliInputFailed => return 1,
        else => return err,
    };
    defer initial_input.deinit(allocator);

    if (app_mode == .print or app_mode == .json) {
        if (initial_input.prompt == null) {
            try stderr.writeAll("Error: No prompt provided\n\n");
            try output.printUsage(allocator, VERSION, stdout);
            return 1;
        }
    }

    if (app_mode != .interactive) {
        // Preflight stored-session cwd BEFORE provider/auth resolution and
        // tool construction so missing-cwd diagnostics always preempt
        // unrelated bootstrap failures. Matches TypeScript main.ts ordering.
        const preflight_options: coding_agent.RunInteractiveModeOptions = .{
            .cwd = cwd,
            .system_prompt = prepared.system_prompt,
            .session_dir = prepared.session_dir,
            .provider = prepared.provider_name,
            .session = options.session,
            .@"continue" = options.@"continue",
            .@"resume" = options.@"resume",
            .fork = options.fork,
            .no_session = options.no_session,
        };
        if (try coding_agent.interactive_mode.preflightInteractiveMissingCwd(
            allocator,
            io,
            preflight_options,
        )) |captured_preflight| {
            var captured_preflight_mut = captured_preflight;
            defer captured_preflight_mut.deinit(allocator);
            const message = try coding_agent.formatMissingSessionCwdError(allocator, captured_preflight_mut.issue());
            defer allocator.free(message);
            try stderr.print("Error: {s}\n", .{message});
            try stderr.flush();
            return 1;
        }
    }

    var provider_runtime = coding_agent.resolveProviderConfig(
        allocator,
        io,
        &effective_env_map,
        prepared.provider_name,
        prepared.model_name,
        options.api_key,
        prepared.runtime_config.lookupApiKey(prepared.provider_name),
    ) catch |err| {
        try stderr.print("Error: {s}\n", .{coding_agent.resolveProviderErrorMessage(err, prepared.provider_name)});
        return 1;
    };
    defer provider_runtime.deinit(allocator);

    if (app_mode != .interactive) {
        var app_context = coding_agent.interactive_mode.AppContext.init(cwd, io);
        var built_tools = try coding_agent.interactive_mode.buildAgentTools(allocator, &app_context, selected_tools);
        defer built_tools.deinit();

        var missing_cwd_issue: ?coding_agent.interactive_mode.OwnedMissingSessionCwdIssue = null;
        defer if (missing_cwd_issue) |*captured| captured.deinit(allocator);
        var session = coding_agent.interactive_mode.openInitialSessionWithMissingCwd(
            allocator,
            io,
            prepared.session_dir,
            .{
                .cwd = cwd,
                .system_prompt = prepared.system_prompt,
                .session_dir = prepared.session_dir,
                .provider = prepared.provider_name,
                .model = prepared.model_name,
                .api_key = options.api_key,
                .thinking = prepared.thinking_level,
                .session = options.session,
                .@"continue" = options.@"continue",
                .@"resume" = options.@"resume",
                .fork = options.fork,
                .no_session = options.no_session,
                .model_patterns = options.models,
                .selected_tools = selected_tools,
                .initial_prompt = null,
                .initial_images = &.{},
                .prompt_templates = prepared.resource_bundle.prompt_templates,
                .keybindings = &prepared.runtime_config.keybindings,
                .theme = prepared.resource_bundle.selectedTheme(),
                .runtime_config = &prepared.runtime_config,
                // Non-interactive flows must never silently fall back to the
                // launch cwd when the stored session cwd no longer exists.
                // The early preflight already failed/exited before this
                // point if the stored cwd was missing, so a missing-cwd
                // issue here is purely a race fallback.
                .missing_cwd_mode = .fail,
                .missing_cwd_already_confirmed = preflight_continue_confirmed,
            },
            provider_runtime.model,
            provider_runtime.api_key,
            built_tools.items,
            &missing_cwd_issue,
        ) catch |err| switch (err) {
            error.MissingSessionCwd => {
                if (missing_cwd_issue) |captured| {
                    const message = try coding_agent.formatMissingSessionCwdError(allocator, captured.issue());
                    defer allocator.free(message);
                    try stderr.print("Error: {s}\n", .{message});
                } else {
                    try stderr.writeAll("Error: stored session working directory does not exist\n");
                }
                try stderr.flush();
                return 1;
            },
            else => return err,
        };
        defer session.deinit();

        if (app_mode == .rpc) {
            return try coding_agent.runRpcMode(
                allocator,
                io,
                &session,
                .{},
                stdout,
                stderr,
            );
        }

        if (app_mode == .ts_rpc) {
            var extension_host_options = try tsRpcExtensionHostOptions(allocator, &effective_env_map, cwd);
            defer extension_host_options.deinit(allocator);
            return try coding_agent.runTsRpcMode(
                allocator,
                io,
                &session,
                .{
                    .extension_ui_parity_scenario = isEnabledEnv(&effective_env_map, "PI_TS_RPC_EXTENSION_UI_PARITY_SCENARIO"),
                    .extension_host = extension_host_options.options,
                },
                stdout,
                stderr,
            );
        }

        if (initial_input.images.len > 0) {
            return try coding_agent.runPrintMode(
                allocator,
                io,
                &session,
                .{
                    .text = initial_input.prompt.?,
                    .images = initial_input.images,
                },
                .{
                    .mode = if (app_mode == .json) .json else .text,
                    .config_errors = prepared.runtime_config.errors,
                },
                stdout,
                stderr,
            );
        }

        return try coding_agent.runPrintMode(
            allocator,
            io,
            &session,
            initial_input.prompt.?,
            .{
                .mode = if (app_mode == .json) .json else .text,
                .config_errors = prepared.runtime_config.errors,
            },
            stdout,
            stderr,
        );
    }

    return try coding_agent.runInteractiveMode(
        allocator,
        io,
        &effective_env_map,
        .{
            .cwd = cwd,
            .system_prompt = prepared.system_prompt,
            .session_dir = prepared.session_dir,
            .provider = prepared.provider_name,
            .model = prepared.model_name,
            .api_key = options.api_key,
            .thinking = prepared.thinking_level,
            .session = options.session,
            .@"continue" = options.@"continue",
            .@"resume" = options.@"resume",
            .fork = options.fork,
            .no_session = options.no_session,
            .model_patterns = options.models,
            .selected_tools = selected_tools,
            .initial_prompt = initial_input.prompt,
            .initial_images = initial_input.images,
            .prompt_templates = prepared.resource_bundle.prompt_templates,
            .keybindings = &prepared.runtime_config.keybindings,
            .theme = prepared.resource_bundle.selectedTheme(),
            .terminal_name = prepared.resource_bundle.terminal_name,
            .runtime_config = &prepared.runtime_config,
            .offline = options.offline,
            .verbose = options.verbose,
            // Continue path of the early pre-`prepareCliRuntime` preflight
            // already showed the Continue/Cancel selector and the user
            // chose Continue. Skip the duplicate prompt inside the
            // interactive bootstrap and let it apply the launch cwd
            // fallback directly.
            .missing_cwd_mode = if (preflight_continue_confirmed) .use_fallback else .fail,
            .missing_cwd_already_confirmed = preflight_continue_confirmed,
        },
        stderr,
    );
}

fn isEnabledEnv(env_map: *const std.process.Environ.Map, key: []const u8) bool {
    const value = env_map.get(key) orelse return false;
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes");
}

const OwnedTsRpcExtensionHostOptions = struct {
    options: ?coding_agent.ts_rpc_mode.ExtensionHostOptions = null,
    argv: ?[][]const u8 = null,

    fn deinit(self: *OwnedTsRpcExtensionHostOptions, allocator: std.mem.Allocator) void {
        if (self.argv) |argv| allocator.free(argv);
        self.* = undefined;
    }
};

fn tsRpcExtensionHostOptions(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
) !OwnedTsRpcExtensionHostOptions {
    const entry = env_map.get("PI_M6_EXTENSION_HOST_ENTRY") orelse return .{};
    if (env_map.get("PI_M6_EXTENSION_HOST_DISABLED")) |value| {
        if (isEnabledValue(value)) return .{};
    }
    const runtime = env_map.get("PI_M6_EXTENSION_HOST_RUNTIME") orelse "bun";
    const fixture = env_map.get("PI_M6_EXTENSION_HOST_FIXTURE") orelse "m6-fixture";
    const marker = env_map.get(extension_host_mod.HOST_MARKER_ENV) orelse "pi-m6-extension-host";
    var argv = try allocator.alloc([]const u8, 3);
    argv[0] = runtime;
    argv[1] = entry;
    argv[2] = marker;
    return .{
        .argv = argv,
        .options = .{
            .argv = argv,
            .cwd = cwd,
            .marker = marker,
            .fixture = fixture,
        },
    };
}

fn isEnabledValue(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes");
}

/// Start a Bun-hosted extension via the M11 registry-dump CLI hook,
/// drain live register_* JSONL frames into the runtime registry, plumb
/// parsed CLI flag values into `extensionState`, and write the
/// deterministic snapshot to stdout. The runtime is configurable via
/// `PI_M11_EXTENSION_HOST_RUNTIME` (default `bun`) so deterministic
/// validation can substitute a local shell stub for the live Bun
/// runtime when needed. Always exits cleanly with the host shut down.
fn runExtensionRegistryDump(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    extension_paths: []const []const u8,
    parsed_flag_values: []const extension_registry_mod.ParsedCliFlag,
    cwd_override: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (extension_paths.len == 0) return 0;
    const runtime = env_map.get("PI_M11_EXTENSION_HOST_RUNTIME") orelse "bun";
    const marker = env_map.get("PI_M11_EXTENSION_HOST_MARKER") orelse "pi-m11-extension-host";
    const fixture = env_map.get("PI_M11_EXTENSION_HOST_FIXTURE") orelse "m11-fixture";
    const ready_timeout_ms: u64 = std.fmt.parseInt(u64, env_map.get("PI_M11_EXTENSION_READY_TIMEOUT_MS") orelse "1500", 10) catch 1500;
    const drain_timeout_ms: u64 = std.fmt.parseInt(u64, env_map.get("PI_M11_EXTENSION_DRAIN_TIMEOUT_MS") orelse "1500", 10) catch 1500;

    // Prefer the first --extension path as the entry point; additional
    // paths are forwarded as host argv tail so a local shell stub can
    // observe them. Bun ignores trailing argv after the entry script.
    const cwd = if (cwd_override) |override| try allocator.dupe(u8, override) else blk: {
        const real_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        break :blk real_cwd;
    };
    defer allocator.free(cwd);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, runtime);
    for (extension_paths) |p| try argv.append(allocator, p);
    try argv.append(allocator, marker);

    const host = extension_host_mod.HostProcess.start(allocator, io, .{
        .argv = argv.items,
        .cwd = cwd,
        .initialize = .{
            .marker = marker,
            .cwd = cwd,
            .fixture = fixture,
        },
        .shutdown_timeout_ms = 1000,
    }) catch |err| {
        try stderr.print("Error: failed to start extension host: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer host.deinit();

    host.waitForReady(ready_timeout_ms) catch {
        try stderr.writeAll("Error: extension host did not become ready\n");
        return 1;
    };

    // Wait until the host has been quiescent for >100ms with no new
    // registry frames arriving, or `drain_timeout_ms` has elapsed.
    var elapsed: u64 = 0;
    var last_count: usize = 0;
    var quiet: u64 = 0;
    const tick_ms: u64 = 10;
    while (elapsed < drain_timeout_ms) : (elapsed += tick_ms) {
        const cur = host.registryFramesApplied();
        if (cur != last_count) {
            last_count = cur;
            quiet = 0;
        } else {
            quiet += tick_ms;
            if (quiet >= 100 and last_count != 0) break;
        }
        std.Io.sleep(io, .fromMilliseconds(@intCast(tick_ms)), .awake) catch {};
    }

    // Plumb parsed CLI flag values into the live registry so
    // extensions can observe them through `getFlag()`.
    if (parsed_flag_values.len > 0) {
        host.applyCliFlagValues(parsed_flag_values) catch {};
    }

    const snapshot = try host.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot);
    try stdout.print("{s}\n", .{snapshot});

    host.shutdown() catch {};
    return 0;
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

fn makeAbsoluteTestPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

fn makeTmpPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const relative_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        name,
    });
    defer allocator.free(relative_dir);
    return try makeAbsoluteTestPath(allocator, relative_dir);
}

const CliExecutableResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(self: *CliExecutableResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

fn exitCodeFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

fn hasAnsiEscape(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '\x1b') != null;
}

fn runCliExecutable(
    allocator: std.mem.Allocator,
    tmp: anytype,
    args: []const []const u8,
    env_entries: []const struct { []const u8, []const u8 },
) !CliExecutableResult {
    try tmp.dir.createDirPath(std.testing.io, "home");
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "project");

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const agent_dir = try makeTmpPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    const binary_path = try makeAbsoluteTestPath(allocator, "zig-out/bin/pi");
    defer allocator.free(binary_path);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, binary_path);
    try argv.appendSlice(allocator, args);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    for (env_entries) |entry| {
        try env_map.put(entry[0], entry[1]);
    }

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .path = project_dir },
        .environ_map = &env_map,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exitCodeFromTerm(result.term),
    };
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
    try std.testing.expect(std.mem.indexOf(u8, help, "--mode <text|json|rpc|ts-rpc>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--tools <names>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-tools") != null);
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
    const no_builtin_selection = effectiveToolSelection(&no_builtin_args).?;
    try std.testing.expectEqual(@as(usize, 0), no_builtin_selection.len);

    var explicit_args = try cli.parseArgs(allocator, &.{
        "--no-builtin-tools",
        "--tools",
        "read,ls",
    });
    defer explicit_args.deinit(allocator);
    const explicit_selection = effectiveToolSelection(&explicit_args).?;
    try std.testing.expectEqual(@as(usize, 2), explicit_selection.len);
    try std.testing.expectEqualStrings("read", explicit_selection[0]);
    try std.testing.expectEqualStrings("ls", explicit_selection[1]);

    var app_context = coding_agent.interactive_mode.AppContext.init("/tmp", std.testing.io);
    var built_tools = try coding_agent.interactive_mode.buildAgentTools(allocator, &app_context, no_builtin_selection);
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

    const cwd = try makeTmpPath(allocator, tmp, "cli-export");
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
    const cwd = try makeTmpPath(allocator, tmp, "cli-file-text");
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
    const cwd = try makeTmpPath(allocator, tmp, "cli-file-image");
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
    const cwd = try makeTmpPath(allocator, tmp, "cli-file-image-omit");
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
    const cwd = try makeTmpPath(allocator, tmp, "cli-file-image-no-resize");
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

    var result = try runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--print", "hello" },
        &.{.{ "PI_FAUX_RESPONSE", "hello from cli binary" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("hello from cli binary\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(!hasAnsiEscape(result.stdout));
    try std.testing.expect(!hasAnsiEscape(result.stderr));
}

test "cli executable print mode json writes valid JSON lines to stdout" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--mode", "json", "--print", "hello" },
        &.{.{ "PI_FAUX_RESPONSE", "json from cli binary" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(!hasAnsiEscape(result.stdout));

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

test "runCli persists and continues sessions across runs" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeTmpPath(allocator, tmp, "cli-session");
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

    const cwd = try makeTmpPath(allocator, tmp, "cli-resume");
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

    const cwd = try makeTmpPath(allocator, tmp, "cli-no-session");
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

    const cwd = try makeTmpPath(allocator, tmp, "cli-session-dir");
    defer allocator.free(cwd);
    const overridden_session_dir = try makeTmpPath(allocator, tmp, "custom-sessions");
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

    const cwd = try makeTmpPath(allocator, tmp, "cli-fork");
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

    const fixture_path = try makeAbsoluteTestPath(allocator, "test/fixtures/extensions/flag-fixture/extension.ts");
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
    const ext_path = try makeTmpPath(allocator, tmp, "ext-stub.sh");
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
    const ext_path = try makeTmpPath(allocator, tmp, "unreg.sh");
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

    const fixture_path = try makeAbsoluteTestPath(allocator, "test/fixtures/extensions/flag-fixture/extension.ts");
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

test "cli executable continue resumes the latest session while preserving older sessions" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ project_dir, ".pi", "sessions" });
    defer allocator.free(session_dir);

    var first = try runCliExecutable(
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

    var second = try runCliExecutable(
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

    var third = try runCliExecutable(
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

    var fourth = try runCliExecutable(
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
        .api = "openai-completions",
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

    const cwd = try makeTmpPath(allocator, tmp, "cli-multi-provider");
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

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try makeTmpPath(allocator, tmp, "repo");
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
    try std.testing.expectEqualStrings("Fix parser bug please.", prepared.expanded_prompt.?);
    try std.testing.expect(prepared.context_files.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "Project instructions from AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "<available_skills>") != null);

    const expected_session_dir = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, "sessions" });
    defer allocator.free(expected_session_dir);
    try std.testing.expectEqualStrings(expected_session_dir, prepared.session_dir);
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

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try makeTmpPath(allocator, tmp, "repo");
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
    try std.testing.expectEqualStrings("CLI fix parser bug.", prepared.expanded_prompt.?);
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

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try makeTmpPath(allocator, tmp, "repo");
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

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, null);
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

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("KIMI_API_KEY", "kimi-key");

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, null);
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

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const stored_cwd = try makeTmpPath(allocator, tmp, "stored");
    defer allocator.free(stored_cwd);
    const launch_cwd = try makeTmpPath(allocator, tmp, "launch");
    defer allocator.free(launch_cwd);
    const session_dir = try makeTmpPath(allocator, tmp, "sessions");
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

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);
    const explicit_dir = try makeTmpPath(allocator, tmp, "explicit");
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

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);
    const env_dir = try makeTmpPath(allocator, tmp, "envvar-sessions");
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

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try makeTmpPath(allocator, tmp, "repo");
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

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);
    const env_dir = try makeTmpPath(allocator, tmp, "envvar-sessions");
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
