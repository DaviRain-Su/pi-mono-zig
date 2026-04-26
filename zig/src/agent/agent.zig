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
    io: std.Io,
    mode: QueueMode,
    messages: std.ArrayList(types.AgentMessage),
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, mode: QueueMode) PendingMessageQueue {
        return .{
            .allocator = allocator,
            .io = io,
            .mode = mode,
            .messages = .empty,
        };
    }

    pub fn deinit(self: *PendingMessageQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        deinitMessageSlice(self.allocator, self.messages.items);
        self.messages.deinit(self.allocator);
    }

    pub fn enqueue(self: *PendingMessageQueue, message: types.AgentMessage) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var owned_message = try cloneMessage(self.allocator, message);
        errdefer deinitMessage(self.allocator, &owned_message);
        try self.messages.append(self.allocator, owned_message);
    }

    pub fn hasItems(self: *const PendingMessageQueue) bool {
        @constCast(&self.mutex).lockUncancelable(self.io);
        defer @constCast(&self.mutex).unlock(self.io);
        return self.messages.items.len > 0;
    }

    pub fn len(self: *const PendingMessageQueue) usize {
        @constCast(&self.mutex).lockUncancelable(self.io);
        defer @constCast(&self.mutex).unlock(self.io);
        return self.messages.items.len;
    }

    pub fn clear(self: *PendingMessageQueue) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        deinitMessageSlice(self.allocator, self.messages.items);
        self.messages.clearRetainingCapacity();
    }

    pub fn snapshot(self: *const PendingMessageQueue, allocator: std.mem.Allocator) ![]types.AgentMessage {
        @constCast(&self.mutex).lockUncancelable(self.io);
        defer @constCast(&self.mutex).unlock(self.io);

        if (self.messages.items.len == 0) {
            return try allocator.alloc(types.AgentMessage, 0);
        }

        return try cloneMessageSlice(allocator, self.messages.items);
    }

    pub fn takeAll(self: *PendingMessageQueue, allocator: std.mem.Allocator) ![]types.AgentMessage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.messages.items.len == 0) {
            return try allocator.alloc(types.AgentMessage, 0);
        }

        const drained = try cloneMessageSlice(allocator, self.messages.items);
        deinitMessageSlice(self.allocator, self.messages.items);
        self.messages.clearRetainingCapacity();
        return drained;
    }

    pub fn drain(self: *PendingMessageQueue, allocator: std.mem.Allocator) ![]types.AgentMessage {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.messages.items.len == 0) {
            return try allocator.alloc(types.AgentMessage, 0);
        }

        if (self.mode == .all) {
            const drained = try cloneMessageSlice(allocator, self.messages.items);
            deinitMessageSlice(self.allocator, self.messages.items);
            self.messages.clearRetainingCapacity();
            return drained;
        }

        const first = try cloneMessageSlice(allocator, self.messages.items[0..1]);
        var removed = self.messages.orderedRemove(0);
        deinitMessage(self.allocator, &removed);
        return first;
    }
};

