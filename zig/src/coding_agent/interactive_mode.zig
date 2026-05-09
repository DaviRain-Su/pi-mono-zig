const std = @import("std");
const builtin = @import("builtin");
const ai = @import("ai");
const agent = @import("agent");
const tui = @import("tui");
const auth = @import("auth/auth.zig");
const config_mod = @import("config/config.zig");
const keybindings_mod = @import("shared/keybindings.zig");
const resources_mod = @import("resources/resources.zig");
const session_advanced = @import("sessions/session_advanced.zig");
const session_cwd_mod = @import("sessions/session_cwd.zig");
const missing_cwd_selector_mod = @import("sessions/missing_cwd_selector.zig");
const session_manager_mod = @import("sessions/session_manager.zig");
const provider_config = @import("providers/provider_config.zig");
const session_mod = @import("sessions/session.zig");
const common = @import("tools/common.zig");

const shared = @import("interactive_mode/shared.zig");
const formatting = @import("interactive_mode/formatting.zig");
const overlays = @import("interactive_mode/overlays.zig");
const rendering = @import("interactive_mode/rendering.zig");
const prompt_worker_mod = @import("interactive_mode/prompt_worker.zig");
const command_router = @import("interactive_mode/command_router.zig");
const slash_commands = @import("interactive_mode/slash_commands.zig");
const auth_flow_mod = @import("interactive_mode/auth_flow.zig");
const session_lifecycle = @import("interactive_mode/session_lifecycle.zig");
const input_dispatch = @import("interactive_mode/input_dispatch.zig");
const system_prompt_mod = @import("resources/system_prompt.zig");
const clipboard_image = @import("interactive_mode/clipboard_image.zig");
const tool_adapters = @import("interactive_mode/tool_adapters.zig");
const session_bootstrap = @import("interactive_mode/session_bootstrap.zig");
const extension_ui_bridge = @import("interactive_mode/extension_ui_bridge.zig");
const extension_runtime = @import("extensions/extension_runtime.zig");

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
pub const loadModelOverlayWithSearch = overlays.loadModelOverlayWithSearch;
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
pub const handleAppRetryLifecycleEvent = rendering.handleAppRetryLifecycleEvent;
pub const handleAppCompactionLifecycleEvent = rendering.handleAppCompactionLifecycleEvent;
pub const InteractiveModeTestBackend = rendering.InteractiveModeTestBackend;
pub const renderScreenWithMockBackend = rendering.renderScreenWithMockBackend;
pub const renderScreenWithMockBackendAndOverlay = rendering.renderScreenWithMockBackendAndOverlay;
pub const renderedLinesContain = rendering.renderedLinesContain;
pub const PromptWorker = prompt_worker_mod.PromptWorker;
pub const cloneImageContents = prompt_worker_mod.cloneImageContents;
pub const deinitImageContents = prompt_worker_mod.deinitImageContents;
pub const BuiltTools = tool_adapters.BuiltTools;
pub const ToolBuildOptions = tool_adapters.ToolBuildOptions;
pub const buildAgentTools = tool_adapters.buildAgentTools;
pub const buildAgentToolsWithOptions = tool_adapters.buildAgentToolsWithOptions;
pub const buildAgentToolsWithSelection = tool_adapters.buildAgentToolsWithSelection;
pub const buildAgentToolsWithExtensions = tool_adapters.buildAgentToolsWithExtensions;
pub const buildAgentToolsWithExtensionsSelection = tool_adapters.buildAgentToolsWithExtensionsSelection;
pub const writeStartupDiagnostics = tool_adapters.writeStartupDiagnostics;
pub const InteractiveBootstrap = session_bootstrap.InteractiveBootstrap;
pub const bootstrapInteractiveState = session_bootstrap.bootstrapInteractiveState;
pub const bootstrapInteractiveStateWithMissingCwd = session_bootstrap.bootstrapInteractiveStateWithMissingCwd;
pub const openInitialSession = session_bootstrap.openInitialSession;
pub const openInitialSessionWithMissingCwd = session_bootstrap.openInitialSessionWithMissingCwd;
pub const OwnedMissingSessionCwdIssue = session_bootstrap.OwnedMissingSessionCwdIssue;
pub const resolveResumeSessionPath = session_bootstrap.resolveResumeSessionPath;
pub const preflightInteractiveMissingCwd = session_bootstrap.preflightInteractiveMissingCwd;
pub const SlashCommandKind = command_router.SlashCommandKind;
pub const SlashCommand = command_router.SlashCommand;
pub const BuiltinSlashCommand = command_router.BuiltinSlashCommand;
pub const BUILTIN_SLASH_COMMANDS = command_router.BUILTIN_SLASH_COMMANDS;
pub const createSeededSession = session_lifecycle.createSeededSession;
pub const parseSlashCommand = command_router.parseSlashCommand;
pub const handleSlashCommand = command_router.handleSlashCommand;
pub const switchSession = session_lifecycle.switchSession;
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

const ReloadExtensionToolsContext = struct {
    bootstrap: *session_bootstrap.InteractiveBootstrap,
    app_context: *AppContext,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
};

fn reloadExtensionToolsForInteractiveMode(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    session: *session_mod.AgentSession,
    live_resources: *LiveResources,
) !void {
    const reload_context: *ReloadExtensionToolsContext = @ptrCast(@alignCast(context.?));
    const extensions = if (live_resources.owned_resource_bundle) |*bundle| bundle.extensions else &.{};
    try tool_adapters.replaceAgentToolsForReload(
        allocator,
        reload_context.app_context,
        session,
        &reload_context.bootstrap.built_tools,
        reload_context.options.selected_tools,
        .{
            .extensions = extensions,
            .env_map = env_map,
            .cwd = cwd,
            .io = io,
            .runtime_config = live_resources.runtime_config,
        },
    );

    if (reload_context.options.current_date.len > 0) {
        const next_system_prompt = try system_prompt_mod.buildSystemPrompt(allocator, .{
            .cwd = cwd,
            .current_date = reload_context.options.current_date,
            .custom_prompt = reload_context.options.custom_prompt,
            .append_prompts = reload_context.options.append_prompts,
            .tool_selection = reload_context.options.selected_tools,
            .active_tools = reload_context.bootstrap.built_tools.items,
            .context_files = reload_context.options.context_files,
            .skills = live_resources.skills,
        });
        errdefer allocator.free(next_system_prompt);
        if (reload_context.bootstrap.owned_system_prompt) |previous| allocator.free(previous);
        reload_context.bootstrap.owned_system_prompt = next_system_prompt;
        session.agent.setSystemPrompt(next_system_prompt);
    } else {
        session.agent.setSystemPrompt(reload_context.options.system_prompt);
    }

    for (reload_context.bootstrap.built_tools.startup_diagnostics) |diagnostic| {
        const message = try std.fmt.allocPrint(allocator, "Reload {s}", .{diagnostic.message});
        defer allocator.free(message);
        switch (diagnostic.severity) {
            .info => try reload_context.app_state.appendInfo(message),
            .warning, .@"error" => try reload_context.app_state.appendError(message),
        }
    }
}

fn appendExtensionStartupDiagnosticsToAppState(
    allocator: std.mem.Allocator,
    diagnostics: []const tool_adapters.ExtensionStartupDiagnostic,
    app_state: *AppState,
) !void {
    for (diagnostics) |diagnostic| {
        const message = try std.fmt.allocPrint(allocator, "Startup {s}", .{diagnostic.message});
        defer allocator.free(message);
        switch (diagnostic.severity) {
            .info => try app_state.appendInfo(message),
            .warning, .@"error" => try app_state.appendError(message),
        }
    }
}

