const std = @import("std");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const layout = @import("../layout.zig");

pub const FlexChild = struct {
    component: component_mod.Component,
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

    pub fn component(self: *const Flex) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn renderInto(
        self: *const Flex,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const effective_width = @max(width, 1);
        const inner_width = if (effective_width > self.padding.horizontal())
            effective_width - self.padding.horizontal()
        else
            1;

        switch (self.direction) {
            .column => try self.renderColumn(allocator, effective_width, inner_width, lines),
            .row => try self.renderRow(allocator, effective_width, inner_width, lines),
        }
    }

    fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const Flex = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }

    fn renderColumn(
        self: *const Flex,
        allocator: std.mem.Allocator,
        effective_width: usize,
        inner_width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        if (self.children.items.len == 0) {
            const target_height = self.height orelse 0;
            const padding_height = self.padding.vertical();
            try layout.appendBlankLines(
                allocator,
                lines,
                @max(target_height, padding_height),
                effective_width,
            );
            return;
        }

        const rendered = try renderChildren(allocator, self.children.items, inner_width);
        defer freeRenderedChildren(allocator, rendered);

        const natural_sizes = try allocator.alloc(usize, rendered.len);
        defer allocator.free(natural_sizes);
        for (rendered, 0..) |entry, index| natural_sizes[index] = entry.lines.items.len;

        const target_inner_height = if (self.height) |height|
            if (height > self.padding.vertical()) height - self.padding.vertical() else 0
        else
            null;

        const gap_total = self.gap * (rendered.len -| 1);
        const available_for_items = if (target_inner_height) |inner_height|
            if (inner_height > gap_total) inner_height - gap_total else 0
        else
            null;

        const assigned_sizes = try allocateMainSizes(
            allocator,
            natural_sizes,
            self.children.items,
            available_for_items,
            self.direction,
            inner_width,
            self.gap,
        );
        defer allocator.free(assigned_sizes);

        try layout.appendBlankLines(allocator, lines, self.padding.top, effective_width);

        if (available_for_items) |available| {
            const used = sumSizes(assigned_sizes);
            const extra = available -| used;
            const justify = try resolveJustify(allocator, self.justify_content, extra, rendered.len);
            defer allocator.free(justify.between);

            try layout.appendBlankLines(allocator, lines, justify.leading, effective_width);
            for (rendered, 0..) |entry, index| {
                try appendColumnChild(
                    allocator,
                    lines,
                    entry.lines.items,
                    assigned_sizes[index],
                    self.children.items[index].align_self orelse self.align_items,
                    effective_width,
                    inner_width,
                    self.padding,
                );

                if (index + 1 < rendered.len) {
                    try layout.appendBlankLines(allocator, lines, self.gap + justify.between[index], effective_width);
                }
            }
            try layout.appendBlankLines(allocator, lines, justify.trailing, effective_width);
        } else {
            for (rendered, 0..) |entry, index| {
                try appendColumnChild(
                    allocator,
                    lines,
                    entry.lines.items,
                    assigned_sizes[index],
                    self.children.items[index].align_self orelse self.align_items,
                    effective_width,
                    inner_width,
                    self.padding,
                );

                if (index + 1 < rendered.len) {
                    try layout.appendBlankLines(allocator, lines, self.gap, effective_width);
                }
            }
        }

        try layout.appendBlankLines(allocator, lines, self.padding.bottom, effective_width);
    }

    fn renderRow(
        self: *const Flex,
        allocator: std.mem.Allocator,
        effective_width: usize,
        inner_width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        if (self.children.items.len == 0) {
            const target_height = self.height orelse 0;
            const padding_height = self.padding.vertical();
            try layout.appendBlankLines(
                allocator,
                lines,
                @max(target_height, padding_height),
                effective_width,
            );
            return;
        }

        const gap_total = self.gap * (self.children.items.len -| 1);
        const available_for_items = if (inner_width > gap_total) inner_width - gap_total else 0;

        const assigned_widths = try allocateRowWidths(allocator, self.children.items, available_for_items);
        defer allocator.free(assigned_widths);

        const rendered = try renderChildrenWithWidths(allocator, self.children.items, assigned_widths);
        defer freeRenderedChildren(allocator, rendered);

        var row_height: usize = 0;
        for (rendered) |entry| row_height = @max(row_height, entry.lines.items.len);

        const target_inner_height = if (self.height) |height|
            if (height > self.padding.vertical()) height - self.padding.vertical() else 0
        else
            row_height;
        row_height = @min(@max(row_height, target_inner_height), target_inner_height);

        const used_width = sumSizes(assigned_widths);
        const extra = available_for_items -| used_width;
        const justify = try resolveJustify(allocator, self.justify_content, extra, self.children.items.len);
        defer allocator.free(justify.between);

        try layout.appendBlankLines(allocator, lines, self.padding.top, effective_width);

        for (0..row_height) |row_index| {
            var builder = std.ArrayList(u8).empty;
            errdefer builder.deinit(allocator);

            try builder.appendNTimes(allocator, ' ', self.padding.left + justify.leading);

            for (rendered, 0..) |entry, index| {
                const alignment = self.children.items[index].align_self orelse self.align_items;
                const line_text = lineForRowChild(entry.lines.items, row_index, row_height, alignment);
                const aligned = try layout.alignLineAlloc(allocator, line_text, assigned_widths[index], .stretch);
                defer allocator.free(aligned);
                try builder.appendSlice(allocator, aligned);

                if (index + 1 < rendered.len) {
                    try builder.appendNTimes(allocator, ' ', self.gap + justify.between[index]);
                }
            }

            try builder.appendNTimes(allocator, ' ', self.padding.right + justify.trailing);
            const fitted = try ansi.padRightVisibleAlloc(allocator, builder.items, effective_width);
            defer allocator.free(fitted);
            try component_mod.appendOwnedLine(lines, allocator, fitted);
            builder.deinit(allocator);
        }

        try layout.appendBlankLines(allocator, lines, self.padding.bottom, effective_width);
    }
};

