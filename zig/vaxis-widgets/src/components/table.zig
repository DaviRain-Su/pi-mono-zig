const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");
const constraints_mod = @import("../constraints.zig");
const layout = @import("../layout.zig");
const ansi = @import("../ansi.zig");

pub const Cell = struct {
    text: []const u8,
    style: ?vaxis.Cell.Style = null,
    alignment: layout.AlignItems = .start,
};

pub const Row = struct {
    cells: []const Cell,
    style: ?vaxis.Cell.Style = null,
};

pub const TableState = struct {
    selected_index: ?usize = null,
    selected_indices: []const usize = &.{},
    offset: usize = 0,

    pub fn select(self: *TableState, index: ?usize, total_rows: usize) void {
        if (index) |i| {
            if (total_rows == 0) {
                self.selected_index = null;
                return;
            }
            self.selected_index = @min(i, total_rows - 1);
        } else {
            self.selected_index = null;
        }
    }

    pub fn selectNext(self: *TableState, total_rows: usize) void {
        if (total_rows == 0) return;
        const current = self.selected_index orelse 0;
        self.selected_index = @min(current + 1, total_rows - 1);
    }

    pub fn selectPrevious(self: *TableState, total_rows: usize) void {
        if (total_rows == 0) return;
        const current = self.selected_index orelse 0;
        self.selected_index = if (current == 0) 0 else current - 1;
    }

    pub fn scrollToSelected(self: *TableState, visible_rows: usize, total_rows: usize) void {
        const selected = self.selected_index orelse return;
        if (visible_rows == 0 or total_rows == 0) return;

        if (selected < self.offset) {
            self.offset = selected;
        } else if (selected >= self.offset + visible_rows) {
            self.offset = selected - visible_rows + 1;
        }

        const max_offset = if (total_rows > visible_rows) total_rows - visible_rows else 0;
        self.offset = @min(self.offset, max_offset);
    }

    pub fn clamp(self: *TableState, visible_rows: usize, total_rows: usize) void {
        if (total_rows == 0) {
            self.selected_index = null;
            self.offset = 0;
            return;
        }
        if (self.selected_index) |selected| {
            self.selected_index = @min(selected, total_rows - 1);
        }
        const max_offset = if (visible_rows > 0 and total_rows > visible_rows) total_rows - visible_rows else 0;
        self.offset = @min(self.offset, max_offset);
    }

    pub fn isSelected(self: TableState, index: usize, total_rows: usize) bool {
        if (index >= total_rows) return false;
        if (self.selected_index != null and self.selected_index.? == index) return true;
        for (self.selected_indices) |selected| {
            if (selected == index) return true;
        }
        return false;
    }
};

pub const SortOrder = enum {
    ascending,
    descending,
};

