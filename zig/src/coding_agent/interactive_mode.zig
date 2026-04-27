const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tui = @import("tui");
const auth = @import("auth.zig");
const config_mod = @import("config.zig");
const keybindings_mod = @import("keybindings.zig");
const resources_mod = @import("resources.zig");
const session_advanced = @import("session_advanced.zig");
const session_manager_mod = @import("session_manager.zig");
const provider_config = @import("provider_config.zig");
const session_mod = @import("session.zig");
const common = @import("tools/common.zig");

const shared = @import("interactive_mode/shared.zig");
const formatting = @import("interactive_mode/formatting.zig");
const overlays = @import("interactive_mode/overlays.zig");
const rendering = @import("interactive_mode/rendering.zig");
const prompt_worker_mod = @import("interactive_mode/prompt_worker.zig");
const slash_commands = @import("interactive_mode/slash_commands.zig");
const input_dispatch = @import("interactive_mode/input_dispatch.zig");
const clipboard_image = @import("interactive_mode/clipboard_image.zig");
const tool_adapters = @import("interactive_mode/tool_adapters.zig");
const session_bootstrap = @import("interactive_mode/session_bootstrap.zig");

pub const RunInteractiveModeOptions = shared.RunInteractiveModeOptions;
pub const LiveResources = shared.LiveResources;
pub const ToolRuntime = shared.ToolRuntime;
pub const AppContext = shared.AppContext;
pub const currentSessionLabel = shared.currentSessionLabel;
pub const configuredCredentials = shared.configuredCredentials;
pub const configuredApiKeyForProvider = shared.configuredApiKeyForProvider;
pub const configuredCompactionSettings = shared.configuredCompactionSettings;
pub const configuredRetrySettings = shared.configuredRetrySettings;
pub const settingsResources = shared.settingsResources;
pub const normalizePathArgument = shared.normalizePathArgument;
pub const overrideApiKeyForProvider = shared.overrideApiKeyForProvider;
pub const ASSISTANT_PREFIX = formatting.ASSISTANT_PREFIX;
pub const formatPrefixedBlocks = formatting.formatPrefixedBlocks;
pub const formatAssistantMessage = formatting.formatAssistantMessage;
pub const formatToolCall = formatting.formatToolCall;
pub const formatToolResult = formatting.formatToolResult;
pub const blocksToText = formatting.blocksToText;
pub const SelectorOverlay = overlays.SelectorOverlay;
pub const InfoOverlay = overlays.InfoOverlay;
pub const SettingsEditorOverlay = overlays.SettingsEditorOverlay;
pub const SessionChoice = overlays.SessionChoice;
pub const SessionOverlay = overlays.SessionOverlay;
pub const ModelChoice = overlays.ModelChoice;
pub const ModelOverlay = overlays.ModelOverlay;
pub const TreeChoice = overlays.TreeChoice;
pub const TreeOverlay = overlays.TreeOverlay;
pub const AuthOverlayMode = overlays.AuthOverlayMode;
pub const AuthChoice = overlays.AuthChoice;
pub const AuthOverlay = overlays.AuthOverlay;
pub const AuthFlow = overlays.AuthFlow;
pub const PendingBrowserRedirect = overlays.PendingBrowserRedirect;
pub const PendingGoogleProject = overlays.PendingGoogleProject;
pub const PendingApiKeyEntry = overlays.PendingApiKeyEntry;
pub const isApiKeyLoginProvider = auth.isApiKeyLoginProvider;
pub const getApiKeyProviderDisplayName = auth.getApiKeyProviderDisplayName;
pub const loadAuthOverlay = overlays.loadAuthOverlay;
pub const loadSettingsEditorOverlay = overlays.loadSettingsEditorOverlay;
pub const loadHotkeysOverlay = overlays.loadHotkeysOverlay;
pub const loadInfoOverlay = overlays.loadInfoOverlay;
pub const appendInfoOverlayItem = overlays.appendInfoOverlayItem;
pub const appendHotkeyOverlayItem = overlays.appendHotkeyOverlayItem;
pub const loadSessionOverlay = overlays.loadSessionOverlay;
pub const loadModelOverlay = overlays.loadModelOverlay;
pub const loadScopedModelOverlay = overlays.loadScopedModelOverlay;
pub const loadSelectableModels = overlays.loadSelectableModels;
pub const modelSupportsInput = overlays.modelSupportsInput;
pub const loadTreeOverlay = overlays.loadTreeOverlay;
pub const appendTreeNodes = overlays.appendTreeNodes;
pub const indentationPrefix = overlays.indentationPrefix;
pub const summarizeSessionEntry = overlays.summarizeSessionEntry;
pub const trimSummaryText = overlays.trimSummaryText;
pub const SessionOverlayEntries = overlays.SessionOverlayEntries;
pub const listSessions = overlays.listSessions;
pub const loadSessionDisplayName = overlays.loadSessionDisplayName;
pub const ChatKind = rendering.ChatKind;
pub const ChatItem = rendering.ChatItem;
pub const FooterUsageTotals = rendering.FooterUsageTotals;
pub const AppState = rendering.AppState;
pub const ScreenComponent = rendering.ScreenComponent;
pub const BorrowedLinesComponent = rendering.BorrowedLinesComponent;
pub const OverlayPanelComponent = rendering.OverlayPanelComponent;
pub const overlayPanelMaxHeight = rendering.overlayPanelMaxHeight;
pub const overlayPanelWidth = rendering.overlayPanelWidth;
pub const overlayAnimationProgress = rendering.overlayAnimationProgress;
pub const nowMilliseconds = rendering.nowMilliseconds;
pub const overlayPanelOptions = rendering.overlayPanelOptions;
pub const rebuildAppStateFromSession = rendering.rebuildAppStateFromSession;
pub const updateAppFooterFromSession = rendering.updateAppFooterFromSession;
pub const assistantContextTokens = rendering.assistantContextTokens;
pub const resolveGitBranch = rendering.resolveGitBranch;
pub const findGitRoot = rendering.findGitRoot;
pub const resolveGitDirectory = rendering.resolveGitDirectory;
pub const parseGitHeadBranch = rendering.parseGitHeadBranch;
pub const parseEnvSize = rendering.parseEnvSize;
pub const freeLinesSafe = rendering.freeLinesSafe;
pub const INPUT_PROMPT_PREFIX = rendering.INPUT_PROMPT_PREFIX;
pub const renderPromptLines = rendering.renderPromptLines;
pub const formatFooterLine = rendering.formatFooterLine;
pub const appendFooterPart = rendering.appendFooterPart;
pub const formatCompactTokenCount = rendering.formatCompactTokenCount;
pub const formatHintsLine = rendering.formatHintsLine;
pub const actionLabel = rendering.actionLabel;
pub const themeChatItem = rendering.themeChatItem;
pub const renderChatItemInto = rendering.renderChatItemInto;
pub const renderAssistantChatItemInto = rendering.renderAssistantChatItemInto;
pub const applyThemeAlloc = rendering.applyThemeAlloc;
pub const fitLine = rendering.fitLine;
pub const handleAppAgentEvent = rendering.handleAppAgentEvent;
pub const InteractiveModeTestBackend = rendering.InteractiveModeTestBackend;
pub const renderScreenWithMockBackend = rendering.renderScreenWithMockBackend;
pub const renderScreenWithMockBackendAndOverlay = rendering.renderScreenWithMockBackendAndOverlay;
pub const renderedLinesContain = rendering.renderedLinesContain;
pub const PromptWorker = prompt_worker_mod.PromptWorker;
pub const cloneImageContents = prompt_worker_mod.cloneImageContents;
pub const deinitImageContents = prompt_worker_mod.deinitImageContents;
pub const BuiltTools = tool_adapters.BuiltTools;
pub const buildAgentTools = tool_adapters.buildAgentTools;
pub const InteractiveBootstrap = session_bootstrap.InteractiveBootstrap;
pub const bootstrapInteractiveState = session_bootstrap.bootstrapInteractiveState;
pub const openInitialSession = session_bootstrap.openInitialSession;
pub const SlashCommandKind = slash_commands.SlashCommandKind;
pub const SlashCommand = slash_commands.SlashCommand;
pub const BuiltinSlashCommand = slash_commands.BuiltinSlashCommand;
pub const BUILTIN_SLASH_COMMANDS = slash_commands.BUILTIN_SLASH_COMMANDS;
pub const createSeededSession = slash_commands.createSeededSession;
pub const parseSlashCommand = slash_commands.parseSlashCommand;
pub const handleSlashCommand = slash_commands.handleSlashCommand;
pub const switchSession = slash_commands.switchSession;
pub const switchModel = slash_commands.switchModel;
pub const handleModelSlashCommand = slash_commands.handleModelSlashCommand;
pub const handleScopedModelsSlashCommand = slash_commands.handleScopedModelsSlashCommand;
pub const handleSessionSlashCommand = slash_commands.handleSessionSlashCommand;
pub const ChangelogView = slash_commands.ChangelogView;
pub const handleChangelogSlashCommand = slash_commands.handleChangelogSlashCommand;
pub const parseChangelogView = slash_commands.parseChangelogView;
pub const buildChangelogMarkdown = slash_commands.buildChangelogMarkdown;
pub const resolveChangelogPath = slash_commands.resolveChangelogPath;
pub const extractLatestVersionSection = slash_commands.extractLatestVersionSection;
pub const handleNameSlashCommand = slash_commands.handleNameSlashCommand;
pub const handleLabelSlashCommand = slash_commands.handleLabelSlashCommand;
pub const resolveCurrentLabelTargetId = slash_commands.resolveCurrentLabelTargetId;
pub const handleCompactSlashCommand = slash_commands.handleCompactSlashCommand;
pub const handleLoginSlashCommand = slash_commands.handleLoginSlashCommand;
pub const beginLoginFlow = slash_commands.beginLoginFlow;
pub const cancelAuthFlow = slash_commands.cancelAuthFlow;
pub const submitAuthFlowInput = slash_commands.submitAuthFlowInput;
pub const persistLoginCredential = slash_commands.persistLoginCredential;
pub const OpenBrowserFn = slash_commands.OpenBrowserFn;
pub const openBrowserBestEffort = slash_commands.openBrowserBestEffort;
pub const defaultOpenBrowserBestEffort = slash_commands.defaultOpenBrowserBestEffort;
pub const ClipboardCopyFn = slash_commands.ClipboardCopyFn;
pub const BrowserOpenCapture = slash_commands.BrowserOpenCapture;
pub const handleSettingsSlashCommand = slash_commands.handleSettingsSlashCommand;
pub const handleImportSlashCommand = slash_commands.handleImportSlashCommand;
pub const handleCopySlashCommand = slash_commands.handleCopySlashCommand;
pub const handleShareSlashCommand = slash_commands.handleShareSlashCommand;
pub const handleLogoutSlashCommand = slash_commands.handleLogoutSlashCommand;
pub const logoutProviderById = slash_commands.logoutProviderById;
pub const handleNewSlashCommand = slash_commands.handleNewSlashCommand;
pub const clearResolvedProviderApiKey = slash_commands.clearResolvedProviderApiKey;
pub const copyTextToClipboard = slash_commands.copyTextToClipboard;
pub const defaultCopyTextToClipboard = slash_commands.defaultCopyTextToClipboard;
pub const runClipboardCommand = slash_commands.runClipboardCommand;
pub const exitCodeFromChildTerm = slash_commands.exitCodeFromChildTerm;
pub const lastAssistantTextAlloc = slash_commands.lastAssistantTextAlloc;
pub const assistantBlocksToTextAlloc = slash_commands.assistantBlocksToTextAlloc;
pub const buildShareText = slash_commands.buildShareText;
pub const messageToShareMarkdown = slash_commands.messageToShareMarkdown;
pub const blocksToShareText = slash_commands.blocksToShareText;
pub const removeStoredAuthToken = slash_commands.removeStoredAuthToken;
pub const handleReloadSlashCommand = slash_commands.handleReloadSlashCommand;
pub const configurePrimaryEditor = slash_commands.configurePrimaryEditor;
pub const appendResourceDiagnostics = slash_commands.appendResourceDiagnostics;
pub const saveSettingsEditorOverlay = slash_commands.saveSettingsEditorOverlay;
pub const handleExportSlashCommand = slash_commands.handleExportSlashCommand;
pub const formatSessionInfo = slash_commands.formatSessionInfo;
pub const cloneCurrentSession = slash_commands.cloneCurrentSession;
pub const forkCurrentSession = slash_commands.forkCurrentSession;
pub const createDerivedSession = slash_commands.createDerivedSession;
pub const replaceCurrentSession = slash_commands.replaceCurrentSession;
pub const navigateTree = slash_commands.navigateTree;
pub const findLastUserMessageIndex = slash_commands.findLastUserMessageIndex;
pub const resolveSessionPath = slash_commands.resolveSessionPath;
pub const handleInputKey = input_dispatch.handleInputKey;
pub const submitEditorText = input_dispatch.submitEditorText;
pub const clearEditor = input_dispatch.clearEditor;
pub const loadEditorAutocompleteItems = input_dispatch.loadEditorAutocompleteItems;
pub const freeOwnedSelectItems = input_dispatch.freeOwnedSelectItems;
pub const pollForInput = input_dispatch.pollForInput;
pub const dispatchInputEvent = input_dispatch.dispatchInputEvent;
pub const consumeInputBytes = input_dispatch.consumeInputBytes;
pub const resolveAppAction = input_dispatch.resolveAppAction;
pub const legacyAppActionForKey = input_dispatch.legacyAppActionForKey;
pub const isLegacyAppActionKey = input_dispatch.isLegacyAppActionKey;
pub const handleAppAction = input_dispatch.handleAppAction;

