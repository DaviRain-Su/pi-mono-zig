const std = @import("std");
const ai = @import("ai");

pub const types = @import("types.zig");
pub const agent_mod = @import("agent.zig");
pub const agent_loop = @import("agent_loop.zig");
pub const proxy = @import("proxy.zig");

pub const Agent = agent_mod.Agent;
pub const AgentOptions = agent_mod.AgentOptions;
pub const QueueMode = agent_mod.QueueMode;
pub const PendingMessageQueue = agent_mod.PendingMessageQueue;
pub const AgentState = types.AgentState;
pub const AgentEvent = types.AgentEvent;
pub const AgentMessage = types.AgentMessage;
pub const AgentTool = types.AgentTool;
pub const AgentToolResult = types.AgentToolResult;
pub const AgentToolCall = types.AgentToolCall;
pub const AgentContext = types.AgentContext;
pub const ToolExecutionMode = types.ToolExecutionMode;
pub const BeforeToolCallContext = types.BeforeToolCallContext;
pub const AfterToolCallContext = types.AfterToolCallContext;
pub const BeforeToolCallResult = types.BeforeToolCallResult;
pub const AfterToolCallResult = types.AfterToolCallResult;
pub const AgentLoopConfig = types.AgentLoopConfig;
pub const AgentEventStream = agent_loop.AgentEventStream;
pub const createAgentEventStream = agent_loop.createAgentEventStream;
pub const agentLoop = agent_loop.agentLoop;
pub const agentLoopContinue = agent_loop.agentLoopContinue;
pub const ProxyStreamOptions = proxy.ProxyStreamOptions;
pub const ProxyAssistantMessageEvent = proxy.ProxyAssistantMessageEvent;
pub const streamProxy = proxy.streamProxy;

test "agent types compile" {
    const ev = AgentEvent.agent_start;
    _ = ev;
}

test "agent exports complete" {
    // Verify all major types are exported and usable
    _ = AgentOptions{};
    _ = QueueMode.all;
    _ = ToolExecutionMode.sequential;
    _ = BeforeToolCallResult{};
    _ = AfterToolCallResult{};
    _ = ProxyStreamOptions{ .auth_token = "test", .proxy_url = "http://test" };
}
