const std = @import("std");
const ai = @import("ai");

/// Agent message types aligned with pi-mono's agent-core.
/// Uses a Zig `union(enum)` with a `custom` variant to simulate
/// TypeScript declaration merging for message extensibility.
pub const AgentMessageTag = enum {
    user,
    assistant,
    tool_result,
    custom,
};

pub const AgentMessage = union(AgentMessageTag) {
    user: ai.UserMessage,
    assistant: ai.AssistantMessage,
    tool_result: ai.ToolResultMessage,
    custom: CustomAgentMessage,

    /// Convert an ai.Message into an AgentMessage.
    pub fn fromAiMessage(msg: ai.Message) AgentMessage {
        return switch (msg) {
            .user => |u| .{ .user = u },
            .assistant => |a| .{ .assistant = a },
            .tool_result => |t| .{ .tool_result = t },
        };
    }

    /// Convert this AgentMessage into an ai.Message.
    /// Custom messages return `null` since they are agent-specific.
    pub fn toAiMessage(self: AgentMessage) ?ai.Message {
        return switch (self) {
            .user => |u| .{ .user = u },
            .assistant => |a| .{ .assistant = a },
            .tool_result => |t| .{ .tool_result = t },
            .custom => null,
        };
    }
};

/// Custom agent message payload for extensibility.
/// Users can extend by wrapping their own data in the `custom` union arm.
pub const CustomAgentMessage = struct {
    tag: []const u8,
    payload: std.json.Value,
};

/// Convert a slice of AgentMessages to ai.Messages, allocating as needed.
pub fn toAiMessages(gpa: std.mem.Allocator, messages: []const AgentMessage) ![]ai.Message {
    var list = std.ArrayList(ai.Message).empty;
    defer list.deinit(gpa);
    for (messages) |msg| {
        if (msg.toAiMessage()) |aim| {
            try list.append(gpa, aim);
        }
    }
    return list.toOwnedSlice(gpa);
}

pub const ToolExecutionMode = enum {
    sequential,
    parallel,
};

pub const AgentToolCall = ai.ToolCall;

pub const BeforeToolCallResult = struct {
    block: bool = false,
    reason: ?[]const u8 = null,
};

pub const AfterToolCallResult = struct {
    content: ?[]const ai.ContentBlock = null,
    details: ?std.json.Value = null,
    is_error: ?bool = null,
};

pub const BeforeToolCallContext = struct {
    assistant_message: ai.AssistantMessage,
    tool_call: AgentToolCall,
    args: std.json.Value,
    context: AgentContext,
};

pub const AfterToolCallContext = struct {
    assistant_message: ai.AssistantMessage,
    tool_call: AgentToolCall,
    args: std.json.Value,
    result: AgentToolResult,
    is_error: bool,
    context: AgentContext,
};

pub const AgentToolResult = struct {
    content: []const ai.ContentBlock,
    details: std.json.Value,
};

pub const AgentToolUpdateCallback = *const fn (partial: AgentToolResult) void;

pub const AgentTool = struct {
    name: []const u8,
    label: []const u8,
    description: []const u8,
    parameters: std.json.Value,
    prepare_arguments: ?*const fn (args: std.json.Value) std.json.Value = null,
    execute: *const fn (tool_call_id: []const u8, params: std.json.Value, signal: ?*anyopaque, on_update: ?AgentToolUpdateCallback) anyerror!AgentToolResult,
};

pub const AgentContext = struct {
    system_prompt: []const u8,
    messages: []AgentMessage,
    tools: ?[]const AgentTool = null,
};

pub const AgentEvent = union(enum) {
    agent_start,
    agent_end: struct { messages: []AgentMessage },
    turn_start,
    turn_end: struct { message: AgentMessage, tool_results: []const ai.ToolResultMessage },
    message_start: AgentMessage,
    message_update: struct { message: AgentMessage, assistant_event: ai.AssistantMessageEvent },
    message_end: AgentMessage,
    tool_execution_start: struct { tool_call_id: []const u8, tool_name: []const u8, args: std.json.Value },
    tool_execution_update: struct { tool_call_id: []const u8, tool_name: []const u8, args: std.json.Value, partial_result: std.json.Value },
    tool_execution_end: struct { tool_call_id: []const u8, tool_name: []const u8, result: std.json.Value, is_error: bool },
};

pub const AgentState = struct {
    system_prompt: []const u8,
    model: ai.Model,
    thinking_level: ai.types.ThinkingLevel,
    tools: []const AgentTool,
    messages: []AgentMessage,
    is_streaming: bool = false,
    streaming_message: ?AgentMessage = null,
    pending_tool_calls: std.StringHashMap(void), // set of ids
    error_message: ?[]const u8 = null,
};

pub const ConvertToLlmFn = *const fn (gpa: std.mem.Allocator, messages: []const AgentMessage) anyerror![]ai.Message;
pub const TransformContextFn = *const fn (gpa: std.mem.Allocator, messages: []const AgentMessage) anyerror![]AgentMessage;
pub const GetAgentMessagesFn = *const fn (ctx: ?*anyopaque) []const AgentMessage;
pub const BeforeToolCallFn = *const fn (ctx: BeforeToolCallContext) anyerror!?BeforeToolCallResult;
pub const AfterToolCallFn = *const fn (ctx: AfterToolCallContext) anyerror!?AfterToolCallResult;

pub const AgentLoopConfig = struct {
    model: ai.Model,
    api_key: ?[]const u8 = null,
    convert_to_llm: ConvertToLlmFn = defaultConvertToLlm,
    transform_context: ?TransformContextFn = null,
    get_api_key: ?*const fn (provider: []const u8) ?[]const u8 = null,
    get_steering_messages: ?GetAgentMessagesFn = null,
    get_follow_up_messages: ?GetAgentMessagesFn = null,
    tool_execution: ToolExecutionMode = .parallel,
    before_tool_call: ?BeforeToolCallFn = null,
    after_tool_call: ?AfterToolCallFn = null,
    user_ctx: ?*anyopaque = null,

    fn defaultConvertToLlm(gpa: std.mem.Allocator, messages: []const AgentMessage) ![]ai.Message {
        return try toAiMessages(gpa, messages);
    }
};
