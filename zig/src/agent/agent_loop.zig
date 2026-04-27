const std = @import("std");
const ai = @import("ai");
const types = @import("types.zig");

pub const AgentLoopError = error{
    MissingAssistantResult,
};

const PreparedToolCall = struct {
    tool_call: ai.ToolCall,
    tool: types.AgentTool,
    args: std.json.Value,

    fn deinit(self: *PreparedToolCall, allocator: std.mem.Allocator) void {
        deinitJsonValue(allocator, self.args);
    }
};

const ImmediateToolCallOutcome = struct {
    result: types.AgentToolResult,
    is_error: bool,
};

const ExecutedToolCallOutcome = struct {
    result: types.AgentToolResult,
    is_error: bool,
};

const UpdateEmitterContext = struct {
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    tool_call: ai.ToolCall,
};

const ParallelToolEmitter = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,

    fn emitUpdate(self: *ParallelToolEmitter, event: types.AgentEvent) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.emit(self.emit_context, event);
    }
};

const ParallelToolTask = struct {
    arena: std.heap.ArenaAllocator,
    prepared: PreparedToolCall,
    signal: ?*const std.atomic.Value(bool),
    emitter: *ParallelToolEmitter,
    result: ?types.AgentToolResult = null,
    is_error: bool = false,

    fn init(
        parent_allocator: std.mem.Allocator,
        prepared: PreparedToolCall,
        signal: ?*const std.atomic.Value(bool),
        emitter: *ParallelToolEmitter,
    ) ParallelToolTask {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .prepared = prepared,
            .signal = signal,
            .emitter = emitter,
        };
    }

    fn deinit(self: *ParallelToolTask) void {
        self.arena.deinit();
    }
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
            };

            const assistant = try streamAssistantResponse(
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

            const tool_calls = assistant.tool_calls orelse &.{};
            has_more_tool_calls = tool_calls.len > 0;

            if (has_more_tool_calls) {
                const executed_tool_results = try executeToolCalls(
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

fn mapThinkingLevel(level: types.ThinkingLevel) ?ai.types.ThinkingLevel {
    return switch (level) {
        .off => null,
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
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
        .signal = signal,
        .reasoning = if (config.reasoning) |reasoning| mapThinkingLevel(reasoning) else null,
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
        defer event.deinitTransient(allocator);
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
            .thinking_start,
            .thinking_delta,
            .thinking_end,
            .toolcall_start,
            .toolcall_delta,
            .toolcall_end,
            => {
                const template = if (partial_template) |value| value else ai.AssistantMessage{
                    .content = &[_]ai.ContentBlock{},
                    .api = config.model.api,
                    .provider = config.model.provider,
                    .model = config.model.id,
                    .usage = ai.Usage.init(),
                    .stop_reason = .stop,
                    .timestamp = 0,
                };
                try emit(emit_context, .{
                    .event_type = .message_update,
                    .message = .{ .assistant = template },
                    .assistant_message_event = event,
                });
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

fn executeToolCalls(
    allocator: std.mem.Allocator,
    io: std.Io,
    current_context: types.AgentContext,
    assistant_message: ai.AssistantMessage,
    tool_calls: []const ai.ToolCall,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
) ![]const types.ToolResultMessage {
    var has_sequential_tool = false;
    for (tool_calls) |tool_call| {
        if (findTool(current_context.tools, tool_call.name)) |tool| {
            if (tool.execution_mode == .sequential) {
                has_sequential_tool = true;
                break;
            }
        }
    }

    if (config.tool_execution == .sequential or has_sequential_tool) {
        return executeToolCallsSequential(
            allocator,
            io,
            current_context,
            assistant_message,
            tool_calls,
            config,
            emit_context,
            emit,
            signal,
        );
    }

    return executeToolCallsParallel(
        allocator,
        io,
        current_context,
        assistant_message,
        tool_calls,
        config,
        emit_context,
        emit,
        signal,
    );
}

fn executeToolCallsSequential(
    allocator: std.mem.Allocator,
    _: std.Io,
    current_context: types.AgentContext,
    assistant_message: ai.AssistantMessage,
    tool_calls: []const ai.ToolCall,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
) ![]const types.ToolResultMessage {
    var results = std.ArrayList(types.ToolResultMessage).empty;
    errdefer results.deinit(allocator);

    for (tool_calls) |tool_call| {
        try emit(emit_context, .{
            .event_type = .tool_execution_start,
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .args = tool_call.arguments,
        });

        const prepared = try prepareToolCall(
            allocator,
            current_context,
            assistant_message,
            tool_call,
            config,
            signal,
        );

        const tool_result = switch (prepared) {
            .prepared => |prepared_tool| blk: {
                var owned_prepared_tool = prepared_tool;
                defer owned_prepared_tool.deinit(allocator);
                const executed = try executePreparedToolCallSequential(
                    allocator,
                    owned_prepared_tool,
                    emit_context,
                    emit,
                    signal,
                );
                break :blk try finalizeExecutedToolCall(
                    allocator,
                    current_context,
                    assistant_message,
                    owned_prepared_tool,
                    executed,
                    false,
                    config,
                    emit_context,
                    emit,
                    signal,
                );
            },
            .immediate => |immediate| try emitToolCallOutcome(
                allocator,
                tool_call,
                immediate.result,
                immediate.is_error,
                emit_context,
                emit,
            ),
        };

        try results.append(allocator, tool_result);
    }

    return try results.toOwnedSlice(allocator);
}

fn executeToolCallsParallel(
    allocator: std.mem.Allocator,
    io: std.Io,
    current_context: types.AgentContext,
    assistant_message: ai.AssistantMessage,
    tool_calls: []const ai.ToolCall,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
) ![]const types.ToolResultMessage {
    var results = std.ArrayList(types.ToolResultMessage).empty;
    errdefer results.deinit(allocator);

    var prepared_calls = std.ArrayList(PreparedToolCall).empty;
    defer {
        for (prepared_calls.items) |*prepared_call| {
            prepared_call.deinit(allocator);
        }
        prepared_calls.deinit(allocator);
    }

    for (tool_calls) |tool_call| {
        try emit(emit_context, .{
            .event_type = .tool_execution_start,
            .tool_call_id = tool_call.id,
            .tool_name = tool_call.name,
            .args = tool_call.arguments,
        });

        const prepared = try prepareToolCall(
            allocator,
            current_context,
            assistant_message,
            tool_call,
            config,
            signal,
        );

        switch (prepared) {
            .prepared => |prepared_tool| try prepared_calls.append(allocator, prepared_tool),
            .immediate => |immediate| {
                const tool_result = try emitToolCallOutcome(
                    allocator,
                    tool_call,
                    immediate.result,
                    immediate.is_error,
                    emit_context,
                    emit,
                );
                try results.append(allocator, tool_result);
            },
        }
    }

    if (prepared_calls.items.len == 0) {
        return try results.toOwnedSlice(allocator);
    }

    const task_count = prepared_calls.items.len;
    const tasks = try allocator.alloc(ParallelToolTask, task_count);
    defer allocator.free(tasks);
    const threads = try allocator.alloc(std.Thread, task_count);
    defer allocator.free(threads);

    var parallel_emitter = ParallelToolEmitter{
        .io = io,
        .emit_context = emit_context,
        .emit = emit,
    };

    for (prepared_calls.items, 0..) |prepared_tool, index| {
        tasks[index] = ParallelToolTask.init(allocator, prepared_tool, signal, &parallel_emitter);
        threads[index] = try std.Thread.spawn(.{}, runParallelToolTask, .{&tasks[index]});
    }

    for (threads) |thread| {
        thread.join();
    }
    defer {
        for (tasks) |*task| task.deinit();
    }

    for (tasks) |*task| {
        const executed = ExecutedToolCallOutcome{
            .result = if (task.result) |result|
                try cloneToolResult(result, allocator)
            else
                try createErrorToolResult(allocator, "Parallel tool execution failed"),
            .is_error = task.is_error,
        };
        const tool_result = try finalizeExecutedToolCall(
            allocator,
            current_context,
            assistant_message,
            task.prepared,
            executed,
            true,
            config,
            emit_context,
            emit,
            signal,
        );
        try results.append(allocator, tool_result);
    }

    return try results.toOwnedSlice(allocator);
}

const PreparedToolCallOrImmediate = union(enum) {
    prepared: PreparedToolCall,
    immediate: ImmediateToolCallOutcome,
};

fn prepareToolCall(
    allocator: std.mem.Allocator,
    current_context: types.AgentContext,
    assistant_message: ai.AssistantMessage,
    tool_call: ai.ToolCall,
    config: types.AgentLoopConfig,
    signal: ?*const std.atomic.Value(bool),
) !PreparedToolCallOrImmediate {
    const tool = findTool(current_context.tools, tool_call.name) orelse {
        return .{ .immediate = .{
            .result = try createErrorToolResult(allocator, try std.fmt.allocPrint(allocator, "Tool {s} not found", .{tool_call.name})),
            .is_error = true,
        } };
    };

    var args = try prepareToolCallArguments(allocator, tool, tool_call.arguments);

    if (config.before_tool_call) |before_tool_call| {
        const before_result = before_tool_call(allocator, .{
            .assistant_message = assistant_message,
            .tool_call = tool_call,
            .args = &args,
            .context = current_context,
        }, signal) catch |err| {
            deinitJsonValue(allocator, args);
            return .{ .immediate = .{
                .result = try createErrorToolResult(allocator, try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)})),
                .is_error = true,
            } };
        };

        if (before_result) |result| {
            if (result.block) {
                deinitJsonValue(allocator, args);
                return .{ .immediate = .{
                    .result = try createErrorToolResult(
                        allocator,
                        result.reason orelse "Tool execution was blocked",
                    ),
                    .is_error = true,
                } };
            }
        }
    }

    return .{ .prepared = .{
        .tool_call = tool_call,
        .tool = tool,
        .args = args,
    } };
}

fn prepareToolCallArguments(
    allocator: std.mem.Allocator,
    tool: types.AgentTool,
    args: std.json.Value,
) !std.json.Value {
    if (tool.prepare_arguments) |prepare_arguments| {
        return try prepare_arguments(allocator, args);
    }
    return try cloneJsonValue(allocator, args);
}

fn findTool(tools: []const types.AgentTool, name: []const u8) ?types.AgentTool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

fn executePreparedToolCallSequential(
    allocator: std.mem.Allocator,
    prepared: PreparedToolCall,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
) !ExecutedToolCallOutcome {
    var update_context = UpdateEmitterContext{
        .emit_context = emit_context,
        .emit = emit,
        .tool_call = prepared.tool_call,
    };
    return try executePreparedToolCallInternal(
        allocator,
        prepared,
        signal,
        &update_context,
        emitToolExecutionUpdate,
    );
}

fn executePreparedToolCallInternal(
    allocator: std.mem.Allocator,
    prepared: PreparedToolCall,
    signal: ?*const std.atomic.Value(bool),
    on_update_context: ?*anyopaque,
    on_update: ?types.AgentToolUpdateCallback,
) !ExecutedToolCallOutcome {
    const execute_tool = prepared.tool.execute orelse {
        return .{
            .result = try createErrorToolResult(allocator, "Tool has no execute function"),
            .is_error = true,
        };
    };

    const result = execute_tool(
        allocator,
        prepared.tool_call.id,
        prepared.args,
        prepared.tool.execute_context,
        signal,
        on_update_context,
        on_update,
    ) catch |err| {
        return .{
            .result = try createErrorToolResult(allocator, try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)})),
            .is_error = true,
        };
    };

    return .{
        .result = result,
        .is_error = false,
    };
}

