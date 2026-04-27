const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("ansi.zig");
const component_mod = @import("component.zig");
const draw_mod = @import("draw.zig");
const spacer_mod = @import("components/spacer.zig");
const terminal_mod = @import("terminal.zig");
const theme_mod = @import("theme.zig");

const RESET = "\x1b[0m";

pub const VaxisAdapter = struct {
    allocator: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    tty: *std.Io.Writer,
    frame_arenas: [2]std.heap.ArenaAllocator,
    active_frame: usize = 1,

    pub fn init(allocator: std.mem.Allocator, vx: *vaxis.Vaxis, tty: *std.Io.Writer) VaxisAdapter {
        return .{
            .allocator = allocator,
            .vx = vx,
            .tty = tty,
            .frame_arenas = .{
                std.heap.ArenaAllocator.init(allocator),
                std.heap.ArenaAllocator.init(allocator),
            },
        };
    }

    pub fn deinit(self: *VaxisAdapter) void {
        for (&self.frame_arenas) |*arena| arena.deinit();
        self.* = undefined;
    }

    pub fn render(self: *VaxisAdapter, size: terminal_mod.Size, lines: []const []const u8) !void {
        const window = try self.beginFrame(size);
        try renderLineListToWindow(window, lines, self.frameAllocator());
        try self.renderTrailingSpacer(window, lines.len);
        try self.finishFrame();
    }

    pub fn renderComponent(
        self: *VaxisAdapter,
        size: terminal_mod.Size,
        component: draw_mod.Component,
        theme: ?*const theme_mod.Theme,
    ) !draw_mod.Size {
        const window = try self.beginFrame(size);
        const ctx: draw_mod.DrawContext = .{
            .window = window,
            .arena = self.frameAllocator(),
            .theme = theme,
        };
        const rendered = try component.draw(window, ctx);
        try self.finishFrame();
        return rendered;
    }

    fn ensureSize(self: *VaxisAdapter, size: terminal_mod.Size) !void {
        const width: u16 = @intCast(@max(size.width, 1));
        const height: u16 = @intCast(@max(size.height, 1));
        if (self.vx.screen.width == width and self.vx.screen.height == height) return;

        try self.vx.resize(self.allocator, self.tty, .{
            .rows = height,
            .cols = width,
            .x_pixel = 0,
            .y_pixel = 0,
        });
    }

    fn advanceFrame(self: *VaxisAdapter) void {
        self.active_frame = (self.active_frame + 1) % self.frame_arenas.len;
        _ = self.frame_arenas[self.active_frame].reset(.retain_capacity);
    }

    pub fn frameAllocator(self: *VaxisAdapter) std.mem.Allocator {
        return self.frame_arenas[self.active_frame].allocator();
    }

    pub fn beginFrame(self: *VaxisAdapter, size: terminal_mod.Size) !vaxis.Window {
        try self.ensureSize(size);
        self.advanceFrame();

        self.vx.state.alt_screen = true;

        const window = self.vx.window();
        window.clear();
        window.hideCursor();
        return window;
    }

    pub fn finishFrame(self: *VaxisAdapter) !void {
        try self.vx.render(self.tty);
    }

    fn renderTrailingSpacer(self: *VaxisAdapter, window: vaxis.Window, line_count: usize) !void {
        const rendered_rows: u16 = @intCast(@min(line_count, window.height));
        if (rendered_rows >= window.height) return;

        const spacer = spacer_mod.Spacer{ .lines = window.height - rendered_rows };
        const spacer_window = window.child(.{
            .y_off = @intCast(rendered_rows),
            .height = window.height - rendered_rows,
        });
        const ctx: draw_mod.DrawContext = .{
            .window = spacer_window,
            .arena = self.frameAllocator(),
            .theme = null,
        };
        _ = try spacer.drawComponent().draw(spacer_window, ctx);
    }
};

pub fn renderLineListToWindow(window: vaxis.Window, lines: []const []const u8, allocator: std.mem.Allocator) !void {
    const height = @min(lines.len, window.height);
    for (0..height) |row| {
        try renderAnsiLine(window, @intCast(row), lines[row], allocator);
    }
}

pub fn appendScreenRowsAsAnsiLines(
    allocator: std.mem.Allocator,
    screen: *vaxis.Screen,
    width: usize,
    height: usize,
    lines: *component_mod.LineList,
) std.mem.Allocator.Error!void {
    const row_count = @min(height, @as(usize, screen.height));
    const col_count = @min(width, @as(usize, screen.width));
    for (0..row_count) |row| {
        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);

        var current_style: vaxis.Cell.Style = .{};
        var col: usize = 0;
        while (col < col_count) {
            var cell = screen.readCell(@intCast(col), @intCast(row)) orelse vaxis.Cell{};
            if (cell.char.grapheme.len == 0) {
                cell.char = .{
                    .grapheme = " ",
                    .width = 1,
                };
            }

            try appendStyleTransition(allocator, &builder, &current_style, cell.style);
            try builder.appendSlice(allocator, cell.char.grapheme);

            const step = @max(@as(usize, 1), cell.char.width);
            col += step;
        }

        if (!std.meta.eql(current_style, vaxis.Cell.Style{})) {
            try builder.appendSlice(allocator, RESET);
        }

        try lines.append(allocator, try builder.toOwnedSlice(allocator));
    }
}

