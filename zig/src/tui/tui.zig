const std = @import("std");
const ansi = @import("ansi.zig");
const component_mod = @import("component.zig");
const terminal_mod = @import("terminal.zig");

pub const OverlayAnchor = enum {
    center,
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    top_center,
    bottom_center,
    left_center,
    right_center,
};

pub const OverlayMargin = struct {
    top: usize = 0,
    right: usize = 0,
    bottom: usize = 0,
    left: usize = 0,
};

pub const OverlayAnimationKind = enum {
    none,
    slide_from_top,
    slide_from_bottom,
    slide_from_left,
    slide_from_right,
};

pub const OverlayAnimation = struct {
    kind: OverlayAnimationKind = .none,
    progress: f32 = 1.0,
};

pub const OverlayOptions = struct {
    width: ?usize = null,
    max_height: ?usize = null,
    anchor: OverlayAnchor = .center,
    offset_x: isize = 0,
    offset_y: isize = 0,
    row: ?usize = null,
    col: ?usize = null,
    margin: OverlayMargin = .{},
    animation: OverlayAnimation = .{},
};

pub const RenderMode = enum {
    none,
    full,
    diff,
};

pub const RenderStats = struct {
    mode: RenderMode = .none,
    changed_line_count: usize = 0,
    payload_bytes: usize = 0,
    frame_bytes: usize = 0,
    synchronized_output: bool = false,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    terminal: *terminal_mod.Terminal,
    previous_lines: component_mod.LineList = .empty,
    previous_size: ?terminal_mod.Size = null,
    overlays: std.ArrayList(OverlayEntry) = .empty,
    next_overlay_id: usize = 1,
    synchronized_output_enabled: bool = true,
    last_render_stats: RenderStats = .{},

    pub fn init(allocator: std.mem.Allocator, terminal: *terminal_mod.Terminal) Renderer {
        return .{
            .allocator = allocator,
            .terminal = terminal,
        };
    }

    pub fn getLastRenderStats(self: *const Renderer) RenderStats {
        return self.last_render_stats;
    }

    pub fn deinit(self: *Renderer) void {
        component_mod.freeLines(self.allocator, &self.previous_lines);
        self.overlays.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn showOverlay(self: *Renderer, component: component_mod.Component, options: OverlayOptions) !usize {
        const id = self.next_overlay_id;
        self.next_overlay_id += 1;
        try self.overlays.append(self.allocator, .{
            .id = id,
            .component = component,
            .options = options,
        });
        return id;
    }

    pub fn removeOverlay(self: *Renderer, id: usize) bool {
        for (self.overlays.items, 0..) |entry, index| {
            if (entry.id != id) continue;
            _ = self.overlays.orderedRemove(index);
            return true;
        }
        return false;
    }

    pub fn dismissTopOverlay(self: *Renderer) bool {
        if (self.overlays.items.len == 0) return false;
        _ = self.overlays.pop();
        return true;
    }

    pub fn updateOverlay(self: *Renderer, id: usize, component: component_mod.Component, options: OverlayOptions) bool {
        for (self.overlays.items) |*entry| {
            if (entry.id != id) continue;
            entry.component = component;
            entry.options = options;
            return true;
        }
        return false;
    }

    pub fn hasOverlays(self: *const Renderer) bool {
        return self.overlays.items.len > 0;
    }

    pub fn render(self: *Renderer, root: component_mod.Component) !void {
        const size = try self.terminal.refreshSize();

        var new_lines = component_mod.LineList.empty;
        defer component_mod.freeLines(self.allocator, &new_lines);
        try root.renderInto(self.allocator, size.width, &new_lines);
        try self.compositeOverlays(size, &new_lines);

        if (self.previous_size == null or self.previous_size.?.width != size.width or self.previous_size.?.height != size.height) {
            try self.fullRedraw(new_lines.items);
        } else {
            try self.diffRedraw(new_lines.items);
        }

        try self.replacePreviousLines(new_lines.items);
        self.previous_size = size;
    }

    fn fullRedraw(self: *Renderer, lines: []const []u8) !void {
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.allocator);

        try buffer.appendSlice(self.allocator, "\x1b[2J\x1b[H");
        for (lines, 0..) |line, index| {
            if (index > 0) try buffer.append(self.allocator, '\n');
            try buffer.appendSlice(self.allocator, line);
        }
        try self.writeFrame(.full, lines.len, buffer.items);
    }

    fn diffRedraw(self: *Renderer, lines: []const []u8) !void {
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.allocator);

        const max_lines = @max(lines.len, self.previous_lines.items.len);
        var changed_line_count: usize = 0;
        for (0..max_lines) |row| {
            const old_line = if (row < self.previous_lines.items.len) self.previous_lines.items[row] else "";
            const new_line = if (row < lines.len) lines[row] else "";
            if (std.mem.eql(u8, old_line, new_line)) continue;
            changed_line_count += 1;

            const cursor = try std.fmt.allocPrint(self.allocator, "\x1b[{d};1H\x1b[2K", .{row + 1});
            defer self.allocator.free(cursor);
            try buffer.appendSlice(self.allocator, cursor);
            try buffer.appendSlice(self.allocator, new_line);
        }

        try self.writeFrame(.diff, changed_line_count, buffer.items);
    }

    fn writeFrame(self: *Renderer, mode: RenderMode, changed_line_count: usize, payload: []const u8) !void {
        self.last_render_stats = .{
            .mode = mode,
            .changed_line_count = changed_line_count,
            .payload_bytes = payload.len,
            .frame_bytes = payload.len,
            .synchronized_output = false,
        };

        if (payload.len == 0) return;

        if (!self.synchronized_output_enabled) {
            try self.terminal.write(payload);
            return;
        }

        var frame = std.ArrayList(u8).empty;
        defer frame.deinit(self.allocator);

        try frame.appendSlice(self.allocator, terminal_mod.Terminal.SYNC_OUTPUT_ENABLE);
        try frame.appendSlice(self.allocator, payload);
        try frame.appendSlice(self.allocator, terminal_mod.Terminal.SYNC_OUTPUT_DISABLE);

        self.last_render_stats.frame_bytes = frame.items.len;
        self.last_render_stats.synchronized_output = true;
        try self.terminal.write(frame.items);
    }

    fn replacePreviousLines(self: *Renderer, lines: []const []u8) !void {
        component_mod.freeLines(self.allocator, &self.previous_lines);
        self.previous_lines = .empty;
        for (lines) |line| {
            try self.previous_lines.append(self.allocator, try self.allocator.dupe(u8, line));
        }
    }

    fn compositeOverlays(self: *Renderer, size: terminal_mod.Size, lines: *component_mod.LineList) !void {
        if (self.overlays.items.len == 0) return;

        try ensureLineCapacity(self.allocator, lines, size.height, size.width);

        for (self.overlays.items) |entry| {
            const width = resolveOverlayWidth(entry.options, size.width);

            var overlay_lines = component_mod.LineList.empty;
            defer component_mod.freeLines(self.allocator, &overlay_lines);
            try entry.component.renderInto(self.allocator, width, &overlay_lines);

            const overlay_height = if (entry.options.max_height) |max_height|
                @min(overlay_lines.items.len, max_height)
            else
                overlay_lines.items.len;
            if (overlay_height == 0) continue;

            const layout = resolveOverlayLayout(entry.options, width, overlay_height, size);
            try ensureLineCapacity(self.allocator, lines, @max(size.height, layout.row + overlay_height), size.width);

            for (0..overlay_height) |row_offset| {
                const target_row = layout.row + row_offset;
                const composed = try compositeLineAt(
                    self.allocator,
                    lines.items[target_row],
                    overlay_lines.items[row_offset],
                    layout.col,
                    width,
                    size.width,
                );
                self.allocator.free(lines.items[target_row]);
                lines.items[target_row] = composed;
            }
        }
    }
};

