const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tui = @import("tui");
const provider_config = @import("provider_config.zig");
const session_mod = @import("session.zig");
const session_manager_mod = @import("session_manager.zig");
const tools = @import("tools/root.zig");
const common = @import("tools/common.zig");

pub const ToolRuntime = struct {
    cwd: []const u8,
    io: std.Io,
};

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
    provider: []const u8,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    thinking: agent.ThinkingLevel = .off,
    session: ?[]const u8 = null,
    @"continue": bool = false,
    selected_tools: ?[]const []const u8 = null,
    initial_prompt: ?[]const u8 = null,
};

const ChatKind = enum {
    welcome,
    user,
    assistant,
    tool_call,
    tool_result,
};

const ChatItem = struct {
    kind: ChatKind,
    text: []u8,
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
                        try self.appendItemLocked(.assistant, "Pi:");
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

    fn deinit(self: *SelectorOverlay, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .session => |*overlay| overlay.deinit(allocator),
            .model => |*overlay| overlay.deinit(allocator),
        }
        self.* = undefined;
    }

    fn title(self: *const SelectorOverlay) []const u8 {
        return switch (self.*) {
            .session => "Session selector",
            .model => "Model selector",
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

const ScreenComponent = struct {
    state: *AppState,
    editor: *tui.Editor,
    height: usize = 24,
    overlay: ?*SelectorOverlay = null,

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
            try tui.ansi.wrapTextWithAnsi(allocator, item.text, @max(width, 1), &chat_lines);
        }

        const prompt_line = try formatPromptLine(allocator, self.editor.text(), width);
        defer allocator.free(prompt_line);
        const footer_line = try formatFooterLine(allocator, self.state.model_label, self.state.session_label, self.state.status, width);
        defer allocator.free(footer_line);
        const hints_line = try fitLine(allocator, "Ctrl+S sessions • Ctrl+P models • Ctrl+C interrupt • Ctrl+D exit • Ctrl+L clear", width);
        defer allocator.free(hints_line);

        const reserved_lines: usize = 3;
        const chat_capacity = if (self.height > reserved_lines) self.height - reserved_lines else 1;
        const visible_chat_start = if (chat_lines.items.len > chat_capacity) chat_lines.items.len - chat_capacity else 0;
        for (chat_lines.items[visible_chat_start..]) |line| {
            try tui.component.appendOwnedLine(lines, allocator, line);
        }
        try tui.component.appendOwnedLine(lines, allocator, prompt_line);
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
        const title_line = try fitLine(allocator, overlay.title(), width);
        defer allocator.free(title_line);
        const hint_line = try fitLine(allocator, overlay.hint(), width);
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
    }

    fn restoreMode(ptr: *anyopaque) !void {
        const self: *NativeTerminalBackend = @ptrCast(@alignCast(ptr));
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
        self.cached_size = self.readSize();
        return self.cached_size;
    }

    fn readSize(self: *NativeTerminalBackend) tui.Size {
        const columns = parseEnvSize(self.env_map.get("COLUMNS")) orelse self.cached_size.width;
        const lines = parseEnvSize(self.env_map.get("LINES")) orelse self.cached_size.height;
        return .{
            .width = if (columns == 0) 80 else columns,
            .height = if (lines == 0) 24 else lines,
        };
    }
};

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
    var current_provider = provider_config.resolveProviderConfig(
        allocator,
        env_map,
        options.provider,
        options.model,
        options.api_key,
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

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ options.cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);

    var session = try openInitialSession(
        allocator,
        io,
        session_dir,
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

    var screen = ScreenComponent{
        .state = &app_state,
        .editor = &editor,
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
            while (tui.keys.parseKey(input_buffer.items)) |parsed| {
                try handleInputKey(
                    allocator,
                    io,
                    env_map,
                    parsed.key,
                    &session,
                    &current_provider,
                    session_dir,
                    options,
                    built_tools.items,
                    &app_state,
                    &editor,
                    &overlay,
                    &prompt_worker,
                    &prompt_worker_active,
                    subscriber,
                    &should_exit,
                );
                if (parsed.consumed >= input_buffer.items.len) {
                    input_buffer.clearRetainingCapacity();
                    break;
                }
                std.mem.copyForwards(u8, input_buffer.items[0 .. input_buffer.items.len - parsed.consumed], input_buffer.items[parsed.consumed..]);
                input_buffer.items.len -= parsed.consumed;
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
) !void {
    if (overlay.*) |*overlay_value| {
        switch (key) {
            .ctrl => |ctrl| if (ctrl == 'd') {
                should_exit.* = true;
                if (prompt_worker_active.*) session.agent.abort();
                return;
            },
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
                        try switchSession(
                            allocator,
                            io,
                            env_map,
                            session,
                            current_provider,
                            session_overlay.choices[index].path,
                            options,
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
                            app_state,
                        );
                    },
                }
                overlay_value.deinit(allocator);
                overlay.* = null;
                return;
            },
        }
    }

    switch (key) {
        .ctrl => |ctrl| switch (ctrl) {
            'c' => {
                if (prompt_worker_active.*) {
                    session.agent.abort();
                    try app_state.setStatus("interrupt requested");
                }
                return;
            },
            'd' => {
                should_exit.* = true;
                if (prompt_worker_active.*) session.agent.abort();
                return;
            },
            'l' => {
                app_state.clearDisplay();
                return;
            },
            's' => {
                if (prompt_worker_active.*) {
                    try app_state.setStatus("wait for the current response to finish before switching sessions");
                    return;
                }
                overlay.* = try loadSessionOverlay(allocator, io, session_dir);
                return;
            },
            'p' => {
                if (prompt_worker_active.*) {
                    try app_state.setStatus("wait for the current response to finish before switching models");
                    return;
                }
                overlay.* = try loadModelOverlay(allocator, env_map, session.agent.getModel());
                return;
            },
            else => {},
        },
        .escape => {
            should_exit.* = true;
            if (prompt_worker_active.*) session.agent.abort();
            return;
        },
        .enter => {
            if (prompt_worker_active.*) {
                try app_state.setStatus("response in progress");
                return;
            }
            const trimmed = std.mem.trim(u8, editor.text(), " \t\r\n");
            if (trimmed.len == 0) return;
            try prompt_worker.start(allocator, session, app_state, trimmed);
            prompt_worker_active.* = true;
            editor.buffer.clearRetainingCapacity();
            editor.cursor = 0;
            try app_state.setStatus("streaming");
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

fn switchSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    session: *session_mod.AgentSession,
    current_provider: *provider_config.ResolvedProviderConfig,
    session_path: []const u8,
    options: RunInteractiveModeOptions,
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
        options.api_key,
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
    app_state: *AppState,
) !void {
    var next_provider = provider_config.resolveProviderConfig(
        allocator,
        env_map,
        provider_name,
        model_id,
        null,
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

fn formatPromptLine(allocator: std.mem.Allocator, prompt: []const u8, width: usize) ![]u8 {
    const line = if (prompt.len == 0)
        "Input: "
    else
        try std.fmt.allocPrint(allocator, "Input: {s}", .{prompt});
    defer if (!std.mem.eql(u8, line, "Input: ")) allocator.free(line);
    return try fitLine(allocator, line, width);
}

fn formatFooterLine(
    allocator: std.mem.Allocator,
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
    return try fitLine(allocator, line, width);
}

fn fitLine(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    if (width == 0) return allocator.dupe(u8, "");
    if (tui.ansi.visibleWidth(text) <= width) return tui.ansi.padRightVisibleAlloc(allocator, text, width);

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var visible: usize = 0;
    var index: usize = 0;
    const limit = if (width > 1) width - 1 else 0;
    while (index < text.len and visible < limit) {
        const rune_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const actual_len = @min(rune_len, text.len - index);
        try builder.appendSlice(allocator, text[index .. index + actual_len]);
        index += actual_len;
        visible += 1;
    }
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
        return try std.fmt.allocPrint(allocator, "Pi: {s}", .{body});
    }
    if (message.stop_reason == .error_reason) {
        return try std.fmt.allocPrint(allocator, "Pi error: {s}", .{message.error_message orelse "unknown error"});
    }
    if (message.stop_reason == .aborted) {
        return try allocator.dupe(u8, "Pi: [interrupted]");
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
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 2].text, "Pi: partial") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[state.items.items.len - 1].text, "Tool result bash: /tmp") != null);
}