pub const AgentOptions = struct {
    system_prompt: []const u8 = "",
    model: ?ai.Model = null,
    api_key: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
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
    before_tool_call: ?types.BeforeToolCallFn = null,
    after_tool_call: ?types.AfterToolCallFn = null,
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
    api_key: ?[]const u8,
    session_id: ?[]const u8,
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
    before_tool_call: ?types.BeforeToolCallFn,
    after_tool_call: ?types.AfterToolCallFn,
    listeners: std.ArrayList(types.AgentSubscriber),
    active_abort_signal: ?*std.atomic.Value(bool),
    run_state_mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, options: AgentOptions) !Agent {
        var agent = Agent{
            .allocator = allocator,
            .system_prompt = options.system_prompt,
            .model = options.model orelse DEFAULT_MODEL,
            .api_key = options.api_key,
            .session_id = options.session_id,
            .thinking_level = options.thinking_level,
            .tools = .empty,
            .messages = .empty,
            .is_streaming = false,
            .streaming_message = null,
            .pending_tool_calls = .empty,
            .error_message = null,
            .steering_queue = PendingMessageQueue.init(allocator, options.io, options.steering_mode),
            .follow_up_queue = PendingMessageQueue.init(allocator, options.io, options.follow_up_mode),
            .tool_execution = options.tool_execution,
            .io = options.io,
            .stream_fn = options.stream_fn,
            .convert_to_llm = options.convert_to_llm orelse defaultConvertToLlm,
            .transform_context = options.transform_context,
            .before_tool_call = options.before_tool_call,
            .after_tool_call = options.after_tool_call,
            .listeners = .empty,
            .active_abort_signal = null,
        };
        errdefer agent.deinit();

        try agent.setTools(options.tools);
        try agent.setMessages(options.messages);
        return agent;
    }

    pub fn deinit(self: *Agent) void {
        self.clearOwnedMessages();
        self.tools.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        self.pending_tool_calls.deinit(self.allocator);
        self.steering_queue.deinit();
        self.follow_up_queue.deinit();
        self.listeners.deinit(self.allocator);
        if (self.error_message) |error_message| self.allocator.free(error_message);
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

    pub fn getApiKey(self: *const Agent) ?[]const u8 {
        return self.api_key;
    }

    pub fn setApiKey(self: *Agent, api_key: ?[]const u8) void {
        self.api_key = api_key;
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
        self.clearOwnedMessages();
        for (next_messages) |message| {
            try self.messages.append(self.allocator, try cloneMessage(self.allocator, message));
        }
    }

    pub fn appendMessage(self: *Agent, message: types.AgentMessage) !void {
        try self.messages.append(self.allocator, try cloneMessage(self.allocator, message));
    }

    pub fn removeLastMessage(self: *Agent) bool {
        if (self.messages.items.len == 0) return false;
        var removed = self.messages.pop().?;
        deinitMessage(self.allocator, &removed);
        return true;
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
        self.setErrorMessage(null);
    }

    pub fn finishRun(self: *Agent) void {
        self.is_streaming = false;
        self.streaming_message = null;
        self.clearPendingToolCalls();
        self.run_state_mutex.lockUncancelable(self.io);
        defer self.run_state_mutex.unlock(self.io);
        self.active_abort_signal = null;
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
        if (self.error_message) |previous| self.allocator.free(previous);
        self.error_message = if (error_message) |message|
            self.allocator.dupe(u8, message) catch @panic("out of memory while storing agent error message")
        else
            null;
    }

    pub fn steer(self: *Agent, message: types.AgentMessage) !void {
        try self.steering_queue.enqueue(message);
    }

    pub fn followUp(self: *Agent, message: types.AgentMessage) !void {
        try self.follow_up_queue.enqueue(message);
    }

    pub fn abort(self: *Agent) void {
        self.run_state_mutex.lockUncancelable(self.io);
        defer self.run_state_mutex.unlock(self.io);

        if (self.active_abort_signal) |signal| {
            signal.store(true, .seq_cst);
        }
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

    pub fn snapshotSteeringMessages(self: *const Agent, allocator: std.mem.Allocator) ![]types.AgentMessage {
        return try self.steering_queue.snapshot(allocator);
    }

    pub fn snapshotFollowUpMessages(self: *const Agent, allocator: std.mem.Allocator) ![]types.AgentMessage {
        return try self.follow_up_queue.snapshot(allocator);
    }

    pub fn takeSteeringMessages(self: *Agent, allocator: std.mem.Allocator) ![]types.AgentMessage {
        return try self.steering_queue.takeAll(allocator);
    }

    pub fn takeFollowUpMessages(self: *Agent, allocator: std.mem.Allocator) ![]types.AgentMessage {
        return try self.follow_up_queue.takeAll(allocator);
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
        self.clearOwnedMessages();
        self.is_streaming = false;
        self.streaming_message = null;
        self.clearPendingToolCalls();
        self.setErrorMessage(null);
        self.clearAllQueues();
    }

    pub fn subscribe(self: *Agent, subscriber: types.AgentSubscriber) !void {
        try self.listeners.append(self.allocator, subscriber);
    }

    pub fn unsubscribe(self: *Agent, subscriber: types.AgentSubscriber) bool {
        for (self.listeners.items, 0..) |listener, index| {
            if (listener.context == subscriber.context and listener.callback == subscriber.callback) {
                _ = self.listeners.orderedRemove(index);
                return true;
            }
        }
        return false;
    }

    pub fn prompt(self: *Agent, input: anytype) !void {
        const Input = @TypeOf(input);
        if (comptime isStringLike(Input)) {
            return self.promptTextWithImages(input, &.{});
        }

        if (Input == types.AgentMessage) {
            return self.promptSingleMessage(input);
        }

        if (comptime isAgentMessageSlice(Input)) {
            return self.runPromptMessages(input);
        }

        if (comptime isTextWithImagesPrompt(Input)) {
            return self.promptTextWithImages(input.text, input.images);
        }

        @compileError("Agent.prompt supports string input, AgentMessage, []const AgentMessage, or a struct with .text and .images fields.");
    }

    pub fn continueRun(self: *Agent) !void {
        const prompts = [_]types.AgentMessage{};
        try self.runPromptMessages(prompts[0..]);
    }

    fn promptSingleMessage(self: *Agent, message: types.AgentMessage) !void {
        const prompts = [_]types.AgentMessage{message};
        try self.runPromptMessages(prompts[0..]);
    }

    fn promptTextWithImages(
        self: *Agent,
        text: []const u8,
        images: []const ai.ImageContent,
    ) !void {
        const prompt_message = try userMessageWithImages(std.heap.page_allocator, text, images, 0);
        const prompts = [_]types.AgentMessage{prompt_message};
        try self.runPromptMessages(prompts[0..]);
    }

    fn runPromptMessages(self: *Agent, prompts: []const types.AgentMessage) !void {
        if (self.is_streaming) return error.AgentAlreadyProcessing;
        const context = self.createContextSnapshot();
        const config = self.createLoopConfig();
        var abort_signal = std.atomic.Value(bool).init(false);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        self.beginRun();
        self.run_state_mutex.lockUncancelable(self.io);
        self.active_abort_signal = &abort_signal;
        self.run_state_mutex.unlock(self.io);
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
            .api_key = self.api_key,
            .session_id = self.session_id,
            .reasoning = if (self.thinking_level == .off) null else self.thinking_level,
            .tool_execution = self.tool_execution,
            .before_tool_call = self.before_tool_call,
            .after_tool_call = self.after_tool_call,
            .convert_to_llm = self.convert_to_llm,
            .transform_context = self.transform_context,
            .get_steering_messages_context = @constCast(self),
            .get_steering_messages = drainSteeringMessages,
            .get_follow_up_messages_context = @constCast(self),
            .get_follow_up_messages = drainFollowUpMessages,
        };
    }

    fn clearOwnedMessages(self: *Agent) void {
        for (self.messages.items) |*message| deinitMessage(self.allocator, message);
        self.messages.clearRetainingCapacity();
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
            .tool_execution_start => {
                if (event.tool_call_id) |tool_call_id| {
                    try self.addPendingToolCall(tool_call_id);
                }
            },
            .tool_execution_end => {
                if (event.tool_call_id) |tool_call_id| {
                    _ = self.removePendingToolCall(tool_call_id);
                }
            },
            .turn_end => {
                if (event.message) |message| {
                    switch (message) {
                        .assistant => |assistant| {
                            if (assistant.error_message) |error_message| {
                                self.setErrorMessage(error_message);
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

pub fn cloneMessage(allocator: std.mem.Allocator, message: types.AgentMessage) !types.AgentMessage {
    return switch (message) {
        .user => |user| .{ .user = .{
            .role = try allocator.dupe(u8, user.role),
            .content = try cloneContentBlocks(allocator, user.content),
            .timestamp = user.timestamp,
        } },
        .assistant => |assistant| .{ .assistant = .{
            .role = try allocator.dupe(u8, assistant.role),
            .content = try cloneContentBlocks(allocator, assistant.content),
            .tool_calls = if (assistant.tool_calls) |tool_calls| try cloneToolCalls(allocator, tool_calls) else null,
            .api = try allocator.dupe(u8, assistant.api),
            .provider = try allocator.dupe(u8, assistant.provider),
            .model = try allocator.dupe(u8, assistant.model),
            .response_id = if (assistant.response_id) |response_id| try allocator.dupe(u8, response_id) else null,
            .usage = assistant.usage,
            .stop_reason = assistant.stop_reason,
            .error_message = if (assistant.error_message) |error_message| try allocator.dupe(u8, error_message) else null,
            .timestamp = assistant.timestamp,
        } },
        .tool_result => |tool_result| .{ .tool_result = .{
            .role = try allocator.dupe(u8, tool_result.role),
            .tool_call_id = try allocator.dupe(u8, tool_result.tool_call_id),
            .tool_name = try allocator.dupe(u8, tool_result.tool_name),
            .content = try cloneContentBlocks(allocator, tool_result.content),
            .is_error = tool_result.is_error,
            .timestamp = tool_result.timestamp,
        } },
    };
}

pub fn deinitMessage(allocator: std.mem.Allocator, message: *types.AgentMessage) void {
    switch (message.*) {
        .user => |*user| {
            allocator.free(user.role);
            deinitContentBlocks(allocator, user.content);
        },
        .assistant => |*assistant| {
            allocator.free(assistant.role);
            deinitContentBlocks(allocator, assistant.content);
            if (assistant.tool_calls) |tool_calls| deinitToolCalls(allocator, tool_calls);
            allocator.free(assistant.api);
            allocator.free(assistant.provider);
            allocator.free(assistant.model);
            if (assistant.response_id) |response_id| allocator.free(response_id);
            if (assistant.error_message) |error_message| allocator.free(error_message);
        },
        .tool_result => |*tool_result| {
            allocator.free(tool_result.role);
            allocator.free(tool_result.tool_call_id);
            allocator.free(tool_result.tool_name);
            deinitContentBlocks(allocator, tool_result.content);
        },
    }
}

pub fn cloneMessageSlice(allocator: std.mem.Allocator, messages: []const types.AgentMessage) ![]types.AgentMessage {
    const cloned = try allocator.alloc(types.AgentMessage, messages.len);
    errdefer allocator.free(cloned);

    var index: usize = 0;
    errdefer {
        for (cloned[0..index]) |*message| deinitMessage(allocator, message);
    }

    for (messages, 0..) |message, message_index| {
        cloned[message_index] = try cloneMessage(allocator, message);
        index += 1;
    }

    return cloned;
}

pub fn deinitMessageSlice(allocator: std.mem.Allocator, messages: []types.AgentMessage) void {
    for (messages) |*message| deinitMessage(allocator, message);
}

fn cloneContentBlocks(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]const ai.ContentBlock {
    const cloned = try allocator.alloc(ai.ContentBlock, blocks.len);
    errdefer allocator.free(cloned);

    for (blocks, 0..) |block, index| {
        cloned[index] = try cloneContentBlock(allocator, block);
    }

    return cloned;
}

fn cloneContentBlock(allocator: std.mem.Allocator, block: ai.ContentBlock) !ai.ContentBlock {
    return switch (block) {
        .text => |text| ai.ContentBlock{ .text = .{ .text = try allocator.dupe(u8, text.text) } },
        .image => |image| ai.ContentBlock{ .image = .{
            .data = try allocator.dupe(u8, image.data),
            .mime_type = try allocator.dupe(u8, image.mime_type),
        } },
        .thinking => |thinking| ai.ContentBlock{ .thinking = .{
            .thinking = try allocator.dupe(u8, thinking.thinking),
            .signature = if (thinking.signature) |signature| try allocator.dupe(u8, signature) else null,
            .redacted = thinking.redacted,
        } },
    };
}

fn deinitContentBlocks(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) void {
    for (blocks) |block| {
        switch (block) {
            .text => |text| allocator.free(text.text),
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
            .thinking => |thinking| {
                allocator.free(thinking.thinking);
                if (thinking.signature) |signature| allocator.free(signature);
            },
        }
    }
    allocator.free(blocks);
}

fn cloneToolCalls(allocator: std.mem.Allocator, tool_calls: []const ai.ToolCall) ![]const ai.ToolCall {
    const cloned = try allocator.alloc(ai.ToolCall, tool_calls.len);
    errdefer allocator.free(cloned);

    for (tool_calls, 0..) |tool_call, index| {
        cloned[index] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try cloneJsonValue(allocator, tool_call.arguments),
        };
    }

    return cloned;
}

fn deinitToolCalls(allocator: std.mem.Allocator, tool_calls: []const ai.ToolCall) void {
    for (tool_calls) |tool_call| {
        allocator.free(tool_call.id);
        allocator.free(tool_call.name);
        deinitJsonValue(allocator, tool_call.arguments);
    }
    allocator.free(tool_calls);
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |v| .{ .bool = v },
        .integer => |v| .{ .integer = v },
        .float => |v| .{ .float = v },
        .number_string => |v| .{ .number_string = try allocator.dupe(u8, v) },
        .string => |v| .{ .string = try allocator.dupe(u8, v) },
        .array => |array| blk: {
            var cloned_array = std.json.Array.init(allocator);
            errdefer {
                for (cloned_array.items) |item| deinitJsonValue(allocator, item);
                cloned_array.deinit();
            }
            for (array.items) |item| {
                try cloned_array.append(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = cloned_array };
        },
        .object => |object| blk: {
            var cloned_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            errdefer {
                var iterator = cloned_object.iterator();
                while (iterator.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    deinitJsonValue(allocator, entry.value_ptr.*);
                }
                cloned_object.deinit(allocator);
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try cloned_object.put(
                    allocator,
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try cloneJsonValue(allocator, entry.value_ptr.*),
                );
            }
            break :blk .{ .object = cloned_object };
        },
    };
}

fn deinitJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .null, .bool, .integer, .float => {},
        .number_string => |v| allocator.free(v),
        .string => |v| allocator.free(v),
        .array => |array| {
            for (array.items) |item| deinitJsonValue(allocator, item);
            var array_mut = array;
            array_mut.deinit();
        },
        .object => |object| {
            var map = object;
            var iterator = map.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr.*);
            }
            map.deinit(allocator);
        },
    }
}

fn defaultConvertToLlm(
    allocator: std.mem.Allocator,
    messages: []const types.AgentMessage,
) ![]ai.Message {
    return try allocator.dupe(ai.Message, messages);
}

fn drainSteeringMessages(
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
) ![]types.AgentMessage {
    const self: *Agent = @ptrCast(@alignCast(context.?));
    return try self.steering_queue.drain(allocator);
}

fn drainFollowUpMessages(
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
) ![]types.AgentMessage {
    const self: *Agent = @ptrCast(@alignCast(context.?));
    return try self.follow_up_queue.drain(allocator);
}

fn userMessageWithImages(
    allocator: std.mem.Allocator,
    text: []const u8,
    images: []const ai.ImageContent,
    timestamp: i64,
) !types.AgentMessage {
    const content = try allocator.alloc(ai.ContentBlock, 1 + images.len);
    content[0] = .{ .text = .{ .text = text } };
    for (images, 0..) |image, index| {
        content[index + 1] = .{ .image = image };
    }
    return .{ .user = .{
        .content = content,
        .timestamp = timestamp,
    } };
}

fn userTextMessage(
    allocator: std.mem.Allocator,
    text: []const u8,
    timestamp: i64,
) !types.AgentMessage {
    return try userMessageWithImages(allocator, text, &.{}, timestamp);
}

fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == u8,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            else => false,
        },
        .array => |array| array.child == u8,
        else => false,
    };
}