const OverlayEntry = struct {
    id: usize,
    component: component_mod.Component,
    options: OverlayOptions,
};

const OverlayLayout = struct {
    row: usize,
    col: usize,
};

fn ensureLineCapacity(
    allocator: std.mem.Allocator,
    lines: *component_mod.LineList,
    target_len: usize,
    width: usize,
) std.mem.Allocator.Error!void {
    while (lines.items.len < target_len) {
        const blank = try allocator.alloc(u8, width);
        @memset(blank, ' ');
        try lines.append(allocator, blank);
    }
}

fn resolveOverlayWidth(options: OverlayOptions, terminal_width: usize) usize {
    const margin = options.margin;
    const available_width = @max(terminal_width, margin.left + margin.right + 1) - margin.left - margin.right;
    const preferred = options.width orelse available_width;
    return @max(@as(usize, 1), @min(preferred, available_width));
}

fn resolveOverlayLayout(
    options: OverlayOptions,
    overlay_width: usize,
    overlay_height: usize,
    size: terminal_mod.Size,
) OverlayLayout {
    const margin = options.margin;
    const available_width = @max(size.width, margin.left + margin.right + 1) - margin.left - margin.right;
    const available_height = @max(size.height, margin.top + margin.bottom + 1) - margin.top - margin.bottom;

    const width = @min(overlay_width, available_width);
    const height = @min(overlay_height, available_height);

    const max_col = margin.left + available_width - width;
    const max_row = margin.top + available_height - height;

    const anchor_col = switch (options.anchor) {
        .top_left, .left_center, .bottom_left => margin.left,
        .top_right, .right_center, .bottom_right => max_col,
        .center, .top_center, .bottom_center => margin.left + (available_width - width) / 2,
    };
    const anchor_row = switch (options.anchor) {
        .top_left, .top_center, .top_right => margin.top,
        .bottom_left, .bottom_center, .bottom_right => max_row,
        .center, .left_center, .right_center => margin.top + (available_height - height) / 2,
    };

    const base_col = options.col orelse anchor_col;
    const base_row = options.row orelse anchor_row;

    return .{
        .row = animatedRow(
            clampPosition(base_row, options.offset_y, margin.top, max_row),
            margin.top,
            max_row,
            options.animation,
        ),
        .col = animatedCol(
            clampPosition(base_col, options.offset_x, margin.left, max_col),
            margin.left,
            max_col,
            options.animation,
        ),
    };
}

