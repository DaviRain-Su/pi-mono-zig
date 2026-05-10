const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tui = @import("tui");
const keybindings_mod = @import("../shared/keybindings.zig");
const provider_config = @import("../providers/provider_config.zig");
const resources_mod = @import("../resources/resources.zig");
const session_mod = @import("../sessions/session.zig");
const session_advanced = @import("../sessions/session_advanced.zig");
const extension_registry = @import("../extensions/extension_registry.zig");
const common = @import("../tools/common.zig");
const bash_execution = @import("bash_execution.zig");
const user_bash_task_mod = @import("user_bash_task.zig");
const active_operation_rendering = @import("active_operation_rendering.zig");
const shared = @import("shared.zig");
const formatting = @import("formatting.zig");
const overlays = @import("overlays.zig");
const clipboard_paste_task = @import("clipboard_paste_task.zig");
const chat_items = @import("chat_items.zig");
const chat_rendering = @import("chat_rendering.zig");
const extension_ui = @import("extension_ui.zig");
const git_status = @import("git_status.zig");
const overlay_panel = @import("overlay_panel.zig");
const pending_editor_images_mod = @import("pending_editor_images.zig");
const prompt_rendering = @import("prompt_rendering.zig");
const render_text = @import("render_text.zig");
const slash_commands = @import("slash_commands.zig");
const currentSessionLabel = shared.currentSessionLabel;
const SelectorOverlay = overlays.SelectorOverlay;
const ASSISTANT_PREFIX = formatting.ASSISTANT_PREFIX;
const ASSISTANT_THINKING_TEXT = "Thinking...";
const formatPrefixedBlocks = formatting.formatPrefixedBlocks;
const formatAssistantMessage = formatting.formatAssistantMessage;
const formatToolCall = formatting.formatToolCall;
const formatStreamingToolCall = formatting.formatStreamingToolCall;
const WHEEL_LINES_PER_NOTCH: usize = 3;

pub const ChatKind = chat_items.ChatKind;
pub const ChatItem = chat_items.ChatItem;

pub const PendingEditorImage = pending_editor_images_mod.PendingEditorImage;

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

pub const ExtensionWidgetPlacement = extension_ui.WidgetPlacement;
pub const ExtensionWidget = extension_ui.Widget;
pub const EXTENSION_WIDGET_TRUNCATION_MARKER = extension_ui.WIDGET_TRUNCATION_MARKER;

pub const SelectionRange = struct {
    start_row: usize,
    start_col: usize,
    end_row: usize,
    end_col: usize,
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
    chat_visible_rows: usize = 0,
    chat_width: usize = 1,
    all_expanded: bool = false,
    hide_thinking_blocks: bool = false,
    hidden_thinking_label: []u8 = &.{},
    extension_header_lines: [][]u8 = &.{},
    extension_footer_lines: [][]u8 = &.{},
    extension_editor_label: ?[]u8 = null,
    extension_widgets: []ExtensionWidget = &.{},
    extension_footer_statuses: [][]u8 = &.{},
    working_message: ?[]u8 = null,
    working_visible: bool = true,
    active_operation: ?ActiveOperationSnapshot = null,

    pub fn deinit(self: *RenderStateSnapshot, allocator: std.mem.Allocator) void {
        for (self.items) |*item| chat_items.deinit(allocator, item);
        if (self.items.len > 0) allocator.free(self.items);
        if (self.status) |status| allocator.free(status);
        if (self.provider_label) |provider_label| allocator.free(provider_label);
        if (self.provider_status) |provider_status| allocator.free(provider_status);
        if (self.model_label) |model_label| allocator.free(model_label);
        if (self.session_label) |session_label| allocator.free(session_label);
        if (self.git_branch) |git_branch| allocator.free(git_branch);
        deinitOwnedStringList(allocator, self.queued_steering);
        deinitOwnedStringList(allocator, self.queued_follow_up);
        pending_editor_images_mod.deinitForRender(allocator, self.pending_editor_images);
        deinitOwnedStringList(allocator, self.extension_header_lines);
        deinitOwnedStringList(allocator, self.extension_footer_lines);
        if (self.extension_editor_label) |label| allocator.free(label);
        for (self.extension_widgets) |*widget| widget.deinit(allocator);
        if (self.extension_widgets.len > 0) allocator.free(self.extension_widgets);
        deinitOwnedStringList(allocator, self.extension_footer_statuses);
        if (self.working_message) |message| allocator.free(message);
        if (self.active_operation) |operation| allocator.free(operation.label);
        self.* = undefined;
    }
};

pub const ActiveOperationKind = active_operation_rendering.ActiveOperationKind;
pub const ActiveOperationSnapshot = active_operation_rendering.ActiveOperationSnapshot;

const ActiveOperationState = struct {
    kind: ActiveOperationKind,
    label: []u8,
    start_ms: i64,
    delay_ms: u64 = 0,
    attempt: u32 = 0,
    max_attempts: u32 = 0,
};

