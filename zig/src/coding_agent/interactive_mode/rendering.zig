const builtin = @import("builtin");
const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tui = @import("tui");
const keybindings_mod = @import("../keybindings.zig");
const resources_mod = @import("../resources.zig");
const session_mod = @import("../session.zig");
const session_advanced = @import("../session_advanced.zig");
const common = @import("../tools/common.zig");
const shared = @import("shared.zig");
const formatting = @import("formatting.zig");
const overlays = @import("overlays.zig");
const currentSessionLabel = shared.currentSessionLabel;
const SelectorOverlay = overlays.SelectorOverlay;
const ASSISTANT_PREFIX = formatting.ASSISTANT_PREFIX;
const ASSISTANT_THINKING_TEXT = "Thinking...";
const formatPrefixedBlocks = formatting.formatPrefixedBlocks;
const formatAssistantMessage = formatting.formatAssistantMessage;
const formatToolCall = formatting.formatToolCall;
const formatToolResult = formatting.formatToolResult;

pub const ChatKind = enum {
    welcome,
    info,
    @"error",
    markdown,
    user,
    assistant,
    tool_call,
    tool_result,
};

pub const ChatItem = struct {
    kind: ChatKind,
    text: []u8,
};

pub const FooterUsageTotals = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    cost: f64 = 0,
};

