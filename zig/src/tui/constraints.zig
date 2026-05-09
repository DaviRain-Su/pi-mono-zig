const std = @import("std");

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn right(self: Rect) u16 {
        return self.x + self.width;
    }

    pub fn bottom(self: Rect) u16 {
        return self.y + self.height;
    }
};

pub const Constraint = union(enum) {
    length: usize,
    percentage: u16,
    min: usize,
    max: usize,
    ratio: struct { numerator: u32, denominator: u32 },
    fill: usize,
    /// Flex constraint with basis, grow and shrink weights (like CSS flexbox).
    /// Basis is the starting size, grow controls expansion when space remains,
    /// shrink controls contraction when space is tight.
    flex: struct { basis: usize, grow: usize = 0, shrink: usize = 1 },
};

/// Split a horizontal area into columns based on constraints.
/// Returns a slice of Rects (one per constraint), allocated from `arena`.
/// Spacing between columns is subtracted from the total available width.
pub fn splitHorizontal(
    arena: std.mem.Allocator,
    area: Rect,
    constraints: []const Constraint,
    spacing: u16,
) std.mem.Allocator.Error![]Rect {
    if (constraints.len == 0) return &[_]Rect{};

    const total_spacing = spacing * @as(u16, @intCast(constraints.len -| 1));
    const available: u16 = if (area.width > total_spacing) area.width - total_spacing else 0;

    const widths = try arena.alloc(usize, constraints.len);
    defer arena.free(widths);

    solveSizes(constraints, available, widths);

    const rects = try arena.alloc(Rect, constraints.len);
    var x: u16 = area.x;
    for (widths, 0..) |w, i| {
        const width: u16 = @intCast(@min(w, @as(usize, std.math.maxInt(u16))));
        rects[i] = .{
            .x = x,
            .y = area.y,
            .width = width,
            .height = area.height,
        };
        x += width;
        if (i + 1 < constraints.len) x += spacing;
    }

    return rects;
}

/// Split a vertical area into rows based on constraints.
/// Returns a slice of Rects (one per constraint), allocated from `arena`.
/// Spacing between rows is subtracted from the total available height.
pub fn splitVertical(
    arena: std.mem.Allocator,
    area: Rect,
    constraints: []const Constraint,
    spacing: u16,
) std.mem.Allocator.Error![]Rect {
    if (constraints.len == 0) return &[_]Rect{};

    const total_spacing = spacing * @as(u16, @intCast(constraints.len -| 1));
    const available: u16 = if (area.height > total_spacing) area.height - total_spacing else 0;

    const heights = try arena.alloc(usize, constraints.len);
    defer arena.free(heights);

    solveSizes(constraints, available, heights);

    const rects = try arena.alloc(Rect, constraints.len);
    var y: u16 = area.y;
    for (heights, 0..) |h, i| {
        const height: u16 = @intCast(@min(h, @as(usize, std.math.maxInt(u16))));
        rects[i] = .{
            .x = area.x,
            .y = y,
            .width = area.width,
            .height = height,
        };
        y += height;
        if (i + 1 < constraints.len) y += spacing;
    }

    return rects;
}

