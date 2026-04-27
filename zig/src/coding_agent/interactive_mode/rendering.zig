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
const formatStreamingToolCall = formatting.formatStreamingToolCall;
const WHEEL_LINES_PER_NOTCH: usize = 3;

pub const ChatKind = enum {
    welcome,
    info,
    @"error",
    markdown,
    user,
    assistant,
    thinking,
    tool_call,
    tool_result,
};

pub const ChatItem = struct {
    kind: ChatKind,
    text: []u8,
    start_ms: ?i64 = null,
    frozen_frame_index: ?usize = null,
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

pub const ChatRegion = struct {
    row_start: usize = 0,
    row_end: usize = 0,
    col_start: usize = 0,
    col_end: usize = 0,

    pub fn contains(self: ChatRegion, row: i16, col: i16) bool {
        if (row < 0 or col < 0) return false;
        const row_index: usize = @intCast(row);
        const col_index: usize = @intCast(col);
        return row_index >= self.row_start and
            row_index < self.row_end and
            col_index >= self.col_start and
            col_index < self.col_end;
    }
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
    chat_scroll_offset: usize = 0,
    all_expanded: bool = false,

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

const StreamingToolCall = struct {
    content_index: ?u32,
    tool_call_id: ?[]u8 = null,
    item_index: usize,
};

const ClockNowMsFn = *const fn (?*anyopaque) i64;

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
    chat_scroll_offset: usize = 0,
    chat_scroll_max_offset: usize = 0,
    chat_visible_rows: usize = 0,
    chat_width: usize = 1,
    chat_region: ChatRegion = .{},
    all_expanded: bool = false,
    last_streaming_assistant_index: ?usize = null,
    last_streaming_thinking_index: ?usize = null,
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
    streaming_tool_calls: std.ArrayList(StreamingToolCall) = .empty,
    tool_output_expanded: bool = false,
    clipboard_paste: ClipboardPasteTask,
    clock_context: ?*anyopaque = null,
    clock_now_ms_fn: ClockNowMsFn = systemNowMilliseconds,

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
        self.clearStreamingToolCallsLocked();
        self.streaming_tool_calls.deinit(self.allocator);
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

    pub fn setClockForTesting(self: *AppState, context: ?*anyopaque, now_ms_fn: ClockNowMsFn) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clock_context = context;
        self.clock_now_ms_fn = now_ms_fn;
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
            .chat_scroll_offset = self.chat_scroll_offset,
            .all_expanded = self.all_expanded,
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
        self.chat_scroll_offset = 0;
        self.replaceLabelLocked(&self.status, "display cleared") catch {};
    }

    pub fn handleChatMouseWheel(self: *AppState, wheel: tui.keys.MouseWheelInput) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.chat_region.contains(wheel.row, wheel.col)) return;
        switch (wheel.direction) {
            .up => self.chat_scroll_offset = @min(
                self.chat_scroll_offset +| WHEEL_LINES_PER_NOTCH,
                self.chat_scroll_max_offset,
            ),
            .down => self.chat_scroll_offset = self.chat_scroll_offset -| WHEEL_LINES_PER_NOTCH,
        }
    }

    pub fn chatScrollToTail(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.chat_scroll_offset = 0;
    }

    pub fn chatScrollClamp(self: *AppState, max_offset: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.chat_scroll_offset = @min(self.chat_scroll_offset, max_offset);
        self.chat_scroll_max_offset = max_offset;
    }

    pub fn toggleAllExpanded(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const was_at_tail = self.chat_scroll_offset == 0;
        self.all_expanded = !self.all_expanded;
        const start_index = @min(self.visible_start_index, self.items.items.len);
        const total_rows = estimateChatRows(self.items.items[start_index..], @max(self.chat_width, 1), self.all_expanded);
        const max_offset = total_rows -| self.chat_visible_rows;
        self.chat_scroll_max_offset = max_offset;
        self.chat_scroll_offset = if (was_at_tail) 0 else @min(self.chat_scroll_offset, max_offset);
    }

    pub fn updateChatScrollLayout(
        self: *AppState,
        total_chat_rows: usize,
        visible_rows: usize,
        row_start: usize,
        width: usize,
    ) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const max_offset = total_chat_rows -| visible_rows;
        self.chat_scroll_max_offset = max_offset;
        self.chat_scroll_offset = @min(self.chat_scroll_offset, max_offset);
        self.chat_visible_rows = visible_rows;
        self.chat_width = @max(width, 1);
        self.chat_region = .{
            .row_start = row_start,
            .row_end = row_start + visible_rows,
            .col_start = 0,
            .col_end = width,
        };
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
        self.chat_scroll_offset = 0;
        self.chat_scroll_max_offset = 0;
        self.chat_visible_rows = 0;
        self.chat_width = 1;
        self.chat_region = .{};
        self.last_streaming_assistant_index = null;
        self.last_streaming_thinking_index = null;
        self.clearPendingEditorImagesLocked();
        self.clearActiveToolUpdatesLocked();
        self.clearStreamingToolCallsLocked();
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
                    try self.appendThinkingBlocksLocked(assistant_message.content);
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
                        self.updateContextUsageLocked(assistantContextTokens(assistant_message.usage));
                        try self.replaceLabelLocked(&self.status, "thinking");
                    },
                    else => {},
                };
            },
            .message_update => {
                var handled_thinking_event = false;
                var handled_toolcall_event = false;
                if (event.assistant_message_event) |assistant_event| {
                    switch (assistant_event.event_type) {
                        .thinking_start => {
                            handled_thinking_event = true;
                            try self.replaceLabelLocked(&self.status, "thinking");
                            try self.ensureThinkingItemLocked();
                        },
                        .thinking_delta => {
                            handled_thinking_event = true;
                            try self.replaceLabelLocked(&self.status, "thinking");
                            try self.appendThinkingDeltaLocked(assistant_event.delta orelse assistant_event.content orelse "");
                        },
                        .thinking_end => {
                            handled_thinking_event = true;
                            try self.replaceLabelLocked(&self.status, "thinking");
                            self.freezeStreamingThinkingItemLocked();
                            self.last_streaming_thinking_index = null;
                        },
                        .text_start, .text_delta, .text_end => try self.replaceLabelLocked(&self.status, "streaming"),
                        .toolcall_start => {
                            handled_toolcall_event = true;
                            try self.replaceLabelLocked(&self.status, "streaming");
                            _ = try self.ensureStreamingToolCallItemLocked(
                                assistant_event.content_index,
                                assistant_event.tool_call,
                            );
                        },
                        .toolcall_delta => {
                            handled_toolcall_event = true;
                            try self.replaceLabelLocked(&self.status, "streaming");
                            try self.appendStreamingToolCallDeltaLocked(
                                assistant_event.content_index,
                                assistant_event.tool_call,
                                assistant_event.delta orelse "",
                            );
                        },
                        .toolcall_end => {
                            handled_toolcall_event = true;
                            try self.replaceLabelLocked(&self.status, "streaming");
                            try self.finishStreamingToolCallLocked(
                                assistant_event.content_index,
                                assistant_event.tool_call,
                            );
                        },
                        else => {},
                    }
                }
                if (handled_thinking_event) return;
                if (handled_toolcall_event) return;
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
                        self.freezeStreamingThinkingItemLocked();
                        self.last_streaming_thinking_index = null;

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
                if (event.tool_call_id) |tool_call_id| {
                    if (self.streamingToolCallItemIndexByIdLocked(tool_call_id) != null) {
                        const status_text = try std.fmt.allocPrint(self.allocator, "working: {s}", .{tool_name});
                        defer self.allocator.free(status_text);
                        try self.replaceLabelLocked(&self.status, status_text);
                        return;
                    }
                }
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

    fn appendThinkingBlocksLocked(self: *AppState, blocks: []const ai.ContentBlock) !void {
        for (blocks) |block| switch (block) {
            .thinking => |thinking| if (thinking.thinking.len > 0) {
                try self.appendItemLocked(.thinking, thinking.thinking);
            },
            else => {},
        };
    }

    pub fn ensureThinkingItemLocked(self: *AppState) !void {
        self.removeAssistantThinkingItemLocked();
        if (self.last_streaming_thinking_index) |index| {
            if (index < self.items.items.len and self.items.items[index].kind == .thinking) return;
        }

        try self.appendStreamingThinkingItemLocked("");
        self.last_streaming_thinking_index = self.items.items.len - 1;
    }

    fn freezeStreamingThinkingItemLocked(self: *AppState) void {
        const index = self.last_streaming_thinking_index orelse return;
        if (index >= self.items.items.len or self.items.items[index].kind != .thinking) return;
        if (self.items.items[index].frozen_frame_index != null) return;
        self.items.items[index].frozen_frame_index = thinkingFrameIndex(self.items.items[index], self.currentNowMsLocked());
    }

    pub fn appendThinkingDeltaLocked(self: *AppState, delta: []const u8) !void {
        if (delta.len == 0) {
            try self.ensureThinkingItemLocked();
            return;
        }
        try self.ensureThinkingItemLocked();
        const index = self.last_streaming_thinking_index orelse return;
        try self.appendToItemTextLocked(index, delta);
    }

    fn ensureStreamingToolCallItemLocked(
        self: *AppState,
        content_index: ?u32,
        tool_call: ?ai.ToolCall,
    ) !usize {
        if (tool_call) |call| {
            if (self.streamingToolCallItemIndexByIdLocked(call.id)) |index| return index;
        }
        if (content_index) |index_value| {
            if (self.streamingToolCallItemIndexByContentIndexLocked(index_value)) |index| return index;
        }

        const initial_text = if (tool_call) |call|
            try formatToolCall(self.allocator, call.name, call.arguments)
        else
            try formatStreamingToolCall(self.allocator, null, "");
        defer self.allocator.free(initial_text);

        try self.appendItemLocked(.tool_call, initial_text);
        const item_index = self.items.items.len - 1;
        try self.streaming_tool_calls.append(self.allocator, .{
            .content_index = content_index,
            .tool_call_id = if (tool_call) |call| try self.allocator.dupe(u8, call.id) else null,
            .item_index = item_index,
        });
        return item_index;
    }

    fn appendStreamingToolCallDeltaLocked(
        self: *AppState,
        content_index: ?u32,
        tool_call: ?ai.ToolCall,
        delta: []const u8,
    ) !void {
        const index = try self.ensureStreamingToolCallItemLocked(content_index, tool_call);
        if (delta.len == 0) return;
        try self.appendToItemTextLocked(index, delta);
    }

    fn finishStreamingToolCallLocked(
        self: *AppState,
        content_index: ?u32,
        tool_call: ?ai.ToolCall,
    ) !void {
        const call = tool_call orelse return;
        const index = try self.ensureStreamingToolCallItemLocked(content_index, call);
        const rendered = try formatToolCall(self.allocator, call.name, call.arguments);
        defer self.allocator.free(rendered);
        try self.replaceItemTextLocked(index, rendered);
        try self.setStreamingToolCallIdLocked(content_index, call.id, index);
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
        self.last_streaming_assistant_index = null;
        if (self.findAssistantThinkingItemLocked()) |index| {
            self.removeItemLocked(index);
        }
    }

    fn findAssistantThinkingItemLocked(self: *const AppState) ?usize {
        if (self.last_streaming_assistant_index) |index| {
            if (index < self.items.items.len) {
                const item = self.items.items[index];
                if (item.kind == .assistant and std.mem.eql(u8, item.text, ASSISTANT_THINKING_TEXT)) return index;
            }
        }
        for (self.items.items, 0..) |item, index| {
            if (item.kind == .assistant and std.mem.eql(u8, item.text, ASSISTANT_THINKING_TEXT)) return index;
        }
        return null;
    }

    pub fn appendItemLocked(self: *AppState, kind: ChatKind, text: []const u8) !void {
        const frozen_frame_index: ?usize = if (kind == .thinking) 0 else null;
        try self.appendItemWithTimingLocked(kind, text, null, frozen_frame_index);
    }

    fn appendStreamingThinkingItemLocked(self: *AppState, text: []const u8) !void {
        try self.appendItemWithTimingLocked(.thinking, text, self.currentNowMsLocked(), null);
    }

    fn appendItemWithTimingLocked(
        self: *AppState,
        kind: ChatKind,
        text: []const u8,
        start_ms: ?i64,
        frozen_frame_index: ?usize,
    ) !void {
        const was_at_tail = self.chat_scroll_offset == 0;
        try self.items.append(self.allocator, .{
            .kind = kind,
            .text = try self.allocator.dupe(u8, text),
            .start_ms = start_ms,
            .frozen_frame_index = frozen_frame_index,
        });
        if (was_at_tail) self.chat_scroll_offset = 0;
    }

    fn currentNowMsLocked(self: *const AppState) i64 {
        return self.clock_now_ms_fn(self.clock_context);
    }

    pub fn appendToItemTextLocked(self: *AppState, index: usize, text: []const u8) !void {
        if (index >= self.items.items.len or text.len == 0) return;
        const old = self.items.items[index].text;
        const combined = try self.allocator.alloc(u8, old.len + text.len);
        @memcpy(combined[0..old.len], old);
        @memcpy(combined[old.len..], text);
        self.allocator.free(old);
        self.items.items[index].text = combined;
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
        var streaming_index: usize = 0;
        while (streaming_index < self.streaming_tool_calls.items.len) {
            const entry = &self.streaming_tool_calls.items[streaming_index];
            if (entry.item_index == index) {
                if (entry.tool_call_id) |tool_call_id| self.allocator.free(tool_call_id);
                _ = self.streaming_tool_calls.orderedRemove(streaming_index);
                continue;
            }
            if (entry.item_index > index) entry.item_index -= 1;
            streaming_index += 1;
        }
        adjustOptionalIndexAfterRemove(&self.last_streaming_assistant_index, index);
        adjustOptionalIndexAfterRemove(&self.last_streaming_thinking_index, index);
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

    fn clearStreamingToolCallsLocked(self: *AppState) void {
        for (self.streaming_tool_calls.items) |entry| {
            if (entry.tool_call_id) |tool_call_id| self.allocator.free(tool_call_id);
        }
        self.streaming_tool_calls.clearRetainingCapacity();
    }

    fn streamingToolCallItemIndexByIdLocked(self: *AppState, tool_call_id: []const u8) ?usize {
        for (self.streaming_tool_calls.items) |entry| {
            const entry_id = entry.tool_call_id orelse continue;
            if (std.mem.eql(u8, entry_id, tool_call_id)) return entry.item_index;
        }
        return null;
    }

    fn streamingToolCallItemIndexByContentIndexLocked(self: *AppState, content_index: u32) ?usize {
        for (self.streaming_tool_calls.items) |entry| {
            if (entry.content_index == content_index) return entry.item_index;
        }
        return null;
    }

    fn setStreamingToolCallIdLocked(
        self: *AppState,
        content_index: ?u32,
        tool_call_id: []const u8,
        item_index: usize,
    ) !void {
        for (self.streaming_tool_calls.items) |*entry| {
            const content_matches = if (content_index) |value|
                entry.content_index != null and entry.content_index.? == value
            else
                false;
            const id_matches = if (entry.tool_call_id) |entry_id|
                std.mem.eql(u8, entry_id, tool_call_id)
            else
                false;
            if (!content_matches and !id_matches) continue;

            if (entry.tool_call_id) |entry_id| {
                if (!std.mem.eql(u8, entry_id, tool_call_id)) {
                    self.allocator.free(entry_id);
                    entry.tool_call_id = try self.allocator.dupe(u8, tool_call_id);
                }
            } else {
                entry.tool_call_id = try self.allocator.dupe(u8, tool_call_id);
            }
            entry.item_index = item_index;
            return;
        }

        try self.streaming_tool_calls.append(self.allocator, .{
            .content_index = content_index,
            .tool_call_id = try self.allocator.dupe(u8, tool_call_id),
            .item_index = item_index,
        });
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

fn adjustOptionalIndexAfterRemove(index: *?usize, removed_index: usize) void {
    const current = index.* orelse return;
    if (current == removed_index) {
        index.* = null;
    } else if (current > removed_index) {
        index.* = current - 1;
    }
}

pub const QueueDisplayMode = enum {
    steering,
    follow_up,
};

pub const ScreenComponent = struct {
    state: *AppState,
    editor: *tui.Editor,
    height: usize = 24,
    now_ms: i64 = 0,
    overlay: ?*SelectorOverlay = null,
    keybindings: ?*const keybindings_mod.Keybindings = null,
    theme: ?*const resources_mod.Theme = null,
    terminal_name: []const u8 = "term",
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
            try renderChatItemIntoWithOptions(
                allocator,
                @max(width, 1),
                self.keybindings,
                self.theme,
                item,
                self.now_ms,
                snapshot.all_expanded,
                &chat_lines,
            );
        }

        var prompt_lines = tui.LineList.empty;
        defer freeLinesSafe(allocator, &prompt_lines);
        try renderPromptLines(allocator, self.theme, self.editor, snapshot.pending_editor_images, width, &prompt_lines);
        var queued_lines = tui.LineList.empty;
        defer freeLinesSafe(allocator, &queued_lines);
        try renderQueuedMessageLines(allocator, self.keybindings, self.theme, &snapshot, width, &queued_lines);
        var task_panel_lines = tui.LineList.empty;
        defer freeLinesSafe(allocator, &task_panel_lines);
        try renderTaskPanelLines(allocator, self.theme, &snapshot, width, &task_panel_lines);
        const footer_line = try formatFooterLineWithTerminal(allocator, self.theme, &snapshot, self.terminal_name, width);
        defer allocator.free(footer_line);
        const hints_line = try formatHintsLine(allocator, self.keybindings, self.theme, width);
        defer allocator.free(hints_line);

        var autocomplete_lines = tui.LineList.empty;
        defer freeLinesSafe(allocator, &autocomplete_lines);
        try self.editor.renderAutocompleteInto(allocator, width, &autocomplete_lines);

        const hints_height = hintsHeightForWidth(width);
        const reserved_lines: usize = task_panel_lines.items.len + prompt_lines.items.len + queued_lines.items.len + hints_height + 1 + autocomplete_lines.items.len;
        const chat_capacity = if (self.height > reserved_lines) self.height - reserved_lines else 1;
        const max_offset = chat_lines.items.len -| chat_capacity;
        self.state.updateChatScrollLayout(chat_lines.items.len, chat_capacity, task_panel_lines.items.len, width);
        const chat_component = BorrowedLineListComponent{ .lines = chat_lines.items };
        const chat_viewport = tui.Viewport{
            .child = chat_component.component(),
            .height = chat_capacity,
            .anchor = .bottom,
            .scroll_offset = @min(snapshot.chat_scroll_offset, max_offset),
            .show_indicators = true,
            .theme = self.theme,
        };
        for (task_panel_lines.items) |line| {
            try tui.component.appendOwnedLine(lines, allocator, line);
        }
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
        if (hints_height > 0) try tui.component.appendOwnedLine(lines, allocator, hints_line);
        try tui.component.appendOwnedLine(lines, allocator, footer_line);
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
        const task_panel_height = taskPanelHeightForWidth(width);
        const hints_height = hintsHeightForWidth(width);
        const reserved_lines: usize = task_panel_height + prompt_height + queued_height + hints_height + 1 + autocomplete_height;
        const window_height: usize = @max(@as(usize, window.height), 1);
        const chat_capacity = if (window_height > reserved_lines) window_height - reserved_lines else 1;

        var row: usize = 0;
        if (task_panel_height > 0 and row < window.height) {
            const panel_window = window.child(.{
                .y_off = @intCast(row),
                .height = @intCast(@min(task_panel_height, @as(usize, window.height) - row)),
            });
            _ = try drawTaskPanel(panel_window, .{
                .window = panel_window,
                .arena = ctx.arena,
                .theme = self.theme,
            }, self.theme, &snapshot);
        }
        row += task_panel_height;

        const chat_metrics = try drawChatViewport(
            ctx.arena,
            self.keybindings,
            self.theme,
            snapshot.items,
            window,
            row,
            chat_capacity,
            snapshot.chat_scroll_offset,
            self.now_ms,
            snapshot.all_expanded,
        );
        self.state.updateChatScrollLayout(chat_metrics.rendered_height, chat_metrics.visible_height, row, width);
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

        const editor_window_width = promptEditorWidth(width);
        const editor_x = promptEditorOffsetX(width);
        const editor_y = prompt_start_row + promptEditorOffsetY(width);
        if (editor_y < window.height and @as(usize, window.width) > editor_x) {
            const editor_window = window.child(.{
                .x_off = @intCast(editor_x),
                .y_off = @intCast(editor_y),
                .width = @intCast(editor_window_width),
                .height = 1,
            });
            _ = try self.editor.draw(editor_window, .{
                .window = editor_window,
                .arena = ctx.arena,
                .theme = self.theme,
            });
        }

        if (autocomplete_height > 0 and row < window.height) {
            const autocomplete_window = window.child(.{
                .x_off = @intCast(editor_x),
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

        if (hints_height > 0 and row < window.height) {
            drawFittedLine(window, row, hints_text, styleForToken(self.theme, .prompt));
            row += 1;
        }
        if (row < window.height) {
            try drawFooterWithTerminal(window, row, footer_text, self.terminal_name, self.theme, ctx.arena);
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

fn drawFooterWithTerminal(
    window: tui.vaxis.Window,
    row: usize,
    footer_text: []const u8,
    terminal_name: []const u8,
    theme: ?*const resources_mod.Theme,
    allocator: std.mem.Allocator,
) !void {
    if (row >= window.height) return;
    const footer_style = styleForToken(theme, .footer);
    const badge_style = styleForToken(theme, .terminal_badge);
    const line_window = window.child(.{
        .y_off = @intCast(row),
        .height = 1,
    });
    line_window.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = footer_style,
    });

    const available_width = @as(usize, line_window.width);
    const badge = if (layoutMode(available_width) == .mini or layoutMode(available_width) == .compact)
        try allocator.dupe(u8, "")
    else
        try formatTerminalBadge(allocator, terminal_name);
    const badge_width = tui.ansi.visibleWidth(badge);
    const footer_width = if (available_width > badge_width + 1) available_width - badge_width - 1 else available_width;
    const compact_footer_text = std.mem.trimEnd(u8, footer_text, " ");
    const fitted_footer = try fitLine(allocator, compact_footer_text, footer_width);

    _ = line_window.printSegment(.{
        .text = fitted_footer,
        .style = footer_style,
    }, .{ .wrap = .none });

    if (badge_width > 0 and available_width > badge_width + 1) {
        _ = line_window.printSegment(.{
            .text = badge,
            .style = badge_style,
        }, .{
            .wrap = .none,
            .col_offset = @intCast(available_width - badge_width),
        });
    }
}

fn drawTaskPanel(
    window: tui.vaxis.Window,
    ctx: tui.DrawContext,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
) !tui.DrawSize {
    const requested_height = taskPanelHeightForWidth(@as(usize, window.width));
    const panel_height = @min(requested_height, @as(usize, window.height));
    if (panel_height == 0) return .{ .width = window.width, .height = 0 };
    const border_style = styleForToken(theme, .task_header_separator);
    const content_style = styleForToken(theme, .task_header);
    const bordered = panel_height >= TOP_PANEL_HEIGHT and window.width >= 2 and window.height >= 2;
    const panel_inner = if (bordered)
        window.child(.{
            .height = @intCast(panel_height),
            .border = .{
                .where = .all,
                .style = border_style,
                .glyphs = .single_rounded,
            },
        })
    else
        window.child(.{ .height = @intCast(panel_height) });

    panel_inner.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = content_style,
    });

    if (panel_inner.height > 0) {
        const content = try formatTaskHeaderTextForMode(ctx.arena, snapshot, @as(usize, panel_inner.width), layoutMode(@as(usize, window.width)));
        _ = panel_inner.printSegment(.{
            .text = content,
            .style = content_style,
        }, .{ .wrap = .none });
    }

    return .{
        .width = window.width,
        .height = @intCast(panel_height),
    };
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
    _ = allocator;
    _ = theme;
    _ = editor;
    const editor_width = promptEditorWidth(width);
    const prompt_rows: usize = switch (layoutMode(width)) {
        .full, .medium, .narrow => PROMPT_BOX_HEIGHT,
        .mini, .compact => 1,
    };
    return prompt_rows + pendingImagesRenderHeight(pending_images, editor_width);
}

fn drawPromptLines(
    window: tui.vaxis.Window,
    ctx: tui.DrawContext,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    pending_images: []const PendingEditorImage,
) !tui.DrawSize {
    const prompt_style = styleForToken(theme, .prompt);
    const glyph_style = styleForToken(theme, .prompt_glyph);
    const border_style = styleForToken(theme, .prompt_border);
    const width = @as(usize, window.width);
    const mode = layoutMode(width);
    const editor_width = promptEditorWidth(width);
    const prompt_rows: usize = switch (mode) {
        .full, .medium, .narrow => PROMPT_BOX_HEIGHT,
        .mini, .compact => 1,
    };
    const prompt_height = @min(prompt_rows, @as(usize, window.height));
    const prompt_inner = if (mode != .mini and mode != .compact and window.width >= 2 and window.height >= 2)
        window.child(.{
            .height = @intCast(prompt_height),
            .border = .{
                .where = .all,
                .style = border_style,
                .glyphs = .single_rounded,
            },
        })
    else
        window.child(.{ .height = @intCast(prompt_height) });
    prompt_inner.clear();

    const full_editor_height = try measureEditorHeight(ctx.arena, theme, editor, editor_width);
    const has_overflow = mode != .mini and mode != .compact and full_editor_height > @as(usize, @max(prompt_inner.height, 1));

    if (prompt_inner.height > 0) {
        const prefix = promptPrefixForWidth(width);
        const prefix_rows = if (mode == .mini or mode == .compact) @as(usize, 1) else @as(usize, prompt_inner.height);
        for (0..prefix_rows) |line_index| {
            _ = prompt_inner.printSegment(.{
                .text = prefix,
                .style = glyph_style,
            }, .{
                .wrap = .none,
                .row_offset = @intCast(line_index),
            });
        }
    }

    const editor_x = if (mode == .mini or mode == .compact) promptEditorOffsetX(width) else PROMPT_GLYPH_WIDTH;
    if (@as(usize, prompt_inner.width) > editor_x) {
        const editor_window = prompt_inner.child(.{
            .x_off = @intCast(editor_x),
            .width = @intCast(editor_width),
            .height = @max(prompt_inner.height, 1),
        });
        _ = try editor.draw(editor_window, .{
            .window = editor_window,
            .arena = ctx.arena,
            .theme = theme,
        });
    }

    if (has_overflow and window.height >= PROMPT_BOX_HEIGHT and window.width > 8) {
        const indicator = "↓ more";
        const indicator_width = tui.ansi.visibleWidth(indicator);
        const indicator_col = @max(@as(usize, 1), @as(usize, window.width) -| (indicator_width + 2));
        _ = window.printSegment(.{
            .text = indicator,
            .style = glyph_style,
        }, .{
            .wrap = .none,
            .row_offset = @intCast(PROMPT_BOX_HEIGHT - 1),
            .col_offset = @intCast(indicator_col),
        });
    }

    const prefix_width = promptEditorOffsetX(@as(usize, window.width));
    const blank_prefix = try ctx.arena.alloc(u8, prefix_width);
    @memset(blank_prefix, ' ');
    var image_row: usize = 0;
    for (pending_images, 0..) |image, index| {
        const row_count = pendingImageRenderHeight(image, editor_width);
        if (prompt_rows + image_row >= window.height) break;

        const continuation_window = window.child(.{
            .x_off = 0,
            .y_off = @intCast(prompt_rows + image_row),
            .height = @intCast(@min(row_count, @as(usize, window.height) -| (prompt_rows + image_row))),
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
        .height = @intCast(@min(prompt_rows + image_row, @as(usize, window.height))),
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

const ChatViewportMetrics = struct {
    rendered_height: usize,
    visible_height: usize,
};

fn drawChatViewport(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    items: []const ChatItem,
    window: tui.vaxis.Window,
    start_row: usize,
    height: usize,
    chat_scroll_offset: usize,
    now_ms: i64,
    all_expanded: bool,
) !ChatViewportMetrics {
    if (start_row >= window.height or height == 0) return .{ .rendered_height = 0, .visible_height = 0 };

    const visible_height = @min(height, @as(usize, window.height) - start_row);
    const width = @max(@as(usize, window.width), 1);
    const scratch_height = @max(visible_height, estimateChatRows(items, width, all_expanded));
    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = @intCast(@min(scratch_height, @as(usize, std.math.maxInt(u16)))),
        .cols = window.width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const scratch_window = tui.draw.rootWindow(&screen);
    scratch_window.clear();
    const rendered = try drawChatItems(scratch_window, allocator, keybindings, theme, items, now_ms, all_expanded);
    const rendered_height = @min(@as(usize, rendered.height), @as(usize, screen.height));
    const max_offset = rendered_height -| visible_height;
    const offset = @min(chat_scroll_offset, max_offset);
    const src_start = max_offset -| offset;
    const dst = window.child(.{
        .y_off = @intCast(start_row),
        .height = @intCast(visible_height),
    });
    blitScreenRows(&screen, dst, src_start, visible_height);
    drawChatScrollIndicators(dst, theme, src_start, rendered_height, visible_height);
    return .{ .rendered_height = rendered_height, .visible_height = visible_height };
}

fn drawChatScrollIndicators(
    window: tui.vaxis.Window,
    theme: ?*const resources_mod.Theme,
    src_start: usize,
    rendered_height: usize,
    visible_height: usize,
) void {
    if (visible_height == 0 or window.width == 0) return;
    const style = styleForToken(theme, .status);
    if (src_start > 0) {
        drawChatScrollIndicator(window, 0, "↑ more", style);
    }
    if (src_start + visible_height < rendered_height) {
        drawChatScrollIndicator(window, visible_height - 1, "↓ more", style);
    }
}

fn drawChatScrollIndicator(
    window: tui.vaxis.Window,
    row: usize,
    text: []const u8,
    style: tui.vaxis.Cell.Style,
) void {
    if (row >= window.height) return;
    const text_width = tui.ansi.visibleWidth(text);
    const col = @as(usize, window.width) -| text_width;
    _ = window.printSegment(.{
        .text = text,
        .style = style,
    }, .{
        .wrap = .none,
        .row_offset = @intCast(row),
        .col_offset = @intCast(col),
    });
}

fn drawChatItems(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    items: []const ChatItem,
    now_ms: i64,
    all_expanded: bool,
) !tui.DrawSize {
    var row: usize = 0;
    for (items) |item| {
        if (row >= window.height) break;
        row += try drawChatItem(window, allocator, keybindings, theme, item, row, now_ms, all_expanded);
    }
    return .{
        .width = window.width,
        .height = @intCast(@min(row, @as(usize, window.height))),
    };
}

fn drawChatItem(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    start_row: usize,
    now_ms: i64,
    all_expanded: bool,
) !usize {
    const remaining_height = @as(usize, window.height) -| start_row;
    if (remaining_height == 0) return 0;
    const child = window.child(.{
        .y_off = @intCast(start_row),
        .height = @intCast(remaining_height),
    });
    if (!all_expanded) {
        if (previewThreshold(item.kind)) |threshold| {
            const full_height_hint = @max(@as(usize, 1), estimateChatItemRowsFull(item, @max(@as(usize, window.width), 1)));
            var scratch = try tui.vaxis.Screen.init(allocator, .{
                .rows = @intCast(@min(full_height_hint, @as(usize, std.math.maxInt(u16)))),
                .cols = window.width,
                .x_pixel = 0,
                .y_pixel = 0,
            });
            defer scratch.deinit(allocator);

            const scratch_window = tui.draw.rootWindow(&scratch);
            scratch_window.clear();
            const rendered_height = @min(
                try drawChatItemFull(scratch_window, allocator, theme, item, 0, now_ms),
                @as(usize, scratch.height),
            );
            if (rendered_height > threshold) {
                const preview_rows = @min(threshold, remaining_height);
                blitScreenRows(&scratch, child, 0, preview_rows);
                if (threshold < remaining_height) {
                    try drawCollapseIndicator(child, allocator, keybindings, theme, item.kind, threshold, rendered_height - threshold);
                }
                return @min(threshold + 1, remaining_height);
            }
        }
    }

    return drawChatItemFull(child, allocator, theme, item, 0, now_ms);
}

fn drawChatItemFull(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    start_row: usize,
    now_ms: i64,
) !usize {
    const remaining_height = @as(usize, window.height) -| start_row;
    if (remaining_height == 0) return 0;
    const child = window.child(.{
        .y_off = @intCast(start_row),
        .height = @intCast(remaining_height),
    });
    switch (item.kind) {
        .assistant => {
            var row: usize = drawWrappedText(child, 0, ASSISTANT_PREFIX, styleForToken(theme, .role_assistant));
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
        .thinking => return drawThinkingChatItem(child, theme, item, now_ms),
        else => return drawWrappedText(child, 0, item.text, styleForToken(theme, chatToken(item.kind))),
    }
}

fn previewThreshold(kind: ChatKind) ?usize {
    return switch (kind) {
        .thinking => 1,
        .tool_result => 3,
        .assistant, .markdown => 5,
        .welcome, .info, .@"error", .user, .tool_call => null,
    };
}

fn drawCollapseIndicator(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    kind: ChatKind,
    row: usize,
    hidden_rows: usize,
) !void {
    if (row >= window.height) return;
    const label = try actionLabel(allocator, keybindings, .toggle_expand_all, "Ctrl+R");
    const text = try std.fmt.allocPrint(allocator, "… +{d} lines ({s} 展开)", .{ hidden_rows, label });
    _ = window.printSegment(.{
        .text = text,
        .style = collapseIndicatorStyle(theme, kind),
    }, .{
        .wrap = .none,
        .row_offset = @intCast(row),
    });
}

fn collapseIndicatorStyle(
    theme: ?*const resources_mod.Theme,
    kind: ChatKind,
) tui.vaxis.Cell.Style {
    var style = switch (kind) {
        .thinking => styleForToken(theme, .role_thinking),
        .tool_result => styleForToken(theme, .role_tool_result),
        .assistant, .markdown => styleForToken(theme, .markdown_text),
        else => styleForToken(theme, .status),
    };
    style.dim = true;
    if (kind == .assistant or kind == .markdown) {
        style.italic = true;
    }
    return style;
}

fn drawThinkingChatItem(
    window: tui.vaxis.Window,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    now_ms: i64,
) usize {
    if (window.height == 0 or window.width == 0) return 0;

    const glyph_style = styleForToken(theme, .role_thinking_glyph);
    const text_style = styleForToken(theme, .role_thinking);
    const glyph = thinkingFrameGlyph(item, now_ms);
    window.writeCell(0, 0, .{
        .char = .{ .grapheme = glyph, .width = 1 },
        .style = glyph_style,
    });
    if (window.width > 1) {
        window.writeCell(1, 0, .{
            .char = .{ .grapheme = " ", .width = 1 },
            .style = text_style,
        });
    }

    if (window.width <= 2 or item.text.len == 0) return 1;

    const text_window = window.child(.{
        .x_off = 2,
        .width = window.width - 2,
    });
    return @max(@as(usize, 1), drawWrappedText(text_window, 0, item.text, text_style));
}

fn thinkingFrameGlyph(item: ChatItem, now_ms: i64) []const u8 {
    var loader = tui.Loader{};
    loader.setFrameIndex(thinkingFrameIndex(item, now_ms));
    return loader.currentFrame();
}

fn thinkingFrameIndex(item: ChatItem, now_ms: i64) usize {
    if (item.frozen_frame_index) |index| return index;
    const start_ms = item.start_ms orelse now_ms;
    const elapsed_i64 = @max(now_ms - start_ms, 0);
    var loader = tui.Loader{};
    return loader.frameIndexForElapsed(@intCast(elapsed_i64));
}

fn chatToken(kind: ChatKind) resources_mod.ThemeToken {
    return switch (kind) {
        .welcome => .welcome,
        .info => .status,
        .@"error" => .@"error",
        .markdown => .markdown_text,
        .user => .role_user,
        .assistant => .role_assistant,
        .thinking => .role_thinking,
        .tool_call => .role_tool_call,
        .tool_result => .role_tool_result,
    };
}

fn estimateChatRows(items: []const ChatItem, width: usize, all_expanded: bool) usize {
    var rows: usize = 1;
    for (items) |item| {
        rows += estimateChatItemRowsVisible(item, width, all_expanded);
    }
    return rows;
}

fn estimateChatItemRowsVisible(item: ChatItem, width: usize, all_expanded: bool) usize {
    const full_rows = estimateChatItemRowsFull(item, width);
    if (!all_expanded) {
        if (previewThreshold(item.kind)) |threshold| {
            if (full_rows > threshold) return threshold + 1;
        }
    }
    return full_rows;
}

fn estimateChatItemRowsFull(item: ChatItem, width: usize) usize {
    return switch (item.kind) {
        .assistant => 1 + estimateWrappedRows(item.text, width) + 8,
        .markdown => estimateWrappedRows(item.text, width) + 8,
        .thinking => if (width <= 2) 1 else @max(@as(usize, 1), estimateWrappedRows(item.text, width - 2)),
        else => estimateWrappedRows(item.text, width),
    };
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
                    .theme => |*theme_overlay| &theme_overlay.list,
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
                        .theme => |*theme_overlay| &theme_overlay.list,
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

fn systemNowMilliseconds(_: ?*anyopaque) i64 {
    return nowMilliseconds();
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

pub const INPUT_PROMPT_PREFIX = "> ";
const COMPACT_INPUT_PROMPT_PREFIX = "Input: ";
const TOP_PANEL_HEIGHT: usize = 3;
const COLLAPSED_TOP_PANEL_HEIGHT: usize = 1;
const PROMPT_BOX_HEIGHT: usize = 3;
const PROMPT_BORDER_TOP_ROWS: usize = 1;
const PROMPT_GLYPH_WIDTH: usize = 2;
const PROMPT_EDITOR_WIDTH_OVERHEAD: usize = 4;

const LayoutMode = enum {
    full,
    medium,
    narrow,
    mini,
    compact,
};

fn layoutMode(width: usize) LayoutMode {
    if (width >= 100) return .full;
    if (width >= 80) return .medium;
    if (width >= 60) return .narrow;
    if (width >= 40) return .mini;
    return .compact;
}

fn taskPanelHeightForWidth(width: usize) usize {
    return switch (layoutMode(width)) {
        .full, .medium => TOP_PANEL_HEIGHT,
        .narrow => COLLAPSED_TOP_PANEL_HEIGHT,
        .mini, .compact => 0,
    };
}

fn hintsHeightForWidth(width: usize) usize {
    return switch (layoutMode(width)) {
        .full, .medium, .narrow => 1,
        .mini, .compact => 0,
    };
}

fn promptPrefixForWidth(width: usize) []const u8 {
    return switch (layoutMode(width)) {
        .compact => COMPACT_INPUT_PROMPT_PREFIX,
        else => INPUT_PROMPT_PREFIX,
    };
}

fn promptEditorWidth(width: usize) usize {
    return switch (layoutMode(width)) {
        .full, .medium, .narrow => @max(@as(usize, 1), width -| PROMPT_EDITOR_WIDTH_OVERHEAD),
        .mini => @max(@as(usize, 1), width -| PROMPT_GLYPH_WIDTH),
        .compact => @max(@as(usize, 1), width -| tui.ansi.visibleWidth(COMPACT_INPUT_PROMPT_PREFIX)),
    };
}

fn promptEditorOffsetX(width: usize) usize {
    return switch (layoutMode(width)) {
        .full, .medium, .narrow => @min(width, PROMPT_BORDER_TOP_ROWS + PROMPT_GLYPH_WIDTH),
        .mini => @min(width, PROMPT_GLYPH_WIDTH),
        .compact => @min(width, tui.ansi.visibleWidth(COMPACT_INPUT_PROMPT_PREFIX)),
    };
}

fn promptEditorOffsetY(width: usize) usize {
    return switch (layoutMode(width)) {
        .full, .medium, .narrow => PROMPT_BORDER_TOP_ROWS,
        .mini, .compact => 0,
    };
}

pub fn renderTaskPanelLines(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    width: usize,
    lines: *tui.LineList,
) !void {
    const panel_height = taskPanelHeightForWidth(width);
    if (panel_height == 0) return;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch_allocator = arena.allocator();

    var screen = try tui.vaxis.Screen.init(scratch_allocator, .{
        .rows = @intCast(panel_height),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(scratch_allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    const rendered = try drawTaskPanel(window, .{
        .window = window,
        .arena = scratch_allocator,
        .theme = theme,
    }, theme, snapshot);
    try tui.cell_rows.appendScreenRowsAsPlainLines(allocator, &screen, width, rendered.height, lines);
}

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
    try tui.cell_rows.appendScreenRowsAsPlainLines(allocator, &screen, width, rendered.height, lines);
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

pub fn formatFooterLineWithTerminal(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    terminal_name: []const u8,
    width: usize,
) ![]u8 {
    const fitted = try formatFooterTextWithTerminal(allocator, snapshot, terminal_name, width);
    defer allocator.free(fitted);
    return try applyThemeAlloc(allocator, theme, .footer, fitted);
}

pub fn formatTaskHeaderText(
    allocator: std.mem.Allocator,
    snapshot: *const RenderStateSnapshot,
    width: usize,
) ![]u8 {
    return formatTaskHeaderTextForMode(allocator, snapshot, width, layoutMode(width));
}

fn formatTaskHeaderTextForMode(
    allocator: std.mem.Allocator,
    snapshot: *const RenderStateSnapshot,
    width: usize,
    mode: LayoutMode,
) ![]u8 {
    const session_label = nonEmptyOr(snapshot.session_label, "(unsaved)");
    const status_label = nonEmptyOr(snapshot.status, "idle");
    const model_label = nonEmptyOr(snapshot.model_label, "unknown");
    const provider_label = nonEmptyOr(snapshot.provider_label, "unknown");

    const title = try std.fmt.allocPrint(allocator, "pi · {s}", .{session_label});
    defer allocator.free(title);

    const single_line_status = try sanitizeSingleLineStatusAlloc(allocator, status_label);
    defer allocator.free(single_line_status);
    if (mode == .narrow) return try fitLine(allocator, title, width);

    const meta = switch (mode) {
        .full => try std.fmt.allocPrint(
            allocator,
            "Status: {s} · Model: {s} · Provider: {s}",
            .{ single_line_status, model_label, provider_label },
        ),
        .medium => try std.fmt.allocPrint(
            allocator,
            "Status: {s} · Model: {s}",
            .{ single_line_status, model_label },
        ),
        else => try std.fmt.allocPrint(
            allocator,
            "Status: {s} · Model: {s}",
            .{ single_line_status, model_label },
        ),
    };
    defer allocator.free(meta);

    const title_width = tui.ansi.visibleWidth(title);
    const meta_width = tui.ansi.visibleWidth(meta);
    if (width > 0 and title_width + 1 + meta_width <= width) {
        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);
        try builder.appendSlice(allocator, title);
        const padding = width - title_width - meta_width;
        try builder.appendNTimes(allocator, ' ', padding);
        try builder.appendSlice(allocator, meta);
        return builder.toOwnedSlice(allocator);
    }

    const combined = try std.fmt.allocPrint(allocator, "{s} · {s}", .{ title, meta });
    defer allocator.free(combined);
    return try fitLine(allocator, combined, width);
}

fn nonEmptyOr(value: ?[]const u8, fallback: []const u8) []const u8 {
    const text = value orelse return fallback;
    return if (text.len > 0) text else fallback;
}

pub fn formatFooterText(
    allocator: std.mem.Allocator,
    snapshot: *const RenderStateSnapshot,
    width: usize,
) ![]u8 {
    switch (layoutMode(width)) {
        .mini => return formatMiniFooterText(allocator, snapshot, width),
        .compact => return formatCompactFooterText(allocator, snapshot, width),
        else => {},
    }

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

    const fitted = try fitLine(allocator, builder.items, width);
    return fitted;
}

fn formatMiniFooterText(
    allocator: std.mem.Allocator,
    snapshot: *const RenderStateSnapshot,
    width: usize,
) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    var needs_separator = false;
    const model_label = nonEmptyOr(snapshot.model_label, "unknown");
    const model_text = try std.fmt.allocPrint(allocator, "Model: {s}", .{model_label});
    defer allocator.free(model_text);
    try appendFooterPart(allocator, &builder, &needs_separator, model_text);

    if (snapshot.context_window > 0) {
        const window_text = try formatCompactTokenCount(allocator, snapshot.context_window);
        defer allocator.free(window_text);
        const context_text = if (snapshot.context_percent) |percent|
            try std.fmt.allocPrint(allocator, "ctx {d:.1}%/{s}", .{ percent, window_text })
        else
            try std.fmt.allocPrint(allocator, "ctx ?/{s}", .{window_text});
        defer allocator.free(context_text);
        try appendFooterPart(allocator, &builder, &needs_separator, context_text);
    }

    return try fitLine(allocator, builder.items, width);
}

fn formatCompactFooterText(
    allocator: std.mem.Allocator,
    snapshot: *const RenderStateSnapshot,
    width: usize,
) ![]u8 {
    const status_label = nonEmptyOr(snapshot.status, "idle");
    const single_line_status = try sanitizeSingleLineStatusAlloc(allocator, status_label);
    defer allocator.free(single_line_status);
    const status_text = try std.fmt.allocPrint(allocator, "Status: {s}", .{single_line_status});
    defer allocator.free(status_text);
    return try fitLine(allocator, status_text, width);
}

pub fn formatFooterTextWithTerminal(
    allocator: std.mem.Allocator,
    snapshot: *const RenderStateSnapshot,
    terminal_name: []const u8,
    width: usize,
) ![]u8 {
    if (width == 0) return allocator.dupe(u8, "");
    if (layoutMode(width) == .mini or layoutMode(width) == .compact) {
        return formatFooterText(allocator, snapshot, width);
    }

    const badge = try formatTerminalBadge(allocator, terminal_name);
    defer allocator.free(badge);
    const badge_width = tui.ansi.visibleWidth(badge);
    if (badge_width == 0 or width <= badge_width + 1) {
        return formatFooterText(allocator, snapshot, width);
    }

    const footer_width = width - badge_width - 1;
    const footer_text = try formatFooterText(allocator, snapshot, footer_width);
    defer allocator.free(footer_text);

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    try builder.appendSlice(allocator, footer_text);
    const current_width = tui.ansi.visibleWidth(builder.items);
    if (width > current_width + badge_width) {
        try builder.appendNTimes(allocator, ' ', width - current_width - badge_width);
    }
    try builder.appendSlice(allocator, badge);
    return builder.toOwnedSlice(allocator);
}

fn formatTerminalBadge(allocator: std.mem.Allocator, terminal_name: []const u8) ![]u8 {
    const source = if (terminal_name.len > 0) terminal_name else "term";
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    for (source) |byte| {
        try builder.append(allocator, std.ascii.toUpper(byte));
    }
    return builder.toOwnedSlice(allocator);
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
    return try applyThemeAlloc(allocator, theme, .prompt, fitted);
}

pub fn formatHintsText(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    width: usize,
) ![]u8 {
    if (hintsHeightForWidth(width) == 0) return allocator.dupe(u8, "");

    const open_sessions = try actionLabel(allocator, keybindings, .open_sessions, "Ctrl+S");
    defer allocator.free(open_sessions);
    const open_models = try actionLabel(allocator, keybindings, .open_models, "Ctrl+P");
    defer allocator.free(open_models);
    const queue_label = try actionLabel(allocator, keybindings, .queue_follow_up, "Alt+Enter");
    defer allocator.free(queue_label);
    const queue_follow_up = try hintKeyLabel(allocator, queue_label);
    defer allocator.free(queue_follow_up);
    const interrupt = try actionLabel(allocator, keybindings, .interrupt, "Ctrl+C");
    defer allocator.free(interrupt);
    const exit = try actionLabel(allocator, keybindings, .exit, "Ctrl+D");
    defer allocator.free(exit);

    const line = switch (layoutMode(width)) {
        .full => try std.fmt.allocPrint(
            allocator,
            "⏎ send · {s} queue · {s} sessions · {s} models · {s} interrupt · {s} exit",
            .{ queue_follow_up, open_sessions, open_models, interrupt, exit },
        ),
        .medium => try std.fmt.allocPrint(
            allocator,
            "⏎ send · {s} queue · {s} sessions · {s} models",
            .{ queue_follow_up, open_sessions, open_models },
        ),
        .narrow => try std.fmt.allocPrint(
            allocator,
            "⏎ send · {s} sessions · {s} models",
            .{ open_sessions, open_models },
        ),
        .mini, .compact => try allocator.dupe(u8, ""),
    };
    defer allocator.free(line);
    const fitted = try fitLine(allocator, line, width);
    return fitted;
}

fn hintKeyLabel(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    if (std.mem.eql(u8, label, "Enter")) return allocator.dupe(u8, "⏎");
    if (std.mem.eql(u8, label, "Alt+Enter")) return allocator.dupe(u8, "Alt+⏎");
    return allocator.dupe(u8, label);
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
        .user => .role_user,
        .assistant => .role_assistant,
        .thinking => .role_thinking,
        .tool_call => .role_tool_call,
        .tool_result => .role_tool_result,
    }, item.text);
}

pub fn renderChatItemInto(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    lines: *tui.LineList,
) !void {
    try renderChatItemIntoAt(allocator, width, theme, item, 0, lines);
}

pub fn renderChatItemIntoAt(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    now_ms: i64,
    lines: *tui.LineList,
) !void {
    try renderChatItemIntoWithOptions(allocator, width, null, theme, item, now_ms, true, lines);
}

fn renderChatItemIntoWithOptions(
    allocator: std.mem.Allocator,
    width: usize,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    now_ms: i64,
    all_expanded: bool,
    lines: *tui.LineList,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch_allocator = arena.allocator();

    const height_hint = @max(@as(usize, 1), estimateChatRows(&.{item}, width, all_expanded));
    var screen = try tui.vaxis.Screen.init(scratch_allocator, .{
        .rows = @intCast(@min(height_hint, @as(usize, std.math.maxInt(u16)))),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(scratch_allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    const rendered = try drawChatItem(window, scratch_allocator, keybindings, theme, item, 0, now_ms, all_expanded);
    try tui.cell_rows.appendScreenRowsAsPlainLines(allocator, &screen, width, rendered, lines);
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
    try tui.cell_rows.appendScreenRowsAsPlainLines(allocator, &screen, width, rendered.height, lines);
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
            .start_ms = item.start_ms,
            .frozen_frame_index = item.frozen_frame_index,
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
        .cols = 80,
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

    const image_col: u16 = @intCast(promptEditorOffsetX(80));
    const image_cell = screen.readCell(image_col, PROMPT_BOX_HEIGHT) orelse return error.TestUnexpectedResult;
    try std.testing.expect(image_cell.image != null);
    try std.testing.expectEqual(@as(u32, 77), image_cell.image.?.img_id);
}

test "drawPromptLines renders bordered prompt with glyph prefix" {
    const allocator = std.testing.allocator;

    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("hello");

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    _ = try drawPromptLines(window, .{
        .window = window,
        .arena = arena.allocator(),
        .theme = &theme,
    }, &theme, &editor, &.{});

    const top_left = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("╭", top_left.char.grapheme);
    try std.testing.expectEqual(styleForToken(&theme, .prompt_border), top_left.style);

    const bottom_left = screen.readCell(0, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("╰", bottom_left.char.grapheme);
    try std.testing.expectEqual(styleForToken(&theme, .prompt_border), bottom_left.style);

    const glyph = screen.readCell(1, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(">", glyph.char.grapheme);
    try std.testing.expectEqual(styleForToken(&theme, .prompt_glyph), glyph.style);

    const first_text = screen.readCell(3, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("h", first_text.char.grapheme);
    try std.testing.expectEqual(styleForToken(&theme, .editor), first_text.style);
}

test "drawPromptLines places cursor after border and glyph offset" {
    const allocator = std.testing.allocator;

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("hello");

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    _ = try drawPromptLines(window, .{
        .window = window,
        .arena = arena.allocator(),
    }, null, &editor, &.{});

    try std.testing.expect(screen.cursor_vis);
    try std.testing.expectEqual(@as(u16, 8), screen.cursor.col);
    try std.testing.expectEqual(@as(u16, 1), screen.cursor.row);
}

test "measurePromptHeight uses fixed border height and editor width overhead" {
    const allocator = std.testing.allocator;

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("a long prompt that would previously grow the prompt area");

    try std.testing.expectEqual(@as(usize, 76), promptEditorWidth(80));
    try std.testing.expectEqual(@as(usize, 3), try measurePromptHeight(allocator, null, &editor, &.{}, 80));
}

test "drawPromptLines shows overflow indicator on bottom border" {
    const allocator = std.testing.allocator;

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz");

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 60,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    _ = try drawPromptLines(window, .{
        .window = window,
        .arena = arena.allocator(),
    }, null, &editor, &.{});

    var rendered = try tui.vaxis.AllocatingScreen.init(allocator, 60, 3);
    defer rendered.deinit(allocator);
    for (0..3) |row| {
        for (0..60) |col| {
            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse continue;
            rendered.writeCell(@intCast(col), @intCast(row), cell);
        }
    }
    const text = try tui.test_helpers.screenToString(&rendered);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "↓ more") != null);
}

test "screen draw renders top task panel and shifts chat below it" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("faux", "faux-1").?;
    try state.setFooterDetails(model, "demo-2026-04-27", null, "Faux", "env");
    try state.setStatus("ready");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
    };

    var screen = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 100, 8);
    defer screen.deinit(std.testing.allocator);

    try tui.test_helpers.expectCell(&screen, 0, 0, "╭", .{});
    try tui.test_helpers.expectCell(&screen, 0, 2, "╰", .{});

    const rendered = try tui.test_helpers.screenToString(&screen);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "pi · demo-2026-04-27") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Status: ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Model: faux-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Provider: Faux") != null);

    const row_three = screen.readCell(0, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("W", row_three.char.grapheme);
}

test "task header owns status model provider while footer excludes them" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("openai", "gpt-5.4").?;
    try state.setFooterDetails(model, "session.jsonl", "zig-implementation", "OpenAI", "env");
    try state.setStatus("missing key\nset OPENAI_API_KEY");

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);

    const header = try formatTaskHeaderText(allocator, &snapshot, 140);
    defer allocator.free(header);
    try std.testing.expect(std.mem.indexOf(u8, header, "pi · session.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Status: missing key set OPENAI_API_KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Model: gpt-5.4") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "Provider: OpenAI") != null);

    const footer = try formatFooterText(allocator, &snapshot, 140);
    defer allocator.free(footer);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Branch: zig-implementation") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Session: session.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Status:") == null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Model:") == null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Provider:") == null);
}

test "prompt m2 renders hints above compact footer with distinct styles and terminal badge" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("faux", "faux-1").?;
    try state.setFooterDetails(model, "demo-session.jsonl", "zig-implementation", "Faux", "env");
    state.usage_totals = .{
        .input = 1200,
        .output = 345,
    };
    state.context_window = 128000;
    state.context_percent = 12.5;

    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 14,
        .theme = &theme,
        .terminal_name = "ghostty",
    };

    var screen = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 100, 14);
    defer screen.deinit(std.testing.allocator);

    const rendered = try tui.test_helpers.screenToString(&screen);
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "⏎ send · Alt+⏎ queue · Ctrl+S sessions · Ctrl+P models · Ctrl+C interrupt · Ctrl+D exit") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "GHOSTTY") != null);

    const prompt_top = screen.readCell(0, 9) orelse return error.TestUnexpectedResult;
    const hint_first = screen.readCell(0, 12) orelse return error.TestUnexpectedResult;
    const footer_first = screen.readCell(0, 13) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("╭", prompt_top.char.grapheme);
    try std.testing.expectEqualStrings("⏎", hint_first.char.grapheme);
    try std.testing.expectEqualStrings("B", footer_first.char.grapheme);
    try std.testing.expect(!std.meta.eql(hint_first.style, footer_first.style));

    const footer_session_label = try allocator.dupe(u8, "demo-session.jsonl");
    defer allocator.free(footer_session_label);
    const footer_git_branch = try allocator.dupe(u8, "zig-implementation");
    defer allocator.free(footer_git_branch);
    const footer = try formatFooterTextWithTerminal(allocator, &.{
        .session_label = footer_session_label,
        .git_branch = footer_git_branch,
        .usage_totals = .{ .input = 1200, .output = 345 },
        .context_window = 128000,
        .context_percent = 12.5,
    }, "ghostty", 100);
    defer allocator.free(footer);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Branch: zig-implementation") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Session:") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "↑1.2k") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "↓345") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "ctx 12.5%/128k") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "GHOSTTY") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Status:") == null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Model:") == null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Provider:") == null);
}