pub const Table = struct {
    rows: []const Row,
    header: ?Row = null,
    widths: []const constraints_mod.Constraint,
    column_spacing: u16 = 1,
    row_highlight_style: ?vaxis.Cell.Style = null,
    header_separator: bool = true,
    row_separator: bool = false,
    highlight_symbol: []const u8 = ">",
    show_scrollbar: bool = false,
    scrollbar_thumb: []const u8 = "█",
    scrollbar_track: []const u8 = "│",
    sort_column: ?usize = null,
    sort_order: SortOrder = .ascending,

    pub fn sortByColumn(
        self: *Table,
        allocator: std.mem.Allocator,
        column_index: usize,
        comptime order: SortOrder,
    ) std.mem.Allocator.Error!void {
        if (self.rows.len <= 1) return;
        if (column_index >= self.columnCount()) return;

        const sorted = try allocator.alloc(Row, self.rows.len);
        std.mem.copyForwards(Row, sorted, self.rows);

        const Context = struct {
            col: usize,
            pub fn lessThan(ctx: @This(), a: Row, b: Row) bool {
                const a_text = if (ctx.col < a.cells.len) a.cells[ctx.col].text else "";
                const b_text = if (ctx.col < b.cells.len) b.cells[ctx.col].text else "";
                return switch (order) {
                    .ascending => std.mem.lessThan(u8, a_text, b_text),
                    .descending => std.mem.lessThan(u8, b_text, a_text),
                };
            }
        };

        std.sort.block(Row, sorted, Context{ .col = column_index }, Context.lessThan);
        self.rows = sorted;
    }

    pub fn filter(
        self: *Table,
        allocator: std.mem.Allocator,
        column_index: usize,
        query: []const u8,
    ) std.mem.Allocator.Error!void {
        if (self.rows.len == 0 or query.len == 0) return;
        if (column_index >= self.columnCount()) return;

        var count: usize = 0;
        for (self.rows) |row| {
            const text = if (column_index < row.cells.len) row.cells[column_index].text else "";
            if (std.mem.indexOf(u8, text, query) != null) {
                count += 1;
            }
        }

        if (count == self.rows.len) return;

        const matched = try allocator.alloc(Row, count);
        var i: usize = 0;
        for (self.rows) |row| {
            const text = if (column_index < row.cells.len) row.cells[column_index].text else "";
            if (std.mem.indexOf(u8, text, query) != null) {
                matched[i] = row;
                i += 1;
            }
        }
        self.rows = matched;
    }

    pub fn draw(
        self: Table,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
        state: *TableState,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const area = constraints_mod.Rect{
            .x = 0,
            .y = 0,
            .width = window.width,
            .height = window.height,
        };

        const column_count = self.columnCount();
        if (column_count == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        state.clamp(0, self.rows.len);
        const has_selection = state.selected_index != null or state.selected_indices.len > 0;
        const selection_width: u16 = if (has_selection)
            @intCast(ansi.visibleWidth(self.highlight_symbol))
        else
            0;

        const widths = if (self.widths.len > 0) self.widths else blk: {
            const equal = try ctx.arena.alloc(constraints_mod.Constraint, column_count);
            for (equal) |*w| w.* = .{ .fill = 1 };
            break :blk equal;
        };

        const header_height: u16 = if (self.header != null) 1 else 0;
        const header_sep_height: u16 = if (self.header != null and self.header_separator) 1 else 0;
        const fixed_height = header_height + header_sep_height;
        const rows_available = if (area.height > fixed_height)
            area.height - fixed_height
        else
            0;
        const data_rows_available = if (self.row_separator)
            @as(usize, (rows_available + 1) / 2)
        else
            @as(usize, rows_available);
        const visible_data_rows = @min(self.rows.len, data_rows_available);

        const scrollbar_width: u16 = if (self.show_scrollbar and self.rows.len > visible_data_rows and visible_data_rows > 0) 1 else 0;
        const content_width = if (area.width > selection_width + scrollbar_width) area.width - selection_width - scrollbar_width else 0;
        const content_area = constraints_mod.Rect{
            .x = selection_width,
            .y = 0,
            .width = content_width,
            .height = area.height,
        };

        const column_rects = try constraints_mod.splitHorizontal(
            ctx.arena,
            content_area,
            widths,
            self.column_spacing,
        );

        state.scrollToSelected(visible_data_rows, self.rows.len);
        state.clamp(visible_data_rows, self.rows.len);

        var y: u16 = 0;

        // Render header
        if (self.header) |header_row| {
            if (y < area.height and header_height > 0) {
                const indicator: ?[]const u8 = switch (self.sort_order) {
                    .ascending => "↑",
                    .descending => "↓",
                };
                try renderRow(ctx.arena, window, header_row, column_rects, selection_width, y, false, null, self.highlight_symbol, self.sort_column, indicator);
                y += 1;
            }

            if (self.header_separator and y < area.height and header_sep_height > 0) {
                renderSeparator(window, area.width, y);
                y += 1;
            }
        }

        // Render visible rows
        const start_index = state.offset;
        const end_index = @min(start_index + visible_data_rows, self.rows.len);

        for (self.rows[start_index..end_index], start_index..) |row, index| {
            if (y >= area.height) break;
            const is_selected = state.isSelected(index, self.rows.len);
            const hl = if (is_selected) self.row_highlight_style else null;
            try renderRow(ctx.arena, window, row, column_rects, selection_width, y, is_selected, hl, self.highlight_symbol, null, null);
            y += 1;

            if (self.row_separator and y < area.height and index + 1 < self.rows.len) {
                renderSeparator(window, area.width, y);
                y += 1;
            }
        }

        // Render scrollbar
        if (scrollbar_width > 0 and rows_available > 0 and visible_data_rows > 0) {
            const scroll_col = area.width - 1;
            const thumb_height = @max(1, (rows_available * rows_available) / self.rows.len);
            const max_offset = self.rows.len - visible_data_rows;
            const thumb_start = if (max_offset == 0) 0 else (state.offset * (rows_available - thumb_height)) / max_offset;

            for (0..rows_available) |row_idx| {
                const row_y = fixed_height + @as(u16, @intCast(row_idx));
                if (row_y >= area.height) break;
                const is_thumb = row_idx >= thumb_start and row_idx < thumb_start + thumb_height;
                window.writeCell(scroll_col, row_y, .{
                    .char = .{ .grapheme = if (is_thumb) self.scrollbar_thumb else self.scrollbar_track, .width = 1 },
                    .style = .{},
                });
            }
        }

        return .{ .width = window.width, .height = y };
    }

    fn columnCount(self: Table) usize {
        var max_cols: usize = 0;
        if (self.header) |h| max_cols = @max(max_cols, h.cells.len);
        for (self.rows) |row| {
            max_cols = @max(max_cols, row.cells.len);
        }
        return max_cols;
    }
};

fn renderRow(
    allocator: std.mem.Allocator,
    window: vaxis.Window,
    row: Row,
    column_rects: []const constraints_mod.Rect,
    selection_width: u16,
    row_y: u16,
    is_selected: bool,
    highlight_style: ?vaxis.Cell.Style,
    highlight_symbol: []const u8,
    sort_column: ?usize,
    sort_indicator: ?[]const u8,
) std.mem.Allocator.Error!void {
    // Render highlight symbol
    if (is_selected and selection_width > 0) {
        const sym_style = highlight_style orelse vaxis.Cell.Style{};
        var x: u16 = 0;
        var byte_idx: usize = 0;
        while (byte_idx < highlight_symbol.len and x < selection_width) {
            const cluster = ansi.nextDisplayCluster(highlight_symbol, byte_idx);
            if (cluster.end <= byte_idx) break;
            const cluster_width: u8 = @intCast(cluster.width);
            if (x + @as(u16, cluster_width) > selection_width) break;
            window.writeCell(x, row_y, .{
                .char = .{ .grapheme = highlight_symbol[byte_idx..cluster.end], .width = cluster_width },
                .style = sym_style,
            });
            x += @as(u16, cluster_width);
            byte_idx = cluster.end;
        }
    }

    // Render cells
    for (row.cells, 0..) |cell, cell_index| {
        if (cell_index >= column_rects.len) break;
        const col_rect = column_rects[cell_index];

        const effective_style = blk: {
            var s = row.style orelse vaxis.Cell.Style{};
            if (cell.style) |cs| {
                s = mergeStyle(s, cs);
            }
            if (highlight_style) |hs| {
                s = mergeStyle(s, hs);
            }
            break :blk s;
        };

        const max_width = col_rect.width;
        const is_sort_col = sort_column != null and sort_column.? == cell_index and sort_indicator != null;
        const indicator_text = if (is_sort_col) sort_indicator.? else "";
        const indicator_width = ansi.visibleWidth(indicator_text);

        // Truncate text to fit
        const effective_max = if (max_width > indicator_width) max_width - indicator_width else 0;
        const visible_text = if (ansi.visibleWidth(cell.text) <= effective_max)
            cell.text
        else blk: {
            const truncated = try ansi.sliceVisibleAlloc(allocator, cell.text, 0, effective_max);
            break :blk truncated;
        };

        // Compute alignment padding
        const text_width = ansi.visibleWidth(visible_text) + indicator_width;
        const left_pad: u16 = if (text_width < max_width) switch (cell.alignment) {
            .start, .stretch => 0,
            .center => @intCast((max_width - text_width) / 2),
            .end => @intCast(max_width - text_width),
        } else 0;

        // Write padding
        var x: u16 = col_rect.x;
        var pad_remaining = left_pad;
        while (pad_remaining > 0) : (pad_remaining -= 1) {
            window.writeCell(x, row_y, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = effective_style,
            });
            x += 1;
        }

        // Write text
        var byte_idx: usize = 0;
        var written: u16 = 0;
        const available_text_width = max_width - left_pad - indicator_width;
        while (byte_idx < visible_text.len and written < available_text_width) {
            const cluster = ansi.nextDisplayCluster(visible_text, byte_idx);
            if (cluster.end <= byte_idx) break;
            const cluster_width: u8 = @intCast(cluster.width);
            if (written + @as(u16, cluster_width) > available_text_width) break;
            window.writeCell(x, row_y, .{
                .char = .{ .grapheme = visible_text[byte_idx..cluster.end], .width = cluster_width },
                .style = effective_style,
            });
            x += @as(u16, cluster_width);
            byte_idx = cluster.end;
            written += @as(u16, cluster_width);
        }

        // Write sort indicator
        if (is_sort_col and indicator_width > 0 and x < col_rect.x + col_rect.width) {
            window.writeCell(x, row_y, .{
                .char = .{ .grapheme = indicator_text, .width = @intCast(indicator_width) },
                .style = effective_style,
            });
            x += @intCast(indicator_width);
        }

        // Fill remaining column space
        while (x < col_rect.x + col_rect.width) {
            window.writeCell(x, row_y, .{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = effective_style,
            });
            x += 1;
        }
    }
}

