const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const draw_mod = @import("../draw.zig");
const style_mod = @import("../style.zig");
const test_helpers = @import("../test_helpers.zig");
const resources_mod = @import("../theme.zig");
const vaxis_adapter = @import("../vaxis_adapter.zig");

const WrapMode = @FieldType(vaxis.Window.PrintOptions, "wrap");
const vxfw = vaxis.vxfw;

const MARKDOWN_TEXT_FALLBACK_STYLE: vaxis.Cell.Style = .{};
const LINK_FALLBACK_STYLE: vaxis.Cell.Style = .{
    .fg = .{ .index = 45 },
    .ul_style = .single,
};
const CODE_FALLBACK_STYLE: vaxis.Cell.Style = .{
    .fg = .{ .index = 214 },
    .bg = .{ .index = 236 },
};
const HEADER_ONE_FALLBACK_STYLE: vaxis.Cell.Style = .{
    .bold = true,
    .ul_style = .single,
};
const HEADER_TWO_FALLBACK_STYLE: vaxis.Cell.Style = .{
    .fg = .{ .index = 39 },
    .bold = true,
};
const QUOTE_FALLBACK_STYLE: vaxis.Cell.Style = .{
    .fg = .{ .index = 244 },
    .italic = true,
};
const QUOTE_BORDER_FALLBACK_STYLE: vaxis.Cell.Style = .{
    .fg = .{ .index = 244 },
};
const LIST_BULLET_FALLBACK_STYLE: vaxis.Cell.Style = .{
    .fg = .{ .index = 45 },
};
const RULE_FALLBACK_STYLE: vaxis.Cell.Style = .{
    .fg = .{ .index = 240 },
};
const CODE_BORDER_FALLBACK_STYLE: vaxis.Cell.Style = .{
    .fg = .{ .index = 244 },
};

