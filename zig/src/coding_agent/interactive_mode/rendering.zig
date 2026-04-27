const builtin = @import("builtin");
const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tui = @import("tui");
const keybindings_mod = @import("../keybindings.zig");
const provider_config = @import("../provider_config.zig");
const resources_mod = @import("../resources.zig");
const session_mod = @import("../session.zig");
const session_advanced = @import("../session_advanced.zig");
const common = @import("../tools/common.zig");
const shared = @import("shared.zig");
const formatting = @import("formatting.zig");
const overlays = @import("overlays.zig");
const clipboard_image = @import("clipboard_image.zig");
const currentSessionLabel = shared.currentSessionLabel;
const SelectorOverlay = overlays.SelectorOverlay;
const ASSISTANT_PREFIX = formatting.ASSISTANT_PREFIX;
const ASSISTANT_THINKING_TEXT = "Thinking...";
const formatPrefixedBlocks = formatting.formatPrefixedBlocks;
const formatAssistantMessage = formatting.formatAssistantMessage;
const formatToolCall = formatting.formatToolCall;

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

pub const PendingEditorImage = struct {
    data: []const u8,
    mime_type: []const u8,
    kitty_image: ?tui.components.image.KittyImage = null,

    fn content(self: PendingEditorImage) ai.ImageContent {
        return .{
            .data = self.data,
            .mime_type = self.mime_type,
        };
    }
};

pub const TerminalImageContext = struct {
    vx: *tui.vaxis.Vaxis,
    tty: *std.Io.Writer,
};

pub const FooterUsageTotals = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    cost: f64 = 0,
};

pub const RenderStateSnapshot = struct {
    items: []ChatItem = &.{},
    status: ?[]u8 = null,
    provider_label: ?[]u8 = null,
    provider_status: ?[]u8 = null,
    model_label: ?[]u8 = null,
    session_label: ?[]u8 = null,
    git_branch: ?[]u8 = null,
    usage_totals: FooterUsageTotals = .{},
    context_window: u32 = 0,
    context_percent: ?f64 = null,
    queued_steering: [][]u8 = &.{},
    queued_follow_up: [][]u8 = &.{},
    pending_editor_images: []PendingEditorImage = &.{},

    pub fn deinit(self: *RenderStateSnapshot, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item.text);
        if (self.items.len > 0) allocator.free(self.items);
        if (self.status) |status| allocator.free(status);
        if (self.provider_label) |provider_label| allocator.free(provider_label);
        if (self.provider_status) |provider_status| allocator.free(provider_status);
        if (self.model_label) |model_label| allocator.free(model_label);
        if (self.session_label) |session_label| allocator.free(session_label);
        if (self.git_branch) |git_branch| allocator.free(git_branch);
        deinitOwnedStringList(allocator, self.queued_steering);
        deinitOwnedStringList(allocator, self.queued_follow_up);
        deinitImageContentsForRender(allocator, self.pending_editor_images);
        self.* = undefined;
    }
};

const ActiveToolUpdate = struct {
    tool_call_id: []u8,
    item_index: usize,
};

const CLIPBOARD_PASTE_PROGRESS_MIN_MS: i64 = 120;

const ClipboardPasteResult = union(enum) {
    none,
    success: ai.ImageContent,
    empty,
    failure,
};

const ClipboardPasteTask = struct {
    io: std.Io,
    env_map: ?*const std.process.Environ.Map = null,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result_mutex: std.Io.Mutex = .init,
    result: ClipboardPasteResult = .none,
    started_at_ms: i64 = 0,

    fn start(self: *ClipboardPasteTask, env_map: *const std.process.Environ.Map) !bool {
        if (self.thread != null) return false;
        self.env_map = env_map;
        self.started_at_ms = nowMilliseconds();
        self.running.store(true, .seq_cst);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return true;
    }

    fn poll(self: *ClipboardPasteTask) ?ClipboardPasteResult {
        if (self.thread == null) return null;
        if (self.running.load(.seq_cst)) return null;
        if (nowMilliseconds() - self.started_at_ms < CLIPBOARD_PASTE_PROGRESS_MIN_MS) return null;

        if (self.thread) |thread| thread.join();
        self.thread = null;

        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);

        const result = self.result;
        self.result = .none;
        return result;
    }

    fn isActive(self: *const ClipboardPasteTask) bool {
        return self.thread != null;
    }

    fn deinit(self: *ClipboardPasteTask) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.running.store(false, .seq_cst);

        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);
        freeClipboardPasteResult(&self.result);
        self.result = .none;
    }

    fn run(self: *ClipboardPasteTask) void {
        defer self.running.store(false, .seq_cst);

        const allocator = std.heap.page_allocator;
        const env_map = self.env_map orelse {
            self.storeResult(.failure);
            return;
        };

        var image = clipboard_image.readClipboardImage(allocator, self.io, env_map) catch {
            self.storeResult(.failure);
            return;
        } orelse {
            self.storeResult(.empty);
            return;
        };
        defer image.deinit(allocator);

        const encoded = clipboard_image.encodeImageContent(allocator, image) catch {
            self.storeResult(.failure);
            return;
        };
        self.storeResult(.{ .success = encoded });
    }

    fn storeResult(self: *ClipboardPasteTask, result: ClipboardPasteResult) void {
        self.result_mutex.lockUncancelable(self.io);
        defer self.result_mutex.unlock(self.io);
        freeClipboardPasteResult(&self.result);
        self.result = result;
    }
};

fn freeClipboardPasteResult(result: *ClipboardPasteResult) void {
    switch (result.*) {
        .success => |*image| clipboard_image.deinitImageContent(std.heap.page_allocator, image),
        else => {},
    }
    result.* = .none;
}