pub fn runInteractiveMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    options: RunInteractiveModeOptions,
    stderr_writer: *std.Io.Writer,
) !u8 {
    var live_resources = LiveResources.init(options);
    defer live_resources.deinit(allocator);

    var app_context = AppContext.init(options.cwd, io);

    var bootstrap = session_bootstrap.bootstrapInteractiveState(
        allocator,
        io,
        env_map,
        options,
        &app_context,
    ) catch |err| switch (err) {
        error.MissingApiKey,
        error.UnknownProvider,
        error.InvalidFauxStopReason,
        error.InvalidFauxTokensPerSecond,
        error.InvalidFauxContextWindow,
        error.InvalidFauxToolArguments,
        => {
            try stderr_writer.print("Error: {s}\n", .{provider_config.resolveProviderErrorMessage(err, options.provider)});
            try stderr_writer.flush();
            return 1;
        },
        else => return err,
    };
    defer bootstrap.deinit();

    var app_state = try AppState.init(allocator, io);
    defer app_state.deinit();
    app_state.setToolOutputExpanded(options.verbose);

    const subscriber = agent.AgentSubscriber{
        .context = &app_state,
        .callback = handleAppAgentEvent,
    };
    try bootstrap.session.agent.subscribe(subscriber);
    defer _ = bootstrap.session.agent.unsubscribe(subscriber);

    try rebuildAppStateFromSession(allocator, io, &app_state, &bootstrap.session, &bootstrap.current_provider);
    try appendVerboseStartupState(
        allocator,
        env_map,
        options,
        live_resources.keybindings,
        live_resources.runtime_config,
        &bootstrap.session,
        &bootstrap.current_provider,
        &app_state,
    );

    var terminal = tui.Terminal.initNative(.{
        .io = io,
        .env_map = env_map,
    });
    try terminal.start();
    defer terminal.stop();

    var input_loop = try terminal.initInputLoop(allocator, io, env_map);
    defer input_loop.deinit();
    input_loop.vaxis_state.queryTerminal(input_loop.loop.tty.writer(), .fromMilliseconds(250)) catch {};

    var renderer = tui.Renderer.init(allocator, &terminal);
    defer renderer.deinit();
    defer app_state.freeActiveTerminalImages(.{
        .vx = input_loop.vaxis_state,
        .tty = input_loop.loop.tty.writer(),
    });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    configurePrimaryEditor(&editor, live_resources.runtime_config);
    const autocomplete_items = try loadEditorAutocompleteItems(allocator, io, options.cwd);
    defer freeOwnedSelectItems(allocator, autocomplete_items);
    try editor.setAutocompleteItems(autocomplete_items);

    var screen = ScreenComponent{
        .state = &app_state,
        .editor = &editor,
        .keybindings = live_resources.keybindings,
        .theme = live_resources.theme,
    };

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var overlay_panel: ?OverlayPanelComponent = null;
    var overlay_handle_id: ?usize = null;
    var overlay_opened_at_ms: ?i64 = null;
    var last_overlay_tag: ?std.meta.Tag(SelectorOverlay) = null;

    var auth_flow: ?AuthFlow = null;
    defer if (auth_flow) |*value| value.deinit(allocator);

    var prompt_worker: PromptWorker = undefined;
    var prompt_worker_active = false;
    defer if (prompt_worker_active) {
        bootstrap.session.agent.abort();
        prompt_worker.join(allocator);
    };

    if (options.initial_prompt) |initial_prompt| {
        if (initial_prompt.len > 0) {
            try prompt_worker.start(allocator, &bootstrap.session, &app_state, initial_prompt, options.initial_images);
            prompt_worker_active = true;
        }
    }

    var should_exit = false;
    var input_buffer = std.ArrayList(u8).empty;
    defer input_buffer.deinit(allocator);

    while (true) {
        if (prompt_worker_active and !prompt_worker.running.load(.seq_cst)) {
            prompt_worker.join(allocator);
            prompt_worker_active = false;
            if (should_exit) break;
        }

        try app_state.pollClipboardPaste(.{
            .vx = input_loop.vaxis_state,
            .tty = input_loop.loop.tty.writer(),
        });
        app_state.flushRetiredTerminalImages(.{
            .vx = input_loop.vaxis_state,
            .tty = input_loop.loop.tty.writer(),
        });

        const size = try terminal.refreshSize();
        screen.height = size.height;
        screen.overlay = if (overlay) |*value| value else null;
        screen.keybindings = live_resources.keybindings;
        screen.theme = live_resources.theme;

        if (overlay) |*overlay_value| {
            const overlay_tag = std.meta.activeTag(overlay_value.*);
            const now_ms = nowMilliseconds();
            if (last_overlay_tag == null or last_overlay_tag.? != overlay_tag) {
                overlay_opened_at_ms = now_ms;
            }
            last_overlay_tag = overlay_tag;

            const progress = overlayAnimationProgress(now_ms, overlay_opened_at_ms);
            overlay_panel = .{
                .overlay = overlay_value,
                .theme = live_resources.theme,
                .max_height = overlayPanelMaxHeight(size.height),
            };

            const overlay_options = overlayPanelOptions(size, progress);
            if (overlay_handle_id) |existing_id| {
                _ = renderer.updateDrawOverlay(existing_id, overlay_panel.?.drawComponent(), overlay_options);
            } else {
                overlay_handle_id = try renderer.showDrawOverlay(overlay_panel.?.drawComponent(), overlay_options);
            }
        } else {
            last_overlay_tag = null;
            overlay_opened_at_ms = null;
            overlay_panel = null;
            if (overlay_handle_id) |existing_id| {
                _ = renderer.removeOverlay(existing_id);
                overlay_handle_id = null;
            }
        }

        try renderer.renderToVaxis(screen.drawComponent(), input_loop.vaxis_state, input_loop.loop.tty.writer());

        if (should_exit and !prompt_worker_active) break;

        var handled_input = false;
        while (try input_loop.tryInputEvent()) |event| {
            defer event.deinit(allocator);
            handled_input = true;
            try dispatchInputEvent(
                allocator,
                io,
                env_map,
                event.parsed,
                &bootstrap.session,
                &bootstrap.current_provider,
                options.session_dir,
                options,
                bootstrap.built_tools.items,
                &app_state,
                &editor,
                &overlay,
                &auth_flow,
                &prompt_worker,
                &prompt_worker_active,
                subscriber,
                &should_exit,
                &input_buffer,
                &app_context,
                &live_resources,
            );
        }
        if (!handled_input) {
            std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
        }
    }

    return 0;
}

fn appendVerboseStartupState(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    options: RunInteractiveModeOptions,
    keybindings: ?*const keybindings_mod.Keybindings,
    runtime_config: ?*const config_mod.RuntimeConfig,
    session: *const session_mod.AgentSession,
    current_provider: *const provider_config.ResolvedProviderConfig,
    app_state: *AppState,
) !void {
    if (!options.verbose) return;

    const banner = try buildVerboseStartupBanner(allocator, keybindings);
    defer allocator.free(banner);
    try app_state.appendInfo(banner);

    const scoped_listing = try buildVerboseScopedModelsListing(
        allocator,
        env_map,
        session.agent.getModel(),
        current_provider,
        options.model_patterns,
        runtime_config,
    );
    defer if (scoped_listing) |text| allocator.free(text);
    if (scoped_listing) |text| {
        try app_state.appendInfo(text);
    }
}

fn buildVerboseStartupBanner(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
) ![]u8 {
    const interrupt = try actionLabel(allocator, keybindings, .interrupt, "Ctrl+C");
    defer allocator.free(interrupt);
    const clear = try actionLabel(allocator, keybindings, .clear, "Ctrl+L");
    defer allocator.free(clear);
    const exit = try actionLabel(allocator, keybindings, .exit, "Ctrl+D");
    defer allocator.free(exit);
    const open_models = try actionLabel(allocator, keybindings, .open_models, "Ctrl+P");
    defer allocator.free(open_models);
    const open_sessions = try actionLabel(allocator, keybindings, .open_sessions, "Ctrl+S");
    defer allocator.free(open_sessions);
    const paste_image = try actionLabel(allocator, keybindings, .paste_image, "Ctrl+V");
    defer allocator.free(paste_image);

    return std.fmt.allocPrint(
        allocator,
        "Pi interactive mode (verbose startup)\n{s} interrupt • {s} clear • {s} exit • {s} models • {s} sessions • {s} paste image • / commands • ! bash",
        .{ interrupt, clear, exit, open_models, open_sessions, paste_image },
    );
}

fn buildVerboseScopedModelsListing(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ai.Model,
    current_provider: *const provider_config.ResolvedProviderConfig,
    model_patterns: ?[]const []const u8,
    runtime_config: ?*const config_mod.RuntimeConfig,
) !?[]u8 {
    _ = model_patterns orelse return null;

    const scoped_models = try loadSelectableModels(
        allocator,
        env_map,
        current_model,
        current_provider,
        model_patterns,
        runtime_config,
    );
    defer allocator.free(scoped_models);
    if (scoped_models.len == 0) return null;

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    try builder.appendSlice(allocator, "Scoped models (Ctrl+P / /scoped-models): ");
    for (scoped_models, 0..) |entry, index| {
        if (index != 0) try builder.appendSlice(allocator, ", ");
        const label = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.provider, entry.model_id });
        defer allocator.free(label);
        try builder.appendSlice(allocator, label);
    }

    return try builder.toOwnedSlice(allocator);
}