const ActiveOperationOptions = struct {
    delay_ms: u64 = 0,
    attempt: u32 = 0,
    max_attempts: u32 = 0,
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

pub const AppState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(ChatItem) = .empty,
    visible_start_index: usize = 0,
    chat_scroll_offset: usize = 0,
    chat_scroll_max_offset: usize = 0,
    chat_total_rows: usize = 0,
    chat_visible_rows: usize = 0,
    chat_width: usize = 1,
    chat_region: ChatRegion = .{},
    scroll_indicator_row: ?usize = null,
    selection_active: bool = false,
    selection_start_row: usize = 0,
    selection_start_col: usize = 0,
    selection_end_row: usize = 0,
    selection_end_col: usize = 0,
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
    hide_thinking_blocks: bool = false,
    hidden_thinking_label: []u8 = &.{},
    extension_header_lines: [][]u8 = &.{},
    extension_footer_lines: [][]u8 = &.{},
    extension_editor_label: ?[]u8 = null,
    extension_widgets: std.ArrayList(ExtensionWidget) = .empty,
    extension_footer_statuses: std.StringHashMap([]u8),
    working_message: []u8 = &.{},
    working_visible: bool = true,
    active_operation: ?ActiveOperationState = null,
    terminal_progress_active: bool = false,
    terminal_progress_dirty: bool = false,
    clipboard_paste: clipboard_paste_task.ClipboardPasteTask,
    user_bash_task: user_bash_task_mod.UserBashTask = .{},
    scoped_model_override_active: bool = false,
    scoped_model_patterns: ?[][]u8 = null,
    clock_context: ?*anyopaque = null,
    clock_now_ms_fn: ClockNowMsFn = systemNowMilliseconds,
    last_clear_action_ms: ?i64 = null,
    last_escape_action_ms: ?i64 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !AppState {
        var state = AppState{
            .allocator = allocator,
            .io = io,
            .extension_footer_statuses = std.StringHashMap([]u8).init(allocator),
            .clipboard_paste = .{ .io = io },
        };
        errdefer state.deinit();
        state.status = try allocator.dupe(u8, "idle");
        state.provider_label = try allocator.dupe(u8, "unknown");
        state.provider_status = try allocator.dupe(u8, "needs auth");
        state.model_label = try allocator.dupe(u8, "unknown");
        state.session_label = try allocator.dupe(u8, "new");
        state.git_branch = try allocator.dupe(u8, "");
        state.hidden_thinking_label = try allocator.dupe(u8, ASSISTANT_THINKING_TEXT);
        state.working_message = try allocator.dupe(u8, "Working...");
        try state.appendItemLocked(.welcome, "Welcome to pi (Zig interactive mode). Type a prompt and press Enter.");
        return state;
    }

    pub fn deinit(self: *AppState) void {
        self.clearExtensionUiHooksLocked();
        self.clearActiveOperationLocked();
        self.extension_widgets.deinit(self.allocator);
        extension_ui.clearFooterStatuses(self.allocator, &self.extension_footer_statuses);
        self.extension_footer_statuses.deinit();
        self.user_bash_task.deinit(self.allocator);
        self.clearScopedModelOverrideLocked();
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
        for (self.items.items) |*item| chat_items.deinit(self.allocator, item);
        self.items.deinit(self.allocator);
        self.allocator.free(self.status);
        self.allocator.free(self.provider_label);
        self.allocator.free(self.provider_status);
        self.allocator.free(self.model_label);
        self.allocator.free(self.session_label);
        self.allocator.free(self.git_branch);
        self.allocator.free(self.hidden_thinking_label);
        self.allocator.free(self.working_message);
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
        var result = self.clipboard_paste.poll() orelse return;
        defer clipboard_paste_task.deinitResult(&result);

        switch (result) {
            .success => |image| {
                var pending = PendingEditorImage{
                    .data = try self.allocator.dupe(u8, image.data),
                    .mime_type = try self.allocator.dupe(u8, image.mime_type),
                    .kitty_image = try self.transmitKittyImage(image, terminal_image_context),
                };
                var appended = false;
                errdefer if (!appended) pending_editor_images_mod.deinit(self.allocator, &pending);

                {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    try self.pending_editor_images.append(self.allocator, pending);
                    appended = true;
                }
                try self.setStatus("clipboard image pasted");
            },
            .empty => try self.setStatus("clipboard does not contain an image"),
            .unsupported => try self.setStatus("clipboard image format is not supported (use PNG, JPEG, WebP, or GIF)"),
            .failure => try self.setStatus("clipboard image paste failed"),
            .none => {},
        }
    }

    pub fn clipboardPasteInProgress(self: *const AppState) bool {
        return self.clipboard_paste.isActive();
    }

    pub fn scopedModelPatterns(self: *const AppState) ?[]const []const u8 {
        if (!self.scoped_model_override_active) return null;
        return self.scoped_model_patterns;
    }

    pub fn hasScopedModelOverride(self: *const AppState) bool {
        return self.scoped_model_override_active;
    }

    pub fn setScopedModelOverride(self: *AppState, patterns: ?[]const []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearScopedModelOverrideLocked();
        self.scoped_model_override_active = true;
        if (patterns) |source| {
            if (source.len > 0) {
                var cloned = try self.allocator.alloc([]u8, source.len);
                var initialized: usize = 0;
                errdefer {
                    for (cloned[0..initialized]) |item| self.allocator.free(item);
                    self.allocator.free(cloned);
                }
                for (source, 0..) |item, index| {
                    cloned[index] = try self.allocator.dupe(u8, item);
                    initialized += 1;
                }
                self.scoped_model_patterns = cloned;
            }
        }
    }

    fn clearScopedModelOverrideLocked(self: *AppState) void {
        if (self.scoped_model_patterns) |patterns| {
            deinitOwnedStringList(self.allocator, patterns);
            self.scoped_model_patterns = null;
        }
        self.scoped_model_override_active = false;
    }

    pub fn startBashExecution(
        self: *AppState,
        allocator: std.mem.Allocator,
        session: *session_mod.AgentSession,
        command: []const u8,
        exclude_from_context: bool,
    ) !bool {
        return try self.user_bash_task.start(allocator, session, bashTaskHooks(self), command, exclude_from_context);
    }

    pub fn isBashExecutionActive(self: *const AppState) bool {
        return self.user_bash_task.isActive();
    }

    pub fn cancelBashExecution(self: *AppState) bool {
        return self.user_bash_task.abort();
    }

    pub fn pollBashExecution(self: *AppState, allocator: std.mem.Allocator) bool {
        return self.user_bash_task.poll(allocator);
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
            .chat_visible_rows = self.chat_visible_rows,
            .chat_width = self.chat_width,
            .all_expanded = self.all_expanded,
            .hide_thinking_blocks = self.hide_thinking_blocks,
        };
        errdefer snapshot.deinit(allocator);

        snapshot.status = try allocator.dupe(u8, self.status);
        snapshot.provider_label = try allocator.dupe(u8, self.provider_label);
        snapshot.provider_status = try allocator.dupe(u8, self.provider_status);
        snapshot.model_label = try allocator.dupe(u8, self.model_label);
        snapshot.session_label = try allocator.dupe(u8, self.session_label);
        snapshot.git_branch = try allocator.dupe(u8, self.git_branch);

        const start_index = @min(self.visible_start_index, self.items.items.len);
        snapshot.items = try chat_items.clone(allocator, self.items.items[start_index..]);
        snapshot.queued_steering = try cloneOwnedStringList(allocator, self.queued_steering.items);
        snapshot.queued_follow_up = try cloneOwnedStringList(allocator, self.queued_follow_up.items);
        snapshot.pending_editor_images = try pending_editor_images_mod.cloneForRender(allocator, self.pending_editor_images.items);
        snapshot.extension_header_lines = try cloneOwnedStringList(allocator, self.extension_header_lines);
        snapshot.extension_footer_lines = try cloneOwnedStringList(allocator, self.extension_footer_lines);
        snapshot.extension_editor_label = if (self.extension_editor_label) |label| try allocator.dupe(u8, label) else null;
        snapshot.extension_widgets = try extension_ui.cloneWidgets(allocator, self.extension_widgets.items);
        snapshot.extension_footer_statuses = try extension_ui.cloneFooterStatusesSorted(allocator, &self.extension_footer_statuses);
        snapshot.working_message = if (self.working_message.len > 0) try allocator.dupe(u8, self.working_message) else null;
        snapshot.working_visible = self.working_visible;
        if (self.active_operation) |operation| {
            snapshot.active_operation = .{
                .kind = operation.kind,
                .label = try allocator.dupe(u8, operation.label),
                .start_ms = operation.start_ms,
                .delay_ms = operation.delay_ms,
                .attempt = operation.attempt,
                .max_attempts = operation.max_attempts,
            };
        }
        return snapshot;
    }

    pub fn clearDisplay(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.visible_start_index = self.items.items.len;
        self.chat_scroll_offset = 0;
        self.chat_total_rows = 0;
        self.replaceLabelLocked(&self.status, "display cleared") catch {};
    }

    pub fn handleChatMouseWheel(self: *AppState, wheel: tui.keys.MouseWheelInput) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.chat_region.contains(wheel.row, wheel.col)) return;
        switch (wheel.direction) {
            .up => {
                if (self.chat_scroll_offset >= self.chat_scroll_max_offset and
                    self.revealOlderChatItemsLocked(WHEEL_LINES_PER_NOTCH))
                {
                    return;
                }
                self.chat_scroll_offset = @min(
                    self.chat_scroll_offset +| WHEEL_LINES_PER_NOTCH,
                    self.chat_scroll_max_offset,
                );
            },
            .down => self.chat_scroll_offset = self.chat_scroll_offset -| WHEEL_LINES_PER_NOTCH,
        }
    }

    pub fn chatScrollPageUp(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const page_size = self.chatScrollPageSizeLocked();
        if (self.chat_scroll_offset >= self.chat_scroll_max_offset and
            self.revealOlderChatItemsLocked(page_size))
        {
            return;
        }
        self.chat_scroll_offset = @min(
            self.chat_scroll_offset +| page_size,
            self.chat_scroll_max_offset,
        );
    }

    pub fn chatScrollPageDown(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.chat_scroll_offset = self.chat_scroll_offset -| self.chatScrollPageSizeLocked();
    }

    pub fn chatScrollToBottom(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.chat_scroll_offset = 0;
    }

    pub fn handleMouseClick(self: *AppState, click: tui.keys.MouseClickInput) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.scroll_indicator_row) |indicator_row| {
            if (click.row == @as(i16, @intCast(indicator_row))) {
                self.chat_scroll_offset = 0;
                return;
            }
        }
        self.startSelectionLocked(click.row, click.col);
    }

    pub fn handleMouseDrag(self: *AppState, drag: tui.keys.MouseDragInput) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.selection_active) return;
        self.updateSelectionEndLocked(drag.row, drag.col);
    }

    pub fn handleMouseRelease(self: *AppState, release: tui.keys.MouseReleaseInput) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.selection_active) return;
        self.updateSelectionEndLocked(release.row, release.col);
        self.selection_active = false;
    }

    fn startSelectionLocked(self: *AppState, row: i16, col: i16) void {
        if (!self.chat_region.contains(row, col)) return;
        const abs_row: usize = @intCast(row);
        const abs_col: usize = @intCast(col);
        const rel_row = abs_row - self.chat_region.row_start;
        const max_offset = self.chat_total_rows -| self.chat_visible_rows;
        const offset = @min(self.chat_scroll_offset, max_offset);
        const src_row = (max_offset -| offset) + rel_row;
        self.selection_active = true;
        self.selection_start_row = src_row;
        self.selection_start_col = abs_col;
        self.selection_end_row = src_row;
        self.selection_end_col = abs_col;
    }

    fn updateSelectionEndLocked(self: *AppState, row: i16, col: i16) void {
        const abs_row: usize = if (row < 0) 0 else @intCast(row);
        const abs_col: usize = if (col < 0) 0 else @intCast(col);
        const rel_row = if (abs_row >= self.chat_region.row_start)
            abs_row - self.chat_region.row_start
        else
            0;
        const max_offset = self.chat_total_rows -| self.chat_visible_rows;
        const offset = @min(self.chat_scroll_offset, max_offset);
        const src_row = (max_offset -| offset) + rel_row;
        self.selection_end_row = @min(src_row, self.chat_total_rows -| 1);
        self.selection_end_col = abs_col;
    }

    pub fn getSelectionRange(self: *const AppState) ?SelectionRange {
        if (self.selection_start_row == self.selection_end_row and
            self.selection_start_col == self.selection_end_col) return null;
        var start_row = self.selection_start_row;
        var start_col = self.selection_start_col;
        var end_row = self.selection_end_row;
        var end_col = self.selection_end_col;
        if (end_row < start_row or (end_row == start_row and end_col < start_col)) {
            const tmp_r = start_row;
            const tmp_c = start_col;
            start_row = end_row;
            start_col = end_col;
            end_row = tmp_r;
            end_col = tmp_c;
        }
        return .{
            .start_row = start_row,
            .start_col = start_col,
            .end_row = end_row,
            .end_col = end_col,
        };
    }

    pub fn hasSelection(self: *const AppState) bool {
        return self.selection_start_row != self.selection_end_row or
            self.selection_start_col != self.selection_end_col;
    }

    pub fn clearSelection(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.selection_active = false;
        self.selection_start_row = 0;
        self.selection_start_col = 0;
        self.selection_end_row = 0;
        self.selection_end_col = 0;
    }

    fn chatScrollPageSizeLocked(self: *const AppState) usize {
        return @max(self.chat_visible_rows -| 1, 1);
    }

    fn revealOlderChatItemsLocked(self: *AppState, min_rows: usize) bool {
        const item_count = self.items.items.len;
        const old_start = @min(self.visible_start_index, item_count);
        if (old_start == 0) {
            self.visible_start_index = 0;
            return false;
        }

        const width = @max(self.chat_width, 1);
        const target_rows = @max(min_rows, 1);
        const old_total_rows = estimateChatRows(self.items.items[old_start..], width, self.all_expanded);

        var new_start = old_start;
        var revealed_item_rows: usize = 0;
        while (new_start > 0 and revealed_item_rows < target_rows) {
            new_start -= 1;
            revealed_item_rows +|= estimateChatItemRowsVisible(self.items.items[new_start], width, self.all_expanded);
        }
        if (new_start == old_start) return false;

        const new_total_rows = estimateChatRows(self.items.items[new_start..], width, self.all_expanded);
        const revealed_rows = new_total_rows -| old_total_rows;
        self.visible_start_index = new_start;
        self.chat_total_rows = new_total_rows;
        self.chat_scroll_max_offset = self.chat_total_rows -| self.chat_visible_rows;
        self.chat_scroll_offset = @min(self.chat_scroll_offset +| revealed_rows, self.chat_scroll_max_offset);
        return true;
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
        self.tool_output_expanded = self.all_expanded;
        const start_index = @min(self.visible_start_index, self.items.items.len);
        const total_rows = estimateChatRows(self.items.items[start_index..], @max(self.chat_width, 1), self.all_expanded);
        const max_offset = total_rows -| self.chat_visible_rows;
        self.chat_total_rows = total_rows;
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
        const was_at_tail = self.chat_scroll_offset == 0;
        if (!was_at_tail and total_chat_rows > self.chat_total_rows) {
            self.chat_scroll_offset +|= total_chat_rows - self.chat_total_rows;
        }
        self.chat_total_rows = total_chat_rows;
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
        self.all_expanded = expanded;
    }

    pub fn toggleThinkingBlockVisibility(self: *AppState) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.hide_thinking_blocks = !self.hide_thinking_blocks;
        try self.applyThinkingBlockVisibilityLocked();
        return self.hide_thinking_blocks;
    }

    pub fn setThinkingBlockVisibility(self: *AppState, hidden: bool) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.hide_thinking_blocks = hidden;
        try self.applyThinkingBlockVisibilityLocked();
    }

    pub fn setHiddenThinkingLabel(self: *AppState, label: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.replaceLabelLocked(&self.hidden_thinking_label, if (label.len > 0) label else ASSISTANT_THINKING_TEXT);
        if (self.hide_thinking_blocks) {
            try self.applyThinkingBlockVisibilityLocked();
        }
    }

    pub fn currentNowMs(self: *AppState) i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.currentNowMsLocked();
    }

    pub fn takeLastClearActionMs(self: *AppState) ?i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const value = self.last_clear_action_ms;
        self.last_clear_action_ms = null;
        return value;
    }

    pub fn setLastClearActionMs(self: *AppState, timestamp_ms: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.last_clear_action_ms = timestamp_ms;
    }

    pub fn takeLastEscapeActionMs(self: *AppState) ?i64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const value = self.last_escape_action_ms;
        self.last_escape_action_ms = null;
        return value;
    }

    pub fn setLastEscapeActionMs(self: *AppState, timestamp_ms: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.last_escape_action_ms = timestamp_ms;
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

    pub fn setExtensionFooterStatus(self: *AppState, key: []const u8, text: ?[]const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.setExtensionFooterStatusLocked(key, text);
    }

    pub fn clearExtensionFooterStatus(self: *AppState, key: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.clearExtensionFooterStatusLocked(key);
    }

    fn setExtensionFooterStatusLocked(self: *AppState, key: []const u8, text: ?[]const u8) !void {
        return extension_ui.setFooterStatus(self.allocator, &self.extension_footer_statuses, key, text);
    }

    fn clearExtensionFooterStatusLocked(self: *AppState, key: []const u8) !void {
        if (key.len == 0) return;
        if (self.extension_footer_statuses.fetchRemove(key)) |removed| {
            const clears_current_status = std.mem.eql(u8, self.status, removed.value);
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
            if (clears_current_status) try self.replaceLabelLocked(&self.status, "idle");
        }
    }

    fn setActiveOperationLocked(
        self: *AppState,
        kind: ActiveOperationKind,
        label: []const u8,
        options: ActiveOperationOptions,
    ) !void {
        const owned_label = try self.allocator.dupe(u8, label);
        const start_ms = if (self.active_operation) |operation|
            if (operation.kind == kind and std.mem.eql(u8, operation.label, label)) operation.start_ms else self.currentNowMsLocked()
        else
            self.currentNowMsLocked();
        self.clearActiveOperationLocked();
        self.active_operation = .{
            .kind = kind,
            .label = owned_label,
            .start_ms = start_ms,
            .delay_ms = options.delay_ms,
            .attempt = options.attempt,
            .max_attempts = options.max_attempts,
        };
    }

    fn clearActiveOperationLocked(self: *AppState) void {
        if (self.active_operation) |operation| {
            self.allocator.free(operation.label);
            self.active_operation = null;
        }
    }

    pub fn setWorkingMessage(self: *AppState, message: ?[]const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.replaceLabelLocked(&self.working_message, message orelse "Working...");
    }

    pub fn setWorkingVisible(self: *AppState, visible: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.working_visible = visible;
    }

    pub fn takeTerminalProgressUpdate(self: *AppState) ?bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.terminal_progress_dirty) return null;
        self.terminal_progress_dirty = false;
        return self.terminal_progress_active;
    }

    pub fn markTerminalProgress(self: *AppState, active: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.markTerminalProgressLocked(active);
    }

    pub fn handleRetryLifecycleEvent(self: *AppState, event: session_mod.RetryLifecycleEvent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.markTerminalProgressLocked(false);
        switch (event) {
            .start => |start| {
                const seconds = (start.delay_ms + 999) / 1000;
                const status_text = try std.fmt.allocPrint(
                    self.allocator,
                    "Retrying ({d}/{d}) in {d}s... (Ctrl+C to cancel)",
                    .{ start.attempt, start.max_attempts, seconds },
                );
                defer self.allocator.free(status_text);
                try self.replaceLabelLocked(&self.status, status_text);
                try self.setActiveOperationLocked(.retry, "retry", .{
                    .delay_ms = start.delay_ms,
                    .attempt = start.attempt,
                    .max_attempts = start.max_attempts,
                });
            },
            .end => |end| {
                self.clearActiveOperationLocked();
                if (end.success) {
                    try self.replaceLabelLocked(&self.status, "retry succeeded");
                } else {
                    const status_text = try std.fmt.allocPrint(
                        self.allocator,
                        "Retry failed after {d} attempts: {s}",
                        .{ end.attempt, end.final_error orelse "Unknown error" },
                    );
                    defer self.allocator.free(status_text);
                    try self.replaceLabelLocked(&self.status, status_text);
                }
            },
        }
    }

    pub fn handleCompactionLifecycleEvent(self: *AppState, event: session_mod.CompactionLifecycleEvent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        switch (event) {
            .start => |start| {
                self.markTerminalProgressLocked(true);
                const label = switch (start.reason) {
                    .manual => "Compacting context... (Ctrl+C to cancel)",
                    .threshold => "Auto-compacting... (Ctrl+C to cancel)",
                    .overflow => "Context overflow detected, auto-compacting... (Ctrl+C to cancel)",
                };
                try self.replaceLabelLocked(&self.status, label);
                const active_label = switch (start.reason) {
                    .manual => "Compacting context...",
                    .threshold => "Auto-compacting...",
                    .overflow => "Context overflow detected, auto-compacting...",
                };
                try self.setActiveOperationLocked(.compaction, active_label, .{});
            },
            .end => |end| {
                self.markTerminalProgressLocked(false);
                self.clearActiveOperationLocked();
                if (end.aborted) {
                    try self.replaceLabelLocked(&self.status, if (end.reason == .manual) "Compaction cancelled" else "Auto-compaction cancelled");
                } else if (end.error_message) |message| {
                    try self.replaceLabelLocked(&self.status, message);
                } else if (end.result) |result| {
                    const status_text = try std.fmt.allocPrint(
                        self.allocator,
                        "Compacted context ({d} tokens)",
                        .{result.tokens_before},
                    );
                    defer self.allocator.free(status_text);
                    try self.replaceLabelLocked(&self.status, status_text);
                } else {
                    try self.replaceLabelLocked(&self.status, "compaction finished");
                }
            },
        }
    }

    pub fn clearExtensionUiHooks(self: *AppState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearExtensionUiHooksLocked();
    }

    pub fn applyExtensionRegistryUi(self: *AppState, registry: *const extension_registry.Registry) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try self.replaceExtensionLinesLocked(&self.extension_header_lines, if (registry.header_hook) |hook| hook.lines else &.{});
        try self.replaceExtensionLinesLocked(&self.extension_footer_lines, if (registry.footer_hook) |hook| hook.lines else &.{});

        const next_editor_label = if (registry.editor_component_hook) |hook| hook.label else null;
        if (self.extension_editor_label) |old| {
            self.allocator.free(old);
            self.extension_editor_label = null;
        }
        if (next_editor_label) |label| {
            self.extension_editor_label = try self.allocator.dupe(u8, label);
        }

        for (self.extension_widgets.items) |*widget| widget.deinit(self.allocator);
        self.extension_widgets.clearRetainingCapacity();
        for (registry.widgets.items) |widget| {
            try self.extension_widgets.append(self.allocator, try extension_ui.cloneRegistryWidget(self.allocator, widget));
        }
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

    fn appendBashExecutionStart(
        self: *AppState,
        command: []const u8,
        exclude_from_context: bool,
    ) !usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const text = try bash_execution.formatBashExecutionDisplay(
            self.allocator,
            command,
            "",
            null,
            false,
            false,
            null,
            exclude_from_context,
            true,
        );
        defer self.allocator.free(text);

        try self.appendItemWithExpandedTextLocked(.bash_execution, text, null, null, null);
        try self.replaceLabelLocked(&self.status, "running bash");
        try self.setActiveOperationLocked(.bash_execution, command, .{});
        return self.items.items.len - 1;
    }

    fn updateBashExecution(
        self: *AppState,
        item_index: ?usize,
        command: []const u8,
        output: []const u8,
        exclude_from_context: bool,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const index = item_index orelse return;
        const text = try bash_execution.formatBashExecutionDisplayExpanded(
            self.allocator,
            command,
            output,
            null,
            false,
            false,
            null,
            exclude_from_context,
            true,
            false,
        );
        defer self.allocator.free(text);
        const expanded = try bash_execution.formatBashExecutionDisplayExpanded(
            self.allocator,
            command,
            output,
            null,
            false,
            false,
            null,
            exclude_from_context,
            true,
            true,
        );
        defer self.allocator.free(expanded);
        const expanded_text: ?[]const u8 = if (std.mem.eql(u8, text, expanded)) null else expanded;
        try self.replaceItemExpandedTextLocked(index, text, expanded_text);
        try self.replaceLabelLocked(&self.status, "running bash");
        try self.setActiveOperationLocked(.bash_execution, command, .{});
    }

    fn finishBashExecution(
        self: *AppState,
        item_index: ?usize,
        command: []const u8,
        output: []const u8,
        exit_code: ?u8,
        cancelled: bool,
        truncated: bool,
        full_output_path: ?[]const u8,
        exclude_from_context: bool,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const text = try bash_execution.formatBashExecutionDisplayExpanded(
            self.allocator,
            command,
            output,
            exit_code,
            cancelled,
            truncated,
            full_output_path,
            exclude_from_context,
            false,
            false,
        );
        defer self.allocator.free(text);
        const expanded = try bash_execution.formatBashExecutionDisplayExpanded(
            self.allocator,
            command,
            output,
            exit_code,
            cancelled,
            truncated,
            full_output_path,
            exclude_from_context,
            false,
            true,
        );
        defer self.allocator.free(expanded);
        const expanded_text: ?[]const u8 = if (std.mem.eql(u8, text, expanded)) null else expanded;
        if (item_index) |index| {
            try self.replaceItemExpandedTextLocked(index, text, expanded_text);
        } else {
            try self.appendItemWithExpandedTextLocked(.bash_execution, text, expanded_text, null, null);
        }
        self.clearActiveOperationLocked();
        try self.replaceLabelLocked(&self.status, "idle");
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

        for (self.items.items) |*item| chat_items.deinit(self.allocator, item);
        self.items.clearRetainingCapacity();
        self.visible_start_index = 0;
        self.chat_scroll_offset = 0;
        self.chat_scroll_max_offset = 0;
        self.chat_total_rows = 0;
        self.chat_visible_rows = 0;
        self.chat_width = 1;
        self.chat_region = .{};
        self.last_streaming_assistant_index = null;
        self.last_streaming_thinking_index = null;
        self.clearPendingEditorImagesLocked();
        self.clearActiveToolUpdatesLocked();
        self.clearStreamingToolCallsLocked();
        self.clearQueuedMessagesLocked();
        self.clearExtensionUiHooksLocked();
        self.clearActiveOperationLocked();
        self.markTerminalProgressLocked(false);

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
                    try self.appendToolResultItemLocked(
                        tool_result.tool_name,
                        tool_result.content,
                        tool_result.is_error,
                        tool_result.details,
                    );
                },
            }
        }
    }

    pub fn handleAgentEvent(self: *AppState, event: agent.AgentEvent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        switch (event.event_type) {
            .agent_start => {
                self.markTerminalProgressLocked(true);
                try self.replaceLabelLocked(&self.status, "thinking");
                try self.setActiveOperationLocked(.agent_wait, self.working_message, .{});
            },
            .agent_end => {
                self.markTerminalProgressLocked(false);
                self.clearActiveOperationLocked();
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
                    .user => {},
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
                            .stop, .length, .tool_use => {},
                            .aborted => try self.replaceLabelLocked(&self.status, "interrupted"),
                            .error_reason => try self.replaceLabelLocked(
                                &self.status,
                                assistant_message.error_message orelse "error",
                            ),
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
                        try self.setActiveOperationLocked(.tool_execution, tool_name, .{});
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
                try self.setActiveOperationLocked(.tool_execution, tool_name, .{});
            },
            .tool_execution_update => {
                const tool_name = event.tool_name orelse "tool";
                const status_text = try std.fmt.allocPrint(self.allocator, "working: {s}", .{tool_name});
                defer self.allocator.free(status_text);
                if (event.tool_call_id) |tool_call_id| {
                    if (event.partial_result) |partial_result| {
                        if (self.activeToolUpdateIndexLocked(tool_call_id)) |index| {
                            try self.replaceToolResultItemLocked(
                                index,
                                tool_name,
                                partial_result.content,
                                false,
                                partial_result.details,
                            );
                        } else {
                            try self.appendToolResultItemLocked(
                                tool_name,
                                partial_result.content,
                                false,
                                partial_result.details,
                            );
                            try self.setActiveToolUpdateLocked(tool_call_id, self.items.items.len - 1);
                        }
                    }
                }
                try self.replaceLabelLocked(&self.status, status_text);
                try self.setActiveOperationLocked(.tool_execution, tool_name, .{});
            },
            .tool_execution_end => {
                const tool_name = event.tool_name orelse "tool";
                const result = event.result orelse return;
                if (event.tool_call_id) |tool_call_id| {
                    if (self.takeActiveToolUpdateIndexLocked(tool_call_id)) |index| {
                        try self.replaceToolResultItemLocked(
                            index,
                            tool_name,
                            result.content,
                            event.is_error orelse false,
                            result.details,
                        );
                    } else {
                        try self.appendToolResultItemLocked(
                            tool_name,
                            result.content,
                            event.is_error orelse false,
                            result.details,
                        );
                    }
                } else {
                    try self.appendToolResultItemLocked(
                        tool_name,
                        result.content,
                        event.is_error orelse false,
                        result.details,
                    );
                }
                try self.replaceLabelLocked(&self.status, "thinking");
                try self.setActiveOperationLocked(.agent_wait, self.working_message, .{});
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
        try self.appendItemWithExpandedTextLocked(kind, text, null, null, frozen_frame_index);
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
        try self.appendItemWithExpandedTextLocked(kind, text, null, start_ms, frozen_frame_index);
    }

    fn appendItemWithExpandedTextLocked(
        self: *AppState,
        kind: ChatKind,
        text: []const u8,
        expanded_text: ?[]const u8,
        start_ms: ?i64,
        frozen_frame_index: ?usize,
    ) !void {
        const was_at_tail = self.chat_scroll_offset == 0;
        const display_text = if (kind == .thinking and self.hide_thinking_blocks) self.hidden_thinking_label else text;
        const stored_expanded_text = if (kind == .thinking and self.hide_thinking_blocks) text else expanded_text;
        const owned_text = try self.allocator.dupe(u8, display_text);
        errdefer self.allocator.free(owned_text);
        const owned_expanded_text = if (stored_expanded_text) |value|
            try self.allocator.dupe(u8, value)
        else
            null;
        errdefer if (owned_expanded_text) |value| self.allocator.free(value);
        try self.items.append(self.allocator, .{
            .kind = kind,
            .text = owned_text,
            .expanded_text = owned_expanded_text,
            .start_ms = start_ms,
            .frozen_frame_index = frozen_frame_index,
        });
        if (was_at_tail) self.chat_scroll_offset = 0;
    }

    fn appendToolResultItemLocked(
        self: *AppState,
        tool_name: []const u8,
        blocks: []const ai.ContentBlock,
        is_error: bool,
        details: ?std.json.Value,
    ) !void {
        const collapsed = try formatting.formatToolResultWithExpansion(
            self.allocator,
            tool_name,
            blocks,
            is_error,
            details,
            false,
        );
        defer self.allocator.free(collapsed);
        const expanded = try formatting.formatToolResultWithExpansion(
            self.allocator,
            tool_name,
            blocks,
            is_error,
            details,
            true,
        );
        defer self.allocator.free(expanded);
        const expanded_text: ?[]const u8 = if (std.mem.eql(u8, collapsed, expanded)) null else expanded;
        try self.appendItemWithExpandedTextLocked(.tool_result, collapsed, expanded_text, null, null);
    }

    fn currentNowMsLocked(self: *const AppState) i64 {
        return self.clock_now_ms_fn(self.clock_context);
    }

    pub fn appendToItemTextLocked(self: *AppState, index: usize, text: []const u8) !void {
        if (index >= self.items.items.len or text.len == 0) return;
        const item = &self.items.items[index];
        if (item.kind == .thinking) {
            if (item.expanded_text) |old_hidden_text| {
                const combined = try self.allocator.alloc(u8, old_hidden_text.len + text.len);
                @memcpy(combined[0..old_hidden_text.len], old_hidden_text);
                @memcpy(combined[old_hidden_text.len..], text);
                self.allocator.free(old_hidden_text);
                item.expanded_text = combined;
                return;
            }
        }
        const old = item.text;
        const combined = try self.allocator.alloc(u8, old.len + text.len);
        @memcpy(combined[0..old.len], old);
        @memcpy(combined[old.len..], text);
        self.allocator.free(old);
        item.text = combined;
    }

    pub fn replaceItemTextLocked(self: *AppState, index: usize, text: []const u8) !void {
        if (index >= self.items.items.len) return;
        try self.replaceItemExpandedTextLocked(index, text, null);
    }

    fn replaceToolResultItemLocked(
        self: *AppState,
        index: usize,
        tool_name: []const u8,
        blocks: []const ai.ContentBlock,
        is_error: bool,
        details: ?std.json.Value,
    ) !void {
        const collapsed = try formatting.formatToolResultWithExpansion(
            self.allocator,
            tool_name,
            blocks,
            is_error,
            details,
            false,
        );
        defer self.allocator.free(collapsed);
        const expanded = try formatting.formatToolResultWithExpansion(
            self.allocator,
            tool_name,
            blocks,
            is_error,
            details,
            true,
        );
        defer self.allocator.free(expanded);
        const expanded_text: ?[]const u8 = if (std.mem.eql(u8, collapsed, expanded)) null else expanded;
        try self.replaceItemExpandedTextLocked(index, collapsed, expanded_text);
    }

    fn replaceItemExpandedTextLocked(self: *AppState, index: usize, text: []const u8, expanded_text: ?[]const u8) !void {
        if (index >= self.items.items.len) return;
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const owned_expanded_text = if (expanded_text) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_expanded_text) |value| self.allocator.free(value);

        self.allocator.free(self.items.items[index].text);
        if (self.items.items[index].expanded_text) |value| self.allocator.free(value);
        self.items.items[index].text = owned_text;
        self.items.items[index].expanded_text = owned_expanded_text;
    }

    pub fn removeItemLocked(self: *AppState, index: usize) void {
        if (index >= self.items.items.len) return;
        chat_items.deinit(self.allocator, &self.items.items[index]);
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

    fn replaceExtensionLinesLocked(self: *AppState, field: *[][]u8, lines: []const []const u8) !void {
        deinitOwnedStringList(self.allocator, field.*);
        field.* = try cloneConstStringList(self.allocator, lines);
    }

    fn clearExtensionUiHooksLocked(self: *AppState) void {
        deinitOwnedStringList(self.allocator, self.extension_header_lines);
        self.extension_header_lines = &.{};
        deinitOwnedStringList(self.allocator, self.extension_footer_lines);
        self.extension_footer_lines = &.{};
        if (self.extension_editor_label) |label| self.allocator.free(label);
        self.extension_editor_label = null;
        for (self.extension_widgets.items) |*widget| widget.deinit(self.allocator);
        self.extension_widgets.clearRetainingCapacity();
        extension_ui.clearFooterStatuses(self.allocator, &self.extension_footer_statuses);
        self.working_visible = true;
        self.replaceLabelLocked(&self.working_message, "Working...") catch {};
    }

    fn applyThinkingBlockVisibilityLocked(self: *AppState) !void {
        for (self.items.items) |*item| {
            if (item.kind != .thinking) continue;
            if (self.hide_thinking_blocks) {
                if (item.expanded_text != null) {
                    self.allocator.free(item.text);
                    item.text = try self.allocator.dupe(u8, self.hidden_thinking_label);
                    continue;
                }
                const original = item.text;
                item.text = try self.allocator.dupe(u8, self.hidden_thinking_label);
                item.expanded_text = original;
            } else if (item.expanded_text) |original| {
                self.allocator.free(item.text);
                item.text = original;
                item.expanded_text = null;
            }
        }
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
            pending_editor_images_mod.deinit(self.allocator, image);
        }
        self.pending_editor_images.clearRetainingCapacity();
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

    fn markTerminalProgressLocked(self: *AppState, active: bool) void {
        if (self.terminal_progress_active == active and self.terminal_progress_dirty) return;
        if (self.terminal_progress_active != active or !self.terminal_progress_dirty) {
            self.terminal_progress_active = active;
            self.terminal_progress_dirty = true;
        }
    }
};

fn bashTaskHooks(state: *AppState) user_bash_task_mod.Hooks {
    return .{
        .allocator = state.allocator,
        .io = state.io,
        .context = state,
        .append_start = bashAppendStartHook,
        .update = bashUpdateHook,
        .finish = bashFinishHook,
        .set_status = bashSetStatusHook,
        .append_error = bashAppendErrorHook,
    };
}

fn bashAppendStartHook(context: *anyopaque, command: []const u8, exclude_from_context: bool) anyerror!usize {
    const state: *AppState = @ptrCast(@alignCast(context));
    return state.appendBashExecutionStart(command, exclude_from_context);
}

fn bashUpdateHook(
    context: *anyopaque,
    item_index: ?usize,
    command: []const u8,
    output: []const u8,
    exclude_from_context: bool,
) anyerror!void {
    const state: *AppState = @ptrCast(@alignCast(context));
    try state.updateBashExecution(item_index, command, output, exclude_from_context);
}

fn bashFinishHook(
    context: *anyopaque,
    item_index: ?usize,
    command: []const u8,
    output: []const u8,
    exit_code: ?u8,
    cancelled: bool,
    truncated: bool,
    full_output_path: ?[]const u8,
    exclude_from_context: bool,
) anyerror!void {
    const state: *AppState = @ptrCast(@alignCast(context));
    try state.finishBashExecution(
        item_index,
        command,
        output,
        exit_code,
        cancelled,
        truncated,
        full_output_path,
        exclude_from_context,
    );
}

fn bashSetStatusHook(context: *anyopaque, text: []const u8) anyerror!void {
    const state: *AppState = @ptrCast(@alignCast(context));
    try state.setStatus(text);
}

fn bashAppendErrorHook(context: *anyopaque, text: []const u8) anyerror!void {
    const state: *AppState = @ptrCast(@alignCast(context));
    try state.appendError(text);
}

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

    pub fn drawComponent(self: *const ScreenComponent) tui.DrawComponent {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
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
        self.editor.setEditorStyle(if (self.theme) |t| tui.styleFor(t, .editor) else .{});
        window.clear();

        var snapshot = try self.state.snapshotForRender(ctx.arena);

        if (self.after_snapshot_hook) |hook| hook.run();

        const width = @max(@as(usize, window.width), 1);
        const footer_text = if (snapshot.extension_footer_lines.len > 0)
            try formatExtensionFooterLineWithTerminal(ctx.arena, null, &snapshot, self.terminal_name, width)
        else
            try formatFooterTextForDisplay(ctx.arena, self.keybindings, &snapshot, width, self.now_ms);
        const extension_header_height = snapshot.extension_header_lines.len;
        const extension_above_height = extensionWidgetLineCount(snapshot.extension_widgets, .above_editor);
        const extension_editor_height: usize = if (snapshot.extension_editor_label != null) 1 else 0;
        const extension_below_height = extensionWidgetLineCount(snapshot.extension_widgets, .below_editor);
        const core_prompt_height = try measurePromptHeight(
            ctx.arena,
            self.theme,
            self.editor,
            snapshot.pending_editor_images,
            width,
        );
        const prompt_height = core_prompt_height + extension_above_height + extension_editor_height + extension_below_height;
        const queued_height = try measureQueuedMessagesHeight(ctx.arena, self.keybindings, self.theme, &snapshot, width);
        const autocomplete_height = try measureAutocompleteHeight(ctx.arena, self.theme, self.editor, width);
        const task_panel_height = taskPanelHeightForWidth(width);
        const scroll_indicator_height: usize = if (snapshot.chat_scroll_offset > 0) 1 else 0;
        const reserved_lines: usize = task_panel_height + extension_header_height + prompt_height + queued_height + 1 + autocomplete_height + scroll_indicator_height;
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
            }, self.keybindings, self.theme, &snapshot, self.now_ms);
        }
        row += task_panel_height;

        if (extension_header_height > 0 and row < window.height) {
            row += drawExtensionHeaderLines(window, row, snapshot.extension_header_lines, self.theme);
        }

        const sel_range: ?chat_rendering.SelectionRange = if (self.state.hasSelection()) blk: {
            const sr = self.state.getSelectionRange().?;
            break :blk .{
                .start_row = sr.start_row,
                .start_col = sr.start_col,
                .end_row = sr.end_row,
                .end_col = sr.end_col,
            };
        } else null;
        var selected_text = std.ArrayList(u8).empty;
        defer selected_text.deinit(ctx.arena);
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
            sel_range,
            if (self.state.hasSelection()) &selected_text else null,
        );
        if (!self.state.selection_active and self.state.hasSelection() and selected_text.items.len > 0) {
            copySelectedText(ctx.arena, self.state.io, selected_text.items);
            self.state.clearSelection();
        }
        self.state.updateChatScrollLayout(chat_metrics.rendered_height, chat_metrics.visible_height, row, width);
        row += chat_capacity;

        if (snapshot.chat_scroll_offset > 0 and row < window.height) {
            self.state.scroll_indicator_row = row;
            const indicator_text = " \xe2\x86\x91 scrolled  \xe2\x86\x93 Jump to bottom (Ctrl+End) ";
            const indicator_style = styleForToken(self.theme, .status);
            const indicator_window = window.child(.{
                .y_off = @intCast(row),
                .height = 1,
            });
            indicator_window.fill(.{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = indicator_style,
            });
            const text_width = std.unicode.utf8CountCodepoints(indicator_text) catch indicator_text.len;
            const x_center: usize = if (width > text_width) (width - text_width) / 2 else 0;
            _ = indicator_window.printSegment(.{
                .text = indicator_text,
                .style = indicator_style,
            }, .{ .col_offset = @intCast(x_center), .wrap = .none });
            row += 1;
        } else {
            self.state.scroll_indicator_row = null;
        }

        if (queued_height > 0 and row < window.height) {
            const queued_window = window.child(.{
                .y_off = @intCast(row),
                .height = @intCast(@min(queued_height, @as(usize, window.height) - row)),
            });
            _ = try drawQueuedMessages(queued_window, .{
                .window = queued_window,
                .arena = ctx.arena,
            }, self.keybindings, self.theme, &snapshot);
        }
        row += queued_height;

        const prompt_start_row = row + extension_above_height + extension_editor_height;
        if (extension_above_height > 0 and row < window.height) {
            row += drawExtensionWidgetLines(window, row, snapshot.extension_widgets, .above_editor, self.theme);
        }
        if (snapshot.extension_editor_label) |label| {
            if (row < window.height) {
                const editor_label = try std.fmt.allocPrint(ctx.arena, "Extension editor: {s}", .{label});
                drawFittedLine(window, row, editor_label, styleForToken(self.theme, .status));
            }
            row += 1;
        }
        if (row < window.height) {
            const prompt_window = window.child(.{
                .y_off = @intCast(row),
                .height = @intCast(@min(core_prompt_height, @as(usize, window.height) - row)),
            });
            _ = try drawPromptLines(
                prompt_window,
                .{ .window = prompt_window, .arena = ctx.arena },
                self.theme,
                self.editor,
                snapshot.pending_editor_images,
            );
        }
        row += core_prompt_height;
        if (extension_below_height > 0 and row < window.height) {
            row += drawExtensionWidgetLines(window, row, snapshot.extension_widgets, .below_editor, self.theme);
        }

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
            });
        }
        row += autocomplete_height;

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