const ActiveToolUpdate = struct {
    tool_call_id: []u8,
    item_index: usize,
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(ChatItem) = .empty,
    visible_start_index: usize = 0,
    last_streaming_assistant_index: ?usize = null,
    status: []u8 = &.{},
    model_label: []u8 = &.{},
    session_label: []u8 = &.{},
    git_branch: []u8 = &.{},
    usage_totals: FooterUsageTotals = .{},
    context_window: u32 = 0,
    context_tokens: ?u32 = null,
    context_percent: ?f64 = null,
    context_unknown: bool = false,
    queued_steering: std.ArrayList([]u8) = .empty,
    queued_follow_up: std.ArrayList([]u8) = .empty,
    pending_editor_images: std.ArrayList(ai.ImageContent) = .empty,
    active_tool_updates: std.ArrayList(ActiveToolUpdate) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !AppState {
        var state = AppState{
            .allocator = allocator,
            .io = io,
        };
        errdefer state.deinit();
        state.status = try allocator.dupe(u8, "idle");
        state.model_label = try allocator.dupe(u8, "unknown");
        state.session_label = try allocator.dupe(u8, "new");
        state.git_branch = try allocator.dupe(u8, "");
        try state.appendItemLocked(.welcome, "Welcome to pi (Zig interactive mode). Type a prompt and press Enter.");
        return state;
    }

    pub fn deinit(self: *AppState) void {
        self.clearPendingEditorImagesLocked();
        self.pending_editor_images.deinit(self.allocator);
        self.clearActiveToolUpdatesLocked();
        self.active_tool_updates.deinit(self.allocator);
        self.clearQueuedMessagesLocked();
        self.queued_steering.deinit(self.allocator);
        self.queued_follow_up.deinit(self.allocator);
        for (self.items.items) |item| self.allocator.free(item.text);
        self.items.deinit(self.allocator);
        self.allocator.free(self.status);
        self.allocator.free(self.model_label);
        self.allocator.free(self.session_label);
        self.allocator.free(self.git_branch);
        self.* = undefined;
    }

    pub fn appendPendingEditorImage(self: *AppState, image: ai.ImageContent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.pending_editor_images.append(self.allocator, image);
    }

    pub fn clearPendingEditorImages(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearPendingEditorImagesLocked();
    }

    pub fn clonePendingEditorImages(self: *AppState, allocator: std.mem.Allocator) ![]ai.ImageContent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.pending_editor_images.items.len == 0) return &.{};

        const cloned = try allocator.alloc(ai.ImageContent, self.pending_editor_images.items.len);
        var initialized: usize = 0;
        errdefer {
            for (cloned[0..initialized]) |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            }
            allocator.free(cloned);
        }

        for (self.pending_editor_images.items, 0..) |image, index| {
            cloned[index] = .{
                .data = try allocator.dupe(u8, image.data),
                .mime_type = try allocator.dupe(u8, image.mime_type),
            };
            initialized += 1;
        }
        return cloned;
    }

    pub fn clearDisplay(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.visible_start_index = self.items.items.len;
        self.replaceLabelLocked(&self.status, "display cleared") catch {};
    }

    pub fn appendQueuedMessage(self: *AppState, mode: QueueDisplayMode, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const target = switch (mode) {
            .steering => &self.queued_steering,
            .follow_up => &self.queued_follow_up,
        };
        try target.append(self.allocator, try self.allocator.dupe(u8, text));
    }

    pub fn clearQueuedMessages(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearQueuedMessagesLocked();
    }

    pub fn setFooter(self: *AppState, model_label: []const u8, session_label: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.replaceLabelLocked(&self.model_label, model_label);
        try self.replaceLabelLocked(&self.session_label, session_label);
    }

    pub fn setFooterDetails(
        self: *AppState,
        model: ai.Model,
        session_label: []const u8,
        git_branch: ?[]const u8,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.replaceLabelLocked(&self.model_label, model.id);
        try self.replaceLabelLocked(&self.session_label, session_label);
        try self.replaceLabelLocked(&self.git_branch, git_branch orelse "");
        self.context_window = model.context_window;
        self.recalculateContextPercentLocked();
    }

    pub fn setStatus(self: *AppState, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.replaceLabelLocked(&self.status, text);
    }

    pub fn appendInfo(self: *AppState, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.appendItemLocked(.info, text);
    }

    pub fn appendMarkdown(self: *AppState, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.appendItemLocked(.markdown, text);
    }

    pub fn appendError(self: *AppState, text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.removeAssistantThinkingItemLocked();
        try self.appendItemLocked(.@"error", text);
        try self.replaceLabelLocked(&self.status, text);
    }

    pub fn rebuildFromSession(
        self: *AppState,
        session: *const session_mod.AgentSession,
        git_branch: ?[]const u8,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const messages = session.agent.getMessages();
        const stats = session_advanced.getSessionStats(session);

        for (self.items.items) |item| self.allocator.free(item.text);
        self.items.clearRetainingCapacity();
        self.visible_start_index = 0;
        self.last_streaming_assistant_index = null;
        self.clearPendingEditorImagesLocked();
        self.clearActiveToolUpdatesLocked();
        self.clearQueuedMessagesLocked();

        try self.replaceLabelLocked(&self.status, "idle");
        try self.replaceLabelLocked(&self.model_label, session.agent.getModel().id);
        try self.replaceLabelLocked(&self.session_label, currentSessionLabel(session));
        try self.replaceLabelLocked(&self.git_branch, git_branch orelse "");
        self.usage_totals = .{
            .input = stats.tokens.input,
            .output = stats.tokens.output,
            .cache_read = stats.tokens.cache_read,
            .cache_write = stats.tokens.cache_write,
            .cost = stats.cost,
        };
        self.context_window = session.agent.getModel().context_window;
        self.context_tokens = if (stats.context_usage) |usage| usage.tokens else null;
        self.context_percent = if (stats.context_usage) |usage| usage.percent else null;
        self.context_unknown = if (stats.context_usage) |usage| usage.percent == null else false;
        self.recalculateContextPercentLocked();
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

    pub fn handleAgentEvent(self: *AppState, event: agent.AgentEvent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        switch (event.event_type) {
            .agent_start => try self.replaceLabelLocked(&self.status, "thinking"),
            .agent_end => {
                if (std.mem.eql(u8, self.status, "streaming") or
                    std.mem.eql(u8, self.status, "thinking") or
                    std.mem.eql(u8, self.status, "working") or
                    std.mem.startsWith(u8, self.status, "working: "))
                {
                    try self.replaceLabelLocked(&self.status, "idle");
                }
            },
            .message_start => {
                if (event.message) |message| switch (message) {
                    .assistant => |assistant_message| {
                        try self.ensureAssistantThinkingItemLocked();
                        self.updateContextUsageLocked(assistantContextTokens(assistant_message.usage));
                        try self.replaceLabelLocked(&self.status, "thinking");
                    },
                    else => {},
                };
            },
            .message_update => {
                if (event.assistant_message_event) |assistant_event| {
                    switch (assistant_event.event_type) {
                        .thinking_start, .thinking_delta, .thinking_end => try self.replaceLabelLocked(&self.status, "thinking"),
                        .text_start, .text_delta, .text_end => try self.replaceLabelLocked(&self.status, "streaming"),
                        else => {},
                    }
                }
                if (event.message) |message| switch (message) {
                    .assistant => |assistant_message| {
                        self.updateContextUsageLocked(assistantContextTokens(assistant_message.usage));
                        const rendered = try formatAssistantMessage(self.allocator, assistant_message);
                        defer self.allocator.free(rendered);
                        if (rendered.len == 0) {
                            if (self.last_streaming_assistant_index) |_| return;
                            try self.ensureAssistantThinkingItemLocked();
                            return;
                        }
                        if (event.assistant_message_event == null) {
                            try self.replaceLabelLocked(&self.status, "streaming");
                        }
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
                        self.removeQueuedMessageLocked(userMessageText(user_message));
                        const rendered = try formatPrefixedBlocks(self.allocator, "You", user_message.content);
                        defer self.allocator.free(rendered);
                        try self.appendItemLocked(.user, rendered);
                        if (std.mem.eql(u8, self.status, "thinking")) {
                            try self.ensureAssistantThinkingItemLocked();
                        }
                    },
                    .assistant => |assistant_message| {
                        self.addUsageLocked(assistant_message.usage);
                        self.updateContextUsageLocked(assistantContextTokens(assistant_message.usage));
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
                const status_text = try std.fmt.allocPrint(self.allocator, "working: {s}", .{tool_name});
                defer self.allocator.free(status_text);
                try self.replaceLabelLocked(&self.status, status_text);
            },
            .tool_execution_update => {
                const tool_name = event.tool_name orelse "tool";
                const status_text = try std.fmt.allocPrint(self.allocator, "working: {s}", .{tool_name});
                defer self.allocator.free(status_text);
                if (event.tool_call_id) |tool_call_id| {
                    if (event.partial_result) |partial_result| {
                        const rendered = try formatToolResult(self.allocator, tool_name, partial_result.content, false);
                        defer self.allocator.free(rendered);
                        if (self.activeToolUpdateIndexLocked(tool_call_id)) |index| {
                            try self.replaceItemTextLocked(index, rendered);
                        } else {
                            try self.appendItemLocked(.tool_result, rendered);
                            try self.setActiveToolUpdateLocked(tool_call_id, self.items.items.len - 1);
                        }
                    }
                }
                try self.replaceLabelLocked(&self.status, status_text);
            },
            .tool_execution_end => {
                const tool_name = event.tool_name orelse "tool";
                const result = event.result orelse return;
                const rendered = try formatToolResult(self.allocator, tool_name, result.content, event.is_error orelse false);
                defer self.allocator.free(rendered);
                if (event.tool_call_id) |tool_call_id| {
                    if (self.takeActiveToolUpdateIndexLocked(tool_call_id)) |index| {
                        try self.replaceItemTextLocked(index, rendered);
                    } else {
                        try self.appendItemLocked(.tool_result, rendered);
                    }
                } else {
                    try self.appendItemLocked(.tool_result, rendered);
                }
                try self.replaceLabelLocked(&self.status, "thinking");
            },
            else => {},
        }
    }

    pub fn ensureAssistantThinkingItemLocked(self: *AppState) !void {
        if (self.last_streaming_assistant_index) |index| {
            if (index < self.items.items.len and self.items.items[index].kind == .assistant and self.items.items[index].text.len == 0) {
                try self.replaceItemTextLocked(index, ASSISTANT_THINKING_TEXT);
            }
            return;
        }

        try self.appendItemLocked(.assistant, ASSISTANT_THINKING_TEXT);
        self.last_streaming_assistant_index = self.items.items.len - 1;
    }

    pub fn removeAssistantThinkingItemLocked(self: *AppState) void {
        const index = self.last_streaming_assistant_index orelse return;
        self.last_streaming_assistant_index = null;
        if (index >= self.items.items.len) return;
        const item = self.items.items[index];
        if (item.kind == .assistant and std.mem.eql(u8, item.text, ASSISTANT_THINKING_TEXT)) {
            self.removeItemLocked(index);
        }
    }

    pub fn appendItemLocked(self: *AppState, kind: ChatKind, text: []const u8) !void {
        try self.items.append(self.allocator, .{
            .kind = kind,
            .text = try self.allocator.dupe(u8, text),
        });
    }

    pub fn replaceItemTextLocked(self: *AppState, index: usize, text: []const u8) !void {
        if (index >= self.items.items.len) return;
        self.allocator.free(self.items.items[index].text);
        self.items.items[index].text = try self.allocator.dupe(u8, text);
    }

    pub fn removeItemLocked(self: *AppState, index: usize) void {
        if (index >= self.items.items.len) return;
        self.allocator.free(self.items.items[index].text);
        _ = self.items.orderedRemove(index);
        for (self.active_tool_updates.items) |*entry| {
            if (entry.item_index > index) entry.item_index -= 1;
        }
        if (self.visible_start_index > self.items.items.len) {
            self.visible_start_index = self.items.items.len;
        }
    }

    pub fn replaceLabelLocked(self: *AppState, field: *[]u8, text: []const u8) !void {
        self.allocator.free(field.*);
        field.* = try self.allocator.dupe(u8, text);
    }

    pub fn addUsageLocked(self: *AppState, usage: ai.Usage) void {
        self.usage_totals.input +|= usage.input;
        self.usage_totals.output +|= usage.output;
        self.usage_totals.cache_read +|= usage.cache_read;
        self.usage_totals.cache_write +|= usage.cache_write;
        self.usage_totals.cost += usage.cost.total;
    }

    pub fn updateContextUsageLocked(self: *AppState, tokens: ?u32) void {
        if (tokens == null) {
            self.context_unknown = true;
        } else {
            self.context_unknown = false;
        }
        self.context_tokens = tokens;
        self.recalculateContextPercentLocked();
    }

    pub fn recalculateContextPercentLocked(self: *AppState) void {
        if (self.context_window == 0) {
            self.context_percent = null;
            self.context_tokens = null;
            self.context_unknown = false;
            return;
        }

        if (self.context_unknown) {
            self.context_percent = null;
            return;
        }

        if (self.context_tokens) |tokens| {
            self.context_percent =
                (@as(f64, @floatFromInt(tokens)) / @as(f64, @floatFromInt(self.context_window))) * 100.0;
            return;
        }

        self.context_tokens = 0;
        self.context_percent = 0.0;
    }

    fn clearPendingEditorImagesLocked(self: *AppState) void {
        for (self.pending_editor_images.items) |image| {
            self.allocator.free(image.data);
            self.allocator.free(image.mime_type);
        }
        self.pending_editor_images.clearRetainingCapacity();
    }

    fn clearActiveToolUpdatesLocked(self: *AppState) void {
        for (self.active_tool_updates.items) |entry| self.allocator.free(entry.tool_call_id);
        self.active_tool_updates.clearRetainingCapacity();
    }

    fn activeToolUpdateIndexLocked(self: *AppState, tool_call_id: []const u8) ?usize {
        for (self.active_tool_updates.items) |entry| {
            if (std.mem.eql(u8, entry.tool_call_id, tool_call_id)) return entry.item_index;
        }
        return null;
    }

    fn setActiveToolUpdateLocked(self: *AppState, tool_call_id: []const u8, item_index: usize) !void {
        for (self.active_tool_updates.items) |*entry| {
            if (std.mem.eql(u8, entry.tool_call_id, tool_call_id)) {
                entry.item_index = item_index;
                return;
            }
        }
        try self.active_tool_updates.append(self.allocator, .{
            .tool_call_id = try self.allocator.dupe(u8, tool_call_id),
            .item_index = item_index,
        });
    }

    fn takeActiveToolUpdateIndexLocked(self: *AppState, tool_call_id: []const u8) ?usize {
        for (self.active_tool_updates.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.tool_call_id, tool_call_id)) continue;
            const item_index = entry.item_index;
            self.allocator.free(entry.tool_call_id);
            _ = self.active_tool_updates.orderedRemove(index);
            return item_index;
        }
        return null;
    }

    fn clearQueuedMessagesLocked(self: *AppState) void {
        for (self.queued_steering.items) |text| self.allocator.free(text);
        self.queued_steering.clearRetainingCapacity();
        for (self.queued_follow_up.items) |text| self.allocator.free(text);
        self.queued_follow_up.clearRetainingCapacity();
    }

    fn removeQueuedMessageLocked(self: *AppState, text: []const u8) void {
        if (removeQueuedTextFromList(self.allocator, &self.queued_steering, text)) return;
        _ = removeQueuedTextFromList(self.allocator, &self.queued_follow_up, text);
    }
};

