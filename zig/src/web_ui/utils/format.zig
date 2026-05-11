const common = @import("../common.zig");
pub const descriptor = common.descriptor("format", "utils/format.ts", .util);

const std = @import("std");

pub const UsageCost = struct {
    total: f64 = 0,
};

pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    cost: ?UsageCost = null,
};

pub const ModelCost = struct {
    input: f64 = 0,
    output: f64 = 0,
};

pub fn plural(count: usize, singular: []const u8, plural_value: []const u8) []const u8 {
    return if (count == 1) singular else plural_value;
}

pub fn formatCost(allocator: std.mem.Allocator, cost: f64) ![]u8 {
    return std.fmt.allocPrint(allocator, "${d:.4}", .{cost});
}

pub fn formatTokenCount(allocator: std.mem.Allocator, count: u64) ![]u8 {
    if (count < 1000) return std.fmt.allocPrint(allocator, "{d}", .{count});
    if (count < 10000) return std.fmt.allocPrint(allocator, "{d:.1}k", .{@as(f64, @floatFromInt(count)) / 1000.0});
    return std.fmt.allocPrint(allocator, "{d}k", .{roundDiv(count, 1000)});
}

pub fn formatModelCost(allocator: std.mem.Allocator, cost: ?ModelCost) ![]u8 {
    const value = cost orelse return allocator.dupe(u8, "Free");
    if (value.input == 0 and value.output == 0) return allocator.dupe(u8, "Free");
    const input = try formatModelCostNumber(allocator, value.input);
    defer allocator.free(input);
    const output = try formatModelCostNumber(allocator, value.output);
    defer allocator.free(output);
    return std.fmt.allocPrint(allocator, "${s}/${s}", .{ input, output });
}

pub fn formatUsage(allocator: std.mem.Allocator, usage: ?Usage) ![]u8 {
    const value = usage orelse return allocator.dupe(u8, "");
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var wrote = false;
    try appendUsagePart(allocator, &out.writer, &wrote, "↑", value.input);
    try appendUsagePart(allocator, &out.writer, &wrote, "↓", value.output);
    try appendUsagePart(allocator, &out.writer, &wrote, "R", value.cache_read);
    try appendUsagePart(allocator, &out.writer, &wrote, "W", value.cache_write);
    if (value.cost) |cost| {
        if (cost.total != 0) {
            if (wrote) try out.writer.writeByte(' ');
            const formatted = try formatCost(allocator, cost.total);
            defer allocator.free(formatted);
            try out.writer.writeAll(formatted);
        }
    }
    return out.toOwnedSlice();
}

fn appendUsagePart(allocator: std.mem.Allocator, writer: *std.Io.Writer, wrote: *bool, prefix: []const u8, count: u64) !void {
    if (count == 0) return;
    if (wrote.*) try writer.writeByte(' ');
    try writer.writeAll(prefix);
    const formatted = try formatTokenCount(allocator, count);
    defer allocator.free(formatted);
    try writer.writeAll(formatted);
    wrote.* = true;
}

fn formatModelCostNumber(allocator: std.mem.Allocator, value: f64) ![]u8 {
    if (value >= 100) return std.fmt.allocPrint(allocator, "{d:.0}", .{value});
    if (value >= 10) return trimTrailingZeros(allocator, try std.fmt.allocPrint(allocator, "{d:.1}", .{value}));
    if (value >= 1) return trimTrailingZeros(allocator, try std.fmt.allocPrint(allocator, "{d:.2}", .{value}));
    return trimTrailingZeros(allocator, try std.fmt.allocPrint(allocator, "{d:.3}", .{value}));
}

fn trimTrailingZeros(allocator: std.mem.Allocator, owned: []u8) ![]u8 {
    var end = owned.len;
    while (end > 0 and owned[end - 1] == '0') : (end -= 1) {}
    if (end > 0 and owned[end - 1] == '.') end -= 1;
    const trimmed = try allocator.dupe(u8, owned[0..end]);
    allocator.free(owned);
    return trimmed;
}

fn roundDiv(value: u64, divisor: u64) u64 {
    return (value + divisor / 2) / divisor;
}

test "web-ui format token counts match TS thresholds" {
    const allocator = std.testing.allocator;
    const small = try formatTokenCount(allocator, 999);
    defer allocator.free(small);
    const medium = try formatTokenCount(allocator, 1500);
    defer allocator.free(medium);
    const large = try formatTokenCount(allocator, 12_499);
    defer allocator.free(large);
    try std.testing.expectEqualStrings("999", small);
    try std.testing.expectEqualStrings("1.5k", medium);
    try std.testing.expectEqualStrings("12k", large);
}

test "web-ui format usage joins populated fields" {
    const allocator = std.testing.allocator;
    const text = try formatUsage(allocator, .{ .input = 1500, .output = 20, .cost = .{ .total = 0.12345 } });
    defer allocator.free(text);
    try std.testing.expectEqualStrings("↑1.5k ↓20 $0.1235", text);
}
