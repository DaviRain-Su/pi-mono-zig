const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const layout = @import("../layout.zig");
const test_helpers = @import("../test_helpers.zig");
const theme_mod = @import("../theme.zig");
const constraints = @import("../constraints.zig");

pub const FlexChild = struct {
    component: draw_mod.Component,
    basis: ?usize = null,
    grow: usize = 0,
    shrink: usize = 1,
    align_self: ?layout.AlignItems = null,
};

pub const Flex = struct {
    direction: layout.Axis = .column,
    justify_content: layout.JustifyContent = .start,
    align_items: layout.AlignItems = .stretch,
    gap: usize = 0,
    padding: layout.Insets = .{},
    height: ?usize = null,
    children: std.ArrayList(FlexChild) = .empty,

    pub fn init(direction: layout.Axis) Flex {
        return .{ .direction = direction };
    }

    pub fn deinit(self: *Flex, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
        self.* = undefined;
    }

    pub fn addChild(self: *Flex, allocator: std.mem.Allocator, child: FlexChild) std.mem.Allocator.Error!void {
        try self.children.append(allocator, child);
    }

    pub fn drawComponent(self: *const Flex) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Flex,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        const effective_height = if (self.height) |height|
            @min(height, @as(usize, window.height))
        else
            @as(usize, window.height);
        const inner_window = insetWindow(window, self.padding, effective_height) orelse {
            return .{
                .width = window.width,
                .height = @intCast(@min(effective_height, @as(usize, window.height))),
            };
        };

        return switch (self.direction) {
            .column => self.drawColumn(window, inner_window, ctx, effective_height),
            .row => self.drawRow(window, inner_window, ctx, effective_height),
        };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Flex = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }

    fn drawColumn(
        self: *const Flex,
        window: vaxis.Window,
        inner_window: vaxis.Window,
        ctx: draw_mod.DrawContext,
        effective_height: usize,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (self.children.items.len == 0) {
            return .{
                .width = window.width,
                .height = @intCast(@min(effective_height, @as(usize, window.height))),
            };
        }

        const rendered = try renderDrawChildren(
            ctx.arena,
            self.children.items,
            @max(@as(usize, inner_window.width), 1),
            @max(@as(usize, inner_window.height), 1),
            ctx.theme,
        );
        defer freeRenderedDrawChildren(ctx.arena, rendered);
        const natural_sizes = try ctx.arena.alloc(usize, rendered.len);
        for (rendered, 0..) |entry, index| natural_sizes[index] = entry.used_height;

        const gap_total = self.gap * (rendered.len -| 1);
        const target_inner_height = if (self.height) |height|
            if (height > self.padding.vertical()) height - self.padding.vertical() else 0
        else
            null;

        const assigned_sizes = if (target_inner_height) |_|
            blk: {
                const child_constraints = try ctx.arena.alloc(constraints.Constraint, self.children.items.len);
                for (self.children.items, natural_sizes, 0..) |child, natural, i| {
                    child_constraints[i] = if (child.basis) |b|
                        .{ .length = b }
                    else
                        .{ .length = natural };
                }
                const rects = try constraints.splitVertical(
                    ctx.arena,
                    .{ .x = 0, .y = 0, .width = inner_window.width, .height = inner_window.height },
                    child_constraints,
                    @intCast(self.gap),
                );
                const sizes = try ctx.arena.alloc(usize, rects.len);
                for (rects, 0..) |r, i| sizes[i] = r.height;
                break :blk sizes;
            }
        else
            blk: {
                const sizes = try ctx.arena.alloc(usize, natural_sizes.len);
                for (self.children.items, natural_sizes, 0..) |child, natural, i| {
                    sizes[i] = child.basis orelse natural;
                }
                break :blk sizes;
            };

        const actual_inner_height = if (target_inner_height) |height|
            @min(height, @as(usize, inner_window.height))
        else
            @min(sumSizes(assigned_sizes) + gap_total, @as(usize, inner_window.height));
        const extra = actual_inner_height -| @min(sumSizes(assigned_sizes) + gap_total, actual_inner_height);
        const justify = try resolveJustify(ctx.arena, self.justify_content, extra, rendered.len);

        var cursor_y: usize = justify.leading;
        for (rendered, 0..) |entry, index| {
            if (cursor_y >= inner_window.height) break;

            const alignment = self.children.items[index].align_self orelse self.align_items;
            const render_width = switch (alignment) {
                .stretch => @as(usize, inner_window.width),
                else => @min(@as(usize, inner_window.width), entry.used_width),
            };
            const x_off = switch (alignment) {
                .start, .stretch => 0,
                .center => (@as(usize, inner_window.width) -| render_width) / 2,
                .end => @as(usize, inner_window.width) -| render_width,
            };
            const child_height = @min(assigned_sizes[index], @as(usize, inner_window.height) - cursor_y);
            const child_window = inner_window.child(.{
                .x_off = @intCast(x_off),
                .y_off = @intCast(cursor_y),
                .width = @intCast(@max(render_width, 1)),
                .height = @intCast(@max(child_height, 1)),
            });
            blitAllocatingScreen(entry.screen, child_window, 0, @max(render_width, 1), child_height);
            cursor_y += child_height;
            if (index + 1 < rendered.len) {
                cursor_y += self.gap + justify.between[index];
            }
        }

        const total_height = if (self.height) |height|
            @min(height, @as(usize, window.height))
        else
            @min(self.padding.top + actual_inner_height + self.padding.bottom, @as(usize, window.height));
        return .{
            .width = window.width,
            .height = @intCast(total_height),
        };
    }

    fn drawRow(
        self: *const Flex,
        window: vaxis.Window,
        inner_window: vaxis.Window,
        ctx: draw_mod.DrawContext,
        effective_height: usize,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (self.children.items.len == 0) {
            return .{
                .width = window.width,
                .height = @intCast(@min(effective_height, @as(usize, window.height))),
            };
        }

        const gap_total = self.gap * (self.children.items.len -| 1);
        const available_for_items = if (@as(usize, inner_window.width) > gap_total)
            @as(usize, inner_window.width) - gap_total
        else
            0;

        const assigned_widths = try allocateRowWidths(ctx.arena, self.children.items, available_for_items);

        const rendered = try renderDrawChildrenWithWidths(
            ctx.arena,
            self.children.items,
            assigned_widths,
            @max(@as(usize, inner_window.height), 1),
            ctx.theme,
        );
        defer freeRenderedDrawChildren(ctx.arena, rendered);

        var row_height: usize = 0;
        for (rendered) |entry| row_height = @max(row_height, entry.used_height);

        const target_inner_height = if (self.height) |height|
            if (height > self.padding.vertical()) height - self.padding.vertical() else 0
        else
            row_height;
        row_height = @min(@max(row_height, target_inner_height), @as(usize, inner_window.height));

        const used_width = sumSizes(assigned_widths);
        const extra = available_for_items -| used_width;
        const justify = try resolveJustify(ctx.arena, self.justify_content, extra, self.children.items.len);

        var cursor_x: usize = justify.leading;
        for (rendered, assigned_widths, 0..) |entry, width, index| {
            if (cursor_x >= inner_window.width) break;

            const alignment = self.children.items[index].align_self orelse self.align_items;
            const child_height = @min(row_height, entry.used_height);
            const y_off = switch (alignment) {
                .start, .stretch => 0,
                .center => (row_height -| child_height) / 2,
                .end => row_height -| child_height,
            };
            const child_window = inner_window.child(.{
                .x_off = @intCast(cursor_x),
                .y_off = @intCast(y_off),
                .width = @intCast(width),
                .height = @intCast(@max(child_height, 1)),
            });
            blitAllocatingScreen(entry.screen, child_window, 0, width, child_height);
            cursor_x += width;
            if (index + 1 < rendered.len) {
                cursor_x += self.gap + justify.between[index];
            }
        }

        const total_height = if (self.height) |height|
            @min(height, @as(usize, window.height))
        else
            @min(self.padding.top + row_height + self.padding.bottom, @as(usize, window.height));
        return .{
            .width = window.width,
            .height = @intCast(total_height),
        };
    }


};

