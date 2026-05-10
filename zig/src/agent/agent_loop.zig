const std = @import("std");
const ai = @import("ai");
const provider_json = ai.provider_json;
const types = @import("types.zig");
const json_schema = @import("json_schema.zig");
const accumulator = @import("accumulator.zig");
const content_clone = @import("content_clone.zig");
const tool_execution = @import("tool_execution.zig");
const streaming = @import("streaming.zig");

pub const AgentLoopError = types.AgentLoopError;


pub fn runAgentLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    prompts: []const types.AgentMessage,
    context: types.AgentContext,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
    stream_fn: ?types.StreamFn,
) ![]const types.AgentMessage {
    var new_messages = std.ArrayList(types.AgentMessage).empty;
    errdefer new_messages.deinit(allocator);

    var current_messages = std.ArrayList(types.AgentMessage).empty;
    defer current_messages.deinit(allocator);
    try current_messages.appendSlice(allocator, context.messages);

    try emit(emit_context, .{ .event_type = .agent_start });
    try emit(emit_context, .{ .event_type = .turn_start });

    for (prompts) |prompt| {
        try current_messages.append(allocator, prompt);
        try new_messages.append(allocator, prompt);
        try emit(emit_context, .{
            .event_type = .message_start,
            .message = prompt,
        });
        try emit(emit_context, .{
            .event_type = .message_end,
            .message = prompt,
        });
    }

    try runLoop(
        allocator,
        io,
        &current_messages,
        &new_messages,
        context.system_prompt,
        context.tools,
        config,
        emit_context,
        emit,
        signal,
        stream_fn,
    );
    return try allocator.dupe(types.AgentMessage, new_messages.items);
}

fn runLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    current_messages: *std.ArrayList(types.AgentMessage),
    new_messages: *std.ArrayList(types.AgentMessage),
    system_prompt: []const u8,
    tools: []const types.AgentTool,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
    stream_fn: ?types.StreamFn,
) !void {
    var first_turn = true;
    var pending_messages = try getPendingMessages(
        allocator,
        config.get_steering_messages,
        config.get_steering_messages_context,
    );
    defer allocator.free(pending_messages);

    while (true) {
        var has_more_tool_calls = true;

        while (has_more_tool_calls or pending_messages.len > 0) {
            if (first_turn) {
                first_turn = false;
            } else {
                try emit(emit_context, .{ .event_type = .turn_start });
            }

            if (pending_messages.len > 0) {
                for (pending_messages) |message| {
                    try current_messages.append(allocator, message);
                    try new_messages.append(allocator, message);
                    try emit(emit_context, .{
                        .event_type = .message_start,
                        .message = message,
                    });
                    try emit(emit_context, .{
                        .event_type = .message_end,
                        .message = message,
                    });
                }

                allocator.free(pending_messages);
                pending_messages = try allocator.alloc(types.AgentMessage, 0);
            }

            const current_context = types.AgentContext{
                .system_prompt = system_prompt,
                .messages = current_messages.items,
                .tools = tools,
                .extension_hook_context = config.extension_hook_context,
            };

            const assistant = try streaming.streamAssistantResponse(
                allocator,
                io,
                current_context,
                config,
                emit_context,
                emit,
                signal,
                stream_fn,
            );

            try current_messages.append(allocator, .{ .assistant = assistant });
            try new_messages.append(allocator, .{ .assistant = assistant });

            var tool_results = std.ArrayList(types.ToolResultMessage).empty;
            defer tool_results.deinit(allocator);

            if (assistant.stop_reason == .error_reason or assistant.stop_reason == .aborted) {
                try emit(emit_context, .{
                    .event_type = .turn_end,
                    .message = .{ .assistant = assistant },
                    .tool_results = tool_results.items,
                });
                try emit(emit_context, .{
                    .event_type = .agent_end,
                    .messages = new_messages.items,
                });
                return;
            }

            const tool_calls = try ai.collectAssistantToolCalls(allocator, assistant);
            defer allocator.free(tool_calls);
            has_more_tool_calls = tool_calls.len > 0;

            if (has_more_tool_calls) {
                const executed_tool_results = try tool_execution.executeToolCalls(
                    allocator,
                    io,
                    current_context,
                    assistant,
                    tool_calls,
                    config,
                    emit_context,
                    emit,
                    signal,
                );
                defer allocator.free(executed_tool_results);

                try tool_results.appendSlice(allocator, executed_tool_results);
                for (tool_results.items) |tool_result| {
                    try current_messages.append(allocator, .{ .tool_result = tool_result });
                    try new_messages.append(allocator, .{ .tool_result = tool_result });
                }
            }

            try emit(emit_context, .{
                .event_type = .turn_end,
                .message = .{ .assistant = assistant },
                .tool_results = tool_results.items,
            });

            if (isAbortRequested(signal)) {
                try emit(emit_context, .{
                    .event_type = .agent_end,
                    .messages = new_messages.items,
                });
                return;
            }

            allocator.free(pending_messages);
            pending_messages = try getPendingMessages(
                allocator,
                config.get_steering_messages,
                config.get_steering_messages_context,
            );
        }

        allocator.free(pending_messages);
        pending_messages = try getPendingMessages(
            allocator,
            config.get_follow_up_messages,
            config.get_follow_up_messages_context,
        );
        if (pending_messages.len > 0) {
            continue;
        }

        break;
    }

    try emit(emit_context, .{
        .event_type = .agent_end,
        .messages = new_messages.items,
    });
}

fn getPendingMessages(
    allocator: std.mem.Allocator,
    callback: ?types.PendingMessagesFn,
    context: ?*anyopaque,
) ![]types.AgentMessage {
    if (callback) |drain_messages| {
        return try drain_messages(allocator, context);
    }
    return try allocator.alloc(types.AgentMessage, 0);
}

fn isAbortRequested(signal: ?*const std.atomic.Value(bool)) bool {
    return if (signal) |abort_signal| abort_signal.load(.seq_cst) else false;
}



const TestCapture = struct {
    allocator: std.mem.Allocator,
    event_types: std.ArrayList(types.AgentEventType),
    event_messages: std.ArrayList(types.AgentMessage),

    fn init(allocator: std.mem.Allocator) TestCapture {
        return .{
            .allocator = allocator,
            .event_types = .empty,
            .event_messages = .empty,
        };
    }

    fn deinit(self: *TestCapture) void {
        self.event_types.deinit(self.allocator);
        self.event_messages.deinit(self.allocator);
    }
};

fn captureEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *TestCapture = @ptrCast(@alignCast(context.?));
    try capture.event_types.append(capture.allocator, event.event_type);
    if (event.message) |message| {
        try capture.event_messages.append(capture.allocator, message);
    }
}

fn defaultConvertToLlmForTest(
    allocator: std.mem.Allocator,
    messages: []const types.AgentMessage,
    _: ?*anyopaque,
) ![]ai.Message {
    return try allocator.dupe(ai.Message, messages);
}

fn createUserMessage(text: []const u8, timestamp: i64) types.AgentMessage {
    const content = std.heap.page_allocator.alloc(ai.ContentBlock, 1) catch unreachable;
    content[0] = .{ .text = .{ .text = text } };
    return .{ .user = .{
        .content = content,
        .timestamp = timestamp,
    } };
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

fn jsonStringObject(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try object.put(
        allocator,
        try allocator.dupe(u8, key),
        .{ .string = try allocator.dupe(u8, value) },
    );
    return .{ .object = object };
}

fn textToolResult(allocator: std.mem.Allocator, text: []const u8) !types.AgentToolResult {
    const content = try allocator.alloc(ai.ContentBlock, 1);
    content[0] = .{
        .text = .{
            .text = try allocator.dupe(u8, text),
        },
    };
    return .{
        .content = content,
        .details = null,
    };
}

const ToolResultContentCapture = struct {
    content_ptr: ?[*]const ai.ContentBlock = null,
    text_ptr: ?[*]const u8 = null,
    text_len: usize = 0,
};

const ToolResultContentCaptureFixture = struct {
    capture: ToolResultContentCapture = .{},
};

fn capturingEchoToolExecute(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const result = try echoToolExecute(allocator, tool_call_id, params, tool_context, signal, on_update_context, on_update);
    const fixture: *ToolResultContentCaptureFixture = @ptrCast(@alignCast(tool_context orelse return result));

    fixture.capture.content_ptr = result.content.ptr;
    switch (result.content[0]) {
        .text => |text| {
            fixture.capture.text_ptr = text.text.ptr;
            fixture.capture.text_len = text.text.len;
        },
        else => return error.UnexpectedToolResultContent,
    }

    return result;
}

fn getStringArg(args: std.json.Value, key: []const u8) ![]const u8 {
    if (args != .object) return error.InvalidToolArguments;
    const value = args.object.get(key) orelse return error.InvalidToolArguments;
    if (value != .string) return error.InvalidToolArguments;
    return value.string;
}

fn yieldForIterations(iterations: usize) void {
    var remaining = iterations;
    while (remaining > 0) : (remaining -= 1) {
        std.Thread.yield() catch {};
    }
}

const ToolExecutionCapture = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(types.AgentEvent),

    fn init(allocator: std.mem.Allocator) ToolExecutionCapture {
        return .{
            .allocator = allocator,
            .events = .empty,
        };
    }

    fn deinit(self: *ToolExecutionCapture) void {
        self.events.deinit(self.allocator);
    }
};

const ParallelStreamingCapture = struct {
    main_thread_id: std.Thread.Id,
    slow_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    saw_fast_update_before_slow_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    saw_update_off_main_thread: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    invalid_main_thread_event: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    concurrent_callback_entry: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    update_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    in_callback: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const ParallelHookOrderingCapture = struct {
    allocator: std.mem.Allocator,
    first_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    second_observed_before_first_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    after_hook_order: std.ArrayList([]const u8) = .empty,
    tool_end_order: std.ArrayList([]const u8) = .empty,
    tool_message_order: std.ArrayList([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator) ParallelHookOrderingCapture {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ParallelHookOrderingCapture) void {
        self.after_hook_order.deinit(self.allocator);
        self.tool_end_order.deinit(self.allocator);
        self.tool_message_order.deinit(self.allocator);
    }
};

fn captureToolEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *ToolExecutionCapture = @ptrCast(@alignCast(context.?));
    try capture.events.append(capture.allocator, event);
}

fn captureParallelHookOrderingEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *ParallelHookOrderingCapture = @ptrCast(@alignCast(context.?));
    switch (event.event_type) {
        .tool_execution_end => {
            try capture.tool_end_order.append(capture.allocator, event.tool_call_id orelse return error.MissingToolCallId);
        },
        .message_end => {
            const message = event.message orelse return;
            switch (message) {
                .tool_result => |tool_result| try capture.tool_message_order.append(capture.allocator, tool_result.tool_call_id),
                else => {},
            }
        },
        else => {},
    }
}