pub const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(ChatItem) = .empty,
    visible_start_index: usize = 0,
    last_streaming_assistant_index: ?usize = null,
    status: []u8 = &.{},
    provider_label: []u8 = &.{},
    provider_status: []u8 = &.{},
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
    pending_editor_images: std.ArrayList(PendingEditorImage) = .empty,
    retired_kitty_images: std.ArrayList(u32) = .empty,
    active_tool_updates: std.ArrayList(ActiveToolUpdate) = .empty,
    tool_output_expanded: bool = false,
    clipboard_paste: ClipboardPasteTask,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !AppState {
        var state = AppState{
            .allocator = allocator,
            .io = io,
            .clipboard_paste = .{ .io = io },
        };
        errdefer state.deinit();
        state.status = try allocator.dupe(u8, "idle");
        state.provider_label = try allocator.dupe(u8, "unknown");
        state.provider_status = try allocator.dupe(u8, "needs auth");
        state.model_label = try allocator.dupe(u8, "unknown");
        state.session_label = try allocator.dupe(u8, "new");
        state.git_branch = try allocator.dupe(u8, "");
        try state.appendItemLocked(.welcome, "Welcome to pi (Zig interactive mode). Type a prompt and press Enter.");
        return state;
    }

    pub fn deinit(self: *AppState) void {
        self.clearPendingEditorImagesLocked();
        self.pending_editor_images.deinit(self.allocator);
        self.retired_kitty_images.deinit(self.allocator);
        self.clearActiveToolUpdatesLocked();
        self.active_tool_updates.deinit(self.allocator);
        self.clipboard_paste.deinit();
        self.clearQueuedMessagesLocked();
        self.queued_steering.deinit(self.allocator);
        self.queued_follow_up.deinit(self.allocator);
        for (self.items.items) |item| self.allocator.free(item.text);
        self.items.deinit(self.allocator);
        self.allocator.free(self.status);
        self.allocator.free(self.provider_label);
        self.allocator.free(self.provider_status);
        self.allocator.free(self.model_label);
        self.allocator.free(self.session_label);
        self.allocator.free(self.git_branch);
        self.* = undefined;
    }

    pub fn appendPendingEditorImage(self: *AppState, image: ai.ImageContent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.pending_editor_images.append(self.allocator, .{
            .data = image.data,
            .mime_type = image.mime_type,
        });
    }

    pub fn clearPendingEditorImages(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearPendingEditorImagesLocked();
    }

    pub fn startClipboardPaste(self: *AppState, env_map: *const std.process.Environ.Map) !void {
        if (!(try self.clipboard_paste.start(env_map))) {
            try self.setStatus("clipboard image paste already in progress");
            return;
        }
        try self.setStatus("pasting clipboard image...");
    }

    pub fn pollClipboardPaste(self: *AppState, terminal_image_context: ?TerminalImageContext) !void {
        const result = self.clipboard_paste.poll() orelse return;

        switch (result) {
            .success => |image| {
                defer {
                    var owned = image;
                    clipboard_image.deinitImageContent(std.heap.page_allocator, &owned);
                }

                var pending = PendingEditorImage{
                    .data = try self.allocator.dupe(u8, image.data),
                    .mime_type = try self.allocator.dupe(u8, image.mime_type),
                    .kitty_image = try self.transmitKittyImage(image, terminal_image_context),
                };
                var appended = false;
                errdefer if (!appended) self.deinitPendingEditorImage(&pending);

                {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    try self.pending_editor_images.append(self.allocator, pending);
                    appended = true;
                }
                try self.setStatus("clipboard image pasted");
            },
            .empty => try self.setStatus("clipboard does not contain an image"),
            .failure => try self.setStatus("clipboard image paste failed"),
            .none => {},
        }
    }

    pub fn clipboardPasteInProgress(self: *const AppState) bool {
        return self.clipboard_paste.isActive();
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

    pub fn flushRetiredTerminalImages(self: *AppState, terminal_image_context: TerminalImageContext) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.flushRetiredTerminalImagesLocked(terminal_image_context);
    }

    pub fn freeActiveTerminalImages(self: *AppState, terminal_image_context: TerminalImageContext) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.flushRetiredTerminalImagesLocked(terminal_image_context);
        for (self.pending_editor_images.items) |*image| {
            if (image.kitty_image) |kitty| {
                terminal_image_context.vx.freeImage(terminal_image_context.tty, kitty.id);
                image.kitty_image = null;
            }
        }
    }

    pub fn snapshotForRender(self: *const AppState, allocator: std.mem.Allocator) !RenderStateSnapshot {
        @constCast(&self.mutex).lockUncancelable(self.io);
        defer @constCast(&self.mutex).unlock(self.io);

        var snapshot = RenderStateSnapshot{
            .usage_totals = self.usage_totals,
            .context_window = self.context_window,
            .context_percent = self.context_percent,
        };
        errdefer snapshot.deinit(allocator);

        snapshot.status = try allocator.dupe(u8, self.status);
        snapshot.provider_label = try allocator.dupe(u8, self.provider_label);
        snapshot.provider_status = try allocator.dupe(u8, self.provider_status);
        snapshot.model_label = try allocator.dupe(u8, self.model_label);
        snapshot.session_label = try allocator.dupe(u8, self.session_label);
        snapshot.git_branch = try allocator.dupe(u8, self.git_branch);

        const start_index = @min(self.visible_start_index, self.items.items.len);
        snapshot.items = try cloneChatItems(allocator, self.items.items[start_index..]);
        snapshot.queued_steering = try cloneOwnedStringList(allocator, self.queued_steering.items);
        snapshot.queued_follow_up = try cloneOwnedStringList(allocator, self.queued_follow_up.items);
        snapshot.pending_editor_images = try cloneImageContentsForRender(allocator, self.pending_editor_images.items);
        return snapshot;
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

    pub fn setToolOutputExpanded(self: *AppState, expanded: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.tool_output_expanded = expanded;
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
        provider_label: []const u8,
        provider_status: []const u8,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.replaceLabelLocked(&self.provider_label, provider_label);
        try self.replaceLabelLocked(&self.provider_status, provider_status);
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
                    const rendered = try formatting.formatToolResultWithExpansion(
                        self.allocator,
                        tool_result.tool_name,
                        tool_result.content,
                        tool_result.is_error,
                        tool_result.details,
                        self.tool_output_expanded,
                    );
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
                        const rendered = try formatting.formatToolResultWithExpansion(
                            self.allocator,
                            tool_name,
                            partial_result.content,
                            false,
                            partial_result.details,
                            self.tool_output_expanded,
                        );
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
                const rendered = try formatting.formatToolResultWithExpansion(
                    self.allocator,
                    tool_name,
                    result.content,
                    event.is_error orelse false,
                    result.details,
                    self.tool_output_expanded,
                );
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
        for (self.pending_editor_images.items) |*image| {
            self.retirePendingEditorImageLocked(image);
            self.deinitPendingEditorImage(image);
        }
        self.pending_editor_images.clearRetainingCapacity();
    }

    fn deinitPendingEditorImage(self: *AppState, image: *PendingEditorImage) void {
        self.allocator.free(image.data);
        self.allocator.free(image.mime_type);
        image.* = undefined;
    }

    fn retirePendingEditorImageLocked(self: *AppState, image: *PendingEditorImage) void {
        if (image.kitty_image) |kitty| {
            self.retired_kitty_images.append(self.allocator, kitty.id) catch {};
            image.kitty_image = null;
        }
    }

    fn flushRetiredTerminalImagesLocked(self: *AppState, terminal_image_context: TerminalImageContext) void {
        for (self.retired_kitty_images.items) |id| {
            terminal_image_context.vx.freeImage(terminal_image_context.tty, id);
        }
        self.retired_kitty_images.clearRetainingCapacity();
    }

    fn transmitKittyImage(
        self: *AppState,
        image: ai.ImageContent,
        terminal_image_context: ?TerminalImageContext,
    ) !?tui.components.image.KittyImage {
        const context = terminal_image_context orelse return null;
        if (!context.vx.caps.kitty_graphics) return null;

        const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(image.data) catch return null;
        const decoded = try self.allocator.alloc(u8, decoded_len);
        defer self.allocator.free(decoded);
        std.base64.standard.Decoder.decode(decoded, image.data) catch return null;

        const transmitted = context.vx.loadImage(self.allocator, context.tty, .{ .mem = decoded }) catch return null;
        return tui.components.image.KittyImage.fromVaxisImage(transmitted);
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
    after_snapshot_hook: ?RenderHook = null,

    pub fn component(self: *const ScreenComponent) tui.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn drawComponent(self: *const ScreenComponent) tui.DrawComponent {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
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

        var snapshot = try self.state.snapshotForRender(allocator);
        defer snapshot.deinit(allocator);

        if (self.after_snapshot_hook) |hook| hook.run();

        for (snapshot.items) |item| {
            try renderChatItemInto(allocator, @max(width, 1), self.theme, item, &chat_lines);
        }

        var prompt_lines = tui.LineList.empty;
        defer freeLinesSafe(allocator, &prompt_lines);
        try renderPromptLines(allocator, self.theme, self.editor, snapshot.pending_editor_images, width, &prompt_lines);
        var queued_lines = tui.LineList.empty;
        defer freeLinesSafe(allocator, &queued_lines);
        try renderQueuedMessageLines(allocator, self.keybindings, self.theme, &snapshot, width, &queued_lines);
        const footer_line = try formatFooterLine(allocator, self.theme, &snapshot, width);
        defer allocator.free(footer_line);
        const hints_line = try formatHintsLine(allocator, self.keybindings, self.theme, width);
        defer allocator.free(hints_line);

        var autocomplete_lines = tui.LineList.empty;
        defer freeLinesSafe(allocator, &autocomplete_lines);
        try self.editor.renderAutocompleteInto(allocator, width, &autocomplete_lines);

        const reserved_lines: usize = prompt_lines.items.len + queued_lines.items.len + 2 + autocomplete_lines.items.len;
        const chat_capacity = if (self.height > reserved_lines) self.height - reserved_lines else 1;
        const chat_component = BorrowedLineListComponent{ .lines = chat_lines.items };
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

    pub fn drawOpaque(
        ptr: *const anyopaque,
        window: tui.vaxis.Window,
        ctx: tui.DrawContext,
    ) std.mem.Allocator.Error!tui.DrawSize {
        const self: *const ScreenComponent = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }

    pub fn draw(
        self: *const ScreenComponent,
        window: tui.vaxis.Window,
        ctx: tui.DrawContext,
    ) std.mem.Allocator.Error!tui.DrawSize {
        self.editor.setTheme(self.theme);
        window.clear();

        var snapshot = try self.state.snapshotForRender(ctx.arena);

        if (self.after_snapshot_hook) |hook| hook.run();

        const width = @max(@as(usize, window.width), 1);
        const footer_text = try formatFooterText(ctx.arena, &snapshot, width);
        const hints_text = try formatHintsText(ctx.arena, self.keybindings, width);
        const prompt_height = try measurePromptHeight(
            ctx.arena,
            self.theme,
            self.editor,
            snapshot.pending_editor_images,
            width,
        );
        const queued_height = try measureQueuedMessagesHeight(ctx.arena, self.keybindings, self.theme, &snapshot, width);
        const autocomplete_height = try measureAutocompleteHeight(ctx.arena, self.theme, self.editor, width);
        const reserved_lines: usize = prompt_height + queued_height + 2 + autocomplete_height;
        const window_height: usize = @max(@as(usize, window.height), 1);
        const chat_capacity = if (window_height > reserved_lines) window_height - reserved_lines else 1;

        var row: usize = 0;
        try drawChatViewport(ctx.arena, self.theme, snapshot.items, window, row, chat_capacity);
        row += chat_capacity;

        if (queued_height > 0 and row < window.height) {
            const queued_window = window.child(.{
                .y_off = @intCast(row),
                .height = @intCast(@min(queued_height, @as(usize, window.height) - row)),
            });
            _ = try drawQueuedMessages(queued_window, .{
                .window = queued_window,
                .arena = ctx.arena,
                .theme = self.theme,
            }, self.keybindings, self.theme, &snapshot);
        }
        row += queued_height;

        const prompt_start_row = row;
        if (row < window.height) {
            const prompt_window = window.child(.{
                .y_off = @intCast(row),
                .height = @intCast(@min(prompt_height, @as(usize, window.height) - row)),
            });
            _ = try drawPromptLines(
                prompt_window,
                .{ .window = prompt_window, .arena = ctx.arena, .theme = self.theme },
                self.theme,
                self.editor,
                snapshot.pending_editor_images,
            );
        }
        row += prompt_height;

        const prefix_width = @min(tui.ansi.visibleWidth(INPUT_PROMPT_PREFIX), @as(usize, window.width));
        const editor_window_width = @max(@as(usize, 1), if (window.width > prefix_width) window.width - @as(u16, @intCast(prefix_width)) else 1);
        const editor_image_rows = pendingImagesRenderHeight(snapshot.pending_editor_images, editor_window_width);
        const editor_rows = if (prompt_height > editor_image_rows) prompt_height - editor_image_rows else 1;
        const editor_window = window.child(.{
            .x_off = @intCast(prefix_width),
            .y_off = @intCast(prompt_start_row),
            .width = @intCast(editor_window_width),
            .height = @intCast(@max(editor_rows, 1)),
        });
        _ = try self.editor.draw(editor_window, .{
            .window = editor_window,
            .arena = ctx.arena,
            .theme = self.theme,
        });

        if (autocomplete_height > 0 and row < window.height) {
            const autocomplete_window = window.child(.{
                .x_off = @intCast(prefix_width),
                .y_off = @intCast(row),
                .width = @intCast(editor_window_width),
                .height = @intCast(@min(autocomplete_height, @as(usize, window.height) - row)),
            });
            _ = try self.editor.drawAutocomplete(autocomplete_window, .{
                .window = autocomplete_window,
                .arena = ctx.arena,
                .theme = self.theme,
            });
        }
        row += autocomplete_height;

        if (row < window.height) {
            drawFittedLine(window, row, footer_text, styleForToken(self.theme, .footer));
        }
        row += 1;
        if (row < window.height) {
            drawFittedLine(window, row, hints_text, styleForToken(self.theme, .status));
        }
        row += 1;

        return .{
            .width = window.width,
            .height = @intCast(@min(row, @as(usize, window.height))),
        };
    }
};

fn styleForToken(theme: ?*const resources_mod.Theme, token: resources_mod.ThemeToken) tui.vaxis.Cell.Style {
    return if (theme) |active_theme| tui.styleFor(active_theme, token) else .{};
}

fn drawFittedLine(
    window: tui.vaxis.Window,
    row: usize,
    text: []const u8,
    style: tui.vaxis.Cell.Style,
) void {
    if (row >= window.height) return;
    const line_window = window.child(.{
        .y_off = @intCast(row),
        .height = 1,
    });
    line_window.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = style,
    });
    _ = line_window.printSegment(.{
        .text = text,
        .style = style,
    }, .{ .wrap = .none });
}

