const std = @import("std");

pub const Api = []const u8;
pub const Provider = []const u8;

pub const ThinkingLevel = enum {
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const CacheRetention = enum {
    none,
    short,
    long,
};

pub const Transport = enum {
    sse,
    websocket,
    auto,
};

pub const StopReason = enum {
    stop,
    length,
    tool_use,
    error_reason,
    aborted,
};

pub const Usage = struct {
    input: u32 = 0,
    output: u32 = 0,
    cache_read: u32 = 0,
    cache_write: u32 = 0,
    total_tokens: u32 = 0,

    pub fn init() Usage {
        return .{};
    }
};

pub const TextContent = struct {
    text: []const u8,
};

pub const ImageContent = struct {
    data: []const u8, // base64
    mime_type: []const u8,
};

pub const ThinkingContent = struct {
    thinking: []const u8,
    signature: ?[]const u8 = null,
    redacted: bool = false,
};

pub const ContentBlock = union(enum) {
    text: TextContent,
    image: ImageContent,
    thinking: ThinkingContent,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.Value,
};

pub const UserMessage = struct {
    role: []const u8 = "user",
    content: []const ContentBlock,
    timestamp: i64,
};

pub const AssistantMessage = struct {
    role: []const u8 = "assistant",
    content: []const ContentBlock,
    tool_calls: ?[]const ToolCall = null,
    api: Api,
    provider: Provider,
    model: []const u8,
    usage: Usage,
    stop_reason: StopReason,
    error_message: ?[]const u8 = null,
    timestamp: i64,
};

pub const ToolResultMessage = struct {
    role: []const u8 = "toolResult",
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const ContentBlock,
    is_error: bool = false,
    timestamp: i64,
};

pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

pub const Context = struct {
    system_prompt: ?[]const u8 = null,
    messages: []const Message,
    tools: ?[]const Tool = null,
};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    api: Api,
    provider: Provider,
    base_url: []const u8,
    reasoning: bool = false,
    input_types: []const []const u8, // "text", "image"
    context_window: u32,
    max_tokens: u32,
};

pub const StreamOptions = struct {
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    api_key: ?[]const u8 = null,
    transport: Transport = .auto,
    cache_retention: CacheRetention = .short,
    session_id: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,
};

pub const EventType = enum {
    start,
    text_start,
    text_delta,
    text_end,
    thinking_start,
    thinking_delta,
    thinking_end,
    toolcall_start,
    toolcall_delta,
    toolcall_end,
    done,
    error_event,
};

pub const AssistantMessageEvent = struct {
    event_type: EventType,
    content_index: ?u32 = null,
    delta: ?[]const u8 = null,
    content: ?[]const u8 = null,
    tool_call: ?ToolCall = null,
    message: ?AssistantMessage = null,
    error_message: ?[]const u8 = null,
};

test "Usage defaults" {
    const usage = Usage.init();
    try std.testing.expectEqual(@as(u32, 0), usage.input);
    try std.testing.expectEqual(@as(u32, 0), usage.output);
}

test "Message union" {
    const user_msg = Message{ .user = .{
        .content = &[1]ContentBlock{.{ .text = .{ .text = "hello" } }},
        .timestamp = 1234567890,
    } };
    try std.testing.expectEqualStrings("user", user_msg.user.role);
}
