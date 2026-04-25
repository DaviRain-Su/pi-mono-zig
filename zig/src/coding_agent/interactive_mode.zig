const builtin = @import("builtin");
const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tui = @import("tui");
const config_mod = @import("config.zig");
const keybindings_mod = @import("keybindings.zig");
const provider_config = @import("provider_config.zig");
const resources_mod = @import("resources.zig");
const session_mod = @import("session.zig");
const session_advanced = @import("session_advanced.zig");
const session_manager_mod = @import("session_manager.zig");
const tools = @import("tools/root.zig");
const common = @import("tools/common.zig");

pub const ToolRuntime = struct {
    cwd: []const u8,
    io: std.Io,
};

/// Process-global tool runtime bridge for interactive mode.
///
/// `buildAgentTools()` registers plain `agent.types.ExecuteToolFn` callbacks, so the per-session `cwd`
/// and `std.Io` handle needed by the tool implementations cannot be threaded through as parameters.
/// Interactive mode therefore publishes that context here before starting agent work so tool callbacks in
/// this module can reach the shared runtime without changing the agent/tool API surface.
///
/// Thread-safety model: interactive mode owns this slot on a single thread, writes it once during setup,
/// only performs read-only access while the session is active, and clears it during teardown. It is global
/// mutable state because the execute callback ABI has no user-data parameter, not because multiple runtimes
/// are expected to coexist.
var global_tool_runtime: ?ToolRuntime = null;

pub fn setToolRuntime(runtime: ToolRuntime) void {
    global_tool_runtime = runtime;
}

pub fn clearToolRuntime() void {
    global_tool_runtime = null;
}

pub const RunInteractiveModeOptions = struct {
    cwd: []const u8,
    system_prompt: []const u8,
    session_dir: []const u8,
    provider: []const u8,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    thinking: agent.ThinkingLevel = .off,
    session: ?[]const u8 = null,
    @"continue": bool = false,
    selected_tools: ?[]const []const u8 = null,
    initial_prompt: ?[]const u8 = null,
    prompt_templates: []const resources_mod.PromptTemplate = &.{},
    keybindings: ?*const keybindings_mod.Keybindings = null,
    theme: ?*const resources_mod.Theme = null,
    runtime_config: ?*const config_mod.RuntimeConfig = null,
};

const ChatKind = enum {
    welcome,
    info,
    @"error",
    user,
    assistant,
    tool_call,
    tool_result,
};

const ChatItem = struct {
    kind: ChatKind,
    text: []u8,
};

const ASSISTANT_PREFIX = "Pi:";

const SlashCommandKind = enum {
    model,
    session,
    tree,
    fork,
    clone,
    compact,
    login,
    @"resume",
    reload,
    @"export",
    quit,
};

const SlashCommand = struct {
    kind: SlashCommandKind,
    argument: ?[]const u8 = null,
    raw: []const u8,
};

const LiveResources = struct {
    runtime_config: ?*const config_mod.RuntimeConfig,
    keybindings: ?*const keybindings_mod.Keybindings,
    prompt_templates: []const resources_mod.PromptTemplate,
    theme: ?*const resources_mod.Theme,
    owned_runtime_config: ?config_mod.RuntimeConfig = null,
    owned_resource_bundle: ?resources_mod.ResourceBundle = null,

    fn init(options: RunInteractiveModeOptions) LiveResources {
        return .{
            .runtime_config = options.runtime_config,
            .keybindings = options.keybindings,
            .prompt_templates = options.prompt_templates,
            .theme = options.theme,
        };
    }

    fn deinit(self: *LiveResources, allocator: std.mem.Allocator) void {
        if (self.owned_resource_bundle) |*bundle| {
            bundle.deinit(allocator);
            self.owned_resource_bundle = null;
        }
        if (self.owned_runtime_config) |*runtime_config| {
            runtime_config.deinit();
            self.owned_runtime_config = null;
        }
    }

    fn reload(
        self: *LiveResources,
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        cwd: []const u8,
    ) ![]const resources_mod.Diagnostic {
        var next_runtime = try config_mod.loadRuntimeConfig(allocator, io, env_map, cwd);
        errdefer next_runtime.deinit();

        var next_bundle = try resources_mod.loadResourceBundle(allocator, io, .{
            .cwd = cwd,
            .agent_dir = next_runtime.agent_dir,
            .global = settingsResources(next_runtime.global_settings),
            .project = settingsResources(next_runtime.project_settings),
        });
        errdefer next_bundle.deinit(allocator);

        self.deinit(allocator);
        self.owned_runtime_config = next_runtime;
        self.owned_resource_bundle = next_bundle;
        self.runtime_config = &self.owned_runtime_config.?;
        self.keybindings = &self.owned_runtime_config.?.keybindings;
        self.prompt_templates = self.owned_resource_bundle.?.prompt_templates;
        self.theme = self.owned_resource_bundle.?.selectedTheme();
        return self.owned_resource_bundle.?.diagnostics;
    }
};

const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(ChatItem) = .empty,
    visible_start_index: usize = 0,
    last_streaming_assistant_index: ?usize = null,
    status: []u8 = &.{},
    model_label: []u8 = &.{},
    session_label: []u8 = &.{},

    fn init(allocator: std.mem.Allocator, io: std.Io) !AppState {
        var state = AppState{
            .allocator = allocator,
            .io = io,
        };
        errdefer state.deinit();
        state.status = try allocator.dupe(u8, "idle");
        state.model_label = try allocator.dupe(u8, "unknown");
        state.session_label = try allocator.dupe(u8, "new");
        try state.appendItemLocked(.welcome, "Welcome to pi (Zig interactive mode). Type a prompt and press Enter.");
        return state;
    }

    fn deinit(self: *AppState) void {
        for (self.items.items) |item| self.allocator.free(item.text);
        self.items.deinit(self.allocator);
        self.allocator.free(self.status);
        self.allocator.free(self.model_label);
        self.allocator.free(self.session_label);
        self.* = undefined;
    }

    fn clearDisplay(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.visible_start_index = self.items.items.len;
        self.replaceLabelLocked(&self.status, "display cleared") catch {};
    }

    fn setFooter(self: *AppState, model_label: []const u8, session_label: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.replaceLabelLocked(&self.model_label, model_label);
        try self.replaceLabelLocked(&self.session_label, session_label);
    }

    fn setStatus(self: *AppState, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.replaceLabelLocked(&self.status, text);
    }

    fn appendInfo(self: *AppState, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.appendItemLocked(.info, text);
    }

    fn appendError(self: *AppState, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.appendItemLocked(.@"error", text);
        try self.replaceLabelLocked(&self.status, text);
    }

    fn rebuildFromMessages(
        self: *AppState,
        session_label: []const u8,
        model_label: []const u8,
        messages: []const agent.AgentMessage,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.items.items) |item| self.allocator.free(item.text);
        self.items.clearRetainingCapacity();
        self.visible_start_index = 0;
        self.last_streaming_assistant_index = null;

        try self.replaceLabelLocked(&self.status, "idle");
        try self.replaceLabelLocked(&self.model_label, model_label);
        try self.replaceLabelLocked(&self.session_label, session_label);
        try self.appendItemLocked(.welcome, "Welcome to pi (Zig interactive mode). Type a prompt and press Enter.");

        for (messages) |message| {
            switch (message) {
                .user => |user_message| {
                    const rendered = try formatPrefixedBlocks(self.allocator, "You", user_message.content);
                    defer self.allocator.free(rendered);
                    try self.appendItemLocked(.user, rendered);
                },
                .assistant => |assistant_message| {
                    const rendered = try formatAssistantMessage(self.allocator, assistant_message);
                    defer self.allocator.free(rendered);
                    if (rendered.len > 0) {
                        try self.appendItemLocked(.assistant, rendered);
                    }
                    if (assistant_message.tool_calls) |tool_calls| {
                        for (tool_calls) |tool_call| {
                            const tool_text = try formatToolCall(self.allocator, tool_call.name, tool_call.arguments);
                            defer self.allocator.free(tool_text);
                            try self.appendItemLocked(.tool_call, tool_text);
                        }
                    }
                },
                .tool_result => |tool_result| {
                    const rendered = try formatToolResult(self.allocator, tool_result.tool_name, tool_result.content, tool_result.is_error);
                    defer self.allocator.free(rendered);
                    try self.appendItemLocked(.tool_result, rendered);
                },
            }
        }
    }

    fn handleAgentEvent(self: *AppState, event: agent.AgentEvent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        switch (event.event_type) {
            .agent_start => try self.replaceLabelLocked(&self.status, "streaming"),
            .agent_end => {
                if (std.mem.eql(u8, self.status, "streaming")) {
                    try self.replaceLabelLocked(&self.status, "idle");
                }
            },
            .message_start => {
                if (event.message) |message| switch (message) {
                    .assistant => {
                        try self.appendItemLocked(.assistant, "");
                        self.last_streaming_assistant_index = self.items.items.len - 1;
                        try self.replaceLabelLocked(&self.status, "streaming");
                    },
                    else => {},
                };
            },
            .message_update => {
                if (event.message) |message| switch (message) {
                    .assistant => |assistant_message| {
                        const rendered = try formatAssistantMessage(self.allocator, assistant_message);
                        defer self.allocator.free(rendered);
                        const target_index = self.last_streaming_assistant_index orelse blk: {
                            try self.appendItemLocked(.assistant, rendered);
                            self.last_streaming_assistant_index = self.items.items.len - 1;
                            break :blk self.last_streaming_assistant_index.?;
                        };
                        try self.replaceItemTextLocked(target_index, rendered);
                    },
                    else => {},
                };
            },
            .message_end => {
                if (event.message) |message| switch (message) {
                    .user => |user_message| {
                        const rendered = try formatPrefixedBlocks(self.allocator, "You", user_message.content);
                        defer self.allocator.free(rendered);
                        try self.appendItemLocked(.user, rendered);
                    },
                    .assistant => |assistant_message| {
                        const rendered = try formatAssistantMessage(self.allocator, assistant_message);
                        defer self.allocator.free(rendered);
                        if (self.last_streaming_assistant_index) |index| {
                            if (rendered.len == 0) {
                                self.removeItemLocked(index);
                            } else {
                                try self.replaceItemTextLocked(index, rendered);
                            }
                        } else if (rendered.len > 0) {
                            try self.appendItemLocked(.assistant, rendered);
                        }
                        self.last_streaming_assistant_index = null;

                        switch (assistant_message.stop_reason) {
                            .aborted => try self.replaceLabelLocked(&self.status, "interrupted"),
                            .error_reason => try self.replaceLabelLocked(
                                &self.status,
                                assistant_message.error_message orelse "error",
                            ),
                            else => {},
                        }
                    },
                    .tool_result => {},
                };
            },
            .tool_execution_start => {
                const tool_name = event.tool_name orelse "tool";
                const args_value = event.args orelse .null;
                const rendered = try formatToolCall(self.allocator, tool_name, args_value);
                defer self.allocator.free(rendered);
                try self.appendItemLocked(.tool_call, rendered);
                const status_text = try std.fmt.allocPrint(self.allocator, "tool: {s}", .{tool_name});
                defer self.allocator.free(status_text);
                try self.replaceLabelLocked(&self.status, status_text);
            },
            .tool_execution_end => {
                const tool_name = event.tool_name orelse "tool";
                const result = event.result orelse return;
                const rendered = try formatToolResult(self.allocator, tool_name, result.content, event.is_error orelse false);
                defer self.allocator.free(rendered);
                try self.appendItemLocked(.tool_result, rendered);
                try self.replaceLabelLocked(&self.status, "streaming");
            },
            else => {},
        }
    }

    fn appendItemLocked(self: *AppState, kind: ChatKind, text: []const u8) !void {
        try self.items.append(self.allocator, .{
            .kind = kind,
            .text = try self.allocator.dupe(u8, text),
        });
    }

    fn replaceItemTextLocked(self: *AppState, index: usize, text: []const u8) !void {
        if (index >= self.items.items.len) return;
        self.allocator.free(self.items.items[index].text);
        self.items.items[index].text = try self.allocator.dupe(u8, text);
    }

    fn removeItemLocked(self: *AppState, index: usize) void {
        if (index >= self.items.items.len) return;
        self.allocator.free(self.items.items[index].text);
        _ = self.items.orderedRemove(index);
        if (self.visible_start_index > self.items.items.len) {
            self.visible_start_index = self.items.items.len;
        }
    }

    fn replaceLabelLocked(self: *AppState, field: *[]u8, text: []const u8) !void {
        self.allocator.free(field.*);
        field.* = try self.allocator.dupe(u8, text);
    }
};

