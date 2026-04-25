const std = @import("std");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const resources_mod = @import("../theme.zig");

const RESET = "\x1b[0m";
const BOLD_STYLE = "\x1b[1m";
const ITALIC_STYLE = "\x1b[3m";
const CODE_STYLE = "\x1b[48;5;236m\x1b[38;5;214m";
const LINK_STYLE = "\x1b[4m\x1b[38;5;45m";
const HEADER_ONE_STYLE = "\x1b[1m\x1b[4m";
const HEADER_TWO_STYLE = "\x1b[1m\x1b[38;5;39m";
const QUOTE_STYLE = "\x1b[3m\x1b[38;5;244m";
const QUOTE_BORDER_STYLE = "\x1b[38;5;244m";
const LIST_STYLE = "\x1b[38;5;45m";
const RULE_STYLE = "\x1b[38;5;240m";
const CODE_BORDER_STYLE = "\x1b[38;5;244m";

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

    pub fn renderInto(
        self: *const Markdown,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        if (std.mem.trim(u8, self.text, " \t\r\n").len == 0) return;

        const effective_width = @max(width, 1);
        const content_width = @max(effective_width, self.padding_x * 2 + 1) - self.padding_x * 2;

        const blank_line = try allocator.alloc(u8, effective_width);
        defer allocator.free(blank_line);
        @memset(blank_line, ' ');

        for (0..self.padding_y) |_| {
            try appendOwnedMarkdownLine(allocator, self.theme, blank_line, lines);
        }

        const normalized = try normalizeTabsAlloc(allocator, self.text);
        defer allocator.free(normalized);

        var source_lines = std.ArrayList([]const u8).empty;
        defer source_lines.deinit(allocator);
        var split = std.mem.splitScalar(u8, normalized, '\n');
        while (split.next()) |raw_line| {
            try source_lines.append(allocator, trimCarriageReturn(raw_line));
        }

        var paragraph_lines = std.ArrayList([]const u8).empty;
        defer paragraph_lines.deinit(allocator);

        var code_block_lines = std.ArrayList([]const u8).empty;
        defer code_block_lines.deinit(allocator);

        var in_code_block = false;
        var code_block_language: []const u8 = "";
        var line_index: usize = 0;
        while (line_index < source_lines.items.len) {
            const line = source_lines.items[line_index];
            const trimmed = std.mem.trim(u8, line, " \t");

            if (in_code_block) {
                if (isCodeFence(trimmed)) {
                    try renderCodeBlock(
                        allocator,
                        self.theme,
                        effective_width,
                        self.padding_x,
                        content_width,
                        code_block_language,
                        code_block_lines.items,
                        lines,
                    );
                    code_block_lines.clearRetainingCapacity();
                    code_block_language = "";
                    in_code_block = false;
                    line_index += 1;
                } else {
                    try code_block_lines.append(allocator, line);
                    line_index += 1;
                }
                continue;
            }

            if (trimmed.len == 0) {
                try flushParagraphLines(allocator, self.theme, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
                try appendOwnedMarkdownLine(allocator, self.theme, blank_line, lines);
                line_index += 1;
                continue;
            }

            if (isCodeFence(trimmed)) {
                try flushParagraphLines(allocator, self.theme, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
                in_code_block = true;
                code_block_language = std.mem.trim(u8, trimmed[3..], " \t");
                code_block_lines.clearRetainingCapacity();
                line_index += 1;
                continue;
            }

            if (parseHeadingLine(line)) |heading| {
                try flushParagraphLines(allocator, self.theme, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
                const formatted_heading = try renderInline(allocator, self.theme, heading.text);
                defer allocator.free(formatted_heading);

                const heading_style = if (heading.level == 1) HEADER_ONE_STYLE else HEADER_TWO_STYLE;
                const styled_heading = try styleWithThemeOrAnsiAlloc(allocator, self.theme, .markdown_heading, formatted_heading, heading_style);
                defer allocator.free(styled_heading);

                try appendWrappedText(allocator, effective_width, self.padding_x, content_width, styled_heading, lines);
                line_index += 1;
                continue;
            }

            if (isHorizontalRule(trimmed)) {
                try flushParagraphLines(allocator, self.theme, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
                const separator = try makeSeparatorLine(allocator, content_width);
                defer allocator.free(separator);
                const styled_separator = try styleWithThemeOrAnsiAlloc(allocator, self.theme, .markdown_rule, separator, RULE_STYLE);
                defer allocator.free(styled_separator);
                try appendWrappedText(allocator, effective_width, self.padding_x, content_width, styled_separator, lines);
                line_index += 1;
                continue;
            }

            if (detectTableBlock(source_lines.items, line_index)) |table_match| {
                try flushParagraphLines(allocator, self.theme, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
                try renderTableBlock(
                    allocator,
                    self.theme,
                    effective_width,
                    self.padding_x,
                    content_width,
                    source_lines.items[line_index],
                    source_lines.items[line_index + 2 .. table_match.end_index],
                    lines,
                );
                line_index = table_match.end_index;
                continue;
            }

            if (parseBlockquoteLine(line)) |quote| {
                try flushParagraphLines(allocator, self.theme, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
                const formatted_quote = try renderInline(allocator, self.theme, quote.text);
                defer allocator.free(formatted_quote);

                const styled_quote = try styleWithThemeOrAnsiAlloc(allocator, self.theme, .markdown_quote, formatted_quote, QUOTE_STYLE);
                defer allocator.free(styled_quote);

                const border_prefix = try formatQuoteBorderPrefix(allocator, self.theme);
                defer allocator.free(border_prefix);
                try appendWrappedPrefixedText(allocator, effective_width, self.padding_x, border_prefix, border_prefix, styled_quote, lines);
                line_index += 1;
                continue;
            }

            if (parseListItem(line)) |item| {
                try flushParagraphLines(allocator, self.theme, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
                const formatted_item = try renderInline(allocator, self.theme, item.text);
                defer allocator.free(formatted_item);

                const bullet_prefix = try formatListBulletPrefix(allocator, self.theme, item.indent, item.bullet);
                defer allocator.free(bullet_prefix);

                const bullet_width = ansi.visibleWidth(item.bullet);
                var continuation_builder = std.ArrayList(u8).empty;
                defer continuation_builder.deinit(allocator);
                try continuation_builder.appendSlice(allocator, item.indent);
                try continuation_builder.appendNTimes(allocator, ' ', bullet_width);

                try appendWrappedPrefixedText(
                    allocator,
                    effective_width,
                    self.padding_x,
                    bullet_prefix,
                    continuation_builder.items,
                    formatted_item,
                    lines,
                );
                line_index += 1;
                continue;
            }

            try paragraph_lines.append(allocator, line);
            line_index += 1;
        }

        try flushParagraphLines(allocator, self.theme, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
        if (in_code_block) {
            try renderCodeBlock(
                allocator,
                self.theme,
                effective_width,
                self.padding_x,
                content_width,
                code_block_language,
                code_block_lines.items,
                lines,
            );
        }

        for (0..self.padding_y) |_| {
            try appendOwnedMarkdownLine(allocator, self.theme, blank_line, lines);
        }
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
};

fn renderInline(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    text: []const u8,
) std.mem.Allocator.Error![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '[') {
            if (findLink(text, index)) |link| {
                const rendered_label = try renderInline(allocator, theme, text[index + 1 .. link.label_end]);
                defer allocator.free(rendered_label);

                const styled_label = try styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_link, rendered_label, LINK_STYLE);
                defer allocator.free(styled_label);

                try builder.appendSlice(allocator, styled_label);
                index = link.url_end + 1;
                continue;
            }
        }

        if (std.mem.startsWith(u8, text[index..], "**")) {
            if (findClosing(text, index + 2, "**")) |end| {
                if (theme) |_| {
                    const themed_bold = try styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_text, text[index + 2 .. end], "");
                    defer allocator.free(themed_bold);
                    try builder.appendSlice(allocator, BOLD_STYLE);
                    try builder.appendSlice(allocator, themed_bold);
                } else {
                    try builder.appendSlice(allocator, BOLD_STYLE);
                    try builder.appendSlice(allocator, text[index + 2 .. end]);
                    try builder.appendSlice(allocator, RESET);
                }
                index = end + 2;
                continue;
            }
        }

        if (text[index] == '*' and (index + 1 >= text.len or text[index + 1] != '*')) {
            if (findClosing(text, index + 1, "*")) |end| {
                if (theme) |_| {
                    const themed_italic = try styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_text, text[index + 1 .. end], "");
                    defer allocator.free(themed_italic);
                    try builder.appendSlice(allocator, ITALIC_STYLE);
                    try builder.appendSlice(allocator, themed_italic);
                } else {
                    try builder.appendSlice(allocator, ITALIC_STYLE);
                    try builder.appendSlice(allocator, text[index + 1 .. end]);
                    try builder.appendSlice(allocator, RESET);
                }
                index = end + 1;
                continue;
            }
        }

        if (text[index] == '`') {
            if (findClosing(text, index + 1, "`")) |end| {
                const styled_code = try styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_code, text[index + 1 .. end], CODE_STYLE);
                defer allocator.free(styled_code);
                try builder.appendSlice(allocator, styled_code);
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

        if (theme) |_| {
            const plain = try styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_text, text[plain_start..index], "");
            defer allocator.free(plain);
            try builder.appendSlice(allocator, plain);
        } else {
            try builder.appendSlice(allocator, text[plain_start..index]);
        }
    }

    return builder.toOwnedSlice(allocator);
}

fn normalizeTabsAlloc(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

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

const TableMatch = struct {
    end_index: usize,
};

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

fn renderCodeBlock(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    effective_width: usize,
    padding_x: usize,
    content_width: usize,
    language: []const u8,
    code_lines: []const []const u8,
    lines: *component_mod.LineList,
) std.mem.Allocator.Error!void {
    if (content_width < 4) {
        const fallback = if (language.len > 0)
            try std.fmt.allocPrint(allocator, "```{s}", .{language})
        else
            try allocator.dupe(u8, "```");
        defer allocator.free(fallback);
        try appendWrappedText(allocator, effective_width, padding_x, content_width, fallback, lines);
        for (code_lines) |code_line| {
            const styled = try styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_code, code_line, CODE_STYLE);
            defer allocator.free(styled);
            try appendWrappedText(allocator, effective_width, padding_x, content_width, styled, lines);
        }
        const closing = try allocator.dupe(u8, "```");
        defer allocator.free(closing);
        try appendWrappedText(allocator, effective_width, padding_x, content_width, closing, lines);
        return;
    }

    const top = try buildCodeBorderLine(allocator, theme, content_width, language, true);
    defer allocator.free(top);
    try appendMarkdownPaddedLine(allocator, effective_width, padding_x, top, lines);

    const inner_width = content_width - 4;
    const left_border = try styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_code_border, "│ ", CODE_BORDER_STYLE);
    defer allocator.free(left_border);
    const right_border = try styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_code_border, " │", CODE_BORDER_STYLE);
    defer allocator.free(right_border);

    if (code_lines.len == 0) {
        var empty_builder = std.ArrayList(u8).empty;
        defer empty_builder.deinit(allocator);
        try empty_builder.appendSlice(allocator, left_border);
        try empty_builder.appendNTimes(allocator, ' ', inner_width);
        try empty_builder.appendSlice(allocator, right_border);
        try appendMarkdownPaddedLine(allocator, effective_width, padding_x, empty_builder.items, lines);
    } else {
        for (code_lines) |code_line| {
            const styled_code = try styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_code, code_line, CODE_STYLE);
            defer allocator.free(styled_code);

            var wrapped = component_mod.LineList.empty;
            defer component_mod.freeLines(allocator, &wrapped);
            try ansi.wrapTextWithAnsi(allocator, styled_code, inner_width, &wrapped);

            for (wrapped.items) |wrapped_line| {
                const padded_cell = try ansi.padRightVisibleAlloc(allocator, wrapped_line, inner_width);
                defer allocator.free(padded_cell);

                var builder = std.ArrayList(u8).empty;
                defer builder.deinit(allocator);
                try builder.appendSlice(allocator, left_border);
                try builder.appendSlice(allocator, padded_cell);
                try builder.appendSlice(allocator, right_border);
                try appendMarkdownPaddedLine(allocator, effective_width, padding_x, builder.items, lines);
            }
        }
    }

    const bottom = try buildCodeBorderLine(allocator, theme, content_width, "", false);
    defer allocator.free(bottom);
    try appendMarkdownPaddedLine(allocator, effective_width, padding_x, bottom, lines);
}

