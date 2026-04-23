const std = @import("std");
const ai = @import("ai");
const agent_loop = @import("agent_loop.zig");
const types = @import("types.zig");

const EMPTY_INPUT_TYPES = [_][]const u8{};

pub const QueueMode = enum {
    all,
    one_at_a_time,
};

pub const PendingMessageQueue = struct {
    allocator: std.mem.Allocator,
    mode: QueueMode,
    messages: std.ArrayList(types.AgentMessage),

    pub fn init(allocator: std.mem.Allocator, mode: QueueMode) PendingMessageQueue {
        return .{
            .allocator = allocator,
            .mode = mode,
            .messages = .empty,
        };
    }

    pub fn deinit(self: *PendingMessageQueue) void {
        self.messages.deinit(self.allocator);
    }

    pub fn enqueue(self: *PendingMessageQueue, message: types.AgentMessage) !void {
        try self.messages.append(self.allocator, message);
    }

    pub fn hasItems(self: *const PendingMessageQueue) bool {
        return self.messages.items.len > 0;
    }

    pub fn len(self: *const PendingMessageQueue) usize {
        return self.messages.items.len;
    }

    pub fn clear(self: *PendingMessageQueue) void {
        self.messages.clearRetainingCapacity();
    }

    pub fn drain(self: *PendingMessageQueue, allocator: std.mem.Allocator) ![]types.AgentMessage {
        if (self.mode == .all) {
            defer self.clear();
            return try allocator.dupe(types.AgentMessage, self.messages.items);
        }

        const first = self.messages.items[0..@min(self.messages.items.len, 1)];
        defer if (self.messages.items.len > 0) {
            _ = self.messages.orderedRemove(0);
        };
        return try allocator.dupe(types.AgentMessage, first);
    }
};

pub const AgentOptions = struct {
    system_prompt: []const u8 = "",
    model: ?ai.Model = null,
    thinking_level: types.ThinkingLevel = .off,
    tools: []const types.AgentTool = &.{},
    messages: []const types.AgentMessage = &.{},
    steering_mode: QueueMode = .one_at_a_time,
    follow_up_mode: QueueMode = .one_at_a_time,
    tool_execution: types.ToolExecutionMode = .parallel,
    io: std.Io = std.Io.failing,
    stream_fn: ?types.StreamFn = null,
    convert_to_llm: ?types.ConvertToLlmFn = null,
    transform_context: ?types.TransformContextFn = null,
};

