const std = @import("std");

pub const ThemeColor = enum(u8) {
    primary,
    secondary,
    success,
    warning,
    @"error",
    background,
    foreground,
    border,
    muted,
};

pub const ThemeToken = enum(u8) {
    welcome,
    user,
    assistant,
    tool_call,
    tool_result,
    @"error",
    status,
    footer,
    prompt,
    box_border,
    text,
    editor,
    editor_cursor,
    select_selected,
    select_description,
    select_scroll,
    select_empty,
    markdown_text,
    markdown_heading,
    markdown_link,
    markdown_code,
    markdown_code_border,
    markdown_quote,
    markdown_quote_border,
    markdown_list_bullet,
    markdown_rule,
    overlay_title,
    overlay_hint,
};

pub const StyleSpec = struct {
    fg: ?[]u8 = null,
    bg: ?[]u8 = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,

    fn clone(self: StyleSpec, allocator: std.mem.Allocator) !StyleSpec {
        return .{
            .fg = if (self.fg) |value| try allocator.dupe(u8, value) else null,
            .bg = if (self.bg) |value| try allocator.dupe(u8, value) else null,
            .bold = self.bold,
            .italic = self.italic,
            .underline = self.underline,
        };
    }

    fn deinit(self: *StyleSpec, allocator: std.mem.Allocator) void {
        if (self.fg) |value| allocator.free(value);
        if (self.bg) |value| allocator.free(value);
        self.* = .{};
    }
};

pub const ThemeColors = struct {
    primary: ?[]u8 = null,
    secondary: ?[]u8 = null,
    success: ?[]u8 = null,
    warning: ?[]u8 = null,
    @"error": ?[]u8 = null,
    background: ?[]u8 = null,
    foreground: ?[]u8 = null,
    border: ?[]u8 = null,
    muted: ?[]u8 = null,

    fn clone(self: ThemeColors, allocator: std.mem.Allocator) !ThemeColors {
        return .{
            .primary = if (self.primary) |value| try allocator.dupe(u8, value) else null,
            .secondary = if (self.secondary) |value| try allocator.dupe(u8, value) else null,
            .success = if (self.success) |value| try allocator.dupe(u8, value) else null,
            .warning = if (self.warning) |value| try allocator.dupe(u8, value) else null,
            .@"error" = if (self.@"error") |value| try allocator.dupe(u8, value) else null,
            .background = if (self.background) |value| try allocator.dupe(u8, value) else null,
            .foreground = if (self.foreground) |value| try allocator.dupe(u8, value) else null,
            .border = if (self.border) |value| try allocator.dupe(u8, value) else null,
            .muted = if (self.muted) |value| try allocator.dupe(u8, value) else null,
        };
    }

    fn deinit(self: *ThemeColors, allocator: std.mem.Allocator) void {
        if (self.primary) |value| allocator.free(value);
        if (self.secondary) |value| allocator.free(value);
        if (self.success) |value| allocator.free(value);
        if (self.warning) |value| allocator.free(value);
        if (self.@"error") |value| allocator.free(value);
        if (self.background) |value| allocator.free(value);
        if (self.foreground) |value| allocator.free(value);
        if (self.border) |value| allocator.free(value);
        if (self.muted) |value| allocator.free(value);
        self.* = .{};
    }

    fn get(self: ThemeColors, color: ThemeColor) ?[]const u8 {
        return switch (color) {
            .primary => self.primary,
            .secondary => self.secondary,
            .success => self.success,
            .warning => self.warning,
            .@"error" => self.@"error",
            .background => self.background,
            .foreground => self.foreground,
            .border => self.border,
            .muted => self.muted,
        };
    }

    fn replace(self: *ThemeColors, allocator: std.mem.Allocator, color: ThemeColor, value: []const u8) !void {
        const target = switch (color) {
            .primary => &self.primary,
            .secondary => &self.secondary,
            .success => &self.success,
            .warning => &self.warning,
            .@"error" => &self.@"error",
            .background => &self.background,
            .foreground => &self.foreground,
            .border => &self.border,
            .muted => &self.muted,
        };
        if (target.*) |existing| allocator.free(existing);
        target.* = try allocator.dupe(u8, value);
    }
};