fn renderTableBlock(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    effective_width: usize,
    padding_x: usize,
    content_width: usize,
    header_line: []const u8,
    row_lines: []const []const u8,
    lines: *component_mod.LineList,
) std.mem.Allocator.Error!void {
    const header_cells = try parseTableCellsAlloc(allocator, header_line);
    defer allocator.free(header_cells);
    if (header_cells.len == 0) return;

    const column_count = header_cells.len;
    const border_overhead = column_count * 3 + 1;
    if (content_width <= border_overhead) {
        try appendWrappedText(allocator, effective_width, padding_x, content_width, header_line, lines);
        return;
    }

    const row_cells = try allocator.alloc([]const []const u8, row_lines.len);
    @memset(row_cells, &.{});
    defer allocator.free(row_cells);
    var cells_parsed: usize = 0;
    for (row_lines, 0..) |row_line, index| {
        row_cells[index] = try parseTableCellsAlloc(allocator, row_line);
        cells_parsed = index + 1;
    }
    defer for (row_cells[0..cells_parsed]) |cells| allocator.free(cells);

    const column_widths = try allocator.alloc(usize, column_count);
    defer allocator.free(column_widths);
    for (column_widths) |*column_width| column_width.* = 3;

    try updateColumnWidths(allocator, theme, header_cells, column_widths, true);
    for (row_cells) |cells| {
        try updateColumnWidths(allocator, theme, cells, column_widths, false);
    }

    const available_width = content_width - border_overhead;
    shrinkColumnWidths(column_widths, available_width);

    const top = try buildTableBorderLine(allocator, theme, column_widths, .top);
    defer allocator.free(top);
    try appendMarkdownPaddedLine(allocator, effective_width, padding_x, top, lines);

    try appendTableRow(allocator, theme, effective_width, padding_x, header_cells, column_widths, true, lines);

    const middle = try buildTableBorderLine(allocator, theme, column_widths, .middle);
    defer allocator.free(middle);
    try appendMarkdownPaddedLine(allocator, effective_width, padding_x, middle, lines);

    for (row_cells, 0..) |cells, index| {
        try appendTableRow(allocator, theme, effective_width, padding_x, cells, column_widths, false, lines);
        if (index + 1 < row_cells.len) {
            try appendMarkdownPaddedLine(allocator, effective_width, padding_x, middle, lines);
        }
    }

    const bottom = try buildTableBorderLine(allocator, theme, column_widths, .bottom);
    defer allocator.free(bottom);
    try appendMarkdownPaddedLine(allocator, effective_width, padding_x, bottom, lines);
}