fn renderSeparator(window: vaxis.Window, width: u16, y: u16) void {
    for (0..width) |x| {
        window.writeCell(@intCast(x), y, .{
            .char = .{ .grapheme = "─", .width = 1 },
            .style = .{},
        });
    }
}

fn mergeStyle(base: vaxis.Cell.Style, overlay: vaxis.Cell.Style) vaxis.Cell.Style {
    return .{
        .fg = if (overlay.fg != .default) overlay.fg else base.fg,
        .bg = if (overlay.bg != .default) overlay.bg else base.bg,
        .ul = if (overlay.ul != .default) overlay.ul else base.ul,
        .bold = overlay.bold or base.bold,
        .dim = overlay.dim or base.dim,
        .italic = overlay.italic or base.italic,
        .blink = overlay.blink or base.blink,
        .reverse = overlay.reverse or base.reverse,
        .invisible = overlay.invisible or base.invisible,
        .strikethrough = overlay.strikethrough or base.strikethrough,
        .ul_style = if (overlay.ul_style != .off) overlay.ul_style else base.ul_style,
    };
}

test "TableState select and scroll" {
    var state = TableState{};

    state.select(5, 10);
    try std.testing.expectEqual(@as(?usize, 5), state.selected_index);

    state.selectNext(10);
    try std.testing.expectEqual(@as(?usize, 6), state.selected_index);

    state.selectPrevious(10);
    try std.testing.expectEqual(@as(?usize, 5), state.selected_index);

    state.select(20, 10);
    try std.testing.expectEqual(@as(?usize, 9), state.selected_index);

    state.select(null, 10);
    try std.testing.expectEqual(@as(?usize, null), state.selected_index);
}

