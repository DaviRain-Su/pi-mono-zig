const common = @import("../common.zig");
pub const descriptor = common.descriptor("message-renderer-registry", "components/message-renderer-registry.ts", .component);

const std = @import("std");

pub const MessageRole = enum {
    system,
    user,
    assistant,
    tool,
};

pub const MessageRenderer = struct {
    name: []const u8,
};

pub const MessageRendererRegistry = struct {
    renderers: [4]?MessageRenderer = .{ null, null, null, null },

    pub fn registerMessageRenderer(self: *MessageRendererRegistry, role: MessageRole, renderer: MessageRenderer) void {
        self.renderers[roleIndex(role)] = renderer;
    }

    pub fn getMessageRenderer(self: MessageRendererRegistry, role: MessageRole) ?MessageRenderer {
        return self.renderers[roleIndex(role)];
    }

    pub fn renderMessage(self: MessageRendererRegistry, role: MessageRole) ?[]const u8 {
        return if (self.getMessageRenderer(role)) |renderer| renderer.name else null;
    }
};

fn roleIndex(role: MessageRole) usize {
    return switch (role) {
        .system => 0,
        .user => 1,
        .assistant => 2,
        .tool => 3,
    };
}

test "web-ui message renderer registry registers by role" {
    var registry = MessageRendererRegistry{};
    registry.registerMessageRenderer(.assistant, .{ .name = "assistant-renderer" });
    try std.testing.expectEqualStrings("assistant-renderer", registry.renderMessage(.assistant).?);
    try std.testing.expect(registry.renderMessage(.user) == null);
}