const RenderedChild = struct {
    lines: component_mod.LineList,
};

const JustifyDistribution = struct {
    leading: usize,
    trailing: usize,
    between: []usize,
};

fn renderChildren(
    allocator: std.mem.Allocator,
    children: []const FlexChild,
    width: usize,
) std.mem.Allocator.Error![]RenderedChild {
    const rendered = try allocator.alloc(RenderedChild, children.len);
    errdefer allocator.free(rendered);

    for (children, 0..) |child, index| {
        rendered[index] = .{ .lines = .empty };
        errdefer {
            for (rendered[0 .. index + 1]) |*entry| component_mod.freeLines(allocator, &entry.lines);
        }
        try child.component.renderInto(allocator, width, &rendered[index].lines);
    }

    return rendered;
}

fn renderChildrenWithWidths(
    allocator: std.mem.Allocator,
    children: []const FlexChild,
    widths: []const usize,
) std.mem.Allocator.Error![]RenderedChild {
    const rendered = try allocator.alloc(RenderedChild, children.len);
    errdefer allocator.free(rendered);

    for (children, 0..) |child, index| {
        rendered[index] = .{ .lines = .empty };
        errdefer {
            for (rendered[0 .. index + 1]) |*entry| component_mod.freeLines(allocator, &entry.lines);
        }
        try child.component.renderInto(allocator, widths[index], &rendered[index].lines);
    }

    return rendered;
}

