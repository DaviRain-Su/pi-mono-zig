const std = @import("std");
const ai = @import("ai");
const shared = @import("shared");
const types = @import("types.zig");

const ManagedList = shared.compat.ManagedList;
const AgentEvent = types.AgentEvent;
const AgentMessage = types.AgentMessage;
const AgentContext = types.AgentContext;
const AgentLoopConfig = types.AgentLoopConfig;
const AgentTool = types.AgentTool;
const AgentToolCall = types.AgentToolCall;
const AgentToolResult = types.AgentToolResult;

pub const AgentEventStream = ai.event_stream.EventStream(AgentEvent, []AgentMessage);

fn isCompleteAgentEvent(event: AgentEvent) bool {
    return switch (event) {
        .agent_end => true,
        else => false,
    };
}

fn extractAgentResult(event: AgentEvent) []AgentMessage {
    return switch (event) {
        .agent_end => |e| e.messages,
        else => unreachable,
    };
}

pub fn createAgentEventStream(gpa: std.mem.Allocator) !AgentEventStream {
    return try AgentEventStream.init(gpa, isCompleteAgentEvent, extractAgentResult);
}

/// Run the agent loop from an initial set of prompt messages.
pub fn agentLoop(
    gpa: std.mem.Allocator,
    prompts: []const AgentMessage,
    context: AgentContext,
    config: AgentLoopConfig,
    stream_fn: *const fn (model: ai.Model, ctx: ai.Context, options: ?ai.SimpleStreamOptions) ai.AssistantMessageEventStream,
    es: *AgentEventStream,
) !void {
    const thread = std.Thread.spawn(.{}, struct {
        fn run(
            g: std.mem.Allocator,
            p: []const AgentMessage,
            c: AgentContext,
            cfg: AgentLoopConfig,
            sf: *const fn (model: ai.Model, ctx: ai.Context, options: ?ai.SimpleStreamOptions) ai.AssistantMessageEventStream,
            e: *AgentEventStream,
        ) !void {
            var new_messages = ManagedList(AgentMessage).init(g);
            defer new_messages.deinit();
            try new_messages.appendSlice(p);

            var current_ctx = try copyContextWithMessages(g, c, p);
            defer g.free(current_ctx.messages);

            try runAgentLoopInner(g, &new_messages, &current_ctx, cfg, sf, e);
        }
    }.run, .{ gpa, prompts, context, config, stream_fn, es }) catch @panic("OOM");
    thread.detach();
}

/// Continue the agent loop from an existing conversation context.
/// The last message must not be an assistant message.
pub fn agentLoopContinue(
    gpa: std.mem.Allocator,
    context: AgentContext,
    config: AgentLoopConfig,
    stream_fn: *const fn (model: ai.Model, ctx: ai.Context, options: ?ai.SimpleStreamOptions) ai.AssistantMessageEventStream,
    es: *AgentEventStream,
) !void {
    if (context.messages.len == 0) {
        return error.CannotContinueNoMessages;
    }
    const last = context.messages[context.messages.len - 1];
    switch (last) {
        .assistant => return error.CannotContinueFromAssistant,
        else => {},
    }

    const thread = std.Thread.spawn(.{}, struct {
        fn run(
            g: std.mem.Allocator,
            c: AgentContext,
            cfg: AgentLoopConfig,
            sf: *const fn (model: ai.Model, ctx: ai.Context, options: ?ai.SimpleStreamOptions) ai.AssistantMessageEventStream,
            e: *AgentEventStream,
        ) !void {
            var new_messages = ManagedList(AgentMessage).init(g);
            defer new_messages.deinit();

            const continue_msg = AgentMessage{ .user = .{ .content = .{ .text = "Continue" }, .timestamp = 0 } };
            try new_messages.append(continue_msg);

            var current_ctx = try copyContext(g, c);
            defer g.free(current_ctx.messages);
            try appendMessage(g, &current_ctx.messages, continue_msg);

            try runAgentLoopInner(g, &new_messages, &current_ctx, cfg, sf, e);
        }
    }.run, .{ gpa, context, config, stream_fn, es }) catch @panic("OOM");
    thread.detach();
}

fn copyContext(gpa: std.mem.Allocator, ctx: AgentContext) !AgentContext {
    const messages = try gpa.alloc(AgentMessage, ctx.messages.len);
    @memcpy(messages, ctx.messages);
    return .{
        .system_prompt = ctx.system_prompt,
        .messages = messages,
        .tools = ctx.tools,
    };
}