test "prompt m5 applies breakpoint-specific layout collapse rules" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("faux", "faux-1").?;
    try state.setFooterDetails(model, "m5-session.jsonl", "zig-implementation", "Faux", "env");
    try state.setStatus("ready");
    state.context_window = 128000;
    state.context_percent = 12.5;

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);

    const header_100 = try formatTaskHeaderText(allocator, &snapshot, 100);
    defer allocator.free(header_100);
    try std.testing.expect(std.mem.indexOf(u8, header_100, "Provider: Faux") != null);

    const header_80 = try formatTaskHeaderText(allocator, &snapshot, 80);
    defer allocator.free(header_80);
    try std.testing.expect(std.mem.indexOf(u8, header_80, "Status: ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, header_80, "Model: faux-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, header_80, "Provider:") == null);

    const header_60 = try formatTaskHeaderText(allocator, &snapshot, 60);
    defer allocator.free(header_60);
    try std.testing.expect(std.mem.indexOf(u8, header_60, "pi · m5-session.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, header_60, "Status:") == null);

    const footer_50 = try formatFooterText(allocator, &snapshot, 50);
    defer allocator.free(footer_50);
    try std.testing.expect(std.mem.indexOf(u8, footer_50, "Model: faux-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer_50, "ctx 12.5%/128k") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer_50, "Session:") == null);

    const footer_36 = try formatFooterText(allocator, &snapshot, 36);
    defer allocator.free(footer_36);
    try std.testing.expect(std.mem.indexOf(u8, footer_36, "Status: ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer_36, "Model:") == null);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("hello");

    var screen_50 = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 12,
        .terminal_name = "ghostty",
    };
    var rendered_50 = try tui.test_helpers.renderToScreen(screen_50.drawComponent(), 50, 12);
    defer rendered_50.deinit(std.testing.allocator);
    const text_50 = try tui.test_helpers.screenToString(&rendered_50);
    defer allocator.free(text_50);
    try std.testing.expect(std.mem.indexOf(u8, text_50, "> hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_50, "╭") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_50, "⏎ send") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_50, "Model: faux-1") != null);

    var rendered_36 = try tui.test_helpers.renderToScreen(screen_50.drawComponent(), 36, 12);
    defer rendered_36.deinit(std.testing.allocator);
    const text_36 = try tui.test_helpers.screenToString(&rendered_36);
    defer allocator.free(text_36);
    try std.testing.expect(std.mem.indexOf(u8, text_36, "Input: hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_36, "Status: ready") != null);
}

test "prompt m5 keeps CJK text visible inside bordered prompt" {
    const allocator = std.testing.allocator;

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("你好");

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 100,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    _ = try drawPromptLines(window, .{
        .window = window,
        .arena = arena.allocator(),
    }, null, &editor, &.{});

    const first = screen.readCell(3, 1) orelse return error.TestUnexpectedResult;
    const second = screen.readCell(5, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("你", first.char.grapheme);
    try std.testing.expectEqualStrings("好", second.char.grapheme);
}

test "screen draw re-reads theme after runtime switch without stale structural cells" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("faux", "faux-1").?;
    try state.setFooterDetails(model, "demo-session.jsonl", "zig-implementation", "Faux", "env");

    var dark = try resources_mod.Theme.initDefault(allocator);
    defer dark.deinit(allocator);
    var codex = try resources_mod.Theme.initCodex(allocator);
    defer codex.deinit(allocator);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("hello");

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 14,
        .theme = &dark,
        .terminal_name = "ghostty",
    };

    var dark_screen = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 100, 14);
    defer dark_screen.deinit(std.testing.allocator);
    const dark_glyph = dark_screen.readCell(1, 10) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(">", dark_glyph.char.grapheme);
    try std.testing.expectEqual(styleForToken(&dark, .prompt_glyph), dark_glyph.style);

    const dark_text = try tui.test_helpers.screenToString(&dark_screen);
    defer allocator.free(dark_text);

    screen_component.theme = &codex;
    var codex_screen = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 100, 14);
    defer codex_screen.deinit(std.testing.allocator);
    const codex_glyph = codex_screen.readCell(1, 10) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(">", codex_glyph.char.grapheme);
    try std.testing.expectEqual(styleForToken(&codex, .prompt_glyph), codex_glyph.style);
    try std.testing.expect(!std.meta.eql(dark_glyph.style, codex_glyph.style));

    const codex_text = try tui.test_helpers.screenToString(&codex_screen);
    defer allocator.free(codex_text);
    try std.testing.expectEqualStrings(dark_text, codex_text);
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

    var rendered = try tui.test_helpers.renderToScreen(screen.drawComponent(), backend.size.width, backend.size.height);
    defer rendered.deinit(std.testing.allocator);

    var lines = tui.LineList.empty;
    errdefer freeLinesSafe(allocator, &lines);
    try tui.cell_rows.appendAllocatingScreenRowsAsPlainLines(allocator, &rendered, backend.size.width, backend.size.height, &lines);
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
    _ = try renderer.showDrawOverlay(panel.drawComponent(), overlayPanelOptions(backend.size, 1.0));

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var vx = try tui.vaxis.init(std.testing.io, allocator, &env_map, .{});
    defer vx.deinit(allocator, &writer.writer);

    try renderer.renderToVaxis(screen.drawComponent(), &vx, &writer.writer);

    var lines = tui.LineList.empty;
    errdefer freeLinesSafe(allocator, &lines);
    try tui.cell_rows.appendAllocatingScreenRowsAsPlainLines(allocator, &vx.screen_last, backend.size.width, backend.size.height, &lines);
    return lines;
}

pub fn renderedLinesContain(lines: []const []const u8, needle: []const u8) bool {
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

test "chat scroll wheel updates offset only inside chat region and clamps" {
    const allocator = std.testing.allocator;
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    state.updateChatScrollLayout(30, 10, 3, 80);
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);
    try std.testing.expectEqual(@as(usize, 20), state.chat_scroll_max_offset);

    state.handleChatMouseWheel(.{ .direction = .up, .row = 0, .col = 10 });
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    state.handleChatMouseWheel(.{ .direction = .up, .row = 23, .col = 10 });
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    state.handleChatMouseWheel(.{ .direction = .up, .row = 5, .col = 10 });
    try std.testing.expectEqual(@as(usize, 3), state.chat_scroll_offset);

    for (0..10) |_| state.handleChatMouseWheel(.{ .direction = .up, .row = 5, .col = 10 });
    try std.testing.expectEqual(@as(usize, 20), state.chat_scroll_offset);

    state.handleChatMouseWheel(.{ .direction = .down, .row = 5, .col = 10 });
    try std.testing.expectEqual(@as(usize, 17), state.chat_scroll_offset);
    for (0..10) |_| state.handleChatMouseWheel(.{ .direction = .down, .row = 5, .col = 10 });
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);
}

test "chat scroll tail clear auto-follow and resize clamp state" {
    const allocator = std.testing.allocator;
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    state.updateChatScrollLayout(30, 10, 3, 80);
    state.chat_scroll_offset = 12;
    state.chatScrollToTail();
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    try state.appendItemLocked(.info, "new tail item");
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    state.chat_scroll_offset = 8;
    try state.appendItemLocked(.info, "preserve reader position");
    try std.testing.expectEqual(@as(usize, 8), state.chat_scroll_offset);

    state.updateChatScrollLayout(30, 25, 3, 80);
    try std.testing.expectEqual(@as(usize, 5), state.chat_scroll_offset);

    state.clearDisplay();
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    state.updateChatScrollLayout(5, 10, 3, 80);
    state.handleChatMouseWheel(.{ .direction = .up, .row = 5, .col = 10 });
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);
}

test "drawChatViewport honors scroll offset and overlays overflow indicators" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var items: [30]ChatItem = undefined;
    for (&items, 0..) |*item, index| {
        item.* = .{
            .kind = .info,
            .text = try std.fmt.allocPrint(allocator, "row {d:0>2}", .{index}),
        };
    }
    defer {
        for (&items) |item| allocator.free(item.text);
    }

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 12,
        .cols = 40,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);
    const window = tui.draw.rootWindow(&screen);
    window.clear();

    const metrics = try drawChatViewport(arena.allocator(), null, null, items[0..], window, 0, 12, 5, 0, true);
    try std.testing.expectEqual(@as(usize, 30), metrics.rendered_height);
    try std.testing.expectEqual(@as(usize, 12), metrics.visible_height);

    var rendered = try tui.vaxis.AllocatingScreen.init(allocator, 40, 12);
    defer rendered.deinit(allocator);
    for (0..12) |row| {
        for (0..40) |col| {
            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse continue;
            rendered.writeCell(@intCast(col), @intCast(row), cell);
        }
    }

    const text = try tui.test_helpers.screenToString(&rendered);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "row 13") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "row 24") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "↑ more") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "↓ more") != null);
}