fn clampPosition(base: usize, offset: isize, min_value: usize, max_value: usize) usize {
    const shifted = @as(isize, @intCast(base)) + offset;
    const clamped = std.math.clamp(shifted, @as(isize, @intCast(min_value)), @as(isize, @intCast(max_value)));
    return @intCast(clamped);
}

fn animatedRow(base_row: usize, min_row: usize, max_row: usize, animation: OverlayAnimation) usize {
    const progress = animationProgress(animation.progress);
    return switch (animation.kind) {
        .slide_from_top => interpolatePosition(min_row, base_row, progress),
        .slide_from_bottom => interpolatePosition(max_row, base_row, progress),
        else => base_row,
    };
}

fn animatedCol(base_col: usize, min_col: usize, max_col: usize, animation: OverlayAnimation) usize {
    const progress = animationProgress(animation.progress);
    return switch (animation.kind) {
        .slide_from_left => interpolatePosition(min_col, base_col, progress),
        .slide_from_right => interpolatePosition(max_col, base_col, progress),
        else => base_col,
    };
}

fn interpolatePosition(start: usize, end: usize, progress: f32) usize {
    if (start == end) return end;
    const distance = @as(f32, @floatFromInt(if (end >= start) end - start else start - end));
    const delta = @as(usize, @intFromFloat(@round(distance * progress)));
    return if (end >= start) start + delta else start - @min(start, delta);
}