fn solveSizes(constraints: []const Constraint, available: u16, out: []usize) void {
    std.debug.assert(constraints.len == out.len);
    if (constraints.len == 0) return;

    @memset(out, 0);

    var remaining: usize = available;
    var fill_indices: [64]usize = undefined;
    var fill_count: usize = 0;
    var fill_weight_total: usize = 0;
    var flex_indices: [64]usize = undefined;
    var flex_count: usize = 0;
    var flex_grow_total: usize = 0;
    var flex_shrink_total: usize = 0;

    // Pass 1: resolve exact constraints and collect flex/fill items
    for (constraints, 0..) |c, i| {
        switch (c) {
            .length => |v| out[i] = v,
            .percentage => |v| out[i] = @max(1, (@as(usize, available) * v) / 100),
            .ratio => |r| {
                if (r.denominator > 0) {
                    out[i] = (@as(usize, available) * r.numerator) / r.denominator;
                }
            },
            .min => |v| out[i] = v,
            .max => |v| out[i] = v,
            .fill => |w| {
                fill_indices[fill_count] = i;
                fill_count += 1;
                fill_weight_total += w;
            },
            .flex => |f| {
                out[i] = f.basis;
                flex_indices[flex_count] = i;
                flex_count += 1;
                flex_grow_total += f.grow;
                flex_shrink_total += f.shrink;
            },
        }
    }

    // Subtract exact sizes from remaining
    for (out) |w| remaining -|= w;

    // Pass 2: distribute remaining space to fill constraints
    if (fill_count > 0 and remaining > 0) {
        if (fill_weight_total == 0) {
            const base = remaining / fill_count;
            var rem = remaining % fill_count;
            for (0..fill_count) |j| {
                const idx = fill_indices[j];
                out[idx] = base + if (rem > 0) blk: {
                    rem -= 1;
                    break :blk @as(usize, 1);
                } else @as(usize, 0);
            }
        } else {
            var used: usize = 0;
            for (0..fill_count) |j| {
                const idx = fill_indices[j];
                const weight = switch (constraints[idx]) {
                    .fill => |w| w,
                    else => unreachable,
                };
                const allocated = (remaining * weight) / fill_weight_total;
                out[idx] = allocated;
                used += allocated;
            }
            var remainder = remaining - used;
            var j: usize = 0;
            while (remainder > 0 and j < fill_count) : (j += 1) {
                out[fill_indices[j]] += 1;
                remainder -= 1;
            }
        }
    }

    // Recalculate remaining after fill
    var sum: usize = 0;
    for (out) |w| sum += w;
    remaining = if (sum < available) available - sum else 0;

    // Pass 3: distribute remaining to flex grow
    if (flex_count > 0 and remaining > 0 and flex_grow_total > 0) {
        var used: usize = 0;
        for (0..flex_count) |j| {
            const idx = flex_indices[j];
            const weight = switch (constraints[idx]) {
                .flex => |f| f.grow,
                else => unreachable,
            };
            const allocated = (remaining * weight) / flex_grow_total;
            out[idx] += allocated;
            used += allocated;
        }
        var remainder = remaining - used;
        var j: usize = 0;
        while (remainder > 0 and j < flex_count) : (j += 1) {
            const idx = flex_indices[j];
            const f = switch (constraints[idx]) { .flex => |ff| ff, else => unreachable };
            if (f.grow > 0) {
                out[idx] += 1;
                remainder -= 1;
            }
        }
    }

    // Pass 4: apply flex shrink if overallocated
    sum = 0;
    for (out) |w| sum += w;
    if (sum > available and flex_shrink_total > 0) {
        const excess = sum - available;
        var used: usize = 0;
        for (0..flex_count) |j| {
            const idx = flex_indices[j];
            const weight = switch (constraints[idx]) {
                .flex => |f| f.shrink,
                else => unreachable,
            };
            const delta = (excess * weight) / flex_shrink_total;
            out[idx] -|= delta;
            used += delta;
        }
        var remainder = excess - used;
        var j: usize = 0;
        while (remainder > 0 and j < flex_count) : (j += 1) {
            const idx = flex_indices[j];
            const f = switch (constraints[idx]) { .flex => |ff| ff, else => unreachable };
            if (f.shrink > 0 and out[idx] > 0) {
                out[idx] -= 1;
                remainder -= 1;
            }
        }
    }

    // Final clamp
    sum = 0;
    for (out) |w| sum += w;
    if (sum > available) {
        var excess = sum - available;
        var i = out.len;
        while (excess > 0 and i > 0) {
            i -= 1;
            const shrink = @min(excess, out[i]);
            out[i] -= shrink;
            excess -= shrink;
        }
    }
}

test "split length constraints" {
    const arena = std.testing.allocator;
    const area = Rect{ .x = 0, .y = 0, .width = 30, .height = 1 };
    const constraints = &[_]Constraint{
        .{ .length = 5 },
        .{ .length = 10 },
        .{ .length = 8 },
    };

    const rects = try splitHorizontal(arena, area, constraints, 1);
    defer arena.free(rects);

    try std.testing.expectEqual(@as(usize, 3), rects.len);
    try std.testing.expectEqual(@as(u16, 5), rects[0].width);
    try std.testing.expectEqual(@as(u16, 10), rects[1].width);
    try std.testing.expectEqual(@as(u16, 8), rects[2].width);
}

test "split percentage constraints" {
    const arena = std.testing.allocator;
    const area = Rect{ .x = 0, .y = 0, .width = 100, .height = 1 };
    const constraints = &[_]Constraint{
        .{ .percentage = 30 },
        .{ .percentage = 70 },
    };

    const rects = try splitHorizontal(arena, area, constraints, 0);
    defer arena.free(rects);

    try std.testing.expectEqual(@as(u16, 30), rects[0].width);
    try std.testing.expectEqual(@as(u16, 70), rects[1].width);
}

test "split fill constraints distributes remaining space" {
    const arena = std.testing.allocator;
    const area = Rect{ .x = 0, .y = 0, .width = 20, .height = 1 };
    const constraints = &[_]Constraint{
        .{ .length = 5 },
        .{ .fill = 1 },
        .{ .fill = 2 },
    };

    const rects = try splitHorizontal(arena, area, constraints, 0);
    defer arena.free(rects);

    try std.testing.expectEqual(@as(u16, 5), rects[0].width);
    try std.testing.expectEqual(@as(u16, 5), rects[1].width);
    try std.testing.expectEqual(@as(u16, 10), rects[2].width);
}

