const std = @import("std");
const tui = @import("tui");
const keybindings_mod = @import("../shared/keybindings.zig");
const resources_mod = @import("../resources/resources.zig");
const chat_items = @import("chat_items.zig");
const formatting = @import("formatting.zig");

const ASSISTANT_PREFIX = formatting.ASSISTANT_PREFIX;

pub const ChatKind = chat_items.ChatKind;
pub const ChatItem = chat_items.ChatItem;

pub const ViewportMetrics = struct {
    rendered_height: usize,
    visible_height: usize,
};

const ItemLayout = struct {
    item_index: usize,
    rows: usize,
};

pub const SelectionRange = struct {
    start_row: usize,
    start_col: usize,
    end_row: usize,
    end_col: usize,
};

/// Renders chat items into `window`, applying scroll offset without allocating
/// a full-size scratch screen. Only items that overlap the visible area are
/// rendered, avoiding expensive off-screen markdown processing.
pub fn drawViewport(
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
    selection: ?SelectionRange,
    selected_text_out: ?*std.ArrayList(u8),
) !ViewportMetrics {
    if (start_row >= window.height or height == 0) return .{ .rendered_height = 0, .visible_height = 0 };

    const visible_height = @min(height, @as(usize, window.height) - start_row);
    const width = @max(@as(usize, window.width), 1);

    // Compute total rendered height and per-item layout without rendering.
    var layout = try computeLayout(allocator, items, width, all_expanded);
    defer layout.deinit(allocator);

    const rendered_height = layout.total_rows;
    const max_offset = rendered_height -| visible_height;
    const offset = @min(chat_scroll_offset, max_offset);
    const src_start = max_offset -| offset;
    const dst = window.child(.{
        .y_off = @intCast(start_row),
        .height = @intCast(visible_height),
    });

    // Find the first item that overlaps the visible area.
    var item_row: usize = 0;
    var item_index: usize = 0;
    while (item_index < layout.entries.items.len) : (item_index += 1) {
        const entry_rows = layout.entries.items[item_index].rows;
        const item_end = item_row + entry_rows;
        if (item_end > src_start) break;
        item_row = item_end;
    }

    // Render visible items directly into the destination window.
    var dst_row: usize = 0;
    while (item_index < items.len and dst_row < visible_height) : (item_index += 1) {
        const entry_rows = if (item_index < layout.entries.items.len) layout.entries.items[item_index].rows else estimateItemRowsVisible(items[item_index], width, all_expanded);
        const draw_start = if (item_row < src_start) src_start - item_row else 0;
        const available = visible_height - dst_row;

        if (draw_start < entry_rows and available > 0) {
            const slice_height = @min(entry_rows - draw_start, available);
            try renderItemSlice(
                dst, allocator, keybindings, theme,
                items[item_index], dst_row, slice_height,
                draw_start, now_ms, all_expanded, width,
                selection, src_start,
            );
            dst_row += slice_height;
        }
        item_row += entry_rows;
    }

    // Extract selected text by re-rendering visible items into a scratch screen.
    if (selected_text_out) |text_out| {
        if (selection) |sel| {
            try extractSelectedTextFromItems(
                allocator, keybindings, theme,
                items, layout, width,
                now_ms, all_expanded, sel, text_out,
            );
        }
    }

    drawScrollIndicators(dst, theme, src_start, rendered_height, visible_height);
    return .{ .rendered_height = rendered_height, .visible_height = visible_height };
}

/// Pre-computed layout: total row count and per-item row counts.
/// Cached across render calls by the caller (AppState) to avoid re-computation
/// when content has not changed.
const Layout = struct {
    total_rows: usize,
    entries: std.ArrayList(ItemLayout),

    fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }
};

fn computeLayout(allocator: std.mem.Allocator, items: []const ChatItem, width: usize, all_expanded: bool) !Layout {
    var entries = try std.ArrayList(ItemLayout).initCapacity(allocator, items.len);
    var total: usize = 0;
    for (items, 0..) |item, i| {
        const rows = estimateItemRowsVisible(item, width, all_expanded);
        entries.appendAssumeCapacity(.{ .item_index = i, .rows = rows });
        total += rows;
    }
    return .{ .total_rows = total, .entries = entries };
}

