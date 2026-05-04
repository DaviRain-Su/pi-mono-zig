const builtin = @import("builtin");
const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tui = @import("tui");
const auth = @import("../auth.zig");
const config_mod = @import("../config.zig");
const provider_config = @import("../provider_config.zig");
const resources_mod = @import("../resources.zig");
const session_mod = @import("../session.zig");
const session_advanced = @import("../session_advanced.zig");
const session_manager_mod = @import("../session_manager.zig");
const common = @import("../tools/common.zig");
const shared = @import("shared.zig");
const formatting = @import("formatting.zig");
const overlays = @import("overlays.zig");
const rendering = @import("rendering.zig");
const RunInteractiveModeOptions = shared.RunInteractiveModeOptions;
const LiveResources = shared.LiveResources;
const currentSessionLabel = shared.currentSessionLabel;
const configuredApiKeyForProvider = shared.configuredApiKeyForProvider;
const configuredCompactionSettings = shared.configuredCompactionSettings;
const configuredRetrySettings = shared.configuredRetrySettings;
const normalizePathArgument = shared.normalizePathArgument;
const overrideApiKeyForProvider = shared.overrideApiKeyForProvider;
const blocksToText = formatting.blocksToText;
const formatAssistantMessage = formatting.formatAssistantMessage;
const SelectorOverlay = overlays.SelectorOverlay;
const AuthFlow = overlays.AuthFlow;
const loadAuthOverlay = overlays.loadAuthOverlay;
const loadSelectableModels = overlays.loadSelectableModels;
const loadHotkeysOverlay = overlays.loadHotkeysOverlay;
const loadSettingsEditorOverlay = overlays.loadSettingsEditorOverlay;
const loadSessionOverlay = overlays.loadSessionOverlay;
const loadModelOverlay = overlays.loadModelOverlay;
const loadThemeOverlay = overlays.loadThemeOverlay;
const loadScopedModelOverlay = overlays.loadScopedModelOverlay;
const loadTreeOverlay = overlays.loadTreeOverlay;
const AppState = rendering.AppState;
const rebuildAppStateFromSession = rendering.rebuildAppStateFromSession;
const updateAppFooterFromSession = rendering.updateAppFooterFromSession;

pub const SlashCommandKind = enum {
    settings,
    model,
    theme,
    scoped_models,
    import,
    share,
    copy,
    name,
    hotkeys,
    label,
    session,
    changelog,
    tree,
    fork,
    clone,
    compact,
    login,
    logout,
    new,
    @"resume",
    reload,
    @"export",
    quit,
};

pub const SlashCommand = struct {
    kind: SlashCommandKind,
    argument: ?[]const u8 = null,
    raw: []const u8,
};

pub const BuiltinSlashCommand = struct {
    name: []const u8,
    description: []const u8,
    argument_hint: ?[]const u8 = null,
};

pub const BUILTIN_SLASH_COMMANDS = [_]BuiltinSlashCommand{
    .{ .name = "settings", .description = "Open settings editor" },
    .{ .name = "model", .description = "Select model (opens selector UI)", .argument_hint = "<provider/model>" },
    .{ .name = "theme", .description = "Switch active theme (no arg opens selector UI)", .argument_hint = "<name>" },
    .{ .name = "scoped-models", .description = "Select from the scoped model cycling list" },
    .{ .name = "export", .description = "Export session (HTML default, or specify path: .html/.jsonl/.json/.md)", .argument_hint = "<path.html|path.jsonl>" },
    .{ .name = "import", .description = "Import and resume a session from JSONL", .argument_hint = "<path.jsonl>" },
    .{ .name = "share", .description = "Upload session as a private GitHub gist with a shareable HTML link" },
    .{ .name = "copy", .description = "Copy last assistant message" },
    .{ .name = "name", .description = "Set session display name", .argument_hint = "<name>" },
    .{ .name = "session", .description = "Show session info and stats" },
    .{ .name = "changelog", .description = "Show CHANGELOG.md", .argument_hint = "<full|condensed>" },
    .{ .name = "hotkeys", .description = "Show keyboard shortcut help" },
    .{ .name = "fork", .description = "Create a new fork from the latest user message" },
    .{ .name = "clone", .description = "Duplicate the current session at the current position" },
    .{ .name = "tree", .description = "Navigate the session tree" },
    .{ .name = "login", .description = "Log into a provider", .argument_hint = "<provider>" },
    .{ .name = "logout", .description = "Remove stored authentication", .argument_hint = "<provider>" },
    .{ .name = "new", .description = "Start a fresh session" },
    .{ .name = "compact", .description = "Manually compact the session context", .argument_hint = "<instructions>" },
    .{ .name = "resume", .description = "Resume a different session" },
    .{ .name = "reload", .description = "Reload keybindings, skills, prompts, and themes" },
    .{ .name = "quit", .description = "Quit pi" },
};

pub fn createSeededSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    system_prompt: []const u8,
    model: ai.Model,
    api_key: ?[]const u8,
    thinking_level: agent.ThinkingLevel,
    tool_items: []const agent.AgentTool,
    compaction_settings: session_mod.CompactionSettings,
    retry_settings: session_mod.RetrySettings,
    session_dir: ?[]const u8,
    messages: []const agent.AgentMessage,
) !session_mod.AgentSession {
    var session = try session_mod.AgentSession.create(allocator, io, .{
        .cwd = cwd,
        .system_prompt = system_prompt,
        .model = model,
        .api_key = api_key,
        .thinking_level = thinking_level,
        .session_dir = session_dir,
        .tools = tool_items,
        .compaction = compaction_settings,
        .retry = retry_settings,
    });
    errdefer session.deinit();

    for (messages) |message| {
        _ = try session.session_manager.appendMessage(message);
    }
    try session.agent.setMessages(messages);

    return session;
}

pub fn parseSlashCommand(text: []const u8) ?SlashCommand {
    if (text.len < 2 or text[0] != '/') return null;

    const space_index = std.mem.indexOfAny(u8, text, " \t\r\n");
    const command_name = if (space_index) |index| text[1..index] else text[1..];
    const raw_argument = if (space_index) |index|
        std.mem.trim(u8, text[index + 1 ..], " \t\r\n")
    else
        "";
    const argument = if (raw_argument.len == 0) null else raw_argument;

    if (std.mem.eql(u8, command_name, "settings")) return .{ .kind = .settings, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "model")) return .{ .kind = .model, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "theme")) return .{ .kind = .theme, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "scoped-models")) return .{ .kind = .scoped_models, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "import")) return .{ .kind = .import, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "share")) return .{ .kind = .share, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "copy")) return .{ .kind = .copy, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "name")) return .{ .kind = .name, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "hotkeys")) return .{ .kind = .hotkeys, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "label")) return .{ .kind = .label, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "session")) return .{ .kind = .session, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "changelog")) return .{ .kind = .changelog, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "tree")) return .{ .kind = .tree, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "fork")) return .{ .kind = .fork, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "clone")) return .{ .kind = .clone, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "compact")) return .{ .kind = .compact, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "login")) return .{ .kind = .login, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "logout")) return .{ .kind = .logout, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "new")) return .{ .kind = .new, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "resume")) return .{ .kind = .@"resume", .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "reload")) return .{ .kind = .reload, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "export")) return .{ .kind = .@"export", .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "quit")) return .{ .kind = .quit, .argument = argument, .raw = text };
    return null;
}