test "split mixed constraints with spacing" {
    const arena = std.testing.allocator;
    const area = Rect{ .x = 0, .y = 0, .width = 32, .height = 1 };
    const constraints = &[_]Constraint{
        .{ .length = 10 },
        .{ .fill = 1 },
    };

    const rects = try splitHorizontal(arena, area, constraints, 2);
    defer arena.free(rects);

    try std.testing.expectEqual(@as(u16, 10), rects[0].width);
    try std.testing.expectEqual(@as(u16, 20), rects[1].width);
    try std.testing.expectEqual(@as(u16, 12), rects[1].x); // 10 + 2 spacing
}

test "split handles overflow by clamping" {
    const arena = std.testing.allocator;
    const area = Rect{ .x = 0, .y = 0, .width = 10, .height = 1 };
    const constraints = &[_]Constraint{
        .{ .length = 5 },
        .{ .length = 5 },
        .{ .length = 5 },
    };

    const rects = try splitHorizontal(arena, area, constraints, 0);
    defer arena.free(rects);

    var sum: u16 = 0;
    for (rects) |r| sum += r.width;
    try std.testing.expect(sum <= area.width);
}

test "split single constraint takes full width" {
    const arena = std.testing.allocator;
    const area = Rect{ .x = 0, .y = 0, .width = 50, .height = 1 };
    const constraints = &[_]Constraint{.{ .fill = 1 }};

    const rects = try splitHorizontal(arena, area, constraints, 0);
    defer arena.free(rects);

    try std.testing.expectEqual(@as(usize, 1), rects.len);
    try std.testing.expectEqual(@as(u16, 50), rects[0].width);
}

test "split vertical distributes height" {
    const arena = std.testing.allocator;
    const area = Rect{ .x = 0, .y = 0, .width = 10, .height = 20 };
    const constraints = &[_]Constraint{
        .{ .length = 4 },
        .{ .fill = 1 },
        .{ .fill = 3 },
    };

    const rects = try splitVertical(arena, area, constraints, 1);
    defer arena.free(rects);

    try std.testing.expectEqual(@as(usize, 3), rects.len);
    try std.testing.expectEqual(@as(u16, 4), rects[0].height);
    try std.testing.expectEqual(@as(u16, 0), rects[0].y);
    try std.testing.expectEqual(@as(u16, 4), rects[1].height);
    try std.testing.expectEqual(@as(u16, 5), rects[1].y);
    try std.testing.expectEqual(@as(u16, 10), rects[2].height);
    try std.testing.expectEqual(@as(u16, 10), rects[2].y);
}

test "split empty constraints returns empty" {
    const arena = std.testing.allocator;
    const area = Rect{ .x = 0, .y = 0, .width = 10, .height = 1 };
    const constraints = &[_]Constraint{};

    const rects = try splitHorizontal(arena, area, constraints, 0);
    try std.testing.expectEqual(@as(usize, 0), rects.len);
}

test "split flex grow distributes extra space" {
    const arena = std.testing.allocator;
    const area = Rect{ .x = 0, .y = 0, .width = 20, .height = 1 };
    const constraints = &[_]Constraint{
        .{ .flex = .{ .basis = 4, .grow = 1 } },
        .{ .flex = .{ .basis = 4, .grow = 2 } },
    };

    const rects = try splitHorizontal(arena, area, constraints, 0);
    defer arena.free(rects);

    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqual(@as(u16, 8), rects[0].width); // 4 + 4*1/3
    try std.testing.expectEqual(@as(u16, 12), rects[1].width); // 4 + 4*2/3
}

test "split flex shrink reduces oversized children" {
    const arena = std.testing.allocator;
    const area = Rect{ .x = 0, .y = 0, .width = 11, .height = 1 };
    const constraints = &[_]Constraint{
        .{ .flex = .{ .basis = 8, .shrink = 1 } },
        .{ .flex = .{ .basis = 8, .shrink = 1 } },
    };

    const rects = try splitHorizontal(arena, area, constraints, 1);
    defer arena.free(rects);

    // available = 11 - 1 gap = 10; basis total = 16; excess = 6
    // each shrinks by (6 * 1) / 2 = 3, so both become 5
    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqual(@as(u16, 5), rects[0].width);
    try std.testing.expectEqual(@as(u16, 5), rects[1].width);
}

test "split flex with gap respects spacing" {
    const arena = std.testing.allocator;
    const area = Rect{ .x = 0, .y = 0, .width = 16, .height = 1 };
    const constraints = &[_]Constraint{
        .{ .flex = .{ .basis = 4, .grow = 1 } },
        .{ .flex = .{ .basis = 4, .grow = 1 } },
    };

    const rects = try splitHorizontal(arena, area, constraints, 2);
    defer arena.free(rects);

    try std.testing.expectEqual(@as(usize, 2), rects.len);
    try std.testing.expectEqual(@as(u16, 7), rects[0].width); // (16-2)/2 = 7
    try std.testing.expectEqual(@as(u16, 7), rects[1].width);
    try std.testing.expectEqual(@as(u16, 9), rects[1].x); // 7 + 2
}