test "TableState scrollToSelected" {
    var state = TableState{ .selected_index = 5 };

    state.scrollToSelected(3, 10);
    try std.testing.expectEqual(@as(usize, 3), state.offset);

    state.selected_index = 1;
    state.scrollToSelected(3, 10);
    try std.testing.expectEqual(@as(usize, 1), state.offset);

    state.selected_index = 0;
    state.scrollToSelected(3, 10);
    try std.testing.expectEqual(@as(usize, 0), state.offset);
}

test "Table renders cells into window" {
    const allocator = std.testing.allocator;

    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 4,
        .cols = 20,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const rows = &[_]Row{
        .{ .cells = &.{ .{ .text = "OpenAI" }, .{ .text = "gpt-5" } } },
        .{ .cells = &.{ .{ .text = "Anthropic" }, .{ .text = "claude" } } },
    };

    var table = Table{
        .rows = rows,
        .header = .{ .cells = &.{ .{ .text = "Provider" }, .{ .text = "Model" } } },
        .widths = &.{ .{ .length = 10 }, .{ .fill = 1 } },
        .header_separator = true,
    };

    var state = TableState{};
    state.select(0, 2);

    const size = try table.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    }, &state);

    try std.testing.expect(size.height > 0);

    // Verify header content
    const header_cell = window.readCell(1, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("P", header_cell.char.grapheme);
}