fn captureParallelStreamingEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *ParallelStreamingCapture = @ptrCast(@alignCast(context.?));
    const current_thread_id = std.Thread.getCurrentId();
    switch (event.event_type) {
        .tool_execution_start, .tool_execution_end => {
            if (current_thread_id != capture.main_thread_id) {
                capture.invalid_main_thread_event.store(true, .seq_cst);
            }
        },
        .tool_execution_update => {
            if (capture.in_callback.swap(true, .seq_cst)) {
                capture.concurrent_callback_entry.store(true, .seq_cst);
            }
            defer capture.in_callback.store(false, .seq_cst);

            if (current_thread_id != capture.main_thread_id) {
                capture.saw_update_off_main_thread.store(true, .seq_cst);
            }
            _ = capture.update_count.fetchAdd(1, .seq_cst);
            if (event.tool_call_id) |tool_call_id| {
                if (std.mem.eql(u8, tool_call_id, "fast") and !capture.slow_done.load(.seq_cst)) {
                    capture.saw_fast_update_before_slow_done.store(true, .seq_cst);
                }
            }
            std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
        },
        else => {},
    }
}

fn ignoreEvent(_: ?*anyopaque, _: types.AgentEvent) !void {}

fn passthroughConvertToLlmForTest(
    _: std.mem.Allocator,
    messages: []const types.AgentMessage,
    _: ?*anyopaque,
) ![]ai.Message {
    return @constCast(messages);
}

fn ownedDeltaStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    _: ai.Context,
    _: ?ai.types.SimpleStreamOptions,
    _: ?*anyopaque,
) !ai.event_stream.AssistantMessageEventStream {
    const result_allocator = allocator;
    const text = try result_allocator.dupe(u8, "streamed response");
    const content = try result_allocator.alloc(ai.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };

    var stream = ai.event_stream.createAssistantMessageEventStream(allocator, io);
    stream.push(.{ .event_type = .start });
    stream.push(.{ .event_type = .text_start, .content_index = 0 });
    stream.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = try allocator.dupe(u8, "streamed "),
        .owns_delta = true,
    });
    stream.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = try allocator.dupe(u8, "response"),
        .owns_delta = true,
    });
    stream.push(.{ .event_type = .text_end, .content_index = 0 });
    stream.push(.{
        .event_type = .done,
        .message = .{
            .content = content,
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = ai.Usage.init(),
            .stop_reason = .stop,
            .timestamp = 1,
        },
    });
    return stream;
}

fn toolCallStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    _: ai.Context,
    _: ?ai.types.SimpleStreamOptions,
    _: ?*anyopaque,
) !ai.event_stream.AssistantMessageEventStream {
    const result_allocator = allocator;
    var args_object = try std.json.ObjectMap.init(result_allocator, &.{}, &.{});
    try args_object.put(
        result_allocator,
        try result_allocator.dupe(u8, "command"),
        .{ .string = try result_allocator.dupe(u8, "echo hi") },
    );
    const tool_calls = try result_allocator.alloc(ai.ToolCall, 1);
    tool_calls[0] = .{
        .id = try result_allocator.dupe(u8, "tool-1"),
        .name = try result_allocator.dupe(u8, "bash"),
        .arguments = .{ .object = args_object },
    };
    var content_args_object = try std.json.ObjectMap.init(result_allocator, &.{}, &.{});
    try content_args_object.put(
        result_allocator,
        try result_allocator.dupe(u8, "command"),
        .{ .string = try result_allocator.dupe(u8, "echo hi") },
    );
    const content = try result_allocator.alloc(ai.ContentBlock, 1);
    content[0] = .{ .tool_call = .{
        .id = try result_allocator.dupe(u8, "tool-1"),
        .name = try result_allocator.dupe(u8, "bash"),
        .arguments = .{ .object = content_args_object },
    } };
    const final_message = ai.AssistantMessage{
        .content = content,
        .tool_calls = tool_calls,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 1,
    };

    var stream = ai.event_stream.createAssistantMessageEventStream(allocator, io);
    stream.push(.{ .event_type = .start, .message = final_message });
    stream.push(.{ .event_type = .toolcall_start, .content_index = 0 });
    stream.push(.{ .event_type = .toolcall_delta, .content_index = 0, .delta = "{\"command\":\"echo hi\"}" });
    stream.push(.{ .event_type = .toolcall_end, .content_index = 0, .tool_call = tool_calls[0] });
    stream.push(.{ .event_type = .done, .message = final_message });
    return stream;
}

fn crossPartialUpdateStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    _: ai.Context,
    _: ?ai.types.SimpleStreamOptions,
    _: ?*anyopaque,
) !ai.event_stream.AssistantMessageEventStream {
    const result_allocator = allocator;
    var content_args_object = try std.json.ObjectMap.init(result_allocator, &.{}, &.{});
    try content_args_object.put(
        result_allocator,
        try result_allocator.dupe(u8, "query"),
        .{ .string = try result_allocator.dupe(u8, "partial") },
    );
    const content = try result_allocator.alloc(ai.ContentBlock, 3);
    content[0] = .{ .thinking = .{ .thinking = try result_allocator.dupe(u8, "plan first") } };
    content[1] = .{ .text = .{ .text = try result_allocator.dupe(u8, "prior text") } };
    content[2] = .{ .tool_call = .{
        .id = try result_allocator.dupe(u8, "call_1"),
        .name = try result_allocator.dupe(u8, "lookup"),
        .arguments = .{ .object = content_args_object },
    } };
    const final_message = ai.AssistantMessage{
        .content = content,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 1,
    };
    const template = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };

    var stream = ai.event_stream.createAssistantMessageEventStream(allocator, io);
    stream.push(.{ .event_type = .start, .message = template });
    stream.push(.{ .event_type = .thinking_start, .content_index = 0 });
    stream.push(.{ .event_type = .thinking_delta, .content_index = 0, .delta = "plan " });
    stream.push(.{ .event_type = .thinking_delta, .content_index = 0, .delta = "first" });
    stream.push(.{ .event_type = .thinking_end, .content_index = 0, .content = "plan first" });
    stream.push(.{ .event_type = .text_start, .content_index = 1 });
    stream.push(.{ .event_type = .text_delta, .content_index = 1, .delta = "prior " });
    stream.push(.{ .event_type = .text_delta, .content_index = 1, .delta = "text" });
    stream.push(.{ .event_type = .text_end, .content_index = 1, .content = "prior text" });
    stream.push(.{ .event_type = .toolcall_start, .content_index = 2 });
    stream.push(.{ .event_type = .toolcall_delta, .content_index = 2, .delta = "{\"query\":\"par" });
    stream.push(.{ .event_type = .toolcall_end, .content_index = 2, .tool_call = content[2].tool_call });
    stream.push(.{ .event_type = .done, .message = final_message });
    return stream;
}

const PartialUpdateCrossCapture = struct {
    saw_thinking_delta: bool = false,
    saw_thinking_end: bool = false,
    saw_text_delta: bool = false,
    saw_toolcall_delta: bool = false,
    saw_toolcall_end: bool = false,
};

const StreamingUpdateSnapshotCapture = struct {
    allocator: std.mem.Allocator,
    snapshots: std.ArrayList([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator) StreamingUpdateSnapshotCapture {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *StreamingUpdateSnapshotCapture) void {
        for (self.snapshots.items) |snapshot| self.allocator.free(snapshot);
        self.snapshots.deinit(self.allocator);
    }
};

const MessageUpdateCountCapture = struct {
    message_update_count: usize = 0,
    message_end_count: usize = 0,
};

fn capturePartialUpdateCrossEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *PartialUpdateCrossCapture = @ptrCast(@alignCast(context.?));
    if (event.event_type != .message_update) return;
    const assistant_event = event.assistant_message_event orelse return;
    const message = event.message orelse return error.MissingPartialMessage;
    const assistant = switch (message) {
        .assistant => |assistant_message| assistant_message,
        else => return error.UnexpectedMessageRole,
    };

    switch (assistant_event.event_type) {
        .thinking_delta => {
            if (!std.mem.eql(u8, assistant_event.delta orelse "", "first")) return;
            capture.saw_thinking_delta = true;
            try std.testing.expectEqual(@as(?u32, 0), assistant_event.content_index);
            try std.testing.expectEqual(@as(usize, 1), assistant.content.len);
            try std.testing.expect(assistant.content[0] == .thinking);
            try std.testing.expectEqualStrings("plan first", assistant.content[0].thinking.thinking);
        },
        .thinking_end => {
            capture.saw_thinking_end = true;
            try std.testing.expectEqual(@as(?u32, 0), assistant_event.content_index);
            try std.testing.expectEqual(@as(usize, 1), assistant.content.len);
            try std.testing.expect(assistant.content[0] == .thinking);
            try std.testing.expectEqualStrings("plan first", assistant.content[0].thinking.thinking);
        },
        .text_delta => {
            if (!std.mem.eql(u8, assistant_event.delta orelse "", "text")) return;
            capture.saw_text_delta = true;
            try std.testing.expectEqual(@as(?u32, 1), assistant_event.content_index);
            try std.testing.expectEqual(@as(usize, 2), assistant.content.len);
            try std.testing.expectEqualStrings("plan first", assistant.content[0].thinking.thinking);
            try std.testing.expectEqualStrings("prior text", assistant.content[1].text.text);
        },
        .toolcall_delta => {
            capture.saw_toolcall_delta = true;
            try std.testing.expectEqual(@as(?u32, 2), assistant_event.content_index);
            try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
            try std.testing.expectEqualStrings("plan first", assistant.content[0].thinking.thinking);
            try std.testing.expectEqualStrings("prior text", assistant.content[1].text.text);
            try std.testing.expect(assistant.content[2] == .tool_call);
            const arguments = assistant.content[2].tool_call.arguments;
            try std.testing.expect(arguments == .object);
            try std.testing.expectEqualStrings("par", arguments.object.get("query").?.string);
        },
        .toolcall_end => {
            capture.saw_toolcall_end = true;
            try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
            try std.testing.expectEqualStrings("plan first", assistant.content[0].thinking.thinking);
            try std.testing.expectEqualStrings("prior text", assistant.content[1].text.text);
            try std.testing.expectEqualStrings("call_1", assistant.content[2].tool_call.id);
            try std.testing.expectEqualStrings("lookup", assistant.content[2].tool_call.name);
            try std.testing.expectEqualStrings("partial", assistant.content[2].tool_call.arguments.object.get("query").?.string);
        },
        else => {},
    }
}

fn captureStreamingUpdateSnapshotEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *StreamingUpdateSnapshotCapture = @ptrCast(@alignCast(context.?));
    if (event.event_type != .message_update) return;

    const snapshot = try streamingUpdateSnapshot(capture.allocator, event);
    errdefer capture.allocator.free(snapshot);
    try capture.snapshots.append(capture.allocator, snapshot);
}

fn countMessageUpdateEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *MessageUpdateCountCapture = @ptrCast(@alignCast(context.?));
    switch (event.event_type) {
        .message_update => capture.message_update_count += 1,
        .message_end => capture.message_end_count += 1,
        else => {},
    }
}

