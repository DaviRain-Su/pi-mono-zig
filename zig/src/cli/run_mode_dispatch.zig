const std = @import("std");
const bootstrap = @import("bootstrap.zig");
const cli = @import("args.zig");
const cli_preflight = @import("preflight.zig");
const input_prep = @import("input_prep.zig");
const runtime_prep = @import("runtime_prep.zig");
const output = @import("output.zig");
const coding_agent = @import("../coding_agent/root.zig");

pub const DispatchRunModeOptions = struct {
    cwd: []const u8,
    app_mode: bootstrap.AppMode,
    selected_tools: ?[]const []const u8,
    preflight_continue_confirmed: bool = false,
    version: []const u8,
};

/// Route the prepared CLI invocation to the selected execution mode.
///
/// `main.zig` owns argument parsing, extension flag pre-dispatch, cwd
/// resolution, and the pre-runtime missing-cwd preflight. This helper owns the
/// post-runtime mode branch: prompt validation for print/json, the
/// non-interactive prepared missing-cwd preflight, provider resolution,
/// session opening, and the final interactive/print/json/RPC/TS-RPC call.
pub fn dispatchRunMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    options: *const cli.Args,
    prepared: *runtime_prep.PreparedCliRuntime,
    initial_input: *const input_prep.PreparedInitialInput,
    dispatch_options: DispatchRunModeOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const cwd = dispatch_options.cwd;
    const app_mode = dispatch_options.app_mode;

    if (app_mode == .print or app_mode == .json) {
        if (initial_input.prompt == null) {
            try stderr.writeAll("Error: No prompt provided\n\n");
            try output.printUsage(allocator, dispatch_options.version, stdout);
            return 1;
        }
    }

    if (app_mode != .interactive) {
        // Preflight stored-session cwd BEFORE provider/auth resolution and
        // tool construction so missing-cwd diagnostics always preempt
        // unrelated bootstrap failures. Matches TypeScript main.ts ordering.
        const preflight_result = try cli_preflight.runMissingSessionCwdPreflight(
            allocator,
            io,
            env_map,
            cli_preflight.preparedContext(cwd, prepared.session_dir, prepared.system_prompt, prepared.provider_name, options),
            false,
            stderr,
        );
        if (preflight_result.exit_code) |exit_code| return exit_code;
    }

    var provider_runtime = coding_agent.resolveProviderConfig(
        allocator,
        io,
        env_map,
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
        return try dispatchNonInteractiveMode(
            allocator,
            io,
            options,
            env_map,
            prepared,
            initial_input,
            dispatch_options,
            &provider_runtime,
            stdout,
            stderr,
        );
    }

    return try coding_agent.runInteractiveMode(
        allocator,
        io,
        env_map,
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
            .selected_tools = dispatch_options.selected_tools,
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
            .missing_cwd_mode = if (dispatch_options.preflight_continue_confirmed) .use_fallback else .fail,
            .missing_cwd_already_confirmed = dispatch_options.preflight_continue_confirmed,
        },
        stderr,
    );
}

fn dispatchNonInteractiveMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: *const cli.Args,
    env_map: *const std.process.Environ.Map,
    prepared: *runtime_prep.PreparedCliRuntime,
    initial_input: *const input_prep.PreparedInitialInput,
    dispatch_options: DispatchRunModeOptions,
    provider_runtime: *coding_agent.ResolvedProviderConfig,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const cwd = dispatch_options.cwd;
    var app_context = coding_agent.interactive_mode.AppContext.init(cwd, io);
    var built_tools = try coding_agent.interactive_mode.buildAgentTools(allocator, &app_context, dispatch_options.selected_tools);
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
            .selected_tools = dispatch_options.selected_tools,
            .initial_prompt = null,
            .initial_images = &.{},
            .prompt_templates = prepared.resource_bundle.prompt_templates,
            .keybindings = &prepared.runtime_config.keybindings,
            .theme = prepared.resource_bundle.selectedTheme(),
            .runtime_config = &prepared.runtime_config,
            // Non-interactive flows must never silently fall back to the
            // launch cwd when the stored session cwd no longer exists.
            // The early preflight already failed/exited before this point if
            // the stored cwd was missing, so a missing-cwd issue here is
            // purely a race fallback.
            .missing_cwd_mode = .fail,
            .missing_cwd_already_confirmed = dispatch_options.preflight_continue_confirmed,
        },
        provider_runtime.model,
        provider_runtime.api_key,
        built_tools.items,
        &missing_cwd_issue,
    ) catch |err| switch (err) {
        error.MissingSessionCwd => {
            if (missing_cwd_issue) |captured| {
                try cli_preflight.writeMissingSessionCwdError(allocator, captured.issue(), stderr);
            } else {
                try cli_preflight.writeMissingSessionCwdFallbackError(stderr);
            }
            try stderr.flush();
            return 1;
        },
        else => return err,
    };
    defer session.deinit();

    if (dispatch_options.app_mode == .rpc) {
        return try coding_agent.runRpcMode(
            allocator,
            io,
            &session,
            .{},
            stdout,
            stderr,
        );
    }

    if (dispatch_options.app_mode == .ts_rpc) {
        var extension_host_options = try tsRpcExtensionHostOptions(allocator, env_map, cwd);
        defer extension_host_options.deinit(allocator);
        return try coding_agent.runTsRpcMode(
            allocator,
            io,
            &session,
            .{
                .extension_ui_parity_scenario = isEnabledEnv(env_map, "PI_TS_RPC_EXTENSION_UI_PARITY_SCENARIO"),
                .extension_host = extension_host_options.options,
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
            .mode = if (dispatch_options.app_mode == .json) .json else .text,
            .config_errors = prepared.runtime_config.errors,
            .initial_images = initial_input.images,
        },
        stdout,
        stderr,
    );
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
    const marker = env_map.get(coding_agent.extension_runtime.HOST_MARKER_ENV) orelse "pi-m6-extension-host";
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

fn isEnabledEnv(env_map: *const std.process.Environ.Map, key: []const u8) bool {
    const value = env_map.get(key) orelse return false;
    return isEnabledValue(value);
}

fn isEnabledValue(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes");
}