test "Table truncates overflowing text" {
    const allocator = std.testing.allocator;

    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 10,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const rows = &[_]Row{
        .{ .cells = &.{.{ .text = "verylongtext" }} },
    };

    var table = Table{
        .rows = rows,
        .widths = &.{.{ .length = 5 }},
    };

    var state = TableState{};
    _ = try table.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    }, &state);

    // Text should be truncated to fit column width
    const cell = window.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cell.char.grapheme.len > 0);
}

test "Table sortByColumn orders rows ascending and descending" {
    const allocator = std.testing.allocator;

    const original_rows = &[_]Row{
        .{ .cells = &.{ .{ .text = "Charlie" }, .{ .text = "3" } } },
        .{ .cells = &.{ .{ .text = "Alpha" }, .{ .text = "1" } } },
        .{ .cells = &.{ .{ .text = "Bravo" }, .{ .text = "2" } } },
    };

    var table = Table{
        .rows = original_rows,
        .widths = &.{ .{ .length = 10 }, .{ .length = 5 } },
    };

    try table.sortByColumn(allocator, 0, .ascending);
    const ascending_rows = table.rows;
    defer allocator.free(ascending_rows);

    try std.testing.expectEqualStrings("Alpha", table.rows[0].cells[0].text);
    try std.testing.expectEqualStrings("Bravo", table.rows[1].cells[0].text);
    try std.testing.expectEqualStrings("Charlie", table.rows[2].cells[0].text);

    try table.sortByColumn(allocator, 0, .descending);
    defer allocator.free(table.rows);

    try std.testing.expectEqualStrings("Charlie", table.rows[0].cells[0].text);
    try std.testing.expectEqualStrings("Bravo", table.rows[1].cells[0].text);
    try std.testing.expectEqualStrings("Alpha", table.rows[2].cells[0].text);
}

test "Table filter reduces rows by query" {
    const allocator = std.testing.allocator;

    const original_rows = &[_]Row{
        .{ .cells = &.{ .{ .text = "OpenAI" }, .{ .text = "gpt-5" } } },
        .{ .cells = &.{ .{ .text = "Anthropic" }, .{ .text = "claude" } } },
        .{ .cells = &.{ .{ .text = "OpenRouter" }, .{ .text = "or-model" } } },
    };

    var table = Table{
        .rows = original_rows,
        .widths = &.{ .{ .length = 10 }, .{ .length = 10 } },
    };

    try table.filter(allocator, 0, "Open");
    defer allocator.free(table.rows);

    try std.testing.expectEqual(@as(usize, 2), table.rows.len);
    try std.testing.expectEqualStrings("OpenAI", table.rows[0].cells[0].text);
    try std.testing.expectEqualStrings("OpenRouter", table.rows[1].cells[0].text);
}