pub const QueueDisplayMode = enum {
    steering,
    follow_up,
};

pub const ScreenComponent = struct {
    state: *AppState,
    editor: *tui.Editor,
    height: usize = 24,
    overlay: ?*SelectorOverlay = null,
    keybindings: ?*const keybindings_mod.Keybindings = null,
    theme: ?*const resources_mod.Theme = null,

    pub fn component(self: *const ScreenComponent) tui.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *tui.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const ScreenComponent = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }

    pub fn renderInto(
        self: *const ScreenComponent,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *tui.LineList,
    ) std.mem.Allocator.Error!void {
        self.editor.setTheme(self.theme);

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
        try renderPromptLines(allocator, self.theme, self.editor, self.state.pending_editor_images.items, width, &prompt_lines);
        var queued_lines = tui.LineList.empty;
        defer freeLinesSafe(allocator, &queued_lines);
        try renderQueuedMessageLines(allocator, self.keybindings, self.theme, self.state, width, &queued_lines);
        const footer_line = try formatFooterLine(allocator, self.theme, self.state, width);
        defer allocator.free(footer_line);
        const hints_line = try formatHintsLine(allocator, self.keybindings, self.theme, width);
        defer allocator.free(hints_line);

        var autocomplete_lines = tui.LineList.empty;
        defer freeLinesSafe(allocator, &autocomplete_lines);
        try self.editor.renderAutocompleteInto(allocator, width, &autocomplete_lines);

        const reserved_lines: usize = prompt_lines.items.len + queued_lines.items.len + 2 + autocomplete_lines.items.len;
        const chat_capacity = if (self.height > reserved_lines) self.height - reserved_lines else 1;
        const chat_component = BorrowedLinesComponent{ .lines = chat_lines.items };
        const chat_viewport = tui.Viewport{
            .child = chat_component.component(),
            .height = chat_capacity,
            .anchor = .bottom,
        };
        try chat_viewport.renderInto(allocator, width, lines);
        for (queued_lines.items) |line| {
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
};

pub const BorrowedLinesComponent = struct {
    lines: []const []u8,

    pub fn component(self: *const BorrowedLinesComponent) tui.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *tui.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const BorrowedLinesComponent = @ptrCast(@alignCast(ptr));
        for (self.lines) |line| {
            const fitted = try fitLine(allocator, line, width);
            defer allocator.free(fitted);
            try tui.component.appendOwnedLine(lines, allocator, fitted);
        }
    }
};

