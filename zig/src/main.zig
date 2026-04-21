const std = @import("std");
const ai = @import("ai/root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("pi - AI assistant (Zig rewrite)\n", .{});
    std.debug.print("Available APIs: {d}\n", .{ai.api_registry.getApiCount()});

    // TODO: Implement CLI argument parsing
    _ = allocator;
}