pub const Theme = struct {
    name: []u8,
    colors: ThemeColors = .{},
    styles: [@typeInfo(ThemeToken).@"enum".fields.len]StyleSpec = defaultThemeStyles(),

    pub fn initDefault(allocator: std.mem.Allocator) !Theme {
        return initNamed(allocator, "dark", defaultDarkPalette());
    }

    pub fn initLight(allocator: std.mem.Allocator) !Theme {
        return initNamed(allocator, "light", defaultLightPalette());
    }

    pub fn clone(self: Theme, allocator: std.mem.Allocator) !Theme {
        var styles = defaultThemeStyles();
        for (&styles, self.styles) |*target, source| {
            target.* = try source.clone(allocator);
        }
        return .{
            .name = try allocator.dupe(u8, self.name),
            .colors = try self.colors.clone(allocator),
            .styles = styles,
        };
    }

    pub fn deinit(self: *Theme, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.colors.deinit(allocator);
        for (&self.styles) |*style| style.deinit(allocator);
        self.* = undefined;
    }

    pub fn applyAlloc(self: *const Theme, allocator: std.mem.Allocator, token: ThemeToken, text: []const u8) ![]u8 {
        const style = self.styles[@intFromEnum(token)];
        if (style.fg == null and style.bg == null and !style.bold and !style.italic and !style.underline) {
            return allocator.dupe(u8, text);
        }

        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);
        if (style.bold) try builder.appendSlice(allocator, "\x1b[1m");
        if (style.italic) try builder.appendSlice(allocator, "\x1b[3m");
        if (style.underline) try builder.appendSlice(allocator, "\x1b[4m");
        if (style.fg) |value| try appendColorAnsi(allocator, &builder, value, true);
        if (style.bg) |value| try appendColorAnsi(allocator, &builder, value, false);
        try builder.appendSlice(allocator, text);
        try builder.appendSlice(allocator, "\x1b[0m");
        return try builder.toOwnedSlice(allocator);
    }

    pub fn setColor(self: *Theme, allocator: std.mem.Allocator, color: ThemeColor, value: []const u8) !void {
        try self.colors.replace(allocator, color, value);
    }

    pub fn applyDerivedStyles(self: *Theme, allocator: std.mem.Allocator) !void {
        for (&self.styles) |*style| style.deinit(allocator);
        self.styles = defaultThemeStyles();

        try self.setDerivedStyle(allocator, .welcome, .{ .fg = self.colors.get(.success), .bold = true });
        try self.setDerivedStyle(allocator, .user, .{ .fg = self.colors.get(.secondary), .bold = true });
        try self.setDerivedStyle(allocator, .assistant, .{ .fg = self.colors.get(.primary), .bold = true });
        try self.setDerivedStyle(allocator, .tool_call, .{ .fg = self.colors.get(.secondary) });
        try self.setDerivedStyle(allocator, .tool_result, .{ .fg = self.colors.get(.foreground) });
        try self.setDerivedStyle(allocator, .@"error", .{ .fg = self.colors.get(.@"error"), .bold = true });
        try self.setDerivedStyle(allocator, .status, .{ .fg = self.colors.get(.muted) });
        try self.setDerivedStyle(allocator, .footer, .{ .fg = self.colors.get(.muted) });
        try self.setDerivedStyle(allocator, .prompt, .{ .fg = self.colors.get(.primary), .bold = true });
        try self.setDerivedStyle(allocator, .box_border, .{ .fg = self.colors.get(.border) });
        try self.setDerivedStyle(allocator, .text, .{ .fg = self.colors.get(.foreground), .bg = self.colors.get(.background) });
        try self.setDerivedStyle(allocator, .editor, .{ .fg = self.colors.get(.foreground), .bg = self.colors.get(.background) });
        try self.setDerivedStyle(allocator, .editor_cursor, .{ .fg = self.colors.get(.background), .bg = self.colors.get(.primary), .bold = true });
        try self.setDerivedStyle(allocator, .select_selected, .{ .fg = self.colors.get(.background), .bg = self.colors.get(.primary), .bold = true });
        try self.setDerivedStyle(allocator, .select_description, .{ .fg = self.colors.get(.muted) });
        try self.setDerivedStyle(allocator, .select_scroll, .{ .fg = self.colors.get(.muted) });
        try self.setDerivedStyle(allocator, .select_empty, .{ .fg = self.colors.get(.muted), .italic = true });
        try self.setDerivedStyle(allocator, .markdown_text, .{ .fg = self.colors.get(.foreground) });
        try self.setDerivedStyle(allocator, .markdown_heading, .{ .fg = self.colors.get(.primary), .bold = true });
        try self.setDerivedStyle(allocator, .markdown_link, .{ .fg = self.colors.get(.secondary), .underline = true });
        try self.setDerivedStyle(allocator, .markdown_code, .{ .fg = self.colors.get(.warning) });
        try self.setDerivedStyle(allocator, .markdown_code_border, .{ .fg = self.colors.get(.border) });
        try self.setDerivedStyle(allocator, .markdown_quote, .{ .fg = self.colors.get(.muted), .italic = true });
        try self.setDerivedStyle(allocator, .markdown_quote_border, .{ .fg = self.colors.get(.border) });
        try self.setDerivedStyle(allocator, .markdown_list_bullet, .{ .fg = self.colors.get(.secondary) });
        try self.setDerivedStyle(allocator, .markdown_rule, .{ .fg = self.colors.get(.border) });
        try self.setDerivedStyle(allocator, .overlay_title, .{ .fg = self.colors.get(.primary), .bold = true });
        try self.setDerivedStyle(allocator, .overlay_hint, .{ .fg = self.colors.get(.muted) });
    }

    fn setDerivedStyle(self: *Theme, allocator: std.mem.Allocator, token: ThemeToken, style: StyleTemplate) !void {
        self.styles[@intFromEnum(token)] = try style.owned(allocator);
    }
};

