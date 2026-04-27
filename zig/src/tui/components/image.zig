const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const draw_mod = @import("../draw.zig");

pub const ImageDisplayMode = enum {
    placeholder,
    ascii,
};

pub const ImageDimensions = struct {
    width_px: usize,
    height_px: usize,
};

pub const KittyImage = struct {
    id: u32,
    width_px: u16,
    height_px: u16,

    pub fn fromVaxisImage(image: vaxis.Image) KittyImage {
        return .{
            .id = image.id,
            .width_px = image.width,
            .height_px = image.height,
        };
    }
};

const RenderSize = struct {
    width: usize,
    height: usize,
};

pub const Image = struct {
    mime_type: []const u8,
    data: []const u8 = "",
    dimensions: ?ImageDimensions = null,
    filename: ?[]const u8 = null,
    max_width_cells: ?usize = null,
    max_height_cells: ?usize = null,
    mode: ImageDisplayMode = .placeholder,
    ascii_art: ?[]const u8 = null,
    kitty_image: ?KittyImage = null,
    padding_x: usize = 0,
    padding_y: usize = 0,

    pub fn component(self: *const Image) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn drawComponent(self: *const Image) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Image,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (self.kitty_image) |kitty| {
            const render_width = @min(resolveRenderWidth(self, @as(usize, window.width)), @as(usize, window.width));
            const max_available_height = @as(usize, window.height) -| self.padding_y * 2;
            const render_height = @min(resolveKittyRenderHeight(self, render_width), @max(max_available_height, 1));

            if (render_width > 0 and render_height > 0 and self.padding_x < window.width and self.padding_y < window.height) {
                const child = window.child(.{
                    .x_off = @intCast(self.padding_x),
                    .y_off = @intCast(self.padding_y),
                    .width = @intCast(@min(render_width, @as(usize, window.width) - self.padding_x)),
                    .height = @intCast(@min(render_height, @as(usize, window.height) - self.padding_y)),
                });
                const image = vaxis.Image{
                    .id = kitty.id,
                    .width = kitty.width_px,
                    .height = kitty.height_px,
                };
                image.draw(child, .{
                    .scale = if (window.screen.width_pix > 0 and window.screen.height_pix > 0) .fit else .fill,
                }) catch {};
            }

            return .{
                .width = @intCast(@min(@as(usize, window.width), render_width + self.padding_x * 2)),
                .height = @intCast(@min(@as(usize, window.height), render_height + self.padding_y * 2)),
            };
        }

        var lines = component_mod.LineList.empty;
        try self.renderInto(ctx.arena, @as(usize, window.width), &lines);
        drawLinesToWindow(window, lines.items);
        return .{
            .width = window.width,
            .height = @intCast(@min(lines.items.len, @as(usize, window.height))),
        };
    }

    pub fn renderInto(
        self: *const Image,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const effective_width = @max(width, 1);
        const content_width = @max(effective_width, self.padding_x * 2 + 1) - self.padding_x * 2;

        const blank_line = try allocator.alloc(u8, effective_width);
        defer allocator.free(blank_line);
        @memset(blank_line, ' ');

        for (0..self.padding_y) |_| {
            try component_mod.appendOwnedLine(lines, allocator, blank_line);
        }

        var rendered = component_mod.LineList.empty;
        defer component_mod.freeLines(allocator, &rendered);

        switch (self.mode) {
            .placeholder => try self.renderPlaceholderInto(allocator, content_width, &rendered),
            .ascii => try self.renderAsciiInto(allocator, content_width, &rendered),
        }

        for (rendered.items) |line| {
            var builder = std.ArrayList(u8).empty;
            errdefer builder.deinit(allocator);

            try builder.appendNTimes(allocator, ' ', self.padding_x);
            try builder.appendSlice(allocator, line);

            const padded = try ansi.padRightVisibleAlloc(allocator, builder.items, effective_width);
            defer allocator.free(padded);
            try component_mod.appendOwnedLine(lines, allocator, padded);
            builder.deinit(allocator);
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
        const self: *const Image = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Image = @ptrCast(@alignCast(ptr));
        return try self.draw(window, ctx);
    }

    fn renderAsciiInto(
        self: *const Image,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const art = self.ascii_art orelse {
            try self.renderPlaceholderInto(allocator, width, lines);
            return;
        };

        const render_width = resolveRenderWidth(self, width);
        const max_height = self.max_height_cells orelse std.math.maxInt(usize);
        var source_lines = std.ArrayList([]const u8).empty;
        defer source_lines.deinit(allocator);

        var split = std.mem.splitScalar(u8, art, '\n');
        while (split.next()) |raw_line| {
            const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;
            try source_lines.append(allocator, line);
        }

        const source_width = measureSourceWidth(source_lines.items);
        if (source_lines.items.len == 0 or source_width == 0) {
            try self.renderPlaceholderInto(allocator, width, lines);
            return;
        }

        const size = resolveAsciiRenderSize(self, render_width, max_height, source_width, source_lines.items.len);
        for (0..size.height) |row| {
            const source_row = @min((row * source_lines.items.len) / size.height, source_lines.items.len - 1);
            const sampled = try sampleAsciiRowAlloc(allocator, source_lines.items[source_row], source_width, size.width);
            defer allocator.free(sampled);
            const padded = try ansi.padRightVisibleAlloc(allocator, sampled, render_width);
            defer allocator.free(padded);
            try component_mod.appendOwnedLine(lines, allocator, padded);
        }
    }

    fn renderPlaceholderInto(
        self: *const Image,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const render_width = resolveRenderWidth(self, width);
        const render_height = resolvePlaceholderHeight(self, render_width);

        if (render_width < 6 or render_height < 3) {
            const fallback = try buildFallbackLabel(allocator, self);
            defer allocator.free(fallback);

            const truncated = try truncatePlainAlloc(allocator, fallback, render_width);
            defer allocator.free(truncated);

            const padded = try ansi.padRightVisibleAlloc(allocator, truncated, render_width);
            defer allocator.free(padded);
            try component_mod.appendOwnedLine(lines, allocator, padded);
            return;
        }

        const top = try buildBorderLine(allocator, render_width, true);
        defer allocator.free(top);
        try component_mod.appendOwnedLine(lines, allocator, top);

        var labels: [4]?[]u8 = .{ null, null, null, null };
        var label_count: usize = 0;
        defer {
            for (labels[0..label_count]) |maybe_label| {
                if (maybe_label) |label| allocator.free(label);
            }
        }

        labels[label_count] = try allocator.dupe(u8, "Image");
        label_count += 1;

        if (self.filename) |filename| {
            if (filename.len > 0 and label_count < labels.len) {
                labels[label_count] = try allocator.dupe(u8, filename);
                label_count += 1;
            }
        }

        if (label_count < labels.len) {
            labels[label_count] = try std.fmt.allocPrint(allocator, "[{s}]", .{self.mime_type});
            label_count += 1;
        }

        if (self.dimensions) |dimensions| {
            if (label_count < labels.len) {
                labels[label_count] = try std.fmt.allocPrint(allocator, "{d}x{d}", .{ dimensions.width_px, dimensions.height_px });
                label_count += 1;
            }
        }

        const interior_height = render_height - 2;
        const visible_label_count = @min(interior_height, label_count);
        const start_row = if (interior_height > visible_label_count) (interior_height - visible_label_count) / 2 else 0;

        for (0..interior_height) |row| {
            const maybe_label = if (row >= start_row and row < start_row + visible_label_count)
                labels[row - start_row]
            else
                null;

            const line = try buildInteriorLine(allocator, render_width, maybe_label);
            defer allocator.free(line);
            try component_mod.appendOwnedLine(lines, allocator, line);
        }

        const bottom = try buildBorderLine(allocator, render_width, false);
        defer allocator.free(bottom);
        try component_mod.appendOwnedLine(lines, allocator, bottom);
    }
};