fn drawWrappedText(
    window: tui.vaxis.Window,
    start_row: usize,
    text: []const u8,
    style: tui.vaxis.Cell.Style,
) usize {
    if (start_row >= window.height) return 0;
    const child = window.child(.{
        .y_off = @intCast(start_row),
        .height = window.height - @as(u16, @intCast(start_row)),
    });
    const result = child.printSegment(.{
        .text = text,
        .style = style,
    }, .{ .wrap = .grapheme });
    return renderedPrintHeight(result, text.len > 0, child.height);
}

fn renderedPrintHeight(result: tui.vaxis.Window.PrintResult, had_text: bool, max_height: u16) usize {
    if (!had_text) return 0;
    const height = @as(usize, result.row) + if (result.col > 0 or result.overflow) @as(usize, 1) else 0;
    return @min(@max(height, 1), @as(usize, max_height));
}

fn estimateWrappedRows(text: []const u8, width: usize) usize {
    const effective_width = @max(width, 1);
    if (text.len == 0) return 1;
    var rows: usize = 0;
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |line| {
        const line_width = tui.ansi.visibleWidth(line);
        rows += @max(@as(usize, 1), (line_width + effective_width - 1) / effective_width);
    }
    return rows;
}

fn measureEditorHeight(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    width: usize,
) !usize {
    const height_hint = @max(@as(usize, 1), estimateWrappedRows(editor.text(), width) + editor.padding_y * 2);
    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = @intCast(@min(height_hint, @as(usize, std.math.maxInt(u16)))),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const measure_window = tui.draw.rootWindow(&screen);
    measure_window.clear();
    const size = try editor.draw(measure_window, .{
        .window = measure_window,
        .arena = allocator,
        .theme = theme,
    });
    return @max(@as(usize, size.height), 1);
}