pub const OverlayPanelComponent = struct {
    overlay: *SelectorOverlay,
    theme: ?*const resources_mod.Theme = null,
    max_height: usize = 12,

    pub fn component(self: *const OverlayPanelComponent) tui.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *tui.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const OverlayPanelComponent = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }

    pub fn renderInto(
        self: *const OverlayPanelComponent,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *tui.LineList,
    ) std.mem.Allocator.Error!void {
        const title_text = try applyThemeAlloc(allocator, self.theme, .overlay_title, self.overlay.title());
        defer allocator.free(title_text);
        const hint_text = try applyThemeAlloc(allocator, self.theme, .overlay_hint, self.overlay.hint());
        defer allocator.free(hint_text);

        const title_component = tui.Text{
            .text = title_text,
            .padding_x = 0,
            .padding_y = 0,
        };
        const hint_component = tui.Text{
            .text = hint_text,
            .padding_x = 0,
            .padding_y = 0,
        };

        var content = tui.Flex.init(.column);
        defer content.deinit(allocator);
        content.gap = 1;
        try content.addChild(allocator, .{ .component = title_component.component() });
        try content.addChild(allocator, .{ .component = hint_component.component() });

        const box_padding_y: usize = 1;
        const border_lines: usize = if (self.theme != null and width >= 2) 2 else 0;

        switch (self.overlay.*) {
            .settings_editor => |*settings_editor| {
                settings_editor.editor.setTheme(self.theme);
                const path_text = try applyThemeAlloc(allocator, self.theme, .overlay_hint, settings_editor.path);
                defer allocator.free(path_text);
                const path_component = tui.Text{
                    .text = path_text,
                    .padding_x = 0,
                    .padding_y = 0,
                };
                try content.addChild(allocator, .{ .component = path_component.component() });

                const chrome_lines = border_lines + box_padding_y * 2 + 4;
                const body_height = @max(@as(usize, 4), if (self.max_height > chrome_lines) self.max_height - chrome_lines else 4);
                const editor_viewport = tui.Viewport{
                    .child = settings_editor.editor.component(),
                    .height = body_height,
                    .anchor = .top,
                };
                try content.addChild(allocator, .{ .component = editor_viewport.component() });
            },
            else => {
                const chrome_lines = border_lines + box_padding_y * 2 + 3;
                const body_height = @max(@as(usize, 3), if (self.max_height > chrome_lines) self.max_height - chrome_lines else 3);
                const overlay_list = switch (self.overlay.*) {
                    .info => |*info_overlay| &info_overlay.list,
                    .session => |*session_overlay| &session_overlay.list,
                    .model => |*model_overlay| &model_overlay.list,
                    .tree => |*tree_overlay| &tree_overlay.list,
                    .auth => |*auth_overlay| &auth_overlay.list,
                    else => unreachable,
                };
                overlay_list.theme = self.theme;
                overlay_list.max_visible = body_height;

                const list_viewport = tui.Viewport{
                    .child = overlay_list.component(),
                    .height = body_height,
                    .show_indicators = true,
                    .theme = self.theme,
                    .indicator_token = .select_scroll,
                };
                try content.addChild(allocator, .{ .component = list_viewport.component() });
            },
        }

        var panel_box = tui.Box.init(2, box_padding_y);
        defer panel_box.deinit(allocator);
        panel_box.theme = self.theme;
        try panel_box.addChild(allocator, content.component());
        try panel_box.renderInto(allocator, width, lines);
    }
};

pub fn overlayPanelMaxHeight(height: usize) usize {
    return if (height > 4) height - 4 else @max(height, 3);
}