fn isAgentMessageSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == types.AgentMessage,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == types.AgentMessage,
                else => false,
            },
            else => false,
        },
        .array => |array| array.child == types.AgentMessage,
        else => false,
    };
}

fn isTextWithImagesPrompt(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasField(T, "text") and @hasField(T, "images"),
        else => false,
    };
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

    var queue_all = PendingMessageQueue.init(std.testing.allocator, std.Io.failing, .all);
    defer queue_all.deinit();
    try queue_all.enqueue(try userTextMessage(arena.allocator(), "one", 1));
    try queue_all.enqueue(try userTextMessage(arena.allocator(), "two", 2));

    const drained_all = try queue_all.drain(std.testing.allocator);
    defer {
        deinitMessageSlice(std.testing.allocator, drained_all);
        std.testing.allocator.free(drained_all);
    }
    try std.testing.expectEqual(@as(usize, 2), drained_all.len);
    try std.testing.expect(!queue_all.hasItems());

    var queue_one = PendingMessageQueue.init(std.testing.allocator, std.Io.failing, .one_at_a_time);
    defer queue_one.deinit();
    try queue_one.enqueue(try userTextMessage(arena.allocator(), "first", 1));
    try queue_one.enqueue(try userTextMessage(arena.allocator(), "second", 2));

    const first = try queue_one.drain(std.testing.allocator);
    defer {
        deinitMessageSlice(std.testing.allocator, first);
        std.testing.allocator.free(first);
    }
    try std.testing.expectEqual(@as(usize, 1), first.len);
    try std.testing.expectEqualStrings("first", first[0].user.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), queue_one.len());
}