fn copyContextWithMessages(gpa: std.mem.Allocator, ctx: AgentContext, extra: []const AgentMessage) !AgentContext {
    const messages = try gpa.alloc(AgentMessage, ctx.messages.len + extra.len);
    @memcpy(messages[0..ctx.messages.len], ctx.messages);
    @memcpy(messages[ctx.messages.len..], extra);
    return .{
        .system_prompt = ctx.system_prompt,
        .messages = messages,
        .tools = ctx.tools,
    };
}

fn appendMessage(gpa: std.mem.Allocator, current: *[]AgentMessage, msg: AgentMessage) !void {
    const new_messages = try gpa.realloc(current.*, current.*.len + 1);
    new_messages[current.*.len] = msg;
    current.* = new_messages;
}

fn pushAgentEvent(es: *AgentEventStream, event: AgentEvent) void {
    es.push(event);
}

fn runAgentLoopInner(
    gpa: std.mem.Allocator,
    new_messages: *ManagedList(AgentMessage),
    current_ctx: *AgentContext,
    config: AgentLoopConfig,
    stream_fn: *const fn (model: ai.Model, ctx: ai.Context, options: ?ai.SimpleStreamOptions) ai.AssistantMessageEventStream,
    es: *AgentEventStream,
) !void {
    pushAgentEvent(es, .agent_start);
    pushAgentEvent(es, .turn_start);

    for (new_messages.items()) |prompt| {
        pushAgentEvent(es, .{ .message_start = prompt });
        pushAgentEvent(es, .{ .message_end = prompt });
    }

    _ = try runLoop(gpa, current_ctx, new_messages, config, stream_fn, es);

    const final_messages = try new_messages.toOwnedSlice();
    pushAgentEvent(es, .{ .agent_end = .{ .messages = final_messages } });
    es.end(final_messages);
}

/// Nested loop: outer follow-up, inner turn + steering.
fn runLoop(
    gpa: std.mem.Allocator,
    current_ctx: *AgentContext,
    new_messages: *ManagedList(AgentMessage),
    config: AgentLoopConfig,
    stream_fn: *const fn (model: ai.Model, ctx: ai.Context, options: ?ai.SimpleStreamOptions) ai.AssistantMessageEventStream,
    es: *AgentEventStream,
) !bool {
    var first_turn = true;
    var pending_messages: []const AgentMessage = if (config.get_steering_messages) |f| f(config.user_ctx) else &[_]AgentMessage{};
    errdefer gpa.free(pending_messages);

    while (true) {
        var has_more_tool_calls = true;

        while (has_more_tool_calls or pending_messages.len > 0) {
            if (!first_turn) {
                pushAgentEvent(es, .turn_start);
            } else {
                first_turn = false;
            }

            if (pending_messages.len > 0) {
                const to_free = pending_messages;
                for (pending_messages) |msg| {
                    pushAgentEvent(es, .{ .message_start = msg });
                    pushAgentEvent(es, .{ .message_end = msg });
                    try appendMessage(gpa, &current_ctx.messages, msg);
                    try new_messages.append(msg);
                }
                gpa.free(to_free);
                pending_messages = &[_]AgentMessage{};
            }

            const message = try streamAssistantResponse(gpa, current_ctx, config, stream_fn, es);
            try new_messages.append(AgentMessage{ .assistant = message });

            const stop_reason = if (message.stop_reason == .err or message.stop_reason == .aborted)
                message.stop_reason
            else
                null;

            if (stop_reason != null) {
                pushAgentEvent(es, .{ .turn_end = .{ .message = AgentMessage{ .assistant = message }, .tool_results = &[_]ai.ToolResultMessage{} } });
                gpa.free(pending_messages);
                return false;
            }

            const tool_calls = extractToolCalls(message);
            has_more_tool_calls = tool_calls.len > 0;

            var tool_results = ManagedList(ai.ToolResultMessage).init(gpa);
            defer tool_results.deinit();

            if (has_more_tool_calls) {
                const results = try executeToolCalls(gpa, current_ctx, message, tool_calls, config, es);
                defer gpa.free(results);
                try tool_results.appendSlice(results);

                for (results) |result| {
                    try appendMessage(gpa, &current_ctx.messages, .{ .tool_result = result });
                    try new_messages.append(AgentMessage{ .tool_result = result });
                }
            }

            pushAgentEvent(es, .{ .turn_end = .{ .message = AgentMessage{ .assistant = message }, .tool_results = tool_results.items() } });
            const next_steering = if (config.get_steering_messages) |f| f(config.user_ctx) else &[_]AgentMessage{};
            gpa.free(pending_messages);
            pending_messages = next_steering;
        }

        const follow_up = if (config.get_follow_up_messages) |f| f(config.user_ctx) else &[_]AgentMessage{};
        if (follow_up.len > 0) {
            gpa.free(pending_messages);
            pending_messages = follow_up;
            continue;
        }

        break;
    }

    gpa.free(pending_messages);
    return true;
}