fn drawLinesToWindow(window: vaxis.Window, lines: []const []const u8) void {
    for (lines, 0..) |line, row| {
        if (row >= window.height) break;

        var index: usize = 0;
        var col: u16 = 0;
        while (index < line.len and col < window.width) {
            const cluster = ansi.nextDisplayCluster(line, index);
            if (cluster.end <= index) break;
            defer index = cluster.end;
            if (cluster.width == 0) continue;
            if (@as(usize, col) + cluster.width > window.width) break;
            window.writeCell(col, @intCast(row), .{
                .char = .{
                    .grapheme = line[index..cluster.end],
                    .width = @intCast(cluster.width),
                },
            });
            col += @intCast(cluster.width);
        }
    }
}

fn resolveRenderWidth(self: *const Image, width: usize) usize {
    const constrained = self.max_width_cells orelse width;
    return @max(@as(usize, 1), @min(width, constrained));
}

fn resolveAsciiRenderSize(
    self: *const Image,
    max_width: usize,
    max_height: usize,
    source_width: usize,
    source_height: usize,
) RenderSize {
    const clamped_max_width = @max(@as(usize, 1), max_width);
    const clamped_max_height = @max(@as(usize, 1), max_height);

    var target_width = clamped_max_width;
    var target_height = estimateRenderHeight(self, target_width, source_width, source_height);
    if (target_height > clamped_max_height) {
        target_height = clamped_max_height;
        target_width = estimateRenderWidth(self, target_height, source_width, source_height);
    }

    return .{
        .width = std.math.clamp(target_width, @as(usize, 1), clamped_max_width),
        .height = std.math.clamp(target_height, @as(usize, 1), clamped_max_height),
    };
}