fn flushParagraphLines(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    effective_width: usize,
    content_width: usize,
    padding_x: usize,
    paragraph_lines: *std.ArrayList([]const u8),
    lines: *component_mod.LineList,
) std.mem.Allocator.Error!void {
    defer paragraph_lines.clearRetainingCapacity();
    if (paragraph_lines.items.len == 0) return;

    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);

    for (paragraph_lines.items) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (builder.items.len > 0) {
            try builder.append(allocator, ' ');
        }
        try builder.appendSlice(allocator, trimmed);
    }

    if (builder.items.len == 0) return;

    const formatted = try renderInline(allocator, theme, builder.items);
    defer allocator.free(formatted);
    try appendWrappedText(allocator, effective_width, padding_x, content_width, formatted, lines);
}

fn appendWrappedText(
    allocator: std.mem.Allocator,
    effective_width: usize,
    padding_x: usize,
    content_width: usize,
    text: []const u8,
    lines: *component_mod.LineList,
) std.mem.Allocator.Error!void {
    var wrapped = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &wrapped);
    try ansi.wrapTextWithAnsi(allocator, text, content_width, &wrapped);

    for (wrapped.items) |wrapped_line| {
        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);

        try builder.appendNTimes(allocator, ' ', padding_x);
        try builder.appendSlice(allocator, wrapped_line);

        const padded = try ansi.padRightVisibleAlloc(allocator, builder.items, effective_width);
        defer allocator.free(padded);
        try appendOwnedMarkdownLine(allocator, null, padded, lines);
        builder.deinit(allocator);
    }
}

