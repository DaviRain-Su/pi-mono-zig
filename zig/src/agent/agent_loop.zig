const std = @import("std");
const ai = @import("ai");
const types = @import("types.zig");

pub const AgentLoopError = error{
    MissingAssistantResult,
};

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

    const assistant = try streamAssistantResponse(
        allocator,
        io,
        .{
            .system_prompt = context.system_prompt,
            .messages = current_messages.items,
            .tools = context.tools,
        },
        config,
        emit_context,
        emit,
        signal,
        stream_fn,
    );

    try current_messages.append(allocator, .{ .assistant = assistant });
    try new_messages.append(allocator, .{ .assistant = assistant });

    const empty_tool_results = [_]types.ToolResultMessage{};
    try emit(emit_context, .{
        .event_type = .turn_end,
        .message = .{ .assistant = assistant },
        .tool_results = empty_tool_results[0..],
    });
    try emit(emit_context, .{
        .event_type = .agent_end,
        .messages = new_messages.items,
    });

    return try allocator.dupe(types.AgentMessage, new_messages.items);
}

fn streamAssistantResponse(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: types.AgentContext,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
    stream_fn: ?types.StreamFn,
) !ai.AssistantMessage {
    const transformed_messages = if (config.transform_context) |transform|
        try transform(allocator, context.messages, signal)
    else
        context.messages;

    const llm_messages = try config.convert_to_llm(allocator, transformed_messages);

    const llm_tools = if (context.tools.len > 0)
        try convertToolsToLlm(allocator, context.tools)
    else
        null;

    const llm_context = ai.Context{
        .system_prompt = if (context.system_prompt.len > 0) context.system_prompt else null,
        .messages = llm_messages,
        .tools = llm_tools,
    };
    const options = ai.types.SimpleStreamOptions{
        .api_key = config.api_key,
        .session_id = config.session_id,
    };

    const active_stream_fn = stream_fn orelse ai.streamSimple;
    var stream = try active_stream_fn(allocator, io, config.model, llm_context, options);
    defer stream.deinit();

    var partial_template: ?ai.AssistantMessage = null;
    var partial_text = std.ArrayList(u8).empty;
    defer partial_text.deinit(allocator);
    var partial_content: [1]ai.ContentBlock = undefined;
    var has_text_block = false;
    var saw_message_start = false;

    while (stream.next()) |event| {
        switch (event.event_type) {
            .start => {
                if (event.message) |message| {
                    partial_template = message;
                    saw_message_start = true;
                    try emit(emit_context, .{
                        .event_type = .message_start,
                        .message = .{ .assistant = message },
                    });
                }
            },
            .text_start => {
                if (partial_template) |template| {
                    try partial_text.resize(allocator, 0);
                    partial_content[0] = .{ .text = .{ .text = "" } };
                    has_text_block = true;
                    try emitPartialMessageUpdate(
                        emit_context,
                        emit,
                        template,
                        event,
                        &partial_content,
                        has_text_block,
                    );
                }
            },
            .text_delta => {
                if (partial_template) |template| {
                    if (!has_text_block) {
                        partial_content[0] = .{ .text = .{ .text = "" } };
                        has_text_block = true;
                    }
                    if (event.delta) |delta| {
                        try partial_text.appendSlice(allocator, delta);
                    }
                    partial_content[0] = .{ .text = .{ .text = partial_text.items } };
                    try emitPartialMessageUpdate(
                        emit_context,
                        emit,
                        template,
                        event,
                        &partial_content,
                        has_text_block,
                    );
                }
            },
            .text_end => {
                if (partial_template) |template| {
                    if (!has_text_block) {
                        has_text_block = true;
                    }
                    partial_content[0] = .{ .text = .{ .text = event.content orelse partial_text.items } };
                    try emitPartialMessageUpdate(
                        emit_context,
                        emit,
                        template,
                        event,
                        &partial_content,
                        has_text_block,
                    );
                }
            },
            .done, .error_event => {
                const final_message = event.message orelse stream.result() orelse return AgentLoopError.MissingAssistantResult;
                if (!saw_message_start) {
                    try emit(emit_context, .{
                        .event_type = .message_start,
                        .message = .{ .assistant = final_message },
                    });
                }
                try emit(emit_context, .{
                    .event_type = .message_end,
                    .message = .{ .assistant = final_message },
                });
                return final_message;
            },
            else => {},
        }
    }

    const final_message = stream.result() orelse return AgentLoopError.MissingAssistantResult;
    if (!saw_message_start) {
        try emit(emit_context, .{
            .event_type = .message_start,
            .message = .{ .assistant = final_message },
        });
    }
    try emit(emit_context, .{
        .event_type = .message_end,
        .message = .{ .assistant = final_message },
    });
    return final_message;
}

