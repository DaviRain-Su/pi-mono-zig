const std = @import("std");
const ai = @import("ai");
const provider_json = ai.provider_json;
const types = @import("types.zig");
const content_clone = @import("content_clone.zig");
const json_schema = @import("json_schema.zig");

pub const PreparedToolCall = struct {
    tool_call: ai.ToolCall,
    tool: types.AgentTool,
    args: std.json.Value,
    finalized: bool = false,

    pub fn deinit(self: *PreparedToolCall, allocator: std.mem.Allocator) void {
        provider_json.freeValue(allocator, self.args);
    }
};

pub const ImmediateToolCallOutcome = struct {
    result: types.AgentToolResult,
    is_error: bool,
};

pub const ExecutedToolCallOutcome = struct {
    result: types.AgentToolResult,
    is_error: bool,
};

pub const FinalizedToolCallOutcome = struct {
    result: types.AgentToolResult,
    is_error: bool,
};

/// Partial tool-call UX policy:
/// - Every toolcall_start/toolcall_delta/toolcall_end still emits a
///   message_update so RPC/streaming clients can observe argument
///   accumulation and finalization order.
/// - Partial arguments are exposed in the callback-scoped partial assistant
///   message only when another assistant block anchors the transcript row.
///   A standalone leading tool call is hidden from message.content until the

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
    source_index: usize,
    completion_counter: *std.atomic.Value(usize),
    completion_order: usize = std.math.maxInt(usize),
    signal: ?*const std.atomic.Value(bool),
    emitter: *ParallelToolEmitter,
    result: ?types.AgentToolResult = null,
    is_error: bool = false,

    fn init(
        parent_allocator: std.mem.Allocator,
        prepared: PreparedToolCall,
        source_index: usize,
        completion_counter: *std.atomic.Value(usize),
        signal: ?*const std.atomic.Value(bool),
        emitter: *ParallelToolEmitter,
    ) ParallelToolTask {
        return .{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .prepared = prepared,
            .source_index = source_index,
            .completion_counter = completion_counter,
            .signal = signal,
            .emitter = emitter,
        };
    }

    fn deinit(self: *ParallelToolTask) void {
        self.arena.deinit();
    }
};

const PreparedToolCallEntry = struct {
    prepared: PreparedToolCall,
    source_index: usize,
};

const ImmediateToolCallEntry = struct {
    tool_call: ai.ToolCall,
    outcome: ImmediateToolCallOutcome,
    source_index: usize,
};

pub const PreparedToolCallOrImmediate = union(enum) {
    prepared: PreparedToolCall,
    immediate: ImmediateToolCallOutcome,
};