const RenderedDrawChild = struct {
    screen: *vaxis.AllocatingScreen,
    used_width: usize,
    used_height: usize,
};

const JustifyDistribution = struct {
    leading: usize,
    trailing: usize,
    between: []usize,
};

fn freeRenderedDrawChildren(allocator: std.mem.Allocator, rendered: []RenderedDrawChild) void {
    for (rendered) |entry| {
        entry.screen.deinit(allocator);
        allocator.destroy(entry.screen);
    }
    allocator.free(rendered);
}

fn renderDrawChildren(
    allocator: std.mem.Allocator,
    children: []const FlexChild,
    width: usize,
    max_height: usize,
    theme: ?*const theme_mod.Theme,
) std.mem.Allocator.Error![]RenderedDrawChild {
    const rendered = try allocator.alloc(RenderedDrawChild, children.len);
    errdefer allocator.free(rendered);

    for (children, 0..) |child, index| {
        rendered[index] = try renderDrawComponentToScreen(
            allocator,
            child.component,
            width,
            max_height,
            theme,
        );
        errdefer {
            for (rendered[0 .. index + 1]) |entry| entry.screen.deinit(allocator);
        }
    }

    return rendered;
}

fn renderDrawChildrenWithWidths(
    allocator: std.mem.Allocator,
    children: []const FlexChild,
    widths: []const usize,
    max_height: usize,
    theme: ?*const theme_mod.Theme,
) std.mem.Allocator.Error![]RenderedDrawChild {
    const rendered = try allocator.alloc(RenderedDrawChild, children.len);
    errdefer allocator.free(rendered);

    for (children, 0..) |child, index| {
        rendered[index] = try renderDrawComponentToScreen(
            allocator,
            child.component,
            widths[index],
            max_height,
            theme,
        );
        errdefer {
            for (rendered[0 .. index + 1]) |entry| entry.screen.deinit(allocator);
        }
    }

    return rendered;
}