const SelectorOverlay = union(enum) {
    session: SessionOverlay,
    model: ModelOverlay,
    tree: TreeOverlay,

    fn deinit(self: *SelectorOverlay, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .session => |*overlay| overlay.deinit(allocator),
            .model => |*overlay| overlay.deinit(allocator),
            .tree => |*overlay| overlay.deinit(allocator),
        }
        self.* = undefined;
    }

    fn title(self: *const SelectorOverlay) []const u8 {
        return switch (self.*) {
            .session => "Session selector",
            .model => "Model selector",
            .tree => "Session tree",
        };
    }

    fn hint(self: *const SelectorOverlay) []const u8 {
        _ = self;
        return "Up/Down move • Enter select • Esc cancel";
    }

    fn list(self: *SelectorOverlay) *tui.SelectList {
        return switch (self.*) {
            .session => &self.session.list,
            .model => &self.model.list,
            .tree => &self.tree.list,
        };
    }
};

const SessionChoice = struct {
    path: []u8,
};

const SessionOverlay = struct {
    choices: []SessionChoice,
    items: []tui.SelectItem,
    list: tui.SelectList,

    fn deinit(self: *SessionOverlay, allocator: std.mem.Allocator) void {
        for (self.choices) |choice| allocator.free(choice.path);
        allocator.free(self.choices);
        for (self.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

const ModelChoice = struct {
    provider: []u8,
    model_id: []u8,
};

const ModelOverlay = struct {
    choices: []ModelChoice,
    items: []tui.SelectItem,
    list: tui.SelectList,

    fn deinit(self: *ModelOverlay, allocator: std.mem.Allocator) void {
        for (self.choices) |choice| {
            allocator.free(choice.provider);
            allocator.free(choice.model_id);
        }
        allocator.free(self.choices);
        for (self.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

const TreeChoice = struct {
    entry_id: []u8,
};

const TreeOverlay = struct {
    choices: []TreeChoice,
    items: []tui.SelectItem,
    list: tui.SelectList,

    fn deinit(self: *TreeOverlay, allocator: std.mem.Allocator) void {
        for (self.choices) |choice| allocator.free(choice.entry_id);
        allocator.free(self.choices);
        for (self.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

const ScreenComponent = struct {
    state: *AppState,
    editor: *tui.Editor,
    height: usize = 24,
    overlay: ?*SelectorOverlay = null,
    keybindings: ?*const keybindings_mod.Keybindings = null,
    theme: ?*const resources_mod.Theme = null,

    fn component(self: *const ScreenComponent) tui.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *tui.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const ScreenComponent = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }

    fn renderInto(
        self: *const ScreenComponent,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *tui.LineList,
    ) std.mem.Allocator.Error!void {
        if (self.overlay) |overlay| {
            try self.renderOverlay(allocator, width, lines, overlay);
            return;
        }

        var chat_lines = tui.LineList.empty;
        defer freeLinesSafe(allocator, &chat_lines);

        self.state.mutex.lockUncancelable(self.state.io);
        defer self.state.mutex.unlock(self.state.io);

        const start_index = @min(self.state.visible_start_index, self.state.items.items.len);
        for (self.state.items.items[start_index..]) |item| {
            try renderChatItemInto(allocator, @max(width, 1), self.theme, item, &chat_lines);
        }

        var prompt_lines = tui.LineList.empty;
        defer freeLinesSafe(allocator, &prompt_lines);
        try renderPromptLines(allocator, self.editor, width, &prompt_lines);
        const footer_line = try formatFooterLine(
            allocator,
            self.theme,
            self.state.model_label,
            self.state.session_label,
            self.state.status,
            width,
        );
        defer allocator.free(footer_line);
        const hints_line = try formatHintsLine(allocator, self.keybindings, self.theme, width);
        defer allocator.free(hints_line);

        var autocomplete_lines = tui.LineList.empty;
        defer freeLinesSafe(allocator, &autocomplete_lines);
        try self.editor.renderAutocompleteInto(allocator, width, &autocomplete_lines);

        const reserved_lines: usize = prompt_lines.items.len + 2 + autocomplete_lines.items.len;
        const chat_capacity = if (self.height > reserved_lines) self.height - reserved_lines else 1;
        const visible_chat_start = if (chat_lines.items.len > chat_capacity) chat_lines.items.len - chat_capacity else 0;
        for (chat_lines.items[visible_chat_start..]) |line| {
            try tui.component.appendOwnedLine(lines, allocator, line);
        }
        for (prompt_lines.items) |line| {
            try tui.component.appendOwnedLine(lines, allocator, line);
        }
        for (autocomplete_lines.items) |line| {
            try tui.component.appendOwnedLine(lines, allocator, line);
        }
        try tui.component.appendOwnedLine(lines, allocator, footer_line);
        try tui.component.appendOwnedLine(lines, allocator, hints_line);
    }

    fn renderOverlay(
        self: *const ScreenComponent,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *tui.LineList,
        overlay: *SelectorOverlay,
    ) std.mem.Allocator.Error!void {
        const title_plain = try fitLine(allocator, overlay.title(), width);
        defer allocator.free(title_plain);
        const title_line = try applyThemeAlloc(allocator, self.theme, .footer, title_plain);
        defer allocator.free(title_line);
        const hint_plain = try fitLine(allocator, overlay.hint(), width);
        defer allocator.free(hint_plain);
        const hint_line = try applyThemeAlloc(allocator, self.theme, .status, hint_plain);
        defer allocator.free(hint_line);

        try tui.component.appendOwnedLine(lines, allocator, title_line);
        try tui.component.appendOwnedLine(lines, allocator, hint_line);

        var list_lines = tui.LineList.empty;
        defer freeLinesSafe(allocator, &list_lines);
        try overlay.list().renderInto(allocator, width, &list_lines);

        const available_rows = if (self.height > 2) self.height - 2 else list_lines.items.len;
        for (list_lines.items[0..@min(available_rows, list_lines.items.len)]) |line| {
            try tui.component.appendOwnedLine(lines, allocator, line);
        }
    }
};

const NativeTerminalBackend = struct {
    env_map: *const std.process.Environ.Map,
    stdin_fd: std.posix.fd_t = 0,
    stdout_fd: std.posix.fd_t = 1,
    original_termios: ?std.posix.termios = null,
    cached_size: tui.Size = .{ .width = 80, .height = 24 },
    resize_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    previous_sigwinch: ?std.posix.Sigaction = null,
    resize_signal_installed: bool = false,
    read_terminal_size_fn: *const fn (context: ?*anyopaque, fd: std.posix.fd_t) ?tui.Size = readTerminalSizeWithIoctl,
    read_terminal_size_context: ?*anyopaque = null,

    fn backend(self: *NativeTerminalBackend) tui.Backend {
        return .{
            .ptr = self,
            .enterRawModeFn = enterRawMode,
            .restoreModeFn = restoreMode,
            .writeFn = write,
            .getSizeFn = getSize,
        };
    }

    fn enterRawMode(ptr: *anyopaque) !void {
        const self: *NativeTerminalBackend = @ptrCast(@alignCast(ptr));
        const current = try std.posix.tcgetattr(self.stdin_fd);
        self.original_termios = current;
        const raw = tui.terminal.makeRawMode(current);
        try std.posix.tcsetattr(self.stdin_fd, .NOW, raw);
        self.cached_size = self.readSize();
        self.resize_pending.store(false, .seq_cst);
        self.installResizeHandler();
    }

    fn restoreMode(ptr: *anyopaque) !void {
        const self: *NativeTerminalBackend = @ptrCast(@alignCast(ptr));
        self.uninstallResizeHandler();
        if (self.original_termios) |term| {
            try std.posix.tcsetattr(self.stdin_fd, .NOW, term);
        }
    }

    fn write(ptr: *anyopaque, bytes: []const u8) !void {
        const self: *NativeTerminalBackend = @ptrCast(@alignCast(ptr));
        var offset: usize = 0;
        while (offset < bytes.len) {
            const written = std.c.write(self.stdout_fd, bytes.ptr + offset, bytes.len - offset);
            if (written <= 0) return error.WriteFailed;
            offset += @intCast(written);
        }
    }

    fn getSize(ptr: *anyopaque) !tui.Size {
        const self: *NativeTerminalBackend = @ptrCast(@alignCast(ptr));
        self.refreshSizeIfPending();
        return self.cached_size;
    }

    fn readSize(self: *NativeTerminalBackend) tui.Size {
        if (self.read_terminal_size_fn(self.read_terminal_size_context, self.stdout_fd)) |size| {
            return normalizeTerminalSize(size, self.cached_size);
        }

        const columns = parseEnvSize(self.env_map.get("COLUMNS")) orelse self.cached_size.width;
        const lines = parseEnvSize(self.env_map.get("LINES")) orelse self.cached_size.height;
        return .{
            .width = if (columns == 0) 80 else columns,
            .height = if (lines == 0) 24 else lines,
        };
    }

    fn refreshSizeIfPending(self: *NativeTerminalBackend) void {
        if (!self.resize_pending.swap(false, .seq_cst)) return;
        self.cached_size = self.readSize();
    }

    fn installResizeHandler(self: *NativeTerminalBackend) void {
        if (!supportsResizeSignals()) return;

        const action: std.posix.Sigaction = .{
            .handler = .{ .sigaction = handleSigwinch },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO | std.posix.SA.RESTART,
        };

        var previous: std.posix.Sigaction = undefined;
        std.posix.sigaction(.WINCH, &action, &previous);
        self.previous_sigwinch = previous;
        self.resize_signal_installed = true;
        active_resize_backend = self;
    }

    fn uninstallResizeHandler(self: *NativeTerminalBackend) void {
        if (!self.resize_signal_installed or !supportsResizeSignals()) return;

        if (self.previous_sigwinch) |previous| {
            std.posix.sigaction(.WINCH, &previous, null);
        }
        if (active_resize_backend == self) {
            active_resize_backend = null;
        }
        self.previous_sigwinch = null;
        self.resize_signal_installed = false;
    }
};

/// Process-global pointer to the native terminal backend that should receive `SIGWINCH` notifications.
///
/// POSIX signal handlers must use a plain C callback (`handleSigwinch`) and cannot capture `self`, so the
/// active backend is published here instead of being passed as a parameter. The handler only reads this
/// pointer and atomically sets `resize_pending`; the interactive-mode thread remains responsible for calling
/// `readSize()`, updating `cached_size`, and installing/removing the handler.
///
/// Thread-safety model: this relies on single-owner discipline rather than shared mutable access. Only one
/// interactive backend may install the resize handler at a time, and the only cross-context mutation is the
/// atomic `resize_pending` flag on the backend instance.
var active_resize_backend: ?*NativeTerminalBackend = null;

fn supportsResizeSignals() bool {
    return switch (builtin.os.tag) {
        .windows, .wasi, .emscripten, .freestanding => false,
        else => true,
    };
}

fn handleSigwinch(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    _ = info;
    _ = ctx_ptr;
    if (sig != .WINCH) return;
    if (active_resize_backend) |backend| {
        backend.resize_pending.store(true, .seq_cst);
    }
}

fn readTerminalSizeWithIoctl(_: ?*anyopaque, fd: std.posix.fd_t) ?tui.Size {
    var winsize: std.posix.winsize = undefined;
    while (true) switch (std.posix.errno(std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize)))) {
        .SUCCESS => return .{
            .width = winsize.col,
            .height = winsize.row,
        },
        .INTR => continue,
        else => return null,
    };
}

fn normalizeTerminalSize(size: tui.Size, fallback: tui.Size) tui.Size {
    return .{
        .width = if (size.width == 0)
            if (fallback.width == 0) 80 else fallback.width
        else
            size.width,
        .height = if (size.height == 0)
            if (fallback.height == 0) 24 else fallback.height
        else
            size.height,
    };
}

const PromptWorker = struct {
    session: *session_mod.AgentSession,
    app_state: *AppState,
    prompt_text: []u8 = &.{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    fn start(self: *PromptWorker, allocator: std.mem.Allocator, session: *session_mod.AgentSession, app_state: *AppState, prompt_text: []const u8) !void {
        self.session = session;
        self.app_state = app_state;
        self.prompt_text = try allocator.dupe(u8, prompt_text);
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, run, .{ self, allocator });
    }

    fn join(self: *PromptWorker, allocator: std.mem.Allocator) void {
        if (self.thread) |thread| thread.join();
        if (self.prompt_text.len > 0) allocator.free(self.prompt_text);
        self.prompt_text = &.{};
        self.thread = null;
        self.running.store(false, .seq_cst);
    }

    fn run(self: *PromptWorker, allocator: std.mem.Allocator) void {
        defer self.running.store(false, .seq_cst);
        self.session.prompt(self.prompt_text) catch |err| {
            const message = std.fmt.allocPrint(allocator, "error: {s}", .{@errorName(err)}) catch return;
            defer allocator.free(message);
            self.app_state.setStatus(message) catch {};
        };
    }
};

pub fn runInteractiveMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    options: RunInteractiveModeOptions,
    stderr_writer: *std.Io.Writer,
) !u8 {
    var live_resources = LiveResources.init(options);
    defer live_resources.deinit(allocator);

    var current_provider = provider_config.resolveProviderConfig(
        allocator,
        env_map,
        options.provider,
        options.model,
        options.api_key,
        configuredApiKeyForProvider(live_resources.runtime_config, options.provider),
    ) catch |err| {
        try stderr_writer.print("Error: {s}\n", .{provider_config.resolveProviderErrorMessage(err, options.provider)});
        try stderr_writer.flush();
        return 1;
    };
    defer current_provider.deinit(allocator);

    setToolRuntime(.{
        .cwd = options.cwd,
        .io = io,
    });
    defer clearToolRuntime();

    var built_tools = try buildAgentTools(allocator, options.selected_tools);
    defer built_tools.deinit();

    var session = try openInitialSession(
        allocator,
        io,
        options.session_dir,
        options,
        current_provider.model,
        current_provider.api_key,
        built_tools.items,
    );
    defer session.deinit();

    var app_state = try AppState.init(allocator, io);
    defer app_state.deinit();

    const subscriber = agent.AgentSubscriber{
        .context = &app_state,
        .callback = handleAppAgentEvent,
    };
    try session.agent.subscribe(subscriber);
    defer _ = session.agent.unsubscribe(subscriber);

    try app_state.rebuildFromMessages(
        currentSessionLabel(&session),
        current_provider.model.id,
        session.agent.getMessages(),
    );

    var backend = NativeTerminalBackend{ .env_map = env_map };
    var terminal = tui.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = tui.Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
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

    var prompt_worker: PromptWorker = undefined;
    var prompt_worker_active = false;
    defer if (prompt_worker_active) {
        session.agent.abort();
        prompt_worker.join(allocator);
    };

    if (options.initial_prompt) |initial_prompt| {
        if (initial_prompt.len > 0) {
            try prompt_worker.start(allocator, &session, &app_state, initial_prompt);
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

        const size = try terminal.refreshSize();
        screen.height = size.height;
        screen.overlay = if (overlay) |*value| value else null;
        screen.keybindings = live_resources.keybindings;
        screen.theme = live_resources.theme;
        try renderer.render(screen.component());

        if (should_exit and !prompt_worker_active) break;

        if (try pollForInput()) {
            var read_buffer: [64]u8 = undefined;
            const bytes_read = std.posix.read(0, &read_buffer) catch 0;
            if (bytes_read == 0) {
                should_exit = true;
                continue;
            }
            try input_buffer.appendSlice(allocator, read_buffer[0..bytes_read]);
            while (tui.keys.parseInputEvent(input_buffer.items)) |result| {
                switch (result) {
                    .parsed => |parsed| try dispatchInputEvent(
                        allocator,
                        io,
                        env_map,
                        parsed,
                        &session,
                        &current_provider,
                        options.session_dir,
                        options,
                        built_tools.items,
                        &app_state,
                        &editor,
                        &overlay,
                        &prompt_worker,
                        &prompt_worker_active,
                        subscriber,
                        &should_exit,
                        &input_buffer,
                        &live_resources,
                    ),
                    .need_more_bytes => break,
                }
            }
        } else if (tui.keys.flushInputEvent(input_buffer.items)) |parsed| {
            try dispatchInputEvent(
                allocator,
                io,
                env_map,
                parsed,
                &session,
                &current_provider,
                options.session_dir,
                options,
                built_tools.items,
                &app_state,
                &editor,
                &overlay,
                &prompt_worker,
                &prompt_worker_active,
                subscriber,
                &should_exit,
                &input_buffer,
                &live_resources,
            );
            while (tui.keys.parseInputEvent(input_buffer.items)) |result| {
                switch (result) {
                    .parsed => |next_parsed| try dispatchInputEvent(
                        allocator,
                        io,
                        env_map,
                        next_parsed,
                        &session,
                        &current_provider,
                        options.session_dir,
                        options,
                        built_tools.items,
                        &app_state,
                        &editor,
                        &overlay,
                        &prompt_worker,
                        &prompt_worker_active,
                        subscriber,
                        &should_exit,
                        &input_buffer,
                        &live_resources,
                    ),
                    .need_more_bytes => break,
                }
            }
        }
    }

    return 0;
}

pub const BuiltTools = struct {
    allocator: std.mem.Allocator,
    items: []agent.AgentTool,

    pub fn deinit(self: *BuiltTools) void {
        for (self.items) |item| common.deinitJsonValue(self.allocator, item.parameters);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn buildAgentTools(allocator: std.mem.Allocator, selected_tools: ?[]const []const u8) !BuiltTools {
    var items = std.ArrayList(agent.AgentTool).empty;
    errdefer {
        for (items.items) |item| common.deinitJsonValue(allocator, item.parameters);
        items.deinit(allocator);
    }

    try appendToolIfEnabled(allocator, &items, selected_tools, tools.ReadTool.name, tools.ReadTool.description, try tools.ReadTool.schema(allocator), runReadTool);
    try appendToolIfEnabled(allocator, &items, selected_tools, tools.BashTool.name, tools.BashTool.description, try tools.BashTool.schema(allocator), runBashTool);
    try appendToolIfEnabled(allocator, &items, selected_tools, tools.WriteTool.name, tools.WriteTool.description, try tools.WriteTool.schema(allocator), runWriteTool);
    try appendToolIfEnabled(allocator, &items, selected_tools, tools.EditTool.name, tools.EditTool.description, try tools.EditTool.schema(allocator), runEditTool);
    try appendToolIfEnabled(allocator, &items, selected_tools, tools.GrepTool.name, tools.GrepTool.description, try tools.GrepTool.schema(allocator), runGrepTool);
    try appendToolIfEnabled(allocator, &items, selected_tools, tools.FindTool.name, tools.FindTool.description, try tools.FindTool.schema(allocator), runFindTool);
    try appendToolIfEnabled(allocator, &items, selected_tools, tools.LsTool.name, tools.LsTool.description, try tools.LsTool.schema(allocator), runLsTool);

    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(allocator),
    };
}

fn appendToolIfEnabled(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(agent.AgentTool),
    selected_tools: ?[]const []const u8,
    name: []const u8,
    description: []const u8,
    schema: std.json.Value,
    execute: agent.types.ExecuteToolFn,
) !void {
    if (selected_tools) |allowlist| {
        var enabled = false;
        for (allowlist) |allowed| {
            if (std.mem.eql(u8, allowed, name)) {
                enabled = true;
                break;
            }
        }
        if (!enabled) {
            common.deinitJsonValue(allocator, schema);
            return;
        }
    }

    try items.append(allocator, .{
        .name = name,
        .description = description,
        .label = name,
        .parameters = schema,
        .execute = execute,
    });
}

fn handleAppAgentEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const app_state: *AppState = @ptrCast(@alignCast(context.?));
    try app_state.handleAgentEvent(event);
}

pub fn openInitialSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    model: ai.Model,
    api_key: ?[]const u8,
    tool_items: []const agent.AgentTool,
) !session_mod.AgentSession {
    const thinking_level = options.thinking;
    if (options.session) |session_ref| {
        const session_path = try resolveSessionPath(allocator, io, session_dir, options.cwd, session_ref);
        defer allocator.free(session_path);
        return try session_mod.AgentSession.open(allocator, io, .{
            .session_file = session_path,
            .cwd_override = options.cwd,
            .system_prompt = options.system_prompt,
            .model = model,
            .api_key = api_key,
            .thinking_level = thinking_level,
            .tools = tool_items,
        });
    }

    if (options.@"continue") {
        if (try session_manager_mod.findMostRecentSession(allocator, io, session_dir)) |recent| {
            defer allocator.free(recent);
            return try session_mod.AgentSession.open(allocator, io, .{
                .session_file = recent,
                .cwd_override = options.cwd,
                .system_prompt = options.system_prompt,
                .model = model,
                .api_key = api_key,
                .thinking_level = thinking_level,
                .tools = tool_items,
            });
        }
    }

    return try session_mod.AgentSession.create(allocator, io, .{
        .cwd = options.cwd,
        .system_prompt = options.system_prompt,
        .model = model,
        .api_key = api_key,
        .thinking_level = thinking_level,
        .session_dir = session_dir,
        .tools = tool_items,
    });
}

fn handleInputKey(
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
        switch (key) {
            .escape => {
                overlay_value.deinit(allocator);
                overlay.* = null;
                return;
            },
            else => {},
        }

        const result = overlay_value.list().handleKey(key);
        switch (result) {
            .handled, .ignored => return,
            .dismissed => {
                overlay_value.deinit(allocator);
                overlay.* = null;
                return;
            },
            .confirmed => |index| {
                switch (overlay_value.*) {
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
                }
                overlay_value.deinit(allocator);
                overlay.* = null;
                return;
            },
        }
    }

    if (key == .escape and editor.isShowingAutocomplete()) {
        _ = try editor.handleKey(key);
        return;
    }

    if (resolveAppAction(live_resources.keybindings, key)) |action| {
        try handleAppAction(
            allocator,
            io,
            env_map,
            action,
            session,
            session_dir,
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

fn submitEditorText(
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
            prompt_worker_active,
            subscriber,
            should_exit,
            live_resources,
        );
        clearEditor(editor);
        return;
    }

    const expanded = try resources_mod.expandPromptTemplate(allocator, trimmed, live_resources.prompt_templates);
    defer allocator.free(expanded);

    if (trimmed.len > 0 and trimmed[0] == '/' and std.mem.eql(u8, expanded, trimmed)) {
        const message = try std.fmt.allocPrint(allocator, "Unknown slash command: {s}", .{trimmed});
        defer allocator.free(message);
        clearEditor(editor);
        try app_state.appendError(message);
        return;
    }

    if (prompt_worker_active.*) {
        try app_state.setStatus("response in progress");
        return;
    }

    try prompt_worker.start(allocator, session, app_state, expanded);
    prompt_worker_active.* = true;
    clearEditor(editor);
    try app_state.setStatus("streaming");
}

fn parseSlashCommand(text: []const u8) ?SlashCommand {
    if (text.len < 2 or text[0] != '/') return null;

    const space_index = std.mem.indexOfAny(u8, text, " \t\r\n");
    const command_name = if (space_index) |index| text[1..index] else text[1..];
    const raw_argument = if (space_index) |index|
        std.mem.trim(u8, text[index + 1 ..], " \t\r\n")
    else
        "";
    const argument = if (raw_argument.len == 0) null else raw_argument;

    if (std.mem.eql(u8, command_name, "model")) return .{ .kind = .model, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "session")) return .{ .kind = .session, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "tree")) return .{ .kind = .tree, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "fork")) return .{ .kind = .fork, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "clone")) return .{ .kind = .clone, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "compact")) return .{ .kind = .compact, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "login")) return .{ .kind = .login, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "resume")) return .{ .kind = .@"resume", .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "reload")) return .{ .kind = .reload, .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "export")) return .{ .kind = .@"export", .argument = argument, .raw = text };
    if (std.mem.eql(u8, command_name, "quit")) return .{ .kind = .quit, .argument = argument, .raw = text };
    return null;
}