test "roles m0 thinking deltas append to a thinking chat item" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const template = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    };

    try state.handleAgentEvent(.{
        .event_type = .message_start,
        .message = .{ .assistant = template },
    });
    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .thinking_start },
    });
    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .thinking_delta, .delta = "internal " },
    });
    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .thinking_delta, .delta = "reasoning" },
    });
    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .thinking_end },
    });

    try std.testing.expectEqual(@as(usize, 2), state.items.items.len);
    try std.testing.expectEqual(ChatKind.welcome, state.items.items[0].kind);
    try std.testing.expectEqual(ChatKind.thinking, state.items.items[1].kind);
    try std.testing.expectEqualStrings("internal reasoning", state.items.items[1].text);
    try std.testing.expect(state.last_streaming_thinking_index == null);
}

const FixedClock = struct {
    now_ms: i64,

    fn now(context: ?*anyopaque) i64 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.now_ms;
    }
};

test "thinking m1 streaming thinking item records start and frozen frame" {
    const allocator = std.testing.allocator;

    var clock = FixedClock{ .now_ms = 12_000 };
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    state.setClockForTesting(&clock, FixedClock.now);

    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .thinking_start },
    });
    try std.testing.expectEqual(ChatKind.thinking, state.items.items[1].kind);
    try std.testing.expectEqual(@as(?i64, 12_000), state.items.items[1].start_ms);
    try std.testing.expectEqual(@as(?usize, null), state.items.items[1].frozen_frame_index);

    clock.now_ms = 12_000 + @as(i64, @intCast(3 * tui.components.loader.DEFAULT_INTERVAL_MS));
    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .thinking_end },
    });

    try std.testing.expectEqual(@as(?usize, 3), state.items.items[1].frozen_frame_index);
    try std.testing.expect(state.last_streaming_thinking_index == null);
}