pub fn handleSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    command: SlashCommand,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    live_resources: *LiveResources,
) !void {
    switch (command.kind) {
        .settings => try handleSettingsSlashCommand(
            allocator,
            io,
            session,
            app_state,
            overlay,
            live_resources,
        ),
        .model => try handleModelSlashCommand(
            allocator,
            env_map,
            session,
            current_provider,
            command.argument,
            options,
            live_resources.runtime_config,
            app_state,
            overlay,
        ),
        .theme => try handleThemeSlashCommand(
            allocator,
            io,
            env_map,
            options.cwd,
            command.argument,
            app_state,
            overlay,
            live_resources,
        ),
        .scoped_models => try handleScopedModelsSlashCommand(
            allocator,
            env_map,
            session,
            current_provider,
            options,
            live_resources.runtime_config,
            app_state,
            overlay,
        ),
        .import => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before importing a session");
                return;
            }
            try handleImportSlashCommand(
                allocator,
                io,
                env_map,
                session,
                current_provider,
                command.argument,
                options,
                live_resources.runtime_config,
                tool_items,
                app_state,
                subscriber,
            );
        },
        .share => try handleShareSlashCommand(allocator, io, env_map, session, app_state),
        .copy => try handleCopySlashCommand(allocator, io, session, app_state),
        .name => try handleNameSlashCommand(allocator, session, command.argument, app_state),
        .hotkeys => overlay.* = try loadHotkeysOverlay(allocator, live_resources.keybindings),
        .label => try handleLabelSlashCommand(allocator, session, command.argument, app_state),
        .session => try handleSessionSlashCommand(allocator, session, app_state),
        .changelog => try handleChangelogSlashCommand(allocator, io, session, command.argument, app_state),
        .tree => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before opening the session tree");
                return;
            }
            overlay.* = try loadTreeOverlay(allocator, session);
        },
        .fork => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before forking the session");
                return;
            }
            try forkCurrentSession(
                allocator,
                io,
                session,
                current_provider,
                session_dir,
                tool_items,
                app_state,
                subscriber,
            );
        },
        .clone => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before cloning the session");
                return;
            }
            try cloneCurrentSession(
                allocator,
                io,
                session,
                current_provider,
                session_dir,
                tool_items,
                app_state,
                subscriber,
            );
        },
        .compact => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before compacting the session");
                return;
            }
            try handleCompactSlashCommand(allocator, session, command.argument, app_state);
        },
        .login => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before logging in");
                return;
            }
            try handleLoginSlashCommand(
                allocator,
                io,
                env_map,
                command.argument,
                app_state,
                overlay,
                auth_flow,
            );
        },
        .logout => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before logging out");
                return;
            }
            try handleLogoutSlashCommand(
                allocator,
                io,
                env_map,
                session,
                current_provider,
                command.argument,
                options,
                app_state,
                overlay,
                live_resources,
            );
        },
        .new => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before starting a new session");
                return;
            }
            try handleNewSlashCommand(
                allocator,
                io,
                session,
                current_provider,
                session_dir,
                options,
                tool_items,
                app_state,
                subscriber,
            );
        },
        .@"resume" => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before switching sessions");
                return;
            }
            overlay.* = try loadSessionOverlay(allocator, io, session_dir);
        },
        .reload => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before reloading resources");
                return;
            }
            try handleReloadSlashCommand(allocator, io, env_map, options.cwd, app_state, live_resources);
        },
        .@"export" => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before exporting the session");
                return;
            }
            try handleExportSlashCommand(allocator, io, session, command.argument, app_state);
        },
        .quit => {
            should_exit.* = true;
            if (prompt_worker_active.*) session.agent.abort();
        },
    }
}

pub fn switchSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_path: []const u8,
    options: RunInteractiveModeOptions,
    runtime_config: ?*const config_mod.RuntimeConfig,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    subscriber: agent.AgentSubscriber,
) !void {
    var candidate = try session_mod.AgentSession.open(allocator, io, .{
        .session_file = session_path,
        .cwd_override = options.cwd,
        .system_prompt = options.system_prompt,
        .tools = tool_items,
        .thinking_level = options.thinking,
        .compaction = configuredCompactionSettings(runtime_config),
        .retry = configuredRetrySettings(runtime_config),
    });
    errdefer candidate.deinit();

    var candidate_provider = provider_config.resolveProviderConfig(
        allocator,
        io,
        env_map,
        candidate.agent.getModel().provider,
        candidate.agent.getModel().id,
        overrideApiKeyForProvider(options, candidate.agent.getModel().provider),
        configuredApiKeyForProvider(runtime_config, candidate.agent.getModel().provider),
    ) catch |err| {
        try presentProviderSelectionError(
            allocator,
            app_state,
            provider_config.resolveProviderErrorMessage(err, candidate.agent.getModel().provider),
            "session switch failed",
        );
        return;
    };
    errdefer candidate_provider.deinit(allocator);

    candidate.setApiKey(candidate_provider.api_key);

    _ = session.agent.unsubscribe(subscriber);
    session.deinit();
    current_provider.deinit(allocator);

    session.* = candidate;
    current_provider.* = candidate_provider;
    try session.agent.subscribe(subscriber);

    try rebuildAppStateFromSession(allocator, session.io, app_state, session, current_provider);
}

pub fn switchModel(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    provider_name: []const u8,
    model_id: []const u8,
    options: RunInteractiveModeOptions,
    runtime_config: ?*const config_mod.RuntimeConfig,
    app_state: *AppState,
) !void {
    var next_provider = provider_config.resolveProviderConfig(
        allocator,
        session.io,
        env_map,
        provider_name,
        model_id,
        overrideApiKeyForProvider(options, provider_name),
        configuredApiKeyForProvider(runtime_config, provider_name),
    ) catch |err| {
        try presentProviderSelectionError(
            allocator,
            app_state,
            provider_config.resolveProviderErrorMessage(err, provider_name),
            "model switch failed",
        );
        return;
    };
    errdefer next_provider.deinit(allocator);

    current_provider.deinit(allocator);
    current_provider.* = next_provider;
    try session.setModel(next_provider.model);
    session.setApiKey(next_provider.api_key);
    try updateAppFooterFromSession(allocator, session.io, app_state, session, current_provider);
    try app_state.setStatus("idle");
}

fn presentProviderSelectionError(
    allocator: std.mem.Allocator,
    app_state: *AppState,
    detail: []const u8,
    status: []const u8,
) !void {
    _ = status;
    const owned = try allocator.dupe(u8, detail);
    defer allocator.free(owned);
    try app_state.appendError(owned);
}

pub fn handleModelSlashCommand(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    argument: ?[]const u8,
    options: RunInteractiveModeOptions,
    runtime_config: ?*const config_mod.RuntimeConfig,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
) !void {
    const search = argument orelse {
        overlay.* = try loadModelOverlay(allocator, env_map, session.agent.getModel(), current_provider, options.model_patterns, runtime_config);
        return;
    };

    const available = try loadSelectableModels(allocator, env_map, session.agent.getModel(), current_provider, options.model_patterns, runtime_config);
    defer allocator.free(available);

    for (available) |entry| {
        const scoped = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.provider, entry.model_id });
        defer allocator.free(scoped);
        if (!std.mem.eql(u8, search, entry.model_id) and
            !std.mem.eql(u8, search, scoped) and
            !std.mem.eql(u8, search, entry.display_name))
        {
            continue;
        }

        try switchModel(
            allocator,
            env_map,
            session,
            current_provider,
            entry.provider,
            entry.model_id,
            options,
            runtime_config,
            app_state,
        );
        return;
    }

    const message = try std.fmt.allocPrint(allocator, "No exact model match for {s}; opening model selector", .{search});
    defer allocator.free(message);
    try app_state.appendInfo(message);
    overlay.* = try loadModelOverlay(allocator, env_map, session.agent.getModel(), current_provider, options.model_patterns, runtime_config);
}

pub fn handleThemeSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    argument: ?[]const u8,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    live_resources: *LiveResources,
) !void {
    try live_resources.ensureOwnedBundle(allocator, io, env_map, cwd);

    if (argument) |raw_name| {
        try applyThemeByName(allocator, io, env_map, cwd, raw_name, app_state, live_resources);
        return;
    }

    const bundle = &live_resources.owned_resource_bundle.?;
    overlay.* = try loadThemeOverlay(allocator, bundle.themes, live_resources.theme);
}

pub fn applyThemeByName(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    raw_name: []const u8,
    app_state: *AppState,
    live_resources: *LiveResources,
) !void {
    const theme_name = std.mem.trim(u8, raw_name, " \t\r\n");
    if (theme_name.len == 0) {
        try app_state.appendError("Usage: /theme <name>");
        return;
    }

    live_resources.applyTheme(allocator, io, env_map, cwd, theme_name) catch |err| switch (err) {
        error.ThemeNotFound => {
            const message = try std.fmt.allocPrint(allocator, "Unknown theme `{s}`", .{theme_name});
            defer allocator.free(message);
            try app_state.appendError(message);
            return;
        },
        else => return err,
    };

    const runtime_config = live_resources.runtime_config orelse {
        try app_state.setStatus("theme switched for this session");
        return;
    };
    try persistGlobalThemeSelection(allocator, io, runtime_config, theme_name);
    try replaceRuntimeSettingsTheme(allocator, &live_resources.owned_runtime_config.?, theme_name);

    const active_theme_name = if (live_resources.theme) |theme| theme.name else theme_name;
    const message = try std.fmt.allocPrint(allocator, "Theme switched to {s}", .{active_theme_name});
    defer allocator.free(message);
    try app_state.setStatus(message);
}