fn renderAnsiLine(window: vaxis.Window, row: u16, line: []const u8, allocator: std.mem.Allocator) !void {
    var style: vaxis.Cell.Style = .{};
    var index: usize = 0;
    var col: u16 = 0;

    while (index < line.len and col < window.width) {
        if (ansiSequenceLength(line, index)) |len| {
            updateStyleFromAnsi(line[index .. index + len], &style);
            index += len;
            continue;
        }

        const cluster = ansi.nextDisplayCluster(line, index);
        if (cluster.end <= index) break;

        const grapheme = line[index..cluster.end];
        index = cluster.end;

        if (cluster.width == 0) continue;

        const width: u16 = @intCast(cluster.width);
        if (col + width > window.width) break;
        const owned_grapheme = try allocator.dupe(u8, grapheme);

        window.writeCell(col, row, .{
            .char = .{
                .grapheme = owned_grapheme,
                .width = @intCast(cluster.width),
            },
            .style = style,
        });
        col += width;
    }
}

fn updateStyleFromAnsi(sequence: []const u8, style: *vaxis.Cell.Style) void {
    if (sequence.len < 3) return;
    if (sequence[0] != 0x1b or sequence[1] != '[' or sequence[sequence.len - 1] != 'm') return;

    const params = sequence[2 .. sequence.len - 1];
    if (params.len == 0) {
        style.* = .{};
        return;
    }

    var values: [32]u16 = undefined;
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, params, ';');
    while (iter.next()) |part| {
        if (count >= values.len) break;
        values[count] = std.fmt.parseInt(u16, if (part.len == 0) "0" else part, 10) catch return;
        count += 1;
    }

    if (count == 0) {
        style.* = .{};
        return;
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const code = values[i];
        switch (code) {
            0 => style.* = .{},
            1 => style.bold = true,
            2 => style.dim = true,
            3 => style.italic = true,
            4 => style.ul_style = .single,
            7 => style.reverse = true,
            8 => style.invisible = true,
            9 => style.strikethrough = true,
            21 => style.ul_style = .double,
            22 => {
                style.bold = false;
                style.dim = false;
            },
            23 => style.italic = false,
            24 => style.ul_style = .off,
            27 => style.reverse = false,
            28 => style.invisible = false,
            29 => style.strikethrough = false,
            30...37 => style.fg = .{ .index = @intCast(code - 30) },
            39 => style.fg = .default,
            40...47 => style.bg = .{ .index = @intCast(code - 40) },
            49 => style.bg = .default,
            58 => {
                const consumed = parseExtendedColor(values[i..count], &style.ul);
                if (consumed > 0) i += consumed - 1;
            },
            90...97 => style.fg = .{ .index = @intCast(code - 90 + 8) },
            100...107 => style.bg = .{ .index = @intCast(code - 100 + 8) },
            38 => {
                const consumed = parseExtendedColor(values[i..count], &style.fg);
                if (consumed > 0) i += consumed - 1;
            },
            48 => {
                const consumed = parseExtendedColor(values[i..count], &style.bg);
                if (consumed > 0) i += consumed - 1;
            },
            else => {},
        }
    }
}

fn parseExtendedColor(values: []const u16, target: *vaxis.Cell.Color) usize {
    if (values.len < 3) return 1;

    switch (values[1]) {
        5 => {
            target.* = .{ .index = @intCast(@min(values[2], 255)) };
            return 3;
        },
        2 => {
            if (values.len < 5) return 1;
            target.* = .{ .rgb = .{
                @intCast(@min(values[2], 255)),
                @intCast(@min(values[3], 255)),
                @intCast(@min(values[4], 255)),
            } };
            return 5;
        },
        else => return 1,
    }
}

fn ansiSequenceLength(text: []const u8, start: usize) ?usize {
    if (start + 1 >= text.len or text[start] != 0x1b) return null;

    const kind = text[start + 1];
    switch (kind) {
        '[' => {
            var index = start + 2;
            while (index < text.len) : (index += 1) {
                const byte = text[index];
                if (byte >= 0x40 and byte <= 0x7e) {
                    return index - start + 1;
                }
            }
            return text.len - start;
        },
        ']' => {
            var index = start + 2;
            while (index < text.len) : (index += 1) {
                if (text[index] == 0x07) return index - start + 1;
                if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '\\') {
                    return index - start + 2;
                }
            }
            return text.len - start;
        },
        else => return if (kind >= 0x40 and kind <= 0x5f) 2 else null,
    }
}

fn appendStyleTransition(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    current_style: *vaxis.Cell.Style,
    next_style: vaxis.Cell.Style,
) std.mem.Allocator.Error!void {
    if (std.meta.eql(current_style.*, next_style)) return;

    if (!std.meta.eql(current_style.*, vaxis.Cell.Style{}) or std.meta.eql(next_style, vaxis.Cell.Style{})) {
        try builder.appendSlice(allocator, RESET);
    }
    if (std.meta.eql(next_style, vaxis.Cell.Style{})) {
        current_style.* = .{};
        return;
    }

    try appendStyleCodes(allocator, builder, next_style);
    current_style.* = next_style;
}