fn appendStyledParagraphLine(
    allocator: std.mem.Allocator,
    effective_width: usize,
    padding_x: usize,
    text: []const u8,
    style: []const u8,
    lines: *component_mod.LineList,
) std.mem.Allocator.Error!void {
    const styled = try applyPersistentStyleAlloc(allocator, text, style);
    defer allocator.free(styled);
    const content_width = @max(effective_width, padding_x * 2 + 1) - padding_x * 2;
    try appendWrappedText(allocator, effective_width, padding_x, content_width, styled, lines);
}

fn appendWrappedPrefixedText(
    allocator: std.mem.Allocator,
    effective_width: usize,
    padding_x: usize,
    prefix: []const u8,
    continuation_prefix: []const u8,
    text: []const u8,
    lines: *component_mod.LineList,
) std.mem.Allocator.Error!void {
    const available_width = @max(effective_width, padding_x * 2 + ansi.visibleWidth(prefix) + 1) - padding_x * 2;
    const wrap_width = if (available_width > ansi.visibleWidth(prefix)) available_width - ansi.visibleWidth(prefix) else 1;

    var wrapped = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &wrapped);
    try ansi.wrapTextWithAnsi(allocator, text, wrap_width, &wrapped);

    for (wrapped.items, 0..) |wrapped_line, line_index| {
        const current_prefix = if (line_index == 0) prefix else continuation_prefix;

        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);
        try builder.appendNTimes(allocator, ' ', padding_x);
        try builder.appendSlice(allocator, current_prefix);
        try builder.appendSlice(allocator, wrapped_line);

        const padded = try ansi.padRightVisibleAlloc(allocator, builder.items, effective_width);
        defer allocator.free(padded);
        try appendOwnedMarkdownLine(allocator, null, padded, lines);
        builder.deinit(allocator);
    }
}