fn complexAssistantMessage(
    allocator: std.mem.Allocator,
    label: []const u8,
    timestamp: i64,
) !types.AgentMessage {
    const text = try std.fmt.allocPrint(allocator, "{s} text", .{label});
    const thinking = try std.fmt.allocPrint(allocator, "{s} thinking", .{label});
    const signature = try std.fmt.allocPrint(allocator, "sig-{s}", .{label});
    const response_id = try std.fmt.allocPrint(allocator, "resp-{s}", .{label});
    const error_message = try std.fmt.allocPrint(allocator, "error-{s}", .{label});
    const tool_call_id = try std.fmt.allocPrint(allocator, "tool-{s}", .{label});

    const content = try allocator.alloc(ai.ContentBlock, 2);
    content[0] = .{ .text = .{ .text = text } };
    content[1] = .{ .thinking = .{
        .thinking = thinking,
        .signature = signature,
    } };

    var items = std.json.Array.init(allocator);
    try items.append(.{ .integer = 1 });
    try items.append(.{ .string = try allocator.dupe(u8, "nested") });

    var arguments = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try arguments.put(allocator, try allocator.dupe(u8, "label"), .{ .string = try allocator.dupe(u8, label) });
    try arguments.put(allocator, try allocator.dupe(u8, "items"), .{ .array = items });

    const tool_calls = try allocator.alloc(ai.ToolCall, 1);
    tool_calls[0] = .{
        .id = tool_call_id,
        .name = try allocator.dupe(u8, "echo"),
        .arguments = .{ .object = arguments },
    };

    return .{ .assistant = .{
        .content = content,
        .tool_calls = tool_calls,
        .api = try allocator.dupe(u8, "faux"),
        .provider = try allocator.dupe(u8, "faux"),
        .model = try allocator.dupe(u8, "faux-model"),
        .response_id = response_id,
        .usage = .{
            .input = 1,
            .output = 2,
            .total_tokens = 3,
        },
        .stop_reason = .tool_use,
        .error_message = error_message,
        .timestamp = timestamp,
    } };
}

