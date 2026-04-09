const std = @import("std");
const ai = @import("ai");
const shared = @import("shared");
const types = @import("types.zig");
const agent_loop = @import("agent_loop.zig");

const ManagedList = shared.compat.ManagedList;

pub const AgentOptions = struct {
    initial_state: ?types.AgentState = null,
    stream_fn: ?*const fn (
        model: ai.Model,
        context: ai.Context,
        options: ?ai.types.SimpleStreamOptions,
    ) ai.AssistantMessageEventStream = null,
    get_api_key: ?*const fn (provider: []const u8) ?[]const u8 = null,
    before_tool_call: ?*const fn (ctx: types.BeforeToolCallContext) anyerror!?types.BeforeToolCallResult = null,
    after_tool_call: ?*const fn (ctx: types.AfterToolCallContext) anyerror!?types.AfterToolCallResult = null,
    tool_execution: types.ToolExecutionMode = .parallel,
    steering_mode: QueueMode = .one_at_a_time,
    follow_up_mode: QueueMode = .one_at_a_time,
};

pub const QueueMode = enum {
    all,
    one_at_a_time,
};

pub const PendingMessageQueue = struct {
    mode: QueueMode,
    items: ManagedList(types.AgentMessage),

    pub fn init(gpa: std.mem.Allocator, mode: QueueMode) PendingMessageQueue {
        return .{
            .mode = mode,
            .items = ManagedList(types.AgentMessage).init(gpa),
        };
    }

    pub fn deinit(self: *PendingMessageQueue) void {
        self.items.deinit();
    }

    pub fn enqueue(self: *PendingMessageQueue, message: types.AgentMessage) void {
        self.items.append(message) catch @panic("OOM");
    }

    pub fn hasItems(self: *const PendingMessageQueue) bool {
        return self.items.len() > 0;
    }

    pub fn drain(self: *PendingMessageQueue) []types.AgentMessage {
        if (self.mode == .all) {
            const drained = self.items.toOwnedSlice() catch @panic("OOM");
            self.items.clearRetainingCapacity();
            return drained;
        }
        if (self.items.len() == 0) return &[_]types.AgentMessage{};
        const first = self.items.orderedRemove(0);
        var list = ManagedList(types.AgentMessage).init(self.items.gpa);
        list.append(first) catch @panic("OOM");
        return list.toOwnedSlice() catch @panic("OOM");
    }

    pub fn clear(self: *PendingMessageQueue) void {
        self.items.clearRetainingCapacity();
    }
};

