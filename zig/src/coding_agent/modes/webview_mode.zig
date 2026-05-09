const std = @import("std");
const builtin = @import("builtin");
const ai = @import("ai");
const session_mod = @import("../sessions/session.zig");
const tool_selection = @import("../tool_selection.zig");
const webview_bridge = @import("webview_bridge.zig");
const webview_platform = @import("webview_platform.zig");

const frontend_asset_relative_path = "share/pi/webview/index.html";
const source_asset_relative_path = "assets/webview/index.html";

const MacosNative = if (builtin.os.tag == .macos) struct {
    extern fn pi_webview_macos_run(
        asset_path: [*:0]const u8,
        window_title: [*:0]const u8,
        auto_close_ms: c_int,
        bridge_context: ?*anyopaque,
        handle_request: *const fn (?*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) ?[*:0]u8,
        free_response: *const fn (?*anyopaque, [*:0]u8) callconv(.c) void,
        close_active_work: *const fn (?*anyopaque) callconv(.c) void,
    ) c_int;
    extern fn pi_webview_macos_last_error() ?[*:0]const u8;
} else struct {};

pub const RunWebViewModeOptions = struct {
    cwd: []const u8,
    provider: []const u8,
    model: ai.Model,
    backend: webview_platform.AvailableBackend,
    no_session: bool,
    api_key_present: bool,
    selected_tools: tool_selection.ToolSelection,
    active_tool_count: usize,
    initial_prompt: ?[]const u8 = null,
    initial_messages: []const []const u8 = &.{},
    initial_images_count: usize = 0,
};

pub const AssetResolutionError = error{
    AssetNotFound,
    InvalidInstallLayout,
};

pub const ResolvedFrontendAsset = struct {
    asset_path: []const u8,
    asset_root: []const u8,
    source: Source,

    pub const Source = enum {
        install_layout,
        source_layout,
        env_override,
    };

    pub fn deinit(self: *ResolvedFrontendAsset, allocator: std.mem.Allocator) void {
        allocator.free(self.asset_path);
        allocator.free(self.asset_root);
        self.* = undefined;
    }
};

const StartupFailureStage = enum {
    after_asset_resolve,
    after_backend_init,
    after_bridge_registration,
};

const StartupCleanupState = struct {
    asset_resolved: bool = false,
    backend_initialized: bool = false,
    bridge_registered: bool = false,

    fn cleanup(self: *StartupCleanupState, stderr: *std.Io.Writer, reason: []const u8) !void {
        try stderr.print(
            "PI_WEBVIEW_CLEANUP reason={s} asset_resolved={s} backend_initialized={s} bridge_registered={s}\n",
            .{
                reason,
                boolText(self.asset_resolved),
                boolText(self.backend_initialized),
                boolText(self.bridge_registered),
            },
        );
        self.asset_resolved = false;
        self.backend_initialized = false;
        self.bridge_registered = false;
    }
};