test "pending message queue drains queue-owned copies after source allocations are released" {
    var queue = PendingMessageQueue.init(std.testing.allocator, std.Io.failing, .all);
    defer queue.deinit();

    {
        var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer source_arena.deinit();

        try queue.enqueue(try complexAssistantMessage(source_arena.allocator(), "copied", 7));
    }

    const drained = try queue.drain(std.testing.allocator);
    defer {
        deinitMessageSlice(std.testing.allocator, drained);
        std.testing.allocator.free(drained);
    }

    try std.testing.expectEqual(@as(usize, 1), drained.len);
    const assistant = drained[0].assistant;
    try std.testing.expectEqualStrings("copied text", assistant.content[0].text.text);
    try std.testing.expectEqualStrings("copied thinking", assistant.content[1].thinking.thinking);
    try std.testing.expectEqualStrings("sig-copied", assistant.content[1].thinking.signature.?);
    try std.testing.expectEqualStrings("tool-copied", assistant.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("copied", assistant.tool_calls.?[0].arguments.object.get("label").?.string);
    try std.testing.expectEqualStrings("nested", assistant.tool_calls.?[0].arguments.object.get("items").?.array.items[1].string);
    try std.testing.expect(!queue.hasItems());
}

test "pending message queue clear and deinit release nested queue-owned allocations" {
    {
        var clear_queue = PendingMessageQueue.init(std.testing.allocator, std.Io.failing, .all);
        defer clear_queue.deinit();

        {
            var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer source_arena.deinit();

            try clear_queue.enqueue(try complexAssistantMessage(source_arena.allocator(), "clear", 9));
        }

        clear_queue.clear();
        try std.testing.expectEqual(@as(usize, 0), clear_queue.len());
    }

    {
        var deinit_queue = PendingMessageQueue.init(std.testing.allocator, std.Io.failing, .all);
        defer deinit_queue.deinit();

        {
            var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer source_arena.deinit();

            try deinit_queue.enqueue(try complexAssistantMessage(source_arena.allocator(), "deinit", 10));
        }
    }
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

fn expectUserText(message: types.AgentMessage, expected: []const u8) !void {
    switch (message) {
        .user => |user| {
            try std.testing.expectEqual(@as(usize, 1), user.content.len);
            try std.testing.expectEqualStrings(expected, user.content[0].text.text);
        },
        else => return error.UnexpectedMessageRole,
    }
}

fn multiTurnFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    call_count: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    const faux = ai.providers.faux;

    switch (call_count.*) {
        1 => {
            try std.testing.expectEqual(@as(usize, 1), context.messages.len);
            try expectUserText(context.messages[0], "hello");
            const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
            blocks[0] = faux.fauxText("First response");
            return faux.fauxAssistantMessage(blocks, .{});
        },
        2 => {
            try std.testing.expectEqual(@as(usize, 3), context.messages.len);
            try expectUserText(context.messages[0], "hello");
            try std.testing.expectEqualStrings("First response", context.messages[1].assistant.content[0].text.text);
            try expectUserText(context.messages[2], "what did I say?");
            const prior_text = context.messages[0].user.content[0].text.text;
            const answer = try std.fmt.allocPrint(allocator, "You said: {s}", .{prior_text});
            const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
            blocks[0] = faux.fauxText(answer);
            return faux.fauxAssistantMessage(blocks, .{});
        },
        else => unreachable,
    }
}

test "agent prompt preserves prior transcript across multiple turns" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = multiTurnFactory },
        .{ .factory = multiTurnFactory },
    });

    var agent = try Agent.init(std.testing.allocator, .{
        .system_prompt = "You are helpful.",
        .model = registration.getModel(),
    });
    defer agent.deinit();

    try agent.prompt("hello");
    try agent.prompt("what did I say?");

    const messages = agent.getMessages();
    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try expectUserText(messages[0], "hello");
    try std.testing.expectEqualStrings("First response", messages[1].assistant.content[0].text.text);
    try expectUserText(messages[2], "what did I say?");
    try std.testing.expectEqualStrings("You said: hello", messages[3].assistant.content[0].text.text);
}

fn promptWithImagesFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    call_count: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    const faux = ai.providers.faux;
    try std.testing.expectEqual(@as(usize, 1), call_count.*);
    try std.testing.expectEqual(@as(usize, 1), context.messages.len);

    const user = context.messages[0].user;
    try std.testing.expectEqual(@as(usize, 3), user.content.len);
    try std.testing.expectEqualStrings("describe this", user.content[0].text.text);
    try std.testing.expectEqualStrings("aGVsbG8=", user.content[1].image.data);
    try std.testing.expectEqualStrings("image/png", user.content[1].image.mime_type);
    try std.testing.expectEqualStrings("d29ybGQ=", user.content[2].image.data);
    try std.testing.expectEqualStrings("image/jpeg", user.content[2].image.mime_type);

    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = faux.fauxText("saw images");
    return faux.fauxAssistantMessage(blocks, .{});
}