fn clearEditor(editor: *tui.Editor) void {
    editor.reset();
}

fn handleSlashCommand(
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
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    live_resources: *LiveResources,
) !void {
    switch (command.kind) {
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
        .session => try handleSessionSlashCommand(allocator, session, app_state),
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
        .login => try handleLoginSlashCommand(allocator, session, live_resources.runtime_config, app_state),
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

fn switchSession(
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
    });
    errdefer candidate.deinit();

    var candidate_provider = provider_config.resolveProviderConfig(
        allocator,
        env_map,
        candidate.agent.getModel().provider,
        candidate.agent.getModel().id,
        overrideApiKeyForProvider(options, candidate.agent.getModel().provider),
        configuredApiKeyForProvider(runtime_config, candidate.agent.getModel().provider),
    ) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "error: {s}", .{
            provider_config.resolveProviderErrorMessage(err, candidate.agent.getModel().provider),
        });
        defer allocator.free(message);
        try app_state.setStatus(message);
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

    try app_state.rebuildFromMessages(currentSessionLabel(session), session.agent.getModel().id, session.agent.getMessages());
}

fn switchModel(
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
        env_map,
        provider_name,
        model_id,
        overrideApiKeyForProvider(options, provider_name),
        configuredApiKeyForProvider(runtime_config, provider_name),
    ) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "error: {s}", .{
            provider_config.resolveProviderErrorMessage(err, provider_name),
        });
        defer allocator.free(message);
        try app_state.setStatus(message);
        return;
    };
    errdefer next_provider.deinit(allocator);

    current_provider.deinit(allocator);
    current_provider.* = next_provider;
    try session.setModel(next_provider.model);
    session.setApiKey(next_provider.api_key);
    try app_state.setFooter(next_provider.model.id, currentSessionLabel(session));
    try app_state.setStatus("idle");
}