pub fn runWebViewMode(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    options: RunWebViewModeOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    if (isEnabledEnv(env_map, "PI_WEBVIEW_CAPTURE_LAUNCH_CONTEXT")) {
        try writeLaunchContextJson(allocator, session, options, stdout);
        return 0;
    }

    var cleanup_state = StartupCleanupState{};
    var asset = resolveFrontendAsset(allocator, env_map, options.cwd) catch |err| {
        try writeAssetDiagnostic(stderr, options.cwd, err);
        try cleanup_state.cleanup(stderr, "asset_resolution_failed");
        return 1;
    };
    defer asset.deinit(allocator);
    cleanup_state.asset_resolved = true;

    if (injectedFailureStage(env_map)) |stage| {
        switch (stage) {
            .after_asset_resolve => {
                try stderr.writeAll("Error: injected WebView startup failure after asset resolution\n");
                try cleanup_state.cleanup(stderr, "injected_after_asset_resolve");
                return 1;
            },
            .after_backend_init => cleanup_state.backend_initialized = true,
            .after_bridge_registration => {
                cleanup_state.backend_initialized = true;
                cleanup_state.bridge_registered = true;
            },
        }
        try stderr.print("Error: injected WebView startup failure at {s}\n", .{@tagName(stage)});
        try cleanup_state.cleanup(stderr, @tagName(stage));
        return 1;
    }

    try stderr.print(
        "PI_WEBVIEW_START pid={d} provider={s} model={s} backend={s} asset={s} asset_source={s}\n",
        .{
            std.c.getpid(),
            options.provider,
            options.model.id,
            @tagName(options.backend.backend),
            asset.asset_path,
            @tagName(asset.source),
        },
    );
    try stderr.flush();

    var smoke_faux_registration: ?ai.providers.faux.FauxProviderRegistration = null;
    defer if (smoke_faux_registration) |registration| registration.unregister();
    try configureFauxWebViewSmokeFixtures(allocator, env_map, options.provider, &smoke_faux_registration);

    var bridge = webview_bridge.BridgeHost.init(.{
        .cwd = options.cwd,
        .trusted_asset_root = asset.asset_root,
        .provider = options.provider,
        .model = options.model,
        .no_session = options.no_session,
        .api_key_present = options.api_key_present,
        .selected_tools = options.selected_tools,
        .active_tool_count = options.active_tool_count,
        .session = session,
        .initial_prompt = options.initial_prompt,
        .initial_messages = options.initial_messages,
        .initial_images_count = options.initial_images_count,
    });
    cleanup_state.bridge_registered = true;

    if (env_map.get("PI_WEBVIEW_SMOKE_PROMPT")) |prompt_text| {
        try runBridgeSmokePrompt(allocator, &bridge, prompt_text, stdout);
    }
    if (env_map.get("PI_WEBVIEW_SMOKE_PROVIDER_ERROR_PROMPT")) |prompt_text| {
        try runBridgeSmokeProviderError(allocator, &bridge, prompt_text, stdout);
    }
    if (env_map.get("PI_WEBVIEW_SMOKE_ABORT_PROMPT")) |prompt_text| {
        try runBridgeSmokeAbortFlow(allocator, &bridge, prompt_text, stdout);
    }
    if (env_map.get("PI_WEBVIEW_SMOKE_CLOSE_PROMPT")) |prompt_text| {
        try runBridgeSmokeCloseFlow(allocator, &bridge, prompt_text, stdout);
    }

    const exit_code = try runNativeWebView(allocator, env_map, asset.asset_path, &bridge, stderr);
    if (exit_code != 0) {
        try cleanup_state.cleanup(stderr, "native_startup_failed");
        return exit_code;
    }

    try cleanup_state.cleanup(stderr, "normal_shutdown");
    return 0;
}

pub fn resolveFrontendAsset(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
) !ResolvedFrontendAsset {
    if (env_map.get("PI_WEBVIEW_ASSET_DIR")) |override_dir| {
        return try resolveAssetInRoot(allocator, override_dir, .env_override);
    }

    const exe_path = std.process.executablePathAlloc(std.Io.Threaded.global_single_threaded.io(), allocator) catch null;
    defer if (exe_path) |path| allocator.free(path);
    return resolveFrontendAssetForLayout(allocator, cwd, exe_path);
}

pub fn resolveFrontendAssetForLayout(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    exe_path: ?[]const u8,
) !ResolvedFrontendAsset {
    if (exe_path) |path| {
        if (std.fs.path.dirname(path)) |bin_dir| {
            if (std.fs.path.dirname(bin_dir)) |install_root| {
                const share_root = try std.fs.path.join(allocator, &.{ install_root, "share", "pi", "webview" });
                defer allocator.free(share_root);
                if (resolveAssetInRoot(allocator, share_root, .install_layout)) |asset| return asset else |_| {}
            } else {
                return error.InvalidInstallLayout;
            }
        } else {
            return error.InvalidInstallLayout;
        }
    }

    const cwd_basename = std.fs.path.basename(cwd);
    if (std.mem.eql(u8, cwd_basename, "zig")) {
        const source_root = try std.fs.path.join(allocator, &.{ cwd, "assets", "webview" });
        defer allocator.free(source_root);
        if (resolveAssetInRoot(allocator, source_root, .source_layout)) |asset| {
            return asset;
        } else |_| {}
    } else {
        const repo_zig_asset_root = try std.fs.path.join(allocator, &.{ cwd, "zig", "assets", "webview" });
        defer allocator.free(repo_zig_asset_root);
        if (resolveAssetInRoot(allocator, repo_zig_asset_root, .source_layout)) |asset| return asset else |_| {}
    }

    return error.AssetNotFound;
}

