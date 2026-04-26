const std = @import("std");
const agent = @import("agent");
const auth = @import("../auth.zig");
const tui = @import("tui");
const config_mod = @import("../config.zig");
const keybindings_mod = @import("../keybindings.zig");
const provider_config = @import("../provider_config.zig");
const resources_mod = @import("../resources.zig");
const session_mod = @import("../session.zig");
const shared = @import("shared.zig");
const overlays = @import("overlays.zig");
const rendering = @import("rendering.zig");
const clipboard_image = @import("clipboard_image.zig");
const prompt_worker_mod = @import("prompt_worker.zig");
const slash_commands = @import("slash_commands.zig");
const RunInteractiveModeOptions = shared.RunInteractiveModeOptions;
const LiveResources = shared.LiveResources;
const SelectorOverlay = overlays.SelectorOverlay;
const AuthFlow = overlays.AuthFlow;
const loadSessionOverlay = overlays.loadSessionOverlay;
const loadModelOverlay = overlays.loadModelOverlay;
const AppState = rendering.AppState;
const PromptWorker = prompt_worker_mod.PromptWorker;
const parseSlashCommand = slash_commands.parseSlashCommand;
const handleSlashCommand = slash_commands.handleSlashCommand;
const saveSettingsEditorOverlay = slash_commands.saveSettingsEditorOverlay;
const switchSession = slash_commands.switchSession;
const switchModel = slash_commands.switchModel;
const navigateTree = slash_commands.navigateTree;
const beginLoginFlow = slash_commands.beginLoginFlow;
const logoutProviderById = slash_commands.logoutProviderById;
const cancelAuthFlow = slash_commands.cancelAuthFlow;
const submitAuthFlowInput = slash_commands.submitAuthFlowInput;
const BUILTIN_SLASH_COMMANDS = slash_commands.BUILTIN_SLASH_COMMANDS;
const AppContext = shared.AppContext;