pub fn executeToolCalls(
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

pub fn executeToolCallsSequential(
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
                const finalized = try finalizeExecutedToolCall(
                    allocator,
                    current_context,
                    assistant_message,
                    &owned_prepared_tool,
                    executed,
                    false,
                    config,
                    emit_context,
                    emit,
                    signal,
                );
                break :blk try emitToolResultMessageForToolCall(
                    owned_prepared_tool.tool_call,
                    finalized.result,
                    finalized.is_error,
                    emit_context,
                    emit,
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

pub fn executeToolCallsParallel(
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
    const result_slots = try allocator.alloc(?types.ToolResultMessage, tool_calls.len);
    @memset(result_slots, null);
    defer allocator.free(result_slots);

    var prepared_calls = std.ArrayList(PreparedToolCallEntry).empty;
    defer {
        for (prepared_calls.items) |*entry| {
            entry.prepared.deinit(allocator);
        }
        prepared_calls.deinit(allocator);
    }
    var immediate_calls = std.ArrayList(ImmediateToolCallEntry).empty;
    defer immediate_calls.deinit(allocator);

    for (tool_calls, 0..) |tool_call, source_index| {
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
            .prepared => |prepared_tool| try prepared_calls.append(allocator, .{
                .prepared = prepared_tool,
                .source_index = source_index,
            }),
            .immediate => |immediate| try immediate_calls.append(allocator, .{
                .tool_call = tool_call,
                .outcome = immediate,
                .source_index = source_index,
            }),
        }
    }

    try finalizeImmediateToolCallsInSourceOrder(
        immediate_calls.items,
        result_slots,
        emit_context,
        emit,
    );

    if (prepared_calls.items.len == 0) {
        try emitParallelToolResultMessagesInSourceOrder(result_slots, emit_context, emit);
        return try collectParallelToolResultsInSourceOrder(allocator, result_slots);
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
    var completion_counter = std.atomic.Value(usize).init(0);

    for (prepared_calls.items, 0..) |entry, index| {
        tasks[index] = ParallelToolTask.init(
            allocator,
            entry.prepared,
            entry.source_index,
            &completion_counter,
            signal,
            &parallel_emitter,
        );
        threads[index] = try std.Thread.spawn(.{}, runParallelToolTask, .{&tasks[index]});
    }

    for (threads) |thread| {
        thread.join();
    }
    defer {
        for (tasks) |*task| task.deinit();
    }

    const completion_order = try allocator.alloc(usize, task_count);
    defer allocator.free(completion_order);
    fillTaskCompletionOrder(completion_order, tasks);

    for (completion_order) |task_index| {
        const task = &tasks[task_index];
        const executed = ExecutedToolCallOutcome{
            .result = if (task.result) |result|
                try content_clone.cloneToolResult(result, allocator)
            else
                try createErrorToolResult(allocator, "Parallel tool execution failed"),
            .is_error = task.is_error,
        };
        const finalized = try finalizeExecutedToolCall(
            allocator,
            current_context,
            assistant_message,
            &task.prepared,
            executed,
            true,
            config,
            emit_context,
            emit,
            signal,
        );
        result_slots[task.source_index] = createToolResultMessage(
            task.prepared.tool_call,
            finalized.result,
            finalized.is_error,
        );
    }

    try emitParallelToolResultMessagesInSourceOrder(result_slots, emit_context, emit);
    return try collectParallelToolResultsInSourceOrder(allocator, result_slots);
}


pub fn prepareToolCall(
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

    var args = prepareToolCallArguments(allocator, tool, tool_call.arguments) catch |err| {
        return .{ .immediate = .{
            .result = try createErrorToolResult(allocator, try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)})),
            .is_error = true,
        } };
    };
    if (try json_schema.validateToolArguments(allocator, tool.parameters, args)) |failure| {
        defer failure.deinit(allocator);
        const result = if (tool.invalid_arguments_result) |invalid_arguments_result|
            try invalid_arguments_result(
                allocator,
                tool_call.id,
                args,
                tool.execute_context,
                .{
                    .code = failure.code,
                    .message = failure.message,
                    .path = failure.path,
                },
            )
        else
            try createErrorToolResult(allocator, "InvalidToolArguments");
        provider_json.freeValue(allocator, args);
        return .{ .immediate = .{
            .result = result,
            .is_error = true,
        } };
    }

    if (config.before_tool_call) |before_tool_call| {
        const before_result = before_tool_call(allocator, .{
            .assistant_message = assistant_message,
            .tool_call = tool_call,
            .args = &args,
            .context = current_context,
        }, signal) catch |err| {
            provider_json.freeValue(allocator, args);
            return .{ .immediate = .{
                .result = try createErrorToolResult(allocator, @errorName(err)),
                .is_error = true,
            } };
        };

        if (before_result) |result| {
            if (result.block) {
                provider_json.freeValue(allocator, args);
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
    return try provider_json.cloneValue(allocator, args);
}

pub fn findTool(tools: []const types.AgentTool, name: []const u8) ?types.AgentTool {
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
        .is_error = result.is_error,
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
        task.result = createErrorToolResult(task.arena.allocator(), "Parallel tool execution failed") catch
            // Arena allocation failed in worker thread — produce a minimal
            // static error result so the parallel task still reports failure
            // to the agent loop without crashing.
            @as(?types.AgentToolResult, .{
                .content = &.{.{ .text = .{ .text = "Parallel tool execution failed" } }},
                .is_error = true,
            });
        task.is_error = true;
        task.completion_order = task.completion_counter.fetchAdd(1, .seq_cst);
        return;
    };

    task.result = outcome.result;
    task.is_error = outcome.is_error;
    task.completion_order = task.completion_counter.fetchAdd(1, .seq_cst);
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

pub fn finalizeExecutedToolCall(
    allocator: std.mem.Allocator,
    current_context: types.AgentContext,
    assistant_message: ai.AssistantMessage,
    prepared: *PreparedToolCall,
    executed: ExecutedToolCallOutcome,
    owns_result_content: bool,
    config: types.AgentLoopConfig,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
    signal: ?*const std.atomic.Value(bool),
) !FinalizedToolCallOutcome {
    if (prepared.finalized) return types.AgentLoopError.ToolCallAlreadyFinalized;
    prepared.finalized = true;

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
            if (result_content_owned) content_clone.deinitContentBlocks(allocator, result.content);
            result = try createErrorToolResult(allocator, try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}));
            is_error = true;
            try emitToolExecutionEnd(
                prepared.tool_call,
                result,
                is_error,
                emit_context,
                emit,
            );
            return .{ .result = result, .is_error = is_error };
        };

        if (after_result) |override| {
            if (override.content) |content| {
                const replaced_content = !content_clone.sameContentBlocks(result.content, content);
                if (result_content_owned and replaced_content) {
                    content_clone.deinitContentBlocks(allocator, result.content);
                }
                result.content = content;
                if (replaced_content) result_content_owned = false;
            }
            if (override.details) |details| result.details = details;
            if (override.is_error) |next_is_error| is_error = next_is_error;
        }
    }

    result.is_error = is_error;
    try emitToolExecutionEnd(
        prepared.tool_call,
        result,
        is_error,
        emit_context,
        emit,
    );
    return .{ .result = result, .is_error = is_error };
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
        .is_error = true,
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
    _ = allocator;
    const tool_result = try finalizeImmediateToolCall(
        tool_call,
        result,
        is_error,
        emit_context,
        emit,
    );
    try emitToolResultMessage(tool_result, emit_context, emit);
    return tool_result;
}