pub fn renderScreenToLines(allocator: std.mem.Allocator, screen: *const ScreenComponent, width: usize) ![]const []const u8 {
    var vscreen = try tui.vaxis.Screen.init(allocator, .{
        .rows = @intCast(@max(screen.height, 1)),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer vscreen.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const window = tui.draw.rootWindow(&vscreen);
    window.clear();
    _ = try screen.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });

    var lines = std.ArrayList([]const u8).empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    for (0..screen.height) |row| {
        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);
        var col: usize = 0;
        while (col < width) {
            const cell = vscreen.readCell(@intCast(col), @intCast(row)) orelse break;
            if (cell.char.grapheme.len > 0) {
                try builder.appendSlice(allocator, cell.char.grapheme);
                col += if (cell.char.width > 0) @as(usize, cell.char.width) else 1;
            } else {
                try builder.append(allocator, ' ');
                col += 1;
            }
        }
        try lines.append(allocator, try builder.toOwnedSlice(allocator));
    }
    return lines.toOwnedSlice(allocator);
}

fn styleForToken(theme: ?*const resources_mod.Theme, token: resources_mod.ThemeToken) tui.vaxis.Cell.Style {
    return if (theme) |active_theme| tui.styleFor(active_theme, token) else .{};
}

fn copySelectedText(allocator: std.mem.Allocator, io: std.Io, text: []const u8) void {
    if (text.len == 0) return;
    const owned = allocator.dupe(u8, text) catch return;
    defer allocator.free(owned);
    slash_commands.copyTextToClipboard(io, owned) catch {};
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

fn extensionWidgetLineCount(widgets: []const ExtensionWidget, placement: ExtensionWidgetPlacement) usize {
    var count: usize = 0;
    for (widgets) |widget| {
        if (widget.placement != placement) continue;
        count += @max(widget.lines.len, 1);
    }
    return count;
}

fn drawExtensionHeaderLines(
    window: tui.vaxis.Window,
    start_row: usize,
    lines: []const []const u8,
    theme: ?*const resources_mod.Theme,
) usize {
    var row = start_row;
    for (lines) |line| {
        if (row >= window.height) return row - start_row;
        drawFittedLine(window, row, line, styleForToken(theme, .status));
        row += 1;
    }
    return row - start_row;
}

fn drawExtensionWidgetLines(
    window: tui.vaxis.Window,
    start_row: usize,
    widgets: []const ExtensionWidget,
    placement: ExtensionWidgetPlacement,
    theme: ?*const resources_mod.Theme,
) usize {
    var row = start_row;
    for (widgets) |widget| {
        if (widget.placement != placement) continue;
        for (widget.lines) |line| {
            if (row >= window.height) return row - start_row;
            drawFittedLine(window, row, line, styleForToken(theme, .status));
            row += 1;
        }
    }
    return row - start_row;
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
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    now_ms: i64,
) !tui.DrawSize {
    const outer_width = @as(usize, window.width);
    const requested_height = taskPanelHeightForWidth(outer_width);

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

    if (panel_inner.width > 0 and panel_inner.height > 0) {
        const content_width = @as(usize, panel_inner.width);
        const content = try formatTaskHeaderTextForDisplay(
            ctx.arena,
            keybindings,
            snapshot,
            content_width,
            layoutMode(outer_width),

            now_ms,
        );
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

fn measurePromptHeight(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    pending_images: []const PendingEditorImage,
    width: usize,
) !usize {
    return prompt_rendering.measureHeight(allocator, theme, editor, pending_images, width);
}

fn drawPromptLines(
    window: tui.vaxis.Window,
    ctx: tui.DrawContext,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    pending_images: []const PendingEditorImage,
) !tui.DrawSize {
    return prompt_rendering.drawLines(window, ctx, theme, editor, pending_images);
}

fn measureAutocompleteHeight(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    editor: *tui.Editor,
    width: usize,
) !usize {
    _ = theme;
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
    const dequeue_label = try actionLabel(ctx.arena, keybindings, .message_dequeue, "Alt+Up");
    const hint = try std.fmt.allocPrint(ctx.arena, "↳ {s} to edit queued messages", .{dequeue_label});
    row += drawWrappedText(window, row, hint, status_style);
    return .{
        .width = window.width,
        .height = @intCast(@min(row, @as(usize, window.height))),
    };
}

const ChatViewportMetrics = chat_rendering.ViewportMetrics;

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
    selection: ?chat_rendering.SelectionRange,
    selected_text_out: ?*std.ArrayList(u8),
) !ChatViewportMetrics {
    return chat_rendering.drawViewport(allocator, keybindings, theme, items, window, start_row, height, chat_scroll_offset, now_ms, all_expanded, selection, selected_text_out);
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
    return chat_rendering.drawItems(window, allocator, keybindings, theme, items, now_ms, all_expanded);
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
    return chat_rendering.drawItem(window, allocator, keybindings, theme, item, start_row, now_ms, all_expanded);
}

fn previewThreshold(kind: ChatKind) ?usize {
    return chat_rendering.previewThreshold(kind);
}

fn thinkingFrameIndex(item: ChatItem, now_ms: i64) usize {
    return chat_rendering.thinkingFrameIndex(item, now_ms);
}

fn chatToken(kind: ChatKind) resources_mod.ThemeToken {
    return chat_rendering.token(kind);
}

fn estimateChatRows(items: []const ChatItem, width: usize, all_expanded: bool) usize {
    return chat_rendering.estimateRows(items, width, all_expanded);
}

fn estimateChatItemRowsVisible(item: ChatItem, width: usize, all_expanded: bool) usize {
    return chat_rendering.estimateItemRowsVisible(item, width, all_expanded);
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

    pub fn component(self: *const BorrowedLineListComponent) tui.draw.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: tui.vaxis.Window,
        ctx: tui.draw.DrawContext,
    ) std.mem.Allocator.Error!tui.draw.Size {
        const self: *const BorrowedLineListComponent = @ptrCast(@alignCast(ptr));
        const row_count = @min(self.lines.len, @as(usize, window.height));
        for (self.lines[0..row_count], 0..) |line, row_index| {
            const fitted = try fitLine(ctx.arena, line, window.width);
            defer ctx.arena.free(fitted);
            const row_window = window.child(.{
                .y_off = @intCast(row_index),
                .height = 1,
            });
            _ = row_window.printSegment(.{ .text = fitted }, .{ .wrap = .none });
        }
        return .{ .width = window.width, .height = @intCast(row_count) };
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

    pub fn drawComponent(self: *const OverlayPanelComponent) tui.DrawComponent {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    fn drawOverlayTable(
        overlay: anytype,
        list_window: tui.vaxis.Window,
        ctx: tui.DrawContext,
        theme: ?*const resources_mod.Theme,
        highlight_style: tui.vaxis.Cell.Style,
    ) std.mem.Allocator.Error!tui.DrawSize {
        _ = theme;
        overlay.table_state.selected_index = overlay.list.selectedIndex();
        var table = tui.Table{
            .rows = overlay.table_rows,
            .widths = overlay.table_widths,
            .row_highlight_style = highlight_style,
            .show_scrollbar = true,
        };
        return try table.draw(list_window, .{
            .window = list_window,
            .arena = ctx.arena,
        }, &overlay.table_state);
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
                settings_editor.editor.setEditorStyle(if (self.theme) |t| tui.styleFor(t, .editor) else .{});
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
                    });
                    row += @as(usize, size.height);
                }
            },
            .extension_dialog => |*dialog| {
                if (dialog.message.len > 0) {
                    drawFittedLine(content_window, row, dialog.message, styleForToken(self.theme, .text));
                    row += 2;
                }
                if (row < content_window.height) {
                    switch (dialog.kind) {
                        .select, .confirm => {
                            dialog.list.max_visible = @max(@as(usize, 1), @min(self.max_height, @as(usize, content_window.height) - row));
                            dialog.list.show_scrollbar = true;
                            const list_window = content_window.child(.{
                                .y_off = @intCast(row),
                                .height = content_window.height - @as(u16, @intCast(row)),
                            });
                            const size = try dialog.list.draw(list_window, .{
                                .window = list_window,
                                .arena = ctx.arena,
                            });
                            row += @as(usize, size.height);
                        },
                        .input, .editor => {
                            dialog.editor.setEditorStyle(if (self.theme) |t| tui.styleFor(t, .editor) else .{});
                            const editor_window = content_window.child(.{
                                .y_off = @intCast(row),
                                .height = content_window.height - @as(u16, @intCast(row)),
                            });
                            const size = try dialog.editor.draw(editor_window, .{
                                .window = editor_window,
                                .arena = ctx.arena,
                            });
                            row += @as(usize, size.height);
                        },
                    }
                }
            },
            else => {
                if (row < content_window.height) {
                    const has_table = switch (self.overlay.*) {
                        .info => |*o| o.table_rows.len > 0,
                        .settings => |*o| o.table_rows.len > 0,
                        .session => |*o| o.table_rows.len > 0,
                        .model => |*o| o.table_rows.len > 0,
                        .scoped_models => |*o| o.table_rows.len > 0,
                        .theme => |*o| o.table_rows.len > 0,
                        .tree => |*o| o.table_rows.len > 0,
                        .fork => |*o| o.table_rows.len > 0,
                        .auth => |*o| o.table_rows.len > 0,
                        else => false,
                    };
                    const list_window = content_window.child(.{
                        .y_off = @intCast(row),
                        .height = content_window.height - @as(u16, @intCast(row)),
                    });
                    if (has_table) {
                        const highlight_style = styleForToken(self.theme, .select_selected);
                        switch (self.overlay.*) {
                            .info => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .settings => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .session => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .model => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .scoped_models => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .theme => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .tree => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .fork => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            .auth => |*o| row += @as(usize, (try OverlayPanelComponent.drawOverlayTable(o, list_window, ctx, self.theme, highlight_style)).height),
                            else => unreachable,
                        }
                    } else {
                        const overlay_list = switch (self.overlay.*) {
                            .info => |*info_overlay| &info_overlay.list,
                            .settings => |*settings_overlay| &settings_overlay.list,
                            .session => |*session_overlay| &session_overlay.list,
                            .model => |*model_overlay| &model_overlay.list,
                            .scoped_models => |*scoped_models_overlay| &scoped_models_overlay.list,
                            .theme => |*theme_overlay| &theme_overlay.list,
                            .tree => |*tree_overlay| &tree_overlay.list,
                            .fork => |*fork_overlay| &fork_overlay.list,
                            .auth => |*auth_overlay| &auth_overlay.list,
                            else => unreachable,
                        };
                        
                        overlay_list.max_visible = @max(@as(usize, 1), @min(self.max_height, @as(usize, content_window.height) - row));
                        const size = try overlay_list.draw(list_window, .{
                            .window = list_window,
                            .arena = ctx.arena,
                        });
                        row += @as(usize, size.height);
                    }
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

pub const overlayPanelMaxHeight = overlay_panel.maxHeight;
pub const overlayPanelWidth = overlay_panel.width;
pub const overlayAnimationProgress = overlay_panel.animationProgress;
pub const nowMilliseconds = overlay_panel.nowMilliseconds;
pub const overlayPanelOptions = overlay_panel.options;
pub const resolveGitBranch = git_status.resolveGitBranch;
pub const findGitRoot = git_status.findGitRoot;
pub const resolveGitDirectory = git_status.resolveGitDirectory;
pub const parseGitHeadBranch = git_status.parseGitHeadBranch;

fn systemNowMilliseconds(_: ?*anyopaque) i64 {
    return nowMilliseconds();
}

pub fn rebuildAppStateFromSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    app_state: *AppState,
    session: *const session_mod.AgentSession,
    current_provider: ?*const provider_config.ResolvedProviderConfig,
) !void {
    const git_branch = try git_status.resolveGitBranch(allocator, io, session.cwd);
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
    const git_branch = try git_status.resolveGitBranch(allocator, io, session.cwd);
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

pub fn parseEnvSize(value: ?[]const u8) ?usize {
    const text = value orelse return null;
    return std.fmt.parseInt(usize, text, 10) catch null;
}

pub fn freeLinesSlice(allocator: std.mem.Allocator, lines: []const []const u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

pub const INPUT_PROMPT_PREFIX = render_text.INPUT_PROMPT_PREFIX;
const TOP_PANEL_HEIGHT = render_text.TOP_PANEL_HEIGHT;
const PROMPT_BORDER_TOP_ROWS = render_text.PROMPT_BORDER_TOP_ROWS;
const LayoutMode = render_text.LayoutMode;
const layoutMode = render_text.layoutMode;
const taskPanelHeightForWidth = render_text.taskPanelHeightForWidth;
const hintsHeightForWidth = render_text.hintsHeightForWidth;
const promptEditorWidth = render_text.promptEditorWidth;
const promptEditorOffsetX = render_text.promptEditorOffsetX;
const promptEditorOffsetY = render_text.promptEditorOffsetY;
pub fn formatFooterLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    width: usize,
) ![]u8 {
    return render_text.formatFooterLine(allocator, theme, snapshot, width);
}

pub fn formatFooterLineWithTerminal(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    terminal_name: []const u8,
    width: usize,
) ![]u8 {
    return render_text.formatFooterLineWithTerminal(allocator, theme, snapshot, terminal_name, width);
}

fn formatFooterLineWithTerminalForDisplay(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    terminal_name: []const u8,
    width: usize,
    now_ms: i64,
) ![]u8 {
    const active_status = try active_operation_rendering.formatStatus(allocator, keybindings, snapshot.active_operation, now_ms) orelse
        return render_text.formatFooterLineWithTerminal(allocator, theme, snapshot, terminal_name, width);
    defer allocator.free(active_status);

    var display_snapshot = snapshot.*;
    display_snapshot.status = active_status;
    return render_text.formatFooterLineWithTerminal(allocator, theme, &display_snapshot, terminal_name, width);
}

fn formatFooterTextForDisplay(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    snapshot: *const RenderStateSnapshot,
    width: usize,
    now_ms: i64,
) ![]u8 {
    const active_status = try active_operation_rendering.formatStatus(allocator, keybindings, snapshot.active_operation, now_ms) orelse
        return render_text.formatFooterText(allocator, snapshot, width);
    defer allocator.free(active_status);

    var display_snapshot = snapshot.*;
    display_snapshot.status = active_status;
    return render_text.formatFooterText(allocator, &display_snapshot, width);
}

pub fn formatExtensionFooterLineWithTerminal(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    snapshot: *const RenderStateSnapshot,
    terminal_name: []const u8,
    width: usize,
) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);
    if (snapshot.extension_footer_lines.len > 0) {
        try builder.appendSlice(allocator, snapshot.extension_footer_lines[0]);
    }
    for (snapshot.extension_footer_statuses) |status| {
        if (status.len == 0) continue;
        if (builder.items.len > 0) try builder.appendSlice(allocator, " • ");
        try builder.appendSlice(allocator, status);
    }
    if (builder.items.len == 0) {
        return render_text.formatFooterLineWithTerminal(allocator, theme, snapshot, terminal_name, width);
    }
    const fitted = try fitLine(allocator, builder.items, width);
    defer allocator.free(fitted);
    return try applyThemeAlloc(allocator, theme, .footer, fitted);
}

pub fn formatTaskHeaderText(
    allocator: std.mem.Allocator,
    snapshot: *const RenderStateSnapshot,
    width: usize,
) ![]u8 {
    return render_text.formatTaskHeaderText(allocator, snapshot, width);
}

fn formatTaskHeaderTextForMode(
    allocator: std.mem.Allocator,
    snapshot: *const RenderStateSnapshot,
    width: usize,
    mode: LayoutMode,
) ![]u8 {
    return render_text.formatTaskHeaderTextForMode(allocator, snapshot, width, mode);
}

fn formatTaskHeaderTextForDisplay(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    snapshot: *const RenderStateSnapshot,
    width: usize,
    mode: LayoutMode,
    now_ms: i64,
) ![]u8 {
    const active_status = try active_operation_rendering.formatStatus(allocator, keybindings, snapshot.active_operation, now_ms) orelse
        return render_text.formatTaskHeaderTextForMode(allocator, snapshot, width, mode);
    defer allocator.free(active_status);

    var display_snapshot = snapshot.*;
    display_snapshot.status = active_status;
    return render_text.formatTaskHeaderTextForMode(allocator, &display_snapshot, width, mode);
}

pub fn formatFooterText(allocator: std.mem.Allocator, snapshot: *const RenderStateSnapshot, width: usize) ![]u8 {
    return render_text.formatFooterText(allocator, snapshot, width);
}

pub fn formatFooterTextWithTerminal(
    allocator: std.mem.Allocator,
    snapshot: *const RenderStateSnapshot,
    terminal_name: []const u8,
    width: usize,
) ![]u8 {
    return render_text.formatFooterTextWithTerminal(allocator, snapshot, terminal_name, width);
}

pub fn appendFooterPart(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    needs_separator: *bool,
    text: []const u8,
) std.mem.Allocator.Error!void {
    return render_text.appendFooterPart(allocator, builder, needs_separator, text);
}

pub fn formatCompactTokenCount(allocator: std.mem.Allocator, count: u64) ![]u8 {
    return render_text.formatCompactTokenCount(allocator, count);
}

pub fn formatHintsLine(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    width: usize,
) ![]u8 {
    return render_text.formatHintsLine(allocator, keybindings, theme, width);
}

pub fn formatHintsText(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    width: usize,
) ![]u8 {
    return render_text.formatHintsText(allocator, keybindings, width);
}

pub fn actionLabel(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    action: keybindings_mod.Action,
    fallback: []const u8,
) ![]u8 {
    return render_text.actionLabel(allocator, keybindings, action, fallback);
}

pub fn applyThemeAlloc(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    token: resources_mod.ThemeToken,
    text: []const u8,
) ![]u8 {
    return render_text.applyThemeAlloc(allocator, theme, token, text);
}

pub fn fitLine(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]u8 {
    return render_text.fitLine(allocator, text, width);
}

fn formatTerminalBadge(allocator: std.mem.Allocator, terminal_name: []const u8) ![]u8 {
    return render_text.formatTerminalBadge(allocator, terminal_name);
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
        .bash_execution => .role_tool_result,
    }, item.text);
}