fn persistGlobalThemeSelection(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_config: *const config_mod.RuntimeConfig,
    theme_name: []const u8,
) !void {
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ runtime_config.agent_dir, "settings.json" });
    defer allocator.free(settings_path);

    const content = std.Io.Dir.readFileAlloc(.cwd(), io, settings_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (content) |value| allocator.free(value);

    var next_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const next_value: std.json.Value = .{ .object = next_object };
        common.deinitJsonValue(allocator, next_value);
    }

    if (content) |settings_content| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, settings_content, .{}) catch null;
        defer if (parsed) |*value| value.deinit();
        if (parsed) |parsed_value| {
            if (parsed_value.value == .object) {
                var iterator = parsed_value.value.object.iterator();
                while (iterator.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "theme")) continue;
                    try next_object.put(
                        allocator,
                        try allocator.dupe(u8, entry.key_ptr.*),
                        try common.cloneJsonValue(allocator, entry.value_ptr.*),
                    );
                }
            }
        }
    }

    try next_object.put(
        allocator,
        try allocator.dupe(u8, "theme"),
        .{ .string = try allocator.dupe(u8, theme_name) },
    );

    const next_value: std.json.Value = .{ .object = next_object };
    defer common.deinitJsonValue(allocator, next_value);

    const serialized = try std.json.Stringify.valueAlloc(allocator, next_value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    try common.writeFileAbsolute(io, settings_path, serialized, true);
}

fn replaceRuntimeSettingsTheme(
    allocator: std.mem.Allocator,
    runtime_config: *config_mod.RuntimeConfig,
    theme_name: []const u8,
) !void {
    const next_global = try allocator.dupe(u8, theme_name);
    errdefer allocator.free(next_global);
    const next_effective = try allocator.dupe(u8, theme_name);
    errdefer allocator.free(next_effective);

    if (runtime_config.global_settings.theme) |old| allocator.free(old);
    runtime_config.global_settings.theme = next_global;
    if (runtime_config.settings.theme) |old| allocator.free(old);
    runtime_config.settings.theme = next_effective;
}

pub fn handleScopedModelsSlashCommand(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    options: RunInteractiveModeOptions,
    runtime_config: ?*const config_mod.RuntimeConfig,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
) !void {
    overlay.* = loadScopedModelOverlay(
        allocator,
        env_map,
        session.agent.getModel(),
        current_provider,
        options.model_patterns,
        runtime_config,
    ) catch |err| switch (err) {
        error.NoScopedModelPatterns => {
            try app_state.setStatus("No scoped models configured. Launch pi with --models to limit model cycling.");
            return;
        },
        error.NoScopedModelsAvailable => {
            try app_state.setStatus("No scoped models matched the current model scope.");
            return;
        },
        else => return err,
    };
}

pub fn handleSessionSlashCommand(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    app_state: *AppState,
) !void {
    const info = try formatSessionInfo(allocator, session);
    defer allocator.free(info);
    try app_state.appendInfo(info);
}

pub const ChangelogView = enum {
    full,
    condensed,
};

pub fn handleChangelogSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const session_mod.AgentSession,
    argument: ?[]const u8,
    app_state: *AppState,
) !void {
    const view = parseChangelogView(argument) catch {
        try app_state.appendError("Usage: /changelog [full|condensed]");
        return;
    };

    const markdown = buildChangelogMarkdown(allocator, io, session.cwd, view) catch |err| switch (err) {
        error.FileNotFound => {
            try app_state.appendError("CHANGELOG.md not found");
            return;
        },
        else => return err,
    };
    defer allocator.free(markdown);

    try app_state.appendMarkdown(markdown);

    const status = try std.fmt.allocPrint(allocator, "showing {s} changelog", .{@tagName(view)});
    defer allocator.free(status);
    try app_state.setStatus(status);
}

pub fn parseChangelogView(argument: ?[]const u8) !ChangelogView {
    const raw = argument orelse return .full;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, value, "full")) return .full;
    if (std.mem.eql(u8, value, "condensed")) return .condensed;
    return error.InvalidChangelogView;
}

pub fn buildChangelogMarkdown(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    view: ChangelogView,
) ![]u8 {
    const changelog_path = try resolveChangelogPath(allocator, io, cwd) orelse return error.FileNotFound;
    defer allocator.free(changelog_path);

    const content = try std.Io.Dir.readFileAlloc(.cwd(), io, changelog_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(content);

    switch (view) {
        .full => return allocator.dupe(u8, content),
        .condensed => {
            if (extractLatestVersionSection(content)) |section| {
                return allocator.dupe(u8, section);
            }
            return allocator.dupe(u8, content);
        },
    }
}

pub fn resolveChangelogPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
) !?[]u8 {
    var current = try allocator.dupe(u8, cwd);
    errdefer allocator.free(current);

    while (true) {
        const package_candidate = try std.fs.path.join(allocator, &[_][]const u8{ current, "packages/coding-agent/CHANGELOG.md" });
        if (pathExists(io, package_candidate)) {
            allocator.free(current);
            return package_candidate;
        }
        allocator.free(package_candidate);

        const local_candidate = try std.fs.path.join(allocator, &[_][]const u8{ current, "CHANGELOG.md" });
        if (pathExists(io, local_candidate)) {
            allocator.free(current);
            return local_candidate;
        }
        allocator.free(local_candidate);

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    allocator.free(current);

    const source_dir = std.fs.path.dirname(@src().file) orelse ".";
    const fallback = try std.fs.path.resolve(allocator, &[_][]const u8{
        source_dir,
        "../../../../packages/coding-agent/CHANGELOG.md",
    });
    if (pathExists(io, fallback)) return fallback;
    allocator.free(fallback);
    return null;
}

pub fn findNearestRelativeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_dir: []const u8,
    relative_path: []const u8,
) !?[]u8 {
    var current = try allocator.dupe(u8, start_dir);
    errdefer allocator.free(current);

    while (true) {
        const candidate = try std.fs.path.join(allocator, &[_][]const u8{ current, relative_path });
        if (pathExists(io, candidate)) {
            allocator.free(current);
            return candidate;
        }
        allocator.free(candidate);

        const parent = std.fs.path.dirname(current) orelse {
            allocator.free(current);
            return null;
        };
        if (std.mem.eql(u8, parent, current)) {
            allocator.free(current);
            return null;
        }

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

pub fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch return false;
    return true;
}

pub fn extractLatestVersionSection(content: []const u8) ?[]const u8 {
    var offset: usize = 0;
    var current_start: ?usize = null;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const line_start = offset;
        offset += line.len + 1;
        const trimmed = trimCarriageReturn(line);
        if (!isVersionHeading(trimmed)) continue;

        if (current_start) |start| {
            return trimTrailingNewlines(content[start..line_start]);
        }
        current_start = line_start;
    }

    if (current_start) |start| {
        return trimTrailingNewlines(content[start..]);
    }
    return null;
}

pub fn isVersionHeading(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "## ")) return false;

    var index: usize = 3;
    while (index < line.len and line[index] == ' ') : (index += 1) {}
    if (index < line.len and line[index] == '[') index += 1;

    const first_len = consumeDigits(line, index);
    if (first_len == 0) return false;
    index += first_len;
    if (index >= line.len or line[index] != '.') return false;
    index += 1;

    const second_len = consumeDigits(line, index);
    if (second_len == 0) return false;
    index += second_len;
    if (index >= line.len or line[index] != '.') return false;
    index += 1;

    const third_len = consumeDigits(line, index);
    if (third_len == 0) return false;
    index += third_len;

    if (index < line.len and line[index] == ']') index += 1;
    return true;
}

fn consumeDigits(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
    return index - start;
}

fn trimCarriageReturn(text: []const u8) []const u8 {
    if (text.len > 0 and text[text.len - 1] == '\r') return text[0 .. text.len - 1];
    return text;
}

fn trimTrailingNewlines(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r')) : (end -= 1) {}
    return text[0..end];
}