pub const DEFAULT_MODEL = ai.Model{
    .id = "unknown",
    .name = "unknown",
    .api = "unknown",
    .provider = "unknown",
    .base_url = "",
    .reasoning = false,
    .input_types = EMPTY_INPUT_TYPES[0..],
    .cost = .{},
    .context_window = 0,
    .max_tokens = 0,
    .headers = null,
    .compat = null,
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    model: ai.Model,
    thinking_level: types.ThinkingLevel,
    tools: std.ArrayList(types.AgentTool),
    messages: std.ArrayList(types.AgentMessage),
    is_streaming: bool,
    streaming_message: ?types.AgentMessage,
    pending_tool_calls: std.ArrayList([]const u8),
    error_message: ?[]const u8,
    steering_queue: PendingMessageQueue,
    follow_up_queue: PendingMessageQueue,
    tool_execution: types.ToolExecutionMode,
    io: std.Io,
    stream_fn: ?types.StreamFn,
    convert_to_llm: types.ConvertToLlmFn,
    transform_context: ?types.TransformContextFn,
    listeners: std.ArrayList(types.AgentSubscriber),

    pub fn init(allocator: std.mem.Allocator, options: AgentOptions) !Agent {
        var agent = Agent{
            .allocator = allocator,
            .system_prompt = options.system_prompt,
            .model = options.model orelse DEFAULT_MODEL,
            .thinking_level = options.thinking_level,
            .tools = .empty,
            .messages = .empty,
            .is_streaming = false,
            .streaming_message = null,
            .pending_tool_calls = .empty,
            .error_message = null,
            .steering_queue = PendingMessageQueue.init(allocator, options.steering_mode),
            .follow_up_queue = PendingMessageQueue.init(allocator, options.follow_up_mode),
            .tool_execution = options.tool_execution,
            .io = options.io,
            .stream_fn = options.stream_fn,
            .convert_to_llm = options.convert_to_llm orelse defaultConvertToLlm,
            .transform_context = options.transform_context,
            .listeners = .empty,
        };
        errdefer agent.deinit();

        try agent.setTools(options.tools);
        try agent.setMessages(options.messages);
        return agent;
    }

    pub fn deinit(self: *Agent) void {
        self.tools.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        self.pending_tool_calls.deinit(self.allocator);
        self.steering_queue.deinit();
        self.follow_up_queue.deinit();
        self.listeners.deinit(self.allocator);
    }

    pub fn state(self: *const Agent) types.AgentState {
        return .{
            .system_prompt = self.system_prompt,
            .model = self.model,
            .thinking_level = self.thinking_level,
            .tools = self.tools.items,
            .messages = self.messages.items,
            .is_streaming = self.is_streaming,
            .streaming_message = self.streaming_message,
            .pending_tool_calls = self.pending_tool_calls.items,
            .error_message = self.error_message,
        };
    }

    pub fn getSystemPrompt(self: *const Agent) []const u8 {
        return self.system_prompt;
    }

    pub fn setSystemPrompt(self: *Agent, system_prompt: []const u8) void {
        self.system_prompt = system_prompt;
    }

    pub fn getModel(self: *const Agent) ai.Model {
        return self.model;
    }

    pub fn setModel(self: *Agent, model: ai.Model) void {
        self.model = model;
    }

    pub fn getThinkingLevel(self: *const Agent) types.ThinkingLevel {
        return self.thinking_level;
    }

    pub fn setThinkingLevel(self: *Agent, thinking_level: types.ThinkingLevel) void {
        self.thinking_level = thinking_level;
    }

    pub fn getTools(self: *const Agent) []const types.AgentTool {
        return self.tools.items;
    }

    pub fn setTools(self: *Agent, next_tools: []const types.AgentTool) !void {
        self.tools.clearRetainingCapacity();
        try self.tools.appendSlice(self.allocator, next_tools);
    }

    pub fn getMessages(self: *const Agent) []const types.AgentMessage {
        return self.messages.items;
    }

    pub fn setMessages(self: *Agent, next_messages: []const types.AgentMessage) !void {
        self.messages.clearRetainingCapacity();
        try self.messages.appendSlice(self.allocator, next_messages);
    }

    pub fn appendMessage(self: *Agent, message: types.AgentMessage) !void {
        try self.messages.append(self.allocator, message);
    }

    pub fn getStreamingMessage(self: *const Agent) ?types.AgentMessage {
        return self.streaming_message;
    }

    pub fn setStreamingMessage(self: *Agent, message: ?types.AgentMessage) void {
        self.streaming_message = message;
    }

    pub fn isStreaming(self: *const Agent) bool {
        return self.is_streaming;
    }

    pub fn beginRun(self: *Agent) void {
        self.is_streaming = true;
        self.streaming_message = null;
        self.error_message = null;
    }

    pub fn finishRun(self: *Agent) void {
        self.is_streaming = false;
        self.streaming_message = null;
        self.clearPendingToolCalls();
    }

    pub fn getPendingToolCalls(self: *const Agent) []const []const u8 {
        return self.pending_tool_calls.items;
    }

    pub fn addPendingToolCall(self: *Agent, tool_call_id: []const u8) !void {
        for (self.pending_tool_calls.items) |existing| {
            if (std.mem.eql(u8, existing, tool_call_id)) return;
        }
        try self.pending_tool_calls.append(self.allocator, tool_call_id);
    }

    pub fn removePendingToolCall(self: *Agent, tool_call_id: []const u8) bool {
        for (self.pending_tool_calls.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, tool_call_id)) {
                _ = self.pending_tool_calls.orderedRemove(index);
                return true;
            }
        }
        return false;
    }

    pub fn clearPendingToolCalls(self: *Agent) void {
        self.pending_tool_calls.clearRetainingCapacity();
    }

    pub fn getErrorMessage(self: *const Agent) ?[]const u8 {
        return self.error_message;
    }

    pub fn setErrorMessage(self: *Agent, error_message: ?[]const u8) void {
        self.error_message = error_message;
    }

    pub fn steer(self: *Agent, message: types.AgentMessage) !void {
        try self.steering_queue.enqueue(message);
    }

    pub fn followUp(self: *Agent, message: types.AgentMessage) !void {
        try self.follow_up_queue.enqueue(message);
    }

    pub fn clearSteeringQueue(self: *Agent) void {
        self.steering_queue.clear();
    }

    pub fn clearFollowUpQueue(self: *Agent) void {
        self.follow_up_queue.clear();
    }

    pub fn clearAllQueues(self: *Agent) void {
        self.clearSteeringQueue();
        self.clearFollowUpQueue();
    }

    pub fn hasQueuedMessages(self: *const Agent) bool {
        return self.steering_queue.hasItems() or self.follow_up_queue.hasItems();
    }

    pub fn steeringQueueLen(self: *const Agent) usize {
        return self.steering_queue.len();
    }

    pub fn followUpQueueLen(self: *const Agent) usize {
        return self.follow_up_queue.len();
    }

    pub fn reset(self: *Agent) void {
        self.messages.clearRetainingCapacity();
        self.is_streaming = false;
        self.streaming_message = null;
        self.clearPendingToolCalls();
        self.error_message = null;
        self.clearAllQueues();
    }

    pub fn subscribe(self: *Agent, subscriber: types.AgentSubscriber) !void {
        try self.listeners.append(self.allocator, subscriber);
    }

    pub fn prompt(self: *Agent, input: []const u8) !void {
        if (self.is_streaming) return error.AgentAlreadyProcessing;

        const prompt_message = try userTextMessage(std.heap.page_allocator, input, 0);
        const prompts = [_]types.AgentMessage{prompt_message};
        const context = self.createContextSnapshot();
        const config = self.createLoopConfig();
        var abort_signal = std.atomic.Value(bool).init(false);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        self.beginRun();
        defer self.finishRun();

        const added_messages = try agent_loop.runAgentLoop(
            arena.allocator(),
            self.io,
            prompts[0..],
            context,
            config,
            self,
            emitAgentEvent,
            &abort_signal,
            self.stream_fn,
        );
        _ = added_messages;
    }

    fn createContextSnapshot(self: *const Agent) types.AgentContext {
        return .{
            .system_prompt = self.system_prompt,
            .messages = self.messages.items,
            .tools = self.tools.items,
        };
    }

    fn createLoopConfig(self: *const Agent) types.AgentLoopConfig {
        return .{
            .model = self.model,
            .reasoning = if (self.thinking_level == .off) null else self.thinking_level,
            .tool_execution = self.tool_execution,
            .convert_to_llm = self.convert_to_llm,
            .transform_context = self.transform_context,
        };
    }

    fn processEvent(self: *Agent, event: types.AgentEvent) !void {
        switch (event.event_type) {
            .message_start => {
                self.streaming_message = event.message;
            },
            .message_update => {
                self.streaming_message = event.message;
            },
            .message_end => {
                self.streaming_message = null;
                if (event.message) |message| {
                    try self.appendMessage(message);
                }
            },
            .turn_end => {
                if (event.message) |message| {
                    switch (message) {
                        .assistant => |assistant| {
                            if (assistant.error_message) |error_message| {
                                self.error_message = error_message;
                            }
                        },
                        else => {},
                    }
                }
            },
            .agent_end => {
                self.streaming_message = null;
            },
            else => {},
        }

        for (self.listeners.items) |subscriber| {
            try subscriber.callback(subscriber.context, event);
        }
    }
};