pub fn renderChatItemInto(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
) ![]const []const u8 {
    return renderChatItemIntoAt(allocator, width, theme, item, 0);
}

pub fn renderChatItemIntoAt(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    now_ms: i64,
) ![]const []const u8 {
    return renderChatItemIntoWithOptions(allocator, width, null, theme, item, now_ms, true);
}

pub fn visibleChatTextAlloc(
    allocator: std.mem.Allocator,
    app_state: *const AppState,
) ![]u8 {
    var snapshot = try app_state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);

    const width = @max(snapshot.chat_width, 1);
    var all_lines = std.ArrayList([]const u8).empty;
    defer {
        for (all_lines.items) |line| allocator.free(line);
        all_lines.deinit(allocator);
    }
    for (snapshot.items) |item| {
        const lines = try renderChatItemIntoWithOptions(
            allocator,
            width,
            null,
            null,
            item,
            0,
            snapshot.all_expanded,
        );
        errdefer {
            for (lines) |line| allocator.free(line);
            allocator.free(lines);
        }
        try all_lines.appendSlice(allocator, lines);
        allocator.free(lines);
    }

    const visible_rows = if (snapshot.chat_visible_rows == 0) all_lines.items.len else snapshot.chat_visible_rows;
    const max_offset = all_lines.items.len -| visible_rows;
    const offset = @min(snapshot.chat_scroll_offset, max_offset);
    const start = max_offset -| offset;
    const end = @min(start + visible_rows, all_lines.items.len);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    for (all_lines.items[start..end], 0..) |line, index| {
        if (index > 0) try writer.writer.writeAll("\n");
        try writer.writer.writeAll(std.mem.trim(u8, line, " "));
    }
    return try allocator.dupe(u8, std.mem.trim(u8, writer.written(), "\n"));
}