fn handleModelSlashCommand(
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
        overlay.* = try loadModelOverlay(allocator, env_map, session.agent.getModel());
        return;
    };

    const available = try provider_config.listAvailableModels(allocator, env_map, session.agent.getModel());
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
    overlay.* = try loadModelOverlay(allocator, env_map, session.agent.getModel());
}

fn handleSessionSlashCommand(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    app_state: *AppState,
) !void {
    const info = try formatSessionInfo(allocator, session);
    defer allocator.free(info);
    try app_state.appendInfo(info);
}

fn handleCompactSlashCommand(
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
    try app_state.rebuildFromMessages(currentSessionLabel(session), session.agent.getModel().id, session.agent.getMessages());
    try app_state.appendInfo(info);
}

fn handleLoginSlashCommand(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    runtime_config: ?*const config_mod.RuntimeConfig,
    app_state: *AppState,
) !void {
    const auth_path = if (runtime_config) |config|
        try std.fs.path.join(allocator, &[_][]const u8{ config.agent_dir, "auth.json" })
    else
        null;
    defer if (auth_path) |path| allocator.free(path);

    const message = if (auth_path) |path|
        try std.fmt.allocPrint(
            allocator,
            "Configure credentials for provider `{s}` via `--api-key`, provider environment variables, or `{s}`, then use `/reload`.",
            .{ session.agent.getModel().provider, path },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "Configure credentials for provider `{s}` via `--api-key` or provider environment variables.",
            .{session.agent.getModel().provider},
        );
    defer allocator.free(message);
    try app_state.appendInfo(message);
}