fn extractToolCalls(message: ai.AssistantMessage) []const AgentToolCall {
    const gpa = std.heap.page_allocator;
    var list = ManagedList(AgentToolCall).init(gpa);
    defer list.deinit();
    for (message.content) |block| {
        switch (block) {
            .tool_call => |tc| {
                list.append(tc) catch @panic("OOM");
            },
            else => {},
        }
    }
    return list.toOwnedSlice() catch @panic("OOM");
}

fn agentToolsToAiTools(gpa: std.mem.Allocator, tools: []const AgentTool) ![]ai.Tool {
    var list = ManagedList(ai.Tool).init(gpa);
    defer list.deinit();
    for (tools) |tool| {
        try list.append(.{
            .name = tool.name,
            .description = tool.description,
            .parameters = tool.parameters,
        });
    }
    return list.toOwnedSlice();
}

fn streamAssistantResponse(
    gpa: std.mem.Allocator,
    context: *AgentContext,
    config: AgentLoopConfig,
    stream_fn: *const fn (model: ai.Model, ctx: ai.Context, options: ?ai.SimpleStreamOptions) ai.AssistantMessageEventStream,
    es: *AgentEventStream,
) !ai.AssistantMessage {
    var messages = context.messages;

    if (config.transform_context) |xf| {
        const transformed = try xf(gpa, messages);
        defer gpa.free(transformed);
        messages = transformed;
    }

    const llm_messages = try config.convert_to_llm(gpa, messages);
    defer gpa.free(llm_messages);

    const ai_tools = if (context.tools) |t| try agentToolsToAiTools(gpa, t) else null;
    defer if (ai_tools) |at| gpa.free(at);

    const llm_ctx = ai.Context{
        .system_prompt = context.system_prompt,
        .messages = llm_messages,
        .tools = ai_tools,
    };

    const provider_name = switch (config.model.provider) {
        .known => |kp| @tagName(kp),
        .custom => |s| s,
    };
    const resolved_api_key = if (config.get_api_key) |f| f(provider_name) else config.api_key;
    const options = ai.SimpleStreamOptions{
        .base = .{ .api_key = resolved_api_key },
    };

    var response = stream_fn(config.model, llm_ctx, options);

    var partial_message: ?ai.AssistantMessage = null;
    var added_partial = false;

    while (true) {
        const ev = response.next() orelse break;
        switch (ev) {
            .start => |s| {
                partial_message = s.partial;
                try appendMessage(gpa, &context.messages, .{ .assistant = s.partial });
                added_partial = true;
                pushAgentEvent(es, .{ .message_start = .{ .assistant = s.partial } });
            },
            .text_start,
            .text_delta,
            .text_end,
            .thinking_start,
            .thinking_delta,
            .thinking_end,
            .toolcall_start,
            .toolcall_delta,
            .toolcall_end,
            => {
                if (partial_message) |pm| {
                    const updated = response.getResult() orelse pm;
                    context.messages[context.messages.len - 1] = .{ .assistant = updated };
                    partial_message = updated;
                    pushAgentEvent(es, .{ .message_update = .{ .message = .{ .assistant = updated }, .assistant_event = ev } });
                }
            },
            .done,
            .err_event,
            => {
                const final_message = response.waitResult() orelse partial_message orelse return error.NoResultFromStream;
                if (added_partial) {
                    context.messages[context.messages.len - 1] = .{ .assistant = final_message };
                } else {
                    try appendMessage(gpa, &context.messages, .{ .assistant = final_message });
                }
                if (!added_partial) {
                    pushAgentEvent(es, .{ .message_start = .{ .assistant = final_message } });
                }
                pushAgentEvent(es, .{ .message_end = .{ .assistant = final_message } });
                return final_message;
            },
        }
    }

    const final_message = response.waitResult() orelse partial_message orelse return error.NoResultFromStream;
    if (added_partial) {
        context.messages[context.messages.len - 1] = .{ .assistant = final_message };
    } else {
        try appendMessage(gpa, &context.messages, .{ .assistant = final_message });
        pushAgentEvent(es, .{ .message_start = .{ .assistant = final_message } });
    }
    pushAgentEvent(es, .{ .message_end = .{ .assistant = final_message } });
    return final_message;
}