test "screen renders welcome prompt footer and tool lines" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");
    try state.setStatus("streaming");
    var args_map = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args_map.put(allocator, try allocator.dupe(u8, "path"), .{ .string = try allocator.dupe(u8, "README.md") });
    const args_object = std.json.Value{ .object = args_map };
    defer common.deinitJsonValue(allocator, args_object);
    try state.handleAgentEvent(.{
        .event_type = .message_end,
        .message = .{ .user = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "hello" } }},
            .timestamp = 1,
        } },
    });
    try state.handleAgentEvent(.{
        .event_type = .tool_execution_start,
        .tool_name = "read",
        .args = args_object,
    });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handleKey(.{ .printable = tui.keys.PrintableKey.fromSlice("w") });

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
    };

    var lines = tui.LineList.empty;
    defer freeLinesSafe(allocator, &lines);
    try screen.renderInto(allocator, 40, &lines);

    try std.testing.expect(lines.items.len >= 3);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "Welcome to pi") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[lines.items.len - 3], "Input: w") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[lines.items.len - 2], "Session: session.jsonl") != null);
}

test "interactive mode startup renders welcome message footer and hints through a mock backend" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 8 } };
    defer backend.deinit(allocator);

    var lines = try renderScreenWithMockBackend(allocator, &screen, &backend);
    defer freeLinesSafe(allocator, &lines);

    try std.testing.expect(backend.entered_raw);
    try std.testing.expect(backend.restored);
    try std.testing.expectEqualStrings(
        tui.Terminal.ALT_SCREEN_ENABLE ++ tui.Terminal.BRACKETED_PASTE_ENABLE ++ tui.Terminal.HIDE_CURSOR ++ tui.Terminal.AUTO_WRAP_DISABLE ++ tui.Terminal.KITTY_KEYBOARD_QUERY ++ tui.Terminal.KITTY_KEYBOARD_ENABLE,
        backend.writes.items[0],
    );
    try std.testing.expectEqualStrings(
        tui.Terminal.AUTO_WRAP_ENABLE ++ tui.Terminal.ALT_SCREEN_DISABLE ++ tui.Terminal.BRACKETED_PASTE_DISABLE ++ tui.Terminal.KITTY_KEYBOARD_DISABLE ++ tui.Terminal.SHOW_CURSOR,
        backend.writes.items[backend.writes.items.len - 1],
    );
    try std.testing.expect(renderedLinesContain(lines.items, "Welcome to pi (Zig interactive mode)."));
    try std.testing.expect(renderedLinesContain(lines.items, "Input: "));
    try std.testing.expect(renderedLinesContain(lines.items, "Session: session.jsonl"));
    try std.testing.expect(renderedLinesContain(lines.items, "Status: idle"));
    try std.testing.expect(renderedLinesContain(lines.items, "Model: faux-1"));
    try std.testing.expect(renderedLinesContain(lines.items, "Ctrl+V paste image"));
}

test "appendVerboseStartupState adds startup banner and scoped model listing" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-key");

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();

    try appendVerboseStartupState(
        allocator,
        &env_map,
        .{
            .cwd = "/tmp",
            .system_prompt = "sys",
            .session_dir = "/tmp/sessions",
            .provider = "faux",
            .verbose = true,
            .model_patterns = &.{"anthropic/sonnet:high"},
        },
        &keybindings,
        null,
        &session,
        &current_provider,
        &state,
    );

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);

    var saw_banner = false;
    var saw_scope = false;
    for (snapshot.items) |item| {
        if (std.mem.indexOf(u8, item.text, "Pi interactive mode (verbose startup)") != null) saw_banner = true;
        if (std.mem.indexOf(u8, item.text, "Scoped models (Ctrl+P / /scoped-models):") != null and
            std.mem.indexOf(u8, item.text, "anthropic/") != null) saw_scope = true;
    }

    try std.testing.expect(saw_banner);
    try std.testing.expect(saw_scope);
}

test "tool output details stay collapsed until verbose expansion is enabled" {
    const allocator = std.testing.allocator;

    const detail_value = try std.json.parseFromSlice(std.json.Value, allocator, "{\"exit_code\":0,\"timed_out\":false}", .{});
    defer detail_value.deinit();

    var collapsed_state = try AppState.init(allocator, std.testing.io);
    defer collapsed_state.deinit();
    try collapsed_state.handleAgentEvent(.{
        .event_type = .tool_execution_end,
        .tool_name = "bash",
        .result = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "hello from bash" } }},
            .details = detail_value.value,
        },
        .is_error = false,
    });

    var collapsed_snapshot = try collapsed_state.snapshotForRender(allocator);
    defer collapsed_snapshot.deinit(allocator);

    var saw_collapsed_body = false;
    var saw_collapsed_details = false;
    for (collapsed_snapshot.items) |item| {
        if (std.mem.indexOf(u8, item.text, "hello from bash") != null) saw_collapsed_body = true;
        if (std.mem.indexOf(u8, item.text, "Details:") != null) saw_collapsed_details = true;
    }
    try std.testing.expect(saw_collapsed_body);
    try std.testing.expect(!saw_collapsed_details);

    var expanded_state = try AppState.init(allocator, std.testing.io);
    defer expanded_state.deinit();
    expanded_state.setToolOutputExpanded(true);
    try expanded_state.handleAgentEvent(.{
        .event_type = .tool_execution_end,
        .tool_name = "bash",
        .result = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "hello from bash" } }},
            .details = detail_value.value,
        },
        .is_error = false,
    });

    var expanded_snapshot = try expanded_state.snapshotForRender(allocator);
    defer expanded_snapshot.deinit(allocator);

    var saw_expanded_details = false;
    for (expanded_snapshot.items) |item| {
        if (std.mem.indexOf(u8, item.text, "Details:") != null and
            std.mem.indexOf(u8, item.text, "\"exit_code\":0") != null) saw_expanded_details = true;
    }
    try std.testing.expect(saw_expanded_details);
}

test "interactive mode renders pending clipboard image placeholders in the prompt area" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");
    try state.appendPendingEditorImage(.{
        .data = try allocator.dupe(u8, "AQID"),
        .mime_type = try allocator.dupe(u8, "image/png"),
    });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 8 } };
    defer backend.deinit(allocator);

    var lines = try renderScreenWithMockBackend(allocator, &screen, &backend);
    defer freeLinesSafe(allocator, &lines);

    try std.testing.expect(renderedLinesContain(lines.items, "Input: "));
    try std.testing.expect(renderedLinesContain(lines.items, "[image 1: image/png]"));
}

test "interactive mode renders submitted user messages through a mock backend" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");
    try state.handleAgentEvent(.{
        .event_type = .message_end,
        .message = .{ .user = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "hello from interactive mode" } }},
            .timestamp = 1,
        } },
    });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 8 } };
    defer backend.deinit(allocator);

    var lines = try renderScreenWithMockBackend(allocator, &screen, &backend);
    defer freeLinesSafe(allocator, &lines);

    try std.testing.expect(renderedLinesContain(lines.items, "You: hello from interactive mode"));
}

test "interactive mode renders streaming assistant updates through a mock backend" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");

    try state.handleAgentEvent(.{
        .event_type = .agent_start,
    });
    try state.handleAgentEvent(.{
        .event_type = .message_start,
        .message = .{ .assistant = .{
            .content = &[_]ai.ContentBlock{},
            .tool_calls = null,
            .api = "faux",
            .provider = "faux",
            .model = "faux-1",
            .usage = ai.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        } },
    });
    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .message = .{ .assistant = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "streaming reply" } }},
            .tool_calls = null,
            .api = "faux",
            .provider = "faux",
            .model = "faux-1",
            .usage = ai.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        } },
    });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 8 } };
    defer backend.deinit(allocator);

    var lines = try renderScreenWithMockBackend(allocator, &screen, &backend);
    defer freeLinesSafe(allocator, &lines);

    try std.testing.expect(renderedLinesContain(lines.items, ASSISTANT_PREFIX));
    try std.testing.expect(renderedLinesContain(lines.items, "streaming reply"));
    try std.testing.expectEqualStrings("streaming", state.status);
}

test "interactive mode renders thinking placeholder before assistant text" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");

    try state.handleAgentEvent(.{ .event_type = .agent_start });
    try state.handleAgentEvent(.{
        .event_type = .message_end,
        .message = .{ .user = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "hello" } }},
            .timestamp = 1,
        } },
    });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 8 } };
    defer backend.deinit(allocator);

    var lines = try renderScreenWithMockBackend(allocator, &screen, &backend);
    defer freeLinesSafe(allocator, &lines);

    try std.testing.expect(renderedLinesContain(lines.items, "You: hello"));
    try std.testing.expect(renderedLinesContain(lines.items, ASSISTANT_PREFIX));
    try std.testing.expect(renderedLinesContain(lines.items, "Thinking..."));
    try std.testing.expectEqualStrings("thinking", state.status);
}

test "interactive mode renders tool execution details through a mock backend" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");

    var args_map = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try args_map.put(allocator, try allocator.dupe(u8, "path"), .{ .string = try allocator.dupe(u8, "README.md") });
    const args_object = std.json.Value{ .object = args_map };
    defer common.deinitJsonValue(allocator, args_object);

    try state.handleAgentEvent(.{
        .event_type = .tool_execution_start,
        .tool_name = "read",
        .args = args_object,
    });
    try state.handleAgentEvent(.{
        .event_type = .tool_execution_end,
        .tool_name = "read",
        .result = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "project notes" } }},
        },
        .is_error = false,
    });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 8 } };
    defer backend.deinit(allocator);

    var lines = try renderScreenWithMockBackend(allocator, &screen, &backend);
    defer freeLinesSafe(allocator, &lines);

    try std.testing.expect(renderedLinesContain(lines.items, "Read README.md"));
    try std.testing.expect(renderedLinesContain(lines.items, "Read result read:"));
    try std.testing.expect(renderedLinesContain(lines.items, "project notes"));
}

test "screen renders multi-line prompt with wrapped continuation lines" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("你好🙂abc\ndef");

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
    };

    var lines = tui.LineList.empty;
    defer freeLinesSafe(allocator, &lines);
    try screen.renderInto(allocator, 12, &lines);

    try std.testing.expect(lines.items.len >= 5);
    var saw_input = false;
    var saw_continuation = false;
    for (lines.items) |line| {
        if (std.mem.indexOf(u8, line, "Input: ") != null) saw_input = true;
        if (std.mem.startsWith(u8, line, "       ") and std.mem.indexOf(u8, line, "def") != null) {
            saw_continuation = true;
        }
    }
    try std.testing.expect(saw_input);
    try std.testing.expect(saw_continuation);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[lines.items.len - 2], "Session:") != null);
}

test "screen renders themed output and custom keybinding hints" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");

    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();
    try keybindings.setBinding(.open_sessions, &.{.{ .ctrl = 'x' }});

    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);
    if (theme.styles[@intFromEnum(resources_mod.ThemeToken.welcome)].fg) |value| allocator.free(value);
    theme.styles[@intFromEnum(resources_mod.ThemeToken.welcome)].fg = try allocator.dupe(u8, "green");
    if (theme.styles[@intFromEnum(resources_mod.ThemeToken.footer)].fg) |value| allocator.free(value);
    theme.styles[@intFromEnum(resources_mod.ThemeToken.footer)].fg = try allocator.dupe(u8, "cyan");
    if (theme.styles[@intFromEnum(resources_mod.ThemeToken.status)].fg) |value| allocator.free(value);
    theme.styles[@intFromEnum(resources_mod.ThemeToken.status)].fg = try allocator.dupe(u8, "yellow");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 6,
        .keybindings = &keybindings,
        .theme = &theme,
    };

    var lines = tui.LineList.empty;
    defer freeLinesSafe(allocator, &lines);
    try screen.renderInto(allocator, 80, &lines);

    var saw_custom_hint = false;
    for (lines.items) |line| {
        if (std.mem.indexOf(u8, line, "Ctrl+X sessions") != null) saw_custom_hint = true;
    }

    try std.testing.expect(saw_custom_hint);
}

