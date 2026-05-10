const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const style_mod = @import("../style.zig");
const test_helpers = @import("../test_helpers.zig");
const cell_rows = @import("../cell_rows.zig");
const resources_mod = @import("../theme.zig");

pub const BorderStyle = enum {
    none,
    single,
    double,
    thick,
};

pub const CornerStyle = enum {
    square,
    rounded,
};

const BorderGlyphs = struct {
    top_left: []const u8,
    top_right: []const u8,
    bottom_left: []const u8,
    bottom_right: []const u8,
    horizontal: []const u8,
    vertical: []const u8,
};

pub const Box = struct {
    padding_x: usize = 1,
    padding_y: usize = 1,
    theme: ?*const resources_mod.Theme = null,
    border_style: BorderStyle = .single,
    corner_style: CornerStyle = .square,
    children: std.ArrayList(draw_mod.Component) = .empty,

    pub fn init(padding_x: usize, padding_y: usize) Box {
        return .{
            .padding_x = padding_x,
            .padding_y = padding_y,
        };
    }

    pub fn deinit(self: *Box, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
        self.* = undefined;
    }

    pub fn addChild(self: *Box, allocator: std.mem.Allocator, child: draw_mod.Component) std.mem.Allocator.Error!void {
        try self.children.append(allocator, child);
    }

    pub fn drawComponent(self: *const Box) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Box,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (self.children.items.len == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        window.clear();
        const active_theme = ctx.theme orelse self.theme;
        const bordered = if (self.borderStyle(active_theme)) |border|
            window.child(.{ .border = border })
        else
            window;
        bordered.clear();

        const content_window = innerWindow(bordered, self.padding_x, self.padding_y) orelse {
            return .{ .width = window.width, .height = window.height };
        };

        for (self.children.items) |child| {
            _ = try child.draw(content_window, ctx);
        }

        return .{ .width = window.width, .height = window.height };
    }

    fn borderStyle(self: *const Box, theme: ?*const resources_mod.Theme) ?vaxis.Window.BorderOptions {
        if (self.border_style == .none) return null;
        return .{
            .where = .all,
            .style = if (theme) |active_theme| style_mod.styleFor(active_theme, .box_border) else .{},
            .glyphs = switch (self.border_style) {
                .none => unreachable,
                .single => if (self.corner_style == .rounded) .single_rounded else .single_square,
                .double => .{ .custom = .{ "╔", "═", "╗", "║", "╝", "╚" } },
                .thick => .{ .custom = .{ "┏", "━", "┓", "┃", "┛", "┗" } },
            },
        };
    }

    fn borderGlyphs(self: *const Box) BorderGlyphs {
        return switch (self.border_style) {
            .none => .{
                .top_left = "",
                .top_right = "",
                .bottom_left = "",
                .bottom_right = "",
                .horizontal = "",
                .vertical = "",
            },
            .single => switch (self.corner_style) {
                .square => .{
                    .top_left = "┌",
                    .top_right = "┐",
                    .bottom_left = "└",
                    .bottom_right = "┘",
                    .horizontal = "─",
                    .vertical = "│",
                },
                .rounded => .{
                    .top_left = "╭",
                    .top_right = "╮",
                    .bottom_left = "╰",
                    .bottom_right = "╯",
                    .horizontal = "─",
                    .vertical = "│",
                },
            },
            .double => .{
                .top_left = "╔",
                .top_right = "╗",
                .bottom_left = "╚",
                .bottom_right = "╝",
                .horizontal = "═",
                .vertical = "║",
            },
            .thick => .{
                .top_left = "┏",
                .top_right = "┓",
                .bottom_left = "┗",
                .bottom_right = "┛",
                .horizontal = "━",
                .vertical = "┃",
            },
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Box = @ptrCast(@alignCast(ptr));
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

fn renderBorderLine(
    allocator: std.mem.Allocator,
    theme: *const resources_mod.Theme,
    glyphs: BorderGlyphs,
    top: bool,
    interior_width: usize,
) std.mem.Allocator.Error![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    try builder.appendSlice(allocator, if (top) glyphs.top_left else glyphs.bottom_left);
    for (0..interior_width) |_| {
        try builder.appendSlice(allocator, glyphs.horizontal);
    }
    try builder.appendSlice(allocator, if (top) glyphs.top_right else glyphs.bottom_right);
    const themed = try theme.applyAlloc(allocator, .box_border, builder.items);
    builder.deinit(allocator);
    return themed;
}

fn renderInteriorLine(
    allocator: std.mem.Allocator,
    theme: *const resources_mod.Theme,
    glyphs: BorderGlyphs,
    child_line: []const u8,
    padding_x: usize,
    interior_width: usize,
) std.mem.Allocator.Error![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    try builder.appendSlice(allocator, glyphs.vertical);
    try builder.appendNTimes(allocator, ' ', padding_x);
    try builder.appendSlice(allocator, child_line);
    const padded = try ansi.padRightVisibleAlloc(allocator, builder.items, interior_width + 1);
    defer allocator.free(padded);

    var with_right = std.ArrayList(u8).empty;
    errdefer with_right.deinit(allocator);
    try with_right.appendSlice(allocator, padded);
    try with_right.appendSlice(allocator, glyphs.vertical);
    const themed = try theme.applyAlloc(allocator, .box_border, with_right.items);
    with_right.deinit(allocator);
    builder.deinit(allocator);
    return themed;
}

test "box renders nested text with outer padding" {
    const text = @import("text.zig").Text{
        .text = "hello",
        .padding_x = 0,
        .padding_y = 0,
    };

    var box = Box.init(1, 1);
    defer box.deinit(std.testing.allocator);
    box.border_style = .none;
    try box.addChild(std.testing.allocator, text.drawComponent());

    var screen = try test_helpers.renderToScreen(box.drawComponent(), 8, 3);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("        \n hello  \n        ", rendered);
}

test "box renders themed borders via vaxis child windows" {
    var theme = try resources_mod.Theme.initDefault(std.testing.allocator);
    defer theme.deinit(std.testing.allocator);

    const text = @import("text.zig").Text{
        .text = "hello",
        .padding_x = 0,
        .padding_y = 0,
    };

    var box = Box.init(1, 0);
    defer box.deinit(std.testing.allocator);
    box.theme = &theme;
    try box.addChild(std.testing.allocator, text.drawComponent());

    var screen = try test_helpers.renderToScreenWithTheme(box.drawComponent(), 9, 3, &theme);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("┌───────┐\n│ hello │\n└───────┘", rendered);
    try test_helpers.expectCell(&screen, 0, 0, "┌", style_mod.styleFor(&theme, .box_border));
    try test_helpers.expectCell(&screen, 8, 2, "┘", style_mod.styleFor(&theme, .box_border));
}

test "box supports rounded, double, and thick border styles" {
    const text = @import("text.zig").Text{
        .text = "polish",
        .padding_x = 0,
        .padding_y = 0,
    };

    var rounded = Box.init(1, 0);
    defer rounded.deinit(std.testing.allocator);
    rounded.corner_style = .rounded;
    try rounded.addChild(std.testing.allocator, text.drawComponent());

    var rounded_screen = try test_helpers.renderToScreen(rounded.drawComponent(), 12, 3);
    defer rounded_screen.deinit(std.testing.allocator);
    try test_helpers.expectCell(&rounded_screen, 0, 0, "╭", .{});
    try test_helpers.expectCell(&rounded_screen, 11, 2, "╯", .{});

    var double = Box.init(1, 0);
    defer double.deinit(std.testing.allocator);
    double.border_style = .double;
    try double.addChild(std.testing.allocator, text.drawComponent());

    var double_screen = try test_helpers.renderToScreen(double.drawComponent(), 12, 3);
    defer double_screen.deinit(std.testing.allocator);
    try test_helpers.expectCell(&double_screen, 0, 0, "╔", .{});
    try test_helpers.expectCell(&double_screen, 0, 1, "║", .{});

    var thick = Box.init(1, 0);
    defer thick.deinit(std.testing.allocator);
    thick.border_style = .thick;
    try thick.addChild(std.testing.allocator, text.drawComponent());

    var thick_screen = try test_helpers.renderToScreen(thick.drawComponent(), 12, 3);
    defer thick_screen.deinit(std.testing.allocator);
    try test_helpers.expectCell(&thick_screen, 0, 0, "┏", .{});
    try test_helpers.expectCell(&thick_screen, 0, 1, "┃", .{});
}