fn appendMarkdownPaddedLine(
    allocator: std.mem.Allocator,
    effective_width: usize,
    padding_x: usize,
    line: []const u8,
    lines: *component_mod.LineList,
) std.mem.Allocator.Error!void {
    var builder = std.ArrayList(u8).empty;
    defer builder.deinit(allocator);
    try builder.appendNTimes(allocator, ' ', padding_x);
    try builder.appendSlice(allocator, line);

    const padded = try ansi.padRightVisibleAlloc(allocator, builder.items, effective_width);
    defer allocator.free(padded);
    try appendOwnedMarkdownLine(allocator, null, padded, lines);
}

fn buildCodeBorderLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    width: usize,
    language: []const u8,
    top: bool,
) std.mem.Allocator.Error![]u8 {
    var plain = std.ArrayList(u8).empty;
    defer plain.deinit(allocator);

    const left = if (top) "┌" else "└";
    const right = if (top) "┐" else "┘";
    try plain.appendSlice(allocator, left);

    var remaining = width - 2;
    if (top and language.len > 0 and remaining > ansi.visibleWidth(language) + 2) {
        try plain.appendSlice(allocator, "─ ");
        try plain.appendSlice(allocator, language);
        try plain.appendSlice(allocator, " ");
        remaining -= ansi.visibleWidth(language) + 2;
    }
    for (0..remaining) |_| {
        try plain.appendSlice(allocator, "─");
    }
    try plain.appendSlice(allocator, right);

    return styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_code_border, plain.items, CODE_BORDER_STYLE);
}

