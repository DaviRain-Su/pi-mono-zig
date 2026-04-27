const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const draw_mod = @import("../draw.zig");
const style_mod = @import("../style.zig");
const test_helpers = @import("../test_helpers.zig");
const resources_mod = @import("../theme.zig");

pub const TextGradient = struct {
    start_hex: []const u8,
    end_hex: []const u8,
};

pub const Text = struct {
    text: []const u8 = "",
    padding_x: usize = 1,
    padding_y: usize = 1,
    theme: ?*const resources_mod.Theme = null,
    gradient: ?TextGradient = null,

    pub fn component(self: *const Text) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn drawComponent(self: *const Text) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Text,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (std.mem.trim(u8, self.text, " \t\r\n").len == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        const active_theme = ctx.theme orelse self.theme;
        const base_style = if (active_theme) |theme|
            style_mod.styleFor(theme, .text)
        else
            vaxis.Cell.Style{};
        fillWindow(window, active_theme != null, base_style);

        const content_window = innerWindow(window, self.padding_x, self.padding_y) orelse {
            return .{ .width = window.width, .height = @min(window.height, @as(u16, @intCast(self.padding_y * 2))) };
        };

        var segments = std.ArrayList(vaxis.Segment).empty;
        try self.appendSegments(ctx.arena, &segments, base_style);

        const result = content_window.print(segments.items, .{ .wrap = .grapheme });
        const rendered_height = renderedLineCount(result, segments.items.len > 0, content_window.height);
        const total_height = @min(
            window.height,
            @as(u16, @intCast(@min(@as(usize, std.math.maxInt(u16)), self.padding_y * 2 + rendered_height))),
        );
        return .{ .width = window.width, .height = total_height };
    }

    pub fn renderInto(
        self: *const Text,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        if (std.mem.trim(u8, self.text, " \t\r\n").len == 0) return;

        const effective_width = @max(width, 1);
        const content_width = @max(effective_width, self.padding_x * 2 + 1) - self.padding_x * 2;

        var wrapped = component_mod.LineList.empty;
        defer component_mod.freeLines(allocator, &wrapped);
        try ansi.wrapTextAlloc(allocator, self.text, content_width, &wrapped);

        const blank_line = try allocator.alloc(u8, effective_width);
        defer allocator.free(blank_line);
        @memset(blank_line, ' ');

        for (0..self.padding_y) |_| {
            if (self.theme) |theme| {
                const themed = try theme.applyAlloc(allocator, .text, blank_line);
                defer allocator.free(themed);
                try component_mod.appendOwnedLine(lines, allocator, themed);
            } else {
                try component_mod.appendOwnedLine(lines, allocator, blank_line);
            }
        }

        for (wrapped.items) |line| {
            const rendered_line = try self.renderLineAlloc(allocator, line);
            defer allocator.free(rendered_line);

            var builder = std.ArrayList(u8).empty;
            errdefer builder.deinit(allocator);

            try builder.appendNTimes(allocator, ' ', self.padding_x);
            try builder.appendSlice(allocator, rendered_line);

            const padded = try ansi.padRightVisibleAlloc(allocator, builder.items, effective_width);
            defer allocator.free(padded);
            if (self.gradient != null) {
                try component_mod.appendOwnedLine(lines, allocator, padded);
            } else if (self.theme) |theme| {
                const themed = try theme.applyAlloc(allocator, .text, padded);
                defer allocator.free(themed);
                try component_mod.appendOwnedLine(lines, allocator, themed);
            } else {
                try component_mod.appendOwnedLine(lines, allocator, padded);
            }
            builder.deinit(allocator);
        }

        for (0..self.padding_y) |_| {
            if (self.theme) |theme| {
                const themed = try theme.applyAlloc(allocator, .text, blank_line);
                defer allocator.free(themed);
                try component_mod.appendOwnedLine(lines, allocator, themed);
            } else {
                try component_mod.appendOwnedLine(lines, allocator, blank_line);
            }
        }
    }

    fn appendSegments(
        self: *const Text,
        allocator: std.mem.Allocator,
        segments: *std.ArrayList(vaxis.Segment),
        base_style: vaxis.Cell.Style,
    ) std.mem.Allocator.Error!void {
        const gradient = self.gradient orelse {
            try segments.append(allocator, .{
                .text = self.text,
                .style = base_style,
            });
            return;
        };

        const start = ansi.parseHexColor(gradient.start_hex) orelse {
            try segments.append(allocator, .{ .text = self.text, .style = base_style });
            return;
        };
        const end = ansi.parseHexColor(gradient.end_hex) orelse {
            try segments.append(allocator, .{ .text = self.text, .style = base_style });
            return;
        };

        const visible_clusters = countVisibleClusters(self.text);
        if (visible_clusters == 0) {
            try segments.append(allocator, .{ .text = self.text, .style = base_style });
            return;
        }

        var cluster_index: usize = 0;
        var index: usize = 0;
        while (index < self.text.len) {
            const cluster = ansi.nextDisplayCluster(self.text, index);
            if (cluster.end <= index) break;

            var segment_style = base_style;
            if (cluster.width > 0) {
                const color = interpolateGradientColor(start, end, cluster_index, visible_clusters);
                segment_style.fg = .{ .rgb = .{ color.r, color.g, color.b } };
                cluster_index += 1;
            }

            try segments.append(allocator, .{
                .text = self.text[index..cluster.end],
                .style = segment_style,
            });
            index = cluster.end;
        }
    }

    fn renderLineAlloc(self: *const Text, allocator: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error![]u8 {
        _ = self;
        return allocator.dupe(u8, line);
    }

    fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const Text = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Text = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

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

fn fillWindow(window: vaxis.Window, themed: bool, style: vaxis.Cell.Style) void {
    if (!themed) {
        window.clear();
        return;
    }
    window.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = style,
    });
}

