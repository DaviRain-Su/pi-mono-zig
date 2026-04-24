const std = @import("std");

pub const types = @import("types.zig");
pub const api_registry = @import("api_registry.zig");
pub const model_registry = @import("model_registry.zig");
pub const json_parse = @import("json_parse.zig");
pub const http_client = @import("http_client.zig");
pub const event_stream = @import("event_stream.zig");
pub const stream_module = @import("stream.zig");
pub const env_api_keys = @import("env_api_keys.zig");
pub const providers = struct {
    pub const openai = @import("providers/openai.zig");
    pub const openai_responses = @import("providers/openai_responses.zig");
    pub const azure_openai_responses = @import("providers/azure_openai_responses.zig");
    pub const openai_codex_responses = @import("providers/openai_codex_responses.zig");
    pub const anthropic = @import("providers/anthropic.zig");
    pub const google = @import("providers/google.zig");
    pub const google_gemini_cli = @import("providers/google_gemini_cli.zig");
    pub const google_vertex = @import("providers/google_vertex.zig");
    pub const mistral = @import("providers/mistral.zig");
    pub const bedrock = @import("providers/bedrock.zig");
    pub const register_builtins = @import("providers/register_builtins.zig");
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
pub const TextContent = types.TextContent;
pub const ImageContent = types.ImageContent;
pub const ThinkingContent = types.ThinkingContent;
pub const UserMessage = types.UserMessage;
pub const stream = stream_module.stream;
pub const complete = stream_module.complete;
pub const streamSimple = stream_module.streamSimple;
pub const completeSimple = stream_module.completeSimple;
pub const getEnvApiKey = env_api_keys.getEnvApiKey;

test {
    _ = @import("providers/openai.zig");
    _ = @import("providers/openai_responses.zig");
    _ = @import("providers/azure_openai_responses.zig");
    _ = @import("providers/openai_codex_responses.zig");
    _ = @import("providers/anthropic.zig");
    _ = @import("providers/google.zig");
    _ = @import("providers/google_gemini_cli.zig");
    _ = @import("providers/google_vertex.zig");
    _ = @import("providers/mistral.zig");
    _ = @import("providers/bedrock.zig");
    _ = @import("providers/register_builtins.zig");
    _ = @import("model_registry.zig");
    _ = @import("stream.zig");
    _ = @import("env_api_keys.zig");
    _ = @import("providers/faux.zig");
}