const TableBorderPosition = enum {
    top,
    middle,
    bottom,
};

fn buildTableBorderLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    column_widths: []const usize,
    position: TableBorderPosition,
) std.mem.Allocator.Error![]u8 {
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

    var plain = std.ArrayList(u8).empty;
    defer plain.deinit(allocator);
    try plain.appendSlice(allocator, left);
    for (column_widths, 0..) |column_width, index| {
        try plain.appendSlice(allocator, "─");
        for (0..column_width) |_| {
            try plain.appendSlice(allocator, "─");
        }
        try plain.appendSlice(allocator, "─");
        if (index + 1 < column_widths.len) {
            try plain.appendSlice(allocator, mid);
        }
    }
    try plain.appendSlice(allocator, right);

    return styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_code_border, plain.items, CODE_BORDER_STYLE);
}

fn appendTableRow(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    effective_width: usize,
    padding_x: usize,
    cells: []const []const u8,
    column_widths: []const usize,
    header: bool,
    lines: *component_mod.LineList,
) std.mem.Allocator.Error!void {
    const CellWrap = struct {
        lines: component_mod.LineList = .empty,
    };

    const wrapped_cells = try allocator.alloc(CellWrap, column_widths.len);
    defer {
        for (wrapped_cells) |*cell| component_mod.freeLines(allocator, &cell.lines);
        allocator.free(wrapped_cells);
    }
    for (wrapped_cells) |*cell| cell.* = .{};

    var row_height: usize = 1;
    for (column_widths, 0..) |column_width, index| {
        const cell_text = if (index < cells.len) cells[index] else "";
        const rendered = try renderInline(allocator, theme, cell_text);
        defer allocator.free(rendered);

        const styled = if (header)
            try styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_heading, rendered, HEADER_TWO_STYLE)
        else
            try allocator.dupe(u8, rendered);
        defer allocator.free(styled);

        try ansi.wrapTextWithAnsi(allocator, styled, column_width, &wrapped_cells[index].lines);
        row_height = @max(row_height, @max(@as(usize, 1), wrapped_cells[index].lines.items.len));
    }

    const left_border = try styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_code_border, "│ ", CODE_BORDER_STYLE);
    defer allocator.free(left_border);
    const middle_border = try styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_code_border, " │ ", CODE_BORDER_STYLE);
    defer allocator.free(middle_border);
    const right_border = try styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_code_border, " │", CODE_BORDER_STYLE);
    defer allocator.free(right_border);

    for (0..row_height) |row_index| {
        var builder = std.ArrayList(u8).empty;
        defer builder.deinit(allocator);
        try builder.appendSlice(allocator, left_border);

        for (column_widths, 0..) |column_width, index| {
            const wrapped_line = if (row_index < wrapped_cells[index].lines.items.len)
                wrapped_cells[index].lines.items[row_index]
            else
                "";
            const padded = try ansi.padRightVisibleAlloc(allocator, wrapped_line, column_width);
            defer allocator.free(padded);
            try builder.appendSlice(allocator, padded);
            if (index + 1 < column_widths.len) {
                try builder.appendSlice(allocator, middle_border);
            }
        }

        try builder.appendSlice(allocator, right_border);
        try appendMarkdownPaddedLine(allocator, effective_width, padding_x, builder.items, lines);
    }
}