fn appendStyleCodes(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    style: vaxis.Cell.Style,
) std.mem.Allocator.Error!void {
    if (style.bold) try builder.appendSlice(allocator, "\x1b[1m");
    if (style.dim) try builder.appendSlice(allocator, "\x1b[2m");
    if (style.italic) try builder.appendSlice(allocator, "\x1b[3m");
    switch (style.ul_style) {
        .off => {},
        .single => try builder.appendSlice(allocator, "\x1b[4m"),
        .double => try builder.appendSlice(allocator, "\x1b[21m"),
        .curly => try builder.appendSlice(allocator, "\x1b[4:3m"),
        .dotted => try builder.appendSlice(allocator, "\x1b[4:4m"),
        .dashed => try builder.appendSlice(allocator, "\x1b[4:5m"),
    }
    if (style.blink) try builder.appendSlice(allocator, "\x1b[5m");
    if (style.reverse) try builder.appendSlice(allocator, "\x1b[7m");
    if (style.invisible) try builder.appendSlice(allocator, "\x1b[8m");
    if (style.strikethrough) try builder.appendSlice(allocator, "\x1b[9m");
    try appendColorCodes(allocator, builder, "48", style.bg);
    try appendColorCodes(allocator, builder, "38", style.fg);
}

fn appendColorCodes(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    prefix: []const u8,
    color: vaxis.Cell.Color,
) std.mem.Allocator.Error!void {
    switch (color) {
        .default => {},
        .index => |index| {
            var buffer: [32]u8 = undefined;
            const rendered = std.fmt.bufPrint(&buffer, "\x1b[{s};5;{}m", .{ prefix, index }) catch unreachable;
            try builder.appendSlice(allocator, rendered);
        },
        .rgb => |rgb| {
            var buffer: [48]u8 = undefined;
            const rendered = std.fmt.bufPrint(&buffer, "\x1b[{s};2;{};{};{}m", .{ prefix, rgb[0], rgb[1], rgb[2] }) catch unreachable;
            try builder.appendSlice(allocator, rendered);
        },
    }
}

test "renderLineListToWindow maps ANSI SGR sequences to libvaxis cell styles" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var vx = try vaxis.init(std.testing.io, allocator, &env_map, .{});
    defer vx.deinit(allocator, &writer.writer);

    try vx.resize(allocator, &writer.writer, .{
        .rows = 2,
        .cols = 12,
        .x_pixel = 0,
        .y_pixel = 0,
    });

    var adapter = VaxisAdapter.init(allocator, &vx, &writer.writer);
    defer adapter.deinit();

    const window = vx.window();
    window.clear();
    try renderLineListToWindow(window, &.{
        "\x1b[1;38;5;196mHi\x1b[0m \x1b[4;48;2;1;2;3mYo\x1b[0m",
    }, adapter.frameAllocator());

    const hi = window.readCell(0, 0).?;
    try std.testing.expectEqualStrings("H", hi.char.grapheme);
    try std.testing.expect(hi.style.bold);
    try std.testing.expectEqual(vaxis.Cell.Color{ .index = 196 }, hi.style.fg);

    const yo = window.readCell(3, 0).?;
    try std.testing.expectEqualStrings("Y", yo.char.grapheme);
    try std.testing.expectEqual(vaxis.Cell.Style.Underline.single, yo.style.ul_style);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 1, 2, 3 } }, yo.style.bg);
}

test "appendScreenRowsAsAnsiLines round trips styled cells through ANSI text" {
    const allocator = std.testing.allocator;

    var source = try vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 4,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer source.deinit(allocator);

    source.writeCell(0, 0, .{
        .char = .{ .grapheme = "H", .width = 1 },
        .style = .{
            .bold = true,
            .fg = .{ .index = 196 },
        },
    });
    source.writeCell(1, 0, .{
        .char = .{ .grapheme = "i", .width = 1 },
        .style = .{
            .italic = true,
            .bg = .{ .rgb = .{ 1, 2, 3 } },
        },
    });

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try appendScreenRowsAsAnsiLines(allocator, &source, 4, 1, &lines);

    var target = try vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 4,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer target.deinit(allocator);

    const target_window: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = target.width,
        .height = target.height,
        .screen = &target,
    };
    target_window.clear();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try renderLineListToWindow(target_window, lines.items, arena.allocator());

    const hi = target.readCell(0, 0).?;
    try std.testing.expectEqualStrings("H", hi.char.grapheme);
    try std.testing.expect(hi.style.bold);
    try std.testing.expectEqual(vaxis.Cell.Color{ .index = 196 }, hi.style.fg);

    const italic = target.readCell(1, 0).?;
    try std.testing.expectEqualStrings("i", italic.char.grapheme);
    try std.testing.expect(italic.style.italic);
    try std.testing.expectEqual(vaxis.Cell.Color{ .rgb = .{ 1, 2, 3 } }, italic.style.bg);
}