fn renderItemSlice(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    item: ChatItem,
    dst_row: usize,
    slice_height: usize,
    src_skip: usize,
    now_ms: i64,
    all_expanded: bool,
    width: usize,
    selection: ?SelectionRange,
    viewport_src_start: usize,
) !void {
    // Allocate a small scratch screen just for this item.
    const full_height = estimateItemRowsFull(item, width, true);
    const scratch_rows = @max(@as(usize, 1), @min(full_height, src_skip + slice_height + 1));
    var scratch = try tui.vaxis.Screen.init(allocator, .{
        .rows = @intCast(@min(scratch_rows, @as(usize, std.math.maxInt(u16)))),
        .cols = @intCast(width),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer scratch.deinit(allocator);

    const scratch_window = tui.draw.rootWindow(&scratch);
    scratch_window.clear();
    _ = try drawItem(scratch_window, allocator, keybindings, theme, item, 0, now_ms, all_expanded);

    const child = window.child(.{
        .y_off = @intCast(dst_row),
        .height = @intCast(slice_height),
    });
    const actual_src = @min(src_skip, @as(usize, scratch.height) -| 1);
    if (selection) |sel| {
        blitScreenRowsWithSelection(&scratch, child, actual_src, slice_height, sel, viewport_src_start + dst_row - actual_src);
    } else {
        blitScreenRows(&scratch, child, actual_src, slice_height);
    }
}

fn drawScrollIndicators(
    window: tui.vaxis.Window,
    theme: ?*const resources_mod.Theme,
    src_start: usize,
    rendered_height: usize,
    visible_height: usize,
) void {
    if (visible_height == 0 or window.width == 0) return;
    const style = styleForToken(theme, .status);
    if (src_start > 0) {
        drawScrollIndicator(window, 0, "↑ more", style);
    }
    if (src_start + visible_height < rendered_height) {
        drawScrollIndicator(window, visible_height - 1, "↓ more", style);
    }
}

fn drawScrollIndicator(
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

pub fn drawItems(
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
        row += try drawItem(window, allocator, keybindings, theme, item, row, now_ms, all_expanded);
    }
    return .{
        .width = window.width,
        .height = @intCast(@min(row, @as(usize, window.height))),
    };
}

pub fn drawItem(
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
            const full_height_hint = @max(@as(usize, 1), estimateItemRowsFull(item, @max(@as(usize, window.width), 1), true));
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
                try drawItemFull(scratch_window, allocator, theme, item, 0, now_ms, true),
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

    return drawItemFull(child, allocator, theme, item, 0, now_ms, all_expanded);
}

fn drawItemFull(
    window: tui.vaxis.Window,
    allocator: std.mem.Allocator,
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
    const item_text = displayText(item, all_expanded);
    switch (item.kind) {
        .assistant => {
            var row: usize = drawWrappedText(child, 0, ASSISTANT_PREFIX, styleForToken(theme, .role_assistant));
            if (std.mem.trim(u8, item_text, " \t\r\n").len == 0) return row;
            const markdown_window = child.child(.{
                .y_off = @intCast(row),
                .height = child.height - @as(u16, @intCast(row)),
            });
            const markdown = tui.Markdown{ .text = item_text, .styles = if (theme) |t| tui.markdownStylesFor(t) else .{} };
            const size = try markdown.draw(markdown_window, .{
                .window = markdown_window,
                .arena = allocator,
            });
            row += @as(usize, size.height);
            return row;
        },
        .markdown => {
            const markdown = tui.Markdown{ .text = item_text, .styles = if (theme) |t| tui.markdownStylesFor(t) else .{} };
            const size = try markdown.draw(child, .{
                .window = child,
                .arena = allocator,
            });
            return @as(usize, size.height);
        },
        .thinking => return drawThinkingItem(child, theme, item, now_ms),
        else => return drawWrappedText(child, 0, item_text, styleForToken(theme, token(item.kind))),
    }
}

fn displayText(item: ChatItem, all_expanded: bool) []const u8 {
    if (all_expanded and (item.kind == .tool_result or item.kind == .bash_execution)) {
        if (item.expanded_text) |expanded_text| return expanded_text;
    }
    return item.text;
}

pub fn previewThreshold(kind: ChatKind) ?usize {
    return switch (kind) {
        .thinking => 1,
        .tool_result => 3,
        .assistant, .markdown => null,
        .welcome, .info, .@"error", .user, .tool_call, .bash_execution => null,
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
    const label = try actionLabel(allocator, keybindings, .tools_expand, "Ctrl+O");
    const text = try std.fmt.allocPrint(allocator, "… +{d} lines ({s} to expand)", .{ hidden_rows, label });
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

fn drawThinkingItem(
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

pub fn thinkingFrameIndex(item: ChatItem, now_ms: i64) usize {
    if (item.frozen_frame_index) |index| return index;
    const start_ms = item.start_ms orelse now_ms;
    const elapsed_i64 = @max(now_ms - start_ms, 0);
    var loader = tui.Loader{};
    return loader.frameIndexForElapsed(@intCast(elapsed_i64));
}

pub fn token(kind: ChatKind) resources_mod.ThemeToken {
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
        .bash_execution => .role_tool_result,
    };
}

pub fn estimateRows(items: []const ChatItem, width: usize, all_expanded: bool) usize {
    var rows: usize = 1;
    for (items) |item| {
        rows += estimateItemRowsVisible(item, width, all_expanded);
    }
    return rows;
}

pub fn estimateItemRowsVisible(item: ChatItem, width: usize, all_expanded: bool) usize {
    const full_rows = estimateItemRowsFull(item, width, true);
    if (!all_expanded) {
        if (previewThreshold(item.kind)) |threshold| {
            if (full_rows > threshold) return threshold + 1;
        }
    }
    return estimateItemRowsFull(item, width, all_expanded);
}

fn estimateItemRowsFull(item: ChatItem, width: usize, all_expanded: bool) usize {
    const item_text = displayText(item, all_expanded);
    return switch (item.kind) {
        .assistant => 1 + estimateWrappedRows(item_text, width),
        .markdown => estimateWrappedRows(item_text, width),
        .thinking => if (width <= 2) 1 else @max(@as(usize, 1), estimateWrappedRows(item_text, width - 2)),
        else => estimateWrappedRows(item_text, width),
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

fn blitScreenRowsWithSelection(
    source: *tui.vaxis.Screen,
    dest: tui.vaxis.Window,
    source_start_row: usize,
    height: usize,
    selection: SelectionRange,
    dest_abs_row_start: usize,
) void {
    const rows = @min(height, @as(usize, dest.height));
    const cols = @min(@as(usize, source.width), @as(usize, dest.width));
    for (0..rows) |row| {
        const abs_row = source_start_row + row;
        for (0..cols) |col| {
            var cell = source.readCell(@intCast(col), @intCast(abs_row)) orelse continue;
            cell = normalizeCellForBlit(cell);
            const dest_abs_row = dest_abs_row_start + row;
            if (isCellSelected(dest_abs_row, col, selection)) {
                const fg = cell.style.fg;
                cell.style.fg = switch (cell.style.bg) {
                    .default => .{ .rgb = .{ 200, 200, 200 } },
                    else => cell.style.bg,
                };
                cell.style.bg = switch (fg) {
                    .default => .{ .rgb = .{ 50, 50, 50 } },
                    else => fg,
                };
            }
            dest.writeCell(@intCast(col), @intCast(row), cell);
        }
    }
}

fn extractSelectedTextFromItems(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    theme: ?*const resources_mod.Theme,
    items: []const ChatItem,
    layout: Layout,
    width: usize,
    now_ms: i64,
    all_expanded: bool,
    selection: SelectionRange,
    output: *std.ArrayList(u8),
) !void {
    // Find all items that overlap the selection range (not just the visible viewport).
    var item_row: usize = 0;
    for (items, 0..) |item, item_index| {
        const entry_rows = if (item_index < layout.entries.items.len) layout.entries.items[item_index].rows else estimateItemRowsVisible(item, width, all_expanded);
        const item_end = item_row + entry_rows;

        // Skip items entirely above or below the selection.
        if (item_end <= selection.start_row) {
            item_row = item_end;
            continue;
        }
        if (item_row > selection.end_row) break;

        // Use a generous scratch screen size for text extraction.
        // estimateItemRowsFull underestimates markdown content (code blocks, headings, etc.),
        // so the scratch screen needs extra room to avoid truncation.
        const item_text = displayText(item, all_expanded);
        const source_lines = countNewlines(item_text) + 1;
        const generous_rows = @max(entry_rows, source_lines * 2 + 8);
        var item_scratch = try tui.vaxis.Screen.init(allocator, .{
            .rows = @intCast(@min(generous_rows, @as(usize, std.math.maxInt(u16)))),
            .cols = @intCast(@min(width, @as(usize, std.math.maxInt(u16)))),
            .x_pixel = 0,
            .y_pixel = 0,
        });
        defer item_scratch.deinit(allocator);

        const item_window = tui.draw.rootWindow(&item_scratch);
        item_window.clear();
        _ = try drawItem(item_window, allocator, keybindings, theme, item, 0, now_ms, all_expanded);

        // Extract selected rows from this item's scratch screen.
        const sel_start_in_item = if (selection.start_row > item_row) selection.start_row - item_row else 0;
        const sel_end_in_item = if (selection.end_row < item_end) selection.end_row - item_row + 1 else entry_rows;
        const cols = @min(@as(usize, item_scratch.width), @as(usize, width));
        var trailing_space: usize = 0;
        var skip_next: bool = false;
        for (sel_start_in_item..sel_end_in_item) |local_row| {
            if (local_row >= @as(usize, item_scratch.height)) break;
            const abs_row = item_row + local_row;
            const col_start: usize = if (abs_row == selection.start_row) selection.start_col else 0;
            const col_end: usize = if (abs_row == selection.end_row) @min(selection.end_col, cols) else cols;
            for (col_start..col_end) |col| {
                const cell = item_scratch.readCell(@intCast(col), @intCast(local_row)) orelse continue;
                if (skip_next) {
                    skip_next = false;
                    continue;
                }
                const grapheme = cell.char.grapheme;
                if (cell.char.width > 1) {
                    for (0..trailing_space) |_| try output.append(allocator, ' ');
                    trailing_space = 0;
                    try output.appendSlice(allocator, grapheme);
                    skip_next = true;
                } else if (grapheme.len == 0 or (grapheme.len == 1 and grapheme[0] == ' ')) {
                    trailing_space += 1;
                } else {
                    for (0..trailing_space) |_| try output.append(allocator, ' ');
                    trailing_space = 0;
                    try output.appendSlice(allocator, grapheme);
                }
            }
            if (abs_row < selection.end_row) {
                try output.append(allocator, '\n');
                trailing_space = 0;
            }
        }
        item_row = item_end;
    }
}

fn isCellSelected(row: usize, col: usize, sel: SelectionRange) bool {
    if (row < sel.start_row or row > sel.end_row) return false;
    if (row == sel.start_row and row == sel.end_row) return col >= sel.start_col and col < sel.end_col;
    if (row == sel.start_row) return col >= sel.start_col;
    if (row == sel.end_row) return col < sel.end_col;
    return true;
}

fn extractSelectedText(
    allocator: std.mem.Allocator,
    source: *tui.vaxis.Screen,
    source_start_row: usize,
    visible_height: usize,
    selection: SelectionRange,
    output: *std.ArrayList(u8),
) !void {
    const cols = source.width;
    const rows = @min(visible_height, @as(usize, source.height));
    for (0..rows) |row| {
        const abs_row = source_start_row + row;
        if (abs_row < selection.start_row or abs_row > selection.end_row) continue;
        const col_start: usize = if (abs_row == selection.start_row) selection.start_col else 0;
        const col_end: usize = if (abs_row == selection.end_row) @min(selection.end_col, @as(usize, cols)) else @as(usize, cols);
        var trailing_space: usize = 0;
        var skip_next: bool = false;
        for (col_start..col_end) |col| {
            const cell = source.readCell(@intCast(col), @intCast(abs_row)) orelse continue;
            if (skip_next) {
                skip_next = false;
                continue;
            }
            const grapheme = cell.char.grapheme;
            if (cell.char.width > 1) {
                for (0..trailing_space) |_| try output.append(allocator, ' ');
                trailing_space = 0;
                try output.appendSlice(allocator, grapheme);
                skip_next = true;
            } else if (grapheme.len == 0 or (grapheme.len == 1 and grapheme[0] == ' ')) {
                trailing_space += 1;
            } else {
                for (0..trailing_space) |_| try output.append(allocator, ' ');
                trailing_space = 0;
                try output.appendSlice(allocator, grapheme);
            }
        }
        if (abs_row < selection.end_row) try output.append(allocator, '\n');
    }
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

pub fn countNewlines(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
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

fn styleForToken(theme: ?*const resources_mod.Theme, theme_token: resources_mod.ThemeToken) tui.vaxis.Cell.Style {
    return if (theme) |active_theme| tui.styleFor(active_theme, theme_token) else .{};
}

fn actionLabel(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
    action: keybindings_mod.Action,
    fallback: []const u8,
) ![]u8 {
    const active = keybindings orelse return allocator.dupe(u8, fallback);
    return active.primaryLabel(allocator, action) catch allocator.dupe(u8, fallback);
}