pub fn handleNameSlashCommand(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    argument: ?[]const u8,
    app_state: *AppState,
) !void {
    const name = argument orelse {
        const current_name = session.session_manager.getSessionName() orelse {
            try app_state.appendInfo("Usage: /name <name>");
            return;
        };
        const message = try std.fmt.allocPrint(allocator, "Session name: {s}", .{current_name});
        defer allocator.free(message);
        try app_state.appendInfo(message);
        return;
    };

    _ = try session.session_manager.appendSessionInfo(name);
    try app_state.setFooter(session.agent.getModel().id, currentSessionLabel(session));

    const message = try std.fmt.allocPrint(allocator, "Session name set: {s}", .{currentSessionLabel(session)});
    defer allocator.free(message);
    try app_state.appendInfo(message);
}

pub fn handleLabelSlashCommand(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    argument: ?[]const u8,
    app_state: *AppState,
) !void {
    const target_id = resolveCurrentLabelTargetId(session) orelse {
        try app_state.setStatus("No current session entry to label");
        return;
    };

    _ = try session.session_manager.appendLabelChange(target_id, argument);

    if (session.session_manager.getLabel(target_id)) |label| {
        const message = try std.fmt.allocPrint(allocator, "Label set: {s}", .{label});
        defer allocator.free(message);
        try app_state.appendInfo(message);
        try app_state.setStatus("label updated");
        return;
    }

    try app_state.appendInfo("Label cleared");
    try app_state.setStatus("label cleared");
}

pub fn resolveCurrentLabelTargetId(session: *const session_mod.AgentSession) ?[]const u8 {
    var target_id = session.session_manager.getLeafId() orelse return null;
    var remaining = session.session_manager.getEntries().len + 1;
    while (remaining > 0) : (remaining -= 1) {
        const entry = session.session_manager.getEntry(target_id) orelse return null;
        switch (entry.*) {
            .label => |label_entry| target_id = label_entry.target_id,
            else => return target_id,
        }
    }
    return null;
}

pub fn handleCompactSlashCommand(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    argument: ?[]const u8,
    app_state: *AppState,
) !void {
    const result = session.compact(argument) catch |err| switch (err) {
        error.NothingToCompact => {
            try app_state.setStatus("Nothing to compact yet");
            return;
        },
        else => return err,
    };

    const info = try std.fmt.allocPrint(
        allocator,
        "Compacted session history. Summary preserved {d} tokens before entry {s}.",
        .{ result.tokens_before, result.first_kept_entry_id },
    );
    defer allocator.free(info);
    try rebuildAppStateFromSession(allocator, session.io, app_state, session, null);
    try app_state.appendInfo(info);
}

pub fn handleLoginSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argument: ?[]const u8,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
) !void {
    if (argument) |provider_id| {
        try beginLoginFlow(allocator, io, env_map, provider_id, null, app_state, auth_flow);
        return;
    }
    overlay.* = try loadAuthOverlay(allocator, .login, null);
}

pub fn beginLoginFlow(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    provider_id: []const u8,
    auth_type: ?auth.ProviderAuthType,
    app_state: *AppState,
    auth_flow: *?AuthFlow,
) !void {
    const provider = if (auth_type) |value|
        auth.findSupportedProviderByAuthType(provider_id, value)
    else
        auth.findSupportedProvider(provider_id);
    if (provider) |resolved_provider| {
        if (auth_flow.*) |*existing| existing.deinit(allocator);
        auth_flow.* = null;

        if (resolved_provider.auth_type == .api_key) {
            const intro = try std.fmt.allocPrint(
                allocator,
                "{s} API key login started. Paste the API key or credential string into the prompt below.",
                .{resolved_provider.name},
            );
            defer allocator.free(intro);
            try app_state.appendInfo(intro);
            try app_state.setStatus("Paste the API key and press Enter, or Esc to cancel");
            auth_flow.* = .{ .api_key = .{
                .provider_id = resolved_provider.id,
                .provider_name = resolved_provider.name,
            } };
            return;
        }

        if (std.mem.eql(u8, resolved_provider.id, "github-copilot")) {
            const copilot = auth.startGitHubCopilotLogin(allocator, io, env_map) catch |err| {
                if (try auth.formatOAuthClientConfigError(allocator, env_map, resolved_provider.id, err)) |message| {
                    defer allocator.free(message);
                    try app_state.appendError(message);
                    return;
                }
                return err;
            };
            openBrowserBestEffort(io, copilot.verification_uri);

            const intro = try std.fmt.allocPrint(
                allocator,
                "GitHub Copilot login started. Open {s} and enter code `{s}`.",
                .{ copilot.verification_uri, copilot.user_code },
            );
            defer allocator.free(intro);
            try app_state.appendInfo(intro);
            try app_state.setStatus("Finish the browser login, then press Enter to complete authentication");
            auth_flow.* = .{ .copilot_device = copilot };
            return;
        }

        const browser_session = auth.startBrowserLogin(allocator, io, env_map, resolved_provider.id) catch |err| {
            if (try auth.formatOAuthClientConfigError(allocator, env_map, resolved_provider.id, err)) |message| {
                defer allocator.free(message);
                try app_state.appendError(message);
                return;
            }
            return err;
        };
        openBrowserBestEffort(io, browser_session.auth_url);

        const intro = try std.fmt.allocPrint(
            allocator,
            "{s} login started. Open the browser URL below. If the localhost callback page says connection refused, copy that full address-bar URL and paste it into the prompt.",
            .{resolved_provider.name},
        );
        defer allocator.free(intro);
        try app_state.appendInfo(intro);
        try app_state.appendInfo(browser_session.auth_url);
        if (browser_session.kind == .google_gemini_cli) {
            try app_state.appendInfo("You will be prompted for a Google Cloud project ID after the redirect is accepted.");
        }
        try app_state.setStatus("Paste the localhost callback URL and press Enter, or Esc to cancel");
        auth_flow.* = .{ .browser_redirect = .{ .session = browser_session } };
        return;
    }

    const message = try std.fmt.allocPrint(allocator, "Unsupported login provider: {s}", .{provider_id});
    defer allocator.free(message);
    try app_state.appendError(message);
}

pub fn cancelAuthFlow(
    allocator: std.mem.Allocator,
    auth_flow: *?AuthFlow,
    app_state: *AppState,
) !void {
    if (auth_flow.*) |*value| {
        value.deinit(allocator);
        auth_flow.* = null;
    }
    try app_state.setStatus("login cancelled");
}

pub fn submitAuthFlowInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    trimmed: []const u8,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    editor: *tui.Editor,
    auth_flow: *?AuthFlow,
    live_resources: *LiveResources,
) !void {
    const active = auth_flow.* orelse return;
    switch (active) {
        .browser_redirect => |redirect| {
            if (trimmed.len == 0) {
                try app_state.setStatus("Paste the redirect URL before pressing Enter");
                return;
            }

            switch (redirect.session.kind) {
                .anthropic => {
                    var credential = try auth.completeBrowserLogin(allocator, io, &redirect.session, trimmed);
                    defer credential.deinit(allocator);
                    try persistLoginCredential(
                        allocator,
                        io,
                        env_map,
                        session,
                        current_provider,
                        redirect.session.provider_id,
                        redirect.session.provider_name,
                        &credential,
                        options,
                        app_state,
                        auth_flow,
                        live_resources,
                    );
                },
                .google_gemini_cli => {
                    const exchange = try auth.exchangeGoogleAuthorizationCode(allocator, io, &redirect.session, trimmed);
                    if (auth_flow.*) |*value| value.deinit(allocator);
                    auth_flow.* = .{ .google_project = .{ .exchange = exchange } };
                    try app_state.setStatus("Enter the Google Cloud project ID for Code Assist and press Enter");
                },
            }
        },
        .google_project => |google_project| {
            if (trimmed.len == 0) {
                const env_project = env_map.get("GOOGLE_CLOUD_PROJECT") orelse env_map.get("GOOGLE_CLOUD_PROJECT_ID");
                if (env_project == null) {
                    try app_state.setStatus("Enter a Google Cloud project ID or set GOOGLE_CLOUD_PROJECT");
                    return;
                }
            }

            const project_id = if (trimmed.len > 0)
                trimmed
            else
                env_map.get("GOOGLE_CLOUD_PROJECT") orelse env_map.get("GOOGLE_CLOUD_PROJECT_ID") orelse "";
            var credential = try auth.finalizeGoogleCredential(allocator, &google_project.exchange, project_id);
            defer credential.deinit(allocator);
            try persistLoginCredential(
                allocator,
                io,
                env_map,
                session,
                current_provider,
                google_project.provider_id,
                google_project.provider_name,
                &credential,
                options,
                app_state,
                auth_flow,
                live_resources,
            );
        },
        .copilot_device => |copilot| {
            var result = try auth.pollGitHubCopilotLogin(allocator, io, &copilot);
            defer result.deinit(allocator);
            switch (result) {
                .pending => |message| {
                    try app_state.setStatus(message);
                    return;
                },
                .completed => |oauth_credential| {
                    var credential = auth.StoredCredential{ .oauth = .{
                        .access = try allocator.dupe(u8, oauth_credential.access),
                        .refresh = try allocator.dupe(u8, oauth_credential.refresh),
                        .expires = oauth_credential.expires,
                    } };
                    defer credential.deinit(allocator);
                    try persistLoginCredential(
                        allocator,
                        io,
                        env_map,
                        session,
                        current_provider,
                        copilot.provider_id,
                        copilot.provider_name,
                        &credential,
                        options,
                        app_state,
                        auth_flow,
                        live_resources,
                    );
                },
            }
        },
        .api_key => |api_key_prompt| {
            if (trimmed.len == 0) {
                try app_state.setStatus("Paste the API key before pressing Enter");
                return;
            }

            var credential = auth.StoredCredential{
                .api_key = try allocator.dupe(u8, trimmed),
            };
            defer credential.deinit(allocator);
            try persistLoginCredential(
                allocator,
                io,
                env_map,
                session,
                current_provider,
                api_key_prompt.provider_id,
                api_key_prompt.provider_name,
                &credential,
                options,
                app_state,
                auth_flow,
                live_resources,
            );
        },
    }

    clearEditor(editor);
}