test "screen renders assistant markdown while keeping user messages plain" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");

    try state.handleAgentEvent(.{
        .event_type = .message_end,
        .message = .{ .user = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "literal **stars** [plain](https://example.com)" } }},
            .timestamp = 1,
        } },
    });
    try state.handleAgentEvent(.{
        .event_type = .message_end,
        .message = .{ .assistant = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text =
            \\**bold** [link](https://example.com)
            \\- list item
            \\```zig
            \\const value = 1;
            \\```
            } }},
            .tool_calls = null,
            .api = "faux",
            .provider = "faux",
            .model = "faux-1",
            .usage = ai.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 2,
        } },
    });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 20,
    };

    var lines = tui.LineList.empty;
    defer freeLinesSafe(allocator, &lines);
    try screen.renderInto(allocator, 80, &lines);

    var saw_prefix = false;
    var saw_user_literal = false;
    var saw_bold = false;
    var saw_link = false;
    var saw_list = false;
    var saw_code = false;

    for (lines.items) |line| {
        if (std.mem.indexOf(u8, line, ASSISTANT_PREFIX) != null) saw_prefix = true;
        if (std.mem.indexOf(u8, line, "You: literal **stars** [plain](https://example.com)") != null) saw_user_literal = true;
        if (std.mem.indexOf(u8, line, "bold") != null) saw_bold = true;
        if (std.mem.indexOf(u8, line, "link") != null) saw_link = true;
        if (std.mem.indexOf(u8, line, "list item") != null) saw_list = true;
        if (std.mem.indexOf(u8, line, "const value = 1;") != null) saw_code = true;
    }

    try std.testing.expect(saw_prefix);
    try std.testing.expect(saw_user_literal);
    try std.testing.expect(saw_bold);
    try std.testing.expect(saw_link);
    try std.testing.expect(saw_list);
    try std.testing.expect(saw_code);
}

test "handleInputKey respects configured exit binding" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-key");

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();
    try keybindings.setBinding(.exit, &.{.{ .ctrl = 'q' }});

    var overlay: ?SelectorOverlay = null;
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const NoopSubscriber = struct {
        fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
    };

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = NoopSubscriber.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
        .keybindings = &keybindings,
    };
    var live_resources = LiveResources.init(options);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .{ .ctrl = 'q' },
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );
    try std.testing.expect(should_exit);

    should_exit = false;
    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .escape,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );
    try std.testing.expect(!should_exit);
}

test "handleInputKey dispatches interrupt exit and clear actions" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");
    try state.handleAgentEvent(.{
        .event_type = .message_end,
        .message = .{ .user = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "keep me?" } }},
            .timestamp = 1,
        } },
    });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var overlay: ?SelectorOverlay = null;
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = true;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .{ .ctrl = 'c' },
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    state.mutex.lockUncancelable(state.io);
    try std.testing.expectEqualStrings("interrupt requested", state.status);
    state.mutex.unlock(state.io);

    prompt_worker_active = false;
    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .{ .ctrl = 'l' },
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
    };
    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 8 } };
    defer backend.deinit(allocator);
    var lines = try renderScreenWithMockBackend(allocator, &screen, &backend);
    defer freeLinesSafe(allocator, &lines);

    try std.testing.expect(!renderedLinesContain(lines.items, "keep me?"));
    try std.testing.expect(renderedLinesContain(lines.items, "Input: "));
    try std.testing.expect(renderedLinesContain(lines.items, "Status: display cleared"));

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .{ .ctrl = 'd' },
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );
    try std.testing.expect(should_exit);
}

test "screen renders queued messages and the dequeue hint" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");
    try state.appendQueuedMessage(.steering, "queued steer");
    try state.appendQueuedMessage(.follow_up, "queued follow-up");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 12,
    };

    var lines = tui.LineList.empty;
    defer freeLinesSafe(allocator, &lines);
    try screen.renderInto(allocator, 80, &lines);

    try std.testing.expect(renderedLinesContain(lines.items, "Steering: queued steer"));
    try std.testing.expect(renderedLinesContain(lines.items, "Follow-up: queued follow-up"));
    try std.testing.expect(renderedLinesContain(lines.items, "Alt+Up to edit queued messages"));
    try std.testing.expect(renderedLinesContain(lines.items, "Queue: 1 steering, 1 follow-up"));
}

test "submitEditorText queues steering messages while streaming" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "ignored");

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();
    session.agent.beginRun();
    defer session.agent.finishRun();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("queued steer");

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = true;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try submitEditorText(
        allocator,
        std.testing.io,
        &env_map,
        editor.text(),
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expectEqual(@as(usize, 1), session.agent.steeringQueueLen());
    try std.testing.expectEqual(@as(usize, 0), session.agent.followUpQueueLen());
    try std.testing.expectEqualStrings("", editor.text());
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expectEqual(@as(usize, 1), state.queued_steering.items.len);
    try std.testing.expectEqualStrings("queued steering message", state.status);
}

test "dispatchInputEvent alt-enter queues follow-up and alt-up restores queued drafts" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "ignored");

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();
    session.agent.beginRun();
    defer session.agent.finishRun();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("queued follow-up");

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = true;
    var should_exit = false;
    var input_buffer = std.ArrayList(u8).empty;
    defer input_buffer.deinit(allocator);
    var app_context = AppContext.init("/tmp/project", std.testing.io);

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try dispatchInputEvent(
        allocator,
        std.testing.io,
        &env_map,
        .{
            .event = .{ .key = .enter },
            .consumed = 1,
            .modifiers = .{ .alt = true },
        },
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &input_buffer,
        &app_context,
        &live_resources,
    );

    try std.testing.expectEqual(@as(usize, 0), session.agent.steeringQueueLen());
    try std.testing.expectEqual(@as(usize, 1), session.agent.followUpQueueLen());
    try std.testing.expectEqualStrings("", editor.text());
    state.mutex.lockUncancelable(state.io);
    try std.testing.expectEqual(@as(usize, 1), state.queued_follow_up.items.len);
    state.mutex.unlock(state.io);

    const queued_image = ai.ImageContent{
        .data = try allocator.dupe(u8, "AQID"),
        .mime_type = try allocator.dupe(u8, "image/png"),
    };
    defer {
        allocator.free(queued_image.data);
        allocator.free(queued_image.mime_type);
    }
    try session.followUp("image follow-up", &.{queued_image});
    try state.appendQueuedMessage(.follow_up, "image follow-up");

    _ = try editor.handlePaste("current draft");

    try dispatchInputEvent(
        allocator,
        std.testing.io,
        &env_map,
        .{
            .event = .{ .key = .up },
            .consumed = 1,
            .modifiers = .{ .alt = true },
        },
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &input_buffer,
        &app_context,
        &live_resources,
    );

    try std.testing.expectEqual(@as(usize, 0), session.agent.followUpQueueLen());
    try std.testing.expectEqualStrings("queued follow-up\n\nimage follow-up\n\ncurrent draft", editor.text());
    const restored_images = try state.clonePendingEditorImages(allocator);
    defer deinitImageContents(allocator, restored_images);
    try std.testing.expectEqual(@as(usize, 1), restored_images.len);
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expectEqual(@as(usize, 0), state.queued_follow_up.items.len);
    try std.testing.expectEqualStrings("Restored 2 queued messages to the editor", state.status);
}

test "parseSlashCommand recognizes builtins and arguments" {
    const settings_command = parseSlashCommand("/settings").?;
    try std.testing.expectEqual(SlashCommandKind.settings, settings_command.kind);
    try std.testing.expect(settings_command.argument == null);

    const model_command = parseSlashCommand("/model faux").?;
    try std.testing.expectEqual(SlashCommandKind.model, model_command.kind);
    try std.testing.expectEqualStrings("faux", model_command.argument.?);

    const scoped_models_command = parseSlashCommand("/scoped-models").?;
    try std.testing.expectEqual(SlashCommandKind.scoped_models, scoped_models_command.kind);
    try std.testing.expect(scoped_models_command.argument == null);

    const import_command = parseSlashCommand("/import ./session.jsonl").?;
    try std.testing.expectEqual(SlashCommandKind.import, import_command.kind);
    try std.testing.expectEqualStrings("./session.jsonl", import_command.argument.?);

    const share_command = parseSlashCommand("/share").?;
    try std.testing.expectEqual(SlashCommandKind.share, share_command.kind);

    const copy_command = parseSlashCommand("/copy").?;
    try std.testing.expectEqual(SlashCommandKind.copy, copy_command.kind);

    const name_command = parseSlashCommand("/name Night Shift").?;
    try std.testing.expectEqual(SlashCommandKind.name, name_command.kind);
    try std.testing.expectEqualStrings("Night Shift", name_command.argument.?);

    const hotkeys_command = parseSlashCommand("/hotkeys").?;
    try std.testing.expectEqual(SlashCommandKind.hotkeys, hotkeys_command.kind);

    const label_command = parseSlashCommand("/label bookmark").?;
    try std.testing.expectEqual(SlashCommandKind.label, label_command.kind);
    try std.testing.expectEqualStrings("bookmark", label_command.argument.?);

    const logout_command = parseSlashCommand("/logout").?;
    try std.testing.expectEqual(SlashCommandKind.logout, logout_command.kind);

    const changelog_command = parseSlashCommand("/changelog condensed").?;
    try std.testing.expectEqual(SlashCommandKind.changelog, changelog_command.kind);
    try std.testing.expectEqualStrings("condensed", changelog_command.argument.?);

    const new_command = parseSlashCommand("/new").?;
    try std.testing.expectEqual(SlashCommandKind.new, new_command.kind);

    const export_command = parseSlashCommand("/export \"/tmp/out.md\"").?;
    try std.testing.expectEqual(SlashCommandKind.@"export", export_command.kind);
    try std.testing.expectEqualStrings("\"/tmp/out.md\"", export_command.argument.?);

    try std.testing.expect(parseSlashCommand("hello") == null);
    try std.testing.expect(parseSlashCommand("/unknown") == null);
}

test "handleLoginSlashCommand opens auth provider selector" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);

    slash_commands.test_auth_flow = null;
    try handleLoginSlashCommand(allocator, std.testing.io, &env_map, null, &state, &overlay, &slash_commands.test_auth_flow);

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .auth);
    try std.testing.expectEqual(AuthOverlayMode.login, overlay.?.auth.mode);
    try std.testing.expect(overlay.?.auth.items.len > 3);
    try std.testing.expectEqualStrings("anthropic", overlay.?.auth.items[0].value);

    var saw_openai = false;
    for (overlay.?.auth.items) |item| {
        if (std.mem.eql(u8, item.value, "openai")) {
            saw_openai = true;
            try std.testing.expectEqualStrings("OpenAI", item.label);
            try std.testing.expectEqualStrings("API key login", item.description.?);
        }
    }
    try std.testing.expect(saw_openai);
}

