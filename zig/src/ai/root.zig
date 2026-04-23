const std = @import("std");

pub const types = @import("types.zig");
pub const api_registry = @import("api_registry.zig");
pub const json_parse = @import("json_parse.zig");
pub const http_client = @import("http_client.zig");
pub const event_stream = @import("event_stream.zig");
pub const stream_module = @import("stream.zig");
pub const env_api_keys = @import("env_api_keys.zig");
pub const providers = struct {
    pub const openai = @import("providers/openai.zig");
    pub const kimi = @import("providers/kimi.zig");
    pub const faux = @import("providers/faux.zig");
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
pub const ContentBlock = types.ContentBlock;
pub const UserMessage = types.UserMessage;
pub const stream = stream_module.stream;
pub const complete = stream_module.complete;
pub const streamSimple = stream_module.streamSimple;
pub const completeSimple = stream_module.completeSimple;
pub const getEnvApiKey = env_api_keys.getEnvApiKey;

test {
    std.testing.refAllDecls(@This());
    _ = @import("providers/openai.zig");
    _ = @import("stream.zig");
    _ = @import("env_api_keys.zig");
}