fn executeToolCalls(
    gpa: std.mem.Allocator,
    current_ctx: *AgentContext,
    assistant_message: ai.AssistantMessage,
    tool_calls: []const AgentToolCall,
    config: AgentLoopConfig,
    es: *AgentEventStream,
) ![]ai.ToolResultMessage {
    if (config.tool_execution == .sequential) {
        return try executeToolCallsSequential(gpa, current_ctx, assistant_message, tool_calls, config, es);
    }
    return try executeToolCallsParallel(gpa, current_ctx, assistant_message, tool_calls, config, es);
}

fn executeToolCallsSequential(
    gpa: std.mem.Allocator,
    current_ctx: *AgentContext,
    assistant_message: ai.AssistantMessage,
    tool_calls: []const AgentToolCall,
    config: AgentLoopConfig,
    es: *AgentEventStream,
) ![]ai.ToolResultMessage {
    var results = ManagedList(ai.ToolResultMessage).init(gpa);
    defer results.deinit();

    for (tool_calls) |tool_call| {
        pushAgentEvent(es, .{ .tool_execution_start = .{
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .args = tool_call.arguments,
        } });

        const prepared = try prepareToolCall(current_ctx, assistant_message, tool_call, config);
        switch (prepared) {
            .immediate => |imm| {
                const result = try emitToolCallOutcome(gpa, tool_call, imm.result, imm.is_error, es);
                try results.append(result);
            },
            .prepared => |prep| {
                const executed = try executePreparedToolCall(prep);
                const result = try finalizeExecutedToolCall(current_ctx, assistant_message, prep, executed, config, es);
                try results.append(result);
            },
        }
    }

    return try results.toOwnedSlice();
}

fn executeToolCallsParallel(
    gpa: std.mem.Allocator,
    current_ctx: *AgentContext,
    assistant_message: ai.AssistantMessage,
    tool_calls: []const AgentToolCall,
    config: AgentLoopConfig,
    es: *AgentEventStream,
) ![]ai.ToolResultMessage {
    var results = ManagedList(ai.ToolResultMessage).init(gpa);
    defer results.deinit();

    const Prepared = PreparedToolCall;
    var immediates = ManagedList(struct { tool_call: AgentToolCall, result: AgentToolResult, is_error: bool }).init(gpa);
    defer immediates.deinit();

    var runnables = ManagedList(Prepared).init(gpa);
    defer runnables.deinit();

    for (tool_calls) |tool_call| {
        pushAgentEvent(es, .{ .tool_execution_start = .{
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .args = tool_call.arguments,
        } });

        const prepared = try prepareToolCall(current_ctx, assistant_message, tool_call, config);
        switch (prepared) {
            .immediate => |imm| {
                try immediates.append(.{
                    .tool_call = tool_call,
                    .result = imm.result,
                    .is_error = imm.is_error,
                });
            },
            .prepared => |prep| {
                try runnables.append(prep);
            },
        }
    }

    var threads = ManagedList(std.Thread).init(gpa);
    defer threads.deinit();
    var outcomes = try gpa.alloc(ExecutedToolCallOutcome, runnables.len());
    defer gpa.free(outcomes);

    for (runnables.items(), 0..) |prepared, i| {
        const t = try std.Thread.spawn(.{}, struct {
            fn run(p: Prepared, out: *ExecutedToolCallOutcome) !void {
                out.* = try executePreparedToolCall(p);
            }
        }.run, .{ prepared, &outcomes[i] });
        try threads.append(t);
    }

    for (threads.items()) |t| {
        t.join();
    }

    for (immediates.items()) |imm| {
        const result = try emitToolCallOutcome(gpa, imm.tool_call, imm.result, imm.is_error, es);
        try results.append(result);
    }

    for (runnables.items(), 0..) |prepared, i| {
        const result = try finalizeExecutedToolCall(current_ctx, assistant_message, prepared, outcomes[i], config, es);
        try results.append(result);
    }

    return try results.toOwnedSlice();
}

const PreparedToolCall = struct {
    tool_call: AgentToolCall,
    tool: AgentTool,
    args: std.json.Value,
};

const ImmediateOutcome = struct {
    result: AgentToolResult,
    is_error: bool,
};

const ExecutedToolCallOutcome = struct {
    result: AgentToolResult,
    is_error: bool,
};