fn streamingUpdateSnapshot(allocator: std.mem.Allocator, event: types.AgentEvent) ![]const u8 {
    const assistant_event = event.assistant_message_event orelse return error.MissingAssistantMessageEvent;
    const message = event.message orelse return error.MissingPartialMessage;
    const assistant = switch (message) {
        .assistant => |assistant_message| assistant_message,
        else => return error.UnexpectedMessageRole,
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print("event={s}", .{@tagName(assistant_event.event_type)});
    if (assistant_event.content_index) |content_index| {
        try out.writer.print("|index={d}", .{content_index});
    }
    if (assistant_event.delta) |delta| {
        try out.writer.print("|delta={s}", .{delta});
    }
    if (assistant_event.content) |content| {
        try out.writer.print("|content={s}", .{content});
    }
    if (assistant_event.tool_call) |tool_call| {
        try out.writer.writeAll("|eventToolCall=");
        try writeToolCallSnapshot(allocator, &out.writer, tool_call);
    }

    try out.writer.writeAll("|message=");
    try writeContentSnapshot(allocator, &out.writer, assistant.content);
    return allocator.dupe(u8, out.written());
}

fn writeContentSnapshot(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    content: []const ai.ContentBlock,
) !void {
    try writer.writeAll("[");
    for (content, 0..) |block, index| {
        if (index > 0) try writer.writeAll(",");
        switch (block) {
            .text => |text| try writer.print("text:{s}", .{text.text}),
            .thinking => |thinking| try writer.print("thinking:{s}", .{thinking.thinking}),
            .tool_call => |tool_call| {
                try writer.writeAll("toolCall:");
                try writeToolCallSnapshot(allocator, writer, tool_call);
            },
            .image => try writer.writeAll("image"),
        }
    }
    try writer.writeAll("]");
}

fn writeToolCallSnapshot(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    tool_call: ai.ToolCall,
) !void {
    const args_json = try std.json.Stringify.valueAlloc(allocator, tool_call.arguments, .{});
    defer allocator.free(args_json);
    try writer.print("id={s},name={s},args={s}", .{ tool_call.id, tool_call.name, args_json });
}

fn malformedPartialToolCallStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    _: ai.Context,
    _: ?ai.types.SimpleStreamOptions,
    _: ?*anyopaque,
) !ai.event_stream.AssistantMessageEventStream {
    const result_allocator = allocator;
    const content_args_object = try std.json.ObjectMap.init(result_allocator, &.{}, &.{});
    const content = try result_allocator.alloc(ai.ContentBlock, 2);
    content[0] = .{ .text = .{ .text = try result_allocator.dupe(u8, "before tool") } };
    content[1] = .{ .tool_call = .{
        .id = try result_allocator.dupe(u8, "call_bad_args"),
        .name = try result_allocator.dupe(u8, "lookup"),
        .arguments = .{ .object = content_args_object },
    } };
    const final_message = ai.AssistantMessage{
        .content = content,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 1,
    };
    const template = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };

    var stream = ai.event_stream.createAssistantMessageEventStream(allocator, io);
    stream.push(.{ .event_type = .start, .message = template });
    stream.push(.{ .event_type = .text_start, .content_index = 0 });
    stream.push(.{ .event_type = .text_delta, .content_index = 0, .delta = "before tool" });
    stream.push(.{ .event_type = .text_end, .content_index = 0, .content = "before tool" });
    stream.push(.{ .event_type = .toolcall_start, .content_index = 1 });
    stream.push(.{ .event_type = .toolcall_delta, .content_index = 1, .delta = "not-json" });
    stream.push(.{ .event_type = .toolcall_end, .content_index = 1, .tool_call = content[1].tool_call });
    stream.push(.{ .event_type = .done, .message = final_message });
    return stream;
}

fn abortedPartialToolCallStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    _: ai.Context,
    options: ?ai.types.SimpleStreamOptions,
    _: ?*anyopaque,
) !ai.event_stream.AssistantMessageEventStream {
    if (options) |stream_options| {
        if (stream_options.signal) |signal| @constCast(signal).store(true, .seq_cst);
    }

    const template = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };
    const final_message = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.Usage.init(),
        .stop_reason = .aborted,
        .error_message = "Request was aborted",
        .timestamp = 2,
    };
    const borrowed_final_tool = ai.ToolCall{
        .id = "abort-tool",
        .name = "lookup",
        .arguments = .{ .string = "borrowed final args" },
        .thought_signature = "borrowed signature",
    };

    var stream = ai.event_stream.createAssistantMessageEventStream(allocator, io);
    errdefer stream.deinit();
    stream.push(.{ .event_type = .start, .message = template });
    stream.push(.{ .event_type = .text_start, .content_index = 0 });
    stream.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = "partial before abort",
    });
    stream.push(.{ .event_type = .toolcall_start, .content_index = 1 });
    stream.push(.{
        .event_type = .toolcall_delta,
        .content_index = 1,
        .delta = "{\"query\":\"owned partial\"}",
    });
    stream.push(.{
        .event_type = .toolcall_end,
        .content_index = 1,
        .tool_call = borrowed_final_tool,
    });
    stream.push(.{
        .event_type = .error_event,
        .message = final_message,
        .error_message = final_message.error_message,
    });
    return stream;
}

fn runtimeErrorToolCallStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    _: ai.Context,
    _: ?ai.types.SimpleStreamOptions,
    _: ?*anyopaque,
) !ai.event_stream.AssistantMessageEventStream {
    const template = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };

    const partial_tool = ai.ToolCall{
        .id = "runtime-error-partial",
        .name = "echo",
        .arguments = .{ .string = "borrowed partial args" },
        .thought_signature = "borrowed runtime signature",
    };

    const terminal_args = try jsonStringObject(allocator, "value", "should-not-run");
    const terminal_tool_calls = try allocator.alloc(ai.ToolCall, 1);
    terminal_tool_calls[0] = .{
        .id = try allocator.dupe(u8, "runtime-error-terminal"),
        .name = try allocator.dupe(u8, "echo"),
        .arguments = terminal_args,
    };
    const terminal_content = try allocator.alloc(ai.ContentBlock, 2);
    terminal_content[0] = .{ .text = .{ .text = try allocator.dupe(u8, "partial before runtime error") } };
    terminal_content[1] = .{ .tool_call = terminal_tool_calls[0] };

    const final_message = ai.AssistantMessage{
        .content = terminal_content,
        .tool_calls = terminal_tool_calls,
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = "ProviderParseFailure",
        .timestamp = 2,
    };

    var stream = ai.event_stream.createAssistantMessageEventStream(allocator, io);
    errdefer stream.deinit();
    stream.push(.{ .event_type = .start, .message = template });
    stream.push(.{ .event_type = .text_start, .content_index = 0 });
    stream.push(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = "partial before runtime error",
    });
    stream.push(.{ .event_type = .toolcall_start, .content_index = 1 });
    stream.push(.{
        .event_type = .toolcall_delta,
        .content_index = 1,
        .delta = "{\"value\":\"should-not-run\"}",
    });
    stream.push(.{
        .event_type = .toolcall_end,
        .content_index = 1,
        .tool_call = partial_tool,
    });
    stream.push(.{
        .event_type = .error_event,
        .message = final_message,
        .error_message = final_message.error_message,
    });
    return stream;
}

const MalformedPartialArgsCapture = struct {
    saw_malformed_toolcall_delta: bool = false,
};

fn captureMalformedPartialArgsEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *MalformedPartialArgsCapture = @ptrCast(@alignCast(context.?));
    if (event.event_type != .message_update) return;
    const assistant_event = event.assistant_message_event orelse return;
    if (assistant_event.event_type != .toolcall_delta) return;

    const message = event.message orelse return error.MissingPartialMessage;
    const assistant = switch (message) {
        .assistant => |assistant_message| assistant_message,
        else => return error.UnexpectedMessageRole,
    };

    capture.saw_malformed_toolcall_delta = true;
    try std.testing.expectEqual(@as(?u32, 1), assistant_event.content_index);
    try std.testing.expectEqual(@as(usize, 2), assistant.content.len);
    try std.testing.expectEqualStrings("before tool", assistant.content[0].text.text);
    try std.testing.expect(assistant.content[1] == .tool_call);
    const arguments = assistant.content[1].tool_call.arguments;
    try std.testing.expect(arguments == .object);
    try std.testing.expectEqual(@as(usize, 0), arguments.object.count());
}

const CountedToolFixture = struct {
    execute_count: usize = 0,
};

fn echoToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const value = try getStringArg(params, "value");
    return try textToolResult(
        allocator,
        try std.fmt.allocPrint(allocator, "echoed: {s}", .{value}),
    );
}

fn countedEchoToolExecute(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const fixture: *CountedToolFixture = @ptrCast(@alignCast(tool_context orelse return error.MissingCountedToolFixture));
    fixture.execute_count += 1;
    return try echoToolExecute(allocator, tool_call_id, params, tool_context, signal, on_update_context, on_update);
}

fn requireValuePrepareArguments(
    allocator: std.mem.Allocator,
    args: std.json.Value,
) !std.json.Value {
    _ = try getStringArg(args, "value");
    return try provider_json.cloneValue(allocator, args);
}

fn failingToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    _ = allocator;
    return error.ToolFailure;
}

const ParallelObservation = struct {
    first_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    parallel_observed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn parallelAwareEchoToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const observation: *ParallelObservation = @ptrCast(@alignCast(tool_context orelse return error.MissingParallelObservation));
    const value = try getStringArg(params, "value");
    if (std.mem.eql(u8, value, "first")) {
        yieldForIterations(50_000);
        observation.first_finished.store(true, .seq_cst);
    } else if (!observation.first_finished.load(.seq_cst)) {
        observation.parallel_observed.store(true, .seq_cst);
    }
    return try textToolResult(
        allocator,
        try std.fmt.allocPrint(allocator, "echoed: {s}", .{value}),
    );
}

fn hookOrderingToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const capture: *ParallelHookOrderingCapture = @ptrCast(@alignCast(tool_context orelse return error.MissingParallelHookOrderingCapture));
    const value = try getStringArg(params, "value");
    if (std.mem.eql(u8, value, "first")) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake) catch {};
        capture.first_finished.store(true, .seq_cst);
    } else if (!capture.first_finished.load(.seq_cst)) {
        capture.second_observed_before_first_finished.store(true, .seq_cst);
    }
    return try textToolResult(
        allocator,
        try std.fmt.allocPrint(allocator, "echoed: {s}", .{value}),
    );
}

fn streamingParallelToolExecute(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    params: std.json.Value,
    tool_context: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const capture: *ParallelStreamingCapture = @ptrCast(@alignCast(tool_context.?));
    const value = try getStringArg(params, "value");
    if (std.mem.eql(u8, value, "slow")) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake) catch {};
        capture.slow_done.store(true, .seq_cst);
    } else {
        if (on_update) |callback| {
            const update = try textToolResult(
                allocator,
                try std.fmt.allocPrint(allocator, "{s} update", .{tool_call_id}),
            );
            try callback(on_update_context, update);
        }
    }
    return try textToolResult(
        allocator,
        try std.fmt.allocPrint(allocator, "{s} done", .{value}),
    );
}