fn resolvePlaceholderHeight(self: *const Image, render_width: usize) usize {
    const max_height = self.max_height_cells orelse 6;
    if (max_height < 3) return 1;

    var estimated_height: usize = 5;
    if (self.dimensions) |dimensions| {
        if (dimensions.width_px > 0 and dimensions.height_px > 0) {
            const numerator = dimensions.height_px * @max(render_width, 1);
            const denominator = dimensions.width_px * 2;
            estimated_height = std.math.divCeil(usize, numerator, @max(denominator, 1)) catch estimated_height;
            estimated_height = std.math.clamp(estimated_height, @as(usize, 3), @as(usize, 8));
        }
    }

    return @max(@as(usize, 3), @min(max_height, estimated_height));
}

fn resolveKittyRenderHeight(self: *const Image, render_width: usize) usize {
    const max_height = self.max_height_cells orelse 8;
    if (max_height == 0) return 1;

    if (self.kitty_image) |kitty| {
        if (kitty.width_px > 0 and kitty.height_px > 0) {
            const numerator = @as(usize, kitty.height_px) * @max(render_width, 1);
            const denominator = @as(usize, kitty.width_px) * 2;
            const estimated = std.math.divCeil(usize, numerator, @max(denominator, 1)) catch 1;
            return std.math.clamp(estimated, @as(usize, 1), @max(@as(usize, 1), max_height));
        }
    }

    if (self.dimensions) |dimensions| {
        if (dimensions.width_px > 0 and dimensions.height_px > 0) {
            const numerator = dimensions.height_px * @max(render_width, 1);
            const denominator = dimensions.width_px * 2;
            const estimated = std.math.divCeil(usize, numerator, @max(denominator, 1)) catch 1;
            return std.math.clamp(estimated, @as(usize, 1), @max(@as(usize, 1), max_height));
        }
    }

    return @min(max_height, @max(@as(usize, 1), resolvePlaceholderHeight(self, render_width)));
}

fn estimateRenderHeight(self: *const Image, target_width: usize, source_width: usize, source_height: usize) usize {
    if (self.dimensions) |dimensions| {
        if (dimensions.width_px > 0 and dimensions.height_px > 0) {
            const numerator = dimensions.height_px * @max(target_width, 1);
            const denominator = dimensions.width_px * 2;
            return std.math.divCeil(usize, numerator, @max(denominator, 1)) catch 1;
        }
    }

    return std.math.divCeil(usize, @max(source_height, 1) * @max(target_width, 1), @max(source_width, 1)) catch 1;
}