const Preparation = union(enum) {
    immediate: ImmediateOutcome,
    prepared: PreparedToolCall,
};

fn prepareToolCallArguments(tool: AgentTool, tool_call: AgentToolCall) AgentToolCall {
    if (tool.prepare_arguments) |prep| {
        const prepared_args = prep(tool_call.arguments);
        return .{
            .id = tool_call.id,
            .name = tool_call.name,
            .arguments = prepared_args,
        };
    }
    return tool_call;
}

fn prepareToolCall(
    current_ctx: *AgentContext,
    assistant_message: ai.AssistantMessage,
    tool_call: AgentToolCall,
    config: AgentLoopConfig,
) !Preparation {
    const tools = current_ctx.tools orelse return Preparation{ .immediate = .{
        .result = createErrorToolResult(tool_call.name, try std.fmt.allocPrint(std.heap.page_allocator, "Tool {s} not found", .{tool_call.name})),
        .is_error = true,
    } };

    const tool = findTool(tools, tool_call.name) orelse return Preparation{ .immediate = .{
        .result = createErrorToolResult(tool_call.name, try std.fmt.allocPrint(std.heap.page_allocator, "Tool {s} not found", .{tool_call.name})),
        .is_error = true,
    } };

    const prepared_tool_call = prepareToolCallArguments(tool, tool_call);
    ai.validation.validateToolArguments(.{
        .name = tool.name,
        .description = tool.description,
        .parameters = tool.parameters,
    }, prepared_tool_call.arguments) catch |err| {
        const msg = try std.fmt.allocPrint(std.heap.page_allocator, "Validation failed: {s}", .{@errorName(err)});
        return Preparation{ .immediate = .{ .result = createErrorToolResult(tool_call.name, msg), .is_error = true } };
    };

    if (config.before_tool_call) |before| {
        const ctx = types.BeforeToolCallContext{
            .assistant_message = assistant_message,
            .tool_call = prepared_tool_call,
            .args = prepared_tool_call.arguments,
            .context = current_ctx.*,
        };
        const before_result = before(ctx) catch |err| {
            const msg = try std.fmt.allocPrint(std.heap.page_allocator, "beforeToolCall failed: {s}", .{@errorName(err)});
            return Preparation{ .immediate = .{ .result = createErrorToolResult(tool_call.name, msg), .is_error = true } };
        };
        if (before_result) |br| {
            if (br.block) {
                const reason = br.reason orelse "Tool execution was blocked";
                return Preparation{ .immediate = .{ .result = createErrorToolResult(tool_call.name, reason), .is_error = true } };
            }
        }
    }

    return Preparation{ .prepared = .{
        .tool_call = prepared_tool_call,
        .tool = tool,
        .args = prepared_tool_call.arguments,
    } };
}

fn executePreparedToolCall(prepared: PreparedToolCall) !ExecutedToolCallOutcome {
    const result = prepared.tool.execute(prepared.tool_call.id, prepared.args, null, null) catch |err| {
        const msg = try std.fmt.allocPrint(std.heap.page_allocator, "Execution failed: {s}", .{@errorName(err)});
        return ExecutedToolCallOutcome{
            .result = createErrorToolResult(prepared.tool_call.name, msg),
            .is_error = true,
        };
    };
    return ExecutedToolCallOutcome{ .result = result, .is_error = false };
}

fn finalizeExecutedToolCall(
    current_ctx: *AgentContext,
    assistant_message: ai.AssistantMessage,
    prepared: PreparedToolCall,
    executed: ExecutedToolCallOutcome,
    config: AgentLoopConfig,
    es: *AgentEventStream,
) !ai.ToolResultMessage {
    var result = executed.result;
    var is_error = executed.is_error;

    if (config.after_tool_call) |after| {
        const ctx = types.AfterToolCallContext{
            .assistant_message = assistant_message,
            .tool_call = prepared.tool_call,
            .args = prepared.args,
            .result = result,
            .is_error = is_error,
            .context = current_ctx.*,
        };
        const after_result = after(ctx) catch null;
        if (after_result) |ar| {
            if (ar.content) |c| result.content = c;
            if (ar.details) |d| result.details = d;
            if (ar.is_error) |e| is_error = e;
        }
    }

    return try emitToolCallOutcome(std.heap.page_allocator, prepared.tool_call, result, is_error, es);
}

fn createErrorToolResult(tool_name: []const u8, message: []const u8) AgentToolResult {
    _ = tool_name;
    const empty_details = std.json.ObjectMap.init(std.heap.page_allocator);
    return .{
        .content = &[_]ai.ContentBlock{.{ .text = .{ .text = message } }},
        .details = .{ .object = empty_details },
    };
}