fn emitToolExecutionUpdate(context: ?*anyopaque, partial_result: types.AgentToolResult) !void {
    const update_context: *UpdateEmitterContext = @ptrCast(@alignCast(context.?));
    try update_context.emit(update_context.emit_context, .{
        .event_type = .tool_execution_update,
        .tool_call_id = update_context.tool_call.id,
        .tool_name = update_context.tool_call.name,
        .args = update_context.tool_call.arguments,
        .partial_result = partial_result,
    });
}

fn runParallelToolTask(task: *ParallelToolTask) void {
    const outcome = executePreparedToolCallInternal(
        task.arena.allocator(),
        task.prepared,
        task.signal,
        task,
        emitParallelToolUpdate,
    ) catch {
        task.result = createErrorToolResult(task.arena.allocator(), "Parallel tool execution failed") catch unreachable;
        task.is_error = true;
        return;
    };

    task.result = outcome.result;
    task.is_error = outcome.is_error;
}

fn emitParallelToolUpdate(context: ?*anyopaque, partial_result: types.AgentToolResult) !void {
    const task: *ParallelToolTask = @ptrCast(@alignCast(context.?));
    try task.emitter.emitUpdate(.{
        .event_type = .tool_execution_update,
        .tool_call_id = task.prepared.tool_call.id,
        .tool_name = task.prepared.tool_call.name,
        .args = task.prepared.tool_call.arguments,
        .partial_result = partial_result,
    });
}