test "beginLoginFlow starts anthropic oauth prompt state" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);
    const oauth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "oauth.json" });
    defer allocator.free(oauth_path);
    try common.writeFileAbsolute(
        std.testing.io,
        oauth_path,
        \\{
        \\  "anthropic": {
        \\    "client_id": "anthropic-client-id"
        \\  }
        \\}
    ,
        true,
    );

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    slash_commands.test_auth_flow = null;
    defer if (slash_commands.test_auth_flow) |*value| {
        value.deinit(allocator);
        slash_commands.test_auth_flow = null;
    };
    var browser_open_capture = BrowserOpenCapture{};
    const previous_browser_open_context = slash_commands.open_browser_context;
    const previous_browser_open_fn = slash_commands.open_browser_fn;
    slash_commands.open_browser_context = &browser_open_capture;
    slash_commands.open_browser_fn = BrowserOpenCapture.capture;
    defer {
        slash_commands.open_browser_context = previous_browser_open_context;
        slash_commands.open_browser_fn = previous_browser_open_fn;
    }

    try beginLoginFlow(allocator, std.testing.io, &env_map, "anthropic", null, &state, &slash_commands.test_auth_flow);

    try std.testing.expect(slash_commands.test_auth_flow != null);
    try std.testing.expect(slash_commands.test_auth_flow.? == .browser_redirect);
    try std.testing.expectEqual(auth.BrowserLoginKind.anthropic, slash_commands.test_auth_flow.?.browser_redirect.session.kind);
    try std.testing.expect(browser_open_capture.called);

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "You will be prompted") == null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "Anthropic (Claude Pro/Max) login started") != null);
}

test "beginLoginFlow shows oauth.json guidance when oauth client config is missing" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    slash_commands.test_auth_flow = null;
    defer if (slash_commands.test_auth_flow) |*value| {
        value.deinit(allocator);
        slash_commands.test_auth_flow = null;
    };

    try beginLoginFlow(allocator, std.testing.io, &env_map, "anthropic", null, &state, &slash_commands.test_auth_flow);

    try std.testing.expect(slash_commands.test_auth_flow == null);

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "oauth.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "\"anthropic\"") != null);
}

test "beginLoginFlow starts API key prompt state for built-in provider" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    slash_commands.test_auth_flow = null;
    defer if (slash_commands.test_auth_flow) |*value| {
        value.deinit(allocator);
        slash_commands.test_auth_flow = null;
    };

    try beginLoginFlow(allocator, std.testing.io, &env_map, "openai", null, &state, &slash_commands.test_auth_flow);

    try std.testing.expect(slash_commands.test_auth_flow != null);
    try std.testing.expect(slash_commands.test_auth_flow.? == .api_key);
    try std.testing.expectEqualStrings("openai", slash_commands.test_auth_flow.?.api_key.provider_id);

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "OpenAI API key login started") != null);
}

test "persistLoginCredential writes auth.json for slash login flows" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "");
    defer allocator.free(root_dir);
    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);
    const session_dir = try makeInteractiveTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime_config = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, root_dir);
    defer runtime_config.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
        .runtime_config = &runtime_config,
    };
    var live_resources = LiveResources.init(options);
    defer live_resources.deinit(allocator);

    var credential = auth.StoredCredential{ .oauth = .{
        .access = try allocator.dupe(u8, "oauth-access-token"),
        .refresh = try allocator.dupe(u8, "oauth-refresh-token"),
        .expires = 1234,
    } };
    defer credential.deinit(allocator);

    var auth_flow: ?AuthFlow = null;
    try persistLoginCredential(
        allocator,
        std.testing.io,
        &env_map,
        &session,
        &current_provider,
        "anthropic",
        "Anthropic (Claude Pro/Max)",
        &credential,
        options,
        &state,
        &auth_flow,
        &live_resources,
    );

    const saved = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, auth_path, allocator, .limited(1024 * 1024));
    defer allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"anthropic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"oauth-access-token\"") != null);
    try std.testing.expectEqualStrings("oauth-access-token", live_resources.runtime_config.?.lookupApiKey("anthropic").?);
}

test "submitAuthFlowInput stores API key credentials for built-in providers" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "");
    defer allocator.free(root_dir);
    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);
    const session_dir = try makeInteractiveTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime_config = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, root_dir);
    defer runtime_config.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
        .runtime_config = &runtime_config,
    };
    var live_resources = LiveResources.init(options);
    defer live_resources.deinit(allocator);

    var auth_flow: ?AuthFlow = .{ .api_key = .{
        .provider_id = "openai",
        .provider_name = "OpenAI",
    } };
    defer if (auth_flow) |*value| value.deinit(allocator);

    try submitAuthFlowInput(
        allocator,
        std.testing.io,
        &env_map,
        "openai-api-key",
        &session,
        &current_provider,
        options,
        &state,
        &editor,
        &auth_flow,
        &live_resources,
    );

    const saved = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, auth_path, allocator, .limited(1024 * 1024));
    defer allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"type\": \"api_key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"key\": \"openai-api-key\"") != null);
    try std.testing.expect(auth_flow == null);
    try std.testing.expectEqualStrings("openai-api-key", live_resources.runtime_config.?.lookupApiKey("openai").?);
}

test "loadEditorAutocompleteItems includes slash command help text" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "");
    defer allocator.free(root_dir);

    const items = try loadEditorAutocompleteItems(allocator, std.testing.io, root_dir);
    defer freeOwnedSelectItems(allocator, items);

    var saw_settings = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "/settings")) {
            saw_settings = true;
            try std.testing.expectEqualStrings("/settings", item.value);
            try std.testing.expectEqualStrings("Open settings editor", item.description.?);
        }
    }

    try std.testing.expect(saw_settings);
}

test "handleInputKey opens settings overlay for slash settings command" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "");
    defer allocator.free(root_dir);
    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try common.writeFileAbsolute(
        std.testing.io,
        settings_path,
        \\{
        \\  "theme": "dark",
        \\  "editorPaddingX": 1
        \\}
    ,
        true,
    );

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime_config = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, root_dir);
    defer runtime_config.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("/settings");

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = try makeInteractiveTestPath(allocator, tmp, "sessions"),
        .provider = "faux",
        .runtime_config = &runtime_config,
    };
    defer allocator.free(options.session_dir);
    var live_resources = LiveResources.init(options);
    defer live_resources.deinit(allocator);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .settings_editor);
    try std.testing.expectEqualStrings("Settings", overlay.?.title());
    try std.testing.expect(std.mem.indexOf(u8, overlay.?.settings_editor.editor.text(), "\"theme\": \"dark\"") != null);
}

test "settings editor overlay saves settings.json and reloads runtime settings" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "");
    defer allocator.free(root_dir);
    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);
    const session_dir = try makeInteractiveTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    try common.writeFileAbsolute(
        std.testing.io,
        settings_path,
        \\{
        \\  "theme": "dark"
        \\}
    ,
        true,
    );

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime_config = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, root_dir);
    defer runtime_config.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var overlay: ?SelectorOverlay = try loadSettingsEditorOverlay(allocator, std.testing.io, &runtime_config, null);
    defer if (overlay) |*value| value.deinit(allocator);

    overlay.?.settings_editor.editor.reset();
    _ = try overlay.?.settings_editor.editor.handlePaste(
        \\{
        \\  "theme": "light",
        \\  "editorPaddingX": 2,
        \\  "autocompleteMaxVisible": 9,
        \\  "compaction": {
        \\    "enabled": true,
        \\    "reserveTokens": 1200,
        \\    "keepRecentTokens": 6400
        \\  },
        \\  "retry": {
        \\    "enabled": true,
        \\    "maxRetries": 4,
        \\    "baseDelayMs": 2500
        \\  }
        \\}
        \\
    );

    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;
    var auth_flow: ?AuthFlow = null;
    defer if (auth_flow) |*value| value.deinit(allocator);

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
        .runtime_config = &runtime_config,
    };
    var live_resources = LiveResources.init(options);
    defer live_resources.deinit(allocator);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .{ .ctrl = 's' },
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay == null);
    try std.testing.expectEqualStrings("light", live_resources.runtime_config.?.settings.theme.?);
    try std.testing.expectEqual(@as(usize, 2), editor.padding_x);
    try std.testing.expectEqual(@as(usize, 9), editor.autocomplete_max_visible);
    try std.testing.expectEqual(true, session.compaction_settings.enabled);
    try std.testing.expectEqual(@as(u32, 1200), session.compaction_settings.reserve_tokens);
    try std.testing.expectEqual(@as(u32, 6400), session.compaction_settings.keep_recent_tokens);
    try std.testing.expectEqual(true, session.retry_settings.enabled);
    try std.testing.expectEqual(@as(u32, 4), session.retry_settings.max_retries);
    try std.testing.expectEqual(@as(u64, 2500), session.retry_settings.base_delay_ms);

    const saved = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, settings_path, allocator, .limited(1024 * 1024));
    defer allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"theme\": \"light\"") != null);
}

test "handleInputKey opens hotkeys overlay for slash hotkeys command" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("/hotkeys");

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    var custom_keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer custom_keybindings.deinit();

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
        .keybindings = &custom_keybindings,
    };
    var live_resources = LiveResources.init(options);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .info);
    try std.testing.expectEqualStrings("Keyboard shortcuts", overlay.?.title());
}

test "handleInputKey opens model overlay for slash model command" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("/model");

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .model);
    try std.testing.expectEqual(@as(usize, 0), editor.text().len);
}

test "handleInputKey opens scoped model overlay for slash scoped-models command" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "test-openai-key");

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "openai", "gpt-5.4", null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("/scoped-models");

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const scoped_patterns = [_][]const u8{
        "openai/gpt-5.4",
        "openai/gpt-5.5",
    };
    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "openai",
        .model = "gpt-5.4",
        .model_patterns = scoped_patterns[0..],
    };
    var live_resources = LiveResources.init(options);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .model);
    try std.testing.expectEqualStrings("Scoped model selector", overlay.?.title());
    try std.testing.expectEqual(@as(usize, 2), overlay.?.model.items.len);
    try std.testing.expectEqualStrings("gpt-5.4", overlay.?.model.items[0].value);
    try std.testing.expectEqualStrings("gpt-5.5", overlay.?.model.items[1].value);
    try std.testing.expectEqual(@as(usize, 0), editor.text().len);
}

test "handleInputKey scoped model overlay supports navigation and selection" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "test-openai-key");

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "openai", "gpt-5.4", null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("/scoped-models");

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const scoped_patterns = [_][]const u8{
        "openai/gpt-5.4",
        "openai/gpt-5.5",
    };
    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "openai",
        .model = "gpt-5.4",
        .model_patterns = scoped_patterns[0..],
    };
    var live_resources = LiveResources.init(options);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .model);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .down,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expectEqual(@as(usize, 1), overlay.?.model.list.selectedIndex());

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay == null);
    try std.testing.expectEqualStrings("gpt-5.5", session.agent.getModel().id);
    try std.testing.expectEqualStrings("gpt-5.5", current_provider.model.id);
}

test "handleInputKey reports when scoped models are not configured" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("/scoped-models");

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay == null);
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expect(std.mem.indexOf(u8, state.status, "No scoped models configured") != null);
}

test "handleInputKey reports unknown slash commands" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("/not-a-command");

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay == null);
    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "Unknown slash command") != null);
}

test "handleInputKey updates session name for slash name command" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("/name Night Shift");

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expectEqualStrings("Night Shift", session.session_manager.getSessionName().?);
    try std.testing.expectEqualStrings("Night Shift", currentSessionLabel(&session));

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expectEqualStrings("Night Shift", state.session_label);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "Session name set: Night Shift") != null);
}