pub const handleLoginSlashCommand = auth_flow_mod.handleLoginSlashCommand;
pub const beginLoginFlow = auth_flow_mod.beginLoginFlow;
pub const cancelAuthFlow = auth_flow_mod.cancelAuthFlow;
pub const submitAuthFlowInput = auth_flow_mod.submitAuthFlowInput;
pub const persistLoginCredential = auth_flow_mod.persistLoginCredential;
pub const OpenBrowserFn = auth_flow_mod.OpenBrowserFn;
pub const openBrowserBestEffort = auth_flow_mod.openBrowserBestEffort;
pub const defaultOpenBrowserBestEffort = auth_flow_mod.defaultOpenBrowserBestEffort;
pub const ClipboardCopyFn = slash_commands.ClipboardCopyFn;
pub const BrowserOpenCapture = auth_flow_mod.BrowserOpenCapture;
pub const handleSettingsSlashCommand = slash_commands.handleSettingsSlashCommand;
pub const handleImportSlashCommand = slash_commands.handleImportSlashCommand;
pub const handleCopySlashCommand = slash_commands.handleCopySlashCommand;
pub const handleShareSlashCommand = slash_commands.handleShareSlashCommand;
pub const handleLogoutSlashCommand = auth_flow_mod.handleLogoutSlashCommand;
pub const logoutProviderById = auth_flow_mod.logoutProviderById;
pub const handleNewSlashCommand = session_lifecycle.handleNewSlashCommand;
pub const clearResolvedProviderApiKey = auth_flow_mod.clearResolvedProviderApiKey;
pub const copyTextToClipboard = slash_commands.copyTextToClipboard;
pub const defaultCopyTextToClipboard = slash_commands.defaultCopyTextToClipboard;
pub const runClipboardCommand = slash_commands.runClipboardCommand;
pub const exitCodeFromChildTerm = slash_commands.exitCodeFromChildTerm;
pub const lastAssistantTextAlloc = slash_commands.lastAssistantTextAlloc;
pub const assistantBlocksToTextAlloc = slash_commands.assistantBlocksToTextAlloc;
pub const buildShareText = slash_commands.buildShareText;
pub const messageToShareMarkdown = slash_commands.messageToShareMarkdown;
pub const blocksToShareText = slash_commands.blocksToShareText;
pub const removeStoredAuthToken = auth_flow_mod.removeStoredAuthToken;
pub const handleReloadSlashCommand = slash_commands.handleReloadSlashCommand;
pub const configurePrimaryEditor = slash_commands.configurePrimaryEditor;
pub const appendResourceDiagnostics = slash_commands.appendResourceDiagnostics;
pub const saveSettingsEditorOverlay = slash_commands.saveSettingsEditorOverlay;
pub const handleExportSlashCommand = slash_commands.handleExportSlashCommand;
pub const formatSessionInfo = session_lifecycle.formatSessionInfo;
pub const cloneCurrentSession = session_lifecycle.cloneCurrentSession;
pub const forkCurrentSession = session_lifecycle.forkCurrentSession;
pub const createDerivedSession = session_lifecycle.createDerivedSession;
pub const replaceCurrentSession = session_lifecycle.replaceCurrentSession;
pub const navigateTree = session_lifecycle.navigateTree;
pub const findLastUserMessageIndex = session_lifecycle.findLastUserMessageIndex;
pub const resolveSessionPath = session_lifecycle.resolveSessionPath;
pub const handleInputKey = input_dispatch.handleInputKey;
pub const handleInputKeyWithModifiers = input_dispatch.handleInputKeyWithModifiers;
pub const submitEditorText = input_dispatch.submitEditorText;
pub const clearEditor = input_dispatch.clearEditor;
pub const loadEditorAutocompleteItems = input_dispatch.loadEditorAutocompleteItems;
pub const loadEditorAutocompleteItemsWithResources = input_dispatch.loadEditorAutocompleteItemsWithResources;
pub const freeOwnedSelectItems = input_dispatch.freeOwnedSelectItems;
pub const pollForInput = input_dispatch.pollForInput;
pub const dispatchInputEvent = input_dispatch.dispatchInputEvent;
pub const consumeInputBytes = input_dispatch.consumeInputBytes;
pub const resolveAppAction = input_dispatch.resolveAppAction;
pub const legacyAppActionForKey = input_dispatch.legacyAppActionForKey;
pub const isLegacyAppActionKey = input_dispatch.isLegacyAppActionKey;
pub const handleAppAction = input_dispatch.handleAppAction;
pub const ExtensionUiBridge = extension_ui_bridge.Bridge;

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

    var missing_cwd_issue: ?session_bootstrap.OwnedMissingSessionCwdIssue = null;
    defer if (missing_cwd_issue) |*captured| captured.deinit(allocator);
    const bootstrap_or_exit = try bootstrapInteractiveStateOrPromptMissingCwd(
        allocator,
        io,
        env_map,
        options,
        &app_context,
        &missing_cwd_issue,
        stderr_writer,
    );
    var bootstrap = switch (bootstrap_or_exit) {
        .bootstrap => |state| state,
        .exit_code => |code| return code,
    };
    defer bootstrap.deinit();

    if (bootstrap.built_tools.required_startup_failed) {
        try tool_adapters.writeStartupDiagnostics(stderr_writer, bootstrap.built_tools.startup_diagnostics);
        try stderr_writer.flush();
        return 1;
    }

    var app_state = try AppState.init(allocator, io);
    defer app_state.deinit();
    app_state.setToolOutputExpanded(options.verbose);
    try live_resources.ensureOwnedBundle(allocator, io, env_map, options.cwd);

    const subscriber = agent.AgentSubscriber{
        .context = &app_state,
        .callback = handleAppAgentEvent,
    };
    try bootstrap.session.agent.subscribe(subscriber);
    defer _ = bootstrap.session.agent.unsubscribe(subscriber);
    installSessionUiCallbacks(&bootstrap.session, &app_state);
    defer clearSessionUiCallbacks(&bootstrap.session);

    try rebuildAppStateFromSession(allocator, io, &app_state, &bootstrap.session, &bootstrap.current_provider);
    try appendExtensionStartupDiagnosticsToAppState(allocator, bootstrap.built_tools.startup_diagnostics, &app_state);
    if (live_resources.runtime_config) |runtime_config| {
        try app_state.setThinkingBlockVisibility(runtime_config.hideThinkingBlock());
    }
    try appendConfigErrorStartupWarning(allocator, live_resources.runtime_config, &app_state);
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
    var last_terminal_title: ?[]u8 = null;
    defer if (last_terminal_title) |title| allocator.free(title);
    try updateInteractiveTerminalTitle(allocator, &terminal, &bootstrap.session, &last_terminal_title);
    defer if (showTerminalProgress(live_resources.runtime_config)) {
        writeTerminalProgress(&terminal, false) catch {};
    };

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
    const autocomplete_items = try loadEditorAutocompleteItemsWithResources(
        allocator,
        io,
        options.cwd,
        live_resources.prompt_templates,
        live_resources.skills,
        true,
    );
    defer freeOwnedSelectItems(allocator, autocomplete_items);
    try editor.setAutocompleteItems(autocomplete_items);

    var screen = ScreenComponent{
        .state = &app_state,
        .editor = &editor,
        .keybindings = live_resources.keybindings,
        .theme = live_resources.theme,
        .terminal_name = live_resources.terminal_name,
    };

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    var overlay_panel: ?OverlayPanelComponent = null;
    var overlay_handle_id: ?usize = null;
    var overlay_opened_at_ms: ?i64 = null;
    var last_overlay_tag: ?std.meta.Tag(SelectorOverlay) = null;

    var auth_flow: ?AuthFlow = null;
    defer if (auth_flow) |*value| value.deinit(allocator);

    var extension_bridge = ExtensionUiBridge.init(allocator, io);
    defer extension_bridge.deinit();
    live_resources.extension_command_sink = extension_bridge.commandSink();
    var reload_tools_context = ReloadExtensionToolsContext{
        .bootstrap = &bootstrap,
        .app_context = &app_context,
        .options = options,
        .app_state = &app_state,
    };
    live_resources.reload_extension_tools_sink = .{
        .context = &reload_tools_context,
        .callback = reloadExtensionToolsForInteractiveMode,
    };

    var prompt_worker: PromptWorker = undefined;
    var prompt_worker_active = false;
    defer if (prompt_worker_active) {
        bootstrap.session.agent.abort();
        prompt_worker.join(allocator);
    };

    if (options.initial_prompt) |initial_prompt| {
        if (initial_prompt.len > 0) {
            for (options.initial_messages) |message| {
                try bootstrap.session.followUp(message, &.{});
            }
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
            app_state.setToolOutputExpanded(true);
            renderer.markDirty();
            if (should_exit) break;
        }
        installSessionUiCallbacks(&bootstrap.session, &app_state);
        if (app_state.pollBashExecution(allocator)) renderer.markDirty();

        try app_state.pollClipboardPaste(.{
            .vx = input_loop.vaxis_state,
            .tty = input_loop.loop.tty.writer(),
        });
        app_state.flushRetiredTerminalImages(.{
            .vx = input_loop.vaxis_state,
            .tty = input_loop.loop.tty.writer(),
        });

        const now_ms = nowMilliseconds();
        try extension_bridge.service(
            env_map,
            options.cwd,
            &terminal,
            &editor,
            &overlay,
            &app_state,
            &live_resources,
            &bootstrap.session,
            now_ms,
        );

        auth_flow_mod.pollAuthFlowCallback(
            allocator,
            io,
            env_map,
            &bootstrap.session,
            &bootstrap.current_provider,
            options,
            &app_state,
            &editor,
            &auth_flow,
            &live_resources,
        ) catch |err| {
            const auth_message = try auth.formatAuthenticationError(allocator, err);
            defer if (auth_message) |formatted| allocator.free(formatted);
            const message = try std.fmt.allocPrint(
                allocator,
                "Authentication failed: {s}",
                .{if (auth_message) |formatted| formatted else @errorName(err)},
            );
            defer allocator.free(message);
            try app_state.appendError(message);
        };

        if (app_state.takeTerminalProgressUpdate()) |active| {
            if (showTerminalProgress(live_resources.runtime_config)) {
                try writeTerminalProgress(&terminal, active);
            }
        }
        try updateInteractiveTerminalTitle(allocator, &terminal, &bootstrap.session, &last_terminal_title);

        if (should_exit and !prompt_worker_active) break;

        const background_render_active = prompt_worker_active or app_state.user_bash_task.isActive();
        if (background_render_active) {
            renderer.markDirty();
        }

        var handled_input = false;
        while (try input_loop.tryInputEvent()) |event| {
            defer event.deinit(allocator);
            handled_input = true;
            renderer.markDirty();
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
            if (app_context.suspend_requested) break;
        }
        if (app_context.suspend_requested) {
            try suspendInteractiveTerminal(allocator, io, env_map, &terminal, &input_loop, &app_state);
            app_context.suspend_requested = false;
            continue;
        }

        // Rebind live resource pointers after input handling. Auth/logout/settings
        // flows may have called live_resources.reload() during dispatchInputEvent(),
        // freeing the previous ResourceBundle and its Theme instances.
        const size = try terminal.refreshSize();
        screen.height = size.height;
        screen.overlay = if (overlay) |*value| value else null;
        screen.keybindings = live_resources.keybindings;
        screen.theme = live_resources.theme;
        screen.terminal_name = live_resources.terminal_name;
        screen.now_ms = now_ms;

        if (overlay) |*overlay_value| {
            const overlay_tag = std.meta.activeTag(overlay_value.*);
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

        if (!handled_input) {
            const sleep_ms: i64 = if (background_render_active) 16 else 50;
            std.Io.sleep(io, .fromMilliseconds(sleep_ms), .awake) catch {};
        }
    }

    return 0;
}

fn installSessionUiCallbacks(session: *session_mod.AgentSession, app_state: *AppState) void {
    session.setRetryLifecycleCallback(.{
        .context = app_state,
        .callback = handleAppRetryLifecycleEvent,
    });
    session.setCompactionLifecycleCallback(.{
        .context = app_state,
        .callback = handleAppCompactionLifecycleEvent,
    });
}

fn clearSessionUiCallbacks(session: *session_mod.AgentSession) void {
    session.clearRetryLifecycleCallback();
    session.clearCompactionLifecycleCallback();
}

fn showTerminalProgress(runtime_config: ?*const config_mod.RuntimeConfig) bool {
    return if (runtime_config) |config| config.showTerminalProgress() else false;
}

fn writeTerminalProgress(terminal: *tui.Terminal, active: bool) !void {
    try terminal.write(if (active) "\x1b]9;4;3\x07" else "\x1b]9;4;0;\x07");
}

fn updateInteractiveTerminalTitle(
    allocator: std.mem.Allocator,
    terminal: *tui.Terminal,
    session: *const session_mod.AgentSession,
    last_title: *?[]u8,
) !void {
    const cwd_basename = std.fs.path.basename(session.cwd);
    const title = if (session.session_manager.getSessionName()) |name|
        try std.fmt.allocPrint(allocator, "pi - {s} - {s}", .{ name, cwd_basename })
    else
        try std.fmt.allocPrint(allocator, "pi - {s}", .{cwd_basename});
    defer allocator.free(title);

    if (last_title.*) |existing| {
        if (std.mem.eql(u8, existing, title)) return;
        allocator.free(existing);
        last_title.* = null;
    }

    const sequence = try std.fmt.allocPrint(allocator, "\x1b]0;{s}\x07", .{title});
    defer allocator.free(sequence);
    try terminal.write(sequence);
    last_title.* = try allocator.dupe(u8, title);
}

fn suspendInteractiveTerminal(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    terminal: *tui.Terminal,
    input_loop: **tui.terminal.InputLoop,
    app_state: *AppState,
) !void {
    if (builtin.os.tag == .windows) {
        try app_state.setStatus("Suspend to background is not supported on Windows");
        return;
    }

    input_loop.*.deinit();
    terminal.stop();

    if (!builtin.is_test) {
        std.posix.kill(0, .TSTP) catch |err| {
            try terminal.start();
            input_loop.* = try terminal.initInputLoop(allocator, io, env_map);
            const message = try std.fmt.allocPrint(allocator, "Suspend failed: {s}", .{@errorName(err)});
            defer allocator.free(message);
            try app_state.setStatus(message);
            return;
        };
    }

    try terminal.start();
    input_loop.* = try terminal.initInputLoop(allocator, io, env_map);
    input_loop.*.vaxis_state.queryTerminal(input_loop.*.loop.tty.writer(), .fromMilliseconds(250)) catch {};
    try app_state.setStatus("resumed");
}

/// Result of bootstrap that may want to short-circuit interactive mode (for
/// example, after a cancelled missing-cwd prompt).
const BootstrapOrExit = union(enum) {
    bootstrap: session_bootstrap.InteractiveBootstrap,
    exit_code: u8,
};