test "thinking m1 spinner frame derives from injected render clock" {
    const allocator = std.testing.allocator;

    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const frames = tui.components.loader.DEFAULT_SPINNER_FRAMES;
    for (frames, 0..) |frame, index| {
        var screen = try tui.vaxis.Screen.init(allocator, .{
            .rows = 2,
            .cols = 12,
            .x_pixel = 0,
            .y_pixel = 0,
        });
        defer screen.deinit(allocator);

        const window = tui.draw.rootWindow(&screen);
        window.clear();
        const now_ms = 1_000 + @as(i64, @intCast(index * tui.components.loader.DEFAULT_INTERVAL_MS));
        _ = try drawChatItem(window, arena.allocator(), null, &theme, .{
            .kind = .thinking,
            .text = @constCast("abc"),
            .start_ms = 1_000,
        }, 0, now_ms, true);

        const glyph = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(frame, glyph.char.grapheme);
        try std.testing.expectEqual(styleForToken(&theme, .role_thinking_glyph), glyph.style);
        const spacer = screen.readCell(1, 0) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(" ", spacer.char.grapheme);
        const body = screen.readCell(2, 0) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("a", body.char.grapheme);
        try std.testing.expectEqual(styleForToken(&theme, .role_thinking), body.style);
    }
}

test "thinking m1 frozen frame ignores later render clock" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var early_screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 8,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer early_screen.deinit(allocator);
    var late_screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 8,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer late_screen.deinit(allocator);

    const item = ChatItem{
        .kind = .thinking,
        .text = @constCast("done"),
        .start_ms = 5_000,
        .frozen_frame_index = 4,
    };

    const early_window = tui.draw.rootWindow(&early_screen);
    early_window.clear();
    _ = try drawChatItem(early_window, arena.allocator(), null, null, item, 0, 5_000, true);
    const early_glyph = early_screen.readCell(0, 0) orelse return error.TestUnexpectedResult;

    const late_window = tui.draw.rootWindow(&late_screen);
    late_window.clear();
    _ = try drawChatItem(late_window, arena.allocator(), null, null, item, 0, 15_000, true);
    const late_glyph = late_screen.readCell(0, 0) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings(tui.components.loader.DEFAULT_SPINNER_FRAMES[4], early_glyph.char.grapheme);
    try std.testing.expectEqualStrings(early_glyph.char.grapheme, late_glyph.char.grapheme);
}