pub const Markdown = struct {
    text: []const u8 = "",
    padding_x: usize = 0,
    padding_y: usize = 0,
    theme: ?*const resources_mod.Theme = null,

    pub fn component(self: *const Markdown) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn drawComponent(self: *const Markdown) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn renderInto(
        self: *const Markdown,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        if (std.mem.trim(u8, self.text, " \t\r\n").len == 0) return;

        const effective_width = @max(width, 1);
        const source_line_count = countSourceLines(self.text);
        const max_height = @max(source_line_count + self.padding_y * 2 + 8, ansi.visibleWidth(self.text) + self.padding_y * 2 + 8);
        var height_hint = @min(@max(source_line_count + self.padding_y * 2 + 4, 8), max_height);

        while (true) {
            var screen = try vaxis.Screen.init(allocator, .{
                .rows = @intCast(@max(height_hint, 1)),
                .cols = @intCast(effective_width),
                .x_pixel = 0,
                .y_pixel = 0,
            });
            defer screen.deinit(allocator);

            const window = draw_mod.rootWindow(&screen);
            window.clear();

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            const size = try self.draw(window, .{
                .window = window,
                .arena = arena.allocator(),
                .theme = self.theme,
            });

            if (size.height < height_hint or height_hint >= max_height) {
                try vaxis_adapter.appendScreenRowsAsAnsiLines(allocator, &screen, effective_width, size.height, lines);
                return;
            }

            height_hint = @min(max_height, height_hint * 2);
        }
    }

    pub fn draw(
        self: *const Markdown,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (std.mem.trim(u8, self.text, " \t\r\n").len == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        const active_theme = ctx.theme orelse self.theme;
        fillWindow(window, resolvedStyle(active_theme, .markdown_text, MARKDOWN_TEXT_FALLBACK_STYLE));

        const content_window = innerWindow(window, self.padding_x, self.padding_y) orelse {
            return .{
                .width = window.width,
                .height = @min(window.height, @as(u16, @intCast(self.padding_y * 2))),
            };
        };

        const normalized = try normalizeTabsAlloc(ctx.arena, self.text);
        var source_lines = std.ArrayList([]const u8).empty;
        var split = std.mem.splitScalar(u8, normalized, '\n');
        while (split.next()) |raw_line| {
            try source_lines.append(ctx.arena, trimCarriageReturn(raw_line));
        }

        var paragraph_lines = std.ArrayList([]const u8).empty;
        var code_block_lines = std.ArrayList([]const u8).empty;

        var current_row: usize = 0;
        var in_code_block = false;
        var code_block_language: []const u8 = "";
        var line_index: usize = 0;
        while (line_index < source_lines.items.len) {
            const line = source_lines.items[line_index];
            const trimmed = std.mem.trim(u8, line, " \t");

            if (in_code_block) {
                if (isCodeFence(trimmed)) {
                    current_row += try drawCodeBlock(
                        ctx.arena,
                        active_theme,
                        content_window,
                        current_row,
                        code_block_language,
                        code_block_lines.items,
                    );
                    code_block_lines.clearRetainingCapacity();
                    code_block_language = "";
                    in_code_block = false;
                } else {
                    try code_block_lines.append(ctx.arena, line);
                }
                line_index += 1;
                continue;
            }

            if (trimmed.len == 0) {
                current_row += try flushParagraphLines(ctx.arena, active_theme, content_window, current_row, &paragraph_lines);
                current_row += 1;
                line_index += 1;
                continue;
            }

            if (isCodeFence(trimmed)) {
                current_row += try flushParagraphLines(ctx.arena, active_theme, content_window, current_row, &paragraph_lines);
                in_code_block = true;
                code_block_language = std.mem.trim(u8, trimmed[3..], " \t");
                code_block_lines.clearRetainingCapacity();
                line_index += 1;
                continue;
            }

            if (parseHeadingLine(line)) |heading| {
                current_row += try flushParagraphLines(ctx.arena, active_theme, content_window, current_row, &paragraph_lines);
                current_row += try drawHeadingLine(ctx.arena, active_theme, content_window, current_row, heading);
                line_index += 1;
                continue;
            }

            if (isHorizontalRule(trimmed)) {
                current_row += try flushParagraphLines(ctx.arena, active_theme, content_window, current_row, &paragraph_lines);
                current_row += try drawHorizontalRule(ctx.arena, active_theme, content_window, current_row);
                line_index += 1;
                continue;
            }

            if (detectTableBlock(source_lines.items, line_index)) |table_match| {
                current_row += try flushParagraphLines(ctx.arena, active_theme, content_window, current_row, &paragraph_lines);
                current_row += try drawTableBlock(
                    ctx.arena,
                    active_theme,
                    content_window,
                    current_row,
                    source_lines.items[line_index],
                    source_lines.items[line_index + 2 .. table_match.end_index],
                );
                line_index = table_match.end_index;
                continue;
            }

            if (parseBlockquoteLine(line)) |quote| {
                current_row += try flushParagraphLines(ctx.arena, active_theme, content_window, current_row, &paragraph_lines);
                current_row += try drawQuoteLine(ctx.arena, active_theme, content_window, current_row, quote);
                line_index += 1;
                continue;
            }

            if (parseListItem(line)) |item| {
                current_row += try flushParagraphLines(ctx.arena, active_theme, content_window, current_row, &paragraph_lines);
                current_row += try drawListItem(ctx.arena, active_theme, content_window, current_row, item);
                line_index += 1;
                continue;
            }

            try paragraph_lines.append(ctx.arena, line);
            line_index += 1;
        }

        current_row += try flushParagraphLines(ctx.arena, active_theme, content_window, current_row, &paragraph_lines);
        if (in_code_block) {
            current_row += try drawCodeBlock(
                ctx.arena,
                active_theme,
                content_window,
                current_row,
                code_block_language,
                code_block_lines.items,
            );
        }

        const total_height = @min(
            @as(usize, window.height),
            self.padding_y + current_row + self.padding_y,
        );
        return .{
            .width = window.width,
            .height = @intCast(total_height),
        };
    }

    fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const Markdown = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Markdown = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

const HeadingLine = struct {
    level: usize,
    text: []const u8,
};

const BlockquoteLine = struct {
    text: []const u8,
};

const ListItem = struct {
    indent: []const u8,
    bullet: []const u8,
    text: []const u8,
};

const LinkMatch = struct {
    label_end: usize,
    url_end: usize,
};

const TableMatch = struct {
    end_index: usize,
};

const TableBorderPosition = enum {
    top,
    middle,
    bottom,
};

fn flushParagraphLines(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    window: vaxis.Window,
    start_row: usize,
    paragraph_lines: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!usize {
    defer paragraph_lines.clearRetainingCapacity();
    if (paragraph_lines.items.len == 0) return 0;

    const joined = try joinParagraphLinesAlloc(allocator, paragraph_lines.items);
    const segments = try buildInlineSegments(
        allocator,
        theme,
        resolvedStyle(theme, .markdown_text, MARKDOWN_TEXT_FALLBACK_STYLE),
        joined,
        null,
    );
    return drawWrappedSegments(allocator, window, start_row, segments, .word, null);
}

fn drawHeadingLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    window: vaxis.Window,
    start_row: usize,
    heading: HeadingLine,
) std.mem.Allocator.Error!usize {
    var base_style = resolvedStyle(
        theme,
        .markdown_heading,
        if (heading.level == 1) HEADER_ONE_FALLBACK_STYLE else HEADER_TWO_FALLBACK_STYLE,
    );
    if (heading.level == 1) {
        base_style = mergeStyles(base_style, .{ .ul_style = .single });
    }
    const segments = try buildInlineSegments(allocator, theme, base_style, heading.text, null);
    return drawWrappedSegments(allocator, window, start_row, segments, .word, null);
}

fn drawHorizontalRule(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    window: vaxis.Window,
    start_row: usize,
) std.mem.Allocator.Error!usize {
    if (window.width == 0 or start_row >= window.height) return 0;
    const text = try repeatGlyphAlloc(allocator, "─", window.width);
    drawTextAtRow(
        window,
        start_row,
        text,
        resolvedStyle(theme, .markdown_rule, RULE_FALLBACK_STYLE),
    );
    return 1;
}

fn drawQuoteLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    window: vaxis.Window,
    start_row: usize,
    quote: BlockquoteLine,
) std.mem.Allocator.Error!usize {
    const prefix_style = resolvedStyle(theme, .markdown_quote_border, QUOTE_BORDER_FALLBACK_STYLE);
    const body_style = resolvedStyle(theme, .markdown_quote, QUOTE_FALLBACK_STYLE);
    const prefix_segments = [_]vaxis.Segment{.{
        .text = "▍ ",
        .style = prefix_style,
    }};
    const body_segments = try buildInlineSegments(allocator, theme, body_style, quote.text, null);
    return drawPrefixedSegments(
        allocator,
        window,
        start_row,
        &prefix_segments,
        &prefix_segments,
        2,
        body_segments,
        null,
    );
}

fn drawListItem(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    window: vaxis.Window,
    start_row: usize,
    item: ListItem,
) std.mem.Allocator.Error!usize {
    const text_style = resolvedStyle(theme, .markdown_text, MARKDOWN_TEXT_FALLBACK_STYLE);
    const bullet_style = resolvedStyle(theme, .markdown_list_bullet, LIST_BULLET_FALLBACK_STYLE);
    const continuation_prefix = try spaceString(allocator, ansi.visibleWidth(item.indent) + ansi.visibleWidth(item.bullet));

    var first_prefix = std.ArrayList(vaxis.Segment).empty;
    if (item.indent.len > 0) {
        try first_prefix.append(allocator, .{ .text = item.indent, .style = text_style });
    }
    try first_prefix.append(allocator, .{ .text = item.bullet, .style = bullet_style });

    const continuation_segments = [_]vaxis.Segment{.{
        .text = continuation_prefix,
        .style = text_style,
    }};
    const body_segments = try buildInlineSegments(allocator, theme, text_style, item.text, null);
    return drawPrefixedSegments(
        allocator,
        window,
        start_row,
        first_prefix.items,
        &continuation_segments,
        ansi.visibleWidth(item.indent) + ansi.visibleWidth(item.bullet),
        body_segments,
        null,
    );
}

fn drawCodeBlock(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    window: vaxis.Window,
    start_row: usize,
    language: []const u8,
    code_lines: []const []const u8,
) std.mem.Allocator.Error!usize {
    if (window.width == 0 or start_row >= window.height) return 0;

    const block_window = window.child(.{
        .y_off = @intCast(start_row),
        .height = window.height - @as(u16, @intCast(start_row)),
    });
    const border_style = resolvedStyle(theme, .markdown_code_border, CODE_BORDER_FALLBACK_STYLE);
    const code_style = resolvedStyle(theme, .markdown_code, CODE_FALLBACK_STYLE);

    if (block_window.width < 4) {
        const fence = if (language.len > 0)
            try std.fmt.allocPrint(allocator, "```{s}", .{language})
        else
            "```";
        const fence_segments = [_]vaxis.Segment{.{ .text = fence, .style = border_style }};

        var rows: usize = 0;
        rows += try drawWrappedSegments(allocator, block_window, rows, &fence_segments, .word, null);
        for (code_lines) |code_line| {
            const code_segments = [_]vaxis.Segment{.{ .text = code_line, .style = code_style }};
            rows += try drawWrappedSegments(allocator, block_window, rows, &code_segments, .grapheme, null);
        }
        rows += try drawWrappedSegments(allocator, block_window, rows, &[_]vaxis.Segment{.{ .text = "```", .style = border_style }}, .word, null);
        return rows;
    }

    const inner_width = block_window.width - 4;
    const top = try buildCodeBorderTextAlloc(allocator, block_window.width, language, true);
    const bottom = try buildCodeBorderTextAlloc(allocator, block_window.width, "", false);
    const scaffold = try buildCodeRowScaffoldTextAlloc(allocator, inner_width);

    drawTextAtRow(block_window, 0, top, border_style);

    var row_cursor: usize = 1;
    if (code_lines.len == 0) {
        drawRepeatedText(block_window, row_cursor, 1, scaffold, border_style);
        row_cursor += 1;
    } else {
        for (code_lines) |code_line| {
            const remaining = remainingRows(block_window, row_cursor);
            if (remaining == 0) break;
            const content_window = block_window.child(.{
                .x_off = 2,
                .y_off = @intCast(row_cursor),
                .width = inner_width,
                .height = @intCast(remaining),
            });
            const segments = [_]vaxis.Segment{.{ .text = code_line, .style = code_style }};
            const row_height = if (code_line.len == 0)
                @as(usize, 1)
            else
                @max(@as(usize, 1), measureSegmentsHeight(content_window, &segments, .grapheme));
            drawRepeatedText(block_window, row_cursor, row_height, scaffold, border_style);
            if (code_line.len != 0) {
                _ = try drawSegments(allocator, content_window, &segments, .grapheme, null);
            }
            row_cursor += row_height;
        }
    }

    drawTextAtRow(block_window, row_cursor, bottom, border_style);
    return row_cursor + 1;
}

fn drawTableBlock(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    window: vaxis.Window,
    start_row: usize,
    header_line: []const u8,
    row_lines: []const []const u8,
) std.mem.Allocator.Error!usize {
    if (window.width == 0 or start_row >= window.height) return 0;

    const header_cells = try parseTableCellsAlloc(allocator, header_line);
    if (header_cells.len == 0) return 0;

    const column_count = header_cells.len;
    const border_overhead = column_count * 3 + 1;
    if (window.width <= border_overhead) {
        const segments = try buildInlineSegments(
            allocator,
            theme,
            resolvedStyle(theme, .markdown_text, MARKDOWN_TEXT_FALLBACK_STYLE),
            header_line,
            null,
        );
        return drawWrappedSegments(allocator, window, start_row, segments, .word, null);
    }

    const row_cells = try allocator.alloc([]const []const u8, row_lines.len);
    for (row_lines, 0..) |row_line, index| {
        row_cells[index] = try parseTableCellsAlloc(allocator, row_line);
    }

    const column_widths = try allocator.alloc(usize, column_count);
    for (column_widths) |*column_width| column_width.* = 3;

    try updateColumnWidths(allocator, theme, header_cells, column_widths, true);
    for (row_cells) |cells| {
        try updateColumnWidths(allocator, theme, cells, column_widths, false);
    }
    shrinkColumnWidths(column_widths, window.width - border_overhead);

    const block_window = window.child(.{
        .y_off = @intCast(start_row),
        .height = window.height - @as(u16, @intCast(start_row)),
    });
    const border_style = resolvedStyle(theme, .markdown_code_border, CODE_BORDER_FALLBACK_STYLE);

    const top = try buildTableBorderTextAlloc(allocator, column_widths, .top);
    const middle = try buildTableBorderTextAlloc(allocator, column_widths, .middle);
    const bottom = try buildTableBorderTextAlloc(allocator, column_widths, .bottom);

    var row_cursor: usize = 0;
    drawTextAtRow(block_window, row_cursor, top, border_style);
    row_cursor += 1;
    row_cursor += try drawTableRow(allocator, theme, block_window, row_cursor, header_cells, column_widths, true);
    drawTextAtRow(block_window, row_cursor, middle, border_style);
    row_cursor += 1;

    for (row_cells, 0..) |cells, index| {
        row_cursor += try drawTableRow(allocator, theme, block_window, row_cursor, cells, column_widths, false);
        if (index + 1 < row_cells.len) {
            drawTextAtRow(block_window, row_cursor, middle, border_style);
            row_cursor += 1;
        }
    }

    drawTextAtRow(block_window, row_cursor, bottom, border_style);
    return row_cursor + 1;
}

fn drawTableRow(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    table_window: vaxis.Window,
    start_row: usize,
    cells: []const []const u8,
    column_widths: []const usize,
    header: bool,
) std.mem.Allocator.Error!usize {
    if (start_row >= table_window.height) return 0;

    const row_window = table_window.child(.{
        .y_off = @intCast(start_row),
        .height = table_window.height - @as(u16, @intCast(start_row)),
    });
    const border_style = resolvedStyle(theme, .markdown_code_border, CODE_BORDER_FALLBACK_STYLE);
    const base_style = if (header)
        resolvedStyle(theme, .markdown_heading, HEADER_TWO_FALLBACK_STYLE)
    else
        resolvedStyle(theme, .markdown_text, MARKDOWN_TEXT_FALLBACK_STYLE);

    const cell_segments = try allocator.alloc([]const vaxis.Segment, column_widths.len);
    var row_height: usize = 1;
    for (column_widths, 0..) |column_width, index| {
        const cell_text = if (index < cells.len) cells[index] else "";
        cell_segments[index] = try buildInlineSegments(allocator, theme, base_style, cell_text, null);

        const remaining = remainingRows(row_window, 0);
        if (remaining == 0) continue;
        const cell_window = row_window.child(.{
            .x_off = @intCast(cellContentOffset(column_widths, index)),
            .width = @intCast(column_width),
            .height = @intCast(remaining),
        });
        const height = if (cell_segments[index].len == 0)
            @as(usize, 1)
        else
            @max(@as(usize, 1), measureSegmentsHeight(cell_window, cell_segments[index], .word));
        row_height = @max(row_height, height);
    }

    const scaffold = try buildTableRowScaffoldTextAlloc(allocator, column_widths);
    drawRepeatedText(row_window, 0, row_height, scaffold, border_style);

    for (column_widths, 0..) |column_width, index| {
        const remaining = remainingRows(row_window, 0);
        if (remaining == 0) break;
        const cell_window = row_window.child(.{
            .x_off = @intCast(cellContentOffset(column_widths, index)),
            .width = @intCast(column_width),
            .height = @intCast(@min(row_height, remaining)),
        });
        if (cell_segments[index].len != 0) {
            _ = try drawSegments(allocator, cell_window, cell_segments[index], .word, null);
        }
    }

    return row_height;
}

fn drawPrefixedSegments(
    allocator: std.mem.Allocator,
    window: vaxis.Window,
    start_row: usize,
    first_prefix: []const vaxis.Segment,
    continuation_prefix: []const vaxis.Segment,
    prefix_width: usize,
    body_segments: []const vaxis.Segment,
    fill_style: ?vaxis.Cell.Style,
) std.mem.Allocator.Error!usize {
    if (window.width == 0 or start_row >= window.height) return 0;

    const block_window = window.child(.{
        .y_off = @intCast(start_row),
        .height = window.height - @as(u16, @intCast(start_row)),
    });
    if (prefix_width >= block_window.width) {
        drawSegmentsNoWrap(block_window, first_prefix);
        return 1;
    }

    const prefix_window = block_window.child(.{
        .width = @intCast(prefix_width),
    });
    const content_window = block_window.child(.{
        .x_off = @intCast(prefix_width),
        .width = block_window.width - @as(u16, @intCast(prefix_width)),
    });

    const row_count = @max(@as(usize, 1), measureSegmentsHeight(content_window, body_segments, .word));
    drawPrefixRows(prefix_window, row_count, first_prefix, continuation_prefix);
    _ = try drawSegments(allocator, content_window, body_segments, .word, fill_style);
    return row_count;
}

fn drawPrefixRows(
    window: vaxis.Window,
    row_count: usize,
    first_prefix: []const vaxis.Segment,
    continuation_prefix: []const vaxis.Segment,
) void {
    const visible_rows = @min(row_count, @as(usize, window.height));
    for (0..visible_rows) |row| {
        const row_window = window.child(.{
            .y_off = @intCast(row),
            .height = 1,
        });
        drawSegmentsNoWrap(row_window, if (row == 0) first_prefix else continuation_prefix);
    }
}

fn drawWrappedSegments(
    allocator: std.mem.Allocator,
    window: vaxis.Window,
    start_row: usize,
    segments: []const vaxis.Segment,
    wrap: WrapMode,
    fill_style: ?vaxis.Cell.Style,
) std.mem.Allocator.Error!usize {
    if (window.width == 0 or start_row >= window.height) return 0;
    const block_window = window.child(.{
        .y_off = @intCast(start_row),
        .height = window.height - @as(u16, @intCast(start_row)),
    });
    return drawSegments(allocator, block_window, segments, wrap, fill_style);
}

fn drawSegments(
    allocator: std.mem.Allocator,
    window: vaxis.Window,
    segments: []const vaxis.Segment,
    wrap: WrapMode,
    fill_style: ?vaxis.Cell.Style,
) std.mem.Allocator.Error!usize {
    if (window.width == 0 or window.height == 0 or segments.len == 0) return 0;

    const height = @max(@as(usize, 1), measureSegmentsHeight(window, segments, wrap));
    if (fill_style) |style| fillRows(window, style, height);

    if (wrap == .grapheme) {
        const result = window.print(segments, .{ .wrap = wrap });
        return renderedLineCount(result, true, window.height);
    }

    var rich_text = richTextForSegments(segments, wrap, fill_style);
    const widget = rich_text.widget();
    const surface = try widget.draw(draw_mod.vxfwDrawContext(window, allocator));
    renderRichTextSurface(surface, window, fill_style != null);
    return @min(@as(usize, surface.size.height), @as(usize, window.height));
}

fn richTextForSegments(
    segments: []const vaxis.Segment,
    wrap: WrapMode,
    fill_style: ?vaxis.Cell.Style,
) vxfw.RichText {
    return .{
        .text = segments,
        .base_style = fill_style orelse .{},
        .softwrap = wrap != .none,
        .overflow = if (wrap == .none) .clip else .ellipsis,
        .width_basis = .parent,
    };
}

fn renderRichTextSurface(surface: vxfw.Surface, window: vaxis.Window, render_blank_cells: bool) void {
    if (surface.buffer.len == 0) return;
    for (surface.buffer, 0..) |cell, index| {
        if (!render_blank_cells and cell.char.grapheme.len == 0) continue;
        const row = index / surface.size.width;
        const col = index % surface.size.width;
        winWriteCell(window, col, row, cell);
    }
}

fn winWriteCell(window: vaxis.Window, col: usize, row: usize, cell: vaxis.Cell) void {
    window.writeCell(@intCast(col), @intCast(row), cell);
}

fn drawSegmentsNoWrap(window: vaxis.Window, segments: []const vaxis.Segment) void {
    if (window.width == 0 or window.height == 0 or segments.len == 0) return;
    _ = window.print(segments, .{ .wrap = .none });
}

fn drawTextAtRow(window: vaxis.Window, row: usize, text: []const u8, style: vaxis.Cell.Style) void {
    if (row >= window.height) return;
    const row_window = window.child(.{
        .y_off = @intCast(row),
        .height = 1,
    });
    drawSegmentsNoWrap(row_window, &[_]vaxis.Segment{.{ .text = text, .style = style }});
}

fn drawRepeatedText(window: vaxis.Window, start_row: usize, row_count: usize, text: []const u8, style: vaxis.Cell.Style) void {
    if (start_row >= window.height) return;
    const visible_rows = @min(row_count, @as(usize, window.height) - start_row);
    for (0..visible_rows) |row| {
        drawTextAtRow(window, start_row + row, text, style);
    }
}

fn fillRows(window: vaxis.Window, style: vaxis.Cell.Style, row_count: usize) void {
    if (row_count == 0 or window.width == 0 or window.height == 0) return;
    const fill_height: u16 = @intCast(@min(row_count, @as(usize, window.height)));
    const fill_window = window.child(.{ .height = fill_height });
    fill_window.fill(blankCell(style));
}

fn measureSegmentsHeight(window: vaxis.Window, segments: []const vaxis.Segment, wrap: WrapMode) usize {
    if (window.width == 0 or window.height == 0 or segments.len == 0) return 0;
    const result = window.print(segments, .{ .wrap = wrap, .commit = false });
    return renderedLineCount(result, true, window.height);
}

fn buildInlineSegments(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    base_style: vaxis.Cell.Style,
    text: []const u8,
    link_url: ?[]const u8,
) std.mem.Allocator.Error![]const vaxis.Segment {
    var segments = std.ArrayList(vaxis.Segment).empty;
    try appendInlineSegments(allocator, theme, base_style, text, link_url, &segments);
    return segments.toOwnedSlice(allocator);
}

fn appendInlineSegments(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    current_style: vaxis.Cell.Style,
    text: []const u8,
    link_url: ?[]const u8,
    segments: *std.ArrayList(vaxis.Segment),
) std.mem.Allocator.Error!void {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '[') {
            if (findLink(text, index)) |link| {
                const link_style = mergeStyles(current_style, resolvedStyle(theme, .markdown_link, LINK_FALLBACK_STYLE));
                try appendInlineSegments(
                    allocator,
                    theme,
                    link_style,
                    text[index + 1 .. link.label_end],
                    text[link.label_end + 2 .. link.url_end],
                    segments,
                );
                index = link.url_end + 1;
                continue;
            }
        }

        if (std.mem.startsWith(u8, text[index..], "**")) {
            if (findClosing(text, index + 2, "**")) |end| {
                try appendInlineSegments(
                    allocator,
                    theme,
                    mergeStyles(current_style, .{ .bold = true }),
                    text[index + 2 .. end],
                    link_url,
                    segments,
                );
                index = end + 2;
                continue;
            }
        }

        if (text[index] == '*' and (index + 1 >= text.len or text[index + 1] != '*')) {
            if (findClosing(text, index + 1, "*")) |end| {
                try appendInlineSegments(
                    allocator,
                    theme,
                    mergeStyles(current_style, .{ .italic = true }),
                    text[index + 1 .. end],
                    link_url,
                    segments,
                );
                index = end + 1;
                continue;
            }
        }

        if (text[index] == '`') {
            if (findClosing(text, index + 1, "`")) |end| {
                try appendPlainSegment(
                    allocator,
                    segments,
                    text[index + 1 .. end],
                    mergeStyles(current_style, resolvedStyle(theme, .markdown_code, CODE_FALLBACK_STYLE)),
                    link_url,
                );
                index = end + 1;
                continue;
            }
        }

        const plain_start = index;
        while (index < text.len) {
            if (text[index] == '[' or text[index] == '`') break;
            if (text[index] == '*' and (std.mem.startsWith(u8, text[index..], "**") or (index + 1 < text.len and text[index + 1] != '*'))) break;
            const rune_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
            index += @min(rune_len, text.len - index);
        }

        if (index == plain_start) {
            const rune_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
            index += @min(rune_len, text.len - index);
        }

        try appendPlainSegment(allocator, segments, text[plain_start..index], current_style, link_url);
    }
}