pub fn persistLoginCredential(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    provider_id: []const u8,
    provider_name: []const u8,
    credential: *const auth.StoredCredential,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    auth_flow: *?AuthFlow,
    live_resources: *LiveResources,
) !void {
    const runtime_config = live_resources.runtime_config orelse {
        try app_state.setStatus("Authentication storage is unavailable in this session");
        return;
    };

    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ runtime_config.agent_dir, "auth.json" });
    defer allocator.free(auth_path);

    try auth.upsertStoredCredential(allocator, io, auth_path, provider_id, credential);

    if (auth_flow.*) |*value| value.deinit(allocator);
    auth_flow.* = null;

    _ = try live_resources.reload(allocator, io, env_map, options.cwd);

    if (std.mem.eql(u8, session.agent.getModel().provider, provider_id)) {
        const resolved = provider_config.resolveProviderConfig(
            allocator,
            io,
            env_map,
            provider_id,
            session.agent.getModel().id,
            overrideApiKeyForProvider(options, provider_id),
            configuredApiKeyForProvider(live_resources.runtime_config, provider_id),
        ) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "Saved credentials for {s}, but could not activate them: {s}", .{
                provider_name,
                provider_config.resolveProviderErrorMessage(err, provider_id),
            });
            defer allocator.free(message);
            try app_state.appendError(message);
            return;
        };
        current_provider.deinit(allocator);
        current_provider.* = resolved;
        session.setApiKey(resolved.api_key);
    }

    const message = try std.fmt.allocPrint(allocator, "Logged in to {s}. Credentials saved to {s}.", .{ provider_name, auth_path });
    defer allocator.free(message);
    try app_state.appendInfo(message);
    try app_state.setStatus("logged in");
}

pub const OpenBrowserFn = *const fn (context: ?*anyopaque, io: std.Io, url: []const u8) void;

pub var open_browser_context: ?*anyopaque = null;
pub var open_browser_fn: OpenBrowserFn = defaultOpenBrowserBestEffort;

pub fn openBrowserBestEffort(io: std.Io, url: []const u8) void {
    open_browser_fn(open_browser_context, io, url);
}

pub fn defaultOpenBrowserBestEffort(_: ?*anyopaque, io: std.Io, url: []const u8) void {
    const argv = switch (builtin.os.tag) {
        .macos => [_][]const u8{ "open", url },
        .windows => [_][]const u8{ "cmd", "/c", "start", url },
        else => [_][]const u8{ "xdg-open", url },
    };

    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

pub const ClipboardCopyFn = *const fn (context: ?*anyopaque, io: std.Io, text: []const u8) anyerror!void;

pub var clipboard_copy_context: ?*anyopaque = null;
pub var clipboard_copy_fn: ClipboardCopyFn = defaultCopyTextToClipboard;
pub var test_auth_flow: ?AuthFlow = null;

pub const BrowserOpenCapture = struct {
    called: bool = false,

    pub fn capture(context: ?*anyopaque, _: std.Io, _: []const u8) void {
        const self: *BrowserOpenCapture = @ptrCast(@alignCast(context.?));
        self.called = true;
    }
};

pub fn handleSettingsSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const session_mod.AgentSession,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    live_resources: *LiveResources,
) !void {
    _ = session;
    const runtime_config = live_resources.runtime_config orelse {
        try app_state.setStatus("Settings editor is unavailable in this session");
        return;
    };
    overlay.* = try loadSettingsEditorOverlay(allocator, io, runtime_config, live_resources.theme);
}

pub fn handleImportSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    argument: ?[]const u8,
    options: RunInteractiveModeOptions,
    runtime_config: ?*const config_mod.RuntimeConfig,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    subscriber: agent.AgentSubscriber,
) !void {
    const raw_path = argument orelse {
        try app_state.appendError("Usage: /import <path.jsonl>");
        return;
    };

    const session_path = try common.resolvePath(allocator, options.cwd, normalizePathArgument(raw_path));
    defer allocator.free(session_path);

    switchSession(
        allocator,
        io,
        env_map,
        session,
        current_provider,
        session_path,
        options,
        runtime_config,
        tool_items,
        app_state,
        subscriber,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            const message = try std.fmt.allocPrint(allocator, "Failed to import session: file not found: {s}", .{session_path});
            defer allocator.free(message);
            try app_state.appendError(message);
            return;
        },
        else => return err,
    };

    const message = try std.fmt.allocPrint(allocator, "Session imported from {s}", .{session_path});
    defer allocator.free(message);
    try app_state.appendInfo(message);
}

pub fn handleCopySlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const session_mod.AgentSession,
    app_state: *AppState,
) !void {
    const text = lastAssistantTextAlloc(allocator, session) orelse {
        try app_state.appendError("No assistant messages to copy yet.");
        return;
    };
    defer allocator.free(text);

    copyTextToClipboard(io, text) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Failed to copy assistant message: {s}", .{@errorName(err)});
        defer allocator.free(message);
        try app_state.appendError(message);
        return;
    };

    try app_state.appendInfo("Copied last assistant message to clipboard");
    try app_state.setStatus("copied");
}

pub const DEFAULT_SHARE_VIEWER_URL: []const u8 = "https://pi.dev/session/";
pub const DEFAULT_SHARE_TMP_FILE: []const u8 = "/tmp/session.html";

pub const ShareGhResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
    /// True only when the binary was missing on PATH (gh not installed).
    not_found: bool = false,

    pub fn deinit(self: *ShareGhResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.stdout = &.{};
        self.stderr = &.{};
    }
};

pub const ShareGhRunFn = *const fn (
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) anyerror!ShareGhResult;

pub var share_gh_run_context: ?*anyopaque = null;
pub var share_gh_run_fn: ShareGhRunFn = defaultShareGhRun;
pub var share_tmp_file_override: ?[]const u8 = null;

pub fn defaultShareGhRun(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) anyerror!ShareGhResult {
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch |err| switch (err) {
        error.FileNotFound => return ShareGhResult{
            .exit_code = 127,
            .stdout = try allocator.alloc(u8, 0),
            .stderr = try allocator.alloc(u8, 0),
            .not_found = true,
        },
        else => return err,
    };
    return ShareGhResult{
        .exit_code = exitCodeFromChildTerm(result.term),
        .stdout = result.stdout,
        .stderr = result.stderr,
        .not_found = false,
    };
}

fn shareTmpFilePath() []const u8 {
    return share_tmp_file_override orelse DEFAULT_SHARE_TMP_FILE;
}

fn parseGistIdFromOutput(stdout: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash| {
        const id = trimmed[slash + 1 ..];
        if (id.len == 0) return null;
        // Reject empty/whitespace and anything that does not look like an id.
        for (id) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return null;
        }
        return id;
    }
    return null;
}

fn shareViewerUrl(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    gist_id: []const u8,
) ![]u8 {
    const base_raw = env_map.get("PI_SHARE_VIEWER_URL");
    const base = if (base_raw) |value|
        std.mem.trim(u8, value, " \t\r\n")
    else
        "";
    const effective = if (base.len > 0) base else DEFAULT_SHARE_VIEWER_URL;
    return std.fmt.allocPrint(allocator, "{s}#{s}", .{ effective, gist_id });
}