test "agent prompt supports text with images" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = promptWithImagesFactory },
    });

    var agent = try Agent.init(std.testing.allocator, .{
        .model = registration.getModel(),
    });
    defer agent.deinit();

    const images = [_]ai.ImageContent{
        .{ .data = "aGVsbG8=", .mime_type = "image/png" },
        .{ .data = "d29ybGQ=", .mime_type = "image/jpeg" },
    };

    try agent.prompt(.{
        .text = "describe this",
        .images = images[0..],
    });

    const messages = agent.getMessages();
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(@as(usize, 3), messages[0].user.content.len);
    try std.testing.expectEqualStrings("describe this", messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("aGVsbG8=", messages[0].user.content[1].image.data);
    try std.testing.expectEqualStrings("d29ybGQ=", messages[0].user.content[2].image.data);
    try std.testing.expectEqualStrings("saw images", messages[1].assistant.content[0].text.text);
}

fn promptMessageArrayFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    call_count: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    const faux = ai.providers.faux;
    try std.testing.expectEqual(@as(usize, 1), call_count.*);
    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try expectUserText(context.messages[0], "first");
    try expectUserText(context.messages[1], "second");

    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = faux.fauxText("combined");
    return faux.fauxAssistantMessage(blocks, .{});
}

test "agent prompt supports AgentMessage arrays and emits prompt events for each message" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = promptMessageArrayFactory },
    });

    var agent = try Agent.init(std.testing.allocator, .{
        .model = registration.getModel(),
    });
    defer agent.deinit();

    var capture = PromptEventCapture.init(&agent, std.testing.allocator);
    defer capture.deinit();
    try agent.subscribe(.{
        .context = &capture,
        .callback = capturePromptEvent,
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prompts = [_]types.AgentMessage{
        try userTextMessage(arena.allocator(), "first", 1),
        try userTextMessage(arena.allocator(), "second", 2),
    };

    try agent.prompt(prompts[0..]);

    const messages = agent.getMessages();
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try expectUserText(messages[0], "first");
    try expectUserText(messages[1], "second");
    try std.testing.expectEqualStrings("combined", messages[2].assistant.content[0].text.text);

    const event_types = capture.event_types.items;
    try std.testing.expectEqual(types.AgentEventType.agent_start, event_types[0]);
    try std.testing.expectEqual(types.AgentEventType.turn_start, event_types[1]);
    try std.testing.expectEqual(types.AgentEventType.message_start, event_types[2]);
    try std.testing.expectEqual(types.AgentEventType.message_end, event_types[3]);
    try std.testing.expectEqual(types.AgentEventType.message_start, event_types[4]);
    try std.testing.expectEqual(types.AgentEventType.message_end, event_types[5]);
    try std.testing.expectEqual(types.AgentEventType.message_start, event_types[6]);
    try std.testing.expectEqual(types.AgentEventType.message_end, event_types[event_types.len - 3]);
    try std.testing.expectEqual(types.AgentEventType.turn_end, event_types[event_types.len - 2]);
    try std.testing.expectEqual(types.AgentEventType.agent_end, event_types[event_types.len - 1]);
}

const SubscriberCapture = struct {
    allocator: std.mem.Allocator,
    event_types: std.ArrayList(types.AgentEventType),

    fn init(allocator: std.mem.Allocator) SubscriberCapture {
        return .{
            .allocator = allocator,
            .event_types = .empty,
        };
    }

    fn deinit(self: *SubscriberCapture) void {
        self.event_types.deinit(self.allocator);
    }
};

fn captureSubscriberEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *SubscriberCapture = @ptrCast(@alignCast(context.?));
    try capture.event_types.append(capture.allocator, event.event_type);
}

test "agent subscribers receive identical event sequences and can be removed dynamically" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    const first_blocks = [_]faux.FauxContentBlock{faux.fauxText("first reply")};
    const second_blocks = [_]faux.FauxContentBlock{faux.fauxText("second reply")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(first_blocks[0..], .{}) },
        .{ .message = faux.fauxAssistantMessage(second_blocks[0..], .{}) },
    });

    var agent = try Agent.init(std.testing.allocator, .{
        .model = registration.getModel(),
    });
    defer agent.deinit();

    var first_capture = SubscriberCapture.init(std.testing.allocator);
    defer first_capture.deinit();
    var second_capture = SubscriberCapture.init(std.testing.allocator);
    defer second_capture.deinit();

    const first_subscriber = types.AgentSubscriber{
        .context = &first_capture,
        .callback = captureSubscriberEvent,
    };
    const second_subscriber = types.AgentSubscriber{
        .context = &second_capture,
        .callback = captureSubscriberEvent,
    };

    try agent.subscribe(first_subscriber);
    try agent.subscribe(second_subscriber);

    try agent.prompt("hello");

    try std.testing.expect(first_capture.event_types.items.len > 0);
    try std.testing.expectEqual(first_capture.event_types.items.len, second_capture.event_types.items.len);
    for (first_capture.event_types.items, second_capture.event_types.items) |lhs, rhs| {
        try std.testing.expectEqual(lhs, rhs);
    }

    const second_count_after_first_prompt = second_capture.event_types.items.len;
    try std.testing.expect(agent.unsubscribe(second_subscriber));
    try std.testing.expect(!agent.unsubscribe(second_subscriber));

    try agent.prompt("again");

    try std.testing.expect(first_capture.event_types.items.len > second_count_after_first_prompt);
    try std.testing.expectEqual(second_count_after_first_prompt, second_capture.event_types.items.len);
}