fn renderChatItemIntoWithOptions(
    allocator: std.mem.Allocator,
    width: usize,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    now_ms: i64,
    all_expanded: bool,
) ![]const []const u8 {
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
    return tui.cell_rows.screenRowsToLinesAlloc(allocator, &screen, width, rendered);
}

pub fn renderAssistantChatItemInto(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    text: []const u8,
) ![]const []const u8 {
    return renderChatItemInto(allocator, width, theme, .{ .kind = .assistant, .text = @constCast(text) });
}

pub fn renderMarkdownChatItemInto(
    allocator: std.mem.Allocator,
    width: usize,
    theme: ?*const resources_mod.Theme,
    text: []const u8,
) ![]const []const u8 {
    return renderChatItemInto(allocator, width, theme, .{ .kind = .markdown, .text = @constCast(text) });
}

pub fn handleAppAgentEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const app_state: *AppState = @ptrCast(@alignCast(context.?));
    try app_state.handleAgentEvent(event);
}

pub fn handleAppRetryLifecycleEvent(context: ?*anyopaque, event: session_mod.RetryLifecycleEvent) !void {
    const app_state: *AppState = @ptrCast(@alignCast(context.?));
    try app_state.handleRetryLifecycleEvent(event);
}

pub fn handleAppCompactionLifecycleEvent(context: ?*anyopaque, event: session_mod.CompactionLifecycleEvent) !void {
    const app_state: *AppState = @ptrCast(@alignCast(context.?));
    try app_state.handleCompactionLifecycleEvent(event);
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

fn cloneConstStringList(allocator: std.mem.Allocator, items: []const []const u8) ![][]u8 {
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

test "prompt m2 renders compact footer with terminal badge" {
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

    try std.testing.expect(std.mem.indexOf(u8, rendered, "⏎ send · Alt+⏎ follow-up") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Alt+Up dequeue") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Ctrl+L models") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "GHOSTTY") != null);

    const prompt_top = screen.readCell(0, 10) orelse return error.TestUnexpectedResult;
    const footer_first = screen.readCell(0, 13) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("╭", prompt_top.char.grapheme);
    try std.testing.expectEqualStrings("B", footer_first.char.grapheme);

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
    const dark_glyph = dark_screen.readCell(1, 11) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(">", dark_glyph.char.grapheme);
    try std.testing.expectEqual(styleForToken(&dark, .prompt_glyph), dark_glyph.style);

    const dark_text = try tui.test_helpers.screenToString(&dark_screen);
    defer allocator.free(dark_text);

    screen_component.theme = &codex;
    var codex_screen = try tui.test_helpers.renderToScreen(screen_component.drawComponent(), 100, 14);
    defer codex_screen.deinit(std.testing.allocator);
    const codex_glyph = codex_screen.readCell(1, 11) orelse return error.TestUnexpectedResult;
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
) ![]const []const u8 {
    var terminal = tui.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var rendered = try tui.test_helpers.renderToScreen(screen.drawComponent(), backend.size.width, backend.size.height);
    defer rendered.deinit(std.testing.allocator);

    return tui.cell_rows.allocatingScreenRowsToLinesAlloc(allocator, &rendered, backend.size.width, backend.size.height);
}