pub fn handleShareSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    app_state: *AppState,
) !void {
    if (session.agent.getMessages().len == 0) {
        try app_state.appendError("No session messages to share yet.");
        return;
    }

    // 1) Check that gh is installed and authenticated.
    var auth_result = share_gh_run_fn(
        share_gh_run_context,
        allocator,
        io,
        &[_][]const u8{ "gh", "auth", "status" },
    ) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Failed to invoke gh: {s}", .{@errorName(err)});
        defer allocator.free(message);
        try app_state.appendError(message);
        try app_state.setStatus("share failed");
        return;
    };
    defer auth_result.deinit(allocator);

    if (auth_result.not_found) {
        try app_state.appendError("GitHub CLI (gh) is not installed. Install it from https://cli.github.com/");
        try app_state.setStatus("share failed");
        return;
    }
    if (auth_result.exit_code != 0) {
        try app_state.appendError("GitHub CLI is not logged in. Run 'gh auth login' first.");
        try app_state.setStatus("share failed");
        return;
    }

    // 2) Export the session to a temporary HTML file.
    const tmp_file = shareTmpFilePath();
    const exported_path = session_advanced.exportToHtml(allocator, io, session, tmp_file) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Failed to export session: {s}", .{@errorName(err)});
        defer allocator.free(message);
        try app_state.appendError(message);
        try app_state.setStatus("share failed");
        return;
    };
    defer allocator.free(exported_path);

    var cleanup_done = false;
    defer if (!cleanup_done) {
        std.Io.Dir.deleteFileAbsolute(io, exported_path) catch {};
    };

    // 3) Create a secret gist.
    var gist_result = share_gh_run_fn(
        share_gh_run_context,
        allocator,
        io,
        &[_][]const u8{ "gh", "gist", "create", "--public=false", exported_path },
    ) catch |err| {
        std.Io.Dir.deleteFileAbsolute(io, exported_path) catch {};
        cleanup_done = true;
        const message = try std.fmt.allocPrint(allocator, "Failed to create gist: {s}", .{@errorName(err)});
        defer allocator.free(message);
        try app_state.appendError(message);
        try app_state.setStatus("share failed");
        return;
    };
    defer gist_result.deinit(allocator);

    // Always clean the temp file once gh has run.
    std.Io.Dir.deleteFileAbsolute(io, exported_path) catch {};
    cleanup_done = true;

    if (gist_result.not_found) {
        try app_state.appendError("GitHub CLI (gh) is not installed. Install it from https://cli.github.com/");
        try app_state.setStatus("share failed");
        return;
    }
    if (gist_result.exit_code != 0) {
        const stderr_trimmed = std.mem.trim(u8, gist_result.stderr, " \t\r\n");
        const detail = if (stderr_trimmed.len > 0) stderr_trimmed else "Unknown error";
        const message = try std.fmt.allocPrint(allocator, "Failed to create gist: {s}", .{detail});
        defer allocator.free(message);
        try app_state.appendError(message);
        try app_state.setStatus("share failed");
        return;
    }

    const gist_url = std.mem.trim(u8, gist_result.stdout, " \t\r\n");
    const gist_id = parseGistIdFromOutput(gist_url) orelse {
        try app_state.appendError("Failed to parse gist ID from gh output");
        try app_state.setStatus("share failed");
        return;
    };

    const preview_url = try shareViewerUrl(allocator, env_map, gist_id);
    defer allocator.free(preview_url);

    const message = try std.fmt.allocPrint(allocator, "Share URL: {s}\nGist: {s}", .{ preview_url, gist_url });
    defer allocator.free(message);
    try app_state.appendInfo(message);
    try app_state.setStatus("shared");
}

pub fn handleLogoutSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    argument: ?[]const u8,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    live_resources: *LiveResources,
) !void {
    const runtime_config = live_resources.runtime_config orelse {
        try app_state.setStatus("Logout is unavailable in this session");
        return;
    };

    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ runtime_config.agent_dir, "auth.json" });
    defer allocator.free(auth_path);

    if (argument) |provider_id| {
        try logoutProviderById(
            allocator,
            io,
            env_map,
            session,
            current_provider,
            provider_id,
            options,
            app_state,
            live_resources,
        );
        return;
    }

    const providers = try auth.listStoredProviders(allocator, io, auth_path);
    defer allocator.free(providers);
    if (providers.len == 0) {
        try app_state.setStatus("No providers logged in. Use /login first.");
        return;
    }

    overlay.* = try loadAuthOverlay(allocator, .logout, providers);
}

pub fn logoutProviderById(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    provider_name: []const u8,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    live_resources: *LiveResources,
) !void {
    const runtime_config = live_resources.runtime_config orelse {
        try app_state.setStatus("Logout is unavailable in this session");
        return;
    };

    const model_id = try allocator.dupe(u8, session.agent.getModel().id);
    defer allocator.free(model_id);
    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ runtime_config.agent_dir, "auth.json" });
    defer allocator.free(auth_path);

    const removed = try auth.removeStoredCredential(allocator, io, auth_path, provider_name);
    const affects_current_provider = std.mem.eql(u8, session.agent.getModel().provider, provider_name);
    if (affects_current_provider) {
        try clearResolvedProviderApiKey(allocator, current_provider);
        session.setApiKey(null);
    }

    _ = try live_resources.reload(allocator, io, env_map, options.cwd);

    if (affects_current_provider) {
        const resolved = provider_config.resolveProviderConfig(
            allocator,
            io,
            env_map,
            provider_name,
            model_id,
            overrideApiKeyForProvider(options, provider_name),
            configuredApiKeyForProvider(live_resources.runtime_config, provider_name),
        ) catch |err| switch (err) {
            error.MissingApiKey => null,
            else => return err,
        };

        if (resolved) |next_provider| {
            current_provider.deinit(allocator);
            current_provider.* = next_provider;
            session.setApiKey(next_provider.api_key);
        }
    }

    const message = if (removed)
        try std.fmt.allocPrint(allocator, "Removed stored authentication for provider `{s}`.", .{provider_name})
    else
        try std.fmt.allocPrint(allocator, "No stored authentication found for provider `{s}`.", .{provider_name});
    defer allocator.free(message);
    try app_state.appendInfo(message);
    try app_state.setStatus("logged out");
}

pub fn handleNewSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    subscriber: agent.AgentSubscriber,
) !void {
    var candidate = try createSeededSession(
        allocator,
        io,
        options.cwd,
        options.system_prompt,
        current_provider.model,
        current_provider.api_key,
        session.agent.getThinkingLevel(),
        tool_items,
        configuredCompactionSettings(options.runtime_config),
        configuredRetrySettings(options.runtime_config),
        if (session.session_manager.getSessionDir().len > 0) session_dir else null,
        &.{},
    );
    errdefer candidate.deinit();

    try replaceCurrentSession(allocator, session, &candidate, app_state, subscriber);
    try app_state.appendInfo("New session started");
}

pub fn clearResolvedProviderApiKey(
    allocator: std.mem.Allocator,
    current_provider: *provider_config.ResolvedProviderConfig,
) !void {
    if (current_provider.owned_api_key) |api_key| allocator.free(api_key);
    current_provider.owned_api_key = null;
    current_provider.api_key = null;
}

pub fn copyTextToClipboard(io: std.Io, text: []const u8) !void {
    try clipboard_copy_fn(clipboard_copy_context, io, text);
}

pub fn defaultCopyTextToClipboard(_: ?*anyopaque, io: std.Io, text: []const u8) !void {
    switch (builtin.os.tag) {
        .macos => try runClipboardCommand(io, &[_][]const u8{"pbcopy"}, text),
        .windows => try runClipboardCommand(io, &[_][]const u8{"clip"}, text),
        else => {
            runClipboardCommand(io, &[_][]const u8{"wl-copy"}, text) catch {
                runClipboardCommand(io, &[_][]const u8{ "xclip", "-selection", "clipboard" }, text) catch {
                    try runClipboardCommand(io, &[_][]const u8{ "xsel", "--clipboard", "--input" }, text);
                };
            };
        },
    }
}