test "handleInputKey updates current entry labels and tree overlay renders them" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var user = try makeInteractiveTestUserMessage("bookmark me", 1);
    defer session_manager_mod.deinitMessage(allocator, &user);
    const user_id = try session.session_manager.appendMessage(user);
    try session.agent.setMessages(&.{user});

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try state.setFooter(current_provider.model.id, currentSessionLabel(&session));

    _ = try editor.handlePaste("/label bookmark");
    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expectEqualStrings("bookmark", session.session_manager.getLabel(user_id).?);
    {
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        try std.testing.expectEqualStrings("label updated", state.status);
        try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "Label set: bookmark") != null);
    }

    _ = try editor.handlePaste("/tree");
    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .tree);

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 24,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 24 } };
    defer backend.deinit(allocator);

    var lines = try renderScreenWithMockBackendAndOverlay(allocator, &screen, &overlay.?, &backend);
    defer freeLinesSafe(allocator, &lines);
    try std.testing.expect(renderedLinesContain(lines.items, "[bookmark]"));

    overlay.?.deinit(allocator);
    overlay = null;
    freeLinesSafe(allocator, &lines);
    lines = .empty;

    _ = try editor.handlePaste("/label");
    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(session.session_manager.getLabel(user_id) == null);
    {
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        try std.testing.expectEqualStrings("label cleared", state.status);
        try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "Label cleared") != null);
    }

    _ = try editor.handlePaste("/tree");
    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    lines = try renderScreenWithMockBackendAndOverlay(allocator, &screen, &overlay.?, &backend);
    try std.testing.expect(!renderedLinesContain(lines.items, "[bookmark]"));
}

test "submitEditorText resets editor autocomplete state after submit" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "submitted");

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    try editor.setAutocompleteItems(&[_]tui.SelectItem{
        .{ .value = "read", .label = "read" },
        .{ .value = "reload", .label = "reload" },
    });
    _ = try editor.handleKey(.{ .printable = tui.keys.PrintableKey.fromSlice("r") });
    try std.testing.expect(editor.isShowingAutocomplete());

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    defer if (prompt_worker_active) prompt_worker.join(allocator);
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try submitEditorText(
        allocator,
        std.testing.io,
        &env_map,
        editor.text(),
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(prompt_worker_active);
    try std.testing.expectEqualStrings("", editor.text());
    try std.testing.expectEqual(@as(usize, 0), editor.cursorIndex());
    try std.testing.expect(!editor.isShowingAutocomplete());
    try std.testing.expect(editor.selectedAutocompleteItem() == null);

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expectEqualStrings("thinking", state.status);
}

test "handleInputKey pastes a clipboard image into the pending prompt attachments" {
    const allocator = std.testing.allocator;

    const ReaderStub = struct {
        fn read(_: ?*anyopaque, alloc: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map) !?clipboard_image.ClipboardImage {
            _ = io;
            _ = env_map;
            return .{
                .bytes = try alloc.dupe(u8, &[_]u8{ 0x01, 0x02, 0x03 }),
                .mime_type = try alloc.dupe(u8, "image/png"),
            };
        }
    };

    const previous_context = clipboard_image.clipboard_image_reader_context;
    const previous_fn = clipboard_image.clipboard_image_reader_fn;
    clipboard_image.clipboard_image_reader_context = null;
    clipboard_image.clipboard_image_reader_fn = ReaderStub.read;
    defer {
        clipboard_image.clipboard_image_reader_context = previous_context;
        clipboard_image.clipboard_image_reader_fn = previous_fn;
    }

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "clipboard");

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .{ .ctrl = 'v' },
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(state.clipboardPasteInProgress());
    const pending = try state.clonePendingEditorImages(allocator);
    defer deinitImageContents(allocator, pending);

    try std.testing.expectEqual(@as(usize, 0), pending.len);
    try std.testing.expectEqualStrings("", editor.text());

    state.mutex.lockUncancelable(state.io);
    try std.testing.expectEqualStrings("pasting clipboard image...", state.status);
    state.mutex.unlock(state.io);

    var attempts: usize = 0;
    while (state.clipboardPasteInProgress() and attempts < 40) : (attempts += 1) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
        try state.pollClipboardPaste(null);
    }

    const completed_pending = try state.clonePendingEditorImages(allocator);
    defer deinitImageContents(allocator, completed_pending);

    try std.testing.expectEqual(@as(usize, 1), completed_pending.len);
    try std.testing.expectEqualStrings("AQID", completed_pending[0].data);
    try std.testing.expectEqualStrings("image/png", completed_pending[0].mime_type);

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expectEqualStrings("clipboard image pasted", state.status);
}

test "submitEditorText includes pending clipboard images and clears the draft attachments" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "submitted");

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.appendPendingEditorImage(.{
        .data = try allocator.dupe(u8, "AQID"),
        .mime_type = try allocator.dupe(u8, "image/png"),
    });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("describe this image");

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    defer if (prompt_worker_active) prompt_worker.join(allocator);
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try submitEditorText(
        allocator,
        std.testing.io,
        &env_map,
        editor.text(),
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(prompt_worker_active);
    prompt_worker.join(allocator);
    prompt_worker_active = false;

    const pending_after_submit = try state.clonePendingEditorImages(allocator);
    defer deinitImageContents(allocator, pending_after_submit);
    try std.testing.expectEqual(@as(usize, 0), pending_after_submit.len);

    const messages = session.agent.getMessages();
    try std.testing.expect(messages.len >= 1);
    switch (messages[0]) {
        .user => |user_message| {
            try std.testing.expectEqual(@as(usize, 2), user_message.content.len);
            try std.testing.expectEqualStrings("describe this image", user_message.content[0].text.text);
            try std.testing.expectEqualStrings("image/png", user_message.content[1].image.mime_type);
            try std.testing.expectEqualStrings("AQID", user_message.content[1].image.data);
        },
        else => return error.ExpectedUserMessage,
    }
}

test "reload slash command refreshes the selected theme from disk" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent/themes");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1",
        \\  "theme": "sunset"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/themes/sunset.json",
        .data =
        \\{
        \\  "name": "sunset",
        \\  "colors": {
        \\    "primary": "red",
        \\    "secondary": "magenta",
        \\    "success": "green",
        \\    "warning": "yellow",
        \\    "error": "red",
        \\    "background": "#1a1b26",
        \\    "foreground": "white",
        \\    "border": "yellow",
        \\    "muted": "blue"
        \\  }
        \\}
        ,
    });

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const agent_dir = try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "agent" });
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime_config = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, cwd);
    defer runtime_config.deinit();
    var bundle = try resources_mod.loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = runtime_config.agent_dir,
        .global = settingsResources(runtime_config.global_settings),
        .project = settingsResources(runtime_config.project_settings),
    });
    defer bundle.deinit(allocator);

    var live_resources = LiveResources.init(.{
        .cwd = cwd,
        .system_prompt = "sys",
        .session_dir = agent_dir,
        .provider = "faux",
        .runtime_config = &runtime_config,
        .keybindings = &runtime_config.keybindings,
        .prompt_templates = bundle.prompt_templates,
        .theme = bundle.selectedTheme(),
    });
    defer live_resources.deinit(allocator);

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const initial_prompt = try live_resources.theme.?.applyAlloc(allocator, .prompt, "Input:");
    defer allocator.free(initial_prompt);
    try std.testing.expectEqualStrings("Input:", initial_prompt);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/themes/sunset.json",
        .data =
        \\{
        \\  "name": "sunset",
        \\  "base": "light",
        \\  "colors": {
        \\    "primary": "cyan",
        \\    "secondary": "magenta",
        \\    "success": "yellow",
        \\    "warning": "yellow",
        \\    "error": "red",
        \\    "background": "#ffffff",
        \\    "foreground": "#111111",
        \\    "border": "red",
        \\    "muted": "black"
        \\  }
        \\}
        ,
    });

    try handleReloadSlashCommand(allocator, std.testing.io, &env_map, cwd, &state, &live_resources);

    const reloaded_prompt = try live_resources.theme.?.applyAlloc(allocator, .prompt, "Input:");
    defer allocator.free(reloaded_prompt);
    try std.testing.expectEqualStrings("Input:", reloaded_prompt);

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expectEqualStrings("Reloaded keybindings, skills, prompts, and themes", state.status);
}

test "handleInputKey shows session stats for slash session command" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var usage = ai.Usage.init();
    usage.input = 11;
    usage.output = 7;
    usage.cache_read = 2;
    usage.cache_write = 1;
    usage.total_tokens = 21;
    usage.cost.total = 0.42;

    var user = try makeInteractiveTestUserMessage("stats prompt", 1);
    defer session_manager_mod.deinitMessage(allocator, &user);
    var assistant = try makeInteractiveTestAssistantMessage("stats reply", current_provider.model, usage, 2);
    defer session_manager_mod.deinitMessage(allocator, &assistant);
    try session.agent.setMessages(&.{ user, assistant });

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("/session");

    var overlay: ?SelectorOverlay = null;
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    const info = state.items.items[state.items.items.len - 1].text;
    try std.testing.expect(std.mem.indexOf(u8, info, "Messages: user=1, assistant=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "Tokens: input=11, output=7, cache_read=2, cache_write=1, total=21") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "Context:") != null);
}

test "buildChangelogMarkdown returns full file and condensed latest entry" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "CHANGELOG.md",
        .data =
        \\# Changelog
        \\
        \\## [Unreleased]
        \\- WIP
        \\
        \\## [1.2.0]
        \\- Added /changelog
        \\
        \\## [1.1.0]
        \\- Older entry
        ,
    });

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "");
    defer allocator.free(root_dir);

    const full = try buildChangelogMarkdown(allocator, std.testing.io, root_dir, .full);
    defer allocator.free(full);
    try std.testing.expect(std.mem.indexOf(u8, full, "# Changelog") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "## [1.1.0]") != null);

    const condensed = try buildChangelogMarkdown(allocator, std.testing.io, root_dir, .condensed);
    defer allocator.free(condensed);
    try std.testing.expect(std.mem.indexOf(u8, condensed, "## [1.2.0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, condensed, "## [1.1.0]") == null);
    try std.testing.expect(std.mem.indexOf(u8, condensed, "# Changelog") == null);
}

test "handleInputKey appends condensed changelog markdown for slash changelog command" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "CHANGELOG.md",
        .data =
        \\# Changelog
        \\
        \\## [2.0.0]
        \\- Added markdown changelog rendering
        \\
        \\## [1.9.0]
        \\- Older release
        ,
    });

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "");
    defer allocator.free(root_dir);

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("/changelog condensed");

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay == null);
    try std.testing.expectEqual(@as(usize, 0), editor.text().len);

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expectEqual(ChatKind.markdown, state.items.items[state.items.items.len - 1].kind);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "## [2.0.0]") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "## [1.9.0]") == null);
    try std.testing.expectEqualStrings("showing condensed changelog", state.status);
}

test "session overlays use persisted session names and labels" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_dir = try makeInteractiveTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var user = try makeInteractiveTestUserMessage("bookmark me", 1);
    defer session_manager_mod.deinitMessage(allocator, &user);
    const user_id = try session.session_manager.appendMessage(user);
    _ = try session.session_manager.appendLabelChange(user_id, "bookmark");
    _ = try session.session_manager.appendSessionInfo("Night Shift");

    var session_overlay = try loadSessionOverlay(allocator, std.testing.io, session_dir);
    defer session_overlay.deinit(allocator);

    try std.testing.expectEqualStrings("Night Shift", session_overlay.session.items[0].label);

    var tree_overlay = try loadTreeOverlay(allocator, &session);
    defer tree_overlay.deinit(allocator);

    var saw_name = false;
    var saw_label = false;
    for (tree_overlay.tree.items) |item| {
        if (std.mem.indexOf(u8, item.label, "session name: Night Shift") != null) saw_name = true;
        if (std.mem.indexOf(u8, item.label, "[bookmark]") != null) saw_label = true;
    }

    try std.testing.expect(saw_name);
    try std.testing.expect(saw_label);
}