const HookObservation = struct {
    transform_calls: usize = 0,
    convert_calls: usize = 0,
};

var active_hook_observation: ?*HookObservation = null;

fn transformContextForTest(
    allocator: std.mem.Allocator,
    messages: []const types.AgentMessage,
    _: ?*const std.atomic.Value(bool),
) ![]types.AgentMessage {
    const observation = active_hook_observation orelse return error.MissingHookObservation;
    observation.transform_calls += 1;

    const transformed = try allocator.alloc(types.AgentMessage, messages.len + 1);
    @memcpy(transformed[0..messages.len], messages);
    transformed[messages.len] = try userTextMessage(allocator, "hooked context", 42);
    return transformed;
}

fn prefixedUserMessage(
    allocator: std.mem.Allocator,
    text: []const u8,
    timestamp: i64,
) !ai.Message {
    const prefixed_text = try std.fmt.allocPrint(allocator, "converted: {s}", .{text});
    return .{ .user = .{
        .content = try allocator.dupe(ai.ContentBlock, &[_]ai.ContentBlock{
            .{ .text = .{ .text = prefixed_text } },
        }),
        .timestamp = timestamp,
    } };
}

fn convertToLlmForTest(
    allocator: std.mem.Allocator,
    messages: []const types.AgentMessage,
) ![]ai.Message {
    const observation = active_hook_observation orelse return error.MissingHookObservation;
    observation.convert_calls += 1;

    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try expectUserText(messages[0], "hello");
    try expectUserText(messages[1], "hooked context");

    const converted = try allocator.alloc(ai.Message, messages.len);
    for (messages, 0..) |message, index| {
        converted[index] = switch (message) {
            .user => |user| try prefixedUserMessage(allocator, user.content[0].text.text, user.timestamp),
            else => message,
        };
    }
    return converted;
}

fn transformedContextFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    call_count: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    const faux = ai.providers.faux;
    try std.testing.expectEqual(@as(usize, 1), call_count.*);
    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try expectUserText(context.messages[0], "converted: hello");
    try expectUserText(context.messages[1], "converted: hooked context");

    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = faux.fauxText("hooks applied");
    return faux.fauxAssistantMessage(blocks, .{});
}

test "agent applies transformContext before convertToLlm for streaming context only" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = transformedContextFactory },
    });

    var observation = HookObservation{};
    active_hook_observation = &observation;
    defer active_hook_observation = null;

    var agent = try Agent.init(std.testing.allocator, .{
        .model = registration.getModel(),
        .transform_context = transformContextForTest,
        .convert_to_llm = convertToLlmForTest,
    });
    defer agent.deinit();

    try agent.prompt("hello");

    try std.testing.expectEqual(@as(usize, 1), observation.transform_calls);
    try std.testing.expectEqual(@as(usize, 1), observation.convert_calls);
    try std.testing.expectEqual(@as(usize, 2), agent.getMessages().len);
    try expectUserText(agent.getMessages()[0], "hello");
    try std.testing.expectEqualStrings("hooks applied", agent.getMessages()[1].assistant.content[0].text.text);
}

const AbortEventCapture = struct {
    assistant_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    tool_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    saw_tool_error: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    saw_agent_end: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn captureAbortEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *AbortEventCapture = @ptrCast(@alignCast(context.?));
    switch (event.event_type) {
        .message_update => {
            if (event.message) |message| switch (message) {
                .assistant => capture.assistant_started.store(true, .seq_cst),
                else => {},
            };
        },
        .tool_execution_start => {
            capture.tool_started.store(true, .seq_cst);
        },
        .tool_execution_end => {
            if (event.is_error) |is_error| {
                if (is_error) capture.saw_tool_error.store(true, .seq_cst);
            }
        },
        .agent_end => {
            capture.saw_agent_end.store(true, .seq_cst);
        },
        else => {},
    }
}

const PromptThreadRunner = struct {
    agent: *Agent,
    input: []const u8,
    err: ?anyerror = null,
};

fn runPromptThread(runner: *PromptThreadRunner) void {
    runner.agent.prompt(runner.input) catch |err| {
        runner.err = err;
    };
}

const RunPromptHandle = struct {
    runner: PromptThreadRunner,
    thread: std.Thread,
    joined: bool = false,

    fn start(agent: *Agent, input: []const u8) !RunPromptHandle {
        var handle = RunPromptHandle{
            .runner = .{
                .agent = agent,
                .input = input,
            },
            .thread = undefined,
        };
        handle.thread = try std.Thread.spawn(.{}, runPromptThread, .{&handle.runner});
        return handle;
    }

    fn join(self: *RunPromptHandle) !void {
        if (self.joined) return;
        self.thread.join();
        self.joined = true;
        if (self.runner.err) |err| return err;
    }
};

fn waitForAtomicTrue(flag: *const std.atomic.Value(bool)) !void {
    var iteration: usize = 0;
    while (iteration < 50_000 and !flag.load(.seq_cst)) : (iteration += 1) {
        std.Thread.yield() catch {};
    }
    if (!flag.load(.seq_cst)) return error.TestTimeout;
}

var abortable_tool_started: ?*std.atomic.Value(bool) = null;
var mid_stream_started: ?*std.atomic.Value(bool) = null;

fn abortableToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    _: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    _ = allocator;

    const started = abortable_tool_started orelse return error.MissingAbortableToolObserver;
    started.store(true, .seq_cst);

    var iteration: usize = 0;
    while (iteration < 5_000) : (iteration += 1) {
        if (signal) |abort_signal| {
            if (abort_signal.load(.seq_cst)) {
                return error.ToolAborted;
            }
        }
        std.Thread.yield() catch {};
    }

    return error.ToolDidNotAbort;
}