fn updateColumnWidths(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    cells: []const []const u8,
    column_widths: []usize,
    header: bool,
) std.mem.Allocator.Error!void {
    for (column_widths, 0..) |*column_width, index| {
        const cell_text = if (index < cells.len) cells[index] else "";
        const rendered = try renderInline(allocator, theme, cell_text);
        defer allocator.free(rendered);

        const styled = if (header)
            try styleWithThemeOrAnsiAlloc(allocator, theme, .markdown_heading, rendered, HEADER_TWO_STYLE)
        else
            try allocator.dupe(u8, rendered);
        defer allocator.free(styled);

        column_width.* = @max(column_width.*, @max(@as(usize, 3), ansi.visibleWidth(styled)));
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

fn appendOwnedMarkdownLine(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    line: []const u8,
    lines: *component_mod.LineList,
) std.mem.Allocator.Error!void {
    if (theme) |active_theme| {
        const themed = try active_theme.applyAlloc(allocator, .markdown_text, line);
        defer allocator.free(themed);
        try component_mod.appendOwnedLine(lines, allocator, themed);
        return;
    }
    try component_mod.appendOwnedLine(lines, allocator, line);
}

fn styleWithThemeOrAnsiAlloc(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    token: resources_mod.ThemeToken,
    text: []const u8,
    fallback_style: []const u8,
) std.mem.Allocator.Error![]u8 {
    if (theme) |active_theme| {
        return active_theme.applyAlloc(allocator, token, text);
    }
    return applyPersistentStyleAlloc(allocator, text, fallback_style);
}

fn formatQuoteBorderPrefix(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
) std.mem.Allocator.Error![]u8 {
    if (theme) |active_theme| {
        return active_theme.applyAlloc(allocator, .markdown_quote_border, "▍ ");
    }
    return std.fmt.allocPrint(allocator, "{s}▍{s} ", .{ QUOTE_BORDER_STYLE, RESET });
}

fn formatListBulletPrefix(
    allocator: std.mem.Allocator,
    theme: ?*const resources_mod.Theme,
    indent: []const u8,
    bullet: []const u8,
) std.mem.Allocator.Error![]u8 {
    if (theme) |active_theme| {
        const themed_bullet = try active_theme.applyAlloc(allocator, .markdown_list_bullet, bullet);
        defer allocator.free(themed_bullet);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ indent, themed_bullet });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{
        indent,
        LIST_STYLE,
        bullet,
        RESET,
    });
}

fn applyPersistentStyleAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    style: []const u8,
) std.mem.Allocator.Error![]u8 {
    if (style.len == 0) return allocator.dupe(u8, text);

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    try builder.appendSlice(allocator, style);

    var index: usize = 0;
    while (index < text.len) {
        if (std.mem.startsWith(u8, text[index..], RESET)) {
            try builder.appendSlice(allocator, RESET);
            try builder.appendSlice(allocator, style);
            index += RESET.len;
            continue;
        }

        try builder.append(allocator, text[index]);
        index += 1;
    }

    try builder.appendSlice(allocator, RESET);
    return builder.toOwnedSlice(allocator);
}

fn findClosing(text: []const u8, start: usize, marker: []const u8) ?usize {
    if (start >= text.len) return null;
    const relative = std.mem.indexOf(u8, text[start..], marker) orelse return null;
    const index = start + relative;
    if (index == start) return null;
    return index;
}

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
    return .{
        .text = remainder[content_start..],
    };
}