test "handleInputKey imports a session from an explicit jsonl path" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "");
    defer allocator.free(root_dir);
    const session_dir = try makeInteractiveTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    var source = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    defer source.deinit();

    var user = try makeInteractiveTestUserMessage("import me", 1);
    defer session_manager_mod.deinitMessage(allocator, &user);
    var assistant = try makeInteractiveTestAssistantMessage("imported reply", current_provider.model, ai.Usage.init(), 2);
    defer session_manager_mod.deinitMessage(allocator, &assistant);
    _ = try source.session_manager.appendMessage(user);
    _ = try source.session_manager.appendMessage(assistant);
    try source.agent.setMessages(&.{ user, assistant });

    const source_path = try allocator.dupe(u8, source.session_manager.getSessionFile().?);
    defer allocator.free(source_path);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    const command = try std.fmt.allocPrint(allocator, "/import \"{s}\"", .{source_path});
    defer allocator.free(command);
    _ = try editor.handlePaste(command);

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };
    try session.agent.subscribe(subscriber);
    defer _ = session.agent.unsubscribe(subscriber);

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expectEqual(@as(usize, 2), session.agent.getMessages().len);
    try std.testing.expectEqualStrings("import me", session.agent.getMessages()[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("imported reply", session.agent.getMessages()[1].assistant.content[0].text.text);
}

test "handleInputKey starts a fresh session for slash new command" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "");
    defer allocator.free(root_dir);
    const session_dir = try makeInteractiveTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var user = try makeInteractiveTestUserMessage("old prompt", 1);
    defer session_manager_mod.deinitMessage(allocator, &user);
    _ = try session.session_manager.appendMessage(user);
    try session.agent.setMessages(&.{user});

    const previous_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(previous_file);

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("/new");

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };
    try session.agent.subscribe(subscriber);
    defer _ = session.agent.unsubscribe(subscriber);

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expectEqual(@as(usize, 0), session.agent.getMessages().len);
    try std.testing.expect(!std.mem.eql(u8, previous_file, session.session_manager.getSessionFile().?));

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "New session started") != null);
}

test "handleInputKey exports session transcript to explicit html and jsonl paths" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "");
    defer allocator.free(root_dir);
    const session_dir = try makeInteractiveTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    const html_path = try std.fs.path.join(allocator, &[_][]const u8{ root_dir, "session export.html" });
    defer allocator.free(html_path);
    const jsonl_path = try std.fs.path.join(allocator, &[_][]const u8{ root_dir, "session export.jsonl" });
    defer allocator.free(jsonl_path);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var usage = ai.Usage.init();
    usage.input = 5;
    usage.output = 3;
    usage.total_tokens = 8;

    var user = try makeInteractiveTestUserMessage("export prompt", 1);
    defer session_manager_mod.deinitMessage(allocator, &user);
    var assistant = try makeInteractiveTestAssistantMessage("export reply", current_provider.model, usage, 2);
    defer session_manager_mod.deinitMessage(allocator, &assistant);
    _ = try session.session_manager.appendMessage(user);
    _ = try session.session_manager.appendMessage(assistant);
    try session.agent.setMessages(&.{ user, assistant });

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var overlay: ?SelectorOverlay = null;
    var prompt_worker = PromptWorker{
        .session = &session,
        .app_state = &state,
    };
    var prompt_worker_active = false;
    var should_exit = false;

    const subscriber = agent.AgentSubscriber{
        .context = null,
        .callback = struct {
            fn callback(_: ?*anyopaque, _: agent.AgentEvent) !void {}
        }.callback,
    };

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
    };
    var live_resources = LiveResources.init(options);

    const html_command = try std.fmt.allocPrint(allocator, "/export \"{s}\"", .{html_path});
    defer allocator.free(html_command);
    _ = try editor.handlePaste(html_command);
    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    const html_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, html_path, allocator, .limited(1024 * 1024));
    defer allocator.free(html_bytes);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "theme-toggle") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "export prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "export reply") != null);

    const jsonl_command = try std.fmt.allocPrint(allocator, "/export \"{s}\"", .{jsonl_path});
    defer allocator.free(jsonl_command);
    _ = try editor.handlePaste(jsonl_command);
    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &slash_commands.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    const jsonl_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, jsonl_path, allocator, .limited(1024 * 1024));
    defer allocator.free(jsonl_bytes);
    try std.testing.expect(std.mem.indexOf(u8, jsonl_bytes, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl_bytes, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl_bytes, "\"export prompt\"") != null);
}

test "app state streams assistant updates and records tool results" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try state.handleAgentEvent(.{
        .event_type = .message_start,
        .message = .{ .assistant = .{
            .content = &[_]ai.ContentBlock{},
            .tool_calls = null,
            .api = "faux",
            .provider = "faux",
            .model = "faux-1",
            .usage = ai.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        } },
    });
    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .message = .{ .assistant = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "partial" } }},
            .tool_calls = null,
            .api = "faux",
            .provider = "faux",
            .model = "faux-1",
            .usage = ai.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        } },
    });
    try state.handleAgentEvent(.{
        .event_type = .tool_execution_end,
        .tool_name = "bash",
        .result = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "/tmp" } }},
        },
        .is_error = false,
    });

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expectEqualStrings("partial", state.items.items[state.items.items.len - 2].text);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "Tool result bash: /tmp") != null);
}

test "app state aggregates usage totals and footer renders git branch stats" {
    const allocator = std.testing.allocator;

    const model = ai.Model{
        .id = "faux-1",
        .name = "Faux 1",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .reasoning = false,
        .input_types = &[_][]const u8{"text"},
        .cost = .{},
        .context_window = 128000,
        .max_tokens = 4096,
        .headers = null,
        .compat = null,
    };

    var usage = ai.Usage.init();
    usage.input = 11;
    usage.output = 7;
    usage.cache_read = 2;
    usage.cache_write = 1;
    usage.total_tokens = 21;
    usage.cost.total = 0.42;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooterDetails(model, "session.jsonl", "zig-implementation", "Faux", "local");

    try state.handleAgentEvent(.{
        .event_type = .message_start,
        .message = .{ .assistant = .{
            .content = &[_]ai.ContentBlock{},
            .tool_calls = null,
            .api = "faux",
            .provider = "faux",
            .model = "faux-1",
            .usage = usage,
            .stop_reason = .stop,
            .timestamp = 1,
        } },
    });

    state.mutex.lockUncancelable(state.io);
    try std.testing.expectEqual(@as(u64, 0), state.usage_totals.input);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0109375), state.context_percent.?, @as(f64, 0.0000001));
    state.mutex.unlock(state.io);

    try state.handleAgentEvent(.{
        .event_type = .message_end,
        .message = .{ .assistant = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text = "done" } }},
            .tool_calls = null,
            .api = "faux",
            .provider = "faux",
            .model = "faux-1",
            .usage = usage,
            .stop_reason = .stop,
            .timestamp = 1,
        } },
    });
    try state.handleAgentEvent(.{ .event_type = .agent_end });

    {
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        try std.testing.expectEqual(@as(u64, 11), state.usage_totals.input);
        try std.testing.expectEqual(@as(u64, 7), state.usage_totals.output);
        try std.testing.expectEqual(@as(u64, 2), state.usage_totals.cache_read);
        try std.testing.expectEqual(@as(u64, 1), state.usage_totals.cache_write);
        try std.testing.expectEqual(@as(u32, 14), state.context_tokens.?);
        try std.testing.expectApproxEqAbs(@as(f64, 0.42), state.usage_totals.cost, @as(f64, 0.0000001));
    }

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);

    const footer = try formatFooterLine(allocator, null, &snapshot, 160);
    defer allocator.free(footer);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Branch: zig-implementation") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Session: session.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Status: idle") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Provider: Faux (local)") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Provider: Faux (local)") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "↑11") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "↓7") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "R2") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "W1") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "$0.420") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "ctx 0.0%/128k") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Model: faux-1") != null);

    try state.appendQueuedMessage(.steering, "queued steer");
    try state.appendQueuedMessage(.follow_up, "queued follow-up");

    var queued_snapshot = try state.snapshotForRender(allocator);
    defer queued_snapshot.deinit(allocator);

    const queued_footer = try formatFooterLine(allocator, null, &queued_snapshot, 160);
    defer allocator.free(queued_footer);
    try std.testing.expect(std.mem.indexOf(u8, queued_footer, "Queue: 1 steering, 1 follow-up") != null);
}

test "resolveGitBranch reads heads from git directories and gitdir files" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/src");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.git/HEAD",
        .data = "ref: refs/heads/feature/footer\n",
    });

    const repo_cwd = try makeInteractiveTestPath(allocator, tmp, "repo/src");
    defer allocator.free(repo_cwd);
    const repo_branch = try resolveGitBranch(allocator, std.testing.io, repo_cwd);
    defer if (repo_branch) |branch| allocator.free(branch);
    try std.testing.expectEqualStrings("feature/footer", repo_branch.?);

    try tmp.dir.createDirPath(std.testing.io, "worktree/gitdata");
    try tmp.dir.createDirPath(std.testing.io, "worktree/app");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "worktree/.git",
        .data = "gitdir: gitdata\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "worktree/gitdata/HEAD",
        .data = "ref: refs/heads/zig-implementation\n",
    });

    const worktree_cwd = try makeInteractiveTestPath(allocator, tmp, "worktree/app");
    defer allocator.free(worktree_cwd);
    const worktree_branch = try resolveGitBranch(allocator, std.testing.io, worktree_cwd);
    defer if (worktree_branch) |branch| allocator.free(branch);
    try std.testing.expectEqualStrings("zig-implementation", worktree_branch.?);
}