fn emitToolCallOutcome(
    gpa: std.mem.Allocator,
    tool_call: AgentToolCall,
    result: AgentToolResult,
    is_error: bool,
    es: *AgentEventStream,
) !ai.ToolResultMessage {
    pushAgentEvent(es, .{ .tool_execution_end = .{
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .result = result.details,
        .is_error = is_error,
    } });

    const ts = std.posix.clock_gettime(std.os.linux.CLOCK.REALTIME) catch return error.ClockError;
    const tool_result_message = ai.ToolResultMessage{
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .content = @constCast(result.content),
        .details = result.details,
        .timestamp = @as(i64, ts.sec) * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms),
    };

    pushAgentEvent(es, .{ .message_start = .{ .tool_result = tool_result_message } });
    pushAgentEvent(es, .{ .message_end = .{ .tool_result = tool_result_message } });
    _ = gpa;
    return tool_result_message;
}

fn findTool(tools: []const AgentTool, name: []const u8) ?AgentTool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

test "agent loop basic text response" {
    const gpa = std.testing.allocator;

    ai.faux_provider.registerFauxProvider();
    var content0 = [_]ai.ContentBlock{ai.faux_provider.fauxText("Hello from faux")};
    ai.faux_provider.addFauxResponses(&[_]ai.AssistantMessage{
        ai.faux_provider.fauxAssistantMessage(
            &content0,
            .stop,
        ),
    });

    const config = AgentLoopConfig{
        .model = ai.Model{
            .id = "faux-1",
            .name = "Faux Model",
            .api = .{ .known = .faux },
            .provider = .{ .known = .faux },
        },
    };

    const context = AgentContext{
        .system_prompt = "You are a test assistant.",
        .messages = &.{},
        .tools = null,
    };

    const prompt = AgentMessage{ .user = .{ .content = .{ .text = "Say hello" }, .timestamp = 0 } };

    var es = try createAgentEventStream(gpa);
    defer es.deinit();
    try agentLoop(gpa, &[_]AgentMessage{prompt}, context, config, ai.streamSimple, &es);

    var saw_agent_start = false;
    var saw_turn_start = false;
    var saw_message_start_assistant = false;
    var saw_message_end_assistant = false;
    var saw_turn_end = false;
    var saw_agent_end = false;

    while (true) {
        const ev = es.next() orelse break;
        switch (ev) {
            .agent_start => saw_agent_start = true,
            .turn_start => saw_turn_start = true,
            .message_start => |m| {
                switch (m) {
                    .assistant => saw_message_start_assistant = true,
                    else => {},
                }
            },
            .message_end => |m| {
                switch (m) {
                    .assistant => saw_message_end_assistant = true,
                    else => {},
                }
            },
            .turn_end => saw_turn_end = true,
            .agent_end => saw_agent_end = true,
            else => {},
        }
    }

    try std.testing.expect(saw_agent_start);
    try std.testing.expect(saw_turn_start);
    try std.testing.expect(saw_message_start_assistant);
    try std.testing.expect(saw_message_end_assistant);
    try std.testing.expect(saw_turn_end);
    try std.testing.expect(saw_agent_end);

    const result = es.waitResult() orelse return error.NoResult;
    try std.testing.expectEqual(@as(usize, 2), result.len);
    gpa.free(result);
}

test "agent event sequence" {
    const gpa = std.testing.allocator;

    ai.faux_provider.registerFauxProvider();
    var content1 = [_]ai.ContentBlock{ai.faux_provider.fauxText("Test response")};
    ai.faux_provider.addFauxResponses(&[_]ai.AssistantMessage{
        ai.faux_provider.fauxAssistantMessage(
            &content1,
            .stop,
        ),
    });

    const config = AgentLoopConfig{
        .model = ai.Model{
            .id = "faux-1",
            .name = "Faux Model",
            .api = .{ .known = .faux },
            .provider = .{ .known = .faux },
        },
    };

    const context = AgentContext{
        .system_prompt = "You are a test assistant.",
        .messages = &.{},
        .tools = null,
    };

    const prompt = AgentMessage{ .user = .{ .content = .{ .text = "Test" }, .timestamp = 0 } };

    var es = try createAgentEventStream(gpa);
    defer es.deinit();
    try agentLoop(gpa, &[_]AgentMessage{prompt}, context, config, ai.streamSimple, &es);

    var events = ManagedList(AgentEvent).init(gpa);
    defer events.deinit();

    while (true) {
        const ev = es.next() orelse break;
        try events.append(ev);
    }

    try std.testing.expect(events.len() >= 6);
    try std.testing.expect(events.items()[0] == .agent_start);
    try std.testing.expect(events.items()[1] == .turn_start);
    try std.testing.expect(events.items()[events.len() - 1] == .agent_end);

    const result = es.waitResult() orelse return error.NoResult;
    try std.testing.expectEqual(@as(usize, 2), result.len);
    gpa.free(result);
}