fn measurePromptHeight(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    pending_images: []const PendingEditorImage,
    width: usize,
) !usize {
    const prefix_width = @min(tui.ansi.visibleWidth(INPUT_PROMPT_PREFIX), width);
    const editor_width = @max(@as(usize, 1), width -| prefix_width);
    return try measureEditorHeight(allocator, theme, editor, editor_width) + pendingImagesRenderHeight(pending_images, editor_width);
}

fn drawPromptLines(
    window: tui.vaxis.Window,
    ctx: tui.DrawContext,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    pending_images: []const PendingEditorImage,
) !tui.DrawSize {
    const prompt_style = styleForToken(theme, .prompt);
    drawFittedLine(window, 0, INPUT_PROMPT_PREFIX, prompt_style);

    const prefix_width = @min(tui.ansi.visibleWidth(INPUT_PROMPT_PREFIX), @as(usize, window.width));
    const editor_width = @max(@as(usize, 1), @as(usize, window.width) -| prefix_width);
    const editor_height = try measureEditorHeight(ctx.arena, theme, editor, editor_width);
    if (prefix_width < window.width) {
        const editor_window = window.child(.{
            .x_off = @intCast(prefix_width),
            .y_off = 0,
            .width = @intCast(editor_width),
            .height = @intCast(@min(editor_height, @as(usize, window.height))),
        });
        _ = try editor.draw(editor_window, .{
            .window = editor_window,
            .arena = ctx.arena,
            .theme = theme,
        });
    }
    const blank_prefix = try ctx.arena.alloc(u8, prefix_width);
    @memset(blank_prefix, ' ');
    var image_row: usize = 0;
    for (pending_images, 0..) |image, index| {
        const row_count = pendingImageRenderHeight(image, editor_width);
        if (editor_height + image_row >= window.height) break;

        const continuation_window = window.child(.{
            .x_off = 0,
            .y_off = @intCast(editor_height + image_row),
            .height = @intCast(@min(row_count, @as(usize, window.height) -| (editor_height + image_row))),
        });

        if (image.kitty_image) |kitty| {
            const image_window = continuation_window.child(.{
                .x_off = @intCast(prefix_width),
                .width = @intCast(editor_width),
                .height = @intCast(@min(row_count, @as(usize, continuation_window.height))),
            });
            const image_component = tui.Image{
                .mime_type = image.mime_type,
                .kitty_image = kitty,
                .max_width_cells = editor_width,
                .max_height_cells = row_count,
            };
            _ = try image_component.drawComponent().draw(image_window, .{
                .window = image_window,
                .arena = ctx.arena,
                .theme = theme,
            });
        } else {
            const placeholder = try std.fmt.allocPrint(ctx.arena, "{s}[image {d}: {s}]", .{ blank_prefix, index + 1, image.mime_type });
            drawFittedLine(continuation_window, 0, placeholder, prompt_style);
        }

        image_row += row_count;
    }
    return .{
        .width = window.width,
        .height = @intCast(@min(editor_height + image_row, @as(usize, window.height))),
    };
}

fn pendingImagesRenderHeight(images: []const PendingEditorImage, width: usize) usize {
    var height: usize = 0;
    for (images) |image| height += pendingImageRenderHeight(image, width);
    return height;
}

fn pendingImageRenderHeight(image: PendingEditorImage, width: usize) usize {
    _ = width;
    return if (image.kitty_image != null) 4 else 1;
}

fn measureAutocompleteHeight(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    width: usize,
) !usize {
    if (!editor.isShowingAutocomplete()) return 0;
    const height_hint = @max(@as(usize, 1), editor.autocomplete_max_visible);
    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = @intCast(height_hint),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const measure_window = tui.draw.rootWindow(&screen);
    measure_window.clear();
    const size = try editor.drawAutocomplete(measure_window, .{
        .window = measure_window,
        .arena = allocator,
        .theme = theme,
    });
    return @as(usize, size.height);
}

fn measureQueuedMessagesHeight(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    width: usize,
) !usize {
    if (snapshot.queued_steering.len == 0 and snapshot.queued_follow_up.len == 0) return 0;
    const height_hint = @max(@as(usize, 4), queuedEstimateRows(snapshot, width));
    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = @intCast(@min(height_hint, @as(usize, std.math.maxInt(u16)))),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const measure_window = tui.draw.rootWindow(&screen);
    measure_window.clear();
    const size = try drawQueuedMessages(measure_window, .{
        .window = measure_window,
        .arena = allocator,
        .theme = theme,
    }, keybindings, theme, snapshot);
    return @as(usize, size.height);
}

fn queuedEstimateRows(snapshot: *const RenderStateSnapshot, width: usize) usize {
    var rows: usize = 2;
    for (snapshot.queued_steering) |queued| rows += estimateWrappedRows(queued, width) + 1;
    for (snapshot.queued_follow_up) |queued| rows += estimateWrappedRows(queued, width) + 1;
    return rows;
}

fn drawQueuedMessages(
    window: tui.vaxis.Window,
    ctx: tui.DrawContext,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
) !tui.DrawSize {
    if (snapshot.queued_steering.len == 0 and snapshot.queued_follow_up.len == 0) {
        return .{ .width = window.width, .height = 0 };
    }

    const status_style = styleForToken(theme, .status);
    var row: usize = 1;
    for (snapshot.queued_steering) |queued| {
        const line = try std.fmt.allocPrint(ctx.arena, "Steering: {s}", .{queued});
        row += drawWrappedText(window, row, line, status_style);
    }
    for (snapshot.queued_follow_up) |queued| {
        const line = try std.fmt.allocPrint(ctx.arena, "Follow-up: {s}", .{queued});
        row += drawWrappedText(window, row, line, status_style);
    }
    const dequeue_label = try actionLabel(ctx.arena, keybindings, .dequeue_messages, "Alt+Up");
    const hint = try std.fmt.allocPrint(ctx.arena, "↳ {s} to edit queued messages", .{dequeue_label});
    row += drawWrappedText(window, row, hint, status_style);
    return .{
        .width = window.width,
        .height = @intCast(@min(row, @as(usize, window.height))),
    };
}