fn appendPlainSegment(
    allocator: std.mem.Allocator,
    segments: *std.ArrayList(vaxis.Segment),
    text: []const u8,
    style: vaxis.Cell.Style,
    link_url: ?[]const u8,
) std.mem.Allocator.Error!void {
    if (text.len == 0) return;
    try segments.append(allocator, .{
        .text = text,
        .style = style,
        .link = if (link_url) |url| .{ .uri = url } else .{},
    });
}

fn buildCodeBorderTextAlloc(
    allocator: std.mem.Allocator,
    width: usize,
    language: []const u8,
    top: bool,
) std.mem.Allocator.Error![]const u8 {
    var builder = std.ArrayList(u8).empty;
    const left = if (top) "┌" else "└";
    const right = if (top) "┐" else "┘";
    try builder.appendSlice(allocator, left);

    var remaining = width - 2;
    if (top and language.len > 0 and remaining > ansi.visibleWidth(language) + 2) {
        try builder.appendSlice(allocator, "─ ");
        try builder.appendSlice(allocator, language);
        try builder.appendSlice(allocator, " ");
        remaining -= ansi.visibleWidth(language) + 2;
    }
    for (0..remaining) |_| {
        try builder.appendSlice(allocator, "─");
    }
    try builder.appendSlice(allocator, right);
    return builder.toOwnedSlice(allocator);
}

