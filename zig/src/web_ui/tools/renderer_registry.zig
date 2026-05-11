const common = @import("../common.zig");
pub const descriptor = common.descriptor("renderer-registry", "tools/renderer-registry.ts", .tool);

const std = @import("std");

pub const ToolRenderState = enum {
    inprogress,
    complete,
    @"error",
};

pub const ToolRenderResult = struct {
    is_custom: bool = false,
};

pub const ToolRendererRegistry = struct {
    allocator: std.mem.Allocator,
    renderers: std.StringHashMap(ToolRenderResult),

    pub fn init(allocator: std.mem.Allocator) ToolRendererRegistry {
        return .{ .allocator = allocator, .renderers = .init(allocator) };
    }

    pub fn deinit(self: *ToolRendererRegistry) void {
        self.renderers.deinit();
        self.* = undefined;
    }

    pub fn registerToolRenderer(self: *ToolRendererRegistry, tool_name: []const u8, renderer: ToolRenderResult) !void {
        try self.renderers.put(tool_name, renderer);
    }

    pub fn getToolRenderer(self: *ToolRendererRegistry, tool_name: []const u8) ?ToolRenderResult {
        return self.renderers.get(tool_name);
    }
};

pub fn headerStatusClass(state: ToolRenderState) []const u8 {
    return switch (state) {
        .inprogress => "text-foreground animate-spin",
        .complete => "text-green-600 dark:text-green-500",
        .@"error" => "text-destructive",
    };
}

test "web-ui tool renderer registry registers and retrieves renderers" {
    var registry = ToolRendererRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerToolRenderer("bash", .{ .is_custom = true });
    try std.testing.expect(registry.getToolRenderer("bash").?.is_custom);
    try std.testing.expectEqualStrings("text-destructive", headerStatusClass(.@"error"));
}