fn renderDrawComponentToScreen(
    allocator: std.mem.Allocator,
    component: draw_mod.Component,
    width: usize,
    max_height: usize,
    theme: ?*const theme_mod.Theme,
) std.mem.Allocator.Error!RenderedDrawChild {
    var screen = try vaxis.Screen.init(allocator, .{
        .rows = @intCast(@max(max_height, 1)),
        .cols = @intCast(@max(width, 1)),
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(allocator);

    const window = draw_mod.rootWindow(&screen);
    window.clear();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const size = try component.draw(window, .{
        .window = window,
        .arena = arena.allocator(),
        .theme = theme,
    });
    const rendered = try cloneScreen(allocator, &screen, width, max_height);
    const used_width = usedColumnCount(rendered);
    return .{
        .screen = rendered,
        .used_width = if (used_width == 0) @min(@as(usize, size.width), width) else used_width,
        .used_height = @min(@as(usize, size.height), max_height),
    };
}

fn cloneScreen(
    allocator: std.mem.Allocator,
    screen: *vaxis.Screen,
    width: usize,
    height: usize,
) std.mem.Allocator.Error!*vaxis.AllocatingScreen {
    const rendered = try allocator.create(vaxis.AllocatingScreen);
    errdefer allocator.destroy(rendered);

    rendered.* = try vaxis.AllocatingScreen.init(
        allocator,
        @intCast(@max(width, 1)),
        @intCast(@max(height, 1)),
    );
    errdefer rendered.deinit(allocator);

    for (0..@max(height, 1)) |row| {
        for (0..@max(width, 1)) |col| {
            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse continue;
            if (cell.default and cell.char.grapheme.len == 0) continue;
            rendered.writeCell(@intCast(col), @intCast(row), normalizeCell(cell));
        }
    }

    return rendered;
}

fn normalizeCell(cell: vaxis.Cell) vaxis.Cell {
    if (cell.char.grapheme.len != 0) return cell;

    var normalized = cell;
    normalized.char = .{
        .grapheme = " ",
        .width = 1,
    };
    return normalized;
}

fn insetWindow(window: vaxis.Window, padding: layout.Insets, total_height: usize) ?vaxis.Window {
    const visible_height = @min(total_height, @as(usize, window.height));
    if (visible_height == 0) return null;

    const left: u16 = @intCast(@min(padding.left, @as(usize, window.width)));
    const right: u16 = @intCast(@min(padding.right, @as(usize, window.width) - @min(@as(usize, window.width), padding.left)));
    const top: u16 = @intCast(@min(padding.top, visible_height));
    const bottom: u16 = @intCast(@min(padding.bottom, visible_height - @min(visible_height, padding.top)));
    if (@as(usize, window.width) <= left + right or visible_height <= top + bottom) return null;

    return window.child(.{
        .x_off = @intCast(left),
        .y_off = @intCast(top),
        .width = window.width - left - right,
        .height = @intCast(visible_height - top - bottom),
    });
}

fn blitAllocatingScreen(
    source: *vaxis.AllocatingScreen,
    destination: vaxis.Window,
    source_row: usize,
    width: usize,
    height: usize,
) void {
    const row_count = @min(@min(height, destination.height), source.height -| source_row);
    const col_count = @min(@min(width, destination.width), source.width);
    for (0..row_count) |row| {
        for (0..col_count) |col| {
            const cell = source.readCell(@intCast(col), @intCast(source_row + row)) orelse continue;
            if (cell.default and cell.char.grapheme.len == 0) continue;
            destination.writeCell(@intCast(col), @intCast(row), cell);
        }
    }
}

fn usedColumnCount(screen: *vaxis.AllocatingScreen) usize {
    var width: usize = 0;
    for (0..screen.height) |row| {
        var last_non_blank: usize = 0;
        var saw_content = false;
        for (0..screen.width) |col| {
            const cell = screen.readCell(@intCast(col), @intCast(row)) orelse continue;
            if (isBlankCell(cell)) continue;
            last_non_blank = col + 1;
            saw_content = true;
        }
        if (saw_content) width = @max(width, last_non_blank);
    }
    return width;
}

fn isBlankCell(cell: vaxis.Cell) bool {
    if (!std.meta.eql(cell.style, vaxis.Cell.Style{})) return false;
    if (cell.default) return true;
    if (cell.char.grapheme.len == 0) return true;
    return std.mem.eql(u8, cell.char.grapheme, " ");
}

fn allocateMainSizes(
    allocator: std.mem.Allocator,
    natural_sizes: []const usize,
    children: []const FlexChild,
    available_for_items: ?usize,
    direction: layout.Axis,
    inner_width: usize,
    gap: usize,
) std.mem.Allocator.Error![]usize {
    const assigned = try allocator.alloc(usize, children.len);
    errdefer allocator.free(assigned);

    if (available_for_items == null) {
        for (natural_sizes, 0..) |natural, index| {
            assigned[index] = children[index].basis orelse natural;
        }
        return assigned;
    }

    const available = available_for_items.?;
    var basis_total: usize = 0;
    var has_explicit_basis = false;
    for (children, 0..) |child, index| {
        assigned[index] = child.basis orelse natural_sizes[index];
        if (child.basis != null) has_explicit_basis = true;
        basis_total += assigned[index];
    }

    if (direction == .row and !has_explicit_basis) {
        const equal_total = if (children.len == 0) 0 else available;
        const base = if (children.len == 0) 0 else equal_total / children.len;
        var remainder = if (children.len == 0) 0 else equal_total % children.len;
        for (assigned) |*value| {
            value.* = base + if (remainder > 0) blk: {
                remainder -= 1;
                break :blk @as(usize, 1);
            } else 0;
        }
        return assigned;
    }

    if (basis_total < available) {
        const extra = available - basis_total;
        var grow_total: usize = 0;
        for (children) |child| grow_total += child.grow;
        if (grow_total > 0) {
            distributeRemainder(assigned, children, extra, grow_total, true);
        }
    } else if (basis_total > available) {
        const overflow = basis_total - available;
        var shrink_total: usize = 0;
        for (children) |child| shrink_total += child.shrink;
        if (shrink_total > 0) {
            distributeRemainder(assigned, children, overflow, shrink_total, false);
        }
    }

    _ = inner_width;
    _ = gap;
    return assigned;
}

fn allocateRowWidths(
    allocator: std.mem.Allocator,
    children: []const FlexChild,
    available: usize,
) std.mem.Allocator.Error![]usize {
    const natural_sizes = try allocator.alloc(usize, children.len);
    defer allocator.free(natural_sizes);
    @memset(natural_sizes, 0);
    return allocateMainSizes(allocator, natural_sizes, children, available, .row, available, 0);
}

fn distributeRemainder(
    sizes: []usize,
    children: []const FlexChild,
    amount: usize,
    weight_total: usize,
    grow: bool,
) void {
    if (amount == 0 or weight_total == 0) return;

    var used: usize = 0;
    for (children, 0..) |child, index| {
        const weight = if (grow) child.grow else child.shrink;
        if (weight == 0) continue;
        const delta = (amount * weight) / weight_total;
        used += delta;
        if (grow) {
            sizes[index] += delta;
        } else {
            sizes[index] -|= delta;
        }
    }

    var remaining = amount -| used;
    var index: usize = 0;
    while (remaining > 0 and index < children.len) : (index += 1) {
        const weight = if (grow) children[index].grow else children[index].shrink;
        if (weight == 0) continue;
        if (grow) {
            sizes[index] += 1;
        } else {
            sizes[index] -|= 1;
        }
        remaining -= 1;
        if (index + 1 == children.len and remaining > 0) index = 0;
    }
}

fn resolveJustify(
    allocator: std.mem.Allocator,
    justify: layout.JustifyContent,
    extra: usize,
    item_count: usize,
) std.mem.Allocator.Error!JustifyDistribution {
    const between_len = item_count -| 1;
    const between = try allocator.alloc(usize, between_len);
    @memset(between, 0);

    var result = JustifyDistribution{
        .leading = 0,
        .trailing = 0,
        .between = between,
    };
    if (item_count == 0 or extra == 0) return result;

    switch (justify) {
        .start => result.trailing = extra,
        .center => {
            result.leading = extra / 2;
            result.trailing = extra - result.leading;
        },
        .end => result.leading = extra,
        .space_between => {
            if (between_len == 0) {
                result.trailing = extra;
            } else {
                distributeAcrossSlots(result.between, extra);
            }
        },
        .space_around => {
            const slot_count = item_count * 2;
            const slot = extra / slot_count;
            var remainder = extra % slot_count;
            result.leading = slot;
            result.trailing = slot;
            for (result.between) |*value| value.* = slot * 2;
            while (remainder > 0) : (remainder -= 1) {
                const position = remainder - 1;
                if (position % 2 == 0) {
                    if (position == 0) {
                        result.leading += 1;
                    } else {
                        result.between[(position - 1) / 2] += 1;
                    }
                } else if (position == slot_count - 1) {
                    result.trailing += 1;
                } else {
                    result.between[(position - 1) / 2] += 1;
                }
            }
        },
        .space_evenly => {
            const slot_count = item_count + 1;
            const slot = extra / slot_count;
            var remainder = extra % slot_count;
            result.leading = slot;
            result.trailing = slot;
            for (result.between) |*value| value.* = slot;
            if (remainder > 0) {
                result.leading += 1;
                remainder -= 1;
            }
            var slot_index: usize = 0;
            while (remainder > 0 and slot_index < result.between.len) : (slot_index += 1) {
                result.between[slot_index] += 1;
                remainder -= 1;
            }
            result.trailing += remainder;
        },
    }

    return result;
}

fn distributeAcrossSlots(slots: []usize, value: usize) void {
    if (slots.len == 0 or value == 0) return;
    const base = value / slots.len;
    var remainder = value % slots.len;
    for (slots) |*slot| {
        slot.* = base + if (remainder > 0) blk: {
            remainder -= 1;
            break :blk @as(usize, 1);
        } else 0;
    }
}

fn sumSizes(values: []const usize) usize {
    var total: usize = 0;
    for (values) |value| total += value;
    return total;
}

const StaticComponent = struct {
    lines: []const []const u8,

    fn drawComponent(self: *const StaticComponent) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = draw,
        };
    }

    fn draw(ptr: *const anyopaque, window: vaxis.Window, _: draw_mod.DrawContext) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const StaticComponent = @ptrCast(@alignCast(ptr));
        window.clear();
        for (self.lines, 0..) |line, row_index| {
            if (row_index >= @as(usize, window.height)) break;
            const row_window = window.child(.{ .y_off = @intCast(row_index), .height = 1 });
            _ = row_window.printSegment(.{ .text = line }, .{ .wrap = .none });
        }
        return .{
            .width = window.width,
            .height = @intCast(@min(self.lines.len, @as(usize, window.height))),
        };
    }
};