test "agent loop continue from user message" {
    const gpa = std.testing.allocator;

    ai.faux_provider.registerFauxProvider();
    var content2 = [_]ai.ContentBlock{ai.faux_provider.fauxText("Response to continue")};
    ai.faux_provider.addFauxResponses(&[_]ai.AssistantMessage{
        ai.faux_provider.fauxAssistantMessage(
            &content2,
            .stop,
        ),
    });

    const config = AgentLoopConfig{
        .model = ai.Model{
            .id = "faux-1",
            .name = "Faux Model",
            .api = .{ .known = .faux },
            .provider = .{ .known = .faux },
        },
    };

    var existing_messages = [_]AgentMessage{AgentMessage{ .user = .{ .content = .{ .text = "Existing" }, .timestamp = 0 } }};
    const context = AgentContext{
        .system_prompt = "You are a test assistant.",
        .messages = &existing_messages,
        .tools = null,
    };

    var es = try createAgentEventStream(gpa);
    defer es.deinit();
    try agentLoopContinue(gpa, context, config, ai.streamSimple, &es);

    var saw_agent_start = false;
    var saw_agent_end = false;

    while (true) {
        const ev = es.next() orelse break;
        switch (ev) {
            .agent_start => saw_agent_start = true,
            .agent_end => saw_agent_end = true,
            else => {},
        }
    }

    try std.testing.expect(saw_agent_start);
    try std.testing.expect(saw_agent_end);

    const result = es.waitResult() orelse return error.NoResult;
    try std.testing.expect(result.len >= 2);
    gpa.free(result);
}

test "agent loop continue fails from assistant message" {
    const gpa = std.testing.allocator;

    const config = AgentLoopConfig{
        .model = ai.Model{
            .id = "faux-1",
            .name = "Faux Model",
            .api = .{ .known = .faux },
            .provider = .{ .known = .faux },
        },
    };

    var assistant_content = [_]ai.ContentBlock{.{ .text = .{ .text = "I am assistant" } }};
    const existing_message = ai.AssistantMessage{
        .role = "assistant",
        .content = &assistant_content,
        .api = .{ .known = .faux },
        .provider = .{ .known = .faux },
        .model = "faux-1",
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = 0,
    };
    var msgs = [_]AgentMessage{.{ .assistant = existing_message }};
    const context = AgentContext{
        .system_prompt = "You are a test assistant.",
        .messages = &msgs,
        .tools = null,
    };

    var es = try createAgentEventStream(gpa);
    defer es.deinit();
    const result = agentLoopContinue(gpa, context, config, ai.streamSimple, &es);
    try std.testing.expectError(error.CannotContinueFromAssistant, result);
}

test "agent loop continue fails with empty messages" {
    const gpa = std.testing.allocator;

    const config = AgentLoopConfig{
        .model = ai.Model{
            .id = "faux-1",
            .name = "Faux Model",
            .api = .{ .known = .faux },
            .provider = .{ .known = .faux },
        },
    };

    const context = AgentContext{
        .system_prompt = "You are a test assistant.",
        .messages = &.{},
        .tools = null,
    };

    var es = try createAgentEventStream(gpa);
    defer es.deinit();
    const result = agentLoopContinue(gpa, context, config, ai.streamSimple, &es);
    try std.testing.expectError(error.CannotContinueNoMessages, result);
}

fn mockToolExecute(tool_call_id: []const u8, params: std.json.Value, signal: ?*anyopaque, on_update: ?types.AgentToolUpdateCallback) !types.AgentToolResult {
    _ = tool_call_id;
    _ = params;
    _ = signal;
    _ = on_update;
    return types.AgentToolResult{
        .content = @constCast(&[_]ai.ContentBlock{.{ .text = .{ .text = "mock result" } }}),
        .details = .{ .object = std.json.ObjectMap.init(std.heap.page_allocator) },
    };
}