fn stressStreamingParallelToolExecute(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    _: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    if (on_update) |callback| {
        for (0..100) |index| {
            const update = try textToolResult(
                allocator,
                try std.fmt.allocPrint(allocator, "{s}:{d}", .{ tool_call_id, index }),
            );
            try callback(on_update_context, update);
        }
    }
    return try textToolResult(allocator, try std.fmt.allocPrint(allocator, "{s} done", .{tool_call_id}));
}

fn blockBeforeToolCall(
    _: std.mem.Allocator,
    _: types.BeforeToolCallContext,
    _: ?*const std.atomic.Value(bool),
) !?types.BeforeToolCallResult {
    return .{
        .block = true,
        .reason = "blocked by hook",
    };
}

fn errorBeforeToolCall(
    _: std.mem.Allocator,
    _: types.BeforeToolCallContext,
    _: ?*const std.atomic.Value(bool),
) !?types.BeforeToolCallResult {
    return error.BeforeToolCallFailed;
}

fn recordAfterToolCallOrder(
    _: std.mem.Allocator,
    context: types.AfterToolCallContext,
    _: ?*const std.atomic.Value(bool),
) !?types.AfterToolCallResult {
    const tool = tool_execution.findTool(context.context.tools, context.tool_call.name) orelse return error.MissingParallelHookOrderingTool;
    const capture: *ParallelHookOrderingCapture = @ptrCast(@alignCast(tool.execute_context orelse return error.MissingParallelHookOrderingCapture));
    try capture.after_hook_order.append(capture.allocator, context.tool_call.id);
    return null;
}

fn overrideAfterToolCall(
    allocator: std.mem.Allocator,
    _: types.AfterToolCallContext,
    _: ?*const std.atomic.Value(bool),
) !?types.AfterToolCallResult {
    const content = try allocator.alloc(ai.ContentBlock, 1);
    content[0] = .{
        .text = .{
            .text = try allocator.dupe(u8, "modified by hook"),
        },
    };
    return .{
        .content = content,
        .is_error = false,
    };
}

const ReentrantToolContext = struct {
    nested_event_count: usize = 0,
};

fn countReentrantNestedEvent(context: ?*anyopaque, _: types.AgentEvent) !void {
    const fixture: *ReentrantToolContext = @ptrCast(@alignCast(context.?));
    fixture.nested_event_count += 1;
}

fn reentrantToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    _: std.json.Value,
    tool_context: ?*anyopaque,
    signal: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const fixture: *ReentrantToolContext = @ptrCast(@alignCast(tool_context orelse return error.MissingReentrantToolContext));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const nested_model = ai.Model{
        .id = "nested-model",
        .name = "Nested Model",
        .api = "recording:test:reentrant-nested",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };
    const nested_prompts = [_]types.AgentMessage{createUserMessage("nested prompt", 1)};
    const nested_result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        nested_prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = nested_model,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        fixture,
        countReentrantNestedEvent,
        signal,
        ownedDeltaStreamForAgentLoopTest,
    );

    try std.testing.expectEqual(@as(usize, 2), nested_result.len);
    try std.testing.expectEqualStrings("streamed response", nested_result[1].assistant.content[0].text.text);
    return try textToolResult(allocator, "nested: streamed response");
}

const ReentrantOuterStreamContext = struct {
    call_count: usize = 0,
};

fn reentrantOuterStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    context: ai.Context,
    options: ?ai.types.SimpleStreamOptions,
    stream_context: ?*anyopaque,
) !ai.event_stream.AssistantMessageEventStream {
    const fixture: *ReentrantOuterStreamContext = @ptrCast(@alignCast(stream_context.?));
    fixture.call_count += 1;
    if (fixture.call_count == 1) {
        return try toolCallStreamForAgentLoopTest(allocator, io, model, context, options, null);
    }
    return try ownedDeltaStreamForAgentLoopTest(allocator, io, model, context, options, null);
}

const PendingQueueTestState = struct {
    steering_poll_count: usize = 0,
    follow_up_poll_count: usize = 0,
};

fn drainSteeringForTest(
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
) ![]types.AgentMessage {
    const state: *PendingQueueTestState = @ptrCast(@alignCast(context.?));
    state.steering_poll_count += 1;
    if (state.steering_poll_count == 2) {
        const messages = try allocator.alloc(types.AgentMessage, 1);
        messages[0] = createUserMessage("steer now", 2);
        return messages;
    }
    return try allocator.alloc(types.AgentMessage, 0);
}

fn drainFollowUpsForTest(
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
) ![]types.AgentMessage {
    const state: *PendingQueueTestState = @ptrCast(@alignCast(context.?));
    state.follow_up_poll_count += 1;
    if (state.follow_up_poll_count == 1) {
        const messages = try allocator.alloc(types.AgentMessage, 1);
        messages[0] = createUserMessage("follow up", 2);
        return messages;
    }
    return try allocator.alloc(types.AgentMessage, 0);
}

fn drainNoMessages(
    allocator: std.mem.Allocator,
    _: ?*anyopaque,
) ![]types.AgentMessage {
    return try allocator.alloc(types.AgentMessage, 0);
}

fn steeringQueueFactory(
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
            blocks[0] = faux.fauxText("first reply");
            return faux.fauxAssistantMessage(blocks, .{});
        },
        2 => {
            try std.testing.expectEqual(@as(usize, 3), context.messages.len);
            try expectUserText(context.messages[0], "hello");
            try std.testing.expectEqualStrings("first reply", context.messages[1].assistant.content[0].text.text);
            try expectUserText(context.messages[2], "steer now");
            const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
            blocks[0] = faux.fauxText("after steer");
            return faux.fauxAssistantMessage(blocks, .{});
        },
        else => return error.UnexpectedFactoryCallCount,
    }
}

fn followUpQueueFactory(
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
            blocks[0] = faux.fauxText("first reply");
            return faux.fauxAssistantMessage(blocks, .{});
        },
        2 => {
            try std.testing.expectEqual(@as(usize, 3), context.messages.len);
            try expectUserText(context.messages[0], "hello");
            try std.testing.expectEqualStrings("first reply", context.messages[1].assistant.content[0].text.text);
            try expectUserText(context.messages[2], "follow up");
            const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
            blocks[0] = faux.fauxText("after follow up");
            return faux.fauxAssistantMessage(blocks, .{});
        },
        else => return error.UnexpectedFactoryCallCount,
    }
}

test "runAgentLoop injects steering messages before the next LLM call" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = steeringQueueFactory },
        .{ .factory = steeringQueueFactory },
    });

    var queue_state = PendingQueueTestState{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
            .get_steering_messages_context = &queue_state,
            .get_steering_messages = drainSteeringForTest,
        },
        null,
        ignoreEvent,
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try expectUserText(result[0], "hello");
    try std.testing.expectEqualStrings("first reply", result[1].assistant.content[0].text.text);
    try expectUserText(result[2], "steer now");
    try std.testing.expectEqualStrings("after steer", result[3].assistant.content[0].text.text);
}

test "runAgentLoop processes follow-up messages only after the agent would otherwise stop" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = followUpQueueFactory },
        .{ .factory = followUpQueueFactory },
    });

    var queue_state = PendingQueueTestState{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
            .get_steering_messages_context = &queue_state,
            .get_steering_messages = drainNoMessages,
            .get_follow_up_messages_context = &queue_state,
            .get_follow_up_messages = drainFollowUpsForTest,
        },
        null,
        ignoreEvent,
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try expectUserText(result[0], "hello");
    try std.testing.expectEqualStrings("first reply", result[1].assistant.content[0].text.text);
    try expectUserText(result[2], "follow up");
    try std.testing.expectEqualStrings("after follow up", result[3].assistant.content[0].text.text);
}

fn buildToolCallAssistantMessage(
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    value: []const u8,
) !ai.providers.faux.FauxAssistantMessage {
    const args = try jsonStringObject(allocator, "value", value);
    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = try ai.providers.faux.fauxToolCall(allocator, name, args, .{ .id = id });
    return ai.providers.faux.fauxAssistantMessage(blocks, .{
        .stop_reason = .tool_use,
    });
}

test "runAgentLoop executes a single tool call and appends the tool result to the transcript" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const second_blocks = [_]faux.FauxContentBlock{faux.fauxText("done")};
    const responses = [_]faux.FauxResponseStep{
        .{ .message = try buildToolCallAssistantMessage(arena.allocator(), "tool-1", "echo", "hello") },
        .{ .message = faux.fauxAssistantMessage(second_blocks[0..], .{}) },
    };
    try registration.setResponses(responses[0..]);

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const start_ms = types.nowMilliseconds();
    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("hello", result[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("echo", result[2].tool_result.tool_name);
    try std.testing.expectEqualStrings("echoed: hello", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("done", result[3].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), fixture.execute_count);
    const end_ms = types.nowMilliseconds();
    try std.testing.expect(result[2].tool_result.timestamp > 0);
    try std.testing.expect(result[2].tool_result.timestamp >= start_ms - 2000);
    try std.testing.expect(result[2].tool_result.timestamp <= end_ms + 2000);

    var saw_tool_start = false;
    var saw_tool_end = false;
    for (capture.events.items) |event| {
        if (event.event_type == .tool_execution_start) saw_tool_start = true;
        if (event.event_type == .tool_execution_end) saw_tool_end = true;
    }
    try std.testing.expect(saw_tool_start);
    try std.testing.expect(saw_tool_end);
}

test "ISS-405 tool execution and result messages follow assistant message_end" {
    const model = ai.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:tool-ordering",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "bash",
        .description = "Echo command",
        .label = "Bash",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };
    var stream_context = ReentrantOuterStreamContext{};
    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = model,
            .convert_to_llm = defaultConvertToLlmForTest,
            .stream_context = &stream_context,
            .tool_execution = .sequential,
        },
        &capture,
        captureToolEvent,
        null,
        reentrantOuterStreamForAgentLoopTest,
    );

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("tool-1", result[2].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("streamed response", result[3].assistant.content[0].text.text);

    var assistant_end_index: ?usize = null;
    var last_update_index: ?usize = null;
    var tool_start_index: ?usize = null;
    var tool_end_index: ?usize = null;
    var tool_result_message_index: ?usize = null;

    for (capture.events.items, 0..) |event, index| {
        switch (event.event_type) {
            .message_update => last_update_index = index,
            .message_end => {
                if (event.message) |message| switch (message) {
                    .assistant => |assistant| {
                        if (assistant.stop_reason == .tool_use and assistant_end_index == null) {
                            assistant_end_index = index;
                        }
                    },
                    .tool_result => if (tool_result_message_index == null) {
                        tool_result_message_index = index;
                    },
                    else => {},
                };
            },
            .tool_execution_start => {
                if (tool_start_index == null) tool_start_index = index;
            },
            .tool_execution_end => {
                if (tool_end_index == null) tool_end_index = index;
            },
            else => {},
        }
    }

    try std.testing.expect(last_update_index != null);
    try std.testing.expect(assistant_end_index != null);
    try std.testing.expect(tool_start_index != null);
    try std.testing.expect(tool_end_index != null);
    try std.testing.expect(tool_result_message_index != null);
    try std.testing.expect(last_update_index.? < assistant_end_index.?);
    try std.testing.expect(assistant_end_index.? < tool_start_index.?);
    try std.testing.expect(tool_start_index.? < tool_end_index.?);
    try std.testing.expect(tool_end_index.? < tool_result_message_index.?);
}