fn resolveAssetInRoot(
    allocator: std.mem.Allocator,
    root: []const u8,
    source: ResolvedFrontendAsset.Source,
) !ResolvedFrontendAsset {
    const asset_path = webview_bridge.resolveAssetRequest(allocator, root, "index.html") catch |err| switch (err) {
        error.FileNotFound => return error.AssetNotFound,
        error.AssetPathDenied => return error.AssetNotFound,
        else => return err,
    };
    errdefer allocator.free(asset_path);
    return .{
        .asset_path = asset_path,
        .asset_root = try allocator.dupe(u8, root),
        .source = source,
    };
}

fn writeAssetDiagnostic(stderr: *std.Io.Writer, cwd: []const u8, err: anyerror) !void {
    switch (err) {
        error.AssetNotFound => try stderr.print(
            "Error: WebView frontend asset not found. Expected bundled asset at {s} relative to the installed pi binary, or source asset at zig/{s} from cwd {s}\n",
            .{ frontend_asset_relative_path, source_asset_relative_path, cwd },
        ),
        error.InvalidInstallLayout => try stderr.writeAll(
            "Error: WebView frontend asset resolution failed because the pi executable is not in a recognizable install layout\n",
        ),
        else => try stderr.print("Error: WebView frontend asset resolution failed: {s}\n", .{@errorName(err)}),
    }
}

fn runNativeWebView(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    asset_path: []const u8,
    bridge: *webview_bridge.BridgeHost,
    stderr: *std.Io.Writer,
) !u8 {
    if (builtin.os.tag != .macos) {
        try stderr.writeAll("Error: WebView native launcher is only implemented for macOS in this build\n");
        return 1;
    }

    const asset_path_z = try allocator.dupeZ(u8, asset_path);
    defer allocator.free(asset_path_z);
    const title_z = try allocator.dupeZ(u8, "pi WebView");
    defer allocator.free(title_z);
    const auto_close_ms = parsePositiveIntEnv(env_map, "PI_WEBVIEW_AUTO_CLOSE_MS") orelse 0;

    const result = MacosNative.pi_webview_macos_run(
        asset_path_z.ptr,
        title_z.ptr,
        @intCast(auto_close_ms),
        bridge,
        nativeBridgeHandleRequest,
        nativeBridgeFreeResponse,
        nativeBridgeCloseActiveWork,
    );
    if (result != 0) {
        if (MacosNative.pi_webview_macos_last_error()) |message| {
            try stderr.print("Error: macOS WebView startup failed: {s}\n", .{std.mem.span(message)});
        } else {
            try stderr.writeAll("Error: macOS WebView startup failed\n");
        }
        return 1;
    }
    return 0;
}

fn nativeBridgeHandleRequest(
    context: ?*anyopaque,
    request_json_z: [*:0]const u8,
    origin_z: [*:0]const u8,
) callconv(.c) ?[*:0]u8 {
    const bridge: *webview_bridge.BridgeHost = @ptrCast(@alignCast(context orelse return null));
    const allocator = std.heap.c_allocator;
    const request_json = std.mem.span(request_json_z);
    const origin = std.mem.span(origin_z);
    const response = bridge.handleRequestJson(allocator, request_json, origin) catch |err| {
        if (err == error.OutOfMemory) return null;
        const fallback = "{\"id\":null,\"ok\":false,\"error\":{\"code\":\"handler_error\",\"message\":\"Bridge command failed\"}}";
        const fallback_z = allocator.dupeZ(u8, fallback) catch return null;
        return fallback_z.ptr;
    };
    defer allocator.free(response);
    const response_z = allocator.dupeZ(u8, response) catch return null;
    return response_z.ptr;
}

fn nativeBridgeFreeResponse(_: ?*anyopaque, response_z: [*:0]u8) callconv(.c) void {
    const response = std.mem.span(response_z);
    std.heap.c_allocator.free(response_z[0 .. response.len + 1]);
}

fn nativeBridgeCloseActiveWork(context: ?*anyopaque) callconv(.c) void {
    const bridge: *webview_bridge.BridgeHost = @ptrCast(@alignCast(context orelse return));
    _ = bridge.closeAndAbortActiveWork();
}