/// Attempts to bootstrap the interactive session. If the stored session cwd
/// no longer exists, prompts the user through a TUI Continue/Cancel selector
/// matching the TypeScript ExtensionSelectorComponent behavior; on cancel,
/// returns an exit code; on continue, retries the bootstrap with
/// `missing_cwd_mode = .use_fallback`.
fn bootstrapInteractiveStateOrPromptMissingCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    options: RunInteractiveModeOptions,
    app_context: *AppContext,
    out_issue: *?session_bootstrap.OwnedMissingSessionCwdIssue,
    stderr_writer: *std.Io.Writer,
) !BootstrapOrExit {
    // Lifecycle ordering: run the missing-cwd preflight BEFORE provider auth /
    // tool construction. This guarantees the Continue/Cancel TUI selector
    // appears even when provider auth or model configuration would otherwise
    // fail later in bootstrap. Matches TypeScript main.ts which checks the
    // missing-cwd issue before constructing the runtime.
    //
    // When the caller already prompted the user via the earlier
    // pre-`prepareCliRuntime` lifecycle preflight, skip prompting again.
    if (!options.missing_cwd_already_confirmed) {
        if (try session_bootstrap.preflightInteractiveMissingCwd(allocator, io, options)) |captured_preflight| {
            var captured_preflight_mut = captured_preflight;
            defer captured_preflight_mut.deinit(allocator);
            const choice = try promptInteractiveMissingSessionCwd(
                allocator,
                io,
                env_map,
                captured_preflight_mut.issue(),
            );
            if (choice == .cancel) {
                try stderr_writer.writeAll("Resume cancelled\n");
                try stderr_writer.flush();
                return .{ .exit_code = 0 };
            }
            var fallback_options = options;
            fallback_options.missing_cwd_mode = .use_fallback;
            const retry = session_bootstrap.bootstrapInteractiveState(
                allocator,
                io,
                env_map,
                fallback_options,
                app_context,
            );
            if (retry) |state| return .{ .bootstrap = state } else |retry_err| switch (retry_err) {
                error.MissingApiKey,
                error.UnknownProvider,
                error.InvalidFauxStopReason,
                error.InvalidFauxTokensPerSecond,
                error.InvalidFauxContextWindow,
                error.InvalidFauxToolArguments,
                => {
                    try stderr_writer.print("Error: {s}\n", .{provider_config.resolveProviderErrorMessage(retry_err, options.provider)});
                    try stderr_writer.flush();
                    return .{ .exit_code = 1 };
                },
                else => return retry_err,
            }
        }
    }

    const initial = session_bootstrap.bootstrapInteractiveStateWithMissingCwd(
        allocator,
        io,
        env_map,
        options,
        app_context,
        out_issue,
    );
    if (initial) |state| {
        return .{ .bootstrap = state };
    } else |err| switch (err) {
        error.MissingApiKey,
        error.UnknownProvider,
        error.InvalidFauxStopReason,
        error.InvalidFauxTokensPerSecond,
        error.InvalidFauxContextWindow,
        error.InvalidFauxToolArguments,
        => {
            try stderr_writer.print("Error: {s}\n", .{provider_config.resolveProviderErrorMessage(err, options.provider)});
            try stderr_writer.flush();
            return .{ .exit_code = 1 };
        },
        error.MissingSessionCwd => {
            // Defensive fallback: if the preflight missed (for example a
            // session whose stored cwd disappeared between preflight and
            // open), reuse the same TUI selector flow.
            const captured = out_issue.* orelse {
                try stderr_writer.writeAll("Error: stored session working directory does not exist\n");
                try stderr_writer.flush();
                return .{ .exit_code = 1 };
            };
            const choice = try promptInteractiveMissingSessionCwd(
                allocator,
                io,
                env_map,
                captured.issue(),
            );
            if (choice == .cancel) {
                try stderr_writer.writeAll("Resume cancelled\n");
                try stderr_writer.flush();
                return .{ .exit_code = 0 };
            }
            var fallback_options = options;
            fallback_options.missing_cwd_mode = .use_fallback;
            const retry = session_bootstrap.bootstrapInteractiveState(
                allocator,
                io,
                env_map,
                fallback_options,
                app_context,
            );
            if (retry) |state| return .{ .bootstrap = state } else |retry_err| switch (retry_err) {
                error.MissingApiKey,
                error.UnknownProvider,
                error.InvalidFauxStopReason,
                error.InvalidFauxTokensPerSecond,
                error.InvalidFauxContextWindow,
                error.InvalidFauxToolArguments,
                => {
                    try stderr_writer.print("Error: {s}\n", .{provider_config.resolveProviderErrorMessage(retry_err, options.provider)});
                    try stderr_writer.flush();
                    return .{ .exit_code = 1 };
                },
                else => return retry_err,
            }
        },
        else => return err,
    }
}

/// Prompts the user via the full TUI Continue/Cancel selector to either
/// continue resuming the session in the launch cwd or cancel. Returns the
/// resolved `MissingCwdChoice`. Mirrors the TypeScript
/// `promptForMissingSessionCwd` flow that uses an ExtensionSelectorComponent
/// with options ["Continue", "Cancel"] before any session mutation.
fn promptInteractiveMissingSessionCwd(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    issue: session_cwd_mod.MissingSessionCwdIssue,
) !missing_cwd_selector_mod.MissingCwdChoice {
    return missing_cwd_selector_mod.runMissingCwdSelector(allocator, io, env_map, issue);
}

fn appendConfigErrorStartupWarning(
    allocator: std.mem.Allocator,
    runtime_config: ?*const config_mod.RuntimeConfig,
    app_state: *AppState,
) !void {
    const config = runtime_config orelse return;
    try appendConfigErrorsStartupWarning(allocator, config.errors, app_state);
}

fn appendConfigErrorsStartupWarning(
    allocator: std.mem.Allocator,
    errors: []const config_mod.ConfigError,
    app_state: *AppState,
) !void {
    if (errors.len == 0) return;
    const first = errors[0];
    const warning = try std.fmt.allocPrint(
        allocator,
        "Config error: {d} issue{s}; first source={s} path={s}: {s}",
        .{
            errors.len,
            if (errors.len == 1) "" else "s",
            config_mod.configErrorSourceName(first.source),
            first.path,
            first.message,
        },
    );
    defer allocator.free(warning);
    try app_state.appendInfo(warning);
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
    const interrupt = try actionLabel(allocator, keybindings, .interrupt, "Esc");
    defer allocator.free(interrupt);
    const clear = try actionLabel(allocator, keybindings, .clear, "Ctrl+C");
    defer allocator.free(clear);
    const exit = try actionLabel(allocator, keybindings, .exit, "Ctrl+D");
    defer allocator.free(exit);
    const suspend_label = try actionLabel(allocator, keybindings, .app_suspend, "Ctrl+Z");
    defer allocator.free(suspend_label);
    const cycle_forward = try actionLabel(allocator, keybindings, .model_cycleForward, "Ctrl+P");
    defer allocator.free(cycle_forward);
    const cycle_backward = try actionLabel(allocator, keybindings, .model_cycleBackward, "Shift+Ctrl+P");
    defer allocator.free(cycle_backward);
    const open_models = try actionLabel(allocator, keybindings, .model_select, "Ctrl+L");
    defer allocator.free(open_models);
    const resume_session = try actionLabel(allocator, keybindings, .session_resume, "Unbound");
    defer allocator.free(resume_session);
    const tree_session = try actionLabel(allocator, keybindings, .session_tree, "Unbound");
    defer allocator.free(tree_session);
    const fork_session = try actionLabel(allocator, keybindings, .session_fork, "Unbound");
    defer allocator.free(fork_session);
    const new_session = try actionLabel(allocator, keybindings, .session_new, "Unbound");
    defer allocator.free(new_session);
    const follow_up = try actionLabel(allocator, keybindings, .message_followUp, "Alt+Enter");
    defer allocator.free(follow_up);
    const dequeue = try actionLabel(allocator, keybindings, .message_dequeue, "Alt+Up");
    defer allocator.free(dequeue);
    const tools_expand = try actionLabel(allocator, keybindings, .tools_expand, "Ctrl+O");
    defer allocator.free(tools_expand);
    const thinking_cycle = try actionLabel(allocator, keybindings, .thinking_cycle, "Shift+Tab");
    defer allocator.free(thinking_cycle);
    const thinking_toggle = try actionLabel(allocator, keybindings, .thinking_toggle, "Ctrl+T");
    defer allocator.free(thinking_toggle);
    const paste_image = try actionLabel(allocator, keybindings, .clipboard_pasteImage, "Ctrl+V");
    defer allocator.free(paste_image);

    return std.fmt.allocPrint(
        allocator,
        "Pi interactive mode (verbose startup)\n{s} interrupt • {s} clear ({s} twice exits) • {s} exit when empty • {s} suspend • {s}/{s} cycle models • {s} models • {s} resume • {s} tree • {s} fork • {s} new • {s} follow-up • {s} dequeue • {s} tools • {s} thinking level • {s} thinking visibility • {s} paste image • / commands • ! bash • !! bash no context",
        .{ interrupt, clear, clear, exit, suspend_label, cycle_forward, cycle_backward, open_models, resume_session, tree_session, fork_session, new_session, follow_up, dequeue, tools_expand, thinking_cycle, thinking_toggle, paste_image },
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
        .event_type = .message_start,
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
        .height = 14,
    };

    var lines = tui.LineList.empty;
    defer freeLinesSafe(allocator, &lines);
    try screen.renderInto(allocator, 80, &lines);

    try std.testing.expect(lines.items.len >= 3);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "╭") != null);
    try std.testing.expect(renderedLinesContain(lines.items, "pi · session.jsonl"));
    try std.testing.expect(renderedLinesContain(lines.items, "Welcome to pi"));
    try std.testing.expect(renderedLinesContain(lines.items, "╭"));
    try std.testing.expect(renderedLinesContain(lines.items, "> w"));
    try std.testing.expect(renderedLinesContain(lines.items, "╰"));
    try std.testing.expect(std.mem.indexOf(u8, lines.items[lines.items.len - 1], "Session: session.jsonl") != null);
}

test "interactive mode startup renders welcome message and footer through a mock backend" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 10,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 10 } };
    defer backend.deinit(allocator);

    var lines = try renderScreenWithMockBackend(allocator, &screen, &backend);
    defer freeLinesSafe(allocator, &lines);

    try std.testing.expect(backend.entered_raw);
    try std.testing.expect(backend.restored);
    const expected_use_kitty = tui.terminal.testing.shouldUseKittyKeyboardProtocolForCurrentEnv();
    try std.testing.expectEqualStrings(
        tui.terminal.testing.expectedStartupSequence(expected_use_kitty),
        backend.writes.items[0],
    );
    try std.testing.expectEqualStrings(
        tui.terminal.testing.expectedStopSequence(expected_use_kitty),
        backend.writes.items[backend.writes.items.len - 1],
    );
    try std.testing.expect(renderedLinesContain(lines.items, "Welcome to pi (Zig interactive mode)."));
    try std.testing.expect(renderedLinesContain(lines.items, "╭"));
    try std.testing.expect(renderedLinesContain(lines.items, "> "));
    try std.testing.expect(renderedLinesContain(lines.items, "╰"));
    try std.testing.expect(renderedLinesContain(lines.items, "Session: session.jsonl"));
    try std.testing.expect(renderedLinesContain(lines.items, "Status: idle"));
    try std.testing.expect(renderedLinesContain(lines.items, "Model: faux-1"));
    try std.testing.expect(!renderedLinesContain(lines.items, "⏎ send"));
    try std.testing.expect(!renderedLinesContain(lines.items, "Alt+⏎ queue"));
}

test "terminal title and progress helpers emit TS control sequences without duplicates" {
    const allocator = std.testing.allocator;

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 24 } };
    defer backend.deinit(allocator);

    var terminal = tui.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .model = ai.model_registry.find("faux", "faux-1").?,
    });
    defer session.deinit();

    var last_title: ?[]u8 = null;
    defer if (last_title) |title| allocator.free(title);

    try updateInteractiveTerminalTitle(allocator, &terminal, &session, &last_title);
    try updateInteractiveTerminalTitle(allocator, &terminal, &session, &last_title);
    try writeTerminalProgress(&terminal, true);
    try writeTerminalProgress(&terminal, false);

    var title_count: usize = 0;
    var active_progress = false;
    var cleared_progress = false;
    for (backend.writes.items) |write| {
        if (std.mem.eql(u8, write, "\x1b]0;pi - project\x07")) title_count += 1;
        if (std.mem.eql(u8, write, "\x1b]9;4;3\x07")) active_progress = true;
        if (std.mem.eql(u8, write, "\x1b]9;4;0;\x07")) cleared_progress = true;
    }
    try std.testing.expectEqual(@as(usize, 1), title_count);
    try std.testing.expect(active_progress);
    try std.testing.expect(cleared_progress);
}