fn animationProgress(progress: f32) f32 {
    return std.math.clamp(progress, 0.0, 1.0);
}

fn compositeLineAt(
    allocator: std.mem.Allocator,
    base_line: []const u8,
    overlay_line: []const u8,
    start_col: usize,
    overlay_width: usize,
    total_width: usize,
) std.mem.Allocator.Error![]u8 {
    const clamped_start = @min(start_col, total_width);
    const clamped_overlay_width = @min(overlay_width, total_width - clamped_start);

    const before = try ansi.sliceVisibleAlloc(allocator, base_line, 0, clamped_start);
    defer allocator.free(before);

    const overlay = try ansi.sliceVisibleAlloc(allocator, overlay_line, 0, clamped_overlay_width);
    defer allocator.free(overlay);

    const after_start = clamped_start + clamped_overlay_width;
    const after = try ansi.sliceVisibleAlloc(allocator, base_line, after_start, total_width - after_start);
    defer allocator.free(after);

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    try builder.appendSlice(allocator, before);
    const before_width = ansi.visibleWidth(before);
    if (before_width < clamped_start) {
        try builder.appendNTimes(allocator, ' ', clamped_start - before_width);
    }

    try builder.appendSlice(allocator, "\x1b[0m");
    try builder.appendSlice(allocator, overlay);
    const overlay_visible_width = ansi.visibleWidth(overlay);
    if (overlay_visible_width < clamped_overlay_width) {
        try builder.appendNTimes(allocator, ' ', clamped_overlay_width - overlay_visible_width);
    }

    try builder.appendSlice(allocator, "\x1b[0m");
    try builder.appendSlice(allocator, after);

    const composed = try ansi.padRightVisibleAlloc(allocator, builder.items, total_width);
    builder.deinit(allocator);
    return composed;
}

const TestMockBackend = struct {
    size: terminal_mod.Size,
    writes: std.ArrayList([]u8) = .empty,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        for (self.writes.items) |entry| alloc.free(entry);
        self.writes.deinit(alloc);
    }

    fn backend(self: *@This()) terminal_mod.Backend {
        return .{
            .ptr = self,
            .enterRawModeFn = enterRawMode,
            .restoreModeFn = restoreMode,
            .writeFn = write,
            .getSizeFn = getSize,
        };
    }

    fn enterRawMode(_: *anyopaque) !void {}
    fn restoreMode(_: *anyopaque) !void {}

    fn write(ptr: *anyopaque, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.writes.append(std.testing.allocator, try std.testing.allocator.dupe(u8, bytes));
    }

    fn getSize(ptr: *anyopaque) !terminal_mod.Size {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.size;
    }
};

const TestStaticComponent = struct {
    lines: []const []const u8,

    fn component(self: *const @This()) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    fn renderInto(self: *const @This(), alloc: std.mem.Allocator, width: usize, lines: *component_mod.LineList) !void {
        for (self.lines) |line| {
            const padded = try ansi.padRightVisibleAlloc(alloc, line, width);
            defer alloc.free(padded);
            try component_mod.appendOwnedLine(lines, alloc, padded);
        }
    }

    fn renderIntoOpaque(ptr: *const anyopaque, alloc: std.mem.Allocator, width: usize, lines: *component_mod.LineList) !void {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        try self.renderInto(alloc, width, lines);
    }
};