pub fn overlayPanelWidth(width: usize) usize {
    if (width <= 24) return @max(width -| 2, 12);
    return std.math.clamp((width * 2) / 3, @as(usize, 24), @min(width -| 2, @as(usize, 96)));
}

pub fn overlayAnimationProgress(now_ms: i64, opened_at_ms: ?i64) f32 {
    const opened = opened_at_ms orelse return 1.0;
    const elapsed_ms = @max(now_ms - opened, 0);
    const duration_ms: f32 = 140.0;
    const progress = @as(f32, @floatFromInt(elapsed_ms)) / duration_ms;
    return std.math.clamp(progress, 0.0, 1.0);
}

pub fn nowMilliseconds() i64 {
    var now: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&now, null);
    return @as(i64, @intCast(now.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(now.usec)), std.time.us_per_ms);
}

pub fn overlayPanelOptions(size: tui.Size, progress: f32) tui.OverlayOptions {
    return .{
        .width = overlayPanelWidth(size.width),
        .max_height = overlayPanelMaxHeight(size.height),
        .anchor = .center,
        .margin = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 },
        .animation = .{
            .kind = .slide_from_top,
            .progress = progress,
        },
    };
}

pub const NativeTerminalBackend = struct {
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

    pub fn backend(self: *NativeTerminalBackend) tui.Backend {
        return .{
            .ptr = self,
            .enterRawModeFn = enterRawMode,
            .restoreModeFn = restoreMode,
            .writeFn = write,
            .getSizeFn = getSize,
        };
    }

    pub fn enterRawMode(ptr: *anyopaque) !void {
        const self: *NativeTerminalBackend = @ptrCast(@alignCast(ptr));
        const current = try std.posix.tcgetattr(self.stdin_fd);
        self.original_termios = current;
        const raw = tui.terminal.makeRawMode(current);
        try std.posix.tcsetattr(self.stdin_fd, .NOW, raw);
        self.cached_size = self.readSize();
        self.resize_pending.store(false, .seq_cst);
        self.installResizeHandler();
    }

    pub fn restoreMode(ptr: *anyopaque) !void {
        const self: *NativeTerminalBackend = @ptrCast(@alignCast(ptr));
        self.uninstallResizeHandler();
        if (self.original_termios) |term| {
            try std.posix.tcsetattr(self.stdin_fd, .NOW, term);
        }
    }

    pub fn write(ptr: *anyopaque, bytes: []const u8) !void {
        const self: *NativeTerminalBackend = @ptrCast(@alignCast(ptr));
        var offset: usize = 0;
        while (offset < bytes.len) {
            const written = std.c.write(self.stdout_fd, bytes.ptr + offset, bytes.len - offset);
            if (written <= 0) return error.WriteFailed;
            offset += @intCast(written);
        }
    }

    pub fn getSize(ptr: *anyopaque) !tui.Size {
        const self: *NativeTerminalBackend = @ptrCast(@alignCast(ptr));
        self.refreshSizeIfPending();
        return self.cached_size;
    }

    pub fn readSize(self: *NativeTerminalBackend) tui.Size {
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

    pub fn refreshSizeIfPending(self: *NativeTerminalBackend) void {
        if (!self.resize_pending.swap(false, .seq_cst)) return;
        self.cached_size = self.readSize();
    }

    pub fn installResizeHandler(self: *NativeTerminalBackend) void {
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

    pub fn uninstallResizeHandler(self: *NativeTerminalBackend) void {
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
pub var active_resize_backend: ?*NativeTerminalBackend = null;

pub fn supportsResizeSignals() bool {
    return switch (builtin.os.tag) {
        .windows, .wasi, .emscripten, .freestanding => false,
        else => true,
    };
}

pub fn handleSigwinch(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    _ = info;
    _ = ctx_ptr;
    if (sig != .WINCH) return;
    if (active_resize_backend) |backend| {
        backend.resize_pending.store(true, .seq_cst);
    }
}

pub fn readTerminalSizeWithIoctl(_: ?*anyopaque, fd: std.posix.fd_t) ?tui.Size {
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

pub fn normalizeTerminalSize(size: tui.Size, fallback: tui.Size) tui.Size {
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

pub fn rebuildAppStateFromSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    app_state: *AppState,
    session: *const session_mod.AgentSession,
) !void {
    const git_branch = try resolveGitBranch(allocator, io, session.cwd);
    defer if (git_branch) |branch| allocator.free(branch);
    try app_state.rebuildFromSession(session, git_branch);
}

pub fn updateAppFooterFromSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    app_state: *AppState,
    session: *const session_mod.AgentSession,
) !void {
    const git_branch = try resolveGitBranch(allocator, io, session.cwd);
    defer if (git_branch) |branch| allocator.free(branch);
    try app_state.setFooterDetails(session.agent.getModel(), currentSessionLabel(session), git_branch);
}

pub fn assistantContextTokens(usage: ai.Usage) ?u32 {
    return usage.input +| usage.cache_read +| usage.cache_write;
}

pub fn resolveGitBranch(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !?[]u8 {
    const repo_root = try findGitRoot(allocator, io, cwd) orelse return null;
    defer allocator.free(repo_root);

    const git_path = try std.fs.path.join(allocator, &[_][]const u8{ repo_root, ".git" });
    defer allocator.free(git_path);

    const git_dir = try resolveGitDirectory(allocator, io, repo_root, git_path) orelse return null;
    defer allocator.free(git_dir);

    const head_path = try std.fs.path.join(allocator, &[_][]const u8{ git_dir, "HEAD" });
    defer allocator.free(head_path);

    const head = std.Io.Dir.readFileAlloc(.cwd(), io, head_path, allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(head);

    return parseGitHeadBranch(allocator, head);
}

pub fn findGitRoot(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) !?[]u8 {
    var current = try allocator.dupe(u8, cwd);
    errdefer allocator.free(current);

    while (true) {
        const git_path = try std.fs.path.join(allocator, &[_][]const u8{ current, ".git" });
        defer allocator.free(git_path);

        const stat = std.Io.Dir.statFile(.cwd(), io, git_path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (stat != null) {
            return current;
        }

        const parent = std.fs.path.dirname(current) orelse {
            allocator.free(current);
            return null;
        };
        if (std.mem.eql(u8, parent, current)) {
            allocator.free(current);
            return null;
        }

        const owned_parent = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = owned_parent;
    }
}

pub fn resolveGitDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    git_path: []const u8,
) !?[]u8 {
    const stat = std.Io.Dir.statFile(.cwd(), io, git_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    if (stat.kind == .directory) return try allocator.dupe(u8, git_path);
    if (stat.kind != .file) return null;

    const content = try std.Io.Dir.readFileAlloc(.cwd(), io, git_path, allocator, .limited(4096));
    defer allocator.free(content);
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;

    const gitdir = std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
    if (std.fs.path.isAbsolute(gitdir)) return try allocator.dupe(u8, gitdir);
    return try std.fs.path.resolve(allocator, &[_][]const u8{ repo_root, gitdir });
}

pub fn parseGitHeadBranch(allocator: std.mem.Allocator, head_contents: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, head_contents, " \t\r\n");
    const prefix = "ref:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;

    const ref_name = std.mem.trim(u8, trimmed[prefix.len..], " \t");
    const heads_prefix = "refs/heads/";
    if (std.mem.startsWith(u8, ref_name, heads_prefix)) {
        return try allocator.dupe(u8, ref_name[heads_prefix.len..]);
    }
    return try allocator.dupe(u8, std.fs.path.basename(ref_name));
}

pub fn parseEnvSize(value: ?[]const u8) ?usize {
    const text = value orelse return null;
    return std.fmt.parseInt(usize, text, 10) catch null;
}

pub fn freeLinesSafe(allocator: std.mem.Allocator, lines: *tui.LineList) void {
    if (lines.items.len == 0) {
        lines.deinit(allocator);
        return;
    }
    tui.component.freeLines(allocator, lines);
}

pub const INPUT_PROMPT_PREFIX = "Input: ";

pub fn renderPromptLines(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    pending_images: []const ai.ImageContent,
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

        if (index == 0 and theme != null) {
            const themed_prefix = try applyThemeAlloc(allocator, theme, .prompt, INPUT_PROMPT_PREFIX);
            defer allocator.free(themed_prefix);
            try builder.appendSlice(allocator, themed_prefix);
        } else {
            try builder.appendSlice(allocator, if (index == 0) INPUT_PROMPT_PREFIX else continuation_prefix);
        }
        try builder.appendSlice(allocator, editor_line);

        const fitted = try fitLine(allocator, builder.items, width);
        defer allocator.free(fitted);
        try tui.component.appendOwnedLine(lines, allocator, fitted);
        builder.deinit(allocator);
    }

    for (pending_images, 0..) |image, index| {
        const placeholder_text = try std.fmt.allocPrint(allocator, "[image {d}: {s}]", .{ index + 1, image.mime_type });
        defer allocator.free(placeholder_text);

        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);
        try builder.appendSlice(allocator, continuation_prefix);
        if (theme) |active_theme| {
            const themed_placeholder = try active_theme.applyAlloc(allocator, .prompt, placeholder_text);
            defer allocator.free(themed_placeholder);
            try builder.appendSlice(allocator, themed_placeholder);
        } else {
            try builder.appendSlice(allocator, placeholder_text);
        }

        const fitted = try fitLine(allocator, builder.items, width);
        defer allocator.free(fitted);
        try tui.component.appendOwnedLine(lines, allocator, fitted);
        builder.deinit(allocator);
    }
}

pub fn formatFooterLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    state: *const AppState,
    width: usize,
) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    var needs_separator = false;
    if (state.git_branch.len > 0) {
        const branch_text = try std.fmt.allocPrint(allocator, "Branch: {s}", .{state.git_branch});
        defer allocator.free(branch_text);
        try appendFooterPart(allocator, &builder, &needs_separator, branch_text);
    }
    const session_text = try std.fmt.allocPrint(allocator, "Session: {s}", .{state.session_label});
    defer allocator.free(session_text);
    try appendFooterPart(allocator, &builder, &needs_separator, session_text);
    const status_text = try std.fmt.allocPrint(allocator, "Status: {s}", .{state.status});
    defer allocator.free(status_text);
    try appendFooterPart(allocator, &builder, &needs_separator, status_text);

    const input_text = try formatCompactTokenCount(allocator, state.usage_totals.input);
    defer allocator.free(input_text);
    const output_text = try formatCompactTokenCount(allocator, state.usage_totals.output);
    defer allocator.free(output_text);
    const input_part = try std.fmt.allocPrint(allocator, "↑{s}", .{input_text});
    defer allocator.free(input_part);
    const output_part = try std.fmt.allocPrint(allocator, "↓{s}", .{output_text});
    defer allocator.free(output_part);
    try appendFooterPart(allocator, &builder, &needs_separator, input_part);
    try appendFooterPart(allocator, &builder, &needs_separator, output_part);

    if (state.usage_totals.cache_read > 0) {
        const cache_read_text = try formatCompactTokenCount(allocator, state.usage_totals.cache_read);
        defer allocator.free(cache_read_text);
        const cache_read_part = try std.fmt.allocPrint(allocator, "R{s}", .{cache_read_text});
        defer allocator.free(cache_read_part);
        try appendFooterPart(allocator, &builder, &needs_separator, cache_read_part);
    }
    if (state.usage_totals.cache_write > 0) {
        const cache_write_text = try formatCompactTokenCount(allocator, state.usage_totals.cache_write);
        defer allocator.free(cache_write_text);
        const cache_write_part = try std.fmt.allocPrint(allocator, "W{s}", .{cache_write_text});
        defer allocator.free(cache_write_part);
        try appendFooterPart(allocator, &builder, &needs_separator, cache_write_part);
    }
    if (state.usage_totals.cost > 0) {
        const cost_text = try std.fmt.allocPrint(allocator, "${d:.3}", .{state.usage_totals.cost});
        defer allocator.free(cost_text);
        try appendFooterPart(allocator, &builder, &needs_separator, cost_text);
    }
    if (state.context_window > 0) {
        const window_text = try formatCompactTokenCount(allocator, state.context_window);
        defer allocator.free(window_text);
        const context_text = if (state.context_percent) |percent|
            try std.fmt.allocPrint(allocator, "ctx {d:.1}%/{s}", .{ percent, window_text })
        else
            try std.fmt.allocPrint(allocator, "ctx ?/{s}", .{window_text});
        defer allocator.free(context_text);
        try appendFooterPart(allocator, &builder, &needs_separator, context_text);
    }

    const model_text = try std.fmt.allocPrint(allocator, "Model: {s}", .{state.model_label});
    defer allocator.free(model_text);
    try appendFooterPart(allocator, &builder, &needs_separator, model_text);

    const fitted = try fitLine(allocator, builder.items, width);
    defer allocator.free(fitted);
    return try applyThemeAlloc(allocator, theme, .footer, fitted);
}

pub fn appendFooterPart(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    needs_separator: *bool,
    text: []const u8,
) std.mem.Allocator.Error!void {
    if (needs_separator.*) try builder.appendSlice(allocator, " • ");
    try builder.appendSlice(allocator, text);
    needs_separator.* = true;
}

pub fn formatCompactTokenCount(allocator: std.mem.Allocator, count: u64) ![]u8 {
    if (count < 1_000) return std.fmt.allocPrint(allocator, "{d}", .{count});
    if (count < 10_000) {
        return std.fmt.allocPrint(
            allocator,
            "{d}.{d}k",
            .{ count / 1_000, (count % 1_000) / 100 },
        );
    }
    if (count < 1_000_000) return std.fmt.allocPrint(allocator, "{d}k", .{(count + 500) / 1_000});
    if (count < 10_000_000) {
        return std.fmt.allocPrint(
            allocator,
            "{d}.{d}M",
            .{ count / 1_000_000, (count % 1_000_000) / 100_000 },
        );
    }
    return std.fmt.allocPrint(allocator, "{d}M", .{(count + 500_000) / 1_000_000});
}

pub fn formatHintsLine(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    width: usize,
) ![]u8 {
    const open_sessions = try actionLabel(allocator, keybindings, .open_sessions, "Ctrl+S");
    defer allocator.free(open_sessions);
    const open_models = try actionLabel(allocator, keybindings, .open_models, "Ctrl+P");
    defer allocator.free(open_models);
    const queue_follow_up = try actionLabel(allocator, keybindings, .queue_follow_up, "Alt+Enter");
    defer allocator.free(queue_follow_up);
    const dequeue_messages = try actionLabel(allocator, keybindings, .dequeue_messages, "Alt+Up");
    defer allocator.free(dequeue_messages);
    const interrupt = try actionLabel(allocator, keybindings, .interrupt, "Ctrl+C");
    defer allocator.free(interrupt);
    const exit = try actionLabel(allocator, keybindings, .exit, "Ctrl+D");
    defer allocator.free(exit);
    const clear = try actionLabel(allocator, keybindings, .clear, "Ctrl+L");
    defer allocator.free(clear);
    const paste_image = try actionLabel(allocator, keybindings, .paste_image, "Ctrl+V");
    defer allocator.free(paste_image);

    const line = try std.fmt.allocPrint(
        allocator,
        "{s} sessions • {s} models • {s} paste image • {s} queue • {s} dequeue • {s} interrupt • {s} exit • {s} clear",
        .{ open_sessions, open_models, paste_image, queue_follow_up, dequeue_messages, interrupt, exit, clear },
    );
    defer allocator.free(line);
    const fitted = try fitLine(allocator, line, width);
    defer allocator.free(fitted);
    return try applyThemeAlloc(allocator, theme, .status, fitted);
}

pub fn actionLabel(
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

pub fn themeChatItem(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
) ![]u8 {
    return try applyThemeAlloc(allocator, theme, switch (item.kind) {
        .welcome => .welcome,
        .info => .status,
        .@"error" => .@"error",
        .markdown => .markdown_text,
        .user => .user,
        .assistant => .assistant,
        .tool_call => .tool_call,
        .tool_result => .tool_result,
    }, item.text);
}

pub fn renderChatItemInto(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    lines: *tui.LineList,
) !void {
    switch (item.kind) {
        .assistant => try renderAssistantChatItemInto(allocator, width, theme, item.text, lines),
        .markdown => try renderMarkdownChatItemInto(allocator, width, theme, item.text, lines),
        else => {
            const themed_item = try themeChatItem(allocator, theme, item);
            defer allocator.free(themed_item);
            try tui.ansi.wrapTextWithAnsi(allocator, themed_item, width, lines);
        },
    }
}

pub fn renderAssistantChatItemInto(
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
        .theme = theme,
    };
    try markdown.renderInto(allocator, width, lines);
}

pub fn renderMarkdownChatItemInto(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    text: []const u8,
    lines: *tui.LineList,
) !void {
    const markdown = tui.Markdown{
        .text = text,
        .theme = theme,
    };
    try markdown.renderInto(allocator, width, lines);
}

pub fn applyThemeAlloc(
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

pub fn fitLine(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
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

pub fn handleAppAgentEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const app_state: *AppState = @ptrCast(@alignCast(context.?));
    try app_state.handleAgentEvent(event);
}

fn removeQueuedTextFromList(
    allocator: std.mem.Allocator,
    items: *std.ArrayList([]u8),
    text: []const u8,
) bool {
    for (items.items, 0..) |queued_text, index| {
        if (std.mem.eql(u8, queued_text, text)) {
            allocator.free(queued_text);
            _ = items.orderedRemove(index);
            return true;
        }
    }
    return false;
}

fn userMessageText(message: ai.types.UserMessage) []const u8 {
    for (message.content) |block| {
        switch (block) {
            .text => |text| return text.text,
            else => {},
        }
    }
    return "";
}

pub fn renderQueuedMessageLines(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    state: *const AppState,
    width: usize,
    lines: *tui.LineList,
) !void {
    if (state.queued_steering.items.len == 0 and state.queued_follow_up.items.len == 0) return;

    const blank = try fitLine(allocator, "", width);
    defer allocator.free(blank);
    try tui.component.appendOwnedLine(lines, allocator, blank);

    for (state.queued_steering.items) |queued| {
        const line = try std.fmt.allocPrint(allocator, "Steering: {s}", .{queued});
        defer allocator.free(line);
        const themed = try applyThemeAlloc(allocator, theme, .status, line);
        defer allocator.free(themed);
        try tui.ansi.wrapTextWithAnsi(allocator, themed, width, lines);
    }

    for (state.queued_follow_up.items) |queued| {
        const line = try std.fmt.allocPrint(allocator, "Follow-up: {s}", .{queued});
        defer allocator.free(line);
        const themed = try applyThemeAlloc(allocator, theme, .status, line);
        defer allocator.free(themed);
        try tui.ansi.wrapTextWithAnsi(allocator, themed, width, lines);
    }

    const dequeue_label = try actionLabel(allocator, keybindings, .dequeue_messages, "Alt+Up");
    defer allocator.free(dequeue_label);
    const hint = try std.fmt.allocPrint(allocator, "↳ {s} to edit queued messages", .{dequeue_label});
    defer allocator.free(hint);
    const themed_hint = try applyThemeAlloc(allocator, theme, .status, hint);
    defer allocator.free(themed_hint);
    try tui.ansi.wrapTextWithAnsi(allocator, themed_hint, width, lines);
}

pub const InteractiveModeTestBackend = struct {
    size: tui.Size,
    entered_raw: bool = false,
    restored: bool = false,
    writes: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.writes.items) |entry| allocator.free(entry);
        self.writes.deinit(allocator);
    }

    pub fn backend(self: *@This()) tui.Backend {
        return .{
            .ptr = self,
            .enterRawModeFn = enterRawMode,
            .restoreModeFn = restoreMode,
            .writeFn = write,
            .getSizeFn = getSize,
        };
    }

    pub fn enterRawMode(ptr: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.entered_raw = true;
    }

    pub fn restoreMode(ptr: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.restored = true;
    }

    pub fn write(ptr: *anyopaque, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.writes.append(std.testing.allocator, try std.testing.allocator.dupe(u8, bytes));
    }

    pub fn getSize(ptr: *anyopaque) !tui.Size {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.size;
    }
};

pub fn renderScreenWithMockBackend(
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

pub fn renderScreenWithMockBackendAndOverlay(
    allocator: std.mem.Allocator,
    screen: *const ScreenComponent,
    overlay: *SelectorOverlay,
    backend: *InteractiveModeTestBackend,
) !tui.LineList {
    var terminal = tui.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = tui.Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    const panel = OverlayPanelComponent{
        .overlay = overlay,
        .theme = screen.theme,
        .max_height = overlayPanelMaxHeight(screen.height),
    };
    _ = try renderer.showOverlay(panel.component(), overlayPanelOptions(backend.size, 1.0));
    try renderer.render(screen.component());

    var lines = tui.LineList.empty;
    errdefer freeLinesSafe(allocator, &lines);
    for (renderer.previous_lines.items) |line| {
        try lines.append(allocator, try allocator.dupe(u8, line));
    }
    return lines;
}

pub fn renderedLinesContain(lines: []const []const u8, needle: []const u8) bool {
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

test "renderChatItemInto renders markdown chat items without assistant prefix" {
    const allocator = std.testing.allocator;

    var lines = tui.LineList.empty;
    defer tui.component.freeLines(allocator, &lines);

    const text = try allocator.dupe(u8,
        \\# Changelog
        \\- Added /changelog
    );
    defer allocator.free(text);

    try renderChatItemInto(allocator, 40, null, .{
        .kind = .markdown,
        .text = text,
    }, &lines);

    try std.testing.expect(renderedLinesContain(lines.items, "Changelog"));
    try std.testing.expect(renderedLinesContain(lines.items, "• "));
    try std.testing.expect(!renderedLinesContain(lines.items, ASSISTANT_PREFIX));
}

test "app state replaces streaming tool updates with the final tool result" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const partial_blocks = try allocator.alloc(ai.ContentBlock, 1);
    defer common.deinitContentBlocks(allocator, partial_blocks);
    partial_blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, "line 1\n\n[Running... 0.1s elapsed]") } };

    const final_blocks = try allocator.alloc(ai.ContentBlock, 1);
    defer common.deinitContentBlocks(allocator, final_blocks);
    final_blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, "line 1\nline 2") } };

    try state.handleAgentEvent(.{
        .event_type = .tool_execution_start,
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .args = .null,
    });
    try state.handleAgentEvent(.{
        .event_type = .tool_execution_update,
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .partial_result = .{
            .content = partial_blocks,
            .details = null,
        },
    });
    try state.handleAgentEvent(.{
        .event_type = .tool_execution_end,
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .result = .{
            .content = final_blocks,
            .details = null,
        },
        .is_error = false,
    });

    try std.testing.expectEqual(@as(usize, 3), state.items.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[2].text, "line 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[2].text, "Running...") == null);
    try std.testing.expectEqualStrings("thinking", state.status);
}