fn emitPartialMessageUpdate(
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    template: ai.AssistantMessage,
    assistant_message_event: ai.AssistantMessageEvent,
    partial_content: *[1]ai.ContentBlock,
    has_text_block: bool,
) !void {
    var partial_message = template;
    partial_message.content = if (has_text_block)
        partial_content[0..1]
    else
        &[_]ai.ContentBlock{};
    try emit(emit_context, .{
        .event_type = .message_update,
        .message = .{ .assistant = partial_message },
        .assistant_message_event = assistant_message_event,
    });
}

fn convertToolsToLlm(
    allocator: std.mem.Allocator,
    tools: []const types.AgentTool,
) ![]ai.Tool {
    const converted = try allocator.alloc(ai.Tool, tools.len);
    for (tools, converted) |tool, *slot| {
        slot.* = .{
            .name = tool.name,
            .description = tool.description,
            .parameters = tool.parameters,
        };
    }
    return converted;
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

// test "runAgentLoop emits the single-turn text event sequence" {
//     const allocator = std.testing.allocator;
//     const faux = ai.providers.faux;
//
//     const registration = try faux.registerFauxProvider(allocator, .{
//         .token_size = .{ .min = 1, .max = 1 },
//     });
//     defer registration.unregister();
//
//     const response_blocks = [_]faux.FauxContentBlock{faux.fauxText("hello")};
//     try registration.setResponses(&[_]faux.FauxResponseStep{
//         .{ .message = faux.fauxAssistantMessage(response_blocks[0..], .{}) },
//     });
//
//     var capture = TestCapture.init(allocator);
//     defer capture.deinit();
//
//     const prompt = createUserMessage("hi", 1);
//     const prompts = [_]types.AgentMessage{prompt};
//     const context = types.AgentContext{
//         .system_prompt = "You are helpful.",
//         .messages = &.{},
//         .tools = &.{},
//     };
//     const config = types.AgentLoopConfig{
//         .model = registration.getModel(),
//         .convert_to_llm = defaultConvertToLlmForTest,
//     };
//
//     const result = try runAgentLoop(
//         allocator,
//         std.Io.failing,
//         prompts[0..],
//         context,
//         config,
//         &capture,
//         captureEvent,
//         null,
//         null,
//     );
//     defer allocator.free(result);
//
//     try std.testing.expectEqual(@as(usize, 2), result.len);
//     try std.testing.expectEqualStrings("hi", result[0].user.content[0].text.text);
//     try std.testing.expectEqualStrings("hello", result[1].assistant.content[0].text.text);
//
//     const event_types = capture.event_types.items;
//     try std.testing.expectEqual(types.AgentEventType.agent_start, event_types[0]);
//     try std.testing.expectEqual(types.AgentEventType.turn_start, event_types[1]);
//     try std.testing.expectEqual(types.AgentEventType.message_start, event_types[2]);
//     try std.testing.expectEqual(types.AgentEventType.message_end, event_types[3]);
//     try std.testing.expectEqual(types.AgentEventType.message_start, event_types[4]);
//     try std.testing.expectEqual(types.AgentEventType.message_end, event_types[event_types.len - 3]);
//     try std.testing.expectEqual(types.AgentEventType.turn_end, event_types[event_types.len - 2]);
//     try std.testing.expectEqual(types.AgentEventType.agent_end, event_types[event_types.len - 1]);
//
//     for (event_types[5 .. event_types.len - 3]) |event_type| {
//         try std.testing.expectEqual(types.AgentEventType.message_update, event_type);
//     }
// }
