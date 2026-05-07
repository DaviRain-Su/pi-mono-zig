const std = @import("std");
const agent = @import("agent");
const config_mod = @import("../config/config.zig");
const provider_config = @import("../providers/provider_config.zig");
const session_mod = @import("../sessions/session.zig");
const shared = @import("shared.zig");
const overlays = @import("overlays.zig");
const rendering = @import("rendering.zig");
const auth_flow_mod = @import("auth_flow.zig");
const session_lifecycle = @import("session_lifecycle.zig");
const slash_commands = @import("slash_commands.zig");

const RunInteractiveModeOptions = shared.RunInteractiveModeOptions;
const LiveResources = shared.LiveResources;
const SelectorOverlay = overlays.SelectorOverlay;
const AuthFlow = overlays.AuthFlow;
const loadSessionOverlay = overlays.loadSessionOverlay;
const loadTreeOverlay = overlays.loadTreeOverlay;
const AppState = rendering.AppState;

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
    .{ .name = "settings", .description = "Open settings menu" },
    .{ .name = "model", .description = "Select model (opens selector UI)" },
    .{ .name = "theme", .description = "Switch color theme", .argument_hint = "[night|day]" },
    .{ .name = "scoped-models", .description = "Enable/disable models for Ctrl+P cycling" },
    .{ .name = "export", .description = "Export session (HTML default, or specify path: .html/.jsonl)" },
    .{ .name = "import", .description = "Import and resume a session from a JSONL file" },
    .{ .name = "share", .description = "Share session as a secret GitHub gist" },
    .{ .name = "copy", .description = "Copy transcript content to clipboard", .argument_hint = "[last|all|visible]" },
    .{ .name = "name", .description = "Set session display name", .argument_hint = "<name>" },
    .{ .name = "session", .description = "Show session info and stats" },
    .{ .name = "changelog", .description = "Show changelog entries" },
    .{ .name = "hotkeys", .description = "Show all keyboard shortcuts" },
    .{ .name = "fork", .description = "Create a new fork from a previous user message" },
    .{ .name = "clone", .description = "Duplicate the current session at the current position" },
    .{ .name = "tree", .description = "Navigate session tree (switch branches)" },
    .{ .name = "login", .description = "Configure provider authentication" },
    .{ .name = "logout", .description = "Remove provider authentication" },
    .{ .name = "new", .description = "Start a new session" },
    .{ .name = "compact", .description = "Manually compact the session context" },
    .{ .name = "resume", .description = "Resume a different session" },
    .{ .name = "reload", .description = "Reload keybindings, extensions, skills, prompts, and themes" },
    .{ .name = "quit", .description = "Quit pi" },
};

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
    if (try handleImmediateSlashCommand(
        allocator,
        io,
        env_map,
        command,
        session,
        current_provider,
        options,
        app_state,
        overlay,
        live_resources,
    )) return;

    switch (command.kind) {
        .settings, .model, .theme, .scoped_models, .share, .copy, .name, .hotkeys, .label, .session, .changelog => unreachable,
        .import => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before importing a session")) return;
            try slash_commands.handleImportSlashCommand(
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
        .tree => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before opening the session tree")) return;
            overlay.* = try loadTreeOverlay(allocator, session);
        },
        .fork => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before forking the session")) return;
            try session_lifecycle.loadForkOverlayOrStatus(allocator, session, app_state, overlay);
        },
        .clone => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before cloning the session")) return;
            try session_lifecycle.cloneCurrentSession(
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
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before compacting the session")) return;
            try slash_commands.handleCompactSlashCommand(allocator, session, command.argument, app_state);
        },
        .login => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before logging in")) return;
            try auth_flow_mod.handleLoginSlashCommand(
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
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before logging out")) return;
            try auth_flow_mod.handleLogoutSlashCommand(
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
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before starting a new session")) return;
            try session_lifecycle.handleNewSlashCommand(
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
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before switching sessions")) return;
            overlay.* = try loadSessionOverlay(allocator, io, session_dir, session.session_manager.getSessionFile());
        },
        .reload => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before reloading resources")) return;
            try slash_commands.handleReloadSlashCommand(allocator, io, env_map, options.cwd, app_state, live_resources);
        },
        .@"export" => {
            if (try blockDuringActivePrompt(prompt_worker_active, app_state, "wait for the current response to finish before exporting the session")) return;
            try slash_commands.handleExportSlashCommand(allocator, io, session, command.argument, app_state);
        },
        .quit => {
            should_exit.* = true;
            if (prompt_worker_active.*) session.agent.abort();
        },
    }
}

fn handleImmediateSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    command: SlashCommand,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    options: RunInteractiveModeOptions,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    live_resources: *LiveResources,
) !bool {
    switch (command.kind) {
        .settings => try slash_commands.handleSettingsSlashCommand(allocator, io, env_map, session, command.argument, options, app_state, overlay, live_resources),
        .model => try slash_commands.handleModelSlashCommand(allocator, env_map, session, current_provider, command.argument, options, live_resources.runtime_config, app_state, overlay),
        .theme => try slash_commands.handleThemeSlashCommand(allocator, io, env_map, options.cwd, command.argument, app_state, overlay, live_resources),
        .scoped_models => try slash_commands.handleScopedModelsSlashCommand(allocator, env_map, session, current_provider, options, live_resources.runtime_config, app_state, overlay),
        .share => try slash_commands.handleShareSlashCommand(allocator, io, env_map, session, app_state),
        .copy => try slash_commands.handleCopySlashCommand(allocator, io, session, app_state, command.argument),
        .name => try slash_commands.handleNameSlashCommand(allocator, session, command.argument, app_state),
        .hotkeys => try slash_commands.handleHotkeysSlashCommand(allocator, app_state, live_resources.keybindings),
        .label => try slash_commands.handleLabelSlashCommand(allocator, session, command.argument, app_state),
        .session => try slash_commands.handleSessionSlashCommand(allocator, session, app_state),
        .changelog => try slash_commands.handleChangelogSlashCommand(allocator, io, session, command.argument, app_state),
        else => return false,
    }
    return true;
}

fn blockDuringActivePrompt(prompt_worker_active: *const bool, app_state: *AppState, status: []const u8) !bool {
    if (!prompt_worker_active.*) return false;
    try app_state.setStatus(status);
    return true;
}

test "built-in slash command autocomplete matrix matches TypeScript order" {
    const expected = [_][]const u8{
        "settings",
        "model",
        "theme",
        "scoped-models",
        "export",
        "import",
        "share",
        "copy",
        "name",
        "session",
        "changelog",
        "hotkeys",
        "fork",
        "clone",
        "tree",
        "login",
        "logout",
        "new",
        "compact",
        "resume",
        "reload",
        "quit",
    };

    try std.testing.expectEqual(expected.len, BUILTIN_SLASH_COMMANDS.len);
    for (expected, 0..) |name, index| {
        try std.testing.expectEqualStrings(name, BUILTIN_SLASH_COMMANDS[index].name);
        var buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "/{s}", .{name});
        try std.testing.expect(parseSlashCommand(text) != null);
    }
}