fn freeRenderedChildren(allocator: std.mem.Allocator, rendered: []RenderedChild) void {
    for (rendered) |*entry| component_mod.freeLines(allocator, &entry.lines);
    allocator.free(rendered);
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

fn appendColumnChild(
    allocator: std.mem.Allocator,
    lines: *component_mod.LineList,
    child_lines: []const []u8,
    target_height: usize,
    alignment: layout.AlignItems,
    effective_width: usize,
    inner_width: usize,
    padding: layout.Insets,
) std.mem.Allocator.Error!void {
    const visible_count = @min(target_height, child_lines.len);
    for (child_lines[0..visible_count]) |child_line| {
        const fitted = try layout.wrapInsetLineAlloc(allocator, child_line, inner_width, effective_width, padding, alignment);
        defer allocator.free(fitted);
        try component_mod.appendOwnedLine(lines, allocator, fitted);
    }

    const remaining = target_height - visible_count;
    try layout.appendBlankLines(allocator, lines, remaining, effective_width);
}

fn lineForRowChild(
    child_lines: []const []u8,
    row_index: usize,
    row_height: usize,
    alignment: layout.AlignItems,
) []const u8 {
    if (child_lines.len >= row_height) {
        const start_index = switch (alignment) {
            .start, .stretch => 0,
            .center => (child_lines.len - row_height) / 2,
            .end => child_lines.len - row_height,
        };
        const index = start_index + row_index;
        return if (index < child_lines.len) child_lines[index] else "";
    }

    const remaining = row_height - child_lines.len;
    const top_padding = switch (alignment) {
        .start, .stretch => 0,
        .center => remaining / 2,
        .end => remaining,
    };
    if (row_index < top_padding or row_index >= top_padding + child_lines.len) return "";
    return child_lines[row_index - top_padding];
}

fn sumSizes(values: []const usize) usize {
    var total: usize = 0;
    for (values) |value| total += value;
    return total;
}

const StaticComponent = struct {
    lines: []const []const u8,

    fn component(self: *const StaticComponent) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const StaticComponent = @ptrCast(@alignCast(ptr));
        for (self.lines) |line| {
            const fitted = try ansi.padRightVisibleAlloc(allocator, line, width);
            defer allocator.free(fitted);
            try component_mod.appendOwnedLine(lines, allocator, fitted);
        }
    }
};

test "flex row distributes width using grow factors" {
    const allocator = std.testing.allocator;

    const left = StaticComponent{ .lines = &[_][]const u8{"L"} };
    const right = StaticComponent{ .lines = &[_][]const u8{"R"} };

    var flex = Flex.init(.row);
    defer flex.deinit(allocator);
    flex.gap = 1;
    try flex.addChild(allocator, .{ .component = left.component(), .basis = 4, .grow = 1 });
    try flex.addChild(allocator, .{ .component = right.component(), .basis = 4, .grow = 2 });

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try flex.renderInto(allocator, 16, &lines);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 16), ansi.visibleWidth(lines.items[0]));
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "L") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "R") != null);
}

test "flex row shrinks oversized children" {
    const allocator = std.testing.allocator;

    const left = StaticComponent{ .lines = &[_][]const u8{"left"} };
    const right = StaticComponent{ .lines = &[_][]const u8{"right"} };

    var flex = Flex.init(.row);
    defer flex.deinit(allocator);
    flex.gap = 1;
    try flex.addChild(allocator, .{ .component = left.component(), .basis = 8, .shrink = 1 });
    try flex.addChild(allocator, .{ .component = right.component(), .basis = 8, .shrink = 1 });

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try flex.renderInto(allocator, 10, &lines);

    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqual(@as(usize, 10), ansi.visibleWidth(lines.items[0]));
}

test "flex column applies padding gap and centering" {
    const allocator = std.testing.allocator;

    const one = StaticComponent{ .lines = &[_][]const u8{"one"} };
    const two = StaticComponent{ .lines = &[_][]const u8{"two"} };

    var flex = Flex.init(.column);
    defer flex.deinit(allocator);
    flex.padding = layout.Insets.symmetric(1, 2);
    flex.gap = 1;
    flex.height = 8;
    flex.justify_content = .center;
    flex.align_items = .center;
    try flex.addChild(allocator, .{ .component = one.component() });
    try flex.addChild(allocator, .{ .component = two.component() });

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);
    try flex.renderInto(allocator, 12, &lines);

    try std.testing.expectEqual(@as(usize, 8), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[2], "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[4], "two") != null);
}