pub const Agent = struct {
    const Self = @This();

    state: types.AgentState,
    listeners: ManagedList(*const fn (event: types.AgentEvent) void),
    steering_queue: PendingMessageQueue,
    follow_up_queue: PendingMessageQueue,
    stream_fn: ?*const fn (model: ai.Model, context: ai.Context, options: ?ai.SimpleStreamOptions) ai.AssistantMessageEventStream,
    get_api_key: ?*const fn (provider: []const u8) ?[]const u8,
    before_tool_call: ?*const fn (ctx: types.BeforeToolCallContext) anyerror!?types.BeforeToolCallResult,
    after_tool_call: ?*const fn (ctx: types.AfterToolCallContext) anyerror!?types.AfterToolCallResult,
    tool_execution: types.ToolExecutionMode,
    gpa: std.mem.Allocator,

    // Lifecycle / concurrency state
    mutex: shared.compat.Mutex = shared.compat.createMutex(),
    idle_cond: shared.compat.Condition = shared.compat.createCondition(),
    is_running: bool = false,
    abort_requested: bool = false,

    pub fn init(gpa: std.mem.Allocator, options: AgentOptions) Self {
        const initial = options.initial_state orelse types.AgentState{
            .system_prompt = "",
            .model = ai.Model{ .id = "unknown", .name = "unknown", .api = .{ .known = .faux }, .provider = .{ .known = .faux } },
            .thinking_level = .minimal,
            .tools = &.{},
            .messages = &.{},
            .pending_tool_calls = std.StringHashMap(void).init(gpa),
        };
        return .{
            .state = initial,
            .listeners = ManagedList(*const fn (event: types.AgentEvent) void).init(gpa),
            .steering_queue = PendingMessageQueue.init(gpa, options.steering_mode),
            .follow_up_queue = PendingMessageQueue.init(gpa, options.follow_up_mode),
            .stream_fn = options.stream_fn,
            .get_api_key = options.get_api_key,
            .before_tool_call = options.before_tool_call,
            .after_tool_call = options.after_tool_call,
            .tool_execution = options.tool_execution,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.state.messages.len > 0) {
            self.gpa.free(self.state.messages);
        }
        self.listeners.deinit();
        self.steering_queue.deinit();
        self.follow_up_queue.deinit();
        self.state.pending_tool_calls.deinit();
    }

    pub fn subscribe(self: *Self, listener: *const fn (event: types.AgentEvent) void) void {
        self.listeners.append(listener) catch @panic("OOM");
    }

    pub fn emit(self: *Self, event: types.AgentEvent) void {
        for (self.listeners.items()) |listener| {
            listener(event);
        }
    }

    pub fn steer(self: *Self, message: types.AgentMessage) void {
        self.steering_queue.enqueue(message);
    }

    pub fn followUp(self: *Self, message: types.AgentMessage) void {
        self.follow_up_queue.enqueue(message);
    }

    pub fn clearSteeringQueue(self: *Self) void {
        self.steering_queue.clear();
    }

    pub fn clearFollowUpQueue(self: *Self) void {
        self.follow_up_queue.clear();
    }

    pub fn clearAllQueues(self: *Self) void {
        self.clearSteeringQueue();
        self.clearFollowUpQueue();
    }

    pub fn reset(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state.messages.len > 0) {
            self.gpa.free(self.state.messages);
        }
        self.state.messages = &[_]types.AgentMessage{};
        self.state.is_streaming = false;
        self.state.streaming_message = null;
        self.state.pending_tool_calls.clearRetainingCapacity();
        self.state.error_message = null;
        self.clearAllQueues();
    }

    pub fn prompt(self: *Self, message: types.AgentMessage) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_running) return error.AlreadyRunning;

        // Append prompt to internal state
        const new_messages = try self.gpa.alloc(types.AgentMessage, self.state.messages.len + 1);
        @memcpy(new_messages[0..self.state.messages.len], self.state.messages);
        new_messages[self.state.messages.len] = message;
        if (self.state.messages.len > 0) {
            self.gpa.free(self.state.messages);
        }
        self.state.messages = new_messages;
        self.is_running = true;
        self.abort_requested = false;

        // Build context excluding the just-added prompt (agentLoop appends prompts)
        const context = types.AgentContext{
            .system_prompt = self.state.system_prompt,
            .messages = self.state.messages[0 .. self.state.messages.len - 1],
            .tools = if (self.state.tools.len > 0) self.state.tools else null,
        };

        const config = self.buildLoopConfigLocked();
        const stream_fn = self.stream_fn orelse ai.streamSimple;
        const prompts = self.state.messages[self.state.messages.len - 1 ..];

        const thread = std.Thread.spawn(.{}, struct {
            fn run(agent: *Self, p: []const types.AgentMessage, c: types.AgentContext, cfg: types.AgentLoopConfig, sf: *const fn (model: ai.Model, ctx: ai.Context, options: ?ai.SimpleStreamOptions) ai.AssistantMessageEventStream) !void {
                var es = try agent_loop.createAgentEventStream(agent.gpa);
                defer es.deinit();
                try agent_loop.agentLoop(agent.gpa, p, c, cfg, sf, &es);
                agent.consumeEventStream(&es);
            }
        }.run, .{ self, prompts, context, config, stream_fn }) catch return error.ThreadSpawnFailed;
        thread.detach();
    }

    pub fn continueRun(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_running) return error.AlreadyRunning;
        if (self.state.messages.len == 0) return error.NoMessagesToContinue;
        const last = self.state.messages[self.state.messages.len - 1];
        switch (last) {
            .assistant => return error.CannotContinueFromAssistant,
            else => {},
        }

        self.is_running = true;
        self.abort_requested = false;

        const context = types.AgentContext{
            .system_prompt = self.state.system_prompt,
            .messages = self.state.messages,
            .tools = if (self.state.tools.len > 0) self.state.tools else null,
        };

        const config = self.buildLoopConfigLocked();
        const stream_fn = self.stream_fn orelse ai.streamSimple;

        const thread = std.Thread.spawn(.{}, struct {
            fn run(agent: *Self, c: types.AgentContext, cfg: types.AgentLoopConfig, sf: *const fn (model: ai.Model, ctx: ai.Context, options: ?ai.SimpleStreamOptions) ai.AssistantMessageEventStream) !void {
                var es = try agent_loop.createAgentEventStream(agent.gpa);
                defer es.deinit();
                try agent_loop.agentLoopContinue(agent.gpa, c, cfg, sf, &es);
                agent.consumeEventStream(&es);
            }
        }.run, .{ self, context, config, stream_fn }) catch return error.ThreadSpawnFailed;
        thread.detach();
    }

    pub fn abort(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.abort_requested = true;
        self.clearAllQueues();
    }

    pub fn waitForIdle(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.is_running) {
            self.idle_cond.wait(&self.mutex);
        }
    }

    fn consumeEventStream(self: *Self, es: *agent_loop.AgentEventStream) void {
        while (true) {
            self.mutex.lock();
            const should_abort = self.abort_requested;
            self.mutex.unlock();

            if (should_abort) {
                break;
            }

            const ev = es.next() orelse break;
            self.emit(ev);
        }

        const final = es.waitResult();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (final) |msgs| {
            if (self.state.messages.len > 0) {
                self.gpa.free(self.state.messages);
            }
            self.state.messages = msgs;
        }
        self.is_running = false;
        self.idle_cond.broadcast();
    }

    fn buildLoopConfigLocked(self: *Self) types.AgentLoopConfig {
        return .{
            .model = self.state.model,
            .get_api_key = self.get_api_key,
            .get_steering_messages = steeringMessagesFromAgent,
            .get_follow_up_messages = followUpMessagesFromAgent,
            .tool_execution = self.tool_execution,
            .before_tool_call = self.before_tool_call,
            .after_tool_call = self.after_tool_call,
            .user_ctx = self,
        };
    }
};