fn finalizeImmediateToolCall(
    tool_call: ai.ToolCall,
    result: types.AgentToolResult,
    is_error: bool,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
) !types.ToolResultMessage {
    try emitToolExecutionEnd(tool_call, result, is_error, emit_context, emit);
    return createToolResultMessage(tool_call, result, is_error);
}

fn finalizeImmediateToolCallsInSourceOrder(
    immediate_calls: []const ImmediateToolCallEntry,
    result_slots: []?types.ToolResultMessage,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
) !void {
    for (immediate_calls) |entry| {
        result_slots[entry.source_index] = try finalizeImmediateToolCall(
            entry.tool_call,
            entry.outcome.result,
            entry.outcome.is_error,
            emit_context,
            emit,
        );
    }
}

fn emitToolExecutionEnd(
    tool_call: ai.ToolCall,
    result: types.AgentToolResult,
    is_error: bool,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
) !void {
    var emitted_result = result;
    emitted_result.is_error = is_error;
    try emit(emit_context, .{
        .event_type = .tool_execution_end,
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .args = tool_call.arguments,
        .result = emitted_result,
        .is_error = is_error,
    });
}

fn createToolResultMessage(
    tool_call: ai.ToolCall,
    result: types.AgentToolResult,
    is_error: bool,
) types.ToolResultMessage {
    var emitted_result = result;
    emitted_result.is_error = is_error;
    return .{
        .tool_call_id = tool_call.id,
        .tool_name = tool_call.name,
        .content = emitted_result.content,
        .details = emitted_result.details,
        .is_error = is_error,
        .timestamp = types.nowMilliseconds(),
    };
}

fn emitToolResultMessage(
    tool_result: types.ToolResultMessage,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
) !void {
    try emit(emit_context, .{
        .event_type = .message_start,
        .message = .{ .tool_result = tool_result },
    });
    try emit(emit_context, .{
        .event_type = .message_end,
        .message = .{ .tool_result = tool_result },
    });
}

fn emitToolResultMessageForToolCall(
    tool_call: ai.ToolCall,
    result: types.AgentToolResult,
    is_error: bool,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
) !types.ToolResultMessage {
    const tool_result = createToolResultMessage(tool_call, result, is_error);
    try emitToolResultMessage(tool_result, emit_context, emit);
    return tool_result;
}

fn collectParallelToolResultsInSourceOrder(
    allocator: std.mem.Allocator,
    result_slots: []const ?types.ToolResultMessage,
) ![]const types.ToolResultMessage {
    var results = try std.ArrayList(types.ToolResultMessage).initCapacity(allocator, result_slots.len);
    errdefer results.deinit(allocator);

    for (result_slots) |slot| {
        const tool_result = slot orelse return error.MissingToolResult;
        try results.append(allocator, tool_result);
    }

    return try results.toOwnedSlice(allocator);
}

fn emitParallelToolResultMessagesInSourceOrder(
    result_slots: []const ?types.ToolResultMessage,
    emit_context: ?*anyopaque,
    emit: types.AgentEventCallback,
) !void {
    for (result_slots) |slot| {
        const tool_result = slot orelse return error.MissingToolResult;
        try emitToolResultMessage(tool_result, emit_context, emit);
    }
}

fn fillTaskCompletionOrder(order: []usize, tasks: []const ParallelToolTask) void {
    for (order, 0..) |*slot, index| slot.* = index;

    var index: usize = 1;
    while (index < order.len) : (index += 1) {
        const task_index = order[index];
        const task_completion = tasks[task_index].completion_order;
        var cursor = index;
        while (cursor > 0 and tasks[order[cursor - 1]].completion_order > task_completion) : (cursor -= 1) {
            order[cursor] = order[cursor - 1];
        }
        order[cursor] = task_index;
    }
}