test "ISS-408 nested agent loop does not corrupt outer streaming state" {
    const model = ai.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:reentrant-outer",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tool_context = ReentrantToolContext{};
    const tool = types.AgentTool{
        .name = "bash",
        .description = "Runs a nested agent loop",
        .label = "Nested",
        .parameters = .null,
        .execute_context = &tool_context,
        .execute = reentrantToolExecute,
    };
    var stream_context = ReentrantOuterStreamContext{};

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = model,
            .convert_to_llm = defaultConvertToLlmForTest,
            .stream_context = &stream_context,
            .tool_execution = .sequential,
        },
        null,
        ignoreEvent,
        null,
        reentrantOuterStreamForAgentLoopTest,
    );

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("tool-1", result[2].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("nested: streamed response", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("streamed response", result[3].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 2), stream_context.call_count);
    try std.testing.expect(tool_context.nested_event_count > 0);
}

test "runAgentLoop sends fallback tool arguments through normal validation" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const empty_args = try std.json.ObjectMap.init(arena.allocator(), &.{}, &.{});
    const blocks = try arena.allocator().alloc(faux.FauxContentBlock, 1);
    blocks[0] = try faux.fauxToolCall(
        arena.allocator(),
        "echo",
        .{ .object = empty_args },
        .{ .id = "tool-1" },
    );
    const response = faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use });
    const done_blocks = [_]faux.FauxContentBlock{faux.fauxText("done")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = response },
        .{ .message = faux.fauxAssistantMessage(done_blocks[0..], .{}) },
    });

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .prepare_arguments = requireValuePrepareArguments,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
        null,
    );
    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("echo", result[2].tool_result.tool_name);
    try std.testing.expect(result[2].tool_result.is_error);
    try std.testing.expectEqualStrings("InvalidToolArguments", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("done", result[3].assistant.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 0), fixture.execute_count);
}

test "streamAssistantResponse frees owned streaming deltas after consumption" {
    const model = ai.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:owned-delta",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    const assistant = try streaming.streamAssistantResponse(
        std.testing.allocator,
        std.Io.failing,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = model,
            .convert_to_llm = passthroughConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
        ownedDeltaStreamForAgentLoopTest,
    );
    defer ai.types.freeAssistantMessage(std.testing.allocator, assistant);

    try std.testing.expectEqualStrings("streamed response", assistant.content[0].text.text);
}

test "route-a m1 streamAssistantResponse emits toolcall message updates" {
    const model = ai.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:toolcall-stream",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const assistant = try streaming.streamAssistantResponse(
        std.testing.allocator,
        std.Io.failing,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = model,
            .convert_to_llm = passthroughConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        toolCallStreamForAgentLoopTest,
    );
    defer ai.types.freeAssistantMessage(std.testing.allocator, assistant);

    try std.testing.expectEqual(@as(usize, 1), assistant.tool_calls.?.len);
    try std.testing.expectEqual(@as(usize, 1), assistant.content.len);
    try std.testing.expect(assistant.content[0] == .tool_call);
    try std.testing.expectEqualStrings("tool-1", assistant.content[0].tool_call.id);
    const expected = [_]ai.EventType{ .toolcall_start, .toolcall_delta, .toolcall_end };
    var next_expected: usize = 0;
    for (capture.events.items) |event| {
        if (event.event_type != .message_update) continue;
        const assistant_event = event.assistant_message_event orelse continue;
        if (assistant_event.event_type == .toolcall_start or
            assistant_event.event_type == .toolcall_delta or
            assistant_event.event_type == .toolcall_end)
        {
            try std.testing.expect(next_expected < expected.len);
            try std.testing.expectEqual(expected[next_expected], assistant_event.event_type);
            next_expected += 1;
        }
    }
    try std.testing.expectEqual(expected.len, next_expected);
}

test "VAL-CROSS-004 streamAssistantResponse accumulates ordered partial content while tool JSON repairs" {
    const model = ai.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:cross-partials",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var capture = PartialUpdateCrossCapture{};
    const assistant = try streaming.streamAssistantResponse(
        std.testing.allocator,
        std.Io.failing,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = model,
            .convert_to_llm = passthroughConvertToLlmForTest,
        },
        &capture,
        capturePartialUpdateCrossEvent,
        null,
        crossPartialUpdateStreamForAgentLoopTest,
    );
    defer ai.types.freeAssistantMessage(std.testing.allocator, assistant);

    try std.testing.expect(capture.saw_thinking_delta);
    try std.testing.expect(capture.saw_thinking_end);
    try std.testing.expect(capture.saw_text_delta);
    try std.testing.expect(capture.saw_toolcall_delta);
    try std.testing.expect(capture.saw_toolcall_end);
    try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
    try std.testing.expectEqualStrings("plan first", assistant.content[0].thinking.thinking);
    try std.testing.expectEqualStrings("prior text", assistant.content[1].text.text);
    try std.testing.expectEqualStrings("partial", assistant.content[2].tool_call.arguments.object.get("query").?.string);
}

test "VAL-REVIEW-M8-001 streaming message_update snapshots cover partial tool-call UX policy" {
    const model = ai.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:partial-tool-ux-snapshots",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var capture = StreamingUpdateSnapshotCapture.init(std.testing.allocator);
    defer capture.deinit();

    const assistant = try streaming.streamAssistantResponse(
        std.testing.allocator,
        std.Io.failing,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = model,
            .convert_to_llm = passthroughConvertToLlmForTest,
        },
        &capture,
        captureStreamingUpdateSnapshotEvent,
        null,
        crossPartialUpdateStreamForAgentLoopTest,
    );
    defer ai.types.freeAssistantMessage(std.testing.allocator, assistant);

    const expected = [_][]const u8{
        "event=thinking_start|index=0|message=[thinking:]",
        "event=thinking_delta|index=0|delta=plan |message=[thinking:plan ]",
        "event=thinking_delta|index=0|delta=first|message=[thinking:plan first]",
        "event=thinking_end|index=0|content=plan first|message=[thinking:plan first]",
        "event=text_start|index=1|message=[thinking:plan first,text:]",
        "event=text_delta|index=1|delta=prior |message=[thinking:plan first,text:prior ]",
        "event=text_delta|index=1|delta=text|message=[thinking:plan first,text:prior text]",
        "event=text_end|index=1|content=prior text|message=[thinking:plan first,text:prior text]",
        "event=toolcall_start|index=2|message=[thinking:plan first,text:prior text,toolCall:id=,name=,args={}]",
        "event=toolcall_delta|index=2|delta={\"query\":\"par|message=[thinking:plan first,text:prior text,toolCall:id=,name=,args={\"query\":\"par\"}]",
        "event=toolcall_end|index=2|eventToolCall=id=call_1,name=lookup,args={\"query\":\"partial\"}|message=[thinking:plan first,text:prior text,toolCall:id=call_1,name=lookup,args={\"query\":\"partial\"}]",
    };

    try std.testing.expectEqual(expected.len, capture.snapshots.items.len);
    for (expected, capture.snapshots.items) |expected_snapshot, actual_snapshot| {
        try std.testing.expectEqualStrings(expected_snapshot, actual_snapshot);
    }

    try std.testing.expectEqual(@as(usize, 3), assistant.content.len);
    try std.testing.expectEqualStrings("partial", assistant.content[2].tool_call.arguments.object.get("query").?.string);
}

test "VAL-CROSS-004 partial tool-call malformed arguments fall back to empty object" {
    const model = ai.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:malformed-partial-args",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var capture = MalformedPartialArgsCapture{};
    const assistant = try streaming.streamAssistantResponse(
        std.testing.allocator,
        std.Io.failing,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = model,
            .convert_to_llm = passthroughConvertToLlmForTest,
        },
        &capture,
        captureMalformedPartialArgsEvent,
        null,
        malformedPartialToolCallStreamForAgentLoopTest,
    );
    defer ai.types.freeAssistantMessage(std.testing.allocator, assistant);

    try std.testing.expect(capture.saw_malformed_toolcall_delta);
    try std.testing.expectEqual(@as(usize, 2), assistant.content.len);
    try std.testing.expectEqualStrings("call_bad_args", assistant.content[1].tool_call.id);
    try std.testing.expectEqual(@as(usize, 0), assistant.content[1].tool_call.arguments.object.count());
}

test "ISS-401 aborted stream cleans partial accumulator tool state" {
    const model = ai.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:partial-abort-cleanup",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var aborted = std.atomic.Value(bool).init(false);
    var capture = MessageUpdateCountCapture{};
    const assistant = try streaming.streamAssistantResponse(
        std.testing.allocator,
        std.Io.failing,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &.{},
        },
        .{
            .model = model,
            .convert_to_llm = passthroughConvertToLlmForTest,
        },
        &capture,
        countMessageUpdateEvent,
        &aborted,
        abortedPartialToolCallStreamForAgentLoopTest,
    );

    try std.testing.expect(aborted.load(.seq_cst));
    try std.testing.expectEqual(ai.StopReason.aborted, assistant.stop_reason);
    try std.testing.expectEqualStrings("Request was aborted", assistant.error_message.?);
    try std.testing.expectEqual(@as(usize, 5), capture.message_update_count);
    try std.testing.expectEqual(@as(usize, 1), capture.message_end_count);
}