fn runBridgeSmokePrompt(
    allocator: std.mem.Allocator,
    bridge: *webview_bridge.BridgeHost,
    prompt_text: []const u8,
    stdout: *std.Io.Writer,
) !void {
    try writeBridgeSmokeResponse(allocator, bridge, "state", "{\"id\":\"smoke-state\",\"command\":\"get_state\"}", stdout);
    try writeBridgeSmokeResponse(allocator, bridge, "messages_before", "{\"id\":\"smoke-messages-before\",\"command\":\"get_messages\"}", stdout);

    var prompt_request: std.Io.Writer.Allocating = .init(allocator);
    defer prompt_request.deinit();
    try prompt_request.writer.writeAll("{\"id\":\"smoke-prompt\",\"command\":\"prompt\",\"payload\":{\"text\":");
    try writeJsonString(allocator, &prompt_request.writer, prompt_text);
    try prompt_request.writer.writeAll("}}");
    try writeBridgeSmokeResponse(allocator, bridge, "prompt", prompt_request.written(), stdout);

    try writeBridgeSmokeResponse(allocator, bridge, "messages_after", "{\"id\":\"smoke-messages-after\",\"command\":\"get_messages\"}", stdout);
}

fn runBridgeSmokeProviderError(
    allocator: std.mem.Allocator,
    bridge: *webview_bridge.BridgeHost,
    prompt_text: []const u8,
    stdout: *std.Io.Writer,
) !void {
    try writeBridgeSmokeResponse(allocator, bridge, "state", "{\"id\":\"smoke-error-state\",\"command\":\"get_state\"}", stdout);
    var prompt_request: std.Io.Writer.Allocating = .init(allocator);
    defer prompt_request.deinit();
    try prompt_request.writer.writeAll("{\"id\":\"smoke-error-prompt\",\"command\":\"prompt\",\"payload\":{\"text\":");
    try writeJsonString(allocator, &prompt_request.writer, prompt_text);
    try prompt_request.writer.writeAll("}}");
    try writeBridgeSmokeResponse(allocator, bridge, "provider_error", prompt_request.written(), stdout);
    try writeBridgeSmokeResponse(allocator, bridge, "state_after_error", "{\"id\":\"smoke-error-state-after\",\"command\":\"get_state\"}", stdout);
}

fn runBridgeSmokeAbortFlow(
    allocator: std.mem.Allocator,
    bridge: *webview_bridge.BridgeHost,
    prompt_text: []const u8,
    stdout: *std.Io.Writer,
) !void {
    var prompt_request: std.Io.Writer.Allocating = .init(allocator);
    defer prompt_request.deinit();
    try prompt_request.writer.writeAll("{\"id\":\"smoke-abort-prompt\",\"command\":\"prompt\",\"payload\":{\"text\":");
    try writeJsonString(allocator, &prompt_request.writer, prompt_text);
    try prompt_request.writer.writeAll("}}");

    var thread_result = BridgeSmokeThreadResult{};
    const prompt_request_owned = try allocator.dupe(u8, prompt_request.written());
    defer allocator.free(prompt_request_owned);
    const prompt_thread = try std.Thread.spawn(.{}, runBridgeSmokePromptThread, .{ bridge, prompt_request_owned, &thread_result });
    while (!bridge.active_generation.load(.seq_cst)) {
        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(10), .awake) catch {};
    }
    std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(250), .awake) catch {};

    try writeBridgeSmokeResponse(allocator, bridge, "abort", "{\"id\":\"smoke-abort\",\"command\":\"abort\"}", stdout);
    prompt_thread.join();
    if (thread_result.err) |err| return err;
    const prompt_response = thread_result.response orelse return error.WebViewSmokePromptMissingResponse;
    defer std.heap.c_allocator.free(prompt_response);
    try stdout.print("PI_WEBVIEW_BRIDGE_TRANSCRIPT label=aborted_prompt response={s}\n", .{prompt_response});

    try writeBridgeSmokeResponse(
        allocator,
        bridge,
        "retry_after_abort",
        "{\"id\":\"smoke-retry\",\"command\":\"prompt\",\"payload\":{\"text\":\"retry after abort\"}}",
        stdout,
    );
    try writeBridgeSmokeResponse(allocator, bridge, "state_after_abort_retry", "{\"id\":\"smoke-abort-state-after\",\"command\":\"get_state\"}", stdout);
}