fn setupToolCallResponses() void {
    ai.faux_provider.registerFauxProvider();
    const gpa = std.heap.page_allocator;

    const tool_content = gpa.alloc(ai.ContentBlock, 1) catch @panic("OOM");
    tool_content[0] = ai.faux_provider.fauxToolCall(
        "mock_tool",
        .{ .object = std.json.ObjectMap.init(gpa) },
        null,
    );
    const tool_response = ai.faux_provider.fauxAssistantMessage(tool_content, .tool_use);
    ai.faux_provider.addFauxResponses(&[_]ai.AssistantMessage{tool_response});

    const text_content = gpa.alloc(ai.ContentBlock, 1) catch @panic("OOM");
    text_content[0] = ai.faux_provider.fauxText("Done");
    const text_response = ai.faux_provider.fauxAssistantMessage(text_content, .stop);
    ai.faux_provider.addFauxResponses(&[_]ai.AssistantMessage{text_response});
}

test "agent loop sequential tool calls" {
    const gpa = std.testing.allocator;
    setupToolCallResponses();

    const tools = &[_]types.AgentTool{types.AgentTool{
        .name = "mock_tool",
        .label = "Mock Tool",
        .description = "A mock tool for testing",
        .parameters = .null,
        .execute = mockToolExecute,
    }};

    const config = AgentLoopConfig{
        .model = ai.Model{
            .id = "faux-1",
            .name = "Faux Model",
            .api = .{ .known = .faux },
            .provider = .{ .known = .faux },
        },
        .tool_execution = .sequential,
    };

    const prompt = AgentMessage{ .user = .{ .content = .{ .text = "Run tool" }, .timestamp = 0 } };
    const context = AgentContext{
        .system_prompt = "You are a test assistant.",
        .messages = &.{},
        .tools = tools,
    };

    var es = try createAgentEventStream(gpa);
    defer es.deinit();
    try agentLoop(gpa, &[_]AgentMessage{prompt}, context, config, ai.streamSimple, &es);

    var saw_tool_start = false;
    var saw_tool_end = false;
    var saw_turn_end = false;
    var saw_agent_end = false;

    while (true) {
        const ev = es.next() orelse break;
        switch (ev) {
            .tool_execution_start => saw_tool_start = true,
            .tool_execution_end => saw_tool_end = true,
            .turn_end => saw_turn_end = true,
            .agent_end => saw_agent_end = true,
            else => {},
        }
    }

    try std.testing.expect(saw_tool_start);
    try std.testing.expect(saw_tool_end);
    try std.testing.expect(saw_turn_end);
    try std.testing.expect(saw_agent_end);

    const result = es.waitResult() orelse return error.NoResult;
    defer gpa.free(result);
    try std.testing.expect(result.len >= 3); // prompt + tool_result + follow-up assistant
}

test "agent loop parallel tool calls" {
    const gpa = std.testing.allocator;
    setupToolCallResponses();

    const tools = &[_]types.AgentTool{types.AgentTool{
        .name = "mock_tool",
        .label = "Mock Tool",
        .description = "A mock tool for testing",
        .parameters = .null,
        .execute = mockToolExecute,
    }};

    const config = AgentLoopConfig{
        .model = ai.Model{
            .id = "faux-1",
            .name = "Faux Model",
            .api = .{ .known = .faux },
            .provider = .{ .known = .faux },
        },
        .tool_execution = .parallel,
    };

    const prompt = AgentMessage{ .user = .{ .content = .{ .text = "Run tool" }, .timestamp = 0 } };
    const context = AgentContext{
        .system_prompt = "You are a test assistant.",
        .messages = &.{},
        .tools = tools,
    };

    var es = try createAgentEventStream(gpa);
    defer es.deinit();
    try agentLoop(gpa, &[_]AgentMessage{prompt}, context, config, ai.streamSimple, &es);

    var saw_tool_start = false;
    var saw_tool_end = false;
    var saw_turn_end = false;
    var saw_agent_end = false;

    while (true) {
        const ev = es.next() orelse break;
        switch (ev) {
            .tool_execution_start => saw_tool_start = true,
            .tool_execution_end => saw_tool_end = true,
            .turn_end => saw_turn_end = true,
            .agent_end => saw_agent_end = true,
            else => {},
        }
    }

    try std.testing.expect(saw_tool_start);
    try std.testing.expect(saw_tool_end);
    try std.testing.expect(saw_turn_end);
    try std.testing.expect(saw_agent_end);

    const result = es.waitResult() orelse return error.NoResult;
    defer gpa.free(result);
    try std.testing.expect(result.len >= 3); // prompt + tool_result + follow-up assistant
}