test "ISS-401 runtime error stream cleans partial tool state and skips terminal tool calls" {
    const model = ai.Model{
        .id = "recording-model",
        .name = "Recording Model",
        .api = "recording:test:partial-runtime-error-cleanup",
        .provider = "recording",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = model,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        runtimeErrorToolCallStreamForAgentLoopTest,
    );

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(ai.StopReason.error_reason, result[1].assistant.stop_reason);
    try std.testing.expectEqualStrings("ProviderParseFailure", result[1].assistant.error_message.?);
    try std.testing.expectEqualStrings("partial before runtime error", result[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("runtime-error-terminal", result[1].assistant.content[1].tool_call.id);
    try std.testing.expectEqual(@as(usize, 0), fixture.execute_count);

    var terminal_assistant_messages: usize = 0;
    var turn_end_count: usize = 0;
    var agent_end_count: usize = 0;
    for (capture.events.items) |event| {
        try std.testing.expect(event.event_type != .tool_execution_start);
        try std.testing.expect(event.event_type != .tool_execution_end);
        switch (event.event_type) {
            .message_end => if (event.message) |message| switch (message) {
                .assistant => |assistant| {
                    if (assistant.stop_reason == .error_reason) terminal_assistant_messages += 1;
                },
                else => {},
            },
            .turn_end => turn_end_count += 1,
            .agent_end => agent_end_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), terminal_assistant_messages);
    try std.testing.expectEqual(@as(usize, 1), turn_end_count);
    try std.testing.expectEqual(@as(usize, 1), agent_end_count);
}

test "ISS-403 cloneToolCall retainers deinit replacement and cloned content" {
    const allocator = std.testing.allocator;

    var partial_tool_call = accumulator.PartialToolCallBlock{};
    try partial_tool_call.setFinal(allocator, .{
        .id = "first-tool",
        .name = "lookup",
        .arguments = .{ .string = "first args" },
        .thought_signature = "first signature",
    });
    try std.testing.expectEqualStrings("first-tool", partial_tool_call.final_tool_call.?.id);

    try partial_tool_call.setFinal(allocator, .{
        .id = "second-tool",
        .name = "lookup",
        .arguments = .{ .string = "second args" },
        .thought_signature = "second signature",
    });
    try std.testing.expectEqualStrings("second-tool", partial_tool_call.final_tool_call.?.id);
    try std.testing.expectEqualStrings("second args", partial_tool_call.final_tool_call.?.arguments.string);
    partial_tool_call.deinit(allocator);

    const source = [_]ai.ContentBlock{.{ .tool_call = .{
        .id = "content-tool",
        .name = "lookup",
        .arguments = .{ .string = "content args" },
        .thought_signature = "content signature",
    } }};

    const cloned = try content_clone.cloneContentBlocks(allocator, source[0..]);
    defer {
        content_clone.deinitContentBlocks(allocator, cloned);
        allocator.free(cloned);
    }

    try std.testing.expectEqual(@as(usize, 1), cloned.len);
    try std.testing.expect(cloned[0] == .tool_call);
    try std.testing.expectEqualStrings("content-tool", cloned[0].tool_call.id);
    try std.testing.expectEqualStrings("lookup", cloned[0].tool_call.name);
    try std.testing.expectEqualStrings("content args", cloned[0].tool_call.arguments.string);
    try std.testing.expectEqualStrings("content signature", cloned[0].tool_call.thought_signature.?);
    try std.testing.expect(cloned[0].tool_call.id.ptr != source[0].tool_call.id.ptr);
    try std.testing.expect(cloned[0].tool_call.name.ptr != source[0].tool_call.name.ptr);
    try std.testing.expect(cloned[0].tool_call.arguments.string.ptr != source[0].tool_call.arguments.string.ptr);
    try std.testing.expect(cloned[0].tool_call.thought_signature.?.ptr != source[0].tool_call.thought_signature.?.ptr);
}

fn checkCloneToolCallAllocation(allocator: std.mem.Allocator, source: ai.ToolCall) !void {
    const cloned = try content_clone.cloneToolCall(allocator, source);
    defer content_clone.deinitToolCall(allocator, cloned);
}

fn checkCloneContentBlocksAllocation(allocator: std.mem.Allocator, source: []const ai.ContentBlock) !void {
    const cloned = try content_clone.cloneContentBlocks(allocator, source);
    defer {
        content_clone.deinitContentBlocks(allocator, cloned);
        allocator.free(cloned);
    }
}

test "ISS-403 accumulator.PartialToolCallBlock keeps existing final tool call on replacement allocation failure" {
    const allocator = std.testing.allocator;

    var partial_tool_call = accumulator.PartialToolCallBlock{};
    defer partial_tool_call.deinit(allocator);

    try partial_tool_call.setFinal(allocator, .{
        .id = "stable-tool",
        .name = "lookup",
        .arguments = .{ .string = "stable args" },
        .thought_signature = "stable signature",
    });

    var fail_index: usize = 0;
    while (fail_index < 4) : (fail_index += 1) {
        var failing_state = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_state.allocator();

        try std.testing.expectError(
            error.OutOfMemory,
            partial_tool_call.setFinal(failing_allocator, .{
                .id = "replacement-tool",
                .name = "lookup",
                .arguments = .{ .string = "replacement args" },
                .thought_signature = "replacement signature",
            }),
        );

        try std.testing.expectEqualStrings("stable-tool", partial_tool_call.final_tool_call.?.id);
        try std.testing.expectEqualStrings("lookup", partial_tool_call.final_tool_call.?.name);
        try std.testing.expectEqualStrings("stable args", partial_tool_call.final_tool_call.?.arguments.string);
        try std.testing.expectEqualStrings("stable signature", partial_tool_call.final_tool_call.?.thought_signature.?);
    }
}

test "ISS-403 cloneToolCall allocation failures clean partial clones" {
    const allocator = std.testing.allocator;

    const source_args = try jsonStringObject(allocator, "query", "owned source");
    defer provider_json.freeValue(allocator, source_args);

    const source = ai.ToolCall{
        .id = "tool-with-owned-args",
        .name = "lookup",
        .arguments = source_args,
        .thought_signature = "signature",
    };
    try std.testing.checkAllAllocationFailures(allocator, checkCloneToolCallAllocation, .{source});

    var array_args = std.json.Array.init(allocator);
    defer array_args.deinit();
    try array_args.append(.{ .string = "array argument" });
    try array_args.append(.{ .number_string = "123" });

    const array_source = ai.ToolCall{
        .id = "tool-with-array-args",
        .name = "lookup",
        .arguments = .{ .array = array_args },
        .thought_signature = "signature",
    };
    try std.testing.checkAllAllocationFailures(allocator, checkCloneToolCallAllocation, .{array_source});
}

test "ISS-403 cloneContentBlocks allocation failures unwind owned blocks once" {
    const allocator = std.testing.allocator;

    const tool_args = try jsonStringObject(allocator, "query", "content tool args");
    defer provider_json.freeValue(allocator, tool_args);

    const source = [_]ai.ContentBlock{
        .{ .text = .{
            .text = "text body",
            .text_signature = "text signature",
        } },
        .{ .image = .{
            .data = "base64-image",
            .mime_type = "image/png",
        } },
        .{ .thinking = .{
            .thinking = "thinking body",
            .thinking_signature = "thinking signature",
            .redacted = false,
        } },
        .{ .tool_call = .{
            .id = "content-tool",
            .name = "lookup",
            .arguments = tool_args,
            .thought_signature = "tool signature",
        } },
    };

    try std.testing.checkAllAllocationFailures(allocator, checkCloneContentBlocksAllocation, .{source[0..]});
}

test "ISS-406 partial accumulator rejects stale explicit content_index reuse after end" {
    var partial_accumulator = accumulator.PartialAssistantAccumulator.init(std.testing.allocator);
    defer partial_accumulator.deinit();

    try partial_accumulator.applyEvent(.{ .event_type = .text_start, .content_index = 0 });
    try partial_accumulator.applyEvent(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = "draft",
    });
    try partial_accumulator.applyEvent(.{
        .event_type = .text_end,
        .content_index = 0,
        .content = "final text",
    });

    try std.testing.expectError(
        AgentLoopError.PartialContentIndexReused,
        partial_accumulator.applyEvent(.{
            .event_type = .text_delta,
            .content_index = 0,
            .delta = " stale delta",
        }),
    );
    try std.testing.expectError(
        AgentLoopError.PartialContentIndexReused,
        partial_accumulator.applyEvent(.{ .event_type = .text_start, .content_index = 0 }),
    );

    const template = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
        .api = "recording:test:partial-index-reuse",
        .provider = "recording",
        .model = "recording-model",
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const partial_message = try partial_accumulator.buildMessage(arena.allocator(), template);
    try std.testing.expectEqual(@as(usize, 1), partial_message.content.len);
    try std.testing.expect(partial_message.content[0] == .text);
    try std.testing.expectEqualStrings("final text", partial_message.content[0].text.text);
}

test "ISS-400 partial accumulator rejects explicit deltas before start" {
    var partial_accumulator = accumulator.PartialAssistantAccumulator.init(std.testing.allocator);
    defer partial_accumulator.deinit();

    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{
            .event_type = .text_delta,
            .content_index = 0,
            .delta = "orphan text",
        }),
    );
    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{
            .event_type = .thinking_delta,
            .content_index = 1,
            .delta = "orphan thinking",
        }),
    );
    try std.testing.expectError(
        AgentLoopError.PartialContentOutOfOrder,
        partial_accumulator.applyEvent(.{
            .event_type = .toolcall_delta,
            .content_index = 2,
            .delta = "{\"value\":\"orphan\"}",
        }),
    );

    // Sparse starts remain valid: the policy rejects non-start events for an
    // unmapped explicit provider index, not sparse provider content indices.
    try partial_accumulator.applyEvent(.{ .event_type = .text_start, .content_index = 3 });
    try partial_accumulator.applyEvent(.{
        .event_type = .text_delta,
        .content_index = 3,
        .delta = "mapped text",
    });
    try partial_accumulator.applyEvent(.{
        .event_type = .text_end,
        .content_index = 3,
        .content = "mapped text",
    });

    const template = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
        .api = "recording:test:partial-out-of-order",
        .provider = "recording",
        .model = "recording-model",
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const partial_message = try partial_accumulator.buildMessage(arena.allocator(), template);
    try std.testing.expectEqual(@as(usize, 1), partial_message.content.len);
    try std.testing.expectEqualStrings("mapped text", partial_message.content[0].text.text);
}

test "VAL-REVIEW-M7-001 finalized tool call rejects double finalization" {
    const args = try jsonStringObject(std.testing.allocator, "value", "once");
    var prepared = tool_execution.PreparedToolCall{
        .tool_call = .{
            .id = "tool-double-finalize",
            .name = "echo",
            .arguments = .null,
        },
        .tool = .{
            .name = "echo",
            .description = "Echo input",
            .label = "Echo",
            .parameters = .null,
        },
        .args = args,
    };
    defer prepared.deinit(std.testing.allocator);

    const content = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    content[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, "already executed") } };
    const executed = tool_execution.ExecutedToolCallOutcome{
        .result = .{
            .content = content,
            .details = null,
        },
        .is_error = false,
    };
    defer {
        std.testing.allocator.free(content[0].text.text);
        std.testing.allocator.free(content);
    }

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const assistant_message = ai.AssistantMessage{
        .content = &.{},
        .api = "faux",
        .provider = "faux",
        .model = "faux-model",
        .usage = ai.Usage.init(),
        .stop_reason = .tool_use,
        .timestamp = 1,
    };
    const context = types.AgentContext{
        .system_prompt = "",
        .messages = &.{},
        .tools = &.{prepared.tool},
    };
    const config = types.AgentLoopConfig{
        .model = .{
            .id = "faux-model",
            .name = "Faux Model",
            .api = "faux",
            .provider = "faux",
            .base_url = "http://localhost",
            .input_types = &[_][]const u8{"text"},
            .context_window = 1024,
            .max_tokens = 256,
        },
        .convert_to_llm = defaultConvertToLlmForTest,
    };

    const finalized = try tool_execution.finalizeExecutedToolCall(
        std.testing.allocator,
        context,
        assistant_message,
        &prepared,
        executed,
        false,
        config,
        &capture,
        captureToolEvent,
        null,
    );
    try std.testing.expectEqualStrings("already executed", finalized.result.content[0].text.text);
    try std.testing.expect(!finalized.is_error);
    try std.testing.expect(prepared.finalized);

    try std.testing.expectError(
        AgentLoopError.ToolCallAlreadyFinalized,
        tool_execution.finalizeExecutedToolCall(
            std.testing.allocator,
            context,
            assistant_message,
            &prepared,
            executed,
            false,
            config,
            &capture,
            captureToolEvent,
            null,
        ),
    );

    var end_count: usize = 0;
    for (capture.events.items) |event| {
        if (event.event_type == .tool_execution_end) {
            end_count += 1;
            try std.testing.expectEqualStrings("tool-double-finalize", event.tool_call_id.?);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), end_count);
}