pub fn renderScreenWithMockBackendAndOverlay(
    allocator: std.mem.Allocator,
    screen: *const ScreenComponent,
    overlay: *SelectorOverlay,
    backend: *InteractiveModeTestBackend,
) ![]const []const u8 {
    var terminal = tui.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = tui.Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    const panel = OverlayPanelComponent{
        .overlay = overlay,
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

    return tui.cell_rows.allocatingScreenRowsToLinesAlloc(allocator, &vx.screen_last, backend.size.width, backend.size.height);
}

pub fn renderedLinesContain(lines: []const []const u8, needle: []const u8) bool {
    for (lines) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

fn countChatKind(items: []const ChatItem, kind: ChatKind) usize {
    var count: usize = 0;
    for (items) |item| {
        if (item.kind == kind) count += 1;
    }
    return count;
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

    state.chatScrollPageUp();
    try std.testing.expectEqual(@as(usize, 9), state.chat_scroll_offset);
    state.chatScrollPageUp();
    state.chatScrollPageUp();
    try std.testing.expectEqual(@as(usize, 20), state.chat_scroll_offset);
    state.chatScrollPageDown();
    try std.testing.expectEqual(@as(usize, 11), state.chat_scroll_offset);
    state.chatScrollPageDown();
    state.chatScrollPageDown();
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);
}

test "chat scroll tail clear auto-follow append preservation and resize clamp state" {
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

    state.updateChatScrollLayout(35, 10, 3, 80);
    try std.testing.expectEqual(@as(usize, 13), state.chat_scroll_offset);

    state.updateChatScrollLayout(30, 25, 3, 80);
    try std.testing.expectEqual(@as(usize, 5), state.chat_scroll_offset);

    state.chat_scroll_offset = 0;
    state.updateChatScrollLayout(40, 25, 3, 80);
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    state.clearDisplay();
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);

    state.updateChatScrollLayout(5, 10, 3, 80);
    state.handleChatMouseWheel(.{ .direction = .up, .row = 5, .col = 10 });
    try std.testing.expectEqual(@as(usize, 0), state.chat_scroll_offset);
}