fn handleReloadSlashCommand(
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

fn handleExportSlashCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    argument: ?[]const u8,
    app_state: *AppState,
) !void {
    const output_path = if (argument) |raw_path| normalizePathArgument(raw_path) else null;
    const exported_path = if (output_path) |path| blk: {
        if (std.mem.endsWith(u8, path, ".json")) {
            break :blk try session_advanced.exportToJson(allocator, io, session, path);
        }
        if (std.mem.endsWith(u8, path, ".md")) {
            break :blk try session_advanced.exportToMarkdown(allocator, io, session, path);
        }
        const message = try std.fmt.allocPrint(allocator, "Unsupported export path: {s}. Use .json or .md.", .{path});
        defer allocator.free(message);
        try app_state.appendError(message);
        return;
    } else try session_advanced.exportToMarkdown(allocator, io, session, null);
    defer allocator.free(exported_path);

    const message = try std.fmt.allocPrint(allocator, "Session exported to {s}", .{exported_path});
    defer allocator.free(message);
    try app_state.appendInfo(message);
    try app_state.setStatus("session exported");
}

fn loadSessionOverlay(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
) !SelectorOverlay {
    const entries = try listSessions(allocator, io, session_dir);
    errdefer {
        for (entries.paths) |path| allocator.free(path);
        allocator.free(entries.paths);
        for (entries.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(entries.items);
    }

    return .{
        .session = .{
            .choices = entries.paths,
            .items = entries.items,
            .list = .{
                .items = entries.items,
                .max_visible = 12,
            },
        },
    };
}

fn loadModelOverlay(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ai.Model,
) !SelectorOverlay {
    const available = try provider_config.listAvailableModels(allocator, env_map, current_model);
    defer allocator.free(available);

    const choices = try allocator.alloc(ModelChoice, available.len);
    errdefer {
        for (choices) |choice| {
            allocator.free(choice.provider);
            allocator.free(choice.model_id);
        }
        allocator.free(choices);
    }

    const items = try allocator.alloc(tui.SelectItem, available.len);
    errdefer {
        for (items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(items);
    }

    var selected_index: usize = 0;
    for (available, 0..) |entry, index| {
        choices[index] = .{
            .provider = try allocator.dupe(u8, entry.provider),
            .model_id = try allocator.dupe(u8, entry.model_id),
        };
        items[index] = .{
            .value = try allocator.dupe(u8, entry.model_id),
            .label = try allocator.dupe(u8, entry.display_name),
            .description = try allocator.dupe(u8, entry.provider),
        };
        if (std.mem.eql(u8, entry.provider, current_model.provider) and std.mem.eql(u8, entry.model_id, current_model.id)) {
            selected_index = index;
        }
    }

    return .{
        .model = .{
            .choices = choices,
            .items = items,
            .list = .{
                .items = items,
                .selected_index = selected_index,
                .max_visible = 12,
            },
        },
    };
}

fn loadTreeOverlay(
    allocator: std.mem.Allocator,
    session: *const session_mod.AgentSession,
) !SelectorOverlay {
    const tree = try session.session_manager.getTree(allocator);
    defer {
        for (tree) |*node| node.deinit(allocator);
        allocator.free(tree);
    }

    var choice_list = std.ArrayList(TreeChoice).empty;
    errdefer {
        for (choice_list.items) |choice| allocator.free(choice.entry_id);
        choice_list.deinit(allocator);
    }

    var item_list = std.ArrayList(tui.SelectItem).empty;
    errdefer {
        for (item_list.items) |item| {
            allocator.free(item.value);
            allocator.free(item.label);
            if (item.description) |description| allocator.free(description);
        }
        item_list.deinit(allocator);
    }

    var selected_index: usize = 0;
    const current_leaf_id = session.session_manager.getLeafId();
    try appendTreeNodes(allocator, tree, 0, current_leaf_id, &choice_list, &item_list, &selected_index);

    if (item_list.items.len == 0) {
        try choice_list.append(allocator, .{ .entry_id = try allocator.dupe(u8, "") });
        try item_list.append(allocator, .{
            .value = try allocator.dupe(u8, "none"),
            .label = try allocator.dupe(u8, "No tree entries"),
            .description = null,
        });
    }

    const choices = try choice_list.toOwnedSlice(allocator);
    errdefer {
        for (choices) |choice| allocator.free(choice.entry_id);
        allocator.free(choices);
    }
    const items = try item_list.toOwnedSlice(allocator);
    errdefer freeOwnedSelectItems(allocator, items);

    return .{
        .tree = .{
            .choices = choices,
            .items = items,
            .list = .{
                .items = items,
                .selected_index = selected_index,
                .max_visible = 12,
            },
        },
    };
}

fn appendTreeNodes(
    allocator: std.mem.Allocator,
    nodes: []const session_manager_mod.SessionTreeNode,
    depth: usize,
    current_leaf_id: ?[]const u8,
    choices: *std.ArrayList(TreeChoice),
    items: *std.ArrayList(tui.SelectItem),
    selected_index: *usize,
) !void {
    for (nodes) |node| {
        const prefix = try indentationPrefix(allocator, depth);
        defer allocator.free(prefix);
        const summary = try summarizeSessionEntry(allocator, node.entry.*);
        defer allocator.free(summary);
        const label = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, summary });
        defer allocator.free(label);

        try choices.append(allocator, .{ .entry_id = try allocator.dupe(u8, node.entry.id()) });
        try items.append(allocator, .{
            .value = try allocator.dupe(u8, node.entry.id()),
            .label = try allocator.dupe(u8, label),
            .description = try allocator.dupe(u8, node.entry.timestamp()),
        });
        if (current_leaf_id) |leaf_id| {
            if (std.mem.eql(u8, leaf_id, node.entry.id())) {
                selected_index.* = items.items.len - 1;
            }
        }

        try appendTreeNodes(allocator, node.children, depth + 1, current_leaf_id, choices, items, selected_index);
    }
}

fn indentationPrefix(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    const prefix = try allocator.alloc(u8, depth * 2);
    @memset(prefix, ' ');
    return prefix;
}

fn summarizeSessionEntry(allocator: std.mem.Allocator, entry: session_manager_mod.SessionEntry) ![]u8 {
    return switch (entry) {
        .message => |message_entry| switch (message_entry.message) {
            .user => |user_message| blk: {
                const text = try blocksToText(allocator, user_message.content);
                defer allocator.free(text);
                break :blk std.fmt.allocPrint(allocator, "user: {s}", .{trimSummaryText(text)});
            },
            .assistant => |assistant_message| blk: {
                const text = try formatAssistantMessage(allocator, assistant_message);
                defer allocator.free(text);
                break :blk allocator.dupe(u8, trimSummaryText(text));
            },
            .tool_result => |tool_result| blk: {
                const text = try blocksToText(allocator, tool_result.content);
                defer allocator.free(text);
                break :blk std.fmt.allocPrint(allocator, "tool {s}: {s}", .{ tool_result.tool_name, trimSummaryText(text) });
            },
        },
        .thinking_level_change => |thinking_entry| std.fmt.allocPrint(allocator, "thinking: {s}", .{@tagName(thinking_entry.thinking_level)}),
        .model_change => |model_entry| std.fmt.allocPrint(allocator, "model: {s}/{s}", .{ model_entry.provider, model_entry.model_id }),
        .compaction => |compaction_entry| std.fmt.allocPrint(allocator, "compaction: {s}", .{trimSummaryText(try session_manager_mod.getCompactionSummary(compaction_entry))}),
    };
}

fn trimSummaryText(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return if (trimmed.len > 72) trimmed[0..72] else trimmed;
}

const SessionOverlayEntries = struct {
    paths: []SessionChoice,
    items: []tui.SelectItem,
};

fn listSessions(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
) !SessionOverlayEntries {
    var dir = std.Io.Dir.openDirAbsolute(io, session_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            const paths = try allocator.alloc(SessionChoice, 1);
            const items = try allocator.alloc(tui.SelectItem, 1);
            paths[0] = .{ .path = try allocator.dupe(u8, "") };
            items[0] = .{
                .value = try allocator.dupe(u8, "none"),
                .label = try allocator.dupe(u8, "No sessions found"),
                .description = null,
            };
            return .{ .paths = paths, .items = items };
        },
        else => return err,
    };
    defer dir.close(io);

    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.order(u8, lhs, rhs) == .gt;
        }
    }.lessThan);

    const count = if (names.items.len == 0) @as(usize, 1) else names.items.len;
    const paths = try allocator.alloc(SessionChoice, count);
    errdefer {
        for (paths) |path| allocator.free(path.path);
        allocator.free(paths);
    }
    const items = try allocator.alloc(tui.SelectItem, count);
    errdefer {
        for (items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(items);
    }

    if (names.items.len == 0) {
        paths[0] = .{ .path = try allocator.dupe(u8, "") };
        items[0] = .{
            .value = try allocator.dupe(u8, "none"),
            .label = try allocator.dupe(u8, "No sessions found"),
            .description = null,
        };
        return .{ .paths = paths, .items = items };
    }

    for (names.items, 0..) |name, index| {
        const path = try std.fs.path.join(allocator, &[_][]const u8{ session_dir, name });
        paths[index] = .{ .path = path };
        items[index] = .{
            .value = try allocator.dupe(u8, name),
            .label = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, path),
        };
    }

    return .{ .paths = paths, .items = items };
}