fn buildCodeRowScaffoldTextAlloc(allocator: std.mem.Allocator, inner_width: usize) std.mem.Allocator.Error![]const u8 {
    var builder = std.ArrayList(u8).empty;
    try builder.appendSlice(allocator, "│ ");
    try builder.appendNTimes(allocator, ' ', inner_width);
    try builder.appendSlice(allocator, " │");
    return builder.toOwnedSlice(allocator);
}

fn buildTableBorderTextAlloc(
    allocator: std.mem.Allocator,
    column_widths: []const usize,
    position: TableBorderPosition,
) std.mem.Allocator.Error![]const u8 {
    const left = switch (position) {
        .top => "┌",
        .middle => "├",
        .bottom => "└",
    };
    const mid = switch (position) {
        .top => "┬",
        .middle => "┼",
        .bottom => "┴",
    };
    const right = switch (position) {
        .top => "┐",
        .middle => "┤",
        .bottom => "┘",
    };

    var builder = std.ArrayList(u8).empty;
    try builder.appendSlice(allocator, left);
    for (column_widths, 0..) |column_width, index| {
        try builder.appendSlice(allocator, "─");
        for (0..column_width) |_| {
            try builder.appendSlice(allocator, "─");
        }
        try builder.appendSlice(allocator, "─");
        if (index + 1 < column_widths.len) {
            try builder.appendSlice(allocator, mid);
        }
    }
    try builder.appendSlice(allocator, right);
    return builder.toOwnedSlice(allocator);
}

