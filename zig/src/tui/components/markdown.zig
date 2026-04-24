const std = @import("std");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");

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

        var paragraph_iter = std.mem.splitScalar(u8, self.text, '\n');
        while (paragraph_iter.next()) |paragraph| {
            if (paragraph.len == 0) {
                try component_mod.appendOwnedLine(lines, allocator, blank_line);
                continue;
            }

            const formatted = try renderInline(allocator, paragraph);
            defer allocator.free(formatted);

            var wrapped = component_mod.LineList.empty;
            defer component_mod.freeLines(allocator, &wrapped);
            try ansi.wrapTextWithAnsi(allocator, formatted, content_width, &wrapped);

            for (wrapped.items) |wrapped_line| {
                var builder = std.ArrayList(u8).empty;
                errdefer builder.deinit(allocator);

                try builder.appendNTimes(allocator, ' ', self.padding_x);
                try builder.appendSlice(allocator, wrapped_line);

                const padded = try ansi.padRightVisibleAlloc(allocator, builder.items, effective_width);
                defer allocator.free(padded);
                try component_mod.appendOwnedLine(lines, allocator, padded);
                builder.deinit(allocator);
            }
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
        if (std.mem.startsWith(u8, text[index..], "**")) {
            if (findClosing(text, index + 2, "**")) |end| {
                try builder.appendSlice(allocator, "\x1b[1m");
                try builder.appendSlice(allocator, text[index + 2 .. end]);
                try builder.appendSlice(allocator, "\x1b[0m");
                index = end + 2;
                continue;
            }
        }

        if (text[index] == '*' and (index + 1 >= text.len or text[index + 1] != '*')) {
            if (findClosing(text, index + 1, "*")) |end| {
                try builder.appendSlice(allocator, "\x1b[3m");
                try builder.appendSlice(allocator, text[index + 1 .. end]);
                try builder.appendSlice(allocator, "\x1b[0m");
                index = end + 1;
                continue;
            }
        }

        if (text[index] == '`') {
            if (findClosing(text, index + 1, "`")) |end| {
                try builder.appendSlice(allocator, "\x1b[48;5;236m\x1b[38;5;214m");
                try builder.appendSlice(allocator, text[index + 1 .. end]);
                try builder.appendSlice(allocator, "\x1b[0m");
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

fn findClosing(text: []const u8, start: usize, marker: []const u8) ?usize {
    if (start >= text.len) return null;
    const relative = std.mem.indexOf(u8, text[start..], marker) orelse return null;
    const index = start + relative;
    if (index == start) return null;
    return index;
}

test "markdown renders bold italic and code formatting" {
    const allocator = std.testing.allocator;

    const markdown = Markdown{
        .text = "**bold** *italic* `code`",
        .padding_x = 1,
        .padding_y = 1,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try markdown.renderInto(allocator, 20, &lines);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "\x1b[1mbold\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "\x1b[3mitalic\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "\x1b[48;5;236m\x1b[38;5;214mcode\x1b[0m") != null);
}

test "markdown wraps formatted content to the available width" {
    const allocator = std.testing.allocator;

    const markdown = Markdown{
        .text = "A **bold** line that should wrap",
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try markdown.renderInto(allocator, 10, &lines);

    try std.testing.expect(lines.items.len >= 2);
    for (lines.items) |line| {
        try std.testing.expectEqual(@as(usize, 10), ansi.visibleWidth(line));
    }
}