fn buildAbortToolCallMessage(allocator: std.mem.Allocator) !ai.providers.faux.FauxAssistantMessage {
    const faux = ai.providers.faux;
    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = try faux.fauxToolCall(allocator, "wait", .null, .{ .id = "tool-1" });
    return faux.fauxAssistantMessage(blocks, .{
        .stop_reason = .tool_use,
    });
}

fn makeAssistantTextMessage(
    allocator: std.mem.Allocator,
    model: ai.Model,
    text: []const u8,
    stop_reason: ai.StopReason,
    error_message: ?[]const u8,
) !ai.AssistantMessage {
    _ = allocator;

    const content = try std.heap.page_allocator.alloc(ai.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try std.heap.page_allocator.dupe(u8, text) } };
    return .{
        .content = content,
        .tool_calls = null,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.Usage.init(),
        .stop_reason = stop_reason,
        .error_message = if (error_message) |message| try std.heap.page_allocator.dupe(u8, message) else null,
        .timestamp = 0,
    };
}

fn blockingAbortStreamFn(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    _: ai.Context,
    options: ?ai.types.SimpleStreamOptions,
) !ai.event_stream.AssistantMessageEventStream {
    var stream = ai.event_stream.createAssistantMessageEventStream(allocator, io);
    const started = mid_stream_started orelse return error.MissingMidStreamObserver;
    started.store(true, .seq_cst);

    const partial = try makeAssistantTextMessage(allocator, model, "", .stop, null);
    stream.push(.{
        .event_type = .start,
        .message = partial,
    });
    stream.push(.{
        .event_type = .text_start,
        .content_index = 0,
    });
    stream.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = "partial",
    });

    var iteration: usize = 0;
    while (iteration < 50_000) : (iteration += 1) {
        if (options) |stream_options| {
            if (stream_options.signal) |signal| {
                if (signal.load(.seq_cst)) {
                    const aborted = try makeAssistantTextMessage(
                        allocator,
                        model,
                        "partial",
                        .aborted,
                        "Request was aborted",
                    );
                    stream.push(.{
                        .event_type = .error_event,
                        .error_message = aborted.error_message,
                        .message = aborted,
                    });
                    stream.end(aborted);
                    return stream;
                }
            }
        }
        std.Thread.yield() catch {};
    }

    const fallback = try makeAssistantTextMessage(allocator, model, "partial", .stop, null);
    stream.push(.{
        .event_type = .done,
        .message = fallback,
    });
    stream.end(fallback);
    return stream;
}

test "agent abort stops an in-flight stream and clears runtime state" {
    const model = ai.Model{
        .id = "blocking-test",
        .name = "Blocking Test",
        .api = "blocking-test",
        .provider = "blocking-test",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var agent = try Agent.init(std.testing.allocator, .{
        .model = model,
        .stream_fn = blockingAbortStreamFn,
    });
    defer agent.deinit();

    var capture = AbortEventCapture{};
    try agent.subscribe(.{
        .context = &capture,
        .callback = captureAbortEvent,
    });

    mid_stream_started = &capture.assistant_started;
    defer mid_stream_started = null;

    var handle = try RunPromptHandle.start(&agent, "hello");
    defer handle.join() catch {};

    try waitForAtomicTrue(&capture.assistant_started);
    agent.abort();
    try handle.join();

    const messages = agent.getMessages();
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expect(!agent.isStreaming());
    try std.testing.expect(agent.getStreamingMessage() == null);
    try std.testing.expectEqual(@as(usize, 0), agent.getPendingToolCalls().len);
    try std.testing.expect(capture.saw_agent_end.load(.seq_cst));

    switch (messages[1]) {
        .assistant => |assistant| {
            try std.testing.expectEqual(ai.StopReason.aborted, assistant.stop_reason);
            try std.testing.expectEqualStrings("Request was aborted", assistant.error_message.?);
        },
        else => return error.UnexpectedMessageRole,
    }
}

test "agent abort during tool execution cancels the tool and stops the run" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = try buildAbortToolCallMessage(arena.allocator()) },
    });

    const tool = types.AgentTool{
        .name = "wait",
        .description = "Wait for abort",
        .label = "Wait",
        .parameters = .null,
        .execute = abortableToolExecute,
    };

    var agent = try Agent.init(std.testing.allocator, .{
        .model = registration.getModel(),
        .tools = &[_]types.AgentTool{tool},
    });
    defer agent.deinit();

    var capture = AbortEventCapture{};
    try agent.subscribe(.{
        .context = &capture,
        .callback = captureAbortEvent,
    });

    abortable_tool_started = &capture.tool_started;
    defer abortable_tool_started = null;

    var handle = try RunPromptHandle.start(&agent, "hello");
    defer handle.join() catch {};

    try waitForAtomicTrue(&capture.tool_started);
    agent.abort();
    try handle.join();

    const messages = agent.getMessages();
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expect(!agent.isStreaming());
    try std.testing.expect(agent.getStreamingMessage() == null);
    try std.testing.expectEqual(@as(usize, 0), agent.getPendingToolCalls().len);
    try std.testing.expect(capture.saw_tool_error.load(.seq_cst));
    try std.testing.expect(capture.saw_agent_end.load(.seq_cst));

    switch (messages[2]) {
        .tool_result => |tool_result| {
            try std.testing.expect(tool_result.is_error);
        },
        else => return error.UnexpectedMessageRole,
    }
}

test "agent prompt minimal" {
    _ = ai.providers.faux;
}