fn buildTableRowScaffoldTextAlloc(
    allocator: std.mem.Allocator,
    column_widths: []const usize,
) std.mem.Allocator.Error![]const u8 {
    var builder = std.ArrayList(u8).empty;
    try builder.appendSlice(allocator, "│ ");
    for (column_widths, 0..) |column_width, index| {
        try builder.appendNTimes(allocator, ' ', column_width);
        if (index + 1 < column_widths.len) {
            try builder.appendSlice(allocator, " │ ");
        }
    }
    try builder.appendSlice(allocator, " │");
    return builder.toOwnedSlice(allocator);
}

fn updateColumnWidths(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    cells: []const []const u8,
    column_widths: []usize,
    header: bool,
) std.mem.Allocator.Error!void {
    const base_style = if (header)
        resolvedStyle(theme, .markdown_heading, HEADER_TWO_FALLBACK_STYLE)
    else
        resolvedStyle(theme, .markdown_text, MARKDOWN_TEXT_FALLBACK_STYLE);

    for (column_widths, 0..) |*column_width, index| {
        const cell_text = if (index < cells.len) cells[index] else "";
        const segments = try buildInlineSegments(allocator, theme, base_style, cell_text, null);
        column_width.* = @max(column_width.*, @max(@as(usize, 3), segmentsVisibleWidth(segments)));
    }
}

