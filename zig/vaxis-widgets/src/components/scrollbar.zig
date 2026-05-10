const std = @import("std");
const vaxis = @import("vaxis");
const draw_mod = @import("../draw.zig");

pub const Orientation = enum {
    vertical_left,
    vertical_right,
    horizontal_top,
    horizontal_bottom,

    pub fn isVertical(self: Orientation) bool {
        return self == .vertical_left or self == .vertical_right;
    }
};

pub const State = struct {
    content_length: usize,
    position: usize = 0,
    viewport_content_length: usize = 0,

    pub fn next(self: *State) void {
        self.position = @min(self.position + 1, self.content_length -| 1);
    }

    pub fn prev(self: *State) void {
        self.position = self.position -| 1;
    }

    pub fn first(self: *State) void {
        self.position = 0;
    }

    pub fn last(self: *State) void {
        self.position = self.content_length -| 1;
    }
};

pub const Scrollbar = struct {
    orientation: Orientation = .vertical_right,
    thumb_symbol: []const u8 = "█",
    track_symbol: ?[]const u8 = "═",
    begin_symbol: ?[]const u8 = "◄",
    end_symbol: ?[]const u8 = "►",
    thumb_style: vaxis.Cell.Style = .{},
    track_style: vaxis.Cell.Style = .{},
    begin_style: vaxis.Cell.Style = .{},
    end_style: vaxis.Cell.Style = .{},

    pub fn drawComponent(self: *const Scrollbar) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Scrollbar,
        window: vaxis.Window,
        _: draw_mod.DrawContext,
        state: *const State,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.height == 0 or window.width == 0) return .{ .width = 0, .height = 0 };
        if (state.content_length == 0) return .{ .width = window.width, .height = window.height };

        const track_len = self.trackLength(window);
        if (track_len == 0) return .{ .width = window.width, .height = window.height };

        const viewport_len = if (state.viewport_content_length != 0)
            state.viewport_content_length
        else if (self.orientation.isVertical())
            window.height
        else
            window.width;

        const parts = computeParts(track_len, state.content_length, state.position, viewport_len);
        const start_len = parts[0];
        const thumb_len = parts[1];
        const end_len = parts[2];

        var idx: u16 = 0;

        // begin symbol
        if (self.begin_symbol) |sym| {
            self.drawAt(window, idx, sym, self.begin_style);
            idx += 1;
        }

        // track start
        for (0..start_len) |_| {
            if (self.track_symbol) |sym| {
                self.drawAt(window, idx, sym, self.track_style);
            }
            idx += 1;
        }

        // thumb
        for (0..thumb_len) |_| {
            self.drawAt(window, idx, self.thumb_symbol, self.thumb_style);
            idx += 1;
        }

        // track end
        for (0..end_len) |_| {
            if (self.track_symbol) |sym| {
                self.drawAt(window, idx, sym, self.track_style);
            }
            idx += 1;
        }

        // end symbol
        if (self.end_symbol) |sym| {
            self.drawAt(window, idx, sym, self.end_style);
            idx += 1;
        }

        return .{
            .width = window.width,
            .height = window.height,
        };
    }

    fn trackLength(self: *const Scrollbar, window: vaxis.Window) u16 {
        const begin_len: u16 = if (self.begin_symbol) |s| @intCast(s.len) else 0;
        const end_len: u16 = if (self.end_symbol) |s| @intCast(s.len) else 0;
        const arrows = begin_len + end_len;
        if (self.orientation.isVertical()) {
            return window.height -| arrows;
        } else {
            return window.width -| arrows;
        }
    }

    fn drawAt(
        self: *const Scrollbar,
        window: vaxis.Window,
        idx: u16,
        symbol: []const u8,
        style: vaxis.Cell.Style,
    ) void {
        switch (self.orientation) {
            .vertical_left => {
                if (idx < window.height) {
                    window.writeCell(0, idx, .{
                        .char = .{ .grapheme = symbol, .width = 1 },
                        .style = style,
                    });
                }
            },
            .vertical_right => {
                if (idx < window.height) {
                    window.writeCell(window.width -| 1, idx, .{
                        .char = .{ .grapheme = symbol, .width = 1 },
                        .style = style,
                    });
                }
            },
            .horizontal_top => {
                if (idx < window.width) {
                    window.writeCell(idx, 0, .{
                        .char = .{ .grapheme = symbol, .width = 1 },
                        .style = style,
                    });
                }
            },
            .horizontal_bottom => {
                if (idx < window.width) {
                    window.writeCell(idx, window.height -| 1, .{
                        .char = .{ .grapheme = symbol, .width = 1 },
                        .style = style,
                    });
                }
            },
        }
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Scrollbar = @ptrCast(@alignCast(ptr));
        return try self.draw(window, ctx, &State{ .content_length = 1 });
    }
};

fn computeParts(track_len: u16, content_len: usize, position: usize, viewport_len: usize) [3]u16 {
    const track = @as(usize, track_len);
    if (track == 0 or content_len == 0) return .{ 0, 0, 0 };

    const max_pos = content_len -| 1;
    const pos = @min(position, max_pos);
    const max_viewport_pos = max_pos + viewport_len;
    if (max_viewport_pos == 0) return .{ 0, @intCast(track), 0 };

    const thumb = @max(1, roundingDivide(viewport_len * track, max_viewport_pos));
    const clamped_thumb = @min(thumb, track);

    const thumb_start = @min(roundingDivide(pos * track, max_viewport_pos), track -| 1);
    const track_end = track -| (thumb_start + clamped_thumb);

    return .{
        @intCast(thumb_start),
        @intCast(clamped_thumb),
        @intCast(track_end),
    };
}

fn roundingDivide(numerator: usize, denominator: usize) usize {
    if (denominator == 0) return 0;
    return (numerator + denominator / 2) / denominator;
}

test "scrollbar renders thumb at correct position" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 10,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const scrollbar = Scrollbar{
        .orientation = .horizontal_bottom,
        .begin_symbol = null,
        .end_symbol = null,
        .track_symbol = "-",
        .thumb_symbol = "#",
    };
    const state = State{ .content_length = 10, .position = 0 };

    const window = draw_mod.rootWindow(&screen);
    window.clear();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try scrollbar.draw(window, .{ .window = window, .arena = arena.allocator() }, &state);

    const first = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("#", first.char.grapheme);
}

test "scrollbar vertical right places symbols at right edge" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 5,
        .cols = 3,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const scrollbar = Scrollbar{
        .orientation = .vertical_right,
        .begin_symbol = null,
        .end_symbol = null,
        .track_symbol = "-",
        .thumb_symbol = "#",
    };
    const state = State{ .content_length = 5, .position = 0 };

    const window = draw_mod.rootWindow(&screen);
    window.clear();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try scrollbar.draw(window, .{ .window = window, .arena = arena.allocator() }, &state);

    const cell = screen.readCell(2, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("#", cell.char.grapheme);
}

test "scrollbar empty content renders nothing" {
    const allocator = std.testing.allocator;
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = 1,
        .cols = 5,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const scrollbar = Scrollbar{
        .orientation = .horizontal_bottom,
        .begin_symbol = null,
        .end_symbol = null,
    };
    const state = State{ .content_length = 0 };

    const window = draw_mod.rootWindow(&screen);
    window.clear();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const size = try scrollbar.draw(window, .{ .window = window, .arena = arena.allocator() }, &state);
    try std.testing.expectEqual(@as(u16, 5), size.width);
}
