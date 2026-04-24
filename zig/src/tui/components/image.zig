const std = @import("std");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");

pub const RenderMode = enum {
    placeholder,
    ascii,
};

pub const ImageDimensions = struct {
    width_px: usize,
    height_px: usize,
};

pub const Image = struct {
    mime_type: []const u8,
    data: []const u8 = "",
    dimensions: ?ImageDimensions = null,
    filename: ?[]const u8 = null,
    max_width_cells: ?usize = null,
    max_height_cells: ?usize = null,
    mode: RenderMode = .placeholder,
    ascii_art: ?[]const u8 = null,
    padding_x: usize = 0,
    padding_y: usize = 0,

    pub fn component(self: *const Image) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
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

        var row_count: usize = 0;
        var split = std.mem.splitScalar(u8, art, '\n');
        while (split.next()) |raw_line| {
            if (row_count >= max_height) break;

            const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;
            const truncated = try truncatePlainAlloc(allocator, line, render_width);
            defer allocator.free(truncated);

            const padded = try ansi.padRightVisibleAlloc(allocator, truncated, render_width);
            defer allocator.free(padded);
            try component_mod.appendOwnedLine(lines, allocator, padded);
            row_count += 1;
        }

        if (row_count == 0) {
            try self.renderPlaceholderInto(allocator, width, lines);
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

        const top = try buildBorderLine(allocator, render_width);
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

        const bottom = try buildBorderLine(allocator, render_width);
        defer allocator.free(bottom);
        try component_mod.appendOwnedLine(lines, allocator, bottom);
    }
};

fn resolveRenderWidth(self: *const Image, width: usize) usize {
    const constrained = self.max_width_cells orelse width;
    return @max(@as(usize, 1), @min(width, constrained));
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

fn buildBorderLine(allocator: std.mem.Allocator, width: usize) std.mem.Allocator.Error![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    try builder.append(allocator, '+');
    if (width > 2) {
        try builder.appendNTimes(allocator, '-', width - 2);
    }
    if (width > 1) {
        try builder.append(allocator, '+');
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

    try builder.append(allocator, '|');
    try builder.appendNTimes(allocator, ' ', left_padding);
    try builder.appendSlice(allocator, label);
    try builder.appendNTimes(allocator, ' ', right_padding);
    try builder.append(allocator, '|');

    return builder.toOwnedSlice(allocator);
}

fn truncatePlainAlloc(allocator: std.mem.Allocator, text: []const u8, max_width: usize) std.mem.Allocator.Error![]u8 {
    if (max_width == 0) return allocator.dupe(u8, "");

    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len and width < max_width) {
        const rune_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const actual_len = @min(rune_len, text.len - index);
        try builder.appendSlice(allocator, text[index .. index + actual_len]);
        index += actual_len;
        width += 1;
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
    try std.testing.expect(std.mem.startsWith(u8, lines.items[0], "+----------------+"));
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
    try std.testing.expectEqualStrings("ABC  ", lines.items[0]);
    try std.testing.expectEqualStrings("FGH  ", lines.items[1]);
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
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "+") != null or std.mem.indexOf(u8, lines.items[1], "Image") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "Image") != null);
}