test "ISS-401 ISS-407 message_update payload is callback-scoped and retained consumers clone" {
    var partial_accumulator = accumulator.PartialAssistantAccumulator.init(std.testing.allocator);
    defer partial_accumulator.deinit();

    try partial_accumulator.applyEvent(.{ .event_type = .text_start, .content_index = 0 });
    try partial_accumulator.applyEvent(.{
        .event_type = .text_delta,
        .content_index = 0,
        .delta = "borrowed update",
    });

    const template = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
        .api = "recording:test:update-lifetime",
        .provider = "recording",
        .model = "recording-model",
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1,
    };

    var temp_buffer: [4096]u8 = undefined;
    var temp_allocator = std.heap.FixedBufferAllocator.init(&temp_buffer);
    const partial_message = try partial_accumulator.buildMessage(temp_allocator.allocator(), template);

    try std.testing.expectEqual(@as(usize, 1), partial_message.content.len);
    try std.testing.expect(partial_message.content[0] == .text);
    try std.testing.expectEqualStrings("borrowed update", partial_message.content[0].text.text);

    const temp_start = @intFromPtr(&temp_buffer[0]);
    const temp_end = temp_start + temp_buffer.len;
    const content_ptr = @intFromPtr(partial_message.content.ptr);
    try std.testing.expect(content_ptr >= temp_start);
    try std.testing.expect(content_ptr < temp_end);

    const borrowed_text_ptr = partial_message.content[0].text.text.ptr;
    const retained_content = try content_clone.cloneContentBlocks(std.testing.allocator, partial_message.content);
    defer {
        content_clone.deinitContentBlocks(std.testing.allocator, retained_content);
        std.testing.allocator.free(retained_content);
    }

    try std.testing.expect(retained_content.ptr != partial_message.content.ptr);
    try std.testing.expect(retained_content[0] == .text);
    try std.testing.expect(retained_content[0].text.text.ptr != borrowed_text_ptr);

    @memset(temp_buffer[0..], 0xa5);

    try std.testing.expectEqualStrings("borrowed update", retained_content[0].text.text);
}

test "ISS-401 VAL-CROSS-002 terminal error with partial tool call suppresses tool execution" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = try jsonStringObject(arena.allocator(), "value", "should-not-run");
    const blocks = try arena.allocator().alloc(faux.FauxContentBlock, 2);
    blocks[0] = faux.fauxText("partial before error");
    blocks[1] = try faux.fauxToolCall(arena.allocator(), "echo", args, .{ .id = "tool-error-1" });
    const response = faux.fauxAssistantMessage(blocks, .{
        .stop_reason = .error_reason,
        .error_message = "provider failed after tool call",
        .response_id = "resp_error_partial",
    });
    try registration.setResponses(&[_]faux.FauxResponseStep{.{ .message = response }});

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(ai.StopReason.error_reason, result[1].assistant.stop_reason);
    try std.testing.expectEqualStrings("resp_error_partial", result[1].assistant.response_id.?);
    try std.testing.expectEqualStrings("partial before error", result[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("tool-error-1", result[1].assistant.content[1].tool_call.id);
    try std.testing.expectEqual(@as(usize, 0), fixture.execute_count);

    for (capture.events.items) |event| {
        try std.testing.expect(event.event_type != .tool_execution_start);
        try std.testing.expect(event.event_type != .tool_execution_end);
    }
}

test "ISS-401 VAL-CROSS-002 terminal abort with partial tool call suppresses tool execution" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const args = try jsonStringObject(arena.allocator(), "value", "should-not-run");
    const blocks = try arena.allocator().alloc(faux.FauxContentBlock, 2);
    blocks[0] = faux.fauxText("partial before abort");
    blocks[1] = try faux.fauxToolCall(arena.allocator(), "echo", args, .{ .id = "tool-abort-1" });
    const response = faux.fauxAssistantMessage(blocks, .{
        .stop_reason = .aborted,
        .error_message = "Request was aborted",
        .response_id = "resp_abort_partial",
    });
    try registration.setResponses(&[_]faux.FauxResponseStep{.{ .message = response }});

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqual(ai.StopReason.aborted, result[1].assistant.stop_reason);
    try std.testing.expectEqualStrings("resp_abort_partial", result[1].assistant.response_id.?);
    try std.testing.expectEqualStrings("partial before abort", result[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("tool-abort-1", result[1].assistant.content[1].tool_call.id);
    try std.testing.expectEqual(@as(usize, 0), fixture.execute_count);
}

test "VAL-CROSS-003 interleaved repaired and fallback tool calls execute exactly once" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const first_parsed = try ai.json_parse.parseStreamingJson(arena.allocator(), "{\"value\":\"first");
    const fallback_args = try std.json.ObjectMap.init(arena.allocator(), &.{}, &.{});
    const blocks = try arena.allocator().alloc(faux.FauxContentBlock, 2);
    blocks[0] = try faux.fauxToolCall(arena.allocator(), "echo", first_parsed.value, .{ .id = "tool-repaired" });
    blocks[1] = try faux.fauxToolCall(arena.allocator(), "optional", .{ .object = fallback_args }, .{ .id = "tool-fallback" });
    const first_response = faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use });
    const done_blocks = [_]faux.FauxContentBlock{faux.fauxText("done")};
    const second_response = faux.fauxAssistantMessage(done_blocks[0..], .{});
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = first_response },
        .{ .message = second_response },
    });

    const echo_fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(echo_fixture);
    echo_fixture.* = .{};
    const optional_fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(optional_fixture);
    optional_fixture.* = .{};

    const tools = [_]types.AgentTool{
        .{
            .name = "echo",
            .description = "Echo input",
            .label = "Echo",
            .parameters = .null,
            .execute_context = echo_fixture,
            .execute = countedEchoToolExecute,
        },
        .{
            .name = "optional",
            .description = "Accept fallback args",
            .label = "Optional",
            .parameters = .null,
            .execute_context = optional_fixture,
            .execute = countedEchoToolExecute,
        },
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = tools[0..],
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
            .tool_execution = .sequential,
        },
        null,
        ignoreEvent,
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 5), result.len);
    try std.testing.expectEqualStrings("tool-repaired", result[2].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("tool-fallback", result[3].tool_result.tool_call_id);
    try std.testing.expectEqual(@as(usize, 1), echo_fixture.execute_count);
    try std.testing.expectEqual(@as(usize, 1), optional_fixture.execute_count);
}

test "runAgentLoop executes multiple tool calls in parallel and emits tool results in source order" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const second_args = try jsonStringObject(arena.allocator(), "value", "second");
    const first_args = try jsonStringObject(arena.allocator(), "value", "first");
    const blocks = try arena.allocator().alloc(faux.FauxContentBlock, 2);
    blocks[0] = try faux.fauxToolCall(arena.allocator(), "echo", first_args, .{ .id = "tool-1" });
    blocks[1] = try faux.fauxToolCall(arena.allocator(), "echo", second_args, .{ .id = "tool-2" });
    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("done")};

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use }) },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    const observation = try std.testing.allocator.create(ParallelObservation);
    defer std.testing.allocator.destroy(observation);
    observation.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = observation,
        .execute = parallelAwareEchoToolExecute,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .tool_execution = .parallel,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        null,
    );

    try std.testing.expect(observation.parallel_observed.load(.seq_cst));
    try std.testing.expectEqualStrings("tool-1", result[2].tool_result.tool_call_id);
    try std.testing.expectEqualStrings("tool-2", result[3].tool_result.tool_call_id);

    var first_end_index: ?usize = null;
    var start_count: usize = 0;
    for (capture.events.items, 0..) |event, index| {
        if (event.event_type == .tool_execution_start) start_count += 1;
        if (event.event_type == .tool_execution_end and first_end_index == null) {
            first_end_index = index;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), start_count);
    try std.testing.expect(first_end_index != null);
    for (capture.events.items[0..first_end_index.?]) |event| {
        if (event.event_type == .tool_execution_end) {
            return error.UnexpectedToolExecutionEndOrder;
        }
    }
}

test "ISS-404 parallel after_tool_call finalizes in completion order and emits messages in source order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const first_args = try jsonStringObject(arena.allocator(), "value", "first");
    const second_args = try jsonStringObject(arena.allocator(), "value", "second");
    const tool_calls = try arena.allocator().alloc(ai.ToolCall, 2);
    tool_calls[0] = .{ .id = "tool-1", .name = "echo", .arguments = first_args };
    tool_calls[1] = .{ .id = "tool-2", .name = "echo", .arguments = second_args };

    var capture = ParallelHookOrderingCapture.init(std.testing.allocator);
    defer capture.deinit();

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = &capture,
        .execute = hookOrderingToolExecute,
    };

    const results = try tool_execution.executeToolCallsParallel(
        std.testing.allocator,
        std.testing.io,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .content = &.{},
            .api = "faux",
            .provider = "faux",
            .model = "faux-model",
            .usage = ai.Usage.init(),
            .stop_reason = .tool_use,
            .timestamp = 1,
        },
        tool_calls,
        .{
            .model = .{
                .id = "faux-model",
                .name = "Faux Model",
                .api = "faux",
                .provider = "faux",
                .base_url = "http://localhost",
                .input_types = &[_][]const u8{"text"},
                .context_window = 1024,
                .max_tokens = 256,
            },
            .tool_execution = .parallel,
            .after_tool_call = recordAfterToolCallOrder,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureParallelHookOrderingEvent,
        null,
    );
    defer {
        for (results) |result| {
            content_clone.deinitContentBlocks(std.testing.allocator, result.content);
            std.testing.allocator.free(result.content);
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expect(capture.second_observed_before_first_finished.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), capture.after_hook_order.items.len);
    try std.testing.expectEqualStrings("tool-2", capture.after_hook_order.items[0]);
    try std.testing.expectEqualStrings("tool-1", capture.after_hook_order.items[1]);
    try std.testing.expectEqual(@as(usize, 2), capture.tool_end_order.items.len);
    try std.testing.expectEqualStrings("tool-2", capture.tool_end_order.items[0]);
    try std.testing.expectEqualStrings("tool-1", capture.tool_end_order.items[1]);
    try std.testing.expectEqual(@as(usize, 2), capture.tool_message_order.items.len);
    try std.testing.expectEqualStrings("tool-1", capture.tool_message_order.items[0]);
    try std.testing.expectEqualStrings("tool-2", capture.tool_message_order.items[1]);
    try std.testing.expectEqualStrings("tool-1", results[0].tool_call_id);
    try std.testing.expectEqualStrings("tool-2", results[1].tool_call_id);
}