test "chat scroll page up at top reveals older hidden items and preserves anchor" {
    const allocator = std.testing.allocator;
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    for (0..10) |index| {
        const text = try std.fmt.allocPrint(allocator, "item {d}", .{index});
        defer allocator.free(text);
        try state.appendItemLocked(.info, text);
    }

    state.visible_start_index = 5;
    const old_total_rows = estimateChatRows(state.items.items[state.visible_start_index..], 80, state.all_expanded);
    state.updateChatScrollLayout(old_total_rows, 4, 3, 80);
    state.chat_scroll_offset = state.chat_scroll_max_offset;
    const old_offset = state.chat_scroll_offset;

    state.chatScrollPageUp();

    try std.testing.expectEqual(@as(usize, 2), state.visible_start_index);
    try std.testing.expectEqual(old_offset + 3, state.chat_scroll_offset);
    try std.testing.expectEqual(state.chat_scroll_max_offset, state.chat_scroll_offset);
}

test "chat scroll wheel at top reveals one notch of older hidden items and preserves anchor" {
    const allocator = std.testing.allocator;
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    for (0..5) |index| {
        const text = try std.fmt.allocPrint(allocator, "item {d}", .{index});
        defer allocator.free(text);
        try state.appendItemLocked(.info, text);
    }

    state.visible_start_index = 4;
    const old_total_rows = estimateChatRows(state.items.items[state.visible_start_index..], 80, state.all_expanded);
    state.updateChatScrollLayout(old_total_rows, 2, 3, 80);
    state.chat_scroll_offset = state.chat_scroll_max_offset;
    const old_offset = state.chat_scroll_offset;

    state.handleChatMouseWheel(.{ .direction = .up, .row = 3, .col = 10 });

    try std.testing.expectEqual(@as(usize, 1), state.visible_start_index);
    try std.testing.expectEqual(old_offset + WHEEL_LINES_PER_NOTCH, state.chat_scroll_offset);
    try std.testing.expectEqual(state.chat_scroll_max_offset, state.chat_scroll_offset);
}

test "chat scroll page up at oldest history is a no-op at top" {
    const allocator = std.testing.allocator;
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    for (0..5) |index| {
        const text = try std.fmt.allocPrint(allocator, "item {d}", .{index});
        defer allocator.free(text);
        try state.appendItemLocked(.info, text);
    }

    state.visible_start_index = 0;
    const old_total_rows = estimateChatRows(state.items.items, 80, state.all_expanded);
    state.updateChatScrollLayout(old_total_rows, 2, 3, 80);
    state.chat_scroll_offset = state.chat_scroll_max_offset;
    const old_offset = state.chat_scroll_offset;

    state.chatScrollPageUp();

    try std.testing.expectEqual(@as(usize, 0), state.visible_start_index);
    try std.testing.expectEqual(old_offset, state.chat_scroll_offset);
    try std.testing.expectEqual(old_total_rows -| @as(usize, 2), state.chat_scroll_max_offset);
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

    const metrics = try drawChatViewport(arena.allocator(), null, null, items[0..], window, 0, 12, 5, 0, true, null, null);
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

test "thinking visibility toggle hides and restores thinking without dropping chat state" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.appendItemLocked(.thinking, "private chain");
    try state.appendItemLocked(.assistant, "public answer");
    try state.appendQueuedMessage(.follow_up, "queued draft");

    const hidden = try state.toggleThinkingBlockVisibility();
    try std.testing.expect(hidden);
    try std.testing.expect(state.hide_thinking_blocks);
    try std.testing.expectEqualStrings(ASSISTANT_THINKING_TEXT, state.items.items[1].text);
    try std.testing.expectEqualStrings("private chain", state.items.items[1].expanded_text.?);
    try std.testing.expectEqualStrings("public answer", state.items.items[2].text);
    try std.testing.expectEqual(@as(usize, 1), state.queued_follow_up.items.len);

    state.last_streaming_thinking_index = 1;
    try state.appendThinkingDeltaLocked(" continued");
    try std.testing.expectEqualStrings(ASSISTANT_THINKING_TEXT, state.items.items[1].text);
    try std.testing.expectEqualStrings("private chain continued", state.items.items[1].expanded_text.?);

    const visible = try state.toggleThinkingBlockVisibility();
    try std.testing.expect(!visible);
    try std.testing.expect(!state.hide_thinking_blocks);
    try std.testing.expectEqualStrings("private chain continued", state.items.items[1].text);
    try std.testing.expect(state.items.items[1].expanded_text == null);
    try std.testing.expectEqualStrings("public answer", state.items.items[2].text);
    try std.testing.expectEqual(@as(usize, 1), state.queued_follow_up.items.len);
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
    try std.testing.expectEqual(@as(?usize, null), previewThreshold(.assistant));
    try std.testing.expectEqual(@as(?usize, null), previewThreshold(.markdown));
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
    const lines = try tui.cell_rows.screenRowsToLinesAlloc(allocator, &screen, 80, rendered);
    defer freeLinesSlice(allocator, lines);
    try std.testing.expect(!renderedLinesContain(lines, "to expand"));
}

test "tool expansion rerenders existing bash details immediately" {
    const allocator = std.testing.allocator;

    const detail_value = try std.json.parseFromSlice(std.json.Value, allocator, "{\"exit_code\":0,\"timed_out\":false}", .{});
    defer detail_value.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.handleAgentEvent(.{
        .event_type = .tool_execution_end,
        .tool_name = "bash",
        .result = .{
            .content = &[_]ai.ContentBlock{.{ .text = .{ .text =
            \\line one
            \\line two
            \\line three
            \\line four
            } }},
            .details = detail_value.value,
        },
        .is_error = false,
    });

    try std.testing.expect(!state.all_expanded);
    try std.testing.expectEqualStrings("Tool result bash:\nline one\nline two\nline three\nline four", state.items.items[1].text);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].expanded_text.?, "Details:") != null);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 12,
    };

    const collapsed_lines = try renderScreenToLines(allocator, &screen_component, 80);
    defer freeLinesSlice(allocator, collapsed_lines);
    try std.testing.expect(!renderedLinesContain(collapsed_lines, "Details:"));
    try std.testing.expect(renderedLinesContain(collapsed_lines, "to expand"));

    state.toggleAllExpanded();
    const expanded_lines = try renderScreenToLines(allocator, &screen_component, 80);
    defer freeLinesSlice(allocator, expanded_lines);
    try std.testing.expect(renderedLinesContain(expanded_lines, "Details:"));
    try std.testing.expect(renderedLinesContain(expanded_lines, "\"exit_code\":0"));
}

test "tool expansion rerenders existing user bash tail preview immediately" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    for (0..25) |index| {
        const line = try std.fmt.allocPrint(allocator, "line {d}\n", .{index + 1});
        defer allocator.free(line);
        try output.appendSlice(allocator, line);
    }

    const item_index = try state.appendBashExecutionStart("seq 25", true);
    try state.finishBashExecution(item_index, "seq 25", output.items, 0, false, false, null, true);

    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "... 6 more lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "line 5\n") == null);
    try std.testing.expect(state.items.items[1].expanded_text != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].expanded_text.?, "line 1") != null);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var screen_component = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 16,
    };

    const collapsed_lines = try renderScreenToLines(allocator, &screen_component, 80);
    defer freeLinesSlice(allocator, collapsed_lines);
    try std.testing.expect(renderedLinesContain(collapsed_lines, "line 25"));
    try std.testing.expect(!renderedLinesContain(collapsed_lines, "line 5"));

    state.toggleAllExpanded();
    const expanded_lines = try renderScreenToLines(allocator, &screen_component, 80);
    defer freeLinesSlice(allocator, expanded_lines);
    try std.testing.expect(renderedLinesContain(expanded_lines, "line 1"));
}

test "extension UI hooks render widgets editor footer and status lifecycle" {
    const allocator = std.testing.allocator;

    var registry = extension_registry.Registry.init(allocator);
    defer registry.deinit();
    const frames =
        \\{ "type": "set_header", "lines": ["ext header"], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_footer", "lines": ["ext footer"], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_editor_component", "label": "VimEditor", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_widget", "key": "above", "lines": ["above one", "above two"], "placement": "aboveEditor", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_widget", "key": "below", "lines": ["below one"], "placement": "belowEditor", "extensionPath": "/tmp/ext.ts" }
        \\
    ;
    _ = try extension_registry.applyHostFrameStream(&registry, frames);

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.applyExtensionRegistryUi(&registry);
    try state.setExtensionFooterStatus("z-last", "last");
    try state.setExtensionFooterStatus("a-first", "first");

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqualStrings("ext header", snapshot.extension_header_lines[0]);
    try std.testing.expectEqualStrings("VimEditor", snapshot.extension_editor_label.?);
    try std.testing.expectEqualStrings("first", snapshot.extension_footer_statuses[0]);
    try std.testing.expectEqualStrings("last", snapshot.extension_footer_statuses[1]);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 14,
    };

    const lines = try renderScreenToLines(allocator, &screen, 100);
    defer freeLinesSlice(allocator, lines);
    try std.testing.expect(renderedLinesContain(lines, "ext header"));
    try std.testing.expect(renderedLinesContain(lines, "above one"));
    try std.testing.expect(renderedLinesContain(lines, "Extension editor: VimEditor"));
    try std.testing.expect(renderedLinesContain(lines, "below one"));
    try std.testing.expect(renderedLinesContain(lines, "ext footer"));
    try std.testing.expect(renderedLinesContain(lines, "first"));

    _ = registry.clearWidgetHook("above");
    _ = registry.clearFooterHook();
    _ = registry.clearEditorComponentHook();
    try state.applyExtensionRegistryUi(&registry);
    var cleared = try state.snapshotForRender(allocator);
    defer cleared.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), cleared.extension_widgets.len);
    try std.testing.expectEqual(@as(?[]u8, null), cleared.extension_editor_label);
    try std.testing.expectEqual(@as(usize, 0), cleared.extension_footer_lines.len);
}

test "agent message_start synchronizes queued display before rendering user message" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.appendQueuedMessage(.steering, "queued steer");

    const blocks = [_]ai.ContentBlock{.{ .text = .{ .text = "queued steer" } }};
    const user_message = ai.UserMessage{
        .role = "user",
        .content = &blocks,
        .timestamp = 1,
    };
    try state.handleAgentEvent(.{
        .event_type = .message_start,
        .message = .{ .user = user_message },
    });

    state.mutex.lockUncancelable(state.io);
    try std.testing.expectEqual(@as(usize, 0), state.queued_steering.items.len);
    try std.testing.expectEqualStrings("You: queued steer", state.items.items[state.items.items.len - 1].text);
    const user_count_after_start = countChatKind(state.items.items, .user);
    state.mutex.unlock(state.io);

    try state.handleAgentEvent(.{
        .event_type = .message_end,
        .message = .{ .user = user_message },
    });

    state.mutex.lockUncancelable(state.io);
    defer state.mutex.unlock(state.io);
    try std.testing.expectEqual(user_count_after_start, countChatKind(state.items.items, .user));
}