fn parseListItem(line: []const u8) ?ListItem {
    const indent_len = leadingWhitespaceLength(line);
    const remainder = line[indent_len..];
    if (remainder.len >= 2 and (remainder[0] == '-' or remainder[0] == '*' or remainder[0] == '+') and remainder[1] == ' ') {
        return .{
            .indent = line[0..indent_len],
            .bullet = "• ",
            .text = remainder[2..],
        };
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
    defer cells.deinit(allocator);

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
    const label_relative = std.mem.indexOfScalarPos(u8, text, start + 1, ']') orelse return null;
    if (label_relative + 1 >= text.len or text[label_relative + 1] != '(') return null;
    const url_relative = std.mem.indexOfScalarPos(u8, text, label_relative + 2, ')') orelse return null;
    if (label_relative == start + 1 or url_relative == label_relative + 2) return null;
    return .{
        .label_end = label_relative,
        .url_end = url_relative,
    };
}

fn makeSeparatorLine(allocator: std.mem.Allocator, width: usize) std.mem.Allocator.Error![]u8 {
    const separator_width = @max(width, 1);
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    for (0..separator_width) |_| {
        try builder.appendSlice(allocator, "─");
    }

    return builder.toOwnedSlice(allocator);
}

fn joinLines(allocator: std.mem.Allocator, lines: component_mod.LineList) std.mem.Allocator.Error![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    for (lines.items, 0..) |line, index| {
        if (index > 0) try builder.append(allocator, '\n');
        try builder.appendSlice(allocator, line);
    }

    return builder.toOwnedSlice(allocator);
}

test "markdown renders bold italic inline code and links" {
    const allocator = std.testing.allocator;

    const markdown = Markdown{
        .text = "**bold** *italic* `code` [link](https://example.com)",
        .padding_x = 1,
        .padding_y = 1,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try markdown.renderInto(allocator, 40, &lines);

    try std.testing.expect(lines.items.len >= 3);

    const joined = try joinLines(allocator, lines);
    defer allocator.free(joined);

    try std.testing.expect(std.mem.indexOf(u8, joined, BOLD_STYLE ++ "bold" ++ RESET) != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, ITALIC_STYLE ++ "italic" ++ RESET) != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, CODE_STYLE ++ "code" ++ RESET) != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, LINK_STYLE ++ "link" ++ RESET) != null);
}

test "markdown renders headings lists blockquotes rules and code blocks" {
    const allocator = std.testing.allocator;

    const markdown = Markdown{
        .text =
        \\# Header
        \\## Subheader
        \\
        \\Paragraph with [link](https://example.com)
        \\- bullet item
        \\1. ordered item
        \\> quoted text
        \\| Name | Role |
        \\| --- | --- |
        \\| Pi | Agent |
        \\---
        \\```zig
        \\const answer = 42;
        \\```
        ,
        .padding_x = 1,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try markdown.renderInto(allocator, 48, &lines);

    const joined = try joinLines(allocator, lines);
    defer allocator.free(joined);

    try std.testing.expect(std.mem.indexOf(u8, joined, HEADER_ONE_STYLE ++ "Header" ++ RESET) != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, HEADER_TWO_STYLE ++ "Subheader" ++ RESET) != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, LINK_STYLE ++ "link" ++ RESET) != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, LIST_STYLE ++ "• " ++ RESET ++ "bullet item") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, LIST_STYLE ++ "1. " ++ RESET ++ "ordered item") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, QUOTE_BORDER_STYLE ++ "▍" ++ RESET ++ " " ++ QUOTE_STYLE ++ "quoted text" ++ RESET) != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "│ " ++ HEADER_TWO_STYLE ++ "Name" ++ RESET) != null or std.mem.indexOf(u8, joined, "Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "Agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, RULE_STYLE ++ "────────────────") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, CODE_BORDER_STYLE ++ "┌─ zig ") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, CODE_STYLE ++ "const answer = 42;" ++ RESET) != null);
}

test "markdown wraps formatted block content to the available width" {
    const allocator = std.testing.allocator;

    const markdown = Markdown{
        .text =
        \\- A **bold** list item that should wrap onto more than one rendered line cleanly
        \\> A quoted paragraph that should also wrap over more than one rendered line
        ,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try markdown.renderInto(allocator, 20, &lines);

    try std.testing.expect(lines.items.len >= 2);
    for (lines.items) |line| {
        try std.testing.expectEqual(@as(usize, 20), ansi.visibleWidth(line));
    }
}

test "markdown applies theme tokens for headings links and code" {
    const allocator = std.testing.allocator;

    var theme = try resources_mod.Theme.initDefault(allocator);
    defer theme.deinit(allocator);

    const markdown = Markdown{
        .text = "# Heading\n[link](https://example.com)\n`code`",
        .theme = &theme,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try markdown.renderInto(allocator, 40, &lines);

    const joined = try joinLines(allocator, lines);
    defer allocator.free(joined);

    try std.testing.expect(std.mem.indexOf(u8, joined, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "Heading") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "link") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "code") != null);
}