test "ISS-401 executeToolCallsParallel returns tool result content that survives task arena cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tool_args = try jsonStringObject(arena.allocator(), "value", "hello");
    const tool_calls = try arena.allocator().alloc(ai.ToolCall, 1);
    tool_calls[0] = .{
        .id = "tool-1",
        .name = "echo",
        .arguments = tool_args,
    };

    const fixture = try std.testing.allocator.create(ToolResultContentCaptureFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = capturingEchoToolExecute,
    };

    const results = try tool_execution.executeToolCallsParallel(
        std.testing.allocator,
        std.testing.io,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .content = &.{},
            .api = "faux",
            .provider = "faux",
            .model = "faux-model",
            .usage = ai.Usage.init(),
            .stop_reason = .tool_use,
            .timestamp = 1,
        },
        tool_calls,
        .{
            .model = .{
                .id = "faux-model",
                .name = "Faux Model",
                .api = "faux",
                .provider = "faux",
                .base_url = "http://localhost",
                .input_types = &[_][]const u8{"text"},
                .context_window = 1024,
                .max_tokens = 256,
            },
            .tool_execution = .parallel,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
    );
    defer {
        for (results) |result| {
            content_clone.deinitContentBlocks(std.testing.allocator, result.content);
            std.testing.allocator.free(result.content);
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(fixture.capture.content_ptr != null);
    try std.testing.expect(fixture.capture.text_ptr != null);

    const scratch_blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    defer std.testing.allocator.free(scratch_blocks);
    const scratch_text = try std.testing.allocator.alloc(u8, fixture.capture.text_len);
    defer std.testing.allocator.free(scratch_text);
    @memset(scratch_text, 'x');
    scratch_blocks[0] = .{
        .text = .{
            .text = scratch_text,
        },
    };

    try std.testing.expect(results[0].content.ptr != fixture.capture.content_ptr.?);
    try std.testing.expect(results[0].content[0].text.text.ptr != fixture.capture.text_ptr.?);
    try std.testing.expectEqualStrings("echoed: hello", results[0].content[0].text.text);
}

test "route-a m1 parallel tool updates emit before join and only updates leave main thread" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const fast_args = try jsonStringObject(arena.allocator(), "value", "fast");
    const slow_args = try jsonStringObject(arena.allocator(), "value", "slow");
    const tool_calls = try arena.allocator().alloc(ai.ToolCall, 2);
    tool_calls[0] = .{ .id = "fast", .name = "stream", .arguments = fast_args };
    tool_calls[1] = .{ .id = "slow", .name = "stream", .arguments = slow_args };

    var capture = ParallelStreamingCapture{ .main_thread_id = std.Thread.getCurrentId() };
    const tool = types.AgentTool{
        .name = "stream",
        .description = "Streaming test tool",
        .label = "Stream",
        .parameters = .null,
        .execute_context = &capture,
        .execute = streamingParallelToolExecute,
    };

    const results = try tool_execution.executeToolCallsParallel(
        std.testing.allocator,
        std.testing.io,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .content = &.{},
            .api = "faux",
            .provider = "faux",
            .model = "faux-model",
            .usage = ai.Usage.init(),
            .stop_reason = .tool_use,
            .timestamp = 1,
        },
        tool_calls,
        .{
            .model = .{
                .id = "faux-model",
                .name = "Faux Model",
                .api = "faux",
                .provider = "faux",
                .base_url = "http://localhost",
                .input_types = &[_][]const u8{"text"},
                .context_window = 1024,
                .max_tokens = 256,
            },
            .tool_execution = .parallel,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureParallelStreamingEvent,
        null,
    );
    defer {
        for (results) |result| {
            content_clone.deinitContentBlocks(std.testing.allocator, result.content);
            std.testing.allocator.free(result.content);
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expect(capture.saw_fast_update_before_slow_done.load(.seq_cst));
    try std.testing.expect(capture.saw_update_off_main_thread.load(.seq_cst));
    try std.testing.expect(!capture.invalid_main_thread_event.load(.seq_cst));
}

test "route-a m1 parallel emitter serializes concurrent update callbacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tool_calls = try arena.allocator().alloc(ai.ToolCall, 4);
    for (tool_calls, 0..) |*tool_call, index| {
        tool_call.* = .{
            .id = try std.fmt.allocPrint(arena.allocator(), "tool-{d}", .{index}),
            .name = "stress",
            .arguments = .null,
        };
    }

    var capture = ParallelStreamingCapture{ .main_thread_id = std.Thread.getCurrentId() };
    const tool = types.AgentTool{
        .name = "stress",
        .description = "Stress streaming test tool",
        .label = "Stress",
        .parameters = .null,
        .execute_context = &capture,
        .execute = stressStreamingParallelToolExecute,
    };

    const results = try tool_execution.executeToolCallsParallel(
        std.testing.allocator,
        std.testing.io,
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .content = &.{},
            .api = "faux",
            .provider = "faux",
            .model = "faux-model",
            .usage = ai.Usage.init(),
            .stop_reason = .tool_use,
            .timestamp = 1,
        },
        tool_calls,
        .{
            .model = .{
                .id = "faux-model",
                .name = "Faux Model",
                .api = "faux",
                .provider = "faux",
                .base_url = "http://localhost",
                .input_types = &[_][]const u8{"text"},
                .context_window = 1024,
                .max_tokens = 256,
            },
            .tool_execution = .parallel,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureParallelStreamingEvent,
        null,
    );
    defer {
        for (results) |result| {
            content_clone.deinitContentBlocks(std.testing.allocator, result.content);
            std.testing.allocator.free(result.content);
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 4), results.len);
    try std.testing.expectEqual(@as(usize, 400), capture.update_count.load(.seq_cst));
    try std.testing.expect(!capture.concurrent_callback_entry.load(.seq_cst));
}

test "runAgentLoop executes tool calls sequentially when configured" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const first_args = try jsonStringObject(arena.allocator(), "value", "first");
    const second_args = try jsonStringObject(arena.allocator(), "value", "second");
    const blocks = try arena.allocator().alloc(faux.FauxContentBlock, 2);
    blocks[0] = try faux.fauxToolCall(arena.allocator(), "echo", first_args, .{ .id = "tool-1" });
    blocks[1] = try faux.fauxToolCall(arena.allocator(), "echo", second_args, .{ .id = "tool-2" });
    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("done")};

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use }) },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    const observation = try std.testing.allocator.create(ParallelObservation);
    defer std.testing.allocator.destroy(observation);
    observation.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = observation,
        .execute = parallelAwareEchoToolExecute,
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    _ = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .tool_execution = .sequential,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
        null,
    );

    try std.testing.expect(!observation.parallel_observed.load(.seq_cst));
}

test "runAgentLoop emits an error tool result and continues the conversation when a tool fails" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("handled failure")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = try buildToolCallAssistantMessage(arena.allocator(), "tool-1", "echo", "hello") },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Failing tool",
        .label = "Echo",
        .parameters = .null,
        .execute = failingToolExecute,
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
        null,
    );

    try std.testing.expect(result[2].tool_result.is_error);
    try std.testing.expectEqualStrings("ToolFailure", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("handled failure", result[3].assistant.content[0].text.text);
}

test "runAgentLoop lets beforeToolCall block execution" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("continued")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = try buildToolCallAssistantMessage(arena.allocator(), "tool-1", "echo", "hello") },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};
    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .before_tool_call = blockBeforeToolCall,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 0), fixture.execute_count);
    try std.testing.expect(result[2].tool_result.is_error);
    try std.testing.expectEqualStrings("blocked by hook", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("continued", result[3].assistant.content[0].text.text);
}

test "ISS-409 before_tool_call error skips execution and emits cleanup result" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("continued after hook error")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = try buildToolCallAssistantMessage(arena.allocator(), "tool-1", "echo", "hello") },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    const fixture = try std.testing.allocator.create(CountedToolFixture);
    defer std.testing.allocator.destroy(fixture);
    fixture.* = .{};

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute_context = fixture,
        .execute = countedEchoToolExecute,
    };

    var capture = ToolExecutionCapture.init(std.testing.allocator);
    defer capture.deinit();

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .before_tool_call = errorBeforeToolCall,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        &capture,
        captureToolEvent,
        null,
        null,
    );

    try std.testing.expectEqual(@as(usize, 0), fixture.execute_count);
    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expect(result[2].tool_result.is_error);
    try std.testing.expectEqualStrings("BeforeToolCallFailed", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("continued after hook error", result[3].assistant.content[0].text.text);

    var tool_start_count: usize = 0;
    var tool_end_count: usize = 0;
    var tool_result_message_count: usize = 0;
    for (capture.events.items) |event| {
        switch (event.event_type) {
            .tool_execution_start => tool_start_count += 1,
            .tool_execution_end => {
                tool_end_count += 1;
                try std.testing.expectEqual(true, event.is_error.?);
                try std.testing.expectEqualStrings("BeforeToolCallFailed", event.result.?.content[0].text.text);
            },
            .message_end => if (event.message) |message| switch (message) {
                .tool_result => |tool_result| {
                    tool_result_message_count += 1;
                    try std.testing.expect(tool_result.is_error);
                    try std.testing.expectEqualStrings("BeforeToolCallFailed", tool_result.content[0].text.text);
                },
                else => {},
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), tool_start_count);
    try std.testing.expectEqual(@as(usize, 1), tool_end_count);
    try std.testing.expectEqual(@as(usize, 1), tool_result_message_count);
}

test "runAgentLoop lets afterToolCall override the tool result before it enters the transcript" {
    const faux = ai.providers.faux;
    const registration = try faux.registerFauxProvider(std.testing.allocator, .{});
    defer registration.unregister();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const final_blocks = [_]faux.FauxContentBlock{faux.fauxText("done")};
    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = try buildToolCallAssistantMessage(arena.allocator(), "tool-1", "echo", "hello") },
        .{ .message = faux.fauxAssistantMessage(final_blocks[0..], .{}) },
    });

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute = echoToolExecute,
    };

    const prompts = [_]types.AgentMessage{createUserMessage("hello", 1)};
    const result = try runAgentLoop(
        arena.allocator(),
        std.Io.failing,
        prompts[0..],
        .{
            .system_prompt = "",
            .messages = &.{},
            .tools = &[_]types.AgentTool{tool},
        },
        .{
            .model = registration.getModel(),
            .after_tool_call = overrideAfterToolCall,
            .convert_to_llm = defaultConvertToLlmForTest,
        },
        null,
        ignoreEvent,
        null,
        null,
    );

    try std.testing.expectEqualStrings("modified by hook", result[2].tool_result.content[0].text.text);
    try std.testing.expect(!result[2].tool_result.is_error);
}
