const std = @import("std");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");

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
            try component_mod.appendOwnedLine(lines, allocator, blank_line);
        }

        const normalized = try normalizeTabsAlloc(allocator, self.text);
        defer allocator.free(normalized);

        var paragraph_lines = std.ArrayList([]const u8).empty;
        defer paragraph_lines.deinit(allocator);

        var in_code_block = false;
        var line_iter = std.mem.splitScalar(u8, normalized, '\n');
        while (line_iter.next()) |raw_line| {
            const line = trimCarriageReturn(raw_line);
            const trimmed = std.mem.trim(u8, line, " \t");

            if (in_code_block) {
                if (isCodeFence(trimmed)) {
                    try appendStyledParagraphLine(allocator, effective_width, self.padding_x, trimmed, CODE_BORDER_STYLE, lines);
                    in_code_block = false;
                } else {
                    const styled_code = try applyPersistentStyleAlloc(allocator, line, CODE_STYLE);
                    defer allocator.free(styled_code);
                    try appendWrappedPrefixedText(allocator, effective_width, self.padding_x, "  ", "  ", styled_code, lines);
                }
                continue;
            }

            if (trimmed.len == 0) {
                try flushParagraphLines(allocator, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
                try component_mod.appendOwnedLine(lines, allocator, blank_line);
                continue;
            }

            if (isCodeFence(trimmed)) {
                try flushParagraphLines(allocator, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
                try appendStyledParagraphLine(allocator, effective_width, self.padding_x, trimmed, CODE_BORDER_STYLE, lines);
                in_code_block = true;
                continue;
            }

            if (parseHeadingLine(line)) |heading| {
                try flushParagraphLines(allocator, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
                const formatted_heading = try renderInline(allocator, heading.text);
                defer allocator.free(formatted_heading);

                const heading_style = if (heading.level == 1) HEADER_ONE_STYLE else HEADER_TWO_STYLE;
                const styled_heading = try applyPersistentStyleAlloc(allocator, formatted_heading, heading_style);
                defer allocator.free(styled_heading);

                try appendWrappedText(allocator, effective_width, self.padding_x, content_width, styled_heading, lines);
                continue;
            }

            if (isHorizontalRule(trimmed)) {
                try flushParagraphLines(allocator, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
                const separator = try makeSeparatorLine(allocator, content_width);
                defer allocator.free(separator);
                try appendStyledParagraphLine(allocator, effective_width, self.padding_x, separator, RULE_STYLE, lines);
                continue;
            }

            if (parseBlockquoteLine(line)) |quote| {
                try flushParagraphLines(allocator, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
                const formatted_quote = try renderInline(allocator, quote.text);
                defer allocator.free(formatted_quote);

                const styled_quote = try applyPersistentStyleAlloc(allocator, formatted_quote, QUOTE_STYLE);
                defer allocator.free(styled_quote);

                const border_prefix = try std.fmt.allocPrint(allocator, "{s}│{s} ", .{ QUOTE_BORDER_STYLE, RESET });
                defer allocator.free(border_prefix);
                try appendWrappedPrefixedText(allocator, effective_width, self.padding_x, border_prefix, border_prefix, styled_quote, lines);
                continue;
            }

            if (parseListItem(line)) |item| {
                try flushParagraphLines(allocator, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
                const formatted_item = try renderInline(allocator, item.text);
                defer allocator.free(formatted_item);

                const bullet_prefix = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{
                    item.indent,
                    LIST_STYLE,
                    item.bullet,
                    RESET,
                });
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
                continue;
            }

            try paragraph_lines.append(allocator, line);
        }

        try flushParagraphLines(allocator, effective_width, content_width, self.padding_x, &paragraph_lines, lines);
        if (in_code_block) {
            try appendStyledParagraphLine(allocator, effective_width, self.padding_x, "```", CODE_BORDER_STYLE, lines);
        }

        for (0..self.padding_y) |_| {
            try component_mod.appendOwnedLine(lines, allocator, blank_line);
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

fn renderInline(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '[') {
            if (findLink(text, index)) |link| {
                const rendered_label = try renderInline(allocator, text[index + 1 .. link.label_end]);
                defer allocator.free(rendered_label);

                const styled_label = try applyPersistentStyleAlloc(allocator, rendered_label, LINK_STYLE);
                defer allocator.free(styled_label);

                try builder.appendSlice(allocator, styled_label);
                index = link.url_end + 1;
                continue;
            }
        }

        if (std.mem.startsWith(u8, text[index..], "**")) {
            if (findClosing(text, index + 2, "**")) |end| {
                try builder.appendSlice(allocator, BOLD_STYLE);
                try builder.appendSlice(allocator, text[index + 2 .. end]);
                try builder.appendSlice(allocator, RESET);
                index = end + 2;
                continue;
            }
        }

        if (text[index] == '*' and (index + 1 >= text.len or text[index + 1] != '*')) {
            if (findClosing(text, index + 1, "*")) |end| {
                try builder.appendSlice(allocator, ITALIC_STYLE);
                try builder.appendSlice(allocator, text[index + 1 .. end]);
                try builder.appendSlice(allocator, RESET);
                index = end + 1;
                continue;
            }
        }

        if (text[index] == '`') {
            if (findClosing(text, index + 1, "`")) |end| {
                try builder.appendSlice(allocator, CODE_STYLE);
                try builder.appendSlice(allocator, text[index + 1 .. end]);
                try builder.appendSlice(allocator, RESET);
                index = end + 1;
                continue;
            }
        }

        const rune_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const actual_len = @min(rune_len, text.len - index);
        try builder.appendSlice(allocator, text[index .. index + actual_len]);
        index += actual_len;
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

fn flushParagraphLines(
    allocator: std.mem.Allocator,
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

    const formatted = try renderInline(allocator, builder.items);
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
        try component_mod.appendOwnedLine(lines, allocator, padded);
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
        try component_mod.appendOwnedLine(lines, allocator, padded);
        builder.deinit(allocator);
    }
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
    try std.testing.expect(std.mem.indexOf(u8, joined, QUOTE_BORDER_STYLE ++ "│" ++ RESET ++ " " ++ QUOTE_STYLE ++ "quoted text" ++ RESET) != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, RULE_STYLE ++ "────────────────") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, CODE_BORDER_STYLE ++ "```zig" ++ RESET) != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, CODE_STYLE ++ "const answer = 42." ++ RESET) == null);
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