fn renderedLineCount(result: vaxis.Window.PrintResult, had_text: bool, max_height: u16) usize {
    if (!had_text or max_height == 0) return 0;
    if (result.overflow) return max_height;
    return @min(max_height, result.row + if (result.col > 0) @as(u16, 1) else 0);
}

fn countVisibleClusters(text: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const cluster = ansi.nextDisplayCluster(text, index);
        if (cluster.end <= index) break;
        if (cluster.width > 0) count += 1;
        index = cluster.end;
    }
    return count;
}

fn interpolateGradientColor(start: ansi.RgbColor, end: ansi.RgbColor, index: usize, total: usize) ansi.RgbColor {
    if (total <= 1) return start;
    return .{
        .r = interpolateChannel(start.r, end.r, index, total),
        .g = interpolateChannel(start.g, end.g, index, total),
        .b = interpolateChannel(start.b, end.b, index, total),
    };
}

fn interpolateChannel(start: u8, end: u8, index: usize, total: usize) u8 {
    if (total <= 1 or start == end) return start;
    const ratio = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(total - 1));
    const start_value = @as(f32, @floatFromInt(start));
    const delta = @as(f32, @floatFromInt(end)) - @as(f32, @floatFromInt(start));
    return @intFromFloat(@round(start_value + delta * ratio));
}

test "text renders wrapped content with themed padding via cells" {
    var theme = try resources_mod.Theme.initDefault(std.testing.allocator);
    defer theme.deinit(std.testing.allocator);

    const text = Text{
        .text = "red blue",
        .padding_x = 1,
        .padding_y = 1,
    };

    var screen = try test_helpers.renderToScreenWithTheme(text.drawComponent(), 6, 4, &theme);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("      \n red  \n blue \n      ", rendered);

    const text_style = style_mod.styleFor(&theme, .text);
    try test_helpers.expectCell(&screen, 0, 0, " ", text_style);
    try test_helpers.expectCell(&screen, 1, 1, "r", text_style);
    try test_helpers.expectCell(&screen, 1, 2, "b", text_style);
}

test "text supports horizontal gradients with per-grapheme colors" {
    const text = Text{
        .text = "Glow",
        .padding_x = 0,
        .padding_y = 0,
        .gradient = .{
            .start_hex = "#ff0000",
            .end_hex = "#0000ff",
        },
    };

    var screen = try test_helpers.renderToScreen(text.drawComponent(), 4, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "G", .{ .fg = .{ .rgb = .{ 255, 0, 0 } } });
    try test_helpers.expectCell(&screen, 3, 0, "w", .{ .fg = .{ .rgb = .{ 0, 0, 255 } } });

    const middle_left = screen.readCell(1, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(middle_left.style.fg != .default);
}