fn emitAgentEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const self: *Agent = @ptrCast(@alignCast(context.?));
    try self.processEvent(event);
}

fn defaultConvertToLlm(
    allocator: std.mem.Allocator,
    messages: []const types.AgentMessage,
) ![]ai.Message {
    return try allocator.dupe(ai.Message, messages);
}

fn userTextMessage(
    allocator: std.mem.Allocator,
    text: []const u8,
    timestamp: i64,
) !types.AgentMessage {
    const content = try allocator.alloc(ai.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };
    return .{ .user = .{
        .content = content,
        .timestamp = timestamp,
    } };
}

fn makeTool(name: []const u8, label: []const u8) types.AgentTool {
    return .{
        .name = name,
        .description = "test tool",
        .label = label,
        .parameters = .null,
    };
}

test "agent initializes with default state" {
    var agent = try Agent.init(std.testing.allocator, .{});
    defer agent.deinit();

    const state = agent.state();
    try std.testing.expectEqualStrings("", state.system_prompt);
    try std.testing.expectEqualStrings("unknown", state.model.id);
    try std.testing.expectEqual(types.ThinkingLevel.off, state.thinking_level);
    try std.testing.expectEqual(@as(usize, 0), state.tools.len);
    try std.testing.expectEqual(@as(usize, 0), state.messages.len);
    try std.testing.expect(!state.is_streaming);
    try std.testing.expect(state.streaming_message == null);
    try std.testing.expectEqual(@as(usize, 0), state.pending_tool_calls.len);
    try std.testing.expect(state.error_message == null);
    try std.testing.expectEqual(types.ToolExecutionMode.parallel, agent.tool_execution);
    try std.testing.expectEqual(QueueMode.one_at_a_time, agent.steering_queue.mode);
    try std.testing.expectEqual(QueueMode.one_at_a_time, agent.follow_up_queue.mode);
}