test "differential renderer only redraws changed lines" {
    const allocator = std.testing.allocator;

    var backend = TestMockBackend{ .size = .{ .width = 12, .height = 4 } };
    defer backend.deinit(allocator);

    var terminal = terminal_mod.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    const first = TestStaticComponent{ .lines = &[_][]const u8{ "alpha", "bravo", "charlie" } };
    try renderer.render(first.component());

    try std.testing.expect(std.mem.indexOf(u8, backend.writes.items[1], "\x1b[2J\x1b[H") != null);

    const baseline_write_count = backend.writes.items.len;
    const second = TestStaticComponent{ .lines = &[_][]const u8{ "alpha", "BRAVO", "charlie" } };
    try renderer.render(second.component());

    try std.testing.expectEqual(baseline_write_count + 1, backend.writes.items.len);
    const delta = backend.writes.items[backend.writes.items.len - 1];
    try std.testing.expect(std.mem.startsWith(u8, delta, terminal_mod.Terminal.SYNC_OUTPUT_ENABLE));
    try std.testing.expect(std.mem.endsWith(u8, delta, terminal_mod.Terminal.SYNC_OUTPUT_DISABLE));
    try std.testing.expect(std.mem.indexOf(u8, delta, "\x1b[2;1H\x1b[2K") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "\x1b[1;1H") == null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "\x1b[3;1H") == null);

    const stats = renderer.getLastRenderStats();
    try std.testing.expectEqual(RenderMode.diff, stats.mode);
    try std.testing.expectEqual(@as(usize, 1), stats.changed_line_count);
    try std.testing.expect(stats.synchronized_output);
    try std.testing.expect(stats.frame_bytes < backend.writes.items[1].len);
}

test "renderer performs a full redraw when the terminal size changes" {
    const allocator = std.testing.allocator;

    var backend = TestMockBackend{ .size = .{ .width = 10, .height = 3 } };
    defer backend.deinit(allocator);

    var terminal = terminal_mod.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    const static_component = TestStaticComponent{ .lines = &[_][]const u8{ "one", "two" } };
    try renderer.render(static_component.component());

    const initial_write_count = backend.writes.items.len;
    backend.size = .{ .width = 14, .height = 5 };

    try renderer.render(static_component.component());

    try std.testing.expectEqual(initial_write_count + 1, backend.writes.items.len);
    const redraw = backend.writes.items[backend.writes.items.len - 1];
    try std.testing.expect(std.mem.startsWith(u8, redraw, terminal_mod.Terminal.SYNC_OUTPUT_ENABLE ++ "\x1b[2J\x1b[H"));
    try std.testing.expect(std.mem.endsWith(u8, redraw, terminal_mod.Terminal.SYNC_OUTPUT_DISABLE));
    try std.testing.expect(std.mem.indexOf(u8, redraw, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, redraw, "two") != null);

    const stats = renderer.getLastRenderStats();
    try std.testing.expectEqual(RenderMode.full, stats.mode);
    try std.testing.expectEqual(@as(usize, 2), stats.changed_line_count);
    try std.testing.expect(stats.synchronized_output);
}

test "renderer skips terminal writes when a frame is unchanged" {
    const allocator = std.testing.allocator;

    var backend = TestMockBackend{ .size = .{ .width = 12, .height = 4 } };
    defer backend.deinit(allocator);

    var terminal = terminal_mod.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    const static_component = TestStaticComponent{ .lines = &[_][]const u8{ "same", "frame" } };
    try renderer.render(static_component.component());
    const baseline_write_count = backend.writes.items.len;

    try renderer.render(static_component.component());

    try std.testing.expectEqual(baseline_write_count, backend.writes.items.len);
    const stats = renderer.getLastRenderStats();
    try std.testing.expectEqual(RenderMode.diff, stats.mode);
    try std.testing.expectEqual(@as(usize, 0), stats.changed_line_count);
    try std.testing.expectEqual(@as(usize, 0), stats.payload_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.frame_bytes);
    try std.testing.expect(!stats.synchronized_output);
}