test "appendVerboseStartupState adds startup banner and scoped model listing" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-key");

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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

test "appendConfigErrorsStartupWarning adds nonfatal startup row" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const path = try allocator.dupe(u8, "/tmp/settings.json");
    defer allocator.free(path);
    const message = try allocator.dupe(u8, "SyntaxError");
    defer allocator.free(message);
    const errors = [_]config_mod.ConfigError{
        .{
            .source = .settings,
            .path = path,
            .message = message,
        },
    };

    try appendConfigErrorsStartupWarning(allocator, &errors, &state);

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);

    var saw_warning = false;
    for (snapshot.items) |item| {
        if (std.mem.indexOf(u8, item.text, "Config error: 1 issue") != null and
            std.mem.indexOf(u8, item.text, "source=settings") != null)
        {
            saw_warning = true;
        }
    }
    try std.testing.expect(saw_warning);
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

    collapsed_state.toggleAllExpanded();
    var expanded_snapshot = try collapsed_state.snapshotForRender(allocator);
    defer expanded_snapshot.deinit(allocator);

    var saw_expanded_details = false;
    for (expanded_snapshot.items) |item| {
        if (item.expanded_text) |expanded_text| {
            if (std.mem.indexOf(u8, expanded_text, "Details:") != null and
                std.mem.indexOf(u8, expanded_text, "\"exit_code\":0") != null) saw_expanded_details = true;
        }
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
        .height = 12,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 12 } };
    defer backend.deinit(allocator);

    var lines = try renderScreenWithMockBackend(allocator, &screen, &backend);
    defer freeLinesSafe(allocator, &lines);

    try std.testing.expect(renderedLinesContain(lines.items, "╭"));
    try std.testing.expect(renderedLinesContain(lines.items, "> "));
    try std.testing.expect(renderedLinesContain(lines.items, "[image 1: image/png]"));
}

test "interactive mode renders submitted user messages through a mock backend" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");
    try state.handleAgentEvent(.{
        .event_type = .message_start,
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
        .height = 12,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 12 } };
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
        .event_type = .message_end,
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
        .height = 12,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 12 } };
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
        .event_type = .message_start,
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
        .height = 12,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 12 } };
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
        .height = 12,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 80, .height = 12 } };
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
    try screen.renderInto(allocator, 60, &lines);

    try std.testing.expect(lines.items.len >= 5);
    var saw_prompt_border = false;
    var saw_prompt_glyph = false;
    var saw_overflow = false;
    for (lines.items) |line| {
        if (std.mem.indexOf(u8, line, "╭") != null) saw_prompt_border = true;
        if (std.mem.indexOf(u8, line, "> ") != null) saw_prompt_glyph = true;
        if (std.mem.indexOf(u8, line, "↓ more") != null) saw_overflow = true;
    }
    try std.testing.expect(saw_prompt_border);
    try std.testing.expect(saw_prompt_glyph);
    try std.testing.expect(saw_overflow);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[lines.items.len - 1], "TERM") != null);
}

test "screen renders themed output without persistent keybinding hints" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");

    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();
    try keybindings.setBinding(.session_resume, &.{.{ .ctrl = 'x' }});

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

    try std.testing.expect(!saw_custom_hint);
}

test "screen renders assistant markdown while keeping user messages plain" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setFooter("faux-1", "session.jsonl");

    try state.handleAgentEvent(.{
        .event_type = .message_start,
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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
        &auth_flow_mod.test_auth_flow,
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        .event_type = .message_start,
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
        .escape,
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &auth_flow_mod.test_auth_flow,
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
        .{ .ctrl = 'c' },
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &auth_flow_mod.test_auth_flow,
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
    try std.testing.expect(renderedLinesContain(lines.items, "╭"));
    try std.testing.expect(renderedLinesContain(lines.items, "> "));
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
        &auth_flow_mod.test_auth_flow,
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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
        &auth_flow_mod.test_auth_flow,
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

    auth_flow_mod.test_auth_flow = null;
    try handleLoginSlashCommand(allocator, std.testing.io, &env_map, null, &state, &overlay, &auth_flow_mod.test_auth_flow);

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .auth);
    try std.testing.expectEqual(AuthOverlayMode.login, overlay.?.auth.mode);
    try std.testing.expect(overlay.?.auth.items.len > 3);
    try std.testing.expectEqualStrings("anthropic", overlay.?.auth.items[0].value);
    try std.testing.expectEqualStrings("Anthropic (Claude Pro/Max)", overlay.?.auth.items[0].label);
    try std.testing.expectEqualStrings("OAuth login", overlay.?.auth.items[0].description.?);

    var saw_copilot = false;
    var saw_codex_subscription = false;
    var saw_openai = false;
    for (overlay.?.auth.items) |item| {
        if (std.mem.eql(u8, item.value, "github-copilot")) {
            saw_copilot = true;
            try std.testing.expectEqualStrings("GitHub Copilot", item.label);
            try std.testing.expectEqualStrings("OAuth login", item.description.?);
        }
        if (std.mem.eql(u8, item.value, "openai-codex") and std.mem.eql(u8, item.description.?, "OAuth login")) {
            saw_codex_subscription = true;
            try std.testing.expectEqualStrings("ChatGPT Plus/Pro (Codex Subscription)", item.label);
        }
        if (std.mem.eql(u8, item.value, "openai")) {
            saw_openai = true;
            try std.testing.expectEqualStrings("OpenAI", item.label);
            try std.testing.expectEqualStrings("API key login", item.description.?);
        }
    }
    try std.testing.expect(saw_copilot);
    try std.testing.expect(saw_codex_subscription);
    try std.testing.expect(saw_openai);
}

test "beginLoginFlow starts anthropic oauth prompt state" {
    const allocator = std.testing.allocator;

    var oauth_callback_lock = try OAuthCallbackTestLock.acquire(std.testing.io);
    defer oauth_callback_lock.release(std.testing.io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    auth_flow_mod.test_auth_flow = null;
    defer if (auth_flow_mod.test_auth_flow) |*value| {
        value.deinit(allocator);
        auth_flow_mod.test_auth_flow = null;
    };
    var browser_open_capture = BrowserOpenCapture{};
    const previous_browser_open_context = auth_flow_mod.open_browser_context;
    const previous_browser_open_fn = auth_flow_mod.open_browser_fn;
    auth_flow_mod.open_browser_context = &browser_open_capture;
    auth_flow_mod.open_browser_fn = BrowserOpenCapture.capture;
    defer {
        auth_flow_mod.open_browser_context = previous_browser_open_context;
        auth_flow_mod.open_browser_fn = previous_browser_open_fn;
    }
    const previous_start_callback_listener_fn = auth_flow_mod.start_callback_listener_for_session_fn;
    auth_flow_mod.start_callback_listener_for_session_fn = startEphemeralCallbackListenerForTest;
    defer auth_flow_mod.start_callback_listener_for_session_fn = previous_start_callback_listener_fn;

    try beginLoginFlow(allocator, std.testing.io, &env_map, "anthropic", null, &state, &auth_flow_mod.test_auth_flow);
    auth_flow_mod.start_callback_listener_for_session_fn = previous_start_callback_listener_fn;

    try std.testing.expect(auth_flow_mod.test_auth_flow != null);
    try std.testing.expect(auth_flow_mod.test_auth_flow.? == .browser_redirect);
    try std.testing.expectEqual(auth.BrowserLoginKind.anthropic, auth_flow_mod.test_auth_flow.?.browser_redirect.session.kind);
    try std.testing.expect(auth_flow_mod.test_auth_flow.?.browser_redirect.callback_listener != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        auth_flow_mod.test_auth_flow.?.browser_redirect.callback_listener.?.redirect_uri,
        "/callback",
    ));
    try std.testing.expect(browser_open_capture.called);
    try std.testing.expect(std.mem.indexOf(u8, browser_open_capture.url.?, "redirect_uri=http%3A%2F%2Flocalhost%3A53692%2Fcallback") != null);

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "You will be prompted") == null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "Anthropic (Claude Pro/Max) login started") != null);
}

test "beginLoginFlow falls back to manual paste when OAuth callback listener bind fails" {
    const allocator = std.testing.allocator;

    var oauth_callback_lock = try OAuthCallbackTestLock.acquire(std.testing.io);
    defer oauth_callback_lock.release(std.testing.io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    auth_flow_mod.test_auth_flow = null;
    defer if (auth_flow_mod.test_auth_flow) |*value| {
        value.deinit(allocator);
        auth_flow_mod.test_auth_flow = null;
    };
    var browser_open_capture = BrowserOpenCapture{};
    const previous_browser_open_context = auth_flow_mod.open_browser_context;
    const previous_browser_open_fn = auth_flow_mod.open_browser_fn;
    auth_flow_mod.open_browser_context = &browser_open_capture;
    auth_flow_mod.open_browser_fn = BrowserOpenCapture.capture;
    defer {
        auth_flow_mod.open_browser_context = previous_browser_open_context;
        auth_flow_mod.open_browser_fn = previous_browser_open_fn;
    }
    const FailingCallbackListener = struct {
        fn start(
            listener_allocator: std.mem.Allocator,
            listener_io: std.Io,
            browser_session: *const auth.BrowserLoginSession,
        ) anyerror!*auth.OAuthCallbackListener {
            _ = listener_allocator;
            _ = listener_io;
            _ = browser_session;
            return error.AddressInUse;
        }
    };
    const previous_start_callback_listener_fn = auth_flow_mod.start_callback_listener_for_session_fn;
    auth_flow_mod.start_callback_listener_for_session_fn = FailingCallbackListener.start;
    defer auth_flow_mod.start_callback_listener_for_session_fn = previous_start_callback_listener_fn;

    try beginLoginFlow(allocator, std.testing.io, &env_map, "anthropic", null, &state, &auth_flow_mod.test_auth_flow);
    auth_flow_mod.start_callback_listener_for_session_fn = previous_start_callback_listener_fn;

    try std.testing.expect(auth_flow_mod.test_auth_flow != null);
    try std.testing.expect(auth_flow_mod.test_auth_flow.? == .browser_redirect);
    try std.testing.expect(auth_flow_mod.test_auth_flow.?.browser_redirect.callback_listener == null);
    try std.testing.expect(browser_open_capture.called);
    try std.testing.expectEqualStrings(
        "Local callback listener unavailable. Paste the callback URL manually, or Esc to cancel",
        state.status,
    );

    {
        state.mutex.lockUncancelable(state.io);
        defer state.mutex.unlock(state.io);
        try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "Could not start the local callback listener") != null);
    }

    try cancelAuthFlow(allocator, &auth_flow_mod.test_auth_flow, &state);
    try std.testing.expect(auth_flow_mod.test_auth_flow == null);
    try std.testing.expectEqualStrings("login cancelled", state.status);
}

