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

    solveWidths(constraints, available, widths);

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

fn solveWidths(constraints: []const Constraint, available: u16, out: []usize) void {
    std.debug.assert(constraints.len == out.len);
    if (constraints.len == 0) return;

    @memset(out, 0);

    var remaining: usize = available;
    var total_fill_weight: usize = 0;
    var fill_indices: [64]usize = undefined;
    var fill_count: usize = 0;

    // Pass 1: resolve exact constraints
    for (constraints, 0..) |c, i| {
        switch (c) {
            .length => |v| out[i] = v,
            .percentage => |v| out[i] = @max(1, (@as(usize, available) * v) / 100),
            .ratio => |r| {
                if (r.denominator > 0) {
                    out[i] = (@as(usize, available) * r.numerator) / r.denominator;
                }
            },
            .min, .max, .fill => {},
        }
    }

    // Apply min constraints and collect fill items
    for (constraints, 0..) |c, i| {
        switch (c) {
            .min => |v| {
                out[i] = v;
            },
            .fill => |weight| {
                fill_indices[fill_count] = i;
                fill_count += 1;
                total_fill_weight += weight;
            },
            else => {},
        }
    }

    // Apply max constraints and subtract exact widths from remaining
    for (constraints, 0..) |c, i| {
        switch (c) {
            .max => |v| {
                out[i] = v;
                if (remaining >= out[i]) {
                    remaining -= out[i];
                } else {
                    remaining = 0;
                }
            },
            .length, .percentage, .ratio => {
                if (remaining >= out[i]) {
                    remaining -= out[i];
                } else {
                    remaining = 0;
                }
            },
            .min => {
                if (remaining >= out[i]) {
                    remaining -= out[i];
                } else {
                    remaining = 0;
                }
            },
            .fill => {},
        }
    }

    // Pass 2: distribute remaining space to fill constraints
    if (fill_count > 0 and remaining > 0) {
        if (total_fill_weight == 0) {
            // Equal distribution if all weights are 0
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
                const allocated = (remaining * weight) / total_fill_weight;
                out[idx] = allocated;
                used += allocated;
            }
            // Distribute rounding remainder
            var remainder = remaining - used;
            var j: usize = 0;
            while (remainder > 0 and j < fill_count) : (j += 1) {
                const idx = fill_indices[j];
                out[idx] += 1;
                remainder -= 1;
            }
        }
    }

    // Pass 3: apply min/max bounds to fill results
    for (0..fill_count) |j| {
        const idx = fill_indices[j];
        // ensure fill gets at least 1 pixel if any space remains
        _ = switch (constraints[idx]) {
            .fill => |w| w,
            else => unreachable,
        };
        // Check if there's an explicit min on this index from another constraint type
        // (fill doesn't have min/max directly, but we ensure non-zero if space allows)
        if (out[idx] == 0 and remaining > 0) {
            out[idx] = 1;
        }
    }

    // Clamp everything to available
    var sum: usize = 0;
    for (out) |w| sum += w;
    if (sum > available) {
        // Shrink from right to left
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

test "split empty constraints returns empty" {
    const arena = std.testing.allocator;
    const area = Rect{ .x = 0, .y = 0, .width = 10, .height = 1 };
    const constraints = &[_]Constraint{};

    const rects = try splitHorizontal(arena, area, constraints, 0);
    try std.testing.expectEqual(@as(usize, 0), rects.len);
}