fn runBridgeSmokeCloseFlow(
    allocator: std.mem.Allocator,
    bridge: *webview_bridge.BridgeHost,
    prompt_text: []const u8,
    stdout: *std.Io.Writer,
) !void {
    var prompt_request: std.Io.Writer.Allocating = .init(allocator);
    defer prompt_request.deinit();
    try prompt_request.writer.writeAll("{\"id\":\"smoke-close-prompt\",\"command\":\"prompt\",\"payload\":{\"text\":");
    try writeJsonString(allocator, &prompt_request.writer, prompt_text);
    try prompt_request.writer.writeAll("}}");

    var thread_result = BridgeSmokeThreadResult{};
    const prompt_request_owned = try allocator.dupe(u8, prompt_request.written());
    defer allocator.free(prompt_request_owned);
    const prompt_thread = try std.Thread.spawn(.{}, runBridgeSmokePromptThread, .{ bridge, prompt_request_owned, &thread_result });
    while (!bridge.active_generation.load(.seq_cst)) {
        std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(10), .awake) catch {};
    }
    std.Io.sleep(std.Io.Threaded.global_single_threaded.io(), .fromMilliseconds(250), .awake) catch {};
    const aborted = bridge.closeAndAbortActiveWork();
    try stdout.print(
        "PI_WEBVIEW_CLOSE_DURING_ACTIVE aborted={s} active_before_join={s}\n",
        .{ boolText(aborted), boolText(bridge.active_generation.load(.seq_cst)) },
    );
    prompt_thread.join();
    if (thread_result.err) |err| return err;
    const prompt_response = thread_result.response orelse return error.WebViewSmokePromptMissingResponse;
    defer std.heap.c_allocator.free(prompt_response);
    try stdout.print("PI_WEBVIEW_BRIDGE_TRANSCRIPT label=closed_prompt response={s}\n", .{prompt_response});
    try stdout.print("PI_WEBVIEW_CLOSE_CLEANUP active_after_join={s}\n", .{boolText(bridge.active_generation.load(.seq_cst))});
}

const BridgeSmokeThreadResult = struct {
    response: ?[]u8 = null,
    err: ?anyerror = null,
};

fn runBridgeSmokePromptThread(
    bridge: *webview_bridge.BridgeHost,
    request_json: []const u8,
    result: *BridgeSmokeThreadResult,
) void {
    result.response = bridge.handleRequestJson(
        std.heap.c_allocator,
        request_json,
        webview_bridge.trusted_bundle_origin,
    ) catch |err| {
        result.err = err;
        return;
    };
}

fn configureFauxWebViewSmokeFixtures(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
    registration_out: *?ai.providers.faux.FauxProviderRegistration,
) !void {
    if (!std.mem.eql(u8, provider, "faux")) return;
    if (env_map.get("PI_WEBVIEW_SMOKE_ABORT_PROMPT") != null) {
        const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
            .tokens_per_second = 5,
            .token_size = .{ .min = 1, .max = 1 },
        });
        errdefer registration.unregister();
        try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
            .{ .factory = webViewSlowSmokeFactory },
            .{ .factory = webViewRetrySmokeFactory },
        });
        registration_out.* = registration;
        return;
    }
    if (env_map.get("PI_WEBVIEW_SMOKE_CLOSE_PROMPT") != null) {
        const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
            .tokens_per_second = 5,
            .token_size = .{ .min = 1, .max = 1 },
        });
        errdefer registration.unregister();
        try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
            .{ .factory = webViewSlowSmokeFactory },
        });
        registration_out.* = registration;
        return;
    }
    if (env_map.get("PI_WEBVIEW_SMOKE_PROVIDER_ERROR_PROMPT") != null) {
        const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
        errdefer registration.unregister();
        try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
            .{ .factory = webViewProviderErrorSmokeFactory },
        });
        registration_out.* = registration;
        return;
    }
    if (env_map.get("PI_WEBVIEW_SMOKE_PROMPT") != null) {
        const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
        errdefer registration.unregister();
        try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
            .{ .factory = webViewSuccessSmokeFactory },
        });
        registration_out.* = registration;
    }
}