test "beginLoginFlow starts OpenAI Codex OAuth subscription prompt state" {
    const allocator = std.testing.allocator;

    var oauth_callback_lock = try OAuthCallbackTestLock.acquire(std.testing.io);
    defer oauth_callback_lock.release(std.testing.io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    auth_flow_mod.test_auth_flow = null;
    defer if (auth_flow_mod.test_auth_flow) |*value| {
        value.deinit(allocator);
        auth_flow_mod.test_auth_flow = null;
    };
    var browser_open_capture = BrowserOpenCapture{};
    const previous_browser_open_context = auth_flow_mod.open_browser_context;
    const previous_browser_open_fn = auth_flow_mod.open_browser_fn;
    auth_flow_mod.open_browser_context = &browser_open_capture;
    auth_flow_mod.open_browser_fn = BrowserOpenCapture.capture;
    defer {
        auth_flow_mod.open_browser_context = previous_browser_open_context;
        auth_flow_mod.open_browser_fn = previous_browser_open_fn;
    }
    const previous_start_callback_listener_fn = auth_flow_mod.start_callback_listener_for_session_fn;
    auth_flow_mod.start_callback_listener_for_session_fn = startEphemeralCallbackListenerForTest;
    defer auth_flow_mod.start_callback_listener_for_session_fn = previous_start_callback_listener_fn;

    try beginLoginFlow(allocator, std.testing.io, &env_map, "openai-codex", .oauth, &state, &auth_flow_mod.test_auth_flow);
    auth_flow_mod.start_callback_listener_for_session_fn = previous_start_callback_listener_fn;

    try std.testing.expect(auth_flow_mod.test_auth_flow != null);
    try std.testing.expect(auth_flow_mod.test_auth_flow.? == .browser_redirect);
    try std.testing.expectEqual(auth.BrowserLoginKind.openai_codex, auth_flow_mod.test_auth_flow.?.browser_redirect.session.kind);
    try std.testing.expectEqualStrings("openai-codex", auth_flow_mod.test_auth_flow.?.browser_redirect.session.provider_id);
    try std.testing.expectEqualStrings(
        "ChatGPT Plus/Pro (Codex Subscription)",
        auth_flow_mod.test_auth_flow.?.browser_redirect.session.provider_name,
    );
    try std.testing.expect(auth_flow_mod.test_auth_flow.?.browser_redirect.callback_listener != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        auth_flow_mod.test_auth_flow.?.browser_redirect.callback_listener.?.redirect_uri,
        "/auth/callback",
    ));
    try std.testing.expect(browser_open_capture.called);
    try std.testing.expect(std.mem.indexOf(u8, browser_open_capture.url.?, "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback") != null);

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "ChatGPT Plus/Pro (Codex Subscription) login started") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[2].text, "auth.openai.com/oauth/authorize") != null);
}

test "beginLoginFlow gives google client config guidance without legacy oauth config path" {
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

    auth_flow_mod.test_auth_flow = null;
    defer if (auth_flow_mod.test_auth_flow) |*value| {
        value.deinit(allocator);
        auth_flow_mod.test_auth_flow = null;
    };

    try beginLoginFlow(allocator, std.testing.io, &env_map, "google-gemini-cli", null, &state, &auth_flow_mod.test_auth_flow);

    try std.testing.expect(auth_flow_mod.test_auth_flow == null);

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "oauth-clients.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "auth.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "legacy oauth.json is ignored") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "\"google-gemini-cli\"") != null);
}

test "beginLoginFlow starts google oauth flow with fake safe client config" {
    const allocator = std.testing.allocator;

    var oauth_callback_lock = try OAuthCallbackTestLock.acquire(std.testing.io);
    defer oauth_callback_lock.release(std.testing.io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);
    const client_config_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "oauth-clients.json" });
    defer allocator.free(client_config_path);
    try common.writeFileAbsolute(
        std.testing.io,
        client_config_path,
        \\{
        \\  "google-gemini-cli": {
        \\    "client_id": "fake-google-client",
        \\    "client_secret": "fake-google-secret"
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

    auth_flow_mod.test_auth_flow = null;
    defer if (auth_flow_mod.test_auth_flow) |*value| {
        value.deinit(allocator);
        auth_flow_mod.test_auth_flow = null;
    };
    var browser_open_capture = BrowserOpenCapture{};
    const previous_browser_open_context = auth_flow_mod.open_browser_context;
    const previous_browser_open_fn = auth_flow_mod.open_browser_fn;
    auth_flow_mod.open_browser_context = &browser_open_capture;
    auth_flow_mod.open_browser_fn = BrowserOpenCapture.capture;
    defer {
        auth_flow_mod.open_browser_context = previous_browser_open_context;
        auth_flow_mod.open_browser_fn = previous_browser_open_fn;
    }
    const previous_start_callback_listener_fn = auth_flow_mod.start_callback_listener_for_session_fn;
    auth_flow_mod.start_callback_listener_for_session_fn = startEphemeralCallbackListenerForTest;
    defer auth_flow_mod.start_callback_listener_for_session_fn = previous_start_callback_listener_fn;

    try beginLoginFlow(allocator, std.testing.io, &env_map, "google-gemini-cli", null, &state, &auth_flow_mod.test_auth_flow);
    auth_flow_mod.start_callback_listener_for_session_fn = previous_start_callback_listener_fn;

    try std.testing.expect(auth_flow_mod.test_auth_flow != null);
    try std.testing.expect(auth_flow_mod.test_auth_flow.? == .browser_redirect);
    try std.testing.expectEqual(auth.BrowserLoginKind.google_gemini_cli, auth_flow_mod.test_auth_flow.?.browser_redirect.session.kind);
    try std.testing.expectEqualStrings("google-gemini-cli", auth_flow_mod.test_auth_flow.?.browser_redirect.session.provider_id);
    try std.testing.expectEqualStrings("fake-google-client", auth_flow_mod.test_auth_flow.?.browser_redirect.session.oauth_client.client_id);
    try std.testing.expect(auth_flow_mod.test_auth_flow.?.browser_redirect.callback_listener != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        auth_flow_mod.test_auth_flow.?.browser_redirect.callback_listener.?.redirect_uri,
        "/oauth2callback",
    ));
    try std.testing.expect(browser_open_capture.called);
    try std.testing.expect(std.mem.indexOf(u8, browser_open_capture.url.?, "redirect_uri=http%3A%2F%2Flocalhost%3A8085%2Foauth2callback") != null);

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "Google Cloud Code Assist (Gemini CLI) login started") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[2].text, "accounts.google.com/o/oauth2/v2/auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[2].text, "client_id=fake-google-client") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[3].text, "Google Cloud project ID") != null);
}

test "beginLoginFlow starts API key prompt state for built-in provider" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    auth_flow_mod.test_auth_flow = null;
    defer if (auth_flow_mod.test_auth_flow) |*value| {
        value.deinit(allocator);
        auth_flow_mod.test_auth_flow = null;
    };

    try beginLoginFlow(allocator, std.testing.io, &env_map, "openai", null, &state, &auth_flow_mod.test_auth_flow);

    try std.testing.expect(auth_flow_mod.test_auth_flow != null);
    try std.testing.expect(auth_flow_mod.test_auth_flow.? == .api_key);
    try std.testing.expectEqualStrings("openai", auth_flow_mod.test_auth_flow.?.api_key.provider_id);

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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        .expires = 4102444800000,
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
            try std.testing.expectEqualStrings("Open settings menu", item.description.?);
        }
    }

    try std.testing.expect(saw_settings);
}

test "handleInputKey opens structured settings overlay and explicit raw settings editor" {
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .settings);
    try std.testing.expectEqualStrings("Settings", overlay.?.title());

    var saw_auto_compact = false;
    var saw_theme = false;
    var saw_editor_padding = false;
    var saw_raw_json = false;
    for (overlay.?.settings.items) |item| {
        if (std.mem.indexOf(u8, item.label, "Auto-compact") != null) saw_auto_compact = true;
        if (std.mem.indexOf(u8, item.label, "Theme") != null and
            std.mem.indexOf(u8, item.label, "dark") != null) saw_theme = true;
        if (std.mem.indexOf(u8, item.label, "Editor padding") != null and
            std.mem.indexOf(u8, item.label, "1") != null) saw_editor_padding = true;
        if (std.mem.indexOf(u8, item.label, "Advanced raw JSON") != null) saw_raw_json = true;
    }
    try std.testing.expect(saw_auto_compact);
    try std.testing.expect(saw_theme);
    try std.testing.expect(saw_editor_padding);
    try std.testing.expect(saw_raw_json);

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .{ .printable = tui.keys.PrintableKey.fromSlice("theme") },
        &session,
        &current_provider,
        options.session_dir,
        options,
        &.{},
        &state,
        &editor,
        &overlay,
        &auth_flow_mod.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );
    try std.testing.expectEqual(@as(usize, 1), overlay.?.settings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, overlay.?.settings.items[0].label, "Theme") != null);

    if (overlay) |*value| value.deinit(allocator);
    overlay = null;
    editor.reset();
    _ = try editor.handlePaste("/settings raw");

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
        &auth_flow_mod.test_auth_flow,
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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

test "theme slash command is registered switches immediately and persists selection" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "repo");
    defer allocator.free(root_dir);
    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime_config = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, root_dir);
    defer runtime_config.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

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

    const parsed = command_router.parseSlashCommand("/theme codex") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(command_router.SlashCommandKind.theme, parsed.kind);
    try std.testing.expectEqualStrings("codex", parsed.argument.?);

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    try slash_commands.handleThemeSlashCommand(
        allocator,
        std.testing.io,
        &env_map,
        root_dir,
        parsed.argument,
        &state,
        &overlay,
        &live_resources,
    );

    try std.testing.expectEqualStrings("codex", live_resources.theme.?.name);
    const saved = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, settings_path, allocator, .limited(1024 * 1024));
    defer allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"theme\": \"codex\"") != null);
}

test "theme overlay lists all themes with active marker and enter activates selection" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "repo");
    defer allocator.free(root_dir);
    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);
    const session_dir = try makeInteractiveTestPath(allocator, tmp, "sessions");
    defer allocator.free(session_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime_config = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, root_dir);
    defer runtime_config.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    try slash_commands.handleThemeSlashCommand(
        allocator,
        std.testing.io,
        &env_map,
        root_dir,
        null,
        &state,
        &overlay,
        &live_resources,
    );

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .theme);
    var saw_dark = false;
    var saw_light = false;
    var saw_codex = false;
    var light_index: usize = 0;
    for (overlay.?.theme.items, 0..) |item, index| {
        if (std.mem.eql(u8, item.value, "dark")) {
            saw_dark = true;
            try std.testing.expect(std.mem.indexOf(u8, item.label, "✓") != null);
        }
        if (std.mem.eql(u8, item.value, "light")) {
            saw_light = true;
            light_index = index;
        }
        if (std.mem.eql(u8, item.value, "codex")) saw_codex = true;
    }
    try std.testing.expect(saw_dark and saw_light and saw_codex);

    overlay.?.theme.list.setSelectedIndex(light_index);

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

    try handleInputKey(
        allocator,
        std.testing.io,
        &env_map,
        .enter,
        &session,
        &current_provider,
        session_dir,
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
    try std.testing.expectEqualStrings("light", live_resources.theme.?.name);
}

test "handleInputKey appends hotkeys markdown for slash hotkeys command" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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
    var hotkeys_item: ?rendering.ChatItem = null;
    for (state.items.items) |item| {
        if (item.kind == .markdown and std.mem.indexOf(u8, item.text, "Keyboard shortcuts") != null) {
            hotkeys_item = item;
            break;
        }
    }
    try std.testing.expect(hotkeys_item != null);
    try std.testing.expect(std.mem.indexOf(u8, hotkeys_item.?.text, "`/`") != null);
    try std.testing.expect(std.mem.indexOf(u8, hotkeys_item.?.text, "`!!`") != null);
}

test "handleInputKey opens model overlay for slash model command" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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