fn estimateRenderWidth(self: *const Image, target_height: usize, source_width: usize, source_height: usize) usize {
    if (self.dimensions) |dimensions| {
        if (dimensions.width_px > 0 and dimensions.height_px > 0) {
            const numerator = dimensions.width_px * 2 * @max(target_height, 1);
            return @max(@as(usize, 1), numerator / dimensions.height_px);
        }
    }

    const numerator = @max(source_width, 1) * @max(target_height, 1);
    return @max(@as(usize, 1), numerator / @max(source_height, 1));
}

fn measureSourceWidth(lines: []const []const u8) usize {
    var max_width: usize = 0;
    for (lines) |line| {
        max_width = @max(max_width, ansi.visibleWidth(line));
    }
    return max_width;
}

fn buildFallbackLabel(allocator: std.mem.Allocator, self: *const Image) std.mem.Allocator.Error![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    try builder.appendSlice(allocator, "[Image");

    if (self.filename) |filename| {
        if (filename.len > 0) {
            try builder.appendSlice(allocator, ": ");
            try builder.appendSlice(allocator, filename);
        }
    }

    try builder.appendSlice(allocator, " [");
    try builder.appendSlice(allocator, self.mime_type);
    try builder.appendSlice(allocator, "]");

    if (self.dimensions) |dimensions| {
        const size_label = try std.fmt.allocPrint(allocator, " {d}x{d}", .{ dimensions.width_px, dimensions.height_px });
        defer allocator.free(size_label);
        try builder.appendSlice(allocator, size_label);
    }

    try builder.append(allocator, ']');
    return builder.toOwnedSlice(allocator);
}

fn buildBorderLine(allocator: std.mem.Allocator, width: usize, top: bool) std.mem.Allocator.Error![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    try builder.appendSlice(allocator, if (top) "╭" else "╰");
    if (width > 2) {
        for (0..width - 2) |_| {
            try builder.appendSlice(allocator, "─");
        }
    }
    if (width > 1) {
        try builder.appendSlice(allocator, if (top) "╮" else "╯");
    }

    return builder.toOwnedSlice(allocator);
}

fn buildInteriorLine(
    allocator: std.mem.Allocator,
    width: usize,
    maybe_label: ?[]const u8,
) std.mem.Allocator.Error![]u8 {
    const interior_width = width - @min(width, 2);
    const label = if (maybe_label) |value|
        try truncatePlainAlloc(allocator, value, interior_width)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(label);

    const label_width = ansi.visibleWidth(label);
    const left_padding = if (interior_width > label_width) (interior_width - label_width) / 2 else 0;
    const right_padding = interior_width - @min(interior_width, left_padding + label_width);

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    try builder.appendSlice(allocator, "│");
    try builder.appendNTimes(allocator, ' ', left_padding);
    try builder.appendSlice(allocator, label);
    try builder.appendNTimes(allocator, ' ', right_padding);
    try builder.appendSlice(allocator, "│");

    return builder.toOwnedSlice(allocator);
}

fn truncatePlainAlloc(allocator: std.mem.Allocator, text: []const u8, max_width: usize) std.mem.Allocator.Error![]u8 {
    if (max_width == 0) return allocator.dupe(u8, "");

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len and width < max_width) {
        const cluster = ansi.nextDisplayCluster(text, index);
        if (cluster.width > max_width - width) break;
        try builder.appendSlice(allocator, text[index..cluster.end]);
        index = cluster.end;
        width += cluster.width;
    }

    return builder.toOwnedSlice(allocator);
}

