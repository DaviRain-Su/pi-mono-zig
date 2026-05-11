const std = @import("std");

pub const RuntimeSurface = enum {
    component,
    dialog,
    storage,
    tool,
    util,
    prompt,
    entry,
};

pub const ModuleDescriptor = struct {
    name: []const u8,
    source_path: []const u8,
    surface: RuntimeSurface,
};

pub fn descriptor(name: []const u8, source_path: []const u8, surface: RuntimeSurface) ModuleDescriptor {
    return .{ .name = name, .source_path = source_path, .surface = surface };
}

pub fn kebabToSnake(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, value);
    for (out) |*byte| {
        if (byte.* == '-') byte.* = '_';
    }
    return out;
}

test "kebabToSnake normalizes TS file slugs" {
    const allocator = std.testing.allocator;
    const value = try kebabToSnake(allocator, "message-renderer-registry");
    defer allocator.free(value);
    try std.testing.expectEqualStrings("message_renderer_registry", value);
}