test "model slash exact match switches and persists default selection" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_dir = try makeInteractiveTestPath(allocator, tmp, "repo");
    defer allocator.free(root_dir);
    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);
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
    try env_map.put("OPENAI_API_KEY", "test-openai-key");

    var runtime_config = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, root_dir);
    defer runtime_config.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = try makeInteractiveTestPath(allocator, tmp, "sessions"),
        .provider = "faux",
        .runtime_config = &runtime_config,
    };
    defer allocator.free(options.session_dir);

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    try slash_commands.handleModelSlashCommand(
        allocator,
        &env_map,
        &session,
        &current_provider,
        "openai/gpt-5.4",
        options,
        &runtime_config,
        &state,
        &overlay,
    );

    try std.testing.expect(overlay == null);
    try std.testing.expectEqualStrings("openai", session.agent.getModel().provider);
    try std.testing.expectEqualStrings("gpt-5.4", session.agent.getModel().id);

    const saved = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, settings_path, allocator, .limited(1024 * 1024));
    defer allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"theme\": \"dark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"defaultProvider\": \"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"defaultModel\": \"gpt-5.4\"") != null);
}

test "model slash unmatched argument opens selector with initial search" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "test-openai-key");

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };

    var overlay: ?SelectorOverlay = null;
    defer if (overlay) |*value| value.deinit(allocator);
    try slash_commands.handleModelSlashCommand(
        allocator,
        &env_map,
        &session,
        &current_provider,
        "definitely-no-such-model",
        options,
        null,
        &state,
        &overlay,
    );

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .model);
    try std.testing.expect(std.mem.indexOf(u8, overlay.?.hint(), "definitely-no-such-model") != null);
    for (overlay.?.model.items) |item| {
        try std.testing.expect(std.mem.indexOf(u8, item.label, "definitely-no-such-model") != null or
            std.mem.indexOf(u8, item.description orelse "", "definitely-no-such-model") != null);
    }
    try std.testing.expectEqualStrings("faux", session.agent.getModel().provider);
    try std.testing.expectEqualStrings("faux-1", session.agent.getModel().id);
}

test "handleInputKey opens scoped model overlay for slash scoped-models command" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "test-openai-key");

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "openai", "gpt-5.4", null, null);
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
        &auth_flow_mod.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .scoped_models);
    try std.testing.expectEqualStrings("Scoped model selector", overlay.?.title());
    try std.testing.expect(overlay.?.scoped_models.enabled_ids != null);
    try std.testing.expectEqual(@as(usize, 2), overlay.?.scoped_models.enabled_ids.?.len);
    try std.testing.expectEqualStrings("openai/gpt-5.4", overlay.?.scoped_models.enabled_ids.?[0]);
    try std.testing.expectEqualStrings("openai/gpt-5.5", overlay.?.scoped_models.enabled_ids.?[1]);
    try std.testing.expectEqual(@as(usize, 0), editor.text().len);
}

test "handleInputKey scoped model overlay supports navigation and selection" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "test-openai-key");

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "openai", "gpt-5.4", null, null);
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
        &auth_flow_mod.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .scoped_models);

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
        &auth_flow_mod.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay.?.scoped_models.list.selectedIndex() < overlay.?.scoped_models.items.len);

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
        &auth_flow_mod.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .scoped_models);
}

test "handleInputKey reports when scoped models are not configured" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    try std.testing.expect(overlay != null);
    try std.testing.expect(overlay.? == .scoped_models);
}

test "handleInputKey reports unknown slash commands" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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
        &auth_flow_mod.test_auth_flow,
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
        &auth_flow_mod.test_auth_flow,
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
        &auth_flow_mod.test_auth_flow,
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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
        fn read(_: ?*anyopaque, alloc: std.mem.Allocator, io: std.Io, env_map: *const std.process.Environ.Map) !clipboard_image.ClipboardImageResult {
            _ = io;
            _ = env_map;
            return .{ .image = .{
                .bytes = try alloc.dupe(u8, &[_]u8{ 0x01, 0x02, 0x03 }),
                .mime_type = try alloc.dupe(u8, "image/png"),
            } };
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = cwd,
        .system_prompt = "sys",
    });
    defer session.deinit();

    try handleReloadSlashCommand(allocator, std.testing.io, &env_map, cwd, &session, &state, &live_resources);

    const reloaded_prompt = try live_resources.theme.?.applyAlloc(allocator, .prompt, "Input:");
    defer allocator.free(reloaded_prompt);
    try std.testing.expectEqualStrings("Input:", reloaded_prompt);

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expectEqualStrings("Reloaded keybindings, extensions, skills, prompts, and themes", state.status);
}

test "reload preserves startup explicit extension sources" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1"
        \\}
        ,
    });
    try writeInteractiveRegisteringExtensionScript(&tmp, "explicit.js", "explicit-tool", "Explicit Tool");

    const cwd = try makeInteractiveTestPath(allocator, tmp, ".");
    defer allocator.free(cwd);
    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const explicit_path = try makeInteractiveTestPath(allocator, tmp, "explicit.js");
    defer allocator.free(explicit_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime_config = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, cwd);
    defer runtime_config.deinit();

    var live_resources = LiveResources.init(.{
        .cwd = cwd,
        .system_prompt = "sys",
        .session_dir = agent_dir,
        .provider = "faux",
        .runtime_config = &runtime_config,
        .startup_cli_extensions = &.{explicit_path},
        .include_default_extensions = false,
    });
    defer live_resources.deinit(allocator);

    _ = try live_resources.reload(allocator, std.testing.io, &env_map, cwd);

    const bundle = &live_resources.owned_resource_bundle.?;
    try std.testing.expectEqual(@as(usize, 1), bundle.extensions.len);
    try std.testing.expectEqualStrings(explicit_path, bundle.extensions[0].path);
    try std.testing.expectEqual(resources_mod.SourceScope.temporary, bundle.extensions[0].source_info.scope);
}

test "reload slash command renders structured extension diagnostics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    const parse_script =
        "IFS= read -r init\n" ++
        "printf '{\"type\":\"ready\"}\\n'\n" ++
        "printf 'not-json\\n'\n" ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "parse.js", .data = parse_script });
    const runtime_script =
        "IFS= read -r init\n" ++
        "printf '{\"type\":\"ready\"}\\n'\n" ++
        "printf '{\"type\":\"diagnostic\",\"category\":\"host_error\",\"severity\":\"error\",\"message\":\"runtime failed\"}\\n'\n" ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "runtime.js", .data = runtime_script });
    try writeInteractiveRegisteringExtensionScript(&tmp, "denied.js", "denied-tool", "Denied Tool");

    const cwd = try makeInteractiveTestPath(allocator, tmp, "project");
    defer allocator.free(cwd);
    const agent_dir = try makeInteractiveTestPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const parse_path = try makeInteractiveTestPath(allocator, tmp, "parse.js");
    defer allocator.free(parse_path);
    const runtime_path = try makeInteractiveTestPath(allocator, tmp, "runtime.js");
    defer allocator.free(runtime_path);
    const denied_path = try makeInteractiveTestPath(allocator, tmp, "denied.js");
    defer allocator.free(denied_path);

    const parse_key = try temporaryTypeScriptPolicyKey(allocator, parse_path);
    defer allocator.free(parse_key);
    const runtime_key = try temporaryTypeScriptPolicyKey(allocator, runtime_path);
    defer allocator.free(runtime_key);
    const denied_key = try temporaryTypeScriptPolicyKey(allocator, denied_path);
    defer allocator.free(denied_key);
    var settings_writer: std.Io.Writer.Allocating = .init(allocator);
    defer settings_writer.deinit();
    try settings_writer.writer.print(
        "{{\n" ++
            "  \"defaultProvider\": \"faux\",\n" ++
            "  \"defaultModel\": \"faux-1\",\n" ++
            "  \"extensionPolicies\": {{\n" ++
            "    \"{s}\": {{ \"approvedGrants\": [\"tool.use\"], \"required\": true }},\n" ++
            "    \"{s}\": {{ \"approvedGrants\": [\"tool.use\"], \"required\": true }},\n" ++
            "    \"{s}\": {{ \"approvedGrants\": [], \"required\": true }}\n" ++
            "  }}\n" ++
            "}}\n",
        .{ parse_key, runtime_key, denied_key },
    );
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/settings.json", .data = settings_writer.written() });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    try env_map.put("PI_M1_EXTENSION_HOST_RUNTIME", "/bin/sh");
    try env_map.put("PI_M1_EXTENSION_DRAIN_TIMEOUT_MS", "1000");
    try env_map.put("PI_M2_EXTENSION_STARTUP_TIMEOUT_MS", "500");

    var runtime_config = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, cwd);
    defer runtime_config.deinit();

    var app_context = AppContext.init(cwd, std.testing.io);
    var initial_tools = try buildAgentToolsWithExtensionsSelection(allocator, &app_context, .{}, .{
        .extensions = &.{},
        .env_map = &env_map,
        .cwd = cwd,
        .io = std.testing.io,
        .runtime_config = &runtime_config,
    });
    errdefer initial_tools.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    errdefer current_provider.deinit(allocator);
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = cwd,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .tools = initial_tools.items,
    });
    errdefer session.deinit();

    var bootstrap = session_bootstrap.InteractiveBootstrap{
        .allocator = allocator,
        .current_provider = current_provider,
        .built_tools = initial_tools,
        .session = session,
    };
    defer bootstrap.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    var live_resources = LiveResources.init(.{
        .cwd = cwd,
        .system_prompt = "sys",
        .session_dir = agent_dir,
        .provider = "faux",
        .runtime_config = &runtime_config,
        .startup_cli_extensions = &.{ parse_path, denied_path, runtime_path },
        .include_default_extensions = false,
    });
    defer live_resources.deinit(allocator);

    var reload_tools_context = ReloadExtensionToolsContext{
        .bootstrap = &bootstrap,
        .app_context = &app_context,
        .options = .{
            .cwd = cwd,
            .system_prompt = "sys",
            .session_dir = agent_dir,
            .provider = "faux",
            .selected_tools = .{},
        },
        .app_state = &state,
    };
    live_resources.reload_extension_tools_sink = .{
        .context = &reload_tools_context,
        .callback = reloadExtensionToolsForInteractiveMode,
    };

    try handleReloadSlashCommand(allocator, std.testing.io, &env_map, cwd, &bootstrap.session, &state, &live_resources);

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);
    try std.testing.expect(appStateSnapshotContains(snapshot.items, "Reload extension lifecycle"));
    try std.testing.expect(appStateSnapshotContains(snapshot.items, "phase=parse"));
    try std.testing.expect(appStateSnapshotContains(snapshot.items, "category=malformed_json"));
    try std.testing.expect(appStateSnapshotContains(snapshot.items, "phase=policy"));
    try std.testing.expect(appStateSnapshotContains(snapshot.items, "required=true"));
    try std.testing.expect(appStateSnapshotContains(snapshot.items, "phase=runtime"));
    try std.testing.expect(appStateSnapshotContains(snapshot.items, "category=host_error"));

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expectEqualStrings("Reloaded keybindings, extensions, skills, prompts, and themes", state.status);
}

test "handleInputKey shows session stats for slash session command" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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

    var session_overlay = try loadSessionOverlay(allocator, std.testing.io, session_dir, session.session_manager.getSessionFile());
    defer session_overlay.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, session_overlay.session.items[0].label, "Night Shift") != null);

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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        &auth_flow_mod.test_auth_flow,
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
        &auth_flow_mod.test_auth_flow,
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
    try std.testing.expect(std.mem.indexOf(u8, footer, "Status:") == null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Provider:") == null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "↑11") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "↓7") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "R2") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "W1") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "$0.420") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "ctx 0.0%/128k") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Model:") == null);

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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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

    try handleCopySlashCommand(allocator, std.testing.io, &session, &state, null);
    try std.testing.expectEqualStrings("copied reply", capture.text.?);
}