fn steeringMessagesFromAgent(ctx: ?*anyopaque) []const types.AgentMessage {
    const self: *Agent = @ptrCast(@alignCast(ctx.?));
    return self.steering_queue.drain();
}

fn followUpMessagesFromAgent(ctx: ?*anyopaque) []const types.AgentMessage {
    const self: *Agent = @ptrCast(@alignCast(ctx.?));
    return self.follow_up_queue.drain();
}

var g_test_events: ?*ManagedList(types.AgentEvent) = null;
var g_test_events_mutex: shared.compat.Mutex = shared.compat.createMutex();

fn testListener(event: types.AgentEvent) void {
    g_test_events_mutex.lock();
    defer g_test_events_mutex.unlock();
    if (g_test_events) |list| {
        list.append(event) catch @panic("OOM");
    }
}

fn setupFauxTextResponse(text: []const u8) void {
    ai.faux_provider.registerFauxProvider();
    ai.faux_provider.addFauxTextResponse(text);
}

test "agent prompt and waitForIdle" {
    const gpa = std.testing.allocator;
    setupFauxTextResponse("Hello agent");

    var events = ManagedList(types.AgentEvent).init(gpa);
    defer events.deinit();

    g_test_events_mutex.lock();
    g_test_events = &events;
    g_test_events_mutex.unlock();
    defer {
        g_test_events_mutex.lock();
        g_test_events = null;
        g_test_events_mutex.unlock();
    }

    var agent = Agent.init(gpa, .{});
    defer agent.deinit();
    agent.subscribe(testListener);

    const prompt = types.AgentMessage{ .user = .{ .content = .{ .text = "Hi" }, .timestamp = 0 } };
    try agent.prompt(prompt);
    agent.waitForIdle();

    try std.testing.expect(!agent.is_running);
    try std.testing.expectEqual(@as(usize, 2), agent.state.messages.len);
    try std.testing.expect(agent.state.messages[0] == .user);
    try std.testing.expect(agent.state.messages[1] == .assistant);

    // Check event sequence ends with agent_end
    g_test_events_mutex.lock();
    const has_agent_end = events.len() > 0 and switch (events.items()[events.len() - 1]) {
        .agent_end => true,
        else => false,
    };
    g_test_events_mutex.unlock();
    try std.testing.expect(has_agent_end);
}

test "agent prompt fails when already running" {
    const gpa = std.testing.allocator;
    setupFauxTextResponse("Hello");

    var agent = Agent.init(gpa, .{});
    defer agent.deinit();

    const prompt = types.AgentMessage{ .user = .{ .content = .{ .text = "Hi" }, .timestamp = 0 } };
    try agent.prompt(prompt);
    defer agent.waitForIdle();

    const prompt2 = types.AgentMessage{ .user = .{ .content = .{ .text = "Again" }, .timestamp = 0 } };
    const result = agent.prompt(prompt2);
    try std.testing.expectError(error.AlreadyRunning, result);
}

test "agent continueRun works" {
    const gpa = std.testing.allocator;
    setupFauxTextResponse("Continuing");

    var agent = Agent.init(gpa, .{});
    defer agent.deinit();

    // Seed a user message so continueRun has somewhere to go.
    agent.state.messages = try gpa.dupe(types.AgentMessage, &[_]types.AgentMessage{
        types.AgentMessage{ .user = .{ .content = .{ .text = "Continue from here" }, .timestamp = 0 } },
    });

    try agent.continueRun();
    agent.waitForIdle();

    try std.testing.expectEqual(@as(usize, 2), agent.state.messages.len);
    try std.testing.expect(agent.state.messages[1] == .assistant);

    // Cannot continue twice in a row from an assistant message.
    const result = agent.continueRun();
    try std.testing.expectError(error.CannotContinueFromAssistant, result);
}