pub fn runClipboardCommand(io: std.Io, argv: []const []const u8, text: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer {
        if (child.id != null) child.kill(io);
    }

    const stdin_file = child.stdin.?;
    child.stdin = null;

    var buffer: [1024]u8 = undefined;
    var writer = stdin_file.writer(io, &buffer);
    try writer.interface.writeAll(text);
    try writer.flush();
    stdin_file.close(io);

    const term = try child.wait(io);
    if (exitCodeFromChildTerm(term) != 0) return error.ClipboardCommandFailed;
}

pub fn exitCodeFromChildTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

pub fn lastAssistantTextAlloc(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) ?[]u8 {
    const messages = session.agent.getMessages();
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .assistant => |assistant_message| {
                const text = assistantBlocksToTextAlloc(allocator, assistant_message.content) catch return null;
                if (text.len == 0) {
                    allocator.free(text);
                    return null;
                }
                return text;
            },
            else => {},
        }
    }
    return null;
}

pub fn assistantBlocksToTextAlloc(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var wrote_any = false;
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                if (text.text.len == 0) continue;
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.writeAll(text.text);
                wrote_any = true;
            },
            .thinking => |thinking| {
                if (thinking.thinking.len == 0) continue;
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.writeAll(thinking.thinking);
                wrote_any = true;
            },
            .image, .tool_call => {},
        }
    }

    return try allocator.dupe(u8, writer.written());
}

pub fn buildShareText(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) ![]u8 {
    const stats = session_advanced.getSessionStats(session);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.print("# Session {s}\n\n", .{stats.session_name orelse stats.session_id});
    try writer.writer.print("- Session ID: `{s}`\n", .{stats.session_id});
    try writer.writer.print("- Working directory: `{s}`\n", .{session.cwd});
    try writer.writer.print("- Model: `{s}` / `{s}`\n\n", .{ session.agent.getModel().provider, session.agent.getModel().id });
    try writer.writer.writeAll("## Transcript\n\n");

    for (session.agent.getMessages(), 0..) |message, index| {
        try writer.writer.print("### {d}. {s}\n\n", .{ index + 1, switch (message) {
            .user => "User",
            .assistant => "Assistant",
            .tool_result => "Tool Result",
        } });
        const markdown = try messageToShareMarkdown(allocator, message);
        defer allocator.free(markdown);
        if (markdown.len == 0) {
            try writer.writer.writeAll("_No text content_\n\n");
        } else {
            try writer.writer.print("{s}\n\n", .{markdown});
        }
    }

    return try allocator.dupe(u8, writer.written());
}

pub fn messageToShareMarkdown(allocator: std.mem.Allocator, message: agent.AgentMessage) ![]u8 {
    return switch (message) {
        .user => |user_message| blocksToShareText(allocator, user_message.content),
        .assistant => |assistant_message| blk: {
            const text = try blocksToShareText(allocator, assistant_message.content);
            if (text.len > 0) break :blk text;
            const calls = try ai.collectAssistantToolCalls(allocator, assistant_message);
            defer allocator.free(calls);
            if (calls.len > 0) {
                var writer: std.Io.Writer.Allocating = .init(allocator);
                defer writer.deinit();
                for (calls, 0..) |tool_call, index| {
                    if (index > 0) try writer.writer.writeAll("\n");
                    const args = try std.json.Stringify.valueAlloc(allocator, tool_call.arguments, .{ .whitespace = .indent_2 });
                    defer allocator.free(args);
                    try writer.writer.print("- `{s}` `{s}`\n```json\n{s}\n```", .{ tool_call.name, tool_call.id, args });
                }
                break :blk try allocator.dupe(u8, writer.written());
            }
            break :blk text;
        },
        .tool_result => |tool_result| blk: {
            const text = try blocksToShareText(allocator, tool_result.content);
            defer allocator.free(text);
            if (text.len == 0) {
                break :blk try std.fmt.allocPrint(allocator, "`{s}` returned no text content", .{tool_result.tool_name});
            }
            break :blk try std.fmt.allocPrint(allocator, "`{s}`\n\n{s}", .{ tool_result.tool_name, text });
        },
    };
}

pub fn blocksToShareText(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var wrote_any = false;
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                if (text.text.len == 0) continue;
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.writeAll(text.text);
                wrote_any = true;
            },
            .thinking => |thinking| {
                if (thinking.thinking.len == 0) continue;
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.print("_Thinking:_ {s}", .{thinking.thinking});
                wrote_any = true;
            },
            .image => |image| {
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.print("![image](data:{s};base64,{s})", .{ image.mime_type, image.data });
                wrote_any = true;
            },
            .tool_call => |tool_call| {
                if (wrote_any) try writer.writer.writeAll("\n");
                const args = try std.json.Stringify.valueAlloc(allocator, tool_call.arguments, .{ .whitespace = .indent_2 });
                defer allocator.free(args);
                try writer.writer.print("- `{s}` `{s}`\n```json\n{s}\n```", .{ tool_call.name, tool_call.id, args });
                wrote_any = true;
            },
        }
    }

    return try allocator.dupe(u8, writer.written());
}

pub fn removeStoredAuthToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_path: []const u8,
    provider_name: []const u8,
) !bool {
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, auth_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;

    var next_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const next_value: std.json.Value = .{ .object = next_object };
        common.deinitJsonValue(allocator, next_value);
    }

    var removed = false;
    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, provider_name)) {
            removed = true;
            continue;
        }
        try next_object.put(
            allocator,
            try allocator.dupe(u8, entry.key_ptr.*),
            try common.cloneJsonValue(allocator, entry.value_ptr.*),
        );
    }
    if (!removed) {
        const next_value: std.json.Value = .{ .object = next_object };
        common.deinitJsonValue(allocator, next_value);
        return false;
    }

    const next_value: std.json.Value = .{ .object = next_object };
    defer common.deinitJsonValue(allocator, next_value);

    const serialized = try std.json.Stringify.valueAlloc(allocator, next_value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    try common.writeFileAbsolute(io, auth_path, serialized, true);
    return true;
}

pub fn clearEditor(editor: *tui.Editor) void {
    editor.reset();
}

pub fn handleReloadSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    app_state: *AppState,
    live_resources: *LiveResources,
) !void {
    if (live_resources.runtime_config == null) {
        try app_state.setStatus("Reload is unavailable in this session");
        return;
    }

    const diagnostics = try live_resources.reload(allocator, io, env_map, cwd);
    try app_state.setStatus("Reloaded keybindings, skills, prompts, and themes");
    try appendResourceDiagnostics(allocator, app_state, diagnostics);
}

pub fn configurePrimaryEditor(editor: *tui.Editor, runtime_config: ?*const config_mod.RuntimeConfig) void {
    editor.padding_x = if (runtime_config) |runtime_config_value|
        runtime_config_value.settings.editor_padding_x orelse 0
    else
        0;
    editor.autocomplete_max_visible = if (runtime_config) |runtime_config_value|
        runtime_config_value.settings.autocomplete_max_visible orelse 5
    else
        5;
}

pub fn appendResourceDiagnostics(
    allocator: std.mem.Allocator,
    app_state: *AppState,
    diagnostics: []const resources_mod.Diagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        const message = if (diagnostic.path) |path|
            try std.fmt.allocPrint(allocator, "{s}: {s} ({s})", .{ diagnostic.kind, diagnostic.message, path })
        else
            try std.fmt.allocPrint(allocator, "{s}: {s}", .{ diagnostic.kind, diagnostic.message });
        defer allocator.free(message);
        if (std.mem.eql(u8, diagnostic.kind, "warning")) {
            try app_state.appendError(message);
        } else {
            try app_state.appendInfo(message);
        }
    }
}

pub fn saveSettingsEditorOverlay(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    live_resources: *LiveResources,
) !void {
    var overlay_value = overlay.* orelse return;
    if (std.meta.activeTag(overlay_value) != .settings_editor) return;

    const trimmed = std.mem.trim(u8, overlay_value.settings_editor.editor.text(), " \t\r\n");
    const serialized = if (trimmed.len == 0)
        "{\n}\n"
    else
        overlay_value.settings_editor.editor.text();

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, serialized, .{}) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Invalid settings.json: {s}", .{@errorName(err)});
        defer allocator.free(message);
        try app_state.appendError(message);
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try app_state.appendError("Invalid settings.json: top-level value must be an object");
        return;
    }

    try common.writeFileAbsolute(io, overlay_value.settings_editor.path, serialized, true);

    const diagnostics = try live_resources.reload(allocator, io, env_map, options.cwd);
    configurePrimaryEditor(editor, live_resources.runtime_config);
    session.compaction_settings = configuredCompactionSettings(live_resources.runtime_config);
    session.retry_settings = configuredRetrySettings(live_resources.runtime_config);

    const path_copy = try allocator.dupe(u8, overlay_value.settings_editor.path);
    defer allocator.free(path_copy);
    overlay_value.deinit(allocator);
    overlay.* = null;

    const message = try std.fmt.allocPrint(allocator, "Saved settings to {s}", .{path_copy});
    defer allocator.free(message);
    try app_state.appendInfo(message);
    try app_state.setStatus("settings saved");
    try appendResourceDiagnostics(allocator, app_state, diagnostics);
}