test "agent state accessors expose configured values" {
    const configured_model = ai.Model{
        .id = "faux-1",
        .name = "Faux 1",
        .api = "faux",
        .provider = "faux",
        .base_url = "http://localhost:0",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var agent = try Agent.init(std.testing.allocator, .{
        .system_prompt = "system",
        .model = configured_model,
        .thinking_level = .medium,
        .tool_execution = .sequential,
    });
    defer agent.deinit();

    try std.testing.expectEqualStrings("system", agent.getSystemPrompt());
    try std.testing.expectEqualStrings("faux-1", agent.getModel().id);
    try std.testing.expectEqual(types.ThinkingLevel.medium, agent.getThinkingLevel());
    try std.testing.expectEqual(types.ToolExecutionMode.sequential, agent.tool_execution);

    agent.setSystemPrompt("changed");
    agent.setThinkingLevel(.high);
    try std.testing.expectEqualStrings("changed", agent.state().system_prompt);
    try std.testing.expectEqual(types.ThinkingLevel.high, agent.state().thinking_level);
}

test "agent copies tool and message arrays on assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var agent = try Agent.init(std.testing.allocator, .{});
    defer agent.deinit();

    var tools = [_]types.AgentTool{
        makeTool("tool-a", "Tool A"),
        makeTool("tool-b", "Tool B"),
    };
    try agent.setTools(tools[0..]);
    tools[0] = makeTool("tool-c", "Tool C");

    var messages = [_]types.AgentMessage{
        try userTextMessage(arena.allocator(), "first", 1),
        try userTextMessage(arena.allocator(), "second", 2),
    };
    try agent.setMessages(messages[0..]);
    messages[0] = try userTextMessage(arena.allocator(), "changed", 3);

    try std.testing.expectEqual(@as(usize, 2), agent.getTools().len);
    try std.testing.expectEqualStrings("tool-a", agent.getTools()[0].name);
    try std.testing.expectEqual(@as(usize, 2), agent.getMessages().len);
    try std.testing.expectEqualStrings("first", agent.getMessages()[0].user.content[0].text.text);
}