fn sampleAsciiRowAlloc(
    allocator: std.mem.Allocator,
    line: []const u8,
    source_width: usize,
    target_width: usize,
) std.mem.Allocator.Error![]u8 {
    if (target_width == 0) return allocator.dupe(u8, "");

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    for (0..target_width) |column| {
        const source_column = @min((column * source_width) / target_width, source_width - 1);
        const cluster = try ansi.sliceVisibleAlloc(allocator, line, source_column, 1);
        defer allocator.free(cluster);

        if (cluster.len == 0) {
            try builder.append(allocator, ' ');
        } else {
            try builder.appendSlice(allocator, cluster);
        }
    }

    return builder.toOwnedSlice(allocator);
}

test "image renders placeholder box within width and height constraints" {
    const allocator = std.testing.allocator;

    const image = Image{
        .mime_type = "image/png",
        .dimensions = .{ .width_px = 640, .height_px = 480 },
        .filename = "cat.png",
        .max_width_cells = 18,
        .max_height_cells = 4,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try image.renderInto(allocator, 30, &lines);

    try std.testing.expectEqual(@as(usize, 4), lines.items.len);
    try std.testing.expectEqual(@as(usize, 30), ansi.visibleWidth(lines.items[0]));
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "Image") != null);
}

test "image renders provided ASCII art within constraints" {
    const allocator = std.testing.allocator;

    const image = Image{
        .mime_type = "image/png",
        .mode = .ascii,
        .ascii_art = "ABCDE\nFGHIJ\nKLMNO",
        .max_width_cells = 3,
        .max_height_cells = 2,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try image.renderInto(allocator, 5, &lines);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expectEqualStrings("ABD  ", lines.items[0]);
    try std.testing.expectEqualStrings("FGI  ", lines.items[1]);
}

test "image draw component renders fallback cells when kitty image is absent" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4,
        .cols = 20,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);

    const image = Image{
        .mime_type = "image/png",
        .mode = .ascii,
        .ascii_art = "AB\nCD",
        .max_width_cells = 2,
        .max_height_cells = 2,
    };

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try image.drawComponent().draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });

    const first = screen.readCell(0, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("A", first.char.grapheme);
    try std.testing.expect(first.image == null);
}

test "image draw component places kitty image cells when available" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 6,
        .cols = 20,
        .x_pixel = 160,
        .y_pixel = 96,
    });
    defer screen.deinit(std.testing.allocator);

    const image = Image{
        .mime_type = "image/png",
        .kitty_image = .{
            .id = 42,
            .width_px = 64,
            .height_px = 32,
        },
        .max_width_cells = 8,
        .max_height_cells = 4,
        .padding_x = 1,
        .padding_y = 1,
    };

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const size = try image.drawComponent().draw(window, .{
        .window = window,
        .arena = arena.allocator(),
    });

    try std.testing.expect(size.height >= 2);
    const cell = screen.readCell(1, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cell.image != null);
    try std.testing.expectEqual(@as(u32, 42), cell.image.?.img_id);
}

test "image preserves aspect ratio when scaling ascii art" {
    const allocator = std.testing.allocator;

    const image = Image{
        .mime_type = "image/png",
        .mode = .ascii,
        .ascii_art = "ABCDEFGH\nIJKLMNOP\nQRSTUVWX\nYZabcdef",
        .dimensions = .{ .width_px = 800, .height_px = 200 },
        .max_width_cells = 8,
        .max_height_cells = 2,
    };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try image.renderInto(allocator, 10, &lines);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 10), ansi.visibleWidth(lines.items[0]));
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "ABCDEFGH") != null);
}

test "image integrates with box component rendering" {
    const allocator = std.testing.allocator;

    const image = Image{
        .mime_type = "image/webp",
        .dimensions = .{ .width_px = 320, .height_px = 200 },
        .max_width_cells = 14,
        .max_height_cells = 5,
    };

    const box_mod = @import("box.zig");
    var box = box_mod.Box.init(1, 0);
    defer box.deinit(allocator);
    try box.addChild(allocator, image.component());

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try box.renderInto(allocator, 18, &lines);

    try std.testing.expect(lines.items.len >= 3);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "╭") != null or std.mem.indexOf(u8, lines.items[1], "Image") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "Image") != null);
}