test "renderer composites overlays on top of base content and can dismiss them" {
    const allocator = std.testing.allocator;

    var backend = TestMockBackend{ .size = .{ .width = 12, .height = 4 } };
    defer backend.deinit(allocator);

    var terminal = terminal_mod.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    const base = TestStaticComponent{ .lines = &[_][]const u8{"base layer"} };
    const overlay = TestStaticComponent{ .lines = &[_][]const u8{"menu"} };
    _ = try renderer.showOverlay(overlay.component(), .{ .width = 6, .anchor = .center });

    try renderer.render(base.component());

    try std.testing.expect(renderer.hasOverlays());
    try std.testing.expectEqual(@as(usize, 4), renderer.previous_lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, renderer.previous_lines.items[1], "menu") != null);

    try std.testing.expect(renderer.dismissTopOverlay());
    try renderer.render(base.component());

    try std.testing.expect(!renderer.hasOverlays());
    try std.testing.expectEqual(@as(usize, 1), renderer.previous_lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, renderer.previous_lines.items[0], "menu") == null);
}

test "overlay layout is recalculated on terminal resize" {
    const allocator = std.testing.allocator;

    var backend = TestMockBackend{ .size = .{ .width = 12, .height = 4 } };
    defer backend.deinit(allocator);

    var terminal = terminal_mod.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    const base = TestStaticComponent{ .lines = &[_][]const u8{} };
    const overlay = TestStaticComponent{ .lines = &[_][]const u8{"pick"} };
    _ = try renderer.showOverlay(overlay.component(), .{ .width = 6, .anchor = .center });

    try renderer.render(base.component());
    try std.testing.expect(std.mem.startsWith(u8, renderer.previous_lines.items[1], "   \x1b[0mpick"));

    backend.size = .{ .width = 16, .height = 6 };
    try renderer.render(base.component());

    try std.testing.expectEqual(@as(usize, 6), renderer.previous_lines.items.len);
    try std.testing.expect(std.mem.startsWith(u8, renderer.previous_lines.items[2], "     \x1b[0mpick"));
}

test "overlay update replaces options for subsequent renders" {
    const allocator = std.testing.allocator;

    var backend = TestMockBackend{ .size = .{ .width = 12, .height = 4 } };
    defer backend.deinit(allocator);

    var terminal = terminal_mod.Terminal.init(backend.backend());
    try terminal.start();
    defer terminal.stop();

    var renderer = Renderer.init(allocator, &terminal);
    defer renderer.deinit();

    const base = TestStaticComponent{ .lines = &[_][]const u8{} };
    const overlay = TestStaticComponent{ .lines = &[_][]const u8{"menu"} };
    const overlay_id = try renderer.showOverlay(overlay.component(), .{ .width = 6, .anchor = .top_left });

    try renderer.render(base.component());
    try std.testing.expect(std.mem.startsWith(u8, renderer.previous_lines.items[0], "\x1b[0mmenu"));

    try std.testing.expect(renderer.updateOverlay(overlay_id, overlay.component(), .{
        .width = 6,
        .anchor = .bottom_right,
    }));
    try renderer.render(base.component());
    try std.testing.expect(std.mem.indexOf(u8, renderer.previous_lines.items[3], "menu") != null);
}

test "overlay animation slides from top before reaching its anchor" {
    const size = terminal_mod.Size{ .width = 20, .height = 10 };
    const start = resolveOverlayLayout(.{
        .width = 8,
        .anchor = .center,
        .animation = .{ .kind = .slide_from_top, .progress = 0.0 },
    }, 8, 3, size);
    const mid = resolveOverlayLayout(.{
        .width = 8,
        .anchor = .center,
        .animation = .{ .kind = .slide_from_top, .progress = 0.5 },
    }, 8, 3, size);
    const end = resolveOverlayLayout(.{
        .width = 8,
        .anchor = .center,
        .animation = .{ .kind = .slide_from_top, .progress = 1.0 },
    }, 8, 3, size);

    try std.testing.expectEqual(@as(usize, 0), start.row);
    try std.testing.expect(mid.row > start.row);
    try std.testing.expectEqual(end.row, resolveOverlayLayout(.{ .width = 8, .anchor = .center }, 8, 3, size).row);
}