fn defaultThemeStyles() [@typeInfo(ThemeToken).@"enum".fields.len]StyleSpec {
    var styles: [@typeInfo(ThemeToken).@"enum".fields.len]StyleSpec = undefined;
    for (&styles) |*style| style.* = .{};
    return styles;
}

const StyleTemplate = struct {
    fg: ?[]const u8 = null,
    bg: ?[]const u8 = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,

    fn owned(self: StyleTemplate, allocator: std.mem.Allocator) !StyleSpec {
        return .{
            .fg = if (self.fg) |value| try allocator.dupe(u8, value) else null,
            .bg = if (self.bg) |value| try allocator.dupe(u8, value) else null,
            .bold = self.bold,
            .italic = self.italic,
            .underline = self.underline,
        };
    }
};

const PaletteTemplate = struct {
    primary: []const u8,
    secondary: []const u8,
    success: []const u8,
    warning: []const u8,
    @"error": []const u8,
    background: []const u8,
    foreground: []const u8,
    border: []const u8,
    muted: []const u8,
};

fn defaultDarkPalette() PaletteTemplate {
    return .{
        .primary = "#7aa2f7",
        .secondary = "#bb9af7",
        .success = "#9ece6a",
        .warning = "#e0af68",
        .@"error" = "#f7768e",
        .background = "#1a1b26",
        .foreground = "#c0caf5",
        .border = "#414868",
        .muted = "#7f849c",
    };
}

fn defaultLightPalette() PaletteTemplate {
    return .{
        .primary = "#3451b2",
        .secondary = "#6f42c1",
        .success = "#2f8f4e",
        .warning = "#a05a00",
        .@"error" = "#c1392b",
        .background = "#f6f8fa",
        .foreground = "#1f2328",
        .border = "#afb8c1",
        .muted = "#57606a",
    };
}

fn initNamed(allocator: std.mem.Allocator, name: []const u8, palette: PaletteTemplate) !Theme {
    var theme = Theme{
        .name = try allocator.dupe(u8, name),
    };
    errdefer theme.deinit(allocator);

    try theme.setColor(allocator, .primary, palette.primary);
    try theme.setColor(allocator, .secondary, palette.secondary);
    try theme.setColor(allocator, .success, palette.success);
    try theme.setColor(allocator, .warning, palette.warning);
    try theme.setColor(allocator, .@"error", palette.@"error");
    try theme.setColor(allocator, .background, palette.background);
    try theme.setColor(allocator, .foreground, palette.foreground);
    try theme.setColor(allocator, .border, palette.border);
    try theme.setColor(allocator, .muted, palette.muted);
    try theme.applyDerivedStyles(allocator);
    return theme;
}

fn appendColorAnsi(allocator: std.mem.Allocator, builder: *std.ArrayList(u8), value: []const u8, foreground: bool) !void {
    if (parseNamedColor(value)) |named| {
        const prefix = if (foreground) "\x1b[3" else "\x1b[4";
        const color_text = try std.fmt.allocPrint(allocator, "{s}{d}m", .{ prefix, named });
        defer allocator.free(color_text);
        try builder.appendSlice(allocator, color_text);
        return;
    }
    if (value.len == 7 and value[0] == '#') {
        const r = std.fmt.parseInt(u8, value[1..3], 16) catch return;
        const g = std.fmt.parseInt(u8, value[3..5], 16) catch return;
        const b = std.fmt.parseInt(u8, value[5..7], 16) catch return;
        const ansi_text = if (foreground)
            try std.fmt.allocPrint(allocator, "\x1b[38;2;{d};{d};{d}m", .{ r, g, b })
        else
            try std.fmt.allocPrint(allocator, "\x1b[48;2;{d};{d};{d}m", .{ r, g, b });
        defer allocator.free(ansi_text);
        try builder.appendSlice(allocator, ansi_text);
    }
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