test "Table renders sort indicator on header" {
    const allocator = std.testing.allocator;

    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 20,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const rows = &[_]Row{
        .{ .cells = &.{ .{ .text = "Alpha" }, .{ .text = "1" } } },
    };

    var table = Table{
        .rows = rows,
        .header = .{ .cells = &.{ .{ .text = "Name" }, .{ .text = "Value" } } },
        .widths = &.{ .{ .length = 8 }, .{ .length = 8 } },
        .sort_column = 0,
        .sort_order = .ascending,
    };

    var state = TableState{};
    _ = try table.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    }, &state);

    const indicator = screen.readCell(4, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("↑", indicator.char.grapheme);
}

test "Table row separators keep selected row visible" {
    const allocator = std.testing.allocator;

    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 16,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const rows = &[_]Row{
        .{ .cells = &.{.{ .text = "row0" }} },
        .{ .cells = &.{.{ .text = "row1" }} },
        .{ .cells = &.{.{ .text = "row2" }} },
        .{ .cells = &.{.{ .text = "row3" }} },
    };

    const table = Table{
        .rows = rows,
        .widths = &.{.{ .length = 8 }},
        .row_separator = true,
        .row_highlight_style = .{ .reverse = true },
    };

    var state = TableState{ .selected_index = 2 };
    _ = try table.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    }, &state);

    try std.testing.expectEqual(@as(usize, 1), state.offset);
    const selected = screen.readCell(0, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(">", selected.char.grapheme);
}

test "Table renders header when rows are empty" {
    const allocator = std.testing.allocator;

    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 2,
        .cols = 16,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const table = Table{
        .rows = &.{},
        .header = .{ .cells = &.{.{ .text = "OnlyHeader" }} },
        .widths = &.{.{ .length = 12 }},
    };
    var state = TableState{ .offset = 99, .selected_index = 3 };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    _ = try table.draw(draw_mod.rootWindow(&screen), .{
        .window = draw_mod.rootWindow(&screen),
        .arena = arena.allocator(),
    }, &state);

    try std.testing.expectEqual(@as(?usize, null), state.selected_index);
    try std.testing.expectEqual(@as(usize, 0), state.offset);
    const header = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("O", header.char.grapheme);
}

test "Table clamps stale offset after rows shrink" {
    const allocator = std.testing.allocator;

    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 2,
        .cols = 12,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const rows = &[_]Row{
        .{ .cells = &.{.{ .text = "row0" }} },
        .{ .cells = &.{.{ .text = "row1" }} },
    };
    const table = Table{
        .rows = rows,
        .widths = &.{.{ .length = 8 }},
    };
    var state = TableState{ .offset = 20 };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    _ = try table.draw(draw_mod.rootWindow(&screen), .{
        .window = draw_mod.rootWindow(&screen),
        .arena = arena.allocator(),
    }, &state);

    try std.testing.expectEqual(@as(usize, 0), state.offset);
    const row0 = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("r", row0.char.grapheme);
}

test "Table renders multi-selected rows and full highlight style" {
    const allocator = std.testing.allocator;

    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 3,
        .cols = 12,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const rows = &[_]Row{
        .{ .cells = &.{.{ .text = "row0" }} },
        .{ .cells = &.{.{ .text = "row1" }} },
        .{ .cells = &.{.{ .text = "row2" }} },
    };
    const table = Table{
        .rows = rows,
        .widths = &.{.{ .length = 8 }},
        .row_highlight_style = .{ .reverse = true, .strikethrough = true },
    };
    const selected = &[_]usize{ 0, 2, 999 };
    var state = TableState{ .selected_indices = selected };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    _ = try table.draw(draw_mod.rootWindow(&screen), .{
        .window = draw_mod.rootWindow(&screen),
        .arena = arena.allocator(),
    }, &state);

    const first = screen.readCell(1, 0) orelse return error.TestUnexpectedResult;
    const middle = screen.readCell(1, 1) orelse return error.TestUnexpectedResult;
    const third = screen.readCell(1, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(first.style.reverse);
    try std.testing.expect(first.style.strikethrough);
    try std.testing.expect(!middle.style.reverse);
    try std.testing.expect(third.style.reverse);
}