fn currentSessionLabel(session: *const session_mod.AgentSession) []const u8 {
    return if (session.session_manager.getSessionFile()) |path|
        std.fs.path.basename(path)
    else
        session.session_manager.getSessionId();
}

fn formatSessionInfo(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) ![]u8 {
    const stats = session_advanced.getSessionStats(session);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.writeAll("Session Info\n");
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

fn cloneCurrentSession(
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

fn forkCurrentSession(
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

fn createDerivedSession(
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

fn replaceCurrentSession(
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
    const session_label = try allocator.dupe(u8, currentSessionLabel(session));
    defer allocator.free(session_label);
    const model_label = try allocator.dupe(u8, session.agent.getModel().id);
    defer allocator.free(model_label);
    try app_state.rebuildFromMessages(session_label, model_label, session.agent.getMessages());
    try app_state.setFooter(model_label, session_label);
    try app_state.setStatus("idle");
}

fn navigateTree(
    session: *session_mod.AgentSession,
    entry_id: []const u8,
    app_state: *AppState,
) !void {
    try session.navigateTo(entry_id);
    try app_state.rebuildFromMessages(currentSessionLabel(session), session.agent.getModel().id, session.agent.getMessages());
    try app_state.setStatus("session tree updated");
}

fn findLastUserMessageIndex(messages: []const agent.AgentMessage) ?usize {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        if (messages[index] == .user) return index;
    }
    return null;
}

fn loadEditorAutocompleteItems(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]tui.SelectItem {
    var dir = try std.Io.Dir.openDirAbsolute(io, cwd, .{ .iterate = true });
    defer dir.close(io);

    var items = std.ArrayList(tui.SelectItem).empty;
    errdefer {
        freeOwnedSelectItems(allocator, items.items);
        items.deinit(allocator);
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
            const lhs_dir = std.mem.endsWith(u8, lhs.value, "/");
            const rhs_dir = std.mem.endsWith(u8, rhs.value, "/");
            if (lhs_dir != rhs_dir) return lhs_dir;
            return std.mem.order(u8, lhs.label, rhs.label) == .lt;
        }
    }.lessThan);

    return try items.toOwnedSlice(allocator);
}

fn freeOwnedSelectItems(allocator: std.mem.Allocator, items: []tui.SelectItem) void {
    for (items) |item| {
        allocator.free(item.value);
        allocator.free(item.label);
        if (item.description) |description| allocator.free(description);
    }
    allocator.free(items);
}

fn resolveSessionPath(
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

fn pollForInput() !bool {
    var fds = [_]std.posix.pollfd{
        .{
            .fd = 0,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    return (try std.posix.poll(fds[0..], 50)) > 0;
}

fn dispatchInputEvent(
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
    prompt_worker: *PromptWorker,
    prompt_worker_active: *bool,
    subscriber: agent.AgentSubscriber,
    should_exit: *bool,
    input_buffer: *std.ArrayList(u8),
    live_resources: *LiveResources,
) !void {
    switch (parsed.event) {
        .key => |key| try handleInputKey(
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
            prompt_worker,
            prompt_worker_active,
            subscriber,
            should_exit,
            live_resources,
        ),
        .paste => |content| {
            if (overlay.* != null) {
                consumeInputBytes(input_buffer, parsed.consumed);
                return;
            }
            _ = try editor.handlePaste(content);
        },
    }
    consumeInputBytes(input_buffer, parsed.consumed);
}

fn consumeInputBytes(buffer: *std.ArrayList(u8), consumed: usize) void {
    if (consumed >= buffer.items.len) {
        buffer.clearRetainingCapacity();
        return;
    }
    std.mem.copyForwards(u8, buffer.items[0 .. buffer.items.len - consumed], buffer.items[consumed..]);
    buffer.items.len -= consumed;
}

fn parseEnvSize(value: ?[]const u8) ?usize {
    const text = value orelse return null;
    return std.fmt.parseInt(usize, text, 10) catch null;
}

fn freeLinesSafe(allocator: std.mem.Allocator, lines: *tui.LineList) void {
    if (lines.items.len == 0) {
        lines.deinit(allocator);
        return;
    }
    tui.component.freeLines(allocator, lines);
}

const INPUT_PROMPT_PREFIX = "Input: ";

fn renderPromptLines(
    allocator: std.mem.Allocator,
    editor: *tui.Editor,
    width: usize,
    lines: *tui.LineList,
) !void {
    const prefix_width = tui.ansi.visibleWidth(INPUT_PROMPT_PREFIX);
    const editor_width = @max(@as(usize, 1), if (width > prefix_width) width - prefix_width else 1);

    var editor_lines = tui.LineList.empty;
    defer freeLinesSafe(allocator, &editor_lines);
    try editor.renderTextInto(allocator, editor_width, &editor_lines);

    const continuation_prefix = try allocator.alloc(u8, prefix_width);
    defer allocator.free(continuation_prefix);
    @memset(continuation_prefix, ' ');

    for (editor_lines.items, 0..) |editor_line, index| {
        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);

        try builder.appendSlice(allocator, if (index == 0) INPUT_PROMPT_PREFIX else continuation_prefix);
        try builder.appendSlice(allocator, editor_line);

        const fitted = try fitLine(allocator, builder.items, width);
        defer allocator.free(fitted);
        try tui.component.appendOwnedLine(lines, allocator, fitted);
        builder.deinit(allocator);
    }
}

fn formatFooterLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    model_label: []const u8,
    session_label: []const u8,
    status: []const u8,
    width: usize,
) ![]u8 {
    const line = try std.fmt.allocPrint(allocator, "Model: {s} • Session: {s} • Status: {s}", .{
        model_label,
        session_label,
        status,
    });
    defer allocator.free(line);
    const fitted = try fitLine(allocator, line, width);
    defer allocator.free(fitted);
    return try applyThemeAlloc(allocator, theme, .footer, fitted);
}

fn formatHintsLine(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    width: usize,
) ![]u8 {
    const open_sessions = try actionLabel(allocator, keybindings, .open_sessions, "Ctrl+S");
    defer allocator.free(open_sessions);
    const open_models = try actionLabel(allocator, keybindings, .open_models, "Ctrl+P");
    defer allocator.free(open_models);
    const interrupt = try actionLabel(allocator, keybindings, .interrupt, "Ctrl+C");
    defer allocator.free(interrupt);
    const exit = try actionLabel(allocator, keybindings, .exit, "Ctrl+D");
    defer allocator.free(exit);
    const clear = try actionLabel(allocator, keybindings, .clear, "Ctrl+L");
    defer allocator.free(clear);

    const line = try std.fmt.allocPrint(
        allocator,
        "{s} sessions • {s} models • {s} interrupt • {s} exit • {s} clear",
        .{ open_sessions, open_models, interrupt, exit, clear },
    );
    defer allocator.free(line);
    const fitted = try fitLine(allocator, line, width);
    defer allocator.free(fitted);
    return try applyThemeAlloc(allocator, theme, .status, fitted);
}

fn actionLabel(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    action: keybindings_mod.Action,
    fallback: []const u8,
) ![]u8 {
    if (keybindings) |bindings| {
        return bindings.primaryLabel(allocator, action);
    }
    return allocator.dupe(u8, fallback);
}

fn themeChatItem(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
) ![]u8 {
    return try applyThemeAlloc(allocator, theme, switch (item.kind) {
        .welcome => .welcome,
        .info => .status,
        .@"error" => .@"error",
        .user => .user,
        .assistant => .assistant,
        .tool_call => .tool_call,
        .tool_result => .tool_result,
    }, item.text);
}

fn renderChatItemInto(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    lines: *tui.LineList,
) !void {
    switch (item.kind) {
        .assistant => try renderAssistantChatItemInto(allocator, width, theme, item.text, lines),
        else => {
            const themed_item = try themeChatItem(allocator, theme, item);
            defer allocator.free(themed_item);
            try tui.ansi.wrapTextWithAnsi(allocator, themed_item, width, lines);
        },
    }
}

fn renderAssistantChatItemInto(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    text: []const u8,
    lines: *tui.LineList,
) !void {
    const prefix = try applyThemeAlloc(allocator, theme, .assistant, ASSISTANT_PREFIX);
    defer allocator.free(prefix);
    try tui.ansi.wrapTextWithAnsi(allocator, prefix, width, lines);

    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;

    const markdown = tui.Markdown{
        .text = text,
    };
    try markdown.renderInto(allocator, width, lines);
}

fn applyThemeAlloc(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    token: resources_mod.ThemeToken,
    text: []const u8,
) ![]u8 {
    if (theme) |selected_theme| {
        return selected_theme.applyAlloc(allocator, token, text);
    }
    return allocator.dupe(u8, text);
}

fn resolveAppAction(keybindings: ?*const keybindings_mod.Keybindings, key: tui.Key) ?keybindings_mod.Action {
    if (keybindings) |bindings| return bindings.actionForKey(key);
    return legacyAppActionForKey(key);
}

fn legacyAppActionForKey(key: tui.Key) ?keybindings_mod.Action {
    return switch (key) {
        .ctrl => |ctrl| switch (ctrl) {
            'c' => .interrupt,
            'd' => .exit,
            'l' => .clear,
            's' => .open_sessions,
            'p' => .open_models,
            else => null,
        },
        .escape => .exit,
        else => null,
    };
}

fn isLegacyAppActionKey(key: tui.Key) bool {
    return legacyAppActionForKey(key) != null;
}

fn handleAppAction(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    action: keybindings_mod.Action,
    session: *session_mod.AgentSession,
    session_dir: []const u8,
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
            overlay.* = try loadModelOverlay(allocator, env_map, session.agent.getModel());
        },
    }
}