fn shrinkColumnWidths(column_widths: []usize, available_width: usize) void {
    var total_width: usize = 0;
    for (column_widths) |column_width| total_width += column_width;

    while (total_width > available_width) {
        var widest_index: ?usize = null;
        var widest_width: usize = 0;
        for (column_widths, 0..) |column_width, index| {
            if (column_width > widest_width and column_width > 3) {
                widest_width = column_width;
                widest_index = index;
            }
        }
        if (widest_index) |index| {
            column_widths[index] -= 1;
            total_width -= 1;
        } else {
            break;
        }
    }
}

fn segmentsVisibleWidth(segments: []const vaxis.Segment) usize {
    var width: usize = 0;
    for (segments) |segment| width += ansi.visibleWidth(segment.text);
    return width;
}

fn repeatGlyphAlloc(allocator: std.mem.Allocator, glyph: []const u8, count: usize) std.mem.Allocator.Error![]const u8 {
    var builder = std.ArrayList(u8).empty;
    for (0..count) |_| try builder.appendSlice(allocator, glyph);
    return builder.toOwnedSlice(allocator);
}

fn joinParagraphLinesAlloc(allocator: std.mem.Allocator, paragraph_lines: []const []const u8) std.mem.Allocator.Error![]const u8 {
    var builder = std.ArrayList(u8).empty;
    for (paragraph_lines) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (builder.items.len > 0) try builder.append(allocator, ' ');
        try builder.appendSlice(allocator, trimmed);
    }
    return builder.toOwnedSlice(allocator);
}

fn fillWindow(window: vaxis.Window, style: vaxis.Cell.Style) void {
    if (isDefaultStyle(style)) {
        window.clear();
        return;
    }
    window.fill(blankCell(style));
}

fn blankCell(style: vaxis.Cell.Style) vaxis.Cell {
    return .{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = style,
    };
}

fn innerWindow(window: vaxis.Window, padding_x: usize, padding_y: usize) ?vaxis.Window {
    const pad_x: u16 = @intCast(@min(padding_x, window.width));
    const pad_y: u16 = @intCast(@min(padding_y, window.height));
    if (window.width <= pad_x * 2 or window.height <= pad_y * 2) return null;
    return window.child(.{
        .x_off = @intCast(pad_x),
        .y_off = @intCast(pad_y),
        .width = window.width - pad_x * 2,
        .height = window.height - pad_y * 2,
    });
}

fn rowCursorWindow(window: vaxis.Window, start_row: usize, width: u16, height: usize) ?vaxis.Window {
    const remaining = remainingRows(window, start_row);
    if (remaining == 0) return null;
    return window.child(.{
        .x_off = 2,
        .y_off = @intCast(start_row),
        .width = width,
        .height = @intCast(@min(height, remaining)),
    });
}

fn remainingRows(window: vaxis.Window, start_row: usize) usize {
    if (start_row >= window.height) return 0;
    return @as(usize, window.height) - start_row;
}

fn cellContentOffset(column_widths: []const usize, index: usize) usize {
    var offset: usize = 2;
    for (column_widths[0..index]) |column_width| {
        offset += column_width + 3;
    }
    return offset;
}