test "agent continueRun fails from assistant message" {
    const gpa = std.testing.allocator;
    var agent = Agent.init(gpa, .{});
    defer agent.deinit();

    var content = [_]ai.ContentBlock{.{ .text = .{ .text = "I am assistant" } }};
    const msg = ai.AssistantMessage{
        .role = "assistant",
        .content = &content,
        .api = .{ .known = .faux },
        .provider = .{ .known = .faux },
        .model = "faux-1",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    const new_messages = try gpa.alloc(types.AgentMessage, 1);
    new_messages[0] = .{ .assistant = msg };
    agent.state.messages = new_messages;

    const result = agent.continueRun();
    try std.testing.expectError(error.CannotContinueFromAssistant, result);
}

test "agent steering queue consumed during loop" {
    const gpa = std.testing.allocator;
    setupFauxTextResponse("Ack");

    var agent = Agent.init(gpa, .{});
    defer agent.deinit();

    const steering = types.AgentMessage{ .user = .{ .content = .{ .text = "Steer me" }, .timestamp = 0 } };
    agent.steer(steering);

    const prompt = types.AgentMessage{ .user = .{ .content = .{ .text = "Hi" }, .timestamp = 0 } };
    try agent.prompt(prompt);
    agent.waitForIdle();

    // prompt + steering + assistant = 3 messages (steering is injected into this turn).
    try std.testing.expectEqual(@as(usize, 3), agent.state.messages.len);
    try std.testing.expect(agent.state.messages[0] == .user);
    try std.testing.expect(agent.state.messages[1] == .user);
    try std.testing.expectEqualStrings("Steer me", agent.state.messages[1].user.content.text);
    try std.testing.expect(agent.state.messages[2] == .assistant);
    // Steering queue should be drained.
    try std.testing.expectEqual(@as(usize, 0), agent.steering_queue.items.len());
}

test "agent followUp queue consumed" {
    const gpa = std.testing.allocator;
    setupFauxTextResponse("Followed");
    // follow-ups trigger a second turn, so queue another response.
    setupFauxTextResponse("Followed again");

    var agent = Agent.init(gpa, .{});
    defer agent.deinit();

    const follow = types.AgentMessage{ .user = .{ .content = .{ .text = "Follow up" }, .timestamp = 0 } };
    agent.followUp(follow);

    const prompt = types.AgentMessage{ .user = .{ .content = .{ .text = "Hi" }, .timestamp = 0 } };
    try agent.prompt(prompt);
    agent.waitForIdle();

    // prompt + first assistant + followUp + second assistant = 4 messages
    try std.testing.expectEqual(@as(usize, 4), agent.state.messages.len);
    try std.testing.expectEqualStrings("Follow up", agent.state.messages[2].user.content.text);
    try std.testing.expect(agent.state.messages[3] == .assistant);
}

test "agent abort clears queues and allows idle" {
    const gpa = std.testing.allocator;
    setupFauxTextResponse("Eventually");

    var agent = Agent.init(gpa, .{});
    defer agent.deinit();

    const steering = types.AgentMessage{ .user = .{ .content = .{ .text = "Steer" }, .timestamp = 0 } };
    agent.steer(steering);

    const prompt = types.AgentMessage{ .user = .{ .content = .{ .text = "Hi" }, .timestamp = 0 } };
    try agent.prompt(prompt);

    // Immediately abort
    agent.abort();
    agent.waitForIdle();

    try std.testing.expect(!agent.is_running);
    try std.testing.expect(!agent.steering_queue.hasItems());
    try std.testing.expect(!agent.follow_up_queue.hasItems());
}

test "agent reset clears state and queues" {
    const gpa = std.testing.allocator;
    setupFauxTextResponse("Hello");

    var agent = Agent.init(gpa, .{});
    defer agent.deinit();

    const prompt = types.AgentMessage{ .user = .{ .content = .{ .text = "Hi" }, .timestamp = 0 } };
    try agent.prompt(prompt);
    agent.waitForIdle();

    agent.steer(types.AgentMessage{ .user = .{ .content = .{ .text = "S" }, .timestamp = 0 } });
    agent.followUp(types.AgentMessage{ .user = .{ .content = .{ .text = "F" }, .timestamp = 0 } });

    agent.reset();

    try std.testing.expectEqual(@as(usize, 0), agent.state.messages.len);
    try std.testing.expect(!agent.steering_queue.hasItems());
    try std.testing.expect(!agent.follow_up_queue.hasItems());
}