test "agent reset clears transcript runtime state and queues without removing tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var agent = try Agent.init(std.testing.allocator, .{});
    defer agent.deinit();

    const tool = makeTool("tool-a", "Tool A");
    try agent.setTools(&[_]types.AgentTool{tool});
    try agent.setMessages(&[_]types.AgentMessage{try userTextMessage(arena.allocator(), "hello", 1)});
    agent.beginRun();
    agent.setStreamingMessage(try userTextMessage(arena.allocator(), "streaming", 2));
    try agent.addPendingToolCall("tool-call-1");
    agent.setErrorMessage("boom");
    try agent.steer(try userTextMessage(arena.allocator(), "steer", 3));
    try agent.followUp(try userTextMessage(arena.allocator(), "follow", 4));

    agent.reset();

    const state = agent.state();
    try std.testing.expectEqual(@as(usize, 1), state.tools.len);
    try std.testing.expectEqual(@as(usize, 0), state.messages.len);
    try std.testing.expect(!state.is_streaming);
    try std.testing.expect(state.streaming_message == null);
    try std.testing.expectEqual(@as(usize, 0), state.pending_tool_calls.len);
    try std.testing.expect(state.error_message == null);
    try std.testing.expectEqual(@as(usize, 0), agent.steeringQueueLen());
    try std.testing.expectEqual(@as(usize, 0), agent.followUpQueueLen());
    try std.testing.expect(!agent.hasQueuedMessages());
}

test "agent streaming lifecycle toggles flags and clears runtime state on finish" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var agent = try Agent.init(std.testing.allocator, .{
        .messages = &[_]types.AgentMessage{try userTextMessage(arena.allocator(), "hello", 1)},
    });
    defer agent.deinit();

    try std.testing.expect(!agent.isStreaming());
    agent.setErrorMessage("old error");
    agent.beginRun();
    try std.testing.expect(agent.isStreaming());
    try std.testing.expect(agent.getErrorMessage() == null);

    const streaming_message = try userTextMessage(arena.allocator(), "partial", 2);
    agent.setStreamingMessage(streaming_message);
    try agent.addPendingToolCall("tool-1");
    try agent.addPendingToolCall("tool-1");
    try std.testing.expectEqual(@as(usize, 1), agent.getPendingToolCalls().len);
    try std.testing.expect(agent.getStreamingMessage() != null);

    agent.finishRun();
    try std.testing.expect(!agent.isStreaming());
    try std.testing.expect(agent.getStreamingMessage() == null);
    try std.testing.expectEqual(@as(usize, 0), agent.getPendingToolCalls().len);
    try std.testing.expectEqual(@as(usize, 1), agent.getMessages().len);
}

test "pending message queue drains according to mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var queue_all = PendingMessageQueue.init(std.testing.allocator, .all);
    defer queue_all.deinit();
    try queue_all.enqueue(try userTextMessage(arena.allocator(), "one", 1));
    try queue_all.enqueue(try userTextMessage(arena.allocator(), "two", 2));

    const drained_all = try queue_all.drain(std.testing.allocator);
    defer std.testing.allocator.free(drained_all);
    try std.testing.expectEqual(@as(usize, 2), drained_all.len);
    try std.testing.expect(!queue_all.hasItems());

    var queue_one = PendingMessageQueue.init(std.testing.allocator, .one_at_a_time);
    defer queue_one.deinit();
    try queue_one.enqueue(try userTextMessage(arena.allocator(), "first", 1));
    try queue_one.enqueue(try userTextMessage(arena.allocator(), "second", 2));

    const first = try queue_one.drain(std.testing.allocator);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqualStrings("first", first[0].user.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), queue_one.len());
}

