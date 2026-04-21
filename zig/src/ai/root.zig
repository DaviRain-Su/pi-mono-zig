const std = @import("std");

pub const types = @import("types.zig");
pub const api_registry = @import("api_registry.zig");
pub const json_parse = @import("json_parse.zig");
pub const http_client = @import("http_client.zig");
pub const providers = struct {
    pub const openai = @import("providers/openai.zig");
};

// Re-export commonly used types
pub const Model = types.Model;
pub const Message = types.Message;
pub const Context = types.Context;
pub const StreamOptions = types.StreamOptions;
pub const AssistantMessage = types.AssistantMessage;
pub const AssistantMessageEvent = types.AssistantMessageEvent;
pub const EventType = types.EventType;
pub const StopReason = types.StopReason;
pub const Usage = types.Usage;
pub const Tool = types.Tool;
pub const ToolCall = types.ToolCall;

test {
    std.testing.refAllDecls(@This());
}