fn webViewSuccessSmokeFactory(
    allocator: std.mem.Allocator,
    _: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("faux WebView smoke response");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

fn webViewSlowSmokeFactory(
    allocator: std.mem.Allocator,
    _: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

fn webViewRetrySmokeFactory(
    allocator: std.mem.Allocator,
    _: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("retry after abort succeeded");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

fn webViewProviderErrorSmokeFactory(
    allocator: std.mem.Allocator,
    _: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("partial before faux provider error");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{
        .stop_reason = .error_reason,
        .error_message = "faux provider error for WebView smoke",
    });
}

fn writeBridgeSmokeResponse(
    allocator: std.mem.Allocator,
    bridge: *webview_bridge.BridgeHost,
    label: []const u8,
    request_json: []const u8,
    stdout: *std.Io.Writer,
) !void {
    const response = try bridge.handleRequestJson(allocator, request_json, webview_bridge.trusted_bundle_origin);
    defer allocator.free(response);
    try stdout.print("PI_WEBVIEW_BRIDGE_TRANSCRIPT label={s} response={s}\n", .{ label, response });
}

fn parsePositiveIntEnv(env_map: *const std.process.Environ.Map, key: []const u8) ?u32 {
    const value = env_map.get(key) orelse return null;
    const parsed = std.fmt.parseUnsigned(u32, value, 10) catch return null;
    return parsed;
}

fn injectedFailureStage(env_map: *const std.process.Environ.Map) ?StartupFailureStage {
    const value = env_map.get("PI_WEBVIEW_INJECT_STARTUP_FAILURE") orelse return null;
    if (std.mem.eql(u8, value, "after_asset_resolve")) return .after_asset_resolve;
    if (std.mem.eql(u8, value, "after_backend_init")) return .after_backend_init;
    if (std.mem.eql(u8, value, "after_bridge_registration")) return .after_bridge_registration;
    return null;
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn writeLaunchContextJson(
    allocator: std.mem.Allocator,
    session: *const session_mod.AgentSession,
    options: RunWebViewModeOptions,
    stdout: *std.Io.Writer,
) !void {
    try stdout.writeAll("{");
    try writeStringField(allocator, stdout, "mode", "webview", false);
    try writeStringField(allocator, stdout, "cwd", options.cwd, true);
    try writeStringField(allocator, stdout, "provider", options.provider, true);
    try writeStringField(allocator, stdout, "model", options.model.id, true);
    try writeStringField(allocator, stdout, "modelProvider", options.model.provider, true);
    try writeStringField(allocator, stdout, "backend", @tagName(options.backend.backend), true);
    try writeStringField(allocator, stdout, "platform", @tagName(options.backend.platform), true);
    try writeStringField(allocator, stdout, "sessionId", session.session_manager.getSessionId(), true);
    try writeOptionalStringField(allocator, stdout, "sessionFile", session.session_manager.getSessionFile(), true);
    try writeBoolField(stdout, "noSession", options.no_session, true);
    try writeBoolField(stdout, "apiKeyPresent", options.api_key_present, true);
    try writeBoolField(stdout, "toolsDisabled", options.selected_tools.disable_all, true);
    try writeBoolField(stdout, "includeBuiltinTools", options.selected_tools.include_builtins, true);
    try writeStringArrayOrNullField(allocator, stdout, "toolAllowlist", options.selected_tools.allowlist, true);
    try writeUsizeField(stdout, "activeToolCount", options.active_tool_count, true);
    try writeOptionalStringField(allocator, stdout, "initialPrompt", options.initial_prompt, true);
    try writeStringArrayField(allocator, stdout, "initialMessages", options.initial_messages, true);
    try writeUsizeField(stdout, "initialImagesCount", options.initial_images_count, true);
    try stdout.writeAll("}\n");
}

fn writeStringField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    name: []const u8,
    value: []const u8,
    comma: bool,
) !void {
    if (comma) try writer.writeAll(",");
    try writeJsonString(allocator, writer, name);
    try writer.writeAll(":");
    try writeJsonString(allocator, writer, value);
}

fn writeOptionalStringField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    name: []const u8,
    value: ?[]const u8,
    comma: bool,
) !void {
    if (comma) try writer.writeAll(",");
    try writeJsonString(allocator, writer, name);
    try writer.writeAll(":");
    if (value) |text| {
        try writeJsonString(allocator, writer, text);
    } else {
        try writer.writeAll("null");
    }
}

fn writeBoolField(
    writer: *std.Io.Writer,
    name: []const u8,
    value: bool,
    comma: bool,
) !void {
    if (comma) try writer.writeAll(",");
    try writer.print("\"{s}\":{s}", .{ name, if (value) "true" else "false" });
}

fn writeUsizeField(
    writer: *std.Io.Writer,
    name: []const u8,
    value: usize,
    comma: bool,
) !void {
    if (comma) try writer.writeAll(",");
    try writer.print("\"{s}\":{d}", .{ name, value });
}

fn writeStringArrayOrNullField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    name: []const u8,
    values: ?[]const []const u8,
    comma: bool,
) !void {
    if (values) |items| {
        try writeStringArrayField(allocator, writer, name, items, comma);
    } else {
        if (comma) try writer.writeAll(",");
        try writeJsonString(allocator, writer, name);
        try writer.writeAll(":null");
    }
}