test "thinking m1 continuation rows are indented without repeating glyph" {
    const allocator = std.testing.allocator;

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 5,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    _ = try drawChatItem(window, arena.allocator(), null, null, .{
        .kind = .thinking,
        .text = @constCast("abcdef"),
        .start_ms = 0,
    }, 0, 0, true);

    const first_glyph = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(tui.components.loader.DEFAULT_SPINNER_FRAMES[0], first_glyph.char.grapheme);
    const continuation_col0 = screen.readCell(0, 1) orelse return error.TestUnexpectedResult;
    const continuation_col1 = screen.readCell(1, 1) orelse return error.TestUnexpectedResult;
    const continuation_text = screen.readCell(2, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(continuation_col0.char.grapheme.len == 0 or std.mem.eql(u8, continuation_col0.char.grapheme, " "));
    try std.testing.expect(continuation_col1.char.grapheme.len == 0 or std.mem.eql(u8, continuation_col1.char.grapheme, " "));
    try std.testing.expectEqualStrings("d", continuation_text.char.grapheme);
}

test "thinking m1 finalized thinking renders identically across clocks" {
    const allocator = std.testing.allocator;

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.appendItemLocked(.thinking, "stable private thought");

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
        .now_ms = 1_000,
    };

    var first = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 60, 8);
    defer first.deinit(std.testing.allocator);
    const first_text = try tui.test_helpers.screenToString(&first);
    defer allocator.free(first_text);

    screen_component.now_ms = 20_000;
    var second = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 60, 8);
    defer second.deinit(std.testing.allocator);
    const second_text = try tui.test_helpers.screenToString(&second);
    defer allocator.free(second_text);

    try std.testing.expectEqualStrings(first_text, second_text);
}