pub fn handleInputKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    key: tui.Key,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker: *PromptWorker,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    live_resources: *LiveResources,
) !void {
    if (overlay.*) |*overlay_value| {
        if (resolveAppAction(live_resources.keybindings, key)) |action| {
            if (action == .exit) {
                should_exit.* = true;
                if (prompt_worker_active.*) session.agent.abort();
                return;
            }
        }

        if (std.meta.activeTag(overlay_value.*) == .settings_editor) {
            switch (key) {
                .escape => {
                    overlay_value.deinit(allocator);
                    overlay.* = null;
                    return;
                },
                .ctrl => |ctrl| {
                    if (ctrl == 's') {
                        try saveSettingsEditorOverlay(
                            allocator,
                            io,
                            env_map,
                            session,
                            options,
                            app_state,
                            editor,
                            overlay,
                            live_resources,
                        );
                        return;
                    }
                },
                else => {},
            }

            _ = try overlay_value.settings_editor.editor.handleKey(key);
            return;
        }

        switch (key) {
            .escape => {
                overlay_value.deinit(allocator);
                overlay.* = null;
                return;
            },
            else => {},
        }

        const overlay_list = switch (overlay_value.*) {
            .info => &overlay_value.info.list,
            .session => &overlay_value.session.list,
            .model => &overlay_value.model.list,
            .tree => &overlay_value.tree.list,
            .auth => &overlay_value.auth.list,
            else => unreachable,
        };
        const result = overlay_list.handleKey(key);
        switch (result) {
            .handled, .ignored => return,
            .dismissed => {
                overlay_value.deinit(allocator);
                overlay.* = null;
                return;
            },
            .confirmed => |index| {
                switch (overlay_value.*) {
                    .info => {},
                    .session => |session_overlay| {
                        if (session_overlay.choices[index].path.len == 0) {
                            try app_state.setStatus("No sessions found");
                            overlay_value.deinit(allocator);
                            overlay.* = null;
                            return;
                        }
                        try switchSession(
                            allocator,
                            io,
                            env_map,
                            session,
                            current_provider,
                            session_overlay.choices[index].path,
                            options,
                            live_resources.runtime_config,
                            tool_items,
                            app_state,
                            subscriber,
                        );
                    },
                    .model => |model_overlay| {
                        try switchModel(
                            allocator,
                            env_map,
                            session,
                            current_provider,
                            model_overlay.choices[index].provider,
                            model_overlay.choices[index].model_id,
                            options,
                            live_resources.runtime_config,
                            app_state,
                        );
                    },
                    .tree => |tree_overlay| {
                        if (tree_overlay.choices[index].entry_id.len == 0) {
                            try app_state.setStatus("No tree entries available");
                        } else {
                            try navigateTree(session, tree_overlay.choices[index].entry_id, app_state);
                        }
                    },
                    .auth => |auth_overlay| switch (auth_overlay.mode) {
                        .login => try beginLoginFlow(
                            allocator,
                            io,
                            env_map,
                            auth_overlay.choices[index].provider_id,
                            auth_overlay.choices[index].auth_type,
                            app_state,
                            auth_flow,
                        ),
                        .logout => try logoutProviderById(
                            allocator,
                            io,
                            env_map,
                            session,
                            current_provider,
                            auth_overlay.choices[index].provider_id,
                            options,
                            app_state,
                            live_resources,
                        ),
                    },
                    else => unreachable,
                }
                overlay_value.deinit(allocator);
                overlay.* = null;
                return;
            },
        }
    }

    if (auth_flow.* != null) {
        if (resolveAppAction(live_resources.keybindings, key)) |action| {
            if (action == .exit) {
                should_exit.* = true;
                if (prompt_worker_active.*) session.agent.abort();
                return;
            }
        }

        switch (key) {
            .escape => {
                cancelAuthFlow(allocator, auth_flow, app_state) catch {};
                clearEditor(app_state, editor);
                return;
            },
            .enter => {
                if (editor.isShowingAutocomplete()) {
                    _ = try editor.handleKey(key);
                    return;
                }
                const trimmed = std.mem.trim(u8, editor.text(), " \t\r\n");
                submitAuthFlowInput(
                    allocator,
                    io,
                    env_map,
                    trimmed,
                    session,
                    current_provider,
                    options,
                    app_state,
                    editor,
                    auth_flow,
                    live_resources,
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
                return;
            },
            else => {},
        }

        const handled_auth = try editor.handleKey(key);
        switch (handled_auth) {
            .exit => {
                should_exit.* = true;
                if (prompt_worker_active.*) session.agent.abort();
            },
            else => {},
        }
        return;
    }

    if (key == .escape and editor.isShowingAutocomplete()) {
        _ = try editor.handleKey(key);
        return;
    }

    if (resolveAppAction(live_resources.keybindings, key)) |action| {
        if (action == .paste_image) {
            try handlePasteImageAction(allocator, io, env_map, app_state);
            return;
        }
        try handleAppAction(
            allocator,
            io,
            env_map,
            action,
            session,
            session_dir,
            options.model_patterns,
            live_resources.runtime_config,
            app_state,
            overlay,
            prompt_worker_active,
            should_exit,
        );
        return;
    }

    if (live_resources.keybindings != null and isLegacyAppActionKey(key)) {
        return;
    }

    switch (key) {
        .enter => {
            if (editor.isShowingAutocomplete()) {
                _ = try editor.handleKey(key);
                return;
            }
            const trimmed = std.mem.trim(u8, editor.text(), " \t\r\n");
            if (trimmed.len == 0) return;
            try submitEditorText(
                allocator,
                io,
                env_map,
                trimmed,
                session,
                current_provider,
                session_dir,
                options,
                tool_items,
                app_state,
                editor,
                overlay,
                auth_flow,
                prompt_worker,
                prompt_worker_active,
                subscriber,
                should_exit,
                live_resources,
            );
            return;
        },
        else => {},
    }

    const handled = try editor.handleKey(key);
    switch (handled) {
        .interrupt => {
            if (prompt_worker_active.*) {
                session.agent.abort();
                try app_state.setStatus("interrupt requested");
            }
        },
        .exit => {
            should_exit.* = true;
            if (prompt_worker_active.*) session.agent.abort();
        },
        else => {},
    }
}

pub fn submitEditorText(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    trimmed: []const u8,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker: *PromptWorker,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    live_resources: *LiveResources,
) !void {
    if (parseSlashCommand(trimmed)) |command| {
        try handleSlashCommand(
            allocator,
            io,
            env_map,
            command,
            session,
            current_provider,
            session_dir,
            options,
            tool_items,
            app_state,
            overlay,
            auth_flow,
            prompt_worker_active,
            subscriber,
            should_exit,
            live_resources,
        );
        clearEditor(app_state, editor);
        return;
    }

    const expanded = try resources_mod.expandPromptTemplate(allocator, trimmed, live_resources.prompt_templates);
    defer allocator.free(expanded);

    if (trimmed.len > 0 and trimmed[0] == '/' and std.mem.eql(u8, expanded, trimmed)) {
        const message = try std.fmt.allocPrint(allocator, "Unknown slash command: {s}", .{trimmed});
        defer allocator.free(message);
        clearEditor(app_state, editor);
        try app_state.appendError(message);
        return;
    }

    if (prompt_worker_active.*) {
        try app_state.setStatus("response in progress");
        return;
    }

    const prompt_images = try app_state.clonePendingEditorImages(allocator);
    defer prompt_worker_mod.deinitImageContents(allocator, prompt_images);

    try prompt_worker.start(allocator, session, app_state, expanded, prompt_images);
    prompt_worker_active.* = true;
    clearEditor(app_state, editor);
    try app_state.setStatus("thinking");
}

fn handlePasteImageAction(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    app_state: *AppState,
) !void {
    var image = (try clipboard_image.readClipboardImage(allocator, io, env_map)) orelse return;
    defer image.deinit(allocator);

    const encoded = try clipboard_image.encodeImageContent(allocator, image);
    errdefer {
        var encoded_copy = encoded;
        clipboard_image.deinitImageContent(allocator, &encoded_copy);
    }

    try app_state.appendPendingEditorImage(encoded);
    try app_state.setStatus("clipboard image pasted");
}

pub fn clearEditor(app_state: *AppState, editor: *tui.Editor) void {
    editor.reset();
    app_state.clearPendingEditorImages();
}

pub fn loadEditorAutocompleteItems(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]tui.SelectItem {
    var dir = try std.Io.Dir.openDirAbsolute(io, cwd, .{ .iterate = true });
    defer dir.close(io);

    var items = std.ArrayList(tui.SelectItem).empty;
    errdefer {
        freeOwnedSelectItems(allocator, items.items);
        items.deinit(allocator);
    }

    for (BUILTIN_SLASH_COMMANDS) |command| {
        const value = if (command.argument_hint != null)
            try std.fmt.allocPrint(allocator, "/{s} ", .{command.name})
        else
            try std.fmt.allocPrint(allocator, "/{s}", .{command.name});
        errdefer allocator.free(value);
        const label = if (command.argument_hint) |argument_hint|
            try std.fmt.allocPrint(allocator, "/{s} {s}", .{ command.name, argument_hint })
        else
            try std.fmt.allocPrint(allocator, "/{s}", .{command.name});
        errdefer allocator.free(label);
        const description = try allocator.dupe(u8, command.description);
        errdefer allocator.free(description);

        try items.append(allocator, .{
            .value = value,
            .label = label,
            .description = description,
        });
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;

        const is_directory = entry.kind == .directory;
        const display = if (is_directory)
            try std.fmt.allocPrint(allocator, "{s}/", .{entry.name})
        else
            try allocator.dupe(u8, entry.name);
        errdefer allocator.free(display);
        const label = try allocator.dupe(u8, display);
        errdefer allocator.free(label);
        const description = try allocator.dupe(u8, if (is_directory) "directory" else "file");
        errdefer allocator.free(description);

        try items.append(allocator, .{
            .value = display,
            .label = label,
            .description = description,
        });
    }

    std.mem.sort(tui.SelectItem, items.items, {}, struct {
        fn lessThan(_: void, lhs: tui.SelectItem, rhs: tui.SelectItem) bool {
            const lhs_slash = std.mem.startsWith(u8, lhs.value, "/");
            const rhs_slash = std.mem.startsWith(u8, rhs.value, "/");
            if (lhs_slash != rhs_slash) return lhs_slash;
            const lhs_dir = std.mem.endsWith(u8, lhs.value, "/");
            const rhs_dir = std.mem.endsWith(u8, rhs.value, "/");
            if (lhs_dir != rhs_dir) return lhs_dir;
            return std.mem.order(u8, lhs.label, rhs.label) == .lt;
        }
    }.lessThan);

    return try items.toOwnedSlice(allocator);
}

pub fn freeOwnedSelectItems(allocator: std.mem.Allocator, items: []tui.SelectItem) void {
    for (items) |item| {
        allocator.free(item.value);
        allocator.free(item.label);
        if (item.description) |description| allocator.free(description);
    }
    allocator.free(items);
}

pub fn pollForInput() !bool {
    var fds = [_]std.posix.pollfd{
        .{
            .fd = 0,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    return (try std.posix.poll(fds[0..], 50)) > 0;
}

pub fn dispatchInputEvent(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    parsed: tui.keys.ParsedInput,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    tool_items: []const agent.AgentTool,
    app_state: *AppState,
    editor: *tui.Editor,
    overlay: *?SelectorOverlay,
    auth_flow: *?AuthFlow,
    prompt_worker: *PromptWorker,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    input_buffer: *std.ArrayList(u8),
    app_context: *AppContext,
    live_resources: *LiveResources,
) !void {
    switch (parsed.event) {
        .key => |key| {
            if (parsed.event_type == .release) {
                consumeInputBytes(input_buffer, parsed.consumed);
                return;
            }
            try handleInputKey(
                allocator,
                io,
                env_map,
                key,
                session,
                current_provider,
                session_dir,
                options,
                tool_items,
                app_state,
                editor,
                overlay,
                auth_flow,
                prompt_worker,
                prompt_worker_active,
                subscriber,
                should_exit,
                live_resources,
            );
        },
        .paste => |content| {
            if (overlay.* != null) {
                consumeInputBytes(input_buffer, parsed.consumed);
                return;
            }
            _ = try editor.handlePaste(content);
        },
        .protocol => |protocol| handleProtocolEvent(app_context, protocol),
    }
    consumeInputBytes(input_buffer, parsed.consumed);
}

fn handleProtocolEvent(app_context: *AppContext, protocol: tui.keys.ProtocolEvent) void {
    switch (protocol) {
        .kitty_keyboard => app_context.kitty_protocol_active = true,
    }
}

pub fn consumeInputBytes(buffer: *std.ArrayList(u8), consumed: usize) void {
    if (consumed >= buffer.items.len) {
        buffer.clearRetainingCapacity();
        return;
    }
    std.mem.copyForwards(u8, buffer.items[0 .. buffer.items.len - consumed], buffer.items[consumed..]);
    buffer.items.len -= consumed;
}

pub fn resolveAppAction(keybindings: ?*const keybindings_mod.Keybindings, key: tui.Key) ?keybindings_mod.Action {
    if (keybindings) |bindings| return bindings.actionForKey(key);
    return legacyAppActionForKey(key);
}

pub fn legacyAppActionForKey(key: tui.Key) ?keybindings_mod.Action {
    return switch (key) {
        .ctrl => |ctrl| switch (ctrl) {
            'c' => .interrupt,
            'd' => .exit,
            'l' => .clear,
            's' => .open_sessions,
            'p' => .open_models,
            'v' => .paste_image,
            else => null,
        },
        .escape => .exit,
        else => null,
    };
}

pub fn isLegacyAppActionKey(key: tui.Key) bool {
    return legacyAppActionForKey(key) != null;
}

pub fn handleAppAction(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    action: keybindings_mod.Action,
    session: *session_mod.AgentSession,
    session_dir: []const u8,
    model_patterns: ?[]const []const u8,
    runtime_config: ?*const config_mod.RuntimeConfig,
    app_state: *AppState,
    overlay: *?SelectorOverlay,
    prompt_worker_active: *bool,
    should_exit: *bool,
) !void {
    switch (action) {
        .interrupt => {
            if (prompt_worker_active.*) {
                session.agent.abort();
                try app_state.setStatus("interrupt requested");
            }
        },
        .exit => {
            should_exit.* = true;
            if (prompt_worker_active.*) session.agent.abort();
        },
        .clear => app_state.clearDisplay(),
        .open_sessions => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before switching sessions");
                return;
            }
            overlay.* = try loadSessionOverlay(allocator, io, session_dir);
        },
        .open_models => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("wait for the current response to finish before switching models");
                return;
            }
            overlay.* = try loadModelOverlay(allocator, env_map, session.agent.getModel(), model_patterns, runtime_config);
        },
        .paste_image => {},
    }
}

test "protocol events update kitty state through app context" {
    var app_context = AppContext.init("/tmp", std.testing.io);
    try std.testing.expect(!app_context.kitty_protocol_active);

    handleProtocolEvent(&app_context, .{ .kitty_keyboard = 31 });

    try std.testing.expect(app_context.kitty_protocol_active);
}

test "legacy app actions include clipboard image paste" {
    try std.testing.expectEqual(keybindings_mod.Action.paste_image, legacyAppActionForKey(.{ .ctrl = 'v' }).?);
}