fn finalizeExecutedToolCall(
    allocator: std.mem.Allocator,
    current_context: types.AgentContext,
    assistant_message: ai.AssistantMessage,
    prepared: PreparedToolCall,
    executed: ExecutedToolCallOutcome,
    owns_result_content: bool,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
) !types.ToolResultMessage {
    var result = executed.result;
    var is_error = executed.is_error;
    var result_content_owned = owns_result_content;

    if (config.after_tool_call) |after_tool_call| {
        const after_result = after_tool_call(allocator, .{
            .assistant_message = assistant_message,
            .tool_call = prepared.tool_call,
            .args = prepared.args,
            .result = result,
            .is_error = is_error,
            .context = current_context,
        }, signal) catch |err| {
            if (result_content_owned) deinitContentBlocks(allocator, result.content);
            result = try createErrorToolResult(allocator, try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}));
            is_error = true;
            return try emitToolCallOutcome(
                allocator,
                prepared.tool_call,
                result,
                is_error,
                emit_context,
                emit,
            );
        };

        if (after_result) |override| {
            if (override.content) |content| {
                const replaced_content = !sameContentBlocks(result.content, content);
                if (result_content_owned and replaced_content) {
                    deinitContentBlocks(allocator, result.content);
                }
                result.content = content;
                if (replaced_content) result_content_owned = false;
            }
            if (override.details) |details| result.details = details;
            if (override.is_error) |next_is_error| is_error = next_is_error;
        }
    }

    return try emitToolCallOutcome(
        allocator,
        prepared.tool_call,
        result,
        is_error,
        emit_context,
        emit,
    );
}

