const std = @import("std");
const dark_theme = @import("themes/dark.zig");
const light_theme = @import("themes/light.zig");
const codex_theme = @import("themes/codex.zig");

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
    prompt_glyph,
    prompt_border,
    task_header,
    task_header_accent,
    task_header_separator,
    role_user,
    role_assistant,
    role_thinking,
    role_tool_call,
    role_tool_result,
    role_thinking_glyph,
    terminal_badge,
};

pub const StyleSpec = struct {
    fg: ?[]u8 = null,
    bg: ?[]u8 = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,

    fn clone(self: StyleSpec, allocator: std.mem.Allocator) !StyleSpec {
        return .{
            .fg = if (self.fg) |value| try allocator.dupe(u8, value) else null,
            .bg = if (self.bg) |value| try allocator.dupe(u8, value) else null,
            .bold = self.bold,
            .dim = self.dim,
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
        return initNamed(allocator, "dark", dark_theme.palette());
    }

    pub fn initLight(allocator: std.mem.Allocator) !Theme {
        return initNamed(allocator, "light", light_theme.palette());
    }

    pub fn initCodex(allocator: std.mem.Allocator) !Theme {
        var theme = try initNamed(allocator, "codex", codex_theme.palette());
        errdefer theme.deinit(allocator);
        try theme.setDerivedStyle(allocator, .prompt_glyph, .{ .fg = theme.colors.get(.primary), .bold = true });
        try theme.setDerivedStyle(allocator, .task_header_accent, .{ .fg = theme.colors.get(.primary), .bold = true });
        try theme.setDerivedStyle(allocator, .terminal_badge, .{ .fg = theme.colors.get(.primary), .bold = true });
        return theme;
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
        _ = self;
        _ = token;
        return allocator.dupe(u8, text);
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
        try self.setDerivedStyle(allocator, .prompt_glyph, .{ .fg = self.colors.get(.primary), .bold = true });
        try self.setDerivedStyle(allocator, .prompt_border, .{ .fg = self.colors.get(.border) });
        try self.setDerivedStyle(allocator, .task_header, .{ .fg = self.colors.get(.muted) });
        try self.setDerivedStyle(allocator, .task_header_accent, .{ .fg = self.colors.get(.primary), .bold = true });
        try self.setDerivedStyle(allocator, .task_header_separator, .{ .fg = self.colors.get(.border) });
        try self.setDerivedStyle(allocator, .role_user, .{ .fg = self.colors.get(.secondary), .bold = true });
        try self.setDerivedStyle(allocator, .role_assistant, .{ .fg = self.colors.get(.primary), .bold = true });
        try self.setDerivedStyle(allocator, .role_thinking, .{ .fg = self.colors.get(.muted), .italic = true });
        try self.setDerivedStyle(allocator, .role_tool_call, .{ .fg = self.colors.get(.secondary), .dim = true });
        try self.setDerivedStyle(allocator, .role_tool_result, .{ .fg = self.colors.get(.warning), .dim = true });
        try self.setDerivedStyle(allocator, .role_thinking_glyph, .{ .fg = self.colors.get(.muted), .italic = true });
        try self.setDerivedStyle(allocator, .terminal_badge, .{ .fg = self.colors.get(.muted) });
    }

    fn setDerivedStyle(self: *Theme, allocator: std.mem.Allocator, token: ThemeToken, style: StyleTemplate) !void {
        const index = @intFromEnum(token);
        self.styles[index].deinit(allocator);
        self.styles[index] = try style.owned(allocator);
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
    dim: bool = false,

    fn owned(self: StyleTemplate, allocator: std.mem.Allocator) !StyleSpec {
        return .{
            .fg = if (self.fg) |value| try allocator.dupe(u8, value) else null,
            .bg = if (self.bg) |value| try allocator.dupe(u8, value) else null,
            .bold = self.bold,
            .italic = self.italic,
            .underline = self.underline,
            .dim = self.dim,
        };
    }
};

pub const PaletteTemplate = struct {
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

test "theme palette modules expose dark light and codex palettes" {
    const dark = dark_theme.palette();
    const light = light_theme.palette();
    const codex = codex_theme.palette();

    try std.testing.expectEqualStrings("#7aa2f7", dark.primary);
    try std.testing.expectEqualStrings("#3451b2", light.primary);
    try std.testing.expectEqualStrings("#d18b50", codex.primary);
    try std.testing.expectEqualStrings("#0f1012", codex.background);
}

test "codex theme and new token fallbacks derive non-default styles" {
    var dark = try Theme.initDefault(std.testing.allocator);
    defer dark.deinit(std.testing.allocator);
    var codex = try Theme.initCodex(std.testing.allocator);
    defer codex.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("codex", codex.name);
    try std.testing.expectEqualStrings("#d18b50", codex.colors.primary.?);
    try std.testing.expectEqualStrings("#0f1012", codex.colors.background.?);
    try std.testing.expectEqualStrings("#d18b50", codex.styles[@intFromEnum(ThemeToken.prompt_glyph)].fg.?);
    try std.testing.expectEqualStrings("#d18b50", codex.styles[@intFromEnum(ThemeToken.task_header_accent)].fg.?);

    const fallback_tokens = [_]ThemeToken{
        .prompt_glyph,
        .prompt_border,
        .task_header,
        .task_header_accent,
        .task_header_separator,
        .role_user,
        .role_assistant,
        .role_thinking,
        .role_tool_call,
        .role_tool_result,
        .role_thinking_glyph,
        .terminal_badge,
    };
    for (fallback_tokens) |token| {
        const spec = dark.styles[@intFromEnum(token)];
        try std.testing.expect(spec.fg != null or spec.bg != null or spec.bold or spec.dim or spec.italic or spec.underline);
    }

    const thinking = dark.styles[@intFromEnum(ThemeToken.role_thinking)];
    try std.testing.expect(thinking.italic);
    try std.testing.expectEqualStrings(dark.colors.muted.?, thinking.fg.?);

    const tool_result = dark.styles[@intFromEnum(ThemeToken.role_tool_result)];
    try std.testing.expect(tool_result.dim);
    try std.testing.expect(tool_result.fg != null);
    try std.testing.expect(!std.mem.eql(u8, dark.colors.foreground.?, tool_result.fg.?));
}