fn configuredApiKeyForProvider(runtime_config: ?*const config_mod.RuntimeConfig, provider_name: []const u8) ?[]const u8 {
    if (runtime_config) |runtime_config_value| {
        return runtime_config_value.lookupApiKey(provider_name);
    }
    return null;
}

fn settingsResources(settings: config_mod.Settings) resources_mod.SettingsResources {
    return .{
        .packages = settings.packages,
        .extensions = settings.extensions,
        .skills = settings.skills,
        .prompts = settings.prompts,
        .themes = settings.themes,
        .theme = settings.theme,
    };
}

fn normalizePathArgument(argument: []const u8) []const u8 {
    if (argument.len >= 2) {
        const first = argument[0];
        const last = argument[argument.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return argument[1 .. argument.len - 1];
        }
    }
    return argument;
}

fn overrideApiKeyForProvider(options: RunInteractiveModeOptions, provider_name: []const u8) ?[]const u8 {
    if (options.api_key) |api_key| {
        if (std.mem.eql(u8, provider_name, options.provider)) return api_key;
    }
    return null;
}

fn fitLine(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    if (width == 0) return allocator.dupe(u8, "");
    if (tui.ansi.visibleWidth(text) <= width) return tui.ansi.padRightVisibleAlloc(allocator, text, width);

    const limit = if (width > 1) width - 1 else 0;
    const prefix = try tui.ansi.sliceVisibleAlloc(allocator, text, 0, limit);
    defer allocator.free(prefix);

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    try builder.appendSlice(allocator, prefix);
    if (width > 0) try builder.append(allocator, '.');

    const fitted = try tui.ansi.padRightVisibleAlloc(allocator, builder.items, width);
    builder.deinit(allocator);
    return fitted;
}

fn formatPrefixedBlocks(allocator: std.mem.Allocator, prefix: []const u8, blocks: []const ai.ContentBlock) ![]u8 {
    const body = try blocksToText(allocator, blocks);
    defer allocator.free(body);
    return if (body.len == 0)
        std.fmt.allocPrint(allocator, "{s}:", .{prefix})
    else
        std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, body });
}

fn formatAssistantMessage(allocator: std.mem.Allocator, message: ai.AssistantMessage) ![]u8 {
    const body = try blocksToText(allocator, message.content);
    defer allocator.free(body);
    if (body.len > 0) {
        return allocator.dupe(u8, body);
    }
    if (message.stop_reason == .error_reason) {
        return try std.fmt.allocPrint(allocator, "Error: {s}", .{message.error_message orelse "unknown error"});
    }
    if (message.stop_reason == .aborted) {
        return try allocator.dupe(u8, "[interrupted]");
    }
    return try allocator.dupe(u8, "");
}

fn formatToolCall(allocator: std.mem.Allocator, name: []const u8, args: std.json.Value) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, args, .{});
    defer allocator.free(json);
    return try std.fmt.allocPrint(allocator, "Tool {s}: {s}", .{ name, json });
}

fn formatToolResult(
    allocator: std.mem.Allocator,
    name: []const u8,
    blocks: []const ai.ContentBlock,
    is_error: bool,
) ![]u8 {
    const body = try blocksToText(allocator, blocks);
    defer allocator.free(body);
    const prefix = if (is_error) "Tool error" else "Tool result";
    return if (body.len == 0)
        std.fmt.allocPrint(allocator, "{s} {s}", .{ prefix, name })
    else
        std.fmt.allocPrint(allocator, "{s} {s}: {s}", .{ prefix, name, body });
}

fn blocksToText(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (blocks, 0..) |block, index| {
        if (index > 0) try out.appendSlice(allocator, "\n");
        switch (block) {
            .text => |text| try out.appendSlice(allocator, text.text),
            .thinking => |thinking| try out.appendSlice(allocator, thinking.thinking),
            .image => |image| {
                const note = try std.fmt.allocPrint(allocator, "[image:{s}:{d}]", .{ image.mime_type, image.data.len });
                defer allocator.free(note);
                try out.appendSlice(allocator, note);
            },
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn getToolRuntime() ToolRuntime {
    return global_tool_runtime orelse @panic("tool runtime not configured");
}

fn runReadTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = getToolRuntime();
    const args = tools.ReadArgs{
        .path = try getRequiredString(params, "path"),
        .offset = getOptionalUsize(params, "offset"),
        .limit = getOptionalUsize(params, "limit"),
    };
    const result = try tools.ReadTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
}

fn runBashTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    signal: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = getToolRuntime();
    const args = tools.BashArgs{
        .command = try getRequiredString(params, "command"),
        .timeout_seconds = getOptionalU64(params, "timeout_seconds"),
    };
    const result = try tools.BashTool.init(runtime.cwd, runtime.io).execute(allocator, args, signal);
    return .{ .content = result.content };
}

fn runWriteTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = getToolRuntime();
    const args = tools.WriteArgs{
        .path = try getRequiredString(params, "path"),
        .content = try getRequiredString(params, "content"),
    };
    const result = try tools.WriteTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
}

fn runEditTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = getToolRuntime();
    const args = tools.EditArgs{
        .path = try getRequiredString(params, "path"),
        .old_text = try getRequiredStringEither(params, "oldText", "old_text"),
        .new_text = try getRequiredStringEither(params, "newText", "new_text"),
    };
    const result = try tools.EditTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
}

fn runGrepTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = getToolRuntime();
    const args = tools.GrepArgs{
        .pattern = try getRequiredString(params, "pattern"),
        .path = getOptionalString(params, "path"),
        .glob = getOptionalStringEither(params, "glob", "glob_pattern"),
        .ignore_case = getOptionalBoolEither(params, "ignoreCase", "ignore_case") orelse false,
        .literal = getOptionalBool(params, "literal") orelse false,
        .context = getOptionalUsize(params, "context") orelse 0,
        .limit = getOptionalUsize(params, "limit"),
    };
    const result = try tools.GrepTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
}

fn runFindTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = getToolRuntime();
    const args = tools.FindArgs{
        .pattern = try getRequiredString(params, "pattern"),
        .path = getOptionalString(params, "path"),
        .limit = getOptionalUsize(params, "limit"),
    };
    const result = try tools.FindTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
}

fn runLsTool(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?agent.types.AgentToolUpdateCallback,
) !agent.AgentToolResult {
    const runtime = getToolRuntime();
    const args = tools.LsArgs{
        .path = getOptionalString(params, "path"),
        .limit = getOptionalUsize(params, "limit"),
    };
    const result = try tools.LsTool.init(runtime.cwd, runtime.io).execute(allocator, args);
    return .{ .content = result.content };
}

fn getRequiredString(value: std.json.Value, key: []const u8) ![]const u8 {
    return getStringObjectValue(value, key) orelse error.InvalidToolArguments;
}

fn getRequiredStringEither(value: std.json.Value, first: []const u8, second: []const u8) ![]const u8 {
    return getStringObjectValue(value, first) orelse getStringObjectValue(value, second) orelse error.InvalidToolArguments;
}

fn getOptionalString(value: std.json.Value, key: []const u8) ?[]const u8 {
    return getStringObjectValue(value, key);
}

fn getOptionalStringEither(value: std.json.Value, first: []const u8, second: []const u8) ?[]const u8 {
    return getStringObjectValue(value, first) orelse getStringObjectValue(value, second);
}

fn getOptionalBool(value: std.json.Value, key: []const u8) ?bool {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const raw = object.get(key) orelse return null;
    return switch (raw) {
        .bool => |bool_value| bool_value,
        else => null,
    };
}

fn getOptionalBoolEither(value: std.json.Value, first: []const u8, second: []const u8) ?bool {
    return getOptionalBool(value, first) orelse getOptionalBool(value, second);
}

fn getOptionalUsize(value: std.json.Value, key: []const u8) ?usize {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const raw = object.get(key) orelse return null;
    return switch (raw) {
        .integer => |integer| std.math.cast(usize, integer) orelse null,
        else => null,
    };
}

fn getOptionalU64(value: std.json.Value, key: []const u8) ?u64 {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const raw = object.get(key) orelse return null;
    return switch (raw) {
        .integer => |integer| std.math.cast(u64, integer) orelse null,
        else => null,
    };
}

fn getStringObjectValue(value: std.json.Value, key: []const u8) ?[]const u8 {
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const raw = object.get(key) orelse return null;
    return switch (raw) {
        .string => |string| string,
        else => null,
    };
}

const InteractiveModeTestBackend = struct {
    size: tui.Size,
    entered_raw: bool = false,
    restored: bool = false,
    writes: std.ArrayList([]u8) = .empty,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.writes.items) |entry| allocator.free(entry);
        self.writes.deinit(allocator);
    }

    fn backend(self: *@This()) tui.Backend {
        return .{
            .ptr = self,
            .enterRawModeFn = enterRawMode,
            .restoreModeFn = restoreMode,
            .writeFn = write,
            .getSizeFn = getSize,
        };
    }

    fn enterRawMode(ptr: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.entered_raw = true;
    }

    fn restoreMode(ptr: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.restored = true;
    }

    fn write(ptr: *anyopaque, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.writes.append(std.testing.allocator, try std.testing.allocator.dupe(u8, bytes));
    }

    fn getSize(ptr: *anyopaque) !tui.Size {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.size;
    }
};