fn renderedLineCount(result: vaxis.Window.PrintResult, had_text: bool, max_height: u16) usize {
    if (!had_text or max_height == 0) return 0;
    if (result.overflow) return max_height;
    return @min(max_height, result.row + if (result.col > 0) @as(u16, 1) else 0);
}

fn resolvedStyle(
    theme: ?*const resources_mod.Theme,
    token: resources_mod.ThemeToken,
    fallback: vaxis.Cell.Style,
) vaxis.Cell.Style {
    if (theme) |active_theme| return style_mod.styleFor(active_theme, token);
    return fallback;
}

fn mergeStyles(base: vaxis.Cell.Style, overlay: vaxis.Cell.Style) vaxis.Cell.Style {
    var merged = base;
    if (!colorIsDefault(overlay.fg)) merged.fg = overlay.fg;
    if (!colorIsDefault(overlay.bg)) merged.bg = overlay.bg;
    if (!colorIsDefault(overlay.ul)) merged.ul = overlay.ul;
    if (overlay.ul_style != .off) merged.ul_style = overlay.ul_style;
    merged.bold = merged.bold or overlay.bold;
    merged.dim = merged.dim or overlay.dim;
    merged.italic = merged.italic or overlay.italic;
    merged.blink = merged.blink or overlay.blink;
    merged.reverse = merged.reverse or overlay.reverse;
    merged.invisible = merged.invisible or overlay.invisible;
    merged.strikethrough = merged.strikethrough or overlay.strikethrough;
    return merged;
}

fn colorIsDefault(color: vaxis.Cell.Color) bool {
    return switch (color) {
        .default => true,
        else => false,
    };
}

fn isDefaultStyle(style: vaxis.Cell.Style) bool {
    return std.meta.eql(style, vaxis.Cell.Style{});
}

fn spaceString(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error![]const u8 {
    if (count == 0) return "";
    const spaces = try allocator.alloc(u8, count);
    @memset(spaces, ' ');
    return spaces;
}

fn normalizeTabsAlloc(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    var builder = std.ArrayList(u8).empty;
    for (text) |byte| {
        if (byte == '\t') {
            try builder.appendSlice(allocator, "    ");
        } else {
            try builder.append(allocator, byte);
        }
    }
    return builder.toOwnedSlice(allocator);
}

fn trimCarriageReturn(text: []const u8) []const u8 {
    if (text.len > 0 and text[text.len - 1] == '\r') return text[0 .. text.len - 1];
    return text;
}

fn countSourceLines(text: []const u8) usize {
    if (text.len == 0) return 1;
    var count: usize = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn parseHeadingLine(line: []const u8) ?HeadingLine {
    const trimmed_left = line[leadingWhitespaceLength(line)..];
    var level: usize = 0;
    while (level < trimmed_left.len and trimmed_left[level] == '#' and level < 6) : (level += 1) {}
    if (level == 0 or level >= trimmed_left.len or trimmed_left[level] != ' ') return null;
    return .{
        .level = level,
        .text = std.mem.trim(u8, trimmed_left[level + 1 ..], " \t"),
    };
}

fn parseBlockquoteLine(line: []const u8) ?BlockquoteLine {
    const indent_len = leadingWhitespaceLength(line);
    const remainder = line[indent_len..];
    if (remainder.len == 0 or remainder[0] != '>') return null;
    const content_start: usize = if (remainder.len > 1 and remainder[1] == ' ') 2 else 1;
    return .{ .text = remainder[content_start..] };
}

fn parseListItem(line: []const u8) ?ListItem {
    const indent_len = leadingWhitespaceLength(line);
    const remainder = line[indent_len..];
    if (remainder.len >= 2 and (remainder[0] == '-' or remainder[0] == '*' or remainder[0] == '+') and remainder[1] == ' ') {
        return .{ .indent = line[0..indent_len], .bullet = "• ", .text = remainder[2..] };
    }

    var digit_count: usize = 0;
    while (digit_count < remainder.len and std.ascii.isDigit(remainder[digit_count])) : (digit_count += 1) {}
    if (digit_count == 0 or digit_count + 1 >= remainder.len) return null;
    if (remainder[digit_count] != '.' or remainder[digit_count + 1] != ' ') return null;
    return .{
        .indent = line[0..indent_len],
        .bullet = remainder[0 .. digit_count + 2],
        .text = remainder[digit_count + 2 ..],
    };
}

fn parseTableCellsAlloc(allocator: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len > 0 and trimmed[0] == '|') trimmed = trimmed[1..];
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '|') trimmed = trimmed[0 .. trimmed.len - 1];

    var cells = std.ArrayList([]const u8).empty;
    var split = std.mem.splitScalar(u8, trimmed, '|');
    while (split.next()) |cell| {
        try cells.append(allocator, std.mem.trim(u8, cell, " \t"));
    }
    return cells.toOwnedSlice(allocator);
}

fn countTableCells(line: []const u8) usize {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '|') == null) return 0;
    if (trimmed[0] == '|') trimmed = trimmed[1..];
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '|') trimmed = trimmed[0 .. trimmed.len - 1];

    var count: usize = 0;
    var split = std.mem.splitScalar(u8, trimmed, '|');
    while (split.next()) |_| count += 1;
    return count;
}

fn isTableSeparatorLine(line: []const u8, expected_cells: usize) bool {
    var trimmed_line = std.mem.trim(u8, line, " \t");
    if (trimmed_line.len == 0) return false;
    if (trimmed_line[0] == '|') trimmed_line = trimmed_line[1..];
    if (trimmed_line.len > 0 and trimmed_line[trimmed_line.len - 1] == '|') {
        trimmed_line = trimmed_line[0 .. trimmed_line.len - 1];
    }

    var count: usize = 0;
    var split = std.mem.splitScalar(u8, trimmed_line, '|');
    while (split.next()) |cell| {
        count += 1;
        const trimmed = std.mem.trim(u8, cell, " \t");
        if (trimmed.len < 3) return false;
        var has_dash = false;
        for (trimmed) |byte| {
            switch (byte) {
                '-' => has_dash = true,
                ':' => {},
                else => return false,
            }
        }
        if (!has_dash) return false;
    }
    return count == expected_cells and count > 0;
}