test "handleCopySlashCommand supports last all visible and invalid scopes" {
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    defer session.deinit();

    var user = try makeInteractiveTestUserMessage("copy all prompt", 1);
    defer session_manager_mod.deinitMessage(allocator, &user);
    var assistant = try makeInteractiveTestAssistantMessage("copy all reply", current_provider.model, ai.Usage.init(), 2);
    defer session_manager_mod.deinitMessage(allocator, &assistant);
    var tool_result = agent.AgentMessage{ .tool_result = .{
        .role = try allocator.dupe(u8, "toolResult"),
        .tool_call_id = try allocator.dupe(u8, "tool-1"),
        .tool_name = try allocator.dupe(u8, "read"),
        .content = try common.makeTextContent(allocator, "tool output text"),
        .is_error = false,
        .details = null,
        .timestamp = 3,
    } };
    defer session_manager_mod.deinitMessage(allocator, &tool_result);
    _ = try session.session_manager.appendMessage(user);
    _ = try session.session_manager.appendMessage(assistant);
    _ = try session.session_manager.appendMessage(tool_result);
    _ = try session.session_manager.appendCustomMessageEntry(
        "bashExecution",
        .{ .text = "Ran `printf bash-output`\n```\nbash-output\n```" },
        true,
        null,
    );
    try session.agent.setMessages(&.{ user, assistant, tool_result });

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try rebuildAppStateFromSession(allocator, std.testing.io, &state, &session, &current_provider);

    try handleCopySlashCommand(allocator, std.testing.io, &session, &state, "last");
    try std.testing.expectEqualStrings("copy all reply", capture.text.?);

    try handleCopySlashCommand(allocator, std.testing.io, &session, &state, "all");
    try std.testing.expect(std.mem.indexOf(u8, capture.text.?, "### User") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text.?, "copy all prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text.?, "### Assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text.?, "copy all reply") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text.?, "### Tool Result") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text.?, "tool output text") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text.?, "### Bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text.?, "bash-output") != null);

    try rebuildAppStateFromSession(allocator, std.testing.io, &state, &session, &current_provider);
    state.updateChatScrollLayout(100, 100, 0, 80);
    try handleCopySlashCommand(allocator, std.testing.io, &session, &state, "visible");
    try std.testing.expect(std.mem.indexOf(u8, capture.text.?, "copy all reply") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text.?, "Provider:") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture.text.?, "Status:") == null);

    const before_invalid = try allocator.dupe(u8, capture.text.?);
    defer allocator.free(before_invalid);
    try handleCopySlashCommand(allocator, std.testing.io, &session, &state, "nonsense");
    try std.testing.expectEqualStrings(before_invalid, capture.text.?);
    try std.testing.expect(lastItemKindContains(&state, .@"error", "Usage: /copy [last|all|visible]"));
}

test "copyTextToClipboardWithFallback uses OSC52 then temp file" {
    const allocator = std.testing.allocator;

    const previous_context = slash_commands.clipboard_copy_context;
    const previous_fn = slash_commands.clipboard_copy_fn;
    slash_commands.clipboard_copy_context = null;
    slash_commands.clipboard_copy_fn = failingClipboardText;
    defer {
        slash_commands.clipboard_copy_context = previous_context;
        slash_commands.clipboard_copy_fn = previous_fn;
    }

    var osc_capture = ClipboardCapture{ .allocator = allocator };
    defer osc_capture.deinit();
    const previous_osc_context = slash_commands.osc52_write_context;
    const previous_osc_fn = slash_commands.osc52_write_fn;
    slash_commands.osc52_write_context = &osc_capture;
    slash_commands.osc52_write_fn = captureClipboardText;
    defer {
        slash_commands.osc52_write_context = previous_osc_context;
        slash_commands.osc52_write_fn = previous_osc_fn;
    }

    var outcome = try slash_commands.copyTextToClipboardWithFallback(allocator, std.testing.io, "osc payload");
    defer outcome.deinit(allocator);
    try std.testing.expectEqual(@as(std.meta.Tag(slash_commands.ClipboardCopyOutcome), .osc52), std.meta.activeTag(outcome));
    try std.testing.expect(osc_capture.text != null);
    try std.testing.expect(std.mem.startsWith(u8, osc_capture.text.?, "\x1b]52;c;"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const temp_path = try makeInteractiveTestPath(allocator, tmp, "copy-fallback.txt");
    defer allocator.free(temp_path);

    const previous_temp_override = slash_commands.copy_temp_file_override;
    slash_commands.copy_temp_file_override = temp_path;
    defer slash_commands.copy_temp_file_override = previous_temp_override;

    const oversized = try allocator.alloc(u8, 80_000);
    defer allocator.free(oversized);
    @memset(oversized, 'x');

    var temp_outcome = try slash_commands.copyTextToClipboardWithFallback(allocator, std.testing.io, oversized);
    defer temp_outcome.deinit(allocator);
    try std.testing.expectEqual(@as(std.meta.Tag(slash_commands.ClipboardCopyOutcome), .temp_file), std.meta.activeTag(temp_outcome));
    try std.testing.expectEqualStrings(temp_path, temp_outcome.temp_file);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, temp_path, allocator, .limited(100_000));
    defer allocator.free(written);
    try std.testing.expectEqualStrings(oversized, written);
}

fn expectShareTmpRemoved(path: []const u8) !void {
    if (std.Io.Dir.openFileAbsolute(std.testing.io, path, .{})) |file| {
        var owned = file;
        owned.close(std.testing.io);
        return error.TestUnexpectedShareTmpFileExists;
    } else |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    }
}

fn lastItemKindContains(state: *const AppState, kind: rendering.ChatKind, needle: []const u8) bool {
    var index = state.items.items.len;
    while (index > 0) {
        index -= 1;
        const item = state.items.items[index];
        if (item.kind != kind) continue;
        if (std.mem.indexOf(u8, item.text, needle) != null) return true;
        return false;
    }
    return false;
}

fn hasItemKind(state: *const AppState, kind: rendering.ChatKind) bool {
    for (state.items.items) |item| {
        if (item.kind == kind) return true;
    }
    return false;
}

const ShareGhStubInvocation = struct {
    argv: [][]u8,

    fn deinit(self: *ShareGhStubInvocation, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
    }
};

const ShareGhStubScript = struct {
    not_found: bool = false,
    exit_code: u8 = 0,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    return_error: ?anyerror = null,
};

const ShareGhStub = struct {
    allocator: std.mem.Allocator,
    auth: ShareGhStubScript = .{},
    gist: ShareGhStubScript = .{},
    invocations: std.ArrayList(ShareGhStubInvocation) = .empty,

    fn deinit(self: *ShareGhStub) void {
        for (self.invocations.items) |*invocation| invocation.deinit(self.allocator);
        self.invocations.deinit(self.allocator);
    }

    fn run(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        argv: []const []const u8,
    ) anyerror!slash_commands.ShareGhResult {
        const self: *ShareGhStub = @ptrCast(@alignCast(context.?));
        var stored_argv = try self.allocator.alloc([]u8, argv.len);
        errdefer self.allocator.free(stored_argv);
        for (argv, 0..) |arg, index| {
            stored_argv[index] = try self.allocator.dupe(u8, arg);
        }
        try self.invocations.append(self.allocator, .{ .argv = stored_argv });

        const script = if (argv.len >= 2 and std.mem.eql(u8, argv[1], "gist"))
            self.gist
        else
            self.auth;

        if (script.return_error) |err| return err;

        return slash_commands.ShareGhResult{
            .exit_code = script.exit_code,
            .stdout = try allocator.dupe(u8, script.stdout),
            .stderr = try allocator.dupe(u8, script.stderr),
            .not_found = script.not_found,
        };
    }
};

fn shareTestTmpFile(allocator: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
    const relative = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "session.html",
    });
    defer allocator.free(relative);
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative });
}

fn installShareTestStub(stub: *ShareGhStub, tmp_path: []const u8) struct {
    prev_run_fn: slash_commands.ShareGhRunFn,
    prev_run_ctx: ?*anyopaque,
    prev_tmp: ?[]const u8,
} {
    const prev_run_fn = slash_commands.share_gh_run_fn;
    const prev_run_ctx = slash_commands.share_gh_run_context;
    const prev_tmp = slash_commands.share_tmp_file_override;
    slash_commands.share_gh_run_fn = ShareGhStub.run;
    slash_commands.share_gh_run_context = stub;
    slash_commands.share_tmp_file_override = tmp_path;
    return .{ .prev_run_fn = prev_run_fn, .prev_run_ctx = prev_run_ctx, .prev_tmp = prev_tmp };
}

fn restoreShareTestStub(prev: anytype) void {
    slash_commands.share_gh_run_fn = prev.prev_run_fn;
    slash_commands.share_gh_run_context = prev.prev_run_ctx;
    slash_commands.share_tmp_file_override = prev.prev_tmp;
}

fn buildShareTestSession(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
) !struct {
    provider: provider_config.ResolvedProviderConfig,
    session: session_mod.AgentSession,
    user: agent.AgentMessage,
    assistant: agent.AgentMessage,
} {
    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, env_map, "faux", null, null, null);
    errdefer current_provider.deinit(allocator);
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
    });
    errdefer session.deinit();
    var user = try makeInteractiveTestUserMessage("share prompt", 1);
    errdefer session_manager_mod.deinitMessage(allocator, &user);
    var assistant = try makeInteractiveTestAssistantMessage("share reply", current_provider.model, ai.Usage.init(), 2);
    errdefer session_manager_mod.deinitMessage(allocator, &assistant);
    try session.agent.setMessages(&.{ user, assistant });
    return .{ .provider = current_provider, .session = session, .user = user, .assistant = assistant };
}

test "handleShareSlashCommand falls back to clipboard when gh not installed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_file = try shareTestTmpFile(allocator, tmp);
    defer allocator.free(tmp_file);

    var capture = ClipboardCapture{ .allocator = allocator };
    defer capture.deinit();
    const previous_clipboard_context = slash_commands.clipboard_copy_context;
    const previous_clipboard_fn = slash_commands.clipboard_copy_fn;
    slash_commands.clipboard_copy_context = &capture;
    slash_commands.clipboard_copy_fn = captureClipboardText;
    defer {
        slash_commands.clipboard_copy_context = previous_clipboard_context;
        slash_commands.clipboard_copy_fn = previous_clipboard_fn;
    }

    var stub = ShareGhStub{ .allocator = allocator, .auth = .{ .not_found = true } };
    defer stub.deinit();
    const prev = installShareTestStub(&stub, tmp_file);
    defer restoreShareTestStub(prev);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var built = try buildShareTestSession(allocator, &env_map);
    defer {
        session_manager_mod.deinitMessage(allocator, &built.assistant);
        session_manager_mod.deinitMessage(allocator, &built.user);
        built.session.deinit();
        built.provider.deinit(allocator);
    }

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try handleShareSlashCommand(allocator, std.testing.io, &env_map, &built.session, &state);

    // Only one gh invocation (auth status), no gist create
    try std.testing.expectEqual(@as(usize, 1), stub.invocations.items.len);
    // Clipboard should have been called with session markdown
    try std.testing.expect(capture.text != null);
    // Status should be "copied", not "share failed"
    try std.testing.expectEqualStrings("copied", state.status);
    // An info item (not error) about clipboard should be present
    try std.testing.expect(lastItemKindContains(&state, .info, "clipboard"));
    // tmp file must not exist (no HTML export was attempted)
    try expectShareTmpRemoved(tmp_file);
}