test "roles m0 rebuildFromSession preserves thinking before assistant text" {
    const allocator = std.testing.allocator;

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp",
        .model = ai.model_registry.find("faux", "faux-1").?,
    });
    defer session.deinit();

    const blocks = [_]ai.ContentBlock{
        .{ .thinking = .{ .thinking = "private chain" } },
        .{ .text = .{ .text = "public answer" } },
    };
    const messages = [_]agent.AgentMessage{.{ .assistant = .{
        .content = &blocks,
        .api = "faux",
        .provider = "faux",
        .model = "faux-1",
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    } }};
    try session.agent.setMessages(&messages);

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try state.rebuildFromSession(&session, null);

    try std.testing.expect(state.items.items.len >= 3);
    try std.testing.expectEqual(ChatKind.welcome, state.items.items[0].kind);
    try std.testing.expectEqual(ChatKind.thinking, state.items.items[1].kind);
    try std.testing.expectEqualStrings("private chain", state.items.items[1].text);
    try std.testing.expectEqual(ChatKind.assistant, state.items.items[2].kind);
    try std.testing.expectEqualStrings("public answer", state.items.items[2].text);
}

test "roles m0 chatToken maps visible roles to role tokens" {
    try std.testing.expectEqual(resources_mod.ThemeToken.role_user, chatToken(.user));
    try std.testing.expectEqual(resources_mod.ThemeToken.role_assistant, chatToken(.assistant));
    try std.testing.expectEqual(resources_mod.ThemeToken.role_thinking, chatToken(.thinking));
    try std.testing.expectEqual(resources_mod.ThemeToken.role_tool_call, chatToken(.tool_call));
    try std.testing.expectEqual(resources_mod.ThemeToken.role_tool_result, chatToken(.tool_result));
}