fn createErrorToolResult(allocator: std.mem.Allocator, message: []const u8) !types.AgentToolResult {
    const content = try allocator.alloc(ai.ContentBlock, 1);
    content[0] = .{
        .text = .{
            .text = try allocator.dupe(u8, message),
        },
    };
    return .{
        .content = content,
        .details = null,
    };
}

fn emitToolCallOutcome(
    allocator: std.mem.Allocator,
    tool_call: ai.ToolCall,
    result: types.AgentToolResult,
    is_error: bool,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
) !types.ToolResultMessage {
    try emit(emit_context, .{
        .event_type = .tool_execution_end,
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .result = result,
        .is_error = is_error,
    });

    const tool_result = types.ToolResultMessage{
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .content = result.content,
        .details = result.details,
        .is_error = is_error,
        .timestamp = 0,
    };

    try emit(emit_context, .{
        .event_type = .message_start,
        .message = .{ .tool_result = tool_result },
    });
    try emit(emit_context, .{
        .event_type = .message_end,
        .message = .{ .tool_result = tool_result },
    });

    _ = allocator;
    return tool_result;
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

fn cloneToolResult(
    result: types.AgentToolResult,
    allocator: std.mem.Allocator,
) !types.AgentToolResult {
    return .{
        .content = try cloneContentBlocks(allocator, result.content),
        .details = if (result.details) |details| try cloneJsonValue(allocator, details) else null,
    };
}

fn cloneContentBlocks(
    allocator: std.mem.Allocator,
    blocks: []const ai.ContentBlock,
) ![]const ai.ContentBlock {
    const cloned = try allocator.alloc(ai.ContentBlock, blocks.len);
    errdefer allocator.free(cloned);

    for (blocks, 0..) |block, index| {
        cloned[index] = cloneContentBlock(allocator, block) catch |err| {
            deinitContentBlocks(allocator, cloned[0..index]);
            allocator.free(cloned);
            return err;
        };
    }

    return cloned;
}

fn cloneContentBlock(
    allocator: std.mem.Allocator,
    block: ai.ContentBlock,
) !ai.ContentBlock {
    return switch (block) {
        .text => |text| .{
            .text = .{
                .text = try allocator.dupe(u8, text.text),
            },
        },
        .image => |image| .{
            .image = .{
                .data = try allocator.dupe(u8, image.data),
                .mime_type = try allocator.dupe(u8, image.mime_type),
            },
        },
        .thinking => |thinking| .{
            .thinking = .{
                .thinking = try allocator.dupe(u8, thinking.thinking),
                .signature = if (thinking.signature) |signature| try allocator.dupe(u8, signature) else null,
                .redacted = thinking.redacted,
            },
        },
    };
}

fn deinitContentBlocks(
    allocator: std.mem.Allocator,
    blocks: []const ai.ContentBlock,
) void {
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
}

fn sameContentBlocks(
    lhs: []const ai.ContentBlock,
    rhs: []const ai.ContentBlock,
) bool {
    return lhs.len == rhs.len and lhs.ptr == rhs.ptr;
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

fn expectUserText(message: types.AgentMessage, expected: []const u8) !void {
    switch (message) {
        .user => |user| {
            try std.testing.expectEqual(@as(usize, 1), user.content.len);
            try std.testing.expectEqualStrings(expected, user.content[0].text.text);
        },
        else => return error.UnexpectedMessageRole,
    }
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |v| .{ .bool = v },
        .integer => |v| .{ .integer = v },
        .float => |v| .{ .float = v },
        .number_string => |v| .{ .number_string = try allocator.dupe(u8, v) },
        .string => |v| .{ .string = try allocator.dupe(u8, v) },
        .array => |arr| blk: {
            var clone = std.json.Array.init(allocator);
            errdefer {
                for (clone.items) |item| deinitJsonValue(allocator, item);
                clone.deinit();
            }
            for (arr.items) |item| {
                try clone.append(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = clone };
        },
        .object => |obj| blk: {
            var clone = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            errdefer {
                var iter = clone.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    deinitJsonValue(allocator, entry.value_ptr.*);
                }
                clone.deinit(allocator);
            }
            var iterator = obj.iterator();
            while (iterator.next()) |entry| {
                try clone.put(
                    allocator,
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try cloneJsonValue(allocator, entry.value_ptr.*),
                );
            }
            break :blk .{ .object = clone };
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
            var object_mut = object;
            var iterator = object_mut.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr.*);
            }
            object_mut.deinit(allocator);
        },
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

var active_tool_result_content_capture: ?*ToolResultContentCapture = null;

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
    const capture = active_tool_result_content_capture orelse return result;

    capture.content_ptr = result.content.ptr;
    switch (result.content[0]) {
        .text => |text| {
            capture.text_ptr = text.text.ptr;
            capture.text_len = text.text.len;
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

fn captureToolEvent(context: ?*anyopaque, event: types.AgentEvent) !void {
    const capture: *ToolExecutionCapture = @ptrCast(@alignCast(context.?));
    try capture.events.append(capture.allocator, event);
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
) ![]ai.Message {
    return @constCast(messages);
}

fn ownedDeltaStreamForAgentLoopTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    _: ai.Context,
    _: ?ai.types.SimpleStreamOptions,
) !ai.event_stream.AssistantMessageEventStream {
    const result_allocator = std.heap.page_allocator;
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
) !ai.event_stream.AssistantMessageEventStream {
    const result_allocator = std.heap.page_allocator;
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
    const final_message = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
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

var block_execute_count: usize = 0;

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
    block_execute_count += 1;
    return try echoToolExecute(allocator, tool_call_id, params, tool_context, signal, on_update_context, on_update);
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

var active_parallel_observation: ?*ParallelObservation = null;

fn parallelAwareEchoToolExecute(
    allocator: std.mem.Allocator,
    _: []const u8,
    params: std.json.Value,
    _: ?*anyopaque,
    _: ?*const std.atomic.Value(bool),
    _: ?*anyopaque,
    _: ?types.AgentToolUpdateCallback,
) !types.AgentToolResult {
    const observation = active_parallel_observation orelse return error.MissingParallelObservation;
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

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute = echoToolExecute,
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

    try std.testing.expectEqual(@as(usize, 4), result.len);
    try std.testing.expectEqualStrings("hello", result[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("echo", result[2].tool_result.tool_name);
    try std.testing.expectEqualStrings("echoed: hello", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("done", result[3].assistant.content[0].text.text);

    var saw_tool_start = false;
    var saw_tool_end = false;
    for (capture.events.items) |event| {
        if (event.event_type == .tool_execution_start) saw_tool_start = true;
        if (event.event_type == .tool_execution_end) saw_tool_end = true;
    }
    try std.testing.expect(saw_tool_start);
    try std.testing.expect(saw_tool_end);
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

    const assistant = try streamAssistantResponse(
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

    const assistant = try streamAssistantResponse(
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

    try std.testing.expectEqual(@as(usize, 1), assistant.tool_calls.?.len);
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

    var observation = ParallelObservation{};
    active_parallel_observation = &observation;
    defer active_parallel_observation = null;

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
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

test "executeToolCallsParallel returns tool result content that survives task arena cleanup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tool_args = try jsonStringObject(arena.allocator(), "value", "hello");
    const tool_calls = try arena.allocator().alloc(ai.ToolCall, 1);
    tool_calls[0] = .{
        .id = "tool-1",
        .name = "echo",
        .arguments = tool_args,
    };

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
        .execute = capturingEchoToolExecute,
    };

    var capture = ToolResultContentCapture{};
    active_tool_result_content_capture = &capture;
    defer active_tool_result_content_capture = null;

    const results = try executeToolCallsParallel(
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
            deinitContentBlocks(std.testing.allocator, result.content);
            std.testing.allocator.free(result.content);
        }
        std.testing.allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expect(capture.content_ptr != null);
    try std.testing.expect(capture.text_ptr != null);

    const scratch_blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    defer std.testing.allocator.free(scratch_blocks);
    const scratch_text = try std.testing.allocator.alloc(u8, capture.text_len);
    defer std.testing.allocator.free(scratch_text);
    @memset(scratch_text, 'x');
    scratch_blocks[0] = .{
        .text = .{
            .text = scratch_text,
        },
    };

    try std.testing.expect(results[0].content.ptr != capture.content_ptr.?);
    try std.testing.expect(results[0].content[0].text.text.ptr != capture.text_ptr.?);
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

    const results = try executeToolCallsParallel(
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
            deinitContentBlocks(std.testing.allocator, result.content);
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

    const results = try executeToolCallsParallel(
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
            deinitContentBlocks(std.testing.allocator, result.content);
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

    var observation = ParallelObservation{};
    active_parallel_observation = &observation;
    defer active_parallel_observation = null;

    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
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

    block_execute_count = 0;
    const tool = types.AgentTool{
        .name = "echo",
        .description = "Echo input",
        .label = "Echo",
        .parameters = .null,
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

    try std.testing.expectEqual(@as(usize, 0), block_execute_count);
    try std.testing.expect(result[2].tool_result.is_error);
    try std.testing.expectEqualStrings("blocked by hook", result[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("continued", result[3].assistant.content[0].text.text);
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
