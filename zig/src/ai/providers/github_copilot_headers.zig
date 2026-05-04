const std = @import("std");
const types = @import("../types.zig");

/// Infers the Copilot initiator based on the last message in the conversation.
/// Returns "user" if the last message is from a user, otherwise "agent" (for assistant or tool messages).
pub fn inferCopilotInitiator(messages: []const types.Message) []const u8 {
    if (messages.len == 0) {
        return "user";
    }
    const last = messages[messages.len - 1];
    switch (last) {
        .user => return "user",
        else => return "agent",
    }
}

/// Checks if any message contains images (for Copilot-Vision-Request header).
pub fn hasCopilotVisionInput(messages: []const types.Message) bool {
    for (messages) |msg| {
        switch (msg) {
            .user => |user_msg| {
                for (user_msg.content) |content_block| {
                    if (content_block == .image) {
                        return true;
                    }
                }
            },
            .toolResult => |tool_result_msg| {
                for (tool_result_msg.content) |content_block| {
                    if (content_block == .image) {
                        return true;
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

/// Builds dynamic headers for GitHub Copilot requests.
pub fn buildCopilotDynamicHeaders(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer headers.deinit();

    const initiator = inferCopilotInitiator(messages);
    try headers.put("X-Initiator", try allocator.dupe(u8, initiator));
    try headers.put("Openai-Intent", try allocator.dupe(u8, "conversation-edits"));

    if (hasCopilotVisionInput(messages)) {
        try headers.put("Copilot-Vision-Request", try allocator.dupe(u8, "true"));
    }

    return headers;
}