test "roles m0 drawChatItem applies role styles to representative cells" {
    const allocator = std.testing.allocator;

    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 8,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const items = [_]ChatItem{
        .{ .kind = .user, .text = @constCast("You: hello") },
        .{ .kind = .assistant, .text = @constCast("answer") },
        .{ .kind = .thinking, .text = @constCast("private") },
        .{ .kind = .tool_call, .text = @constCast("Tool: bash") },
        .{ .kind = .tool_result, .text = @constCast("output") },
    };

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    _ = try drawChatItems(window, arena.allocator(), null, &theme, &items, 0, true);

    const user = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    const assistant = screen.readCell(0, 1) orelse return error.TestUnexpectedResult;
    const thinking = screen.readCell(2, 3) orelse return error.TestUnexpectedResult;
    const tool_call = screen.readCell(0, 4) orelse return error.TestUnexpectedResult;
    const tool_result = screen.readCell(0, 5) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(styleForToken(&theme, .role_user), user.style);
    try std.testing.expectEqual(styleForToken(&theme, .role_assistant), assistant.style);
    try std.testing.expectEqual(styleForToken(&theme, .role_thinking), thinking.style);
    try std.testing.expectEqual(styleForToken(&theme, .role_tool_call), tool_call.style);
    try std.testing.expectEqual(styleForToken(&theme, .role_tool_result), tool_result.style);
}

test "collapse m2 app state defaults and snapshots all_expanded" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try std.testing.expect(!state.all_expanded);
    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);
    try std.testing.expect(!snapshot.all_expanded);
}