test "flex row distributes width using grow factors" {
    const left = StaticComponent{ .lines = &[_][]const u8{"L"} };
    const right = StaticComponent{ .lines = &[_][]const u8{"R"} };

    var flex = Flex.init(.row);
    defer flex.deinit(std.testing.allocator);
    flex.gap = 1;
    try flex.addChild(std.testing.allocator, .{ .component = left.drawComponent(), .basis = 4, .grow = 1 });
    try flex.addChild(std.testing.allocator, .{ .component = right.drawComponent(), .basis = 4, .grow = 2 });

    var screen = try test_helpers.renderToScreen(flex.drawComponent(), 16, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "L", .{});
    try test_helpers.expectCell(&screen, 8, 0, "R", .{});
}

test "flex row shrinks oversized children" {
    const left = StaticComponent{ .lines = &[_][]const u8{"left"} };
    const right = StaticComponent{ .lines = &[_][]const u8{"right"} };

    var flex = Flex.init(.row);
    defer flex.deinit(std.testing.allocator);
    flex.gap = 1;
    try flex.addChild(std.testing.allocator, .{ .component = left.drawComponent(), .basis = 8, .shrink = 1 });
    try flex.addChild(std.testing.allocator, .{ .component = right.drawComponent(), .basis = 8, .shrink = 1 });

    var screen = try test_helpers.renderToScreen(flex.drawComponent(), 10, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "l", .{});
    try test_helpers.expectCell(&screen, 5, 0, "r", .{});
}