fn detectTableBlock(source_lines: []const []const u8, start_index: usize) ?TableMatch {
    if (start_index + 1 >= source_lines.len) return null;

    const header_cells = countTableCells(source_lines[start_index]);
    if (header_cells < 2) return null;
    if (!isTableSeparatorLine(source_lines[start_index + 1], header_cells)) return null;

    var end_index = start_index + 2;
    while (end_index < source_lines.len) : (end_index += 1) {
        const trimmed = std.mem.trim(u8, source_lines[end_index], " \t");
        if (trimmed.len == 0) break;
        if (countTableCells(source_lines[end_index]) != header_cells) break;
    }

    return .{ .end_index = end_index };
}

fn leadingWhitespaceLength(text: []const u8) usize {
    var index: usize = 0;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) : (index += 1) {}
    return index;
}

fn isHorizontalRule(trimmed: []const u8) bool {
    if (trimmed.len < 3) return false;
    const marker = trimmed[0];
    if (marker != '-' and marker != '_' and marker != '*') return false;
    for (trimmed) |byte| {
        if (byte != marker) return false;
    }
    return true;
}

fn isCodeFence(trimmed: []const u8) bool {
    return std.mem.startsWith(u8, trimmed, "```");
}

fn findLink(text: []const u8, start: usize) ?LinkMatch {
    if (start >= text.len or text[start] != '[') return null;
    const label_end = std.mem.indexOfScalarPos(u8, text, start + 1, ']') orelse return null;
    if (label_end + 1 >= text.len or text[label_end + 1] != '(') return null;
    const url_end = std.mem.indexOfScalarPos(u8, text, label_end + 2, ')') orelse return null;
    if (label_end == start + 1 or url_end == label_end + 2) return null;
    return .{ .label_end = label_end, .url_end = url_end };
}

fn findClosing(text: []const u8, start: usize, marker: []const u8) ?usize {
    if (start >= text.len) return null;
    const relative = std.mem.indexOf(u8, text[start..], marker) orelse return null;
    const index = start + relative;
    if (index == start) return null;
    return index;
}

test "markdown renders inline styles as cell styles" {
    var theme = try resources_mod.Theme.initDefault(std.testing.allocator);
    defer theme.deinit(std.testing.allocator);

    const markdown = Markdown{
        .text = "**bold** *italic* `code` [link](https://example.com)",
        .theme = &theme,
    };

    var screen = try test_helpers.renderToScreenWithTheme(markdown.drawComponent(), 48, 2, &theme);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "b", mergeStyles(style_mod.styleFor(&theme, .markdown_text), .{ .bold = true }));
    try test_helpers.expectCell(&screen, 5, 0, "i", mergeStyles(style_mod.styleFor(&theme, .markdown_text), .{ .italic = true }));
    try test_helpers.expectCell(&screen, 12, 0, "c", style_mod.styleFor(&theme, .markdown_code));
    try test_helpers.expectCell(&screen, 17, 0, "l", style_mod.styleFor(&theme, .markdown_link));
}

test "markdown rich text segments delegate through vxfw RichText" {
    const segments = [_]vaxis.Segment{
        .{ .text = "hello " },
        .{ .text = "vxfw", .style = .{ .bold = true } },
    };
    var rich_text = richTextForSegments(&segments, .word, null);
    const widget = rich_text.widget();

    try std.testing.expectEqual(@intFromPtr(&rich_text), @intFromPtr(widget.userdata));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const surface = try widget.draw(.{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = 8, .height = 2 },
        .cell_size = .{ .width = 0, .height = 0 },
    });

    try std.testing.expectEqual(@as(u16, 8), surface.size.width);
    try std.testing.expectEqual(@as(u16, 2), surface.size.height);
    try std.testing.expectEqualStrings("v", surface.readCell(0, 1).char.grapheme);
    try std.testing.expect(surface.readCell(0, 1).style.bold);
}

test "markdown renders headings lists blockquotes rules and code blocks with cell styles" {
    var theme = try resources_mod.Theme.initDefault(std.testing.allocator);
    defer theme.deinit(std.testing.allocator);

    const markdown = Markdown{
        .text =
        \\# Header
        \\- bullet item
        \\> quote
        \\---
        \\```zig
        \\const answer = 42;
        \\```
        ,
        .theme = &theme,
    };

    var screen = try test_helpers.renderToScreenWithTheme(markdown.drawComponent(), 24, 8, &theme);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "H", mergeStyles(style_mod.styleFor(&theme, .markdown_heading), .{ .ul_style = .single }));
    try test_helpers.expectCell(&screen, 0, 1, "•", style_mod.styleFor(&theme, .markdown_list_bullet));
    try test_helpers.expectCell(&screen, 0, 2, "▍", style_mod.styleFor(&theme, .markdown_quote_border));
    try test_helpers.expectCell(&screen, 0, 3, "─", style_mod.styleFor(&theme, .markdown_rule));
    try test_helpers.expectCell(&screen, 0, 4, "┌", style_mod.styleFor(&theme, .markdown_code_border));
    try test_helpers.expectCell(&screen, 2, 5, "c", style_mod.styleFor(&theme, .markdown_code));
    try test_helpers.expectCell(&screen, 0, 6, "└", style_mod.styleFor(&theme, .markdown_code_border));
}

test "markdown table snapshot preserves three column alignment" {
    const markdown = Markdown{
        .text =
        \\| A | BB | C |
        \\| --- | --- | --- |
        \\| one | two | three |
        \\| 1 | 22 | 333 |
        ,
    };

    var screen = try test_helpers.renderToScreen(markdown.drawComponent(), 21, 7);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\┌─────┬─────┬───────┐
        \\│ A   │ BB  │ C     │
        \\├─────┼─────┼───────┤
        \\│ one │ two │ three │
        \\├─────┼─────┼───────┤
        \\│ 1   │ 22  │ 333   │
        \\└─────┴─────┴───────┘
    ,
        rendered,
    );
}
