const std = @import("std");
const ai = @import("ai");

pub const AgentMessage = ai.Message;
pub const AgentToolCall = ai.ToolCall;
pub const ToolResultMessage = ai.types.ToolResultMessage;

pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const ToolExecutionMode = enum {
    sequential,
    parallel,
};

pub const BeforeToolCallResult = struct {
    block: bool = false,
    reason: ?[]const u8 = null,
};

pub const AfterToolCallResult = struct {
    content: ?[]const ai.ContentBlock = null,
    details: ?std.json.Value = null,
    is_error: ?bool = null,
};

pub const AgentToolResult = struct {
    content: []const ai.ContentBlock,
    details: ?std.json.Value = null,
};

pub const AgentToolUpdateCallback = *const fn (
    context: ?*anyopaque,
    // Borrowed for the duration of the callback. Clone any owned fields before retaining them.
    partial_result: AgentToolResult,
) anyerror!void;

pub const PrepareArgumentsFn = *const fn (
    allocator: std.mem.Allocator,
    args: std.json.Value,
) anyerror!std.json.Value;

pub const ExecuteToolFn = *const fn (
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?AgentToolUpdateCallback,
) anyerror!AgentToolResult;

pub const BeforeToolCallContext = struct {
    assistant_message: ai.AssistantMessage,
    tool_call: AgentToolCall,
    args: *std.json.Value,
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

pub const BeforeToolCallFn = *const fn (
    allocator: std.mem.Allocator,
    context: BeforeToolCallContext,
    signal: ?*const std.atomic.Value(bool),
) anyerror!?BeforeToolCallResult;

pub const AfterToolCallFn = *const fn (
    allocator: std.mem.Allocator,
    context: AfterToolCallContext,
    signal: ?*const std.atomic.Value(bool),
) anyerror!?AfterToolCallResult;

pub const AgentTool = struct {
    name: []const u8,
    description: []const u8,
    label: []const u8,
    parameters: std.json.Value,
    prepare_arguments: ?PrepareArgumentsFn = null,
    execute: ?ExecuteToolFn = null,
    execute_context: ?*anyopaque = null,
    execution_mode: ?ToolExecutionMode = null,
};

pub const AgentState = struct {
    system_prompt: []const u8,
    model: ai.Model,
    thinking_level: ThinkingLevel,
    tools: []const AgentTool,
    messages: []const AgentMessage,
    is_streaming: bool,
    streaming_message: ?AgentMessage,
    pending_tool_calls: []const []const u8,
    error_message: ?[]const u8,
};

pub const AgentContext = struct {
    system_prompt: []const u8,
    messages: []const AgentMessage,
    tools: []const AgentTool = &.{},
};

pub const StreamFn = *const fn (
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    context: ai.Context,
    options: ?ai.types.SimpleStreamOptions,
) anyerror!ai.event_stream.AssistantMessageEventStream;

pub const ConvertToLlmFn = *const fn (
    allocator: std.mem.Allocator,
    messages: []const AgentMessage,
) anyerror![]ai.Message;

pub const TransformContextFn = *const fn (
    allocator: std.mem.Allocator,
    messages: []const AgentMessage,
    signal: ?*const std.atomic.Value(bool),
) anyerror![]AgentMessage;

pub const PendingMessagesFn = *const fn (
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
) anyerror![]AgentMessage;

pub const AgentLoopConfig = struct {
    model: ai.Model,
    api_key: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    reasoning: ?ThinkingLevel = null,
    tool_execution: ToolExecutionMode = .parallel,
    before_tool_call: ?BeforeToolCallFn = null,
    after_tool_call: ?AfterToolCallFn = null,
    convert_to_llm: ConvertToLlmFn,
    transform_context: ?TransformContextFn = null,
    get_steering_messages_context: ?*anyopaque = null,
    get_steering_messages: ?PendingMessagesFn = null,
    get_follow_up_messages_context: ?*anyopaque = null,
    get_follow_up_messages: ?PendingMessagesFn = null,
};

pub const AgentEventType = enum {
    agent_start,
    agent_end,
    turn_start,
    turn_end,
    message_start,
    message_update,
    message_end,
    tool_execution_start,
    tool_execution_update,
    tool_execution_end,
};

pub const AgentEvent = struct {
    event_type: AgentEventType,
    message: ?AgentMessage = null,
    messages: ?[]const AgentMessage = null,
    assistant_message_event: ?ai.AssistantMessageEvent = null,
    tool_results: ?[]const ToolResultMessage = null,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    args: ?std.json.Value = null,
    result: ?AgentToolResult = null,
    partial_result: ?AgentToolResult = null,
    is_error: ?bool = null,
};

pub const AgentEventCallback = *const fn (
    context: ?*anyopaque,
    event: AgentEvent,
) anyerror!void;

pub const AgentSubscriber = struct {
    context: ?*anyopaque = null,
    callback: AgentEventCallback,
};

test "thinking levels include off" {
    try std.testing.expectEqual(ThinkingLevel.off, .off);
    try std.testing.expectEqual(ToolExecutionMode.parallel, .parallel);
}

test "agent event type includes single turn lifecycle variants" {
    try std.testing.expectEqual(AgentEventType.agent_start, .agent_start);
    try std.testing.expectEqual(AgentEventType.message_update, .message_update);
    try std.testing.expectEqual(AgentEventType.agent_end, .agent_end);
}