test "interactive tool conversation renders tool lines and persists session entries" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "");
    defer allocator.free(root_dir);
    const session_dir = try makeInteractiveTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    const file_path = try std.fs.path.join(allocator, &[_][]const u8{ root_dir, "note.txt" });
    defer allocator.free(file_path);
    try common.writeFileAbsolute(std.testing.io, file_path, "secret note", true);

    const tool_args_json = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{file_path});
    defer allocator.free(tool_args_json);
    try env_map.put("PI_FAUX_TOOL_NAME", "read");
    try env_map.put("PI_FAUX_TOOL_ARGS_JSON", tool_args_json);
    try env_map.put("PI_FAUX_TOOL_FINAL_RESPONSE", "The file says: secret note");

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var app_context = AppContext.init(root_dir, std.testing.io);
    var built_tools = try buildAgentTools(allocator, &app_context, &[_][]const u8{"read"});
    defer built_tools.deinit();

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter(current_provider.model.id, currentSessionLabel(&session));

    const subscriber = agent.AgentSubscriber{
        .context = &state,
        .callback = handleAppAgentEvent,
    };
    try session.agent.subscribe(subscriber);
    defer _ = session.agent.unsubscribe(subscriber);

    try session.prompt("what is in the file?");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 24,
    };

    var lines = tui.LineList.empty;
    defer freeLinesSafe(allocator, &lines);
    try screen.renderInto(allocator, 240, &lines);

    var saw_user = false;
    var saw_tool_call = false;
    var saw_tool_result = false;
    var saw_assistant_prefix = false;
    var saw_final_response = false;
    for (lines.items) |line| {
        if (std.mem.indexOf(u8, line, "You: what is in the file?") != null) saw_user = true;
        if (std.mem.indexOf(u8, line, "Read ") != null and std.mem.indexOf(u8, line, file_path) != null) saw_tool_call = true;
        if (std.mem.indexOf(u8, line, "Read result read:") != null or std.mem.indexOf(u8, line, "secret note") != null) saw_tool_result = true;
        if (std.mem.indexOf(u8, line, ASSISTANT_PREFIX) != null) saw_assistant_prefix = true;
        if (std.mem.indexOf(u8, line, "The file says: secret note") != null) saw_final_response = true;
    }
    try std.testing.expect(saw_user);
    try std.testing.expect(saw_tool_call);
    try std.testing.expect(saw_tool_result);
    try std.testing.expect(saw_assistant_prefix);
    try std.testing.expect(saw_final_response);

    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);

    const session_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, allocator, .limited(1024 * 1024));
    defer allocator.free(session_bytes);
    try std.testing.expect(std.mem.indexOf(u8, session_bytes, "\"type\":\"toolCall\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_bytes, "\"toolCallId\"") != null);

    var reopened = try session_manager_mod.SessionManager.open(allocator, std.testing.io, session_file, root_dir);
    defer reopened.deinit();

    var context = try reopened.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), context.messages.len);
    try std.testing.expectEqualStrings("what is in the file?", context.messages[0].user.content[0].text.text);
    try std.testing.expect(context.messages[1].assistant.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), context.messages[1].assistant.tool_calls.?.len);
    try std.testing.expectEqualStrings("read", context.messages[1].assistant.tool_calls.?[0].name);
    try std.testing.expectEqualStrings(file_path, context.messages[1].assistant.tool_calls.?[0].arguments.object.get("path").?.string);
    try std.testing.expectEqualStrings("read", context.messages[2].tool_result.tool_name);
    try std.testing.expectEqualStrings("secret note", context.messages[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("The file says: secret note", context.messages[3].assistant.content[0].text.text);
}

test "interactive bash tool conversation preserves structured details" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "");
    defer allocator.free(root_dir);
    const session_dir = try makeInteractiveTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    try env_map.put("PI_FAUX_TOOL_NAME", "bash");
    try env_map.put("PI_FAUX_TOOL_ARGS_JSON", "{\"command\":\"seq 3000\",\"timeout_seconds\":1}");
    try env_map.put("PI_FAUX_TOOL_FINAL_RESPONSE", "The command completed");

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var app_context = AppContext.init(root_dir, std.testing.io);
    var built_tools = try buildAgentTools(allocator, &app_context, &[_][]const u8{"bash"});
    defer built_tools.deinit();

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter(current_provider.model.id, currentSessionLabel(&session));

    const subscriber = agent.AgentSubscriber{
        .context = &state,
        .callback = handleAppAgentEvent,
    };
    try session.agent.subscribe(subscriber);
    defer _ = session.agent.unsubscribe(subscriber);

    try session.prompt("run bash");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 24,
    };

    var lines = tui.LineList.empty;
    defer freeLinesSafe(allocator, &lines);
    try screen.renderInto(allocator, 240, &lines);

    var saw_bash_output = false;
    for (lines.items) |line| {
        if (std.mem.indexOf(u8, line, "3000") != null) saw_bash_output = true;
    }
    try std.testing.expect(saw_bash_output);

    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);

    var reopened = try session_manager_mod.SessionManager.open(allocator, std.testing.io, session_file, root_dir);
    defer reopened.deinit();

    var context = try reopened.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqualStrings("bash", context.messages[2].tool_result.tool_name);
    try std.testing.expect(context.messages[2].tool_result.details != null);
    const details = context.messages[2].tool_result.details.?.object;
    try std.testing.expectEqual(@as(i64, 0), details.get("exit_code").?.integer);
    try std.testing.expectEqual(false, details.get("timed_out").?.bool);
    try std.testing.expect(details.get("full_output_path") != null);
    try std.testing.expect(details.get("truncation") != null);
    try std.testing.expectEqualStrings("lines", details.get("truncation").?.object.get("truncated_by").?.string);
    try std.testing.expect(details.get("truncation").?.object.get("total_lines").?.integer >= 3000);
    const full_output_path = details.get("full_output_path").?.string;
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, full_output_path) catch {};
    try std.testing.expect(std.mem.startsWith(u8, full_output_path, "/tmp/pi-bash-"));
}

test "handleCopySlashCommand copies the last assistant message to the clipboard" {
    const allocator = std.testing.allocator;

    var capture = ClipboardCapture{ .allocator = allocator };
    defer capture.deinit();
    const previous_context = slash_commands.clipboard_copy_context;
    const previous_fn = slash_commands.clipboard_copy_fn;
    slash_commands.clipboard_copy_context = &capture;
    slash_commands.clipboard_copy_fn = captureClipboardText;
    defer {
        slash_commands.clipboard_copy_context = previous_context;
        slash_commands.clipboard_copy_fn = previous_fn;
    }

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var assistant = try makeInteractiveTestAssistantMessage("copied reply", current_provider.model, ai.Usage.init(), 1);
    defer session_manager_mod.deinitMessage(allocator, &assistant);
    try session.agent.setMessages(&.{assistant});

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try handleCopySlashCommand(allocator, std.testing.io, &session, &state);
    try std.testing.expectEqualStrings("copied reply", capture.text.?);
}

test "handleShareSlashCommand copies markdown transcript to the clipboard" {
    const allocator = std.testing.allocator;

    var capture = ClipboardCapture{ .allocator = allocator };
    defer capture.deinit();
    const previous_context = slash_commands.clipboard_copy_context;
    const previous_fn = slash_commands.clipboard_copy_fn;
    slash_commands.clipboard_copy_context = &capture;
    slash_commands.clipboard_copy_fn = captureClipboardText;
    defer {
        slash_commands.clipboard_copy_context = previous_context;
        slash_commands.clipboard_copy_fn = previous_fn;
    }

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var user = try makeInteractiveTestUserMessage("share prompt", 1);
    defer session_manager_mod.deinitMessage(allocator, &user);
    var assistant = try makeInteractiveTestAssistantMessage("share reply", current_provider.model, ai.Usage.init(), 2);
    defer session_manager_mod.deinitMessage(allocator, &assistant);
    try session.agent.setMessages(&.{ user, assistant });

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try handleShareSlashCommand(allocator, std.testing.io, &session, &state);
    try std.testing.expect(std.mem.indexOf(u8, capture.text.?, "# Session") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text.?, "share prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text.?, "share reply") != null);
}

test "handleLogoutSlashCommand opens selector for stored auth providers" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "");
    defer allocator.free(root_dir);
    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);
    const session_dir = try makeInteractiveTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);
    try common.writeFileAbsolute(
        std.testing.io,
        auth_path,
        \\{
        \\  "anthropic": {
        \\    "type": "oauth",
        \\    "access": "oauth-token",
        \\    "refresh": "refresh-token",
        \\    "expires": 1234
        \\  },
        \\  "github-copilot": {
        \\    "type": "oauth",
        \\    "access": "copilot-token",
        \\    "refresh": "refresh-token",
        \\    "expires": 1234
        \\  }
        \\}
    ,
        true,
    );

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime_config = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, root_dir);
    defer runtime_config.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
        .runtime_config = &runtime_config,
    };
    var live_resources = LiveResources.init(options);
    defer live_resources.deinit(allocator);

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);

    try handleLogoutSlashCommand(
        allocator,
        std.testing.io,
        &env_map,
        &session,
        &current_provider,
        null,
        options,
        &state,
        &overlay,
        &live_resources,
    );

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .auth);
    try std.testing.expectEqual(AuthOverlayMode.logout, overlay.?.auth.mode);
    try std.testing.expectEqual(@as(usize, 2), overlay.?.auth.items.len);
}

test "handleLogoutSlashCommand removes stored auth for the current provider" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "");
    defer allocator.free(root_dir);
    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);
    const session_dir = try makeInteractiveTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);
    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);
    try common.writeFileAbsolute(
        std.testing.io,
        auth_path,
        \\{
        \\  "openai": {
        \\    "key": "logout-token"
        \\  }
        \\}
    ,
        true,
    );

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime_config = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, root_dir);
    defer runtime_config.deinit();

    var current_provider = try provider_config.resolveProviderConfig(
        allocator,
        &env_map,
        "openai",
        null,
        null,
        runtime_config.lookupApiKey("openai"),
    );
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "openai",
        .runtime_config = &runtime_config,
    };
    var live_resources = LiveResources.init(options);
    defer live_resources.deinit(allocator);
    var overlay: ?SelectorOverlay = null;

    try handleLogoutSlashCommand(
        allocator,
        std.testing.io,
        &env_map,
        &session,
        &current_provider,
        "openai",
        options,
        &state,
        &overlay,
        &live_resources,
    );

    try std.testing.expect(current_provider.api_key == null);
    const auth_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, auth_path, allocator, .limited(1024 * 1024));
    defer allocator.free(auth_bytes);
    try std.testing.expect(std.mem.indexOf(u8, auth_bytes, "openai") == null);
}

fn makeInteractiveTestPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    if (name.len == 0) {
        const relative_root = try std.fs.path.join(allocator, &[_][]const u8{
            ".zig-cache",
            "tmp",
            &tmp.sub_path,
        });
        defer allocator.free(relative_root);
        return makeInteractiveAbsolutePath(allocator, relative_root);
    }

    const relative_path = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        name,
    });
    defer allocator.free(relative_path);
    return makeInteractiveAbsolutePath(allocator, relative_path);
}

fn makeInteractiveAbsolutePath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

fn makeInteractiveTestUserMessage(text: []const u8, timestamp: i64) !agent.AgentMessage {
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, text) } };
    return .{ .user = .{
        .role = try std.testing.allocator.dupe(u8, "user"),
        .content = blocks,
        .timestamp = timestamp,
    } };
}

fn makeInteractiveTestAssistantMessage(
    text: []const u8,
    model: ai.Model,
    usage: ai.Usage,
    timestamp: i64,
) !agent.AgentMessage {
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, text) } };
    return .{ .assistant = .{
        .role = try std.testing.allocator.dupe(u8, "assistant"),
        .content = blocks,
        .tool_calls = null,
        .api = try std.testing.allocator.dupe(u8, model.api),
        .provider = try std.testing.allocator.dupe(u8, model.provider),
        .model = try std.testing.allocator.dupe(u8, model.id),
        .usage = usage,
        .stop_reason = .stop,
        .timestamp = timestamp,
    } };
}

const ClipboardCapture = struct {
    allocator: std.mem.Allocator,
    text: ?[]u8 = null,

    fn deinit(self: *ClipboardCapture) void {
        if (self.text) |text| self.allocator.free(text);
    }
};

fn captureClipboardText(context: ?*anyopaque, io: std.Io, text: []const u8) !void {
    _ = io;
    const capture: *ClipboardCapture = @ptrCast(@alignCast(context.?));
    if (capture.text) |existing| capture.allocator.free(existing);
    capture.text = try capture.allocator.dupe(u8, text);
}

test "loadSelectableModels respects CLI model patterns" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-key");

    const current_model = ai.model_registry.find("faux", "faux-1").?;
    const filtered = try loadSelectableModels(
        allocator,
        &env_map,
        current_model,
        null,
        &.{"anthropic/sonnet:high"},
        null,
    );
    defer allocator.free(filtered);

    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    for (filtered) |entry| {
        try std.testing.expectEqualStrings("anthropic", entry.provider);
        try std.testing.expect(std.mem.indexOf(u8, entry.model_id, "sonnet") != null);
    }
}