test "flex column applies padding gap and centering" {
    const one = StaticComponent{ .lines = &[_][]const u8{"one"} };
    const two = StaticComponent{ .lines = &[_][]const u8{"two"} };

    var flex = Flex.init(.column);
    defer flex.deinit(std.testing.allocator);
    flex.padding = layout.Insets.symmetric(1, 2);
    flex.gap = 1;
    flex.height = 8;
    flex.justify_content = .center;
    flex.align_items = .center;
    try flex.addChild(std.testing.allocator, .{ .component = one.drawComponent() });
    try flex.addChild(std.testing.allocator, .{ .component = two.drawComponent() });

    var screen = try test_helpers.renderToScreen(flex.drawComponent(), 12, 8);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 4, 2, "o", .{});
    try test_helpers.expectCell(&screen, 4, 4, "t", .{});
}

test "flex draw row uses child windows for gap placement" {
    const left = StaticComponent{ .lines = &[_][]const u8{"L"} };
    const right = StaticComponent{ .lines = &[_][]const u8{"R"} };

    var flex = Flex.init(.row);
    defer flex.deinit(std.testing.allocator);
    flex.gap = 1;
    try flex.addChild(std.testing.allocator, .{
        .component = left.drawComponent(),
        .basis = 2,
    });
    try flex.addChild(std.testing.allocator, .{
        .component = right.drawComponent(),
        .basis = 3,
    });

    var screen = try test_helpers.renderToScreen(flex.drawComponent(), 8, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "L", .{});
    try test_helpers.expectCell(&screen, 3, 0, "R", .{});
}

test "flex draw column applies padding and vertical gap" {
    const top = StaticComponent{ .lines = &[_][]const u8{"top"} };
    const bottom = StaticComponent{ .lines = &[_][]const u8{"bot"} };

    var flex = Flex.init(.column);
    defer flex.deinit(std.testing.allocator);
    flex.padding = layout.Insets.symmetric(1, 2);
    flex.gap = 1;
    try flex.addChild(std.testing.allocator, .{ .component = top.drawComponent() });
    try flex.addChild(std.testing.allocator, .{ .component = bottom.drawComponent() });

    var screen = try test_helpers.renderToScreen(flex.drawComponent(), 8, 5);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 2, 1, "t", .{});
    try test_helpers.expectCell(&screen, 2, 3, "b", .{});
    try test_helpers.expectCell(&screen, 2, 2, " ", .{});
}