fn renderScreenWithMockBackend(
    allocator: std.mem.Allocator,
    screen: *const ScreenComponent,
    backend: *InteractiveModeTestBackend,
) !tui.LineList {
    var terminal = tui.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = tui.Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    try renderer.render(screen.component());

    var lines = tui.LineList.empty;
    errdefer freeLinesSafe(allocator, &lines);
    for (renderer.previous_lines.items) |line| {
        try lines.append(allocator, try allocator.dupe(u8, line));
    }
    return lines;
}

fn renderedLinesContain(lines: []const []const u8, needle: []const u8) bool {
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
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
    try std.testing.expect(std.mem.indexOf(u8, lines.items[lines.items.len - 2], "Model: faux-1") != null);
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
        tui.Terminal.ALT_SCREEN_ENABLE ++ tui.Terminal.BRACKETED_PASTE_ENABLE ++ tui.Terminal.HIDE_CURSOR,
        backend.writes.items[0],
    );
    try std.testing.expectEqualStrings(
        tui.Terminal.ALT_SCREEN_DISABLE ++ tui.Terminal.BRACKETED_PASTE_DISABLE ++ tui.Terminal.SHOW_CURSOR,
        backend.writes.items[backend.writes.items.len - 1],
    );
    try std.testing.expect(renderedLinesContain(lines.items, "Welcome to pi (Zig interactive mode)."));
    try std.testing.expect(renderedLinesContain(lines.items, "Input: "));
    try std.testing.expect(renderedLinesContain(lines.items, "Model: faux-1 • Session: session.jsonl • Status: idle"));
    try std.testing.expect(renderedLinesContain(lines.items, "Ctrl+S sessions • Ctrl+P models • Ctrl+C interrupt • Ctrl+D exit • Ctrl+L clear"));
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
    try std.testing.expect(renderedLinesContain(lines.items, "Status: streaming"));
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

    try std.testing.expect(renderedLinesContain(lines.items, "Tool read: {\"path\":\"README.md\"}"));
    try std.testing.expect(renderedLinesContain(lines.items, "Tool result read: project notes"));
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
    try std.testing.expect(std.mem.indexOf(u8, lines.items[lines.items.len - 2], "Model:") != null);
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
    theme.styles[@intFromEnum(resources_mod.ThemeToken.welcome)].fg = try allocator.dupe(u8, "green");
    theme.styles[@intFromEnum(resources_mod.ThemeToken.footer)].fg = try allocator.dupe(u8, "cyan");
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

    var saw_ansi = false;
    var saw_custom_hint = false;
    for (lines.items) |line| {
        if (std.mem.indexOf(u8, line, "\x1b[") != null) saw_ansi = true;
        if (std.mem.indexOf(u8, line, "Ctrl+X sessions") != null) saw_custom_hint = true;
    }

    try std.testing.expect(saw_ansi);
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
        if (std.mem.indexOf(u8, line, "\x1b[1mbold\x1b[0m") != null) saw_bold = true;
        if (std.mem.indexOf(u8, line, "\x1b[4m\x1b[38;5;45mlink\x1b[0m") != null) saw_link = true;
        if (std.mem.indexOf(u8, line, "\x1b[38;5;45m• \x1b[0mlist item") != null) saw_list = true;
        if (std.mem.indexOf(u8, line, "\x1b[48;5;236m\x1b[38;5;214mconst value = 1;\x1b[0m") != null) saw_code = true;
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
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );
    try std.testing.expect(should_exit);
}

test "parseSlashCommand recognizes builtins and arguments" {
    const model_command = parseSlashCommand("/model faux").?;
    try std.testing.expectEqual(SlashCommandKind.model, model_command.kind);
    try std.testing.expectEqualStrings("faux", model_command.argument.?);

    const export_command = parseSlashCommand("/export \"/tmp/out.md\"").?;
    try std.testing.expectEqual(SlashCommandKind.@"export", export_command.kind);
    try std.testing.expectEqualStrings("\"/tmp/out.md\"", export_command.argument.?);

    try std.testing.expect(parseSlashCommand("hello") == null);
    try std.testing.expect(parseSlashCommand("/unknown") == null);
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
    try std.testing.expectEqualStrings("streaming", state.status);
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

test "handleInputKey exports session transcript to explicit markdown and json paths" {
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
    const markdown_path = try std.fs.path.join(allocator, &[_][]const u8{ root_dir, "session export.md" });
    defer allocator.free(markdown_path);
    const json_path = try std.fs.path.join(allocator, &[_][]const u8{ root_dir, "session export.json" });
    defer allocator.free(json_path);

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

    const markdown_command = try std.fmt.allocPrint(allocator, "/export \"{s}\"", .{markdown_path});
    defer allocator.free(markdown_command);
    _ = try editor.handlePaste(markdown_command);
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
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    const markdown_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, markdown_path, allocator, .limited(1024 * 1024));
    defer allocator.free(markdown_bytes);
    try std.testing.expect(std.mem.indexOf(u8, markdown_bytes, "# Session") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown_bytes, "export prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown_bytes, "export reply") != null);

    const json_command = try std.fmt.allocPrint(allocator, "/export \"{s}\"", .{json_path});
    defer allocator.free(json_command);
    _ = try editor.handlePaste(json_command);
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
        &prompt_worker,
        &prompt_worker_active,
        subscriber,
        &should_exit,
        &live_resources,
    );

    const json_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, json_path, allocator, .limited(1024 * 1024));
    defer allocator.free(json_bytes);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"header\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"entries\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"export prompt\"") != null);
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

    setToolRuntime(.{
        .cwd = root_dir,
        .io = std.testing.io,
    });
    defer clearToolRuntime();

    var built_tools = try buildAgentTools(allocator, &[_][]const u8{"read"});
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
        if (std.mem.indexOf(u8, line, "Tool read:") != null and std.mem.indexOf(u8, line, file_path) != null) saw_tool_call = true;
        if (std.mem.indexOf(u8, line, "Tool result read: secret note") != null) saw_tool_result = true;
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

test "native terminal backend prefers ioctl size over environment variables" {
    const allocator = std.testing.allocator;

    const TestSizeReader = struct {
        size: tui.Size,

        fn read(context: ?*anyopaque, fd: std.posix.fd_t) ?tui.Size {
            _ = fd;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.size;
        }
    };

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("COLUMNS", "40");
    try env_map.put("LINES", "12");

    var reader = TestSizeReader{
        .size = .{ .width = 120, .height = 48 },
    };
    var backend = NativeTerminalBackend{
        .env_map = &env_map,
        .read_terminal_size_fn = TestSizeReader.read,
        .read_terminal_size_context = &reader,
    };

    try std.testing.expectEqual(tui.Size{ .width = 120, .height = 48 }, backend.readSize());
}

test "native terminal backend falls back to environment variables when ioctl fails" {
    const allocator = std.testing.allocator;

    const FailingSizeReader = struct {
        fn read(_: ?*anyopaque, fd: std.posix.fd_t) ?tui.Size {
            _ = fd;
            return null;
        }
    };

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("COLUMNS", "132");
    try env_map.put("LINES", "43");

    var backend = NativeTerminalBackend{
        .env_map = &env_map,
        .cached_size = .{ .width = 80, .height = 24 },
        .read_terminal_size_fn = FailingSizeReader.read,
    };

    try std.testing.expectEqual(tui.Size{ .width = 132, .height = 43 }, backend.readSize());
}

test "SIGWINCH handler only marks resize as pending" {
    const allocator = std.testing.allocator;

    const TestSizeReader = struct {
        size: tui.Size,

        fn read(context: ?*anyopaque, fd: std.posix.fd_t) ?tui.Size {
            _ = fd;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.size;
        }
    };

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var reader = TestSizeReader{
        .size = .{ .width = 80, .height = 24 },
    };
    var backend = NativeTerminalBackend{
        .env_map = &env_map,
        .cached_size = .{ .width = 80, .height = 24 },
        .read_terminal_size_fn = TestSizeReader.read,
        .read_terminal_size_context = &reader,
    };

    active_resize_backend = &backend;
    defer active_resize_backend = null;

    reader.size = .{ .width = 101, .height = 33 };
    var siginfo: std.posix.siginfo_t = undefined;
    handleSigwinch(.WINCH, &siginfo, null);

    try std.testing.expect(backend.resize_pending.load(.seq_cst));
    try std.testing.expectEqual(tui.Size{ .width = 80, .height = 24 }, backend.cached_size);
}

test "native terminal backend refreshes cached terminal size in main loop after SIGWINCH" {
    const allocator = std.testing.allocator;

    const TestSizeReader = struct {
        size: tui.Size,

        fn read(context: ?*anyopaque, fd: std.posix.fd_t) ?tui.Size {
            _ = fd;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.size;
        }
    };

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var reader = TestSizeReader{
        .size = .{ .width = 80, .height = 24 },
    };
    var backend = NativeTerminalBackend{
        .env_map = &env_map,
        .cached_size = .{ .width = 80, .height = 24 },
        .read_terminal_size_fn = TestSizeReader.read,
        .read_terminal_size_context = &reader,
    };

    active_resize_backend = &backend;
    defer active_resize_backend = null;

    reader.size = .{ .width = 101, .height = 33 };
    var siginfo: std.posix.siginfo_t = undefined;
    handleSigwinch(.WINCH, &siginfo, null);

    backend.refreshSizeIfPending();
    try std.testing.expect(!backend.resize_pending.load(.seq_cst));
    try std.testing.expectEqual(tui.Size{ .width = 101, .height = 33 }, backend.cached_size);
}