fn drawChatViewport(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    items: []const ChatItem,
    window: tui.vaxis.Window,
    start_row: usize,
    height: usize,
) !void {
    if (start_row >= window.height or height == 0) return;

    const visible_height = @min(height, @as(usize, window.height) - start_row);
    const width = @max(@as(usize, window.width), 1);
    const scratch_height = @max(visible_height, estimateChatRows(items, width));
    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = @intCast(@min(scratch_height, @as(usize, std.math.maxInt(u16)))),
        .cols = window.width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const scratch_window = tui.draw.rootWindow(&screen);
    scratch_window.clear();
    const rendered = try drawChatItems(scratch_window, allocator, theme, items);
    const rendered_height = @min(@as(usize, rendered.height), @as(usize, screen.height));
    const src_start = rendered_height -| visible_height;
    const dst = window.child(.{
        .y_off = @intCast(start_row),
        .height = @intCast(visible_height),
    });
    blitScreenRows(&screen, dst, src_start, visible_height);
}

fn drawChatItems(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    items: []const ChatItem,
) !tui.DrawSize {
    var row: usize = 0;
    for (items) |item| {
        if (row >= window.height) break;
        row += try drawChatItem(window, allocator, theme, item, row);
    }
    return .{
        .width = window.width,
        .height = @intCast(@min(row, @as(usize, window.height))),
    };
}

fn drawChatItem(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    start_row: usize,
) !usize {
    const remaining_height = @as(usize, window.height) -| start_row;
    if (remaining_height == 0) return 0;
    const child = window.child(.{
        .y_off = @intCast(start_row),
        .height = @intCast(remaining_height),
    });
    switch (item.kind) {
        .assistant => {
            var row: usize = drawWrappedText(child, 0, ASSISTANT_PREFIX, styleForToken(theme, .assistant));
            if (std.mem.trim(u8, item.text, " \t\r\n").len == 0) return row;
            const markdown_window = child.child(.{
                .y_off = @intCast(row),
                .height = child.height - @as(u16, @intCast(row)),
            });
            const markdown = tui.Markdown{ .text = item.text, .theme = theme };
            const size = try markdown.draw(markdown_window, .{
                .window = markdown_window,
                .arena = allocator,
                .theme = theme,
            });
            row += @as(usize, size.height);
            return row;
        },
        .markdown => {
            const markdown = tui.Markdown{ .text = item.text, .theme = theme };
            const size = try markdown.draw(child, .{
                .window = child,
                .arena = allocator,
                .theme = theme,
            });
            return @as(usize, size.height);
        },
        else => return drawWrappedText(child, 0, item.text, styleForToken(theme, chatToken(item.kind))),
    }
}

fn chatToken(kind: ChatKind) resources_mod.ThemeToken {
    return switch (kind) {
        .welcome => .welcome,
        .info => .status,
        .@"error" => .@"error",
        .markdown => .markdown_text,
        .user => .user,
        .assistant => .assistant,
        .tool_call => .tool_call,
        .tool_result => .tool_result,
    };
}

fn estimateChatRows(items: []const ChatItem, width: usize) usize {
    var rows: usize = 1;
    for (items) |item| {
        rows += switch (item.kind) {
            .assistant => 1 + estimateWrappedRows(item.text, width) + 8,
            .markdown => estimateWrappedRows(item.text, width) + 8,
            else => estimateWrappedRows(item.text, width),
        };
    }
    return rows;
}

fn blitScreenRows(
    source: *tui.vaxis.Screen,
    dest: tui.vaxis.Window,
    source_start_row: usize,
    height: usize,
) void {
    const rows = @min(height, @as(usize, dest.height));
    const cols = @min(@as(usize, source.width), @as(usize, dest.width));
    for (0..rows) |row| {
        for (0..cols) |col| {
            const cell = source.readCell(@intCast(col), @intCast(source_start_row + row)) orelse continue;
            dest.writeCell(@intCast(col), @intCast(row), normalizeCellForBlit(cell));
        }
    }
}

fn normalizeCellForBlit(cell: tui.vaxis.Cell) tui.vaxis.Cell {
    if (cell.char.grapheme.len != 0) return cell;
    var normalized = cell;
    normalized.char = .{ .grapheme = " ", .width = 1 };
    return normalized;
}

const RenderHook = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque) void,

    pub fn run(self: RenderHook) void {
        self.callback(self.context);
    }
};

const BorrowedLineListComponent = struct {
    lines: []const []u8,

    pub fn component(self: *const BorrowedLineListComponent) tui.Component {
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
        const self: *const BorrowedLineListComponent = @ptrCast(@alignCast(ptr));
        for (self.lines) |line| {
            const fitted = try fitLine(allocator, line, width);
            defer allocator.free(fitted);
            try tui.component.appendOwnedLine(lines, allocator, fitted);
        }
    }
};

pub const BorrowedCellRow = struct {
    cells: []const tui.vaxis.Cell,
};