pub fn handleExportSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    argument: ?[]const u8,
    app_state: *AppState,
) !void {
    const output_path = if (argument) |raw_path| normalizePathArgument(raw_path) else null;
    const exported_path = if (output_path) |path| blk: {
        if (std.mem.endsWith(u8, path, ".html")) {
            break :blk try session_advanced.exportToHtml(allocator, io, session, path);
        }
        if (std.mem.endsWith(u8, path, ".jsonl")) {
            break :blk try session_advanced.exportToJsonl(allocator, io, session, path);
        }
        if (std.mem.endsWith(u8, path, ".json")) {
            break :blk try session_advanced.exportToJson(allocator, io, session, path);
        }
        if (std.mem.endsWith(u8, path, ".md")) {
            break :blk try session_advanced.exportToMarkdown(allocator, io, session, path);
        }
        const message = try std.fmt.allocPrint(allocator, "Unsupported export path: {s}. Use .html, .jsonl, .json, or .md.", .{path});
        defer allocator.free(message);
        try app_state.appendError(message);
        return;
    } else try session_advanced.exportToHtml(allocator, io, session, null);
    defer allocator.free(exported_path);

    const message = try std.fmt.allocPrint(allocator, "Session exported to {s}", .{exported_path});
    defer allocator.free(message);
    try app_state.appendInfo(message);
    try app_state.setStatus("session exported");
}

pub fn formatSessionInfo(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) ![]u8 {
    const stats = session_advanced.getSessionStats(session);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.writeAll("Session Info\n");
    if (session.session_manager.getSessionName()) |name| {
        try writer.writer.print("Name: {s}\n", .{name});
    }
    try writer.writer.print("File: {s}\n", .{stats.session_file orelse "in-memory"});
    try writer.writer.print("ID: {s}\n", .{stats.session_id});
    try writer.writer.print("Model: {s}/{s}\n", .{ session.agent.getModel().provider, session.agent.getModel().id });
    try writer.writer.print(
        "Messages: user={d}, assistant={d}, tool_calls={d}, tool_results={d}, total={d}\n",
        .{ stats.user_messages, stats.assistant_messages, stats.tool_calls, stats.tool_results, stats.total_messages },
    );
    try writer.writer.print(
        "Tokens: input={d}, output={d}, cache_read={d}, cache_write={d}, total={d}\n",
        .{ stats.tokens.input, stats.tokens.output, stats.tokens.cache_read, stats.tokens.cache_write, stats.tokens.total },
    );
    if (stats.context_usage) |usage| {
        try writer.writer.print(
            "Context: {d}/{d} tokens ({d:.1}%)\n",
            .{ usage.tokens orelse 0, usage.context_window, usage.percent orelse 0 },
        );
    }
    if (stats.cost > 0) {
        try writer.writer.print("Cost: {d:.4}\n", .{stats.cost});
    }

    return try allocator.dupe(u8, writer.written());
}

pub fn cloneCurrentSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    subscriber: agent.AgentSubscriber,
) !void {
    const messages = session.agent.getMessages();
    if (messages.len == 0) {
        try app_state.setStatus("Nothing to clone yet");
        return;
    }

    var candidate = try createDerivedSession(
        allocator,
        io,
        session,
        current_provider,
        session_dir,
        tool_items,
        messages,
    );
    errdefer candidate.deinit();

    try replaceCurrentSession(allocator, session, &candidate, app_state, subscriber);
    const message = try std.fmt.allocPrint(allocator, "Cloned session to {s}", .{currentSessionLabel(session)});
    defer allocator.free(message);
    try app_state.appendInfo(message);
}

pub fn forkCurrentSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    subscriber: agent.AgentSubscriber,
) !void {
    const messages = session.agent.getMessages();
    const last_user_index = findLastUserMessageIndex(messages) orelse {
        try app_state.setStatus("No user messages to fork from");
        return;
    };

    var candidate = try createDerivedSession(
        allocator,
        io,
        session,
        current_provider,
        session_dir,
        tool_items,
        messages[0 .. last_user_index + 1],
    );
    errdefer candidate.deinit();

    try replaceCurrentSession(allocator, session, &candidate, app_state, subscriber);
    const message = try std.fmt.allocPrint(allocator, "Forked session at the latest user message into {s}", .{currentSessionLabel(session)});
    defer allocator.free(message);
    try app_state.appendInfo(message);
}

pub fn createDerivedSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_session: *const session_mod.AgentSession,
    current_provider: *const provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    tool_items: []const agent.AgentTool,
    messages: []const agent.AgentMessage,
) !session_mod.AgentSession {
    var derived = try session_mod.AgentSession.create(allocator, io, .{
        .cwd = source_session.cwd,
        .system_prompt = source_session.system_prompt,
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .thinking_level = source_session.agent.getThinkingLevel(),
        .tools = tool_items,
        .session_dir = session_dir,
    });
    errdefer derived.deinit();

    for (messages) |message| {
        _ = try derived.session_manager.appendMessage(message);
    }
    try derived.agent.setMessages(messages);
    derived.agent.setModel(current_provider.model);
    derived.agent.setApiKey(current_provider.api_key);
    return derived;
}

pub fn replaceCurrentSession(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    candidate: *session_mod.AgentSession,
    app_state: *AppState,
    subscriber: agent.AgentSubscriber,
) !void {
    _ = session.agent.unsubscribe(subscriber);
    session.deinit();
    session.* = candidate.*;
    candidate.* = undefined;
    try session.agent.subscribe(subscriber);
    try rebuildAppStateFromSession(allocator, session.io, app_state, session, null);
    try app_state.setStatus("idle");
}

pub fn navigateTree(
    session: *session_mod.AgentSession,
    entry_id: []const u8,
    app_state: *AppState,
) !void {
    try session.navigateTo(entry_id);
    try rebuildAppStateFromSession(session.allocator, session.io, app_state, session, null);
    try app_state.setStatus("session tree updated");
}

pub fn findLastUserMessageIndex(messages: []const agent.AgentMessage) ?usize {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        if (messages[index] == .user) return index;
    }
    return null;
}

pub fn resolveSessionPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    cwd: []const u8,
    session_ref: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(session_ref) or std.mem.indexOfScalar(u8, session_ref, '/') != null) {
        return if (std.fs.path.isAbsolute(session_ref))
            allocator.dupe(u8, session_ref)
        else
            std.fs.path.resolve(allocator, &[_][]const u8{ cwd, session_ref });
    }

    var dir = try std.Io.Dir.openDirAbsolute(io, session_dir, .{ .iterate = true });
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        if (!std.mem.containsAtLeast(u8, entry.name, 1, session_ref)) continue;
        return try std.fs.path.join(allocator, &[_][]const u8{ session_dir, entry.name });
    }

    return error.FileNotFound;
}

test "switchModel shows provider-specific setup guidance when auth is missing" {
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

    var app_state = try AppState.init(allocator, std.testing.io);
    defer app_state.deinit();

    const options = RunInteractiveModeOptions{
        .cwd = "/tmp/project",
        .system_prompt = "sys",
        .session_dir = "/tmp/project/.pi/sessions",
        .provider = "faux",
    };

    try switchModel(
        allocator,
        &env_map,
        &session,
        &current_provider,
        "openai",
        "gpt-5.4",
        options,
        null,
        &app_state,
    );

    app_state.mutex.lockUncancelable(app_state.io);
    defer app_state.mutex.unlock(app_state.io);
    try std.testing.expect(std.mem.indexOf(u8, app_state.status, "OPENAI_API_KEY") != null);
    try std.testing.expect(app_state.items.items.len > 1);
    const error_text = app_state.items.items[app_state.items.items.len - 1].text;
    try std.testing.expect(std.mem.indexOf(u8, error_text, "OPENAI_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_text, "/login openai") != null);
}