fn writeStringArrayField(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    name: []const u8,
    values: []const []const u8,
    comma: bool,
) !void {
    if (comma) try writer.writeAll(",");
    try writeJsonString(allocator, writer, name);
    try writer.writeAll(":[");
    for (values, 0..) |value, index| {
        if (index > 0) try writer.writeAll(",");
        try writeJsonString(allocator, writer, value);
    }
    try writer.writeAll("]");
}

fn writeJsonString(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    value: []const u8,
) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = value }, .{});
    defer allocator.free(encoded);
    try writer.writeAll(encoded);
}

fn isEnabledEnv(env_map: *const std.process.Environ.Map, key: []const u8) bool {
    const value = env_map.get(key) orelse return false;
    return std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes");
}

test "resolve frontend asset prefers install layout independent of cwd" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "install/bin");
    try tmp.dir.createDirPath(std.testing.io, "install/share/pi/webview");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "install/share/pi/webview/index.html", .data = "<!doctype html>" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "install/bin/pi", .data = "" });

    const exe_path = try tmp.dir.realPathFileAlloc(std.testing.io, "install/bin/pi", allocator);
    defer allocator.free(exe_path);

    const unrelated_cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(unrelated_cwd);

    var asset = try resolveFrontendAssetForLayout(allocator, unrelated_cwd, exe_path);
    defer asset.deinit(allocator);

    try std.testing.expectEqual(ResolvedFrontendAsset.Source.install_layout, asset.source);
    try std.testing.expect(std.mem.endsWith(u8, asset.asset_path, "install/share/pi/webview/index.html"));
}

test "resolve frontend asset supports repo root and zig source cwd" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/zig/assets/webview");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/zig/assets/webview/index.html", .data = "<!doctype html>" });

    const repo_cwd = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", allocator);
    defer allocator.free(repo_cwd);
    var from_repo = try resolveFrontendAssetForLayout(allocator, repo_cwd, null);
    defer from_repo.deinit(allocator);
    try std.testing.expectEqual(ResolvedFrontendAsset.Source.source_layout, from_repo.source);

    const zig_cwd = try tmp.dir.realPathFileAlloc(std.testing.io, "repo/zig", allocator);
    defer allocator.free(zig_cwd);
    var from_zig = try resolveFrontendAssetForLayout(allocator, zig_cwd, null);
    defer from_zig.deinit(allocator);
    try std.testing.expectEqual(ResolvedFrontendAsset.Source.source_layout, from_zig.source);
    try std.testing.expectEqualStrings(from_repo.asset_path, from_zig.asset_path);
}

test "resolve frontend asset reports missing bundle clearly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "install/bin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "install/bin/pi", .data = "" });
    const exe_path = try tmp.dir.realPathFileAlloc(std.testing.io, "install/bin/pi", allocator);
    defer allocator.free(exe_path);
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd);

    try std.testing.expectError(error.AssetNotFound, resolveFrontendAssetForLayout(allocator, cwd, exe_path));
}

test "startup cleanup state clears partial resources after injected backend failure" {
    const allocator = std.testing.allocator;
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var state = StartupCleanupState{
        .asset_resolved = true,
        .backend_initialized = true,
        .bridge_registered = true,
    };
    try state.cleanup(&stderr_capture.writer, "after_bridge_registration");

    try std.testing.expect(!state.asset_resolved);
    try std.testing.expect(!state.backend_initialized);
    try std.testing.expect(!state.bridge_registered);
    const output = stderr_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "PI_WEBVIEW_CLEANUP") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "bridge_registered=true") != null);
}
