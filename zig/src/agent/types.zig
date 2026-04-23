const std = @import("std");
const ai = @import("ai");

pub const AgentMessage = ai.Message;
pub const AgentToolCall = ai.ToolCall;

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

pub const AgentToolResult = struct {
    content: []const ai.ContentBlock,
    details: ?std.json.Value = null,
};

pub const AgentToolUpdateCallback = *const fn (
    context: ?*anyopaque,
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
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?AgentToolUpdateCallback,
) anyerror!AgentToolResult;

pub const AgentTool = struct {
    name: []const u8,
    description: []const u8,
    label: []const u8,
    parameters: std.json.Value,
    prepare_arguments: ?PrepareArgumentsFn = null,
    execute: ?ExecuteToolFn = null,
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

test "thinking levels include off" {
    try std.testing.expectEqual(ThinkingLevel.off, .off);
    try std.testing.expectEqual(ToolExecutionMode.parallel, .parallel);
}