pub const BorrowedLinesComponent = struct {
    rows: []const BorrowedCellRow,

    pub fn drawComponent(self: *const BorrowedLinesComponent) tui.DrawComponent {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const BorrowedLinesComponent,
        window: tui.vaxis.Window,
        _: tui.DrawContext,
    ) std.mem.Allocator.Error!tui.DrawSize {
        window.clear();
        const row_count = @min(self.rows.len, @as(usize, window.height));
        for (self.rows[0..row_count], 0..) |row, row_index| {
            const col_count = @min(row.cells.len, @as(usize, window.width));
            for (row.cells[0..col_count], 0..) |cell, col| {
                window.writeCell(@intCast(col), @intCast(row_index), cell);
            }
        }
        return .{
            .width = window.width,
            .height = @intCast(row_count),
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: tui.vaxis.Window,
        ctx: tui.DrawContext,
    ) std.mem.Allocator.Error!tui.DrawSize {
        const self: *const BorrowedLinesComponent = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
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

    pub fn drawComponent(self: *const OverlayPanelComponent) tui.DrawComponent {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
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

    pub fn draw(
        self: *const OverlayPanelComponent,
        window: tui.vaxis.Window,
        ctx: tui.DrawContext,
    ) std.mem.Allocator.Error!tui.DrawSize {
        window.clear();
        const border_style = styleForToken(self.theme, .box_border);
        const bordered = if (window.width >= 2 and window.height >= 2)
            window.child(.{
                .border = .{
                    .where = .all,
                    .style = border_style,
                    .glyphs = .single_square,
                },
            })
        else
            window;
        bordered.clear();

        const content_window = bordered.child(.{
            .x_off = @intCast(@min(@as(usize, 2), @as(usize, bordered.width))),
            .y_off = @intCast(@min(@as(usize, 1), @as(usize, bordered.height))),
            .width = @intCast(@max(@as(usize, 1), @as(usize, bordered.width) -| 4)),
            .height = @intCast(@max(@as(usize, 1), @as(usize, bordered.height) -| 2)),
        });

        var row: usize = 0;
        drawFittedLine(content_window, row, self.overlay.title(), styleForToken(self.theme, .overlay_title));
        row += 2;
        drawFittedLine(content_window, row, self.overlay.hint(), styleForToken(self.theme, .overlay_hint));
        row += 2;

        switch (self.overlay.*) {
            .settings_editor => |*settings_editor| {
                settings_editor.editor.setTheme(self.theme);
                drawFittedLine(content_window, row, settings_editor.path, styleForToken(self.theme, .overlay_hint));
                row += 2;
                if (row < content_window.height) {
                    const editor_window = content_window.child(.{
                        .y_off = @intCast(row),
                        .height = content_window.height - @as(u16, @intCast(row)),
                    });
                    const size = try settings_editor.editor.draw(editor_window, .{
                        .window = editor_window,
                        .arena = ctx.arena,
                        .theme = self.theme,
                    });
                    row += @as(usize, size.height);
                }
            },
            else => {
                if (row < content_window.height) {
                    const overlay_list = switch (self.overlay.*) {
                        .info => |*info_overlay| &info_overlay.list,
                        .session => |*session_overlay| &session_overlay.list,
                        .model => |*model_overlay| &model_overlay.list,
                        .tree => |*tree_overlay| &tree_overlay.list,
                        .auth => |*auth_overlay| &auth_overlay.list,
                        else => unreachable,
                    };
                    overlay_list.theme = self.theme;
                    overlay_list.max_visible = @max(@as(usize, 1), @min(self.max_height, @as(usize, content_window.height) - row));
                    const list_window = content_window.child(.{
                        .y_off = @intCast(row),
                        .height = content_window.height - @as(u16, @intCast(row)),
                    });
                    const size = try overlay_list.draw(list_window, .{
                        .window = list_window,
                        .arena = ctx.arena,
                        .theme = self.theme,
                    });
                    row += @as(usize, size.height);
                }
            },
        }

        const chrome_height: usize = if (window.width >= 2 and window.height >= 2) 2 else 0;
        const total_height = @min(@as(usize, window.height), row + 2 + chrome_height);
        return .{
            .width = window.width,
            .height = @intCast(@max(@as(usize, 1), total_height)),
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: tui.vaxis.Window,
        ctx: tui.DrawContext,
    ) std.mem.Allocator.Error!tui.DrawSize {
        const self: *const OverlayPanelComponent = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
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
    current_provider: ?*const provider_config.ResolvedProviderConfig,
) !void {
    const git_branch = try resolveGitBranch(allocator, io, session.cwd);
    defer if (git_branch) |branch| allocator.free(branch);
    try app_state.rebuildFromSession(session, git_branch);
    if (current_provider) |resolved_provider| {
        try app_state.setFooterDetails(
            session.agent.getModel(),
            currentSessionLabel(session),
            git_branch,
            provider_config.providerDisplayName(resolved_provider.model.provider),
            provider_config.providerAuthStatusLabel(resolved_provider.auth_status),
        );
    }
}

pub fn updateAppFooterFromSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    app_state: *AppState,
    session: *const session_mod.AgentSession,
    current_provider: *const provider_config.ResolvedProviderConfig,
) !void {
    const git_branch = try resolveGitBranch(allocator, io, session.cwd);
    defer if (git_branch) |branch| allocator.free(branch);
    try app_state.setFooterDetails(
        session.agent.getModel(),
        currentSessionLabel(session),
        git_branch,
        provider_config.providerDisplayName(current_provider.model.provider),
        provider_config.providerAuthStatusLabel(current_provider.auth_status),
    );
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
    pending_images: []const PendingEditorImage,
    width: usize,
    lines: *tui.LineList,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch_allocator = arena.allocator();

    const height = try measurePromptHeight(scratch_allocator, theme, editor, pending_images, width);
    var screen = try tui.vaxis.Screen.init(scratch_allocator, .{
        .rows = @intCast(@max(height, 1)),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(scratch_allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    const rendered = try drawPromptLines(window, .{
        .window = window,
        .arena = scratch_allocator,
        .theme = theme,
    }, theme, editor, pending_images);
    try tui.vaxis_adapter.appendScreenRowsAsAnsiLines(allocator, &screen, width, rendered.height, lines);
}

pub fn formatFooterLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    width: usize,
) ![]u8 {
    const fitted = try formatFooterText(allocator, snapshot, width);
    defer allocator.free(fitted);
    return try applyThemeAlloc(allocator, theme, .footer, fitted);
}

pub fn formatFooterText(
    allocator: std.mem.Allocator,
    snapshot: *const RenderStateSnapshot,
    width: usize,
) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    var needs_separator = false;
    if (snapshot.git_branch) |git_branch| {
        if (git_branch.len > 0) {
            const branch_text = try std.fmt.allocPrint(allocator, "Branch: {s}", .{git_branch});
            defer allocator.free(branch_text);
            try appendFooterPart(allocator, &builder, &needs_separator, branch_text);
        }
    }
    const compact_session_label = try truncateVisibleTextAlloc(allocator, snapshot.session_label.?, 16);
    defer allocator.free(compact_session_label);
    const session_text = try std.fmt.allocPrint(allocator, "Session: {s}", .{compact_session_label});
    defer allocator.free(session_text);
    try appendFooterPart(allocator, &builder, &needs_separator, session_text);
    const single_line_status = try sanitizeSingleLineStatusAlloc(allocator, snapshot.status.?);
    defer allocator.free(single_line_status);
    const status_text = try std.fmt.allocPrint(allocator, "Status: {s}", .{single_line_status});
    defer allocator.free(status_text);
    try appendFooterPart(allocator, &builder, &needs_separator, status_text);
    if (snapshot.provider_label) |provider_label| {
        if (provider_label.len > 0 and !std.mem.eql(u8, provider_label, "unknown")) {
            const provider_text = try std.fmt.allocPrint(
                allocator,
                "Provider: {s} ({s})",
                .{ provider_label, snapshot.provider_status.? },
            );
            defer allocator.free(provider_text);
            try appendFooterPart(allocator, &builder, &needs_separator, provider_text);
        }
    }

    if (snapshot.queued_steering.len > 0 or snapshot.queued_follow_up.len > 0) {
        const queue_text = try formatQueueSummary(allocator, snapshot.queued_steering.len, snapshot.queued_follow_up.len);
        defer allocator.free(queue_text);
        try appendFooterPart(allocator, &builder, &needs_separator, queue_text);
    }

    if (snapshot.usage_totals.input > 0) {
        const input_text = try formatCompactTokenCount(allocator, snapshot.usage_totals.input);
        defer allocator.free(input_text);
        const input_part = try std.fmt.allocPrint(allocator, "↑{s}", .{input_text});
        defer allocator.free(input_part);
        try appendFooterPart(allocator, &builder, &needs_separator, input_part);
    }
    if (snapshot.usage_totals.output > 0) {
        const output_text = try formatCompactTokenCount(allocator, snapshot.usage_totals.output);
        defer allocator.free(output_text);
        const output_part = try std.fmt.allocPrint(allocator, "↓{s}", .{output_text});
        defer allocator.free(output_part);
        try appendFooterPart(allocator, &builder, &needs_separator, output_part);
    }

    if (snapshot.usage_totals.cache_read > 0) {
        const cache_read_text = try formatCompactTokenCount(allocator, snapshot.usage_totals.cache_read);
        defer allocator.free(cache_read_text);
        const cache_read_part = try std.fmt.allocPrint(allocator, "R{s}", .{cache_read_text});
        defer allocator.free(cache_read_part);
        try appendFooterPart(allocator, &builder, &needs_separator, cache_read_part);
    }
    if (snapshot.usage_totals.cache_write > 0) {
        const cache_write_text = try formatCompactTokenCount(allocator, snapshot.usage_totals.cache_write);
        defer allocator.free(cache_write_text);
        const cache_write_part = try std.fmt.allocPrint(allocator, "W{s}", .{cache_write_text});
        defer allocator.free(cache_write_part);
        try appendFooterPart(allocator, &builder, &needs_separator, cache_write_part);
    }
    if (snapshot.usage_totals.cost > 0) {
        const cost_text = try std.fmt.allocPrint(allocator, "${d:.3}", .{snapshot.usage_totals.cost});
        defer allocator.free(cost_text);
        try appendFooterPart(allocator, &builder, &needs_separator, cost_text);
    }
    const has_usage_totals = snapshot.usage_totals.input > 0 or
        snapshot.usage_totals.output > 0 or
        snapshot.usage_totals.cache_read > 0 or
        snapshot.usage_totals.cache_write > 0 or
        snapshot.usage_totals.cost > 0;
    const show_context = snapshot.context_window > 0 and (has_usage_totals or snapshot.context_percent == null or snapshot.context_percent.? > 0.0);
    if (show_context) {
        const window_text = try formatCompactTokenCount(allocator, snapshot.context_window);
        defer allocator.free(window_text);
        const context_text = if (snapshot.context_percent) |percent|
            try std.fmt.allocPrint(allocator, "ctx {d:.1}%/{s}", .{ percent, window_text })
        else
            try std.fmt.allocPrint(allocator, "ctx ?/{s}", .{window_text});
        defer allocator.free(context_text);
        try appendFooterPart(allocator, &builder, &needs_separator, context_text);
    }

    const model_text = try std.fmt.allocPrint(allocator, "Model: {s}", .{snapshot.model_label.?});
    defer allocator.free(model_text);
    try appendFooterPart(allocator, &builder, &needs_separator, model_text);

    const fitted = try fitLine(allocator, builder.items, width);
    return fitted;
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

fn formatQueueSummary(allocator: std.mem.Allocator, steering_count: usize, follow_up_count: usize) ![]u8 {
    if (steering_count > 0 and follow_up_count > 0) {
        return std.fmt.allocPrint(
            allocator,
            "Queue: {d} steering, {d} follow-up",
            .{ steering_count, follow_up_count },
        );
    }
    if (steering_count > 0) {
        return std.fmt.allocPrint(allocator, "Queue: {d} steering", .{steering_count});
    }
    return std.fmt.allocPrint(allocator, "Queue: {d} follow-up", .{follow_up_count});
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
    const fitted = try formatHintsText(allocator, keybindings, width);
    defer allocator.free(fitted);
    return try applyThemeAlloc(allocator, theme, .status, fitted);
}

pub fn formatHintsText(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
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
    return fitted;
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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch_allocator = arena.allocator();

    const height_hint = @max(@as(usize, 1), estimateChatRows(&.{item}, width));
    var screen = try tui.vaxis.Screen.init(scratch_allocator, .{
        .rows = @intCast(@min(height_hint, @as(usize, std.math.maxInt(u16)))),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(scratch_allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    const rendered = try drawChatItem(window, scratch_allocator, theme, item, 0);
    try tui.vaxis_adapter.appendScreenRowsAsAnsiLines(allocator, &screen, width, rendered, lines);
}

pub fn renderAssistantChatItemInto(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    text: []const u8,
    lines: *tui.LineList,
) !void {
    try renderChatItemInto(allocator, width, theme, .{ .kind = .assistant, .text = @constCast(text) }, lines);
}

pub fn renderMarkdownChatItemInto(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    text: []const u8,
    lines: *tui.LineList,
) !void {
    try renderChatItemInto(allocator, width, theme, .{ .kind = .markdown, .text = @constCast(text) }, lines);
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
    snapshot: *const RenderStateSnapshot,
    width: usize,
    lines: *tui.LineList,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch_allocator = arena.allocator();

    const height = try measureQueuedMessagesHeight(scratch_allocator, keybindings, theme, snapshot, width);
    if (height == 0) return;

    var screen = try tui.vaxis.Screen.init(scratch_allocator, .{
        .rows = @intCast(height),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(scratch_allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    const rendered = try drawQueuedMessages(window, .{
        .window = window,
        .arena = scratch_allocator,
        .theme = theme,
    }, keybindings, theme, snapshot);
    try tui.vaxis_adapter.appendScreenRowsAsAnsiLines(allocator, &screen, width, rendered.height, lines);
}

fn cloneChatItems(allocator: std.mem.Allocator, items: []const ChatItem) ![]ChatItem {
    if (items.len == 0) return &.{};

    const cloned = try allocator.alloc(ChatItem, items.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |item| allocator.free(item.text);
        allocator.free(cloned);
    }

    for (items, 0..) |item, index| {
        cloned[index] = .{
            .kind = item.kind,
            .text = try allocator.dupe(u8, item.text),
        };
        initialized += 1;
    }
    return cloned;
}

fn sanitizeSingleLineStatusAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var previous_was_space = false;
    for (text) |char| {
        const is_whitespace = char == '\n' or char == '\r' or char == '\t';
        if (is_whitespace) {
            if (!previous_was_space) {
                try builder.append(allocator, ' ');
                previous_was_space = true;
            }
            continue;
        }
        try builder.append(allocator, char);
        previous_was_space = char == ' ';
    }

    if (builder.items.len > 0 and builder.items[builder.items.len - 1] == ' ') {
        _ = builder.pop();
    }
    return builder.toOwnedSlice(allocator);
}

fn truncateVisibleTextAlloc(allocator: std.mem.Allocator, text: []const u8, max_width: usize) ![]u8 {
    if (max_width == 0) return allocator.dupe(u8, "");
    if (tui.ansi.visibleWidth(text) <= max_width) return allocator.dupe(u8, text);

    const limit = if (max_width > 1) max_width - 1 else 0;
    const prefix = try tui.ansi.sliceVisibleAlloc(allocator, text, 0, limit);
    defer allocator.free(prefix);

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    try builder.appendSlice(allocator, prefix);
    if (max_width > 0) try builder.append(allocator, '.');
    return builder.toOwnedSlice(allocator);
}

fn cloneOwnedStringList(allocator: std.mem.Allocator, items: []const []u8) ![][]u8 {
    if (items.len == 0) return &.{};

    const cloned = try allocator.alloc([]u8, items.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |item| allocator.free(item);
        allocator.free(cloned);
    }

    for (items, 0..) |item, index| {
        cloned[index] = try allocator.dupe(u8, item);
        initialized += 1;
    }
    return cloned;
}

fn deinitOwnedStringList(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |item| allocator.free(item);
    if (items.len > 0) allocator.free(items);
}

fn cloneImageContentsForRender(allocator: std.mem.Allocator, images: []const PendingEditorImage) ![]PendingEditorImage {
    if (images.len == 0) return &.{};

    const cloned = try allocator.alloc(PendingEditorImage, images.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        allocator.free(cloned);
    }

    for (images, 0..) |image, index| {
        cloned[index] = .{
            .data = try allocator.dupe(u8, image.data),
            .mime_type = try allocator.dupe(u8, image.mime_type),
            .kitty_image = image.kitty_image,
        };
        initialized += 1;
    }
    return cloned;
}

fn deinitImageContentsForRender(allocator: std.mem.Allocator, images: []const PendingEditorImage) void {
    for (images) |image| {
        allocator.free(image.data);
        allocator.free(image.mime_type);
    }
    if (images.len > 0) allocator.free(images);
}

test "drawPromptLines places Kitty image cells for transmitted pending images" {
    const allocator = std.testing.allocator;

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 8,
        .cols = 40,
        .x_pixel = 320,
        .y_pixel = 128,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const pending = [_]PendingEditorImage{.{
        .data = "AQID",
        .mime_type = "image/png",
        .kitty_image = .{
            .id = 77,
            .width_px = 64,
            .height_px = 32,
        },
    }};

    _ = try drawPromptLines(window, .{
        .window = window,
        .arena = arena.allocator(),
    }, null, &editor, &pending);

    const image_col: u16 = @intCast(tui.ansi.visibleWidth(INPUT_PROMPT_PREFIX));
    const image_cell = screen.readCell(image_col, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(image_cell.image != null);
    try std.testing.expectEqual(@as(u32, 77), image_cell.image.?.img_id);
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

test "screen rendering releases app state lock before expensive rendering work" {
    const allocator = std.heap.page_allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setStatus("snapshot status");
    try state.appendInfo("streaming output");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("rendered prompt");

    const HookContext = struct {
        snapshot_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        release_render: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        setter_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn afterSnapshot(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.snapshot_ready.store(true, .seq_cst);
            while (!self.release_render.load(.seq_cst)) {
                std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
            }
        }
    };

    const RenderThreadContext = struct {
        allocator: std.mem.Allocator,
        screen: *const ScreenComponent,
        lines: tui.LineList = tui.LineList.empty,
        render_error: ?std.mem.Allocator.Error = null,

        fn run(self: *@This()) void {
            self.screen.renderInto(self.allocator, 120, &self.lines) catch |err| {
                self.render_error = err;
            };
        }
    };

    const SetterThreadContext = struct {
        state: *AppState,
        finished: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            self.state.setStatus("updated while rendering") catch return;
            self.finished.store(true, .seq_cst);
        }
    };

    var hook_context = HookContext{};
    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 10,
        .after_snapshot_hook = .{
            .context = &hook_context,
            .callback = HookContext.afterSnapshot,
        },
    };

    var render_context = RenderThreadContext{
        .allocator = allocator,
        .screen = &screen,
    };
    const render_thread = try std.Thread.spawn(.{}, RenderThreadContext.run, .{&render_context});

    var snapshot_ready = false;
    for (0..100) |_| {
        if (hook_context.snapshot_ready.load(.seq_cst)) {
            snapshot_ready = true;
            break;
        }
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(snapshot_ready);

    var setter_context = SetterThreadContext{
        .state = &state,
        .finished = &hook_context.setter_finished,
    };
    const setter_thread = try std.Thread.spawn(.{}, SetterThreadContext.run, .{&setter_context});

    var setter_finished_before_release = false;
    for (0..100) |_| {
        if (hook_context.setter_finished.load(.seq_cst)) {
            setter_finished_before_release = true;
            break;
        }
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }

    hook_context.release_render.store(true, .seq_cst);
    render_thread.join();
    setter_thread.join();

    try std.testing.expect(setter_finished_before_release);
    try std.testing.expectEqual(@as(?std.mem.Allocator.Error, null), render_context.render_error);
    defer freeLinesSafe(allocator, &render_context.lines);
    try std.testing.expect(renderedLinesContain(render_context.lines.items, "Status: snapshot status"));
    try std.testing.expect(!renderedLinesContain(render_context.lines.items, "updated while rendering"));
}

test "formatFooterLine shows provider auth status and sanitizes multiline status text" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("openai", "gpt-5.4").?;
    try state.setFooterDetails(model, "session.jsonl", "zig-implementation", "OpenAI", "env");
    try state.setStatus("missing key\nset OPENAI_API_KEY");

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);

    const footer = try formatFooterLine(allocator, null, &snapshot, 240);
    defer allocator.free(footer);

    try std.testing.expect(std.mem.indexOf(u8, footer, "Provider: OpenAI (env)") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Status: missing key set OPENAI_API_KEY") != null);
}

test "screen draw stacks autocomplete below the prompt editor child window" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    try editor.setAutocompleteItems(&[_]tui.SelectItem{
        .{ .value = "read", .label = "read" },
        .{ .value = "reload", .label = "reload" },
        .{ .value = "render", .label = "render" },
    });

    _ = try editor.handleKey(.{ .printable = tui.keys.PrintableKey.fromSlice("r") });
    _ = try editor.handleKey(.{ .printable = tui.keys.PrintableKey.fromSlice("e") });

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
    };

    var screen = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 20, 8);
    defer screen.deinit(std.testing.allocator);

    try tui.test_helpers.expectCell(&screen, 0, 2, "I", .{});

    const prefix_width = tui.ansi.visibleWidth(INPUT_PROMPT_PREFIX);
    const selected = screen.readCell(@intCast(prefix_width + 2), 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("r", selected.char.grapheme);
    try std.testing.expect(selected.style.reverse);
}

test "borrowed lines component draws stored cell rows without ansi strings" {
    const selected_style = tui.vaxis.Cell.Style{ .reverse = true };
    const first_row = [_]tui.vaxis.Cell{
        .{ .char = .{ .grapheme = "A", .width = 1 }, .style = selected_style },
        .{ .char = .{ .grapheme = "B", .width = 1 } },
    };
    const second_row = [_]tui.vaxis.Cell{
        .{ .char = .{ .grapheme = "C", .width = 1 } },
    };
    const borrowed = BorrowedLinesComponent{
        .rows = &[_]BorrowedCellRow{
            .{ .cells = &first_row },
            .{ .cells = &second_row },
        },
    };

    var screen = try tui.test_helpers.renderToScreen(borrowed.drawComponent(), 3, 2);
    defer screen.deinit(std.testing.allocator);

    try tui.test_helpers.expectCell(&screen, 0, 0, "A", selected_style);
    try tui.test_helpers.expectCell(&screen, 1, 0, "B", .{});
    try tui.test_helpers.expectCell(&screen, 0, 1, "C", .{});
}