test "session rebuild clears stale streaming queue extension and progress state" {
    const allocator = std.testing.allocator;

    var registry = extension_registry.Registry.init(allocator);
    defer registry.deinit();
    const frames =
        \\{ "type": "set_header", "lines": ["stale header"], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_footer", "lines": ["stale footer"], "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_editor_component", "label": "StaleEditor", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_widget", "key": "stale", "lines": ["stale widget"], "placement": "aboveEditor", "extensionPath": "/tmp/ext.ts" }
        \\
    ;
    _ = try extension_registry.applyHostFrameStream(&registry, frames);

    const model = ai.model_registry.find("faux", "faux-1").?;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .model = model,
    });
    defer session.deinit();

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.applyExtensionRegistryUi(&registry);
    try state.setExtensionFooterStatus("stale", "status");
    try state.appendQueuedMessage(.follow_up, "queued draft");
    try state.appendMarkdown("stale streaming text");
    state.markTerminalProgress(true);

    try state.rebuildFromSession(&session, null);

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), snapshot.queued_follow_up.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.extension_header_lines.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.extension_footer_lines.len);
    try std.testing.expectEqual(@as(?[]u8, null), snapshot.extension_editor_label);
    try std.testing.expectEqual(@as(usize, 0), snapshot.extension_widgets.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.extension_footer_statuses.len);
    try std.testing.expectEqual(false, state.takeTerminalProgressUpdate().?);
}

test "compaction and retry lifecycle update status and terminal progress state" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    try state.handleCompactionLifecycleEvent(.{ .start = .{ .reason = .threshold } });
    try std.testing.expectEqual(true, state.takeTerminalProgressUpdate().?);
    state.mutex.lockUncancelable(state.io);
    try std.testing.expectEqualStrings("Auto-compacting... (Ctrl+C to cancel)", state.status);
    state.mutex.unlock(state.io);

    try state.handleCompactionLifecycleEvent(.{ .end = .{
        .reason = .threshold,
        .result = .{
            .summary = "summary",
            .first_kept_entry_id = "entry-1",
            .tokens_before = 42,
        },
    } });
    try std.testing.expectEqual(false, state.takeTerminalProgressUpdate().?);
    state.mutex.lockUncancelable(state.io);
    try std.testing.expectEqualStrings("Compacted context (42 tokens)", state.status);
    state.mutex.unlock(state.io);

    try state.handleRetryLifecycleEvent(.{ .start = .{
        .attempt = 1,
        .max_attempts = 2,
        .delay_ms = 1500,
        .error_message = "rate limit",
    } });
    try std.testing.expectEqual(false, state.takeTerminalProgressUpdate().?);
    state.mutex.lockUncancelable(state.io);
    try std.testing.expectEqualStrings("Retrying (1/2) in 2s... (Ctrl+C to cancel)", state.status);
    state.mutex.unlock(state.io);
}

test "active operation indicator animates agent wait and clears on agent end" {
    const allocator = std.testing.allocator;

    var clock = FixedClock{ .now_ms = 1_000 };
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    state.setClockForTesting(&clock, FixedClock.now);

    try state.handleAgentEvent(.{ .event_type = .agent_start });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
        .now_ms = 1_000,
    };

    const first = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, first);
    try std.testing.expect(renderedLinesContain(first, "Working... 0s elapsed"));
    try std.testing.expect(renderedLinesContain(first, "Esc to interrupt"));
    try std.testing.expect(renderedLinesContain(first, "⠋ Working"));

    const item_count = state.items.items.len;
    screen.now_ms = 1_000 + @as(i64, @intCast(tui.components.loader.DEFAULT_INTERVAL_MS));
    const second = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, second);
    try std.testing.expectEqual(item_count, state.items.items.len);
    try std.testing.expect(renderedLinesContain(second, "⠙ Working"));

    try state.handleAgentEvent(.{ .event_type = .agent_end });
    const completed = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, completed);
    try std.testing.expect(!renderedLinesContain(completed, "Working..."));
    try std.testing.expect(renderedLinesContain(completed, "Status: idle"));
}

test "active operation indicator identifies running tool without appending animation rows" {
    const allocator = std.testing.allocator;

    var clock = FixedClock{ .now_ms = 5_000 };
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    state.setClockForTesting(&clock, FixedClock.now);

    try state.handleAgentEvent(.{
        .event_type = .tool_execution_start,
        .tool_call_id = "tool-active",
        .tool_name = "read",
        .args = .null,
    });

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
        .now_ms = 5_000,
    };

    const first = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, first);
    try std.testing.expect(renderedLinesContain(first, "Running read 0s elapsed"));
    try std.testing.expect(renderedLinesContain(first, "⠋ Running read"));

    const item_count = state.items.items.len;
    screen.now_ms = 5_000 + @as(i64, @intCast(tui.components.loader.DEFAULT_INTERVAL_MS));
    const second = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, second);
    try std.testing.expectEqual(item_count, state.items.items.len);
    try std.testing.expect(renderedLinesContain(second, "⠙ Running read"));
}

test "active operation retry countdown and compaction elapsed render dynamically" {
    const allocator = std.testing.allocator;

    var clock = FixedClock{ .now_ms = 10_000 };
    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    state.setClockForTesting(&clock, FixedClock.now);

    var editor = tui.Editor.init(allocator);
    defer editor.deinit();
    var screen = ScreenComponent{
        .state = &state,
        .editor = &editor,
        .height = 8,
        .now_ms = 10_000,
    };

    try state.handleRetryLifecycleEvent(.{ .start = .{
        .attempt = 2,
        .max_attempts = 4,
        .delay_ms = 2500,
        .error_message = "rate limit",
    } });

    const retry_first = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, retry_first);
    try std.testing.expect(renderedLinesContain(retry_first, "Retrying (2/4) in 3s..."));
    try std.testing.expect(renderedLinesContain(retry_first, "Esc to cancel"));

    screen.now_ms = 11_100;
    const retry_second = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, retry_second);
    try std.testing.expect(renderedLinesContain(retry_second, "Retrying (2/4) in 2s..."));

    try state.handleRetryLifecycleEvent(.{ .end = .{
        .success = true,
        .attempt = 2,
        .final_error = null,
    } });
    const retry_end = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, retry_end);
    try std.testing.expect(!renderedLinesContain(retry_end, "Retrying (2/4)"));

    clock.now_ms = 20_000;
    try state.handleCompactionLifecycleEvent(.{ .start = .{ .reason = .threshold } });
    screen.now_ms = 20_000;
    const compact_first = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, compact_first);
    try std.testing.expect(renderedLinesContain(compact_first, "Auto-compacting... 0s elapsed"));
    try std.testing.expect(renderedLinesContain(compact_first, "Esc to cancel"));

    screen.now_ms = 21_000;
    const compact_second = try renderScreenToLines(allocator, &screen, 140);
    defer freeLinesSlice(allocator, compact_second);
    try std.testing.expect(renderedLinesContain(compact_second, "Auto-compacting... 1s elapsed"));
}

test "extension widgets replace by key and truncate after ten lines" {
    const allocator = std.testing.allocator;

    var registry = extension_registry.Registry.init(allocator);
    defer registry.deinit();
    const frames =
        \\{ "type": "set_widget", "key": "status", "lines": ["old"], "placement": "aboveEditor", "extensionPath": "/tmp/ext.ts" }
        \\{ "type": "set_widget", "key": "status", "lines": ["1","2","3","4","5","6","7","8","9","10","11"], "placement": "belowEditor", "extensionPath": "/tmp/ext.ts" }
        \\
    ;
    _ = try extension_registry.applyHostFrameStream(&registry, frames);

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();
    try state.applyExtensionRegistryUi(&registry);

    var snapshot = try state.snapshotForRender(allocator);
    defer snapshot.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.extension_widgets.len);
    try std.testing.expectEqual(ExtensionWidgetPlacement.below_editor, snapshot.extension_widgets[0].placement);
    try std.testing.expectEqual(@as(usize, 11), snapshot.extension_widgets[0].lines.len);
    try std.testing.expectEqualStrings(EXTENSION_WIDGET_TRUNCATION_MARKER, snapshot.extension_widgets[0].lines[10]);
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

    const text = try allocator.dupe(u8,
        \\# Changelog
        \\- Added /changelog
    );
    defer allocator.free(text);

    const lines = try renderChatItemInto(allocator, 40, null, .{
        .kind = .markdown,
        .text = text,
    });
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    try std.testing.expect(renderedLinesContain(lines, "Changelog"));
    try std.testing.expect(renderedLinesContain(lines, "• "));
    try std.testing.expect(!renderedLinesContain(lines, ASSISTANT_PREFIX));
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

test "app state replaces repeated partial tool updates and final error styling text" {
    const allocator = std.testing.allocator;

    var state = try AppState.init(allocator, std.testing.io);
    defer state.deinit();

    const first_partial = try allocator.alloc(ai.ContentBlock, 1);
    defer common.deinitContentBlocks(allocator, first_partial);
    first_partial[0] = .{ .text = .{ .text = try allocator.dupe(u8, "partial one") } };

    const second_partial = try allocator.alloc(ai.ContentBlock, 1);
    defer common.deinitContentBlocks(allocator, second_partial);
    second_partial[0] = .{ .text = .{ .text = try allocator.dupe(u8, "partial two") } };

    const final_blocks = try allocator.alloc(ai.ContentBlock, 1);
    defer common.deinitContentBlocks(allocator, final_blocks);
    final_blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, "final failure") } };

    try state.handleAgentEvent(.{
        .event_type = .tool_execution_update,
        .tool_call_id = "tool-repeat",
        .tool_name = "write",
        .partial_result = .{
            .content = first_partial,
            .details = null,
        },
    });
    try state.handleAgentEvent(.{
        .event_type = .tool_execution_update,
        .tool_call_id = "tool-repeat",
        .tool_name = "write",
        .partial_result = .{
            .content = second_partial,
            .details = null,
        },
    });
    try state.handleAgentEvent(.{
        .event_type = .tool_execution_end,
        .tool_call_id = "tool-repeat",
        .tool_name = "write",
        .result = .{
            .content = final_blocks,
            .details = null,
        },
        .is_error = true,
    });

    try std.testing.expectEqual(@as(usize, 2), state.items.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "partial one") == null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "partial two") == null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "Tool error write") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "final failure") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, state.items.items[1].text, "$ echo hi") != null);

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
        lines: []const []const u8 = &.{},
        render_error: ?std.mem.Allocator.Error = null,

        fn run(self: *@This()) void {
            self.lines = renderScreenToLines(self.allocator, self.screen, 120) catch |err| {
                self.render_error = err;
                return;
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
    defer freeLinesSlice(allocator, render_context.lines);
    try std.testing.expect(renderedLinesContain(render_context.lines, "Status: snapshot status"));
    try std.testing.expect(!renderedLinesContain(render_context.lines, "updated while rendering"));
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
    try std.testing.expect(!selected.style.reverse);
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

test "vaxis m8 visual parity snapshot covers chat rows footer and queue" {
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

    const lines = try renderScreenWithMockBackend(allocator, &screen_component, &backend);
    defer freeLinesSlice(allocator, lines);

    try std.testing.expect(renderedLinesContain(lines, "M8 heading"));
    try std.testing.expect(renderedLinesContain(lines, "Tool read:"));
    try std.testing.expect(renderedLinesContain(lines, "Steering: queued during compaction"));
    try std.testing.expect(renderedLinesContain(lines, "Follow-up: queued follow-up"));
    try std.testing.expect(renderedLinesContain(lines, "> pending prompt"));
    try std.testing.expect(!renderedLinesContain(lines, "⏎ send · Alt+⏎ follow-up"));
    try std.testing.expect(!renderedLinesContain(lines, "Alt+Up dequeue"));
    try std.testing.expect(!renderedLinesContain(lines, "Ctrl+C/Ctrl+D clear/exit"));
    try std.testing.expect(renderedLinesContain(lines, "Faux"));
    try std.testing.expect(renderedLinesContain(lines, "Queue: 1 steering, 1 follow-up"));
    try std.testing.expect(renderedLinesContain(lines, "Model: faux-1"));
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
        .height = 24,
        .keybindings = &keybindings,
    };

    var overlay = try overlays.loadHotkeysOverlay(allocator, &keybindings);
    defer overlay.deinit(allocator);

    var backend = InteractiveModeTestBackend{ .size = .{ .width = 100, .height = 24 } };
    defer backend.deinit(allocator);

    const lines = try renderScreenWithMockBackendAndOverlay(allocator, &screen_component, &overlay, &backend);
    defer freeLinesSlice(allocator, lines);

    try std.testing.expect(renderedLinesContain(lines, "Keyboard shortcuts"));
    try std.testing.expect(renderedLinesContain(lines, "Ctrl+C"));
    try std.testing.expect(renderedLinesContain(lines, "Ctrl+L"));
}