test "handleShareSlashCommand reports unauthenticated gh and cleans up" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_file = try shareTestTmpFile(allocator, tmp);
    defer allocator.free(tmp_file);

    var stub = ShareGhStub{
        .allocator = allocator,
        .auth = .{ .exit_code = 1, .stderr = "You are not logged into any GitHub hosts.\n" },
    };
    defer stub.deinit();
    const prev = installShareTestStub(&stub, tmp_file);
    defer restoreShareTestStub(prev);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var built = try buildShareTestSession(allocator, &env_map);
    defer {
        session_manager_mod.deinitMessage(allocator, &built.assistant);
        session_manager_mod.deinitMessage(allocator, &built.user);
        built.session.deinit();
        built.provider.deinit(allocator);
    }

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try handleShareSlashCommand(allocator, std.testing.io, &env_map, &built.session, &state);

    try std.testing.expectEqual(@as(usize, 1), stub.invocations.items.len);
    try std.testing.expect(lastItemKindContains(&state, .@"error", "gh auth login"));
    try expectShareTmpRemoved(tmp_file);
}

test "handleShareSlashCommand creates secret gist and uses default viewer URL" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_file = try shareTestTmpFile(allocator, tmp);
    defer allocator.free(tmp_file);

    var stub = ShareGhStub{
        .allocator = allocator,
        .auth = .{ .exit_code = 0, .stdout = "Logged in to github.com\n" },
        .gist = .{ .exit_code = 0, .stdout = "https://gist.github.com/octocat/abc123def456\n" },
    };
    defer stub.deinit();
    const prev = installShareTestStub(&stub, tmp_file);
    defer restoreShareTestStub(prev);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var built = try buildShareTestSession(allocator, &env_map);
    defer {
        session_manager_mod.deinitMessage(allocator, &built.assistant);
        session_manager_mod.deinitMessage(allocator, &built.user);
        built.session.deinit();
        built.provider.deinit(allocator);
    }

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try handleShareSlashCommand(allocator, std.testing.io, &env_map, &built.session, &state);

    try std.testing.expectEqual(@as(usize, 2), stub.invocations.items.len);
    const gist_invocation = stub.invocations.items[1];
    try std.testing.expectEqualStrings("gh", gist_invocation.argv[0]);
    try std.testing.expectEqualStrings("gist", gist_invocation.argv[1]);
    try std.testing.expectEqualStrings("create", gist_invocation.argv[2]);
    try std.testing.expectEqualStrings("--public=false", gist_invocation.argv[3]);
    try std.testing.expectEqualStrings(tmp_file, gist_invocation.argv[4]);

    try std.testing.expect(lastItemKindContains(&state, .info, "https://pi.dev/session/#abc123def456"));
    try std.testing.expect(lastItemKindContains(&state, .info, "https://gist.github.com/octocat/abc123def456"));
    try std.testing.expectEqualStrings("shared", state.status);
    try expectShareTmpRemoved(tmp_file);
}

test "handleShareSlashCommand honors PI_SHARE_VIEWER_URL override" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_file = try shareTestTmpFile(allocator, tmp);
    defer allocator.free(tmp_file);

    var stub = ShareGhStub{
        .allocator = allocator,
        .auth = .{ .exit_code = 0 },
        .gist = .{ .exit_code = 0, .stdout = "https://gist.github.com/user/zzz999\n" },
    };
    defer stub.deinit();
    const prev = installShareTestStub(&stub, tmp_file);
    defer restoreShareTestStub(prev);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_SHARE_VIEWER_URL", "https://share.example.com/v/");

    var built = try buildShareTestSession(allocator, &env_map);
    defer {
        session_manager_mod.deinitMessage(allocator, &built.assistant);
        session_manager_mod.deinitMessage(allocator, &built.user);
        built.session.deinit();
        built.provider.deinit(allocator);
    }

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try handleShareSlashCommand(allocator, std.testing.io, &env_map, &built.session, &state);

    try std.testing.expect(lastItemKindContains(&state, .info, "https://share.example.com/v/#zzz999"));
    try expectShareTmpRemoved(tmp_file);
}

test "handleShareSlashCommand surfaces gist creation failure and cleans up" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_file = try shareTestTmpFile(allocator, tmp);
    defer allocator.free(tmp_file);

    var stub = ShareGhStub{
        .allocator = allocator,
        .auth = .{ .exit_code = 0 },
        .gist = .{ .exit_code = 1, .stderr = "rate limit exceeded\n" },
    };
    defer stub.deinit();
    const prev = installShareTestStub(&stub, tmp_file);
    defer restoreShareTestStub(prev);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var built = try buildShareTestSession(allocator, &env_map);
    defer {
        session_manager_mod.deinitMessage(allocator, &built.assistant);
        session_manager_mod.deinitMessage(allocator, &built.user);
        built.session.deinit();
        built.provider.deinit(allocator);
    }

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try handleShareSlashCommand(allocator, std.testing.io, &env_map, &built.session, &state);

    try std.testing.expect(lastItemKindContains(&state, .@"error", "Failed to create gist"));
    try std.testing.expect(lastItemKindContains(&state, .@"error", "rate limit exceeded"));
    try std.testing.expect(!hasItemKind(&state, .info));
    try expectShareTmpRemoved(tmp_file);
}

test "handleShareSlashCommand rejects gh stdout without a parseable gist id" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_file = try shareTestTmpFile(allocator, tmp);
    defer allocator.free(tmp_file);

    var stub = ShareGhStub{
        .allocator = allocator,
        .auth = .{ .exit_code = 0 },
        .gist = .{ .exit_code = 0, .stdout = "no usable url here\n" },
    };
    defer stub.deinit();
    const prev = installShareTestStub(&stub, tmp_file);
    defer restoreShareTestStub(prev);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var built = try buildShareTestSession(allocator, &env_map);
    defer {
        session_manager_mod.deinitMessage(allocator, &built.assistant);
        session_manager_mod.deinitMessage(allocator, &built.user);
        built.session.deinit();
        built.provider.deinit(allocator);
    }

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try handleShareSlashCommand(allocator, std.testing.io, &env_map, &built.session, &state);

    try std.testing.expect(lastItemKindContains(&state, .@"error", "Failed to parse gist ID"));
    try std.testing.expect(!hasItemKind(&state, .info));
    try expectShareTmpRemoved(tmp_file);
}

test "handleShareSlashCommand clipboard fallback does not call gist create" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_file = try shareTestTmpFile(allocator, tmp);
    defer allocator.free(tmp_file);

    var capture = ClipboardCapture{ .allocator = allocator };
    defer capture.deinit();
    const previous_clipboard_context = slash_commands.clipboard_copy_context;
    const previous_clipboard_fn = slash_commands.clipboard_copy_fn;
    slash_commands.clipboard_copy_context = &capture;
    slash_commands.clipboard_copy_fn = captureClipboardText;
    defer {
        slash_commands.clipboard_copy_context = previous_clipboard_context;
        slash_commands.clipboard_copy_fn = previous_clipboard_fn;
    }

    var stub = ShareGhStub{
        .allocator = allocator,
        .auth = .{ .not_found = true },
    };
    defer stub.deinit();
    const prev = installShareTestStub(&stub, tmp_file);
    defer restoreShareTestStub(prev);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var built = try buildShareTestSession(allocator, &env_map);
    defer {
        session_manager_mod.deinitMessage(allocator, &built.assistant);
        session_manager_mod.deinitMessage(allocator, &built.user);
        built.session.deinit();
        built.provider.deinit(allocator);
    }

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try handleShareSlashCommand(allocator, std.testing.io, &env_map, &built.session, &state);

    // Clipboard fallback should have been called (gh not found)
    try std.testing.expect(capture.text != null);
    // Only auth status was invoked - no gist create
    try std.testing.expectEqual(@as(usize, 1), stub.invocations.items.len);
    // Should show copied status, not share failed
    try std.testing.expectEqualStrings("copied", state.status);
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

    var current_provider = try provider_config.resolveProviderConfig(allocator, std.testing.io, &env_map, "faux", null, null, null);
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
        std.testing.io,
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

fn appStateSnapshotContains(items: []const ChatItem, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.indexOf(u8, item.text, needle) != null) return true;
        if (item.expanded_text) |expanded_text| {
            if (std.mem.indexOf(u8, expanded_text, needle) != null) return true;
        }
    }
    return false;
}

fn temporaryTypeScriptPolicyKey(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const source_info = resources_mod.SourceInfo{
        .path = @constCast(path),
        .source = @constCast("local"),
        .scope = .temporary,
        .origin = .top_level,
        .base_dir = @constCast(std.fs.path.dirname(path) orelse "."),
    };
    return extension_runtime.typeScriptPolicyLookupKey(allocator, .{
        .configured_path = path,
        .resolved_path = path,
        .source_info = source_info,
    });
}

fn writeInteractiveRegisteringExtensionScript(tmp: anytype, sub_path: []const u8, tool_name: []const u8, label: []const u8) !void {
    var script: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer script.deinit();
    try script.writer.print(
        "IFS= read -r init\n" ++
            "printf '{{\"type\":\"ready\"}}\\n'\n" ++
            "printf '{{\"type\":\"register_tool\",\"name\":\"{s}\",\"label\":\"{s}\",\"description\":\"{s} description\",\"parameters\":{{\"type\":\"object\",\"properties\":{{}}}},\"extensionPath\":\"{s}\"}}\\n'\n" ++
            "while IFS= read -r line; do\n" ++
            "  case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac\n" ++
            "done\n",
        .{ tool_name, label, label, sub_path },
    );
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = script.written() });
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

const OAuthCallbackTestLock = struct {
    const path = ".zig-cache/oauth-callback-tests.lock";
    const max_attempts = 1200;
    const retry_delay_ms = 25;

    fn acquire(io: std.Io) !OAuthCallbackTestLock {
        try std.Io.Dir.createDirPath(.cwd(), io, ".zig-cache");
        var attempt: usize = 0;
        while (attempt < max_attempts) : (attempt += 1) {
            std.Io.Dir.createDir(.cwd(), io, path, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    _ = io.sleep(.fromMilliseconds(retry_delay_ms), .awake) catch {};
                    continue;
                },
                else => return err,
            };
            return .{};
        }
        return error.OAuthCallbackTestLockTimeout;
    }

    fn release(_: *OAuthCallbackTestLock, io: std.Io) void {
        std.Io.Dir.deleteDir(.cwd(), io, path) catch {};
    }
};

fn makeInteractiveAbsolutePath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

fn callbackProviderKindForTest(kind: auth.BrowserLoginKind) auth.OAuthCallbackProviderKind {
    return switch (kind) {
        .anthropic => .anthropic,
        .openai_codex => .openai_codex,
        .google_gemini_cli => .google_gemini_cli,
    };
}

fn startEphemeralCallbackListenerForTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    browser_session: *const auth.BrowserLoginSession,
) anyerror!*auth.OAuthCallbackListener {
    const listener = try auth.OAuthCallbackListener.createForTesting(
        allocator,
        io,
        callbackProviderKindForTest(browser_session.kind),
        browser_session.state,
        0,
    );
    errdefer listener.destroy();
    try listener.start();
    return listener;
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

fn failingClipboardText(context: ?*anyopaque, io: std.Io, text: []const u8) !void {
    _ = context;
    _ = io;
    _ = text;
    return error.ClipboardCommandFailed;
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

    try std.testing.expect(filtered.len > 0);
    for (filtered) |entry| {
        try std.testing.expectEqualStrings("anthropic", entry.provider);
        try std.testing.expect(std.mem.indexOf(u8, entry.model_id, "sonnet") != null);
    }
}
