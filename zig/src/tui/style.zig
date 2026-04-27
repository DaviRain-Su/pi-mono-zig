const std = @import("std");
const vaxis = @import("vaxis");
const theme_mod = @import("theme.zig");

pub fn styleFor(theme: *const theme_mod.Theme, token: theme_mod.ThemeToken) vaxis.Cell.Style {
    return styleFromSpec(theme.styles[@intFromEnum(token)]);
}

pub fn styleFromSpec(spec: theme_mod.StyleSpec) vaxis.Cell.Style {
    return .{
        .fg = parseColor(spec.fg),
        .bg = parseColor(spec.bg),
        .bold = spec.bold,
        .dim = spec.dim,
        .italic = spec.italic,
        .ul_style = if (spec.underline) .single else .off,
    };
}

fn parseColor(value: ?[]const u8) vaxis.Cell.Color {
    const color = value orelse return .default;
    if (parseNamedColor(color)) |named| {
        return .{ .index = named };
    }
    if (color.len == 7 and color[0] == '#') {
        const r = std.fmt.parseInt(u8, color[1..3], 16) catch return .default;
        const g = std.fmt.parseInt(u8, color[3..5], 16) catch return .default;
        const b = std.fmt.parseInt(u8, color[5..7], 16) catch return .default;
        return .{ .rgb = .{ r, g, b } };
    }
    return .default;
}

fn parseNamedColor(value: []const u8) ?u8 {
    if (std.mem.eql(u8, value, "black")) return 0;
    if (std.mem.eql(u8, value, "red")) return 1;
    if (std.mem.eql(u8, value, "green")) return 2;
    if (std.mem.eql(u8, value, "yellow")) return 3;
    if (std.mem.eql(u8, value, "blue")) return 4;
    if (std.mem.eql(u8, value, "magenta")) return 5;
    if (std.mem.eql(u8, value, "cyan")) return 6;
    if (std.mem.eql(u8, value, "white")) return 7;
    return null;
}

test "styleFor maps representative theme tokens to vaxis styles" {
    var theme = try theme_mod.Theme.initDefault(std.testing.allocator);
    defer theme.deinit(std.testing.allocator);

    const welcome = styleFor(&theme, .welcome);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 158, 206, 106 } }, welcome.fg);
    try std.testing.expect(welcome.bold);

    const selected = styleFor(&theme, .select_selected);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 26, 27, 38 } }, selected.fg);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 122, 162, 247 } }, selected.bg);
    try std.testing.expect(selected.bold);

    const link = styleFor(&theme, .markdown_link);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 187, 154, 247 } }, link.fg);
    try std.testing.expectEqual(vaxis.Cell.Style.Underline.single, link.ul_style);

    const empty = styleFor(&theme, .select_empty);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 127, 132, 156 } }, empty.fg);
    try std.testing.expect(empty.italic);

    const prompt_glyph = styleFor(&theme, .prompt_glyph);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 122, 162, 247 } }, prompt_glyph.fg);
    try std.testing.expect(prompt_glyph.bold);

    const prompt_border = styleFor(&theme, .prompt_border);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 65, 72, 104 } }, prompt_border.fg);

    const terminal_badge = styleFor(&theme, .terminal_badge);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 127, 132, 156 } }, terminal_badge.fg);
    try std.testing.expect(!terminal_badge.bold);
}