const PromptEventCapture = struct {
    agent: *Agent,
    allocator: std.mem.Allocator,
    event_types: std.ArrayList(types.AgentEventType),
    saw_assistant_message_start: bool = false,
    saw_assistant_message_update: bool = false,
    assistant_message_end_cleared_streaming: bool = false,

    fn init(agent: *Agent, allocator: std.mem.Allocator) PromptEventCapture {
        return .{
            .agent = agent,
            .allocator = allocator,
            .event_types = .empty,
        };
    }

    fn deinit(self: *PromptEventCapture) void {
        self.event_types.deinit(self.allocator);
    }
};

fn capturePromptEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *PromptEventCapture = @ptrCast(@alignCast(context.?));
    try capture.event_types.append(capture.allocator, event.event_type);

    switch (event.event_type) {
        .message_start => {
            if (event.message) |message| switch (message) {
                .assistant => {
                    capture.saw_assistant_message_start = true;
                    try std.testing.expect(capture.agent.getStreamingMessage() != null);
                    try std.testing.expect(capture.agent.isStreaming());
                },
                else => {},
            };
        },
        .message_update => {
            if (event.message) |message| switch (message) {
                .assistant => {
                    capture.saw_assistant_message_update = true;
                    try std.testing.expect(capture.agent.getStreamingMessage() != null);
                },
                else => {},
            };
        },
        .message_end => {
            if (event.message) |message| switch (message) {
                .assistant => {
                    capture.assistant_message_end_cleared_streaming = capture.agent.getStreamingMessage() == null;
                },
                else => {},
            };
        },
        else => {},
    }
}

test "agent prompt records transcript and clears streaming state for single-turn text responses" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 1, .max = 1 },
    });
    defer registration.unregister();

    const blocks = [_]faux.FauxContentBlock{faux.fauxText("hello there")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks[0..], .{}) },
    });

    var agent = try Agent.init(std.testing.allocator, .{
        .system_prompt = "You are helpful.",
        .model = registration.getModel(),
    });
    defer agent.deinit();

    var capture = PromptEventCapture.init(&agent, std.testing.allocator);
    defer capture.deinit();
    try agent.subscribe(.{
        .context = &capture,
        .callback = capturePromptEvent,
    });

    try agent.prompt("hello");

    try std.testing.expect(capture.saw_assistant_message_start);
    try std.testing.expect(capture.saw_assistant_message_update);
    try std.testing.expect(capture.assistant_message_end_cleared_streaming);

    try std.testing.expect(!agent.isStreaming());
    try std.testing.expect(agent.getStreamingMessage() == null);
    try std.testing.expectEqual(@as(usize, 2), agent.getMessages().len);
    try std.testing.expectEqualStrings("hello", agent.getMessages()[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("hello there", agent.getMessages()[1].assistant.content[0].text.text);

    const event_types = capture.event_types.items;
    try std.testing.expectEqual(types.AgentEventType.agent_start, event_types[0]);
    try std.testing.expectEqual(types.AgentEventType.turn_start, event_types[1]);
    try std.testing.expectEqual(types.AgentEventType.message_start, event_types[2]);
    try std.testing.expectEqual(types.AgentEventType.message_end, event_types[3]);
    try std.testing.expectEqual(types.AgentEventType.message_start, event_types[4]);
    try std.testing.expectEqual(types.AgentEventType.message_end, event_types[event_types.len - 3]);
    try std.testing.expectEqual(types.AgentEventType.turn_end, event_types[event_types.len - 2]);
    try std.testing.expectEqual(types.AgentEventType.agent_end, event_types[event_types.len - 1]);

    for (event_types[5 .. event_types.len - 3]) |event_type| {
        try std.testing.expectEqual(types.AgentEventType.message_update, event_type);
    }
}

test "agent prompt minimal" {
    _ = ai.providers.faux;
}
