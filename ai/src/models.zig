const std = @import("std");
const types = @import("types.zig");

/// In-memory registry of provider -> model_id -> Model.
/// Populated at runtime via `registerModel`.
var registry = std.StringHashMap(std.StringHashMap(types.Model)).init(std.heap.page_allocator);
var registry_mutex = std.Thread.Mutex{};

pub fn registerModel(model: types.Model) void {
    registry_mutex.lock();
    defer registry_mutex.unlock();

    const provider_key = switch (model.provider) {
        .known => |k| @tagName(k),
        .custom => |c| c,
    };

    const gop = registry.getOrPut(provider_key) catch @panic("OOM");
    if (!gop.found_existing) {
        gop.value_ptr.* = std.StringHashMap(types.Model).init(std.heap.page_allocator);
    }
    gop.value_ptr.put(model.id, model) catch @panic("OOM");
}

pub fn getModel(provider: []const u8, model_id: []const u8) ?types.Model {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const provider_models = registry.get(provider) orelse return null;
    return provider_models.get(model_id);
}

pub fn getProviders(gpa: std.mem.Allocator) ![][]const u8 {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    var list = std.ArrayList([]const u8).init(gpa);
    var it = registry.keyIterator();
    while (it.next()) |key| {
        try list.append(key.*);
    }
    return try list.toOwnedSlice();
}

pub fn getModels(gpa: std.mem.Allocator, provider: []const u8) ![]types.Model {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const provider_models = registry.get(provider) orelse return &.{};
    var list = std.ArrayList(types.Model).init(gpa);
    var it = provider_models.valueIterator();
    while (it.next()) |model| {
        try list.append(model.*);
    }
    return try list.toOwnedSlice();
}

pub fn calculateCost(model: types.Model, usage: *types.Usage) void {
    usage.cost.input = (model.cost.input / 1_000_000.0) * @as(f64, @floatFromInt(usage.input));
    usage.cost.output = (model.cost.output / 1_000_000.0) * @as(f64, @floatFromInt(usage.output));
    usage.cost.cache_read = (model.cost.cache_read / 1_000_000.0) * @as(f64, @floatFromInt(usage.cache_read));
    usage.cost.cache_write = (model.cost.cache_write / 1_000_000.0) * @as(f64, @floatFromInt(usage.cache_write));
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
}

pub fn supportsXhigh(model: types.Model) bool {
    if (std.mem.indexOf(u8, model.id, "gpt-5.2") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.3") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.4") != null)
    {
        return true;
    }
    if (std.mem.indexOf(u8, model.id, "opus-4-6") != null or
        std.mem.indexOf(u8, model.id, "opus-4.6") != null)
    {
        return true;
    }
    return false;
}

pub fn modelsAreEqual(a: ?types.Model, b: ?types.Model) bool {
    if (a == null or b == null) return false;
    if (!std.mem.eql(u8, a.?.id, b.?.id)) return false;
    return providerEql(a.?.provider, b.?.provider);
}

fn providerEql(p1: types.Provider, p2: types.Provider) bool {
    return switch (p1) {
        .known => |k1| switch (p2) {
            .known => |k2| k1 == k2,
            else => false,
        },
        .custom => |c1| switch (p2) {
            .custom => |c2| std.mem.eql(u8, c1, c2),
            else => false,
        },
    };
}

test "register and get model" {
    const model = types.Model{
        .id = "kimi-latest",
        .name = "Kimi",
        .api = .{ .known = .openai_completions },
        .provider = .{ .known = .kimi_coding },
        .cost = .{ .input = 1.0, .output = 2.0 },
        .max_tokens = 8192,
    };
    registerModel(model);
    const looked = getModel("kimi_coding", "kimi-latest");
    try std.testing.expect(looked != null);
    try std.testing.expectEqualStrings("kimi-latest", looked.?.id);
}

test "calculateCost" {
    const model = types.Model{ .id = "test", .name = "T", .api = .{ .known = .faux }, .provider = .{ .known = .openai }, .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.5, .cache_write = 0.25 }, .max_tokens = 1000 };
    var usage = types.Usage{ .input = 1_000_000, .output = 500_000, .cache_read = 200_000, .cache_write = 100_000, .total_tokens = 1_800_000 };
    calculateCost(model, &usage);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), usage.cost.input, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), usage.cost.output, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), usage.cost.cache_read, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.025), usage.cost.cache_write, 0.001);
}

test "supportsXhigh" {
    const m1 = types.Model{ .id = "gpt-5.2-any", .name = "T", .api = .{ .known = .faux }, .provider = .{ .known = .openai }, .max_tokens = 1000 };
    try std.testing.expect(supportsXhigh(m1));
    const m2 = types.Model{ .id = "gpt-4o", .name = "T", .api = .{ .known = .faux }, .provider = .{ .known = .openai }, .max_tokens = 1000 };
    try std.testing.expect(!supportsXhigh(m2));
}