test "collapse m2 preview thresholds match collapsible chat kinds" {
    try std.testing.expectEqual(@as(?usize, 1), previewThreshold(.thinking));
    try std.testing.expectEqual(@as(?usize, 3), previewThreshold(.tool_result));
    try std.testing.expectEqual(@as(?usize, 5), previewThreshold(.assistant));
    try std.testing.expectEqual(@as(?usize, 5), previewThreshold(.markdown));
    try std.testing.expectEqual(@as(?usize, null), previewThreshold(.welcome));
    try std.testing.expectEqual(@as(?usize, null), previewThreshold(.info));
    try std.testing.expectEqual(@as(?usize, null), previewThreshold(.@"error"));
    try std.testing.expectEqual(@as(?usize, null), previewThreshold(.user));
    try std.testing.expectEqual(@as(?usize, null), previewThreshold(.tool_call));
}

test "collapse m2 indicator renders with hidden row count and distinct style" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();
    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);

    const text =
        \\one
        \\two
        \\three
        \\four
        \\five
        \\six
        \\seven
        \\eight
        \\nine
        \\ten
    ;
    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 4,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    const rendered = try drawChatItem(window, arena.allocator(), &keybindings, &theme, .{
        .kind = .thinking,
        .text = @constCast(text),
        .frozen_frame_index = 0,
    }, 0, 0, false);

    try std.testing.expectEqual(@as(usize, 2), rendered);
    const body = screen.readCell(2, 0) orelse return error.TestUnexpectedResult;
    const indicator = screen.readCell(0, 1) orelse return error.TestUnexpectedResult;
    const indicator_plus = screen.readCell(2, 1) orelse return error.TestUnexpectedResult;
    const indicator_count = screen.readCell(3, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("…", indicator.char.grapheme);
    try std.testing.expectEqualStrings("+", indicator_plus.char.grapheme);
    try std.testing.expectEqualStrings("9", indicator_count.char.grapheme);
    try std.testing.expect(!std.meta.eql(body.style, indicator.style));
}

test "collapse m2 items at or under threshold render without indicator" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();

    var screen = try tui.vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = tui.draw.rootWindow(&screen);
    window.clear();
    const rendered = try drawChatItem(window, arena.allocator(), &keybindings, null, .{
        .kind = .tool_result,
        .text = @constCast("Tool result bash: ok"),
    }, 0, 0, false);

    try std.testing.expectEqual(@as(usize, 1), rendered);
    var lines = tui.LineList.empty;
    defer tui.component.freeLines(allocator, &lines);
    try tui.cell_rows.appendScreenRowsAsPlainLines(allocator, &screen, 80, rendered, &lines);
    try std.testing.expect(!renderedLinesContain(lines.items, "展开"));
}

test "collapse m2 estimateChatRows uses collapsed or expanded heights" {
    const text =
        \\one
        \\two
        \\three
        \\four
        \\five
        \\six
        \\seven
        \\eight
        \\nine
        \\ten
    ;
    const item = ChatItem{ .kind = .thinking, .text = @constCast(text), .frozen_frame_index = 0 };
    try std.testing.expectEqual(@as(usize, 2), estimateChatItemRowsVisible(item, 80, false));
    try std.testing.expectEqual(@as(usize, 10), estimateChatItemRowsVisible(item, 80, true));
    try std.testing.expectEqual(@as(usize, 3), estimateChatRows(&.{item}, 80, false));
    try std.testing.expectEqual(@as(usize, 11), estimateChatRows(&.{item}, 80, true));
}

test "collapse m2 toggle preserves tail and clamps non-tail offset" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    for (state.items.items) |item| allocator.free(item.text);
    state.items.clearRetainingCapacity();

    const text =
        \\one
        \\two
        \\three
        \\four
        \\five
        \\six
        \\seven
        \\eight
        \\nine
        \\ten
    ;
    try state.appendItemLocked(.thinking, text);
    state.chat_visible_rows = 2;
    state.chat_width = 80;

    state.chat_scroll_offset = 0;
    state.all_expanded = false;
    state.toggleAllExpanded();
    try std.testing.expect(state.all_expanded);
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    state.chat_scroll_offset = 20;
    state.chat_scroll_max_offset = 30;
    state.toggleAllExpanded();
    try std.testing.expect(!state.all_expanded);
    try std.testing.expectEqual(@as(usize, 1), state.chat_scroll_offset);
    try std.testing.expectEqual(@as(usize, 1), state.chat_scroll_max_offset);
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

test "route-a m1 streams tool-call arguments and dedupes execution start" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    var args_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer common.deinitJsonValue(allocator, .{ .object = args_object });
    try args_object.put(allocator, try allocator.dupe(u8, "command"), .{ .string = try allocator.dupe(u8, "echo hi") });
    const tool_call = ai.ToolCall{
        .id = "tool-1",
        .name = "bash",
        .arguments = .{ .object = args_object },
    };

    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .toolcall_start, .content_index = 0 },
    });
    try std.testing.expectEqual(@as(usize, 2), state.items.items.len);
    try std.testing.expectEqual(ChatKind.tool_call, state.items.items[1].kind);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "Tool call:") != null);

    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .toolcall_delta, .content_index = 0, .delta = "{\"command\":" },
    });
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "{\"command\":") != null);

    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .toolcall_delta, .content_index = 0, .delta = "\"echo hi\"}" },
    });
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "\"echo hi\"}") != null);

    try state.handleAgentEvent(.{
        .event_type = .message_update,
        .assistant_message_event = .{ .event_type = .toolcall_end, .content_index = 0, .tool_call = tool_call },
    });
    try std.testing.expectEqual(@as(usize, 2), state.items.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "Tool bash:") != null);

    try state.handleAgentEvent(.{
        .event_type = .tool_execution_start,
        .tool_call_id = "tool-1",
        .tool_name = "bash",
        .args = .{ .object = args_object },
    });
    try std.testing.expectEqual(@as(usize, 2), state.items.items.len);
    try std.testing.expectEqual(ChatKind.tool_call, state.items.items[1].kind);
    try std.testing.expect(std.mem.indexOf(u8, state.status, "working: bash") != null);
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

test "formatFooterLine excludes provider auth status after task header split" {
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

    try std.testing.expect(std.mem.indexOf(u8, footer, "Session: session.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Provider:") == null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Status:") == null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Model:") == null);
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
        .height = 11,
    };

    var screen = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 80, 11);
    defer screen.deinit(std.testing.allocator);

    try tui.test_helpers.expectCell(&screen, 0, 4, "╭", .{});

    const selected = screen.readCell(@intCast(promptEditorOffsetX(80) + 2), 7) orelse return error.TestUnexpectedResult;
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

test "vaxis m8 visual parity snapshot covers chat rows footer hints and queue" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("faux", "faux-1").?;
    try state.setFooterDetails(model, "m8-session.jsonl", "zig-implementation", "Faux", "env");
    try state.setStatus("streaming");
    try state.appendMarkdown("# M8 heading\n\n- list item\n\n`inline` code");
    try state.appendInfo("Tool read: {\"path\":\"note.txt\"}");
    try state.appendQueuedMessage(.steering, "queued during compaction");
    try state.appendQueuedMessage(.follow_up, "queued follow-up");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("pending prompt");

    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 20,
        .keybindings = &keybindings,
    };

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 160, .height = 20 } };
    defer backend.deinit(allocator);

    var lines = try renderScreenWithMockBackend(allocator, &screen_component, &backend);
    defer freeLinesSafe(allocator, &lines);

    try std.testing.expect(renderedLinesContain(lines.items, "M8 heading"));
    try std.testing.expect(renderedLinesContain(lines.items, "Tool read:"));
    try std.testing.expect(renderedLinesContain(lines.items, "Steering: queued during compaction"));
    try std.testing.expect(renderedLinesContain(lines.items, "Follow-up: queued follow-up"));
    try std.testing.expect(renderedLinesContain(lines.items, "> pending prompt"));
    try std.testing.expect(renderedLinesContain(lines.items, "⏎ send · Alt+⏎ queue · Ctrl+S sessions · Ctrl+P models · Ctrl+C interrupt · Ctrl+D exit"));
    try std.testing.expect(renderedLinesContain(lines.items, "Faux"));
    try std.testing.expect(renderedLinesContain(lines.items, "Queue: 1 steering, 1 follow-up"));
    try std.testing.expect(renderedLinesContain(lines.items, "Model: faux-1"));
}

test "vaxis m8 visual parity snapshot covers codex layout at 100x30 and 60x20" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const model = ai.model_registry.find("faux", "faux-1").?;
    try state.setFooterDetails(model, "codex-layout.jsonl", "zig-implementation", "Faux", "env");
    try state.setStatus("ready");
    try state.appendMarkdown("# Codex layout\n\n- visual parity");
    state.context_window = 128000;
    state.context_percent = 7.5;

    var theme = try resources_mod.Theme.initCodex(allocator);
    defer theme.deinit(allocator);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    _ = try editor.handlePaste("codex prompt");

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 30,
        .theme = &theme,
        .terminal_name = "ghostty",
    };

    var screen_100 = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 100, 30);
    defer screen_100.deinit(std.testing.allocator);
    const text_100 = try tui.test_helpers.screenToString(&screen_100);
    defer allocator.free(text_100);
    try std.testing.expect(std.mem.indexOf(u8, text_100, "pi · codex-layout.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_100, "Provider: Faux") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_100, "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_100, "> codex prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_100, "GHOSTTY") != null);

    screen_component.height = 20;
    var screen_60 = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 60, 20);
    defer screen_60.deinit(std.testing.allocator);
    const text_60 = try tui.test_helpers.screenToString(&screen_60);
    defer allocator.free(text_60);
    try std.testing.expect(std.mem.indexOf(u8, text_60, "pi · codex-layout.jsonl") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_60, "Provider:") == null);
    try std.testing.expect(std.mem.indexOf(u8, text_60, "> codex prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_60, "GHOSTTY") != null);
}

test "vaxis m8 visual parity snapshot covers overlay composition" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.setStatus("overlay open");

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();

    var keybindings = try keybindings_mod.Keybindings.initDefaults(allocator);
    defer keybindings.deinit();

    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 16,
        .keybindings = &keybindings,
    };

    var overlay = try overlays.loadHotkeysOverlay(allocator, &keybindings);
    defer overlay.deinit(allocator);

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 100, .height = 16 } };
    defer backend.deinit(allocator);

    var lines = try renderScreenWithMockBackendAndOverlay(allocator, &screen_component, &overlay, &backend);
    defer freeLinesSafe(allocator, &lines);

    try std.testing.expect(renderedLinesContain(lines.items, "Keyboard shortcuts"));
    try std.testing.expect(renderedLinesContain(lines.items, "Ctrl+P"));
    try std.testing.expect(renderedLinesContain(lines.items, "Ctrl+S"));
}
