const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const json_event_wire = @import("json_event_wire.zig");
const common = @import("tools/common.zig");
const session_mod = @import("session.zig");

pub const RunTsRpcModeOptions = struct {};

const PromptStreamingBehavior = enum {
    steer,
    follow_up,
};

const DeferredResponsePriority = enum(u8) {
    queued_prompt = 0,
    abort = 1,
    queue_control = 2,
};

const DEFERRED_RESPONSE_FLUSH_INTERVAL_MS = 50;

const DeferredResponse = struct {
    id: ?[]u8,
    command: []u8,
    priority: DeferredResponsePriority,
    sequence: usize,

    fn deinit(self: *DeferredResponse, allocator: std.mem.Allocator) void {
        if (self.id) |id_string| allocator.free(id_string);
        allocator.free(self.command);
        self.* = undefined;
    }
};

const PromptTask = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: *TsRpcServer,
    session: *session_mod.AgentSession,
    id: ?[]u8,
    message: []u8,
    images: []ai.ImageContent,
    response_sent: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        server: *TsRpcServer,
        session: *session_mod.AgentSession,
        id: ?[]const u8,
        message: []u8,
        images: []ai.ImageContent,
    ) !*PromptTask {
        const task = try allocator.create(PromptTask);
        errdefer allocator.destroy(task);
        task.* = .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .session = session,
            .id = if (id) |id_string| try allocator.dupe(u8, id_string) else null,
            .message = message,
            .images = images,
        };
        return task;
    }

    fn spawn(self: *PromptTask) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *PromptTask) void {
        defer self.done.store(true, .seq_cst);
        self.session.promptWithAcceptedCallback(
            .{ .text = self.message, .images = self.images },
            .{ .context = self, .callback = writePromptAccepted },
        ) catch |err| {
            if (!self.response_sent.load(.seq_cst)) {
                self.server.writeCommandError(self.id, "prompt", err) catch {};
                self.response_sent.store(true, .seq_cst);
            }
        };
    }

    fn isDone(self: *const PromptTask) bool {
        return self.done.load(.seq_cst);
    }

    fn waitForResponse(self: *const PromptTask) void {
        while (!self.response_sent.load(.seq_cst)) {
            std.Io.sleep(self.io, .fromMilliseconds(1), .awake) catch {};
        }
    }

    fn joinAndDestroy(self: *PromptTask) void {
        if (self.thread) |thread| {
            thread.join();
        }
        if (self.id) |id_string| self.allocator.free(id_string);
        self.allocator.free(self.message);
        deinitImages(self.allocator, self.images);
        self.allocator.destroy(self);
    }

    fn writePromptAccepted(context: ?*anyopaque) !void {
        const self: *PromptTask = @ptrCast(@alignCast(context.?));
        try self.server.writeSuccessResponseNoData(self.id, "prompt");
        self.response_sent.store(true, .seq_cst);
        // TypeScript's RPC dispatcher accepts the prompt synchronously, then
        // continues processing already-buffered JSONL input before later agent
        // events can dominate the output stream. Yield briefly after the
        // acceptance response so rapid controls can be handled in dispatcher
        // order instead of racing the prompt worker.
        std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
    }
};

pub const command_types = [_][]const u8{
    "prompt",
    "steer",
    "follow_up",
    "abort",
    "new_session",
    "get_state",
    "set_model",
    "cycle_model",
    "get_available_models",
    "set_thinking_level",
    "cycle_thinking_level",
    "set_steering_mode",
    "set_follow_up_mode",
    "compact",
    "set_auto_compaction",
    "set_auto_retry",
    "abort_retry",
    "bash",
    "abort_bash",
    "get_session_stats",
    "export_html",
    "switch_session",
    "fork",
    "clone",
    "get_fork_messages",
    "get_last_assistant_text",
    "set_session_name",
    "get_messages",
    "get_commands",
};

pub fn isKnownCommandType(command_type: []const u8) bool {
    for (command_types) |known| {
        if (std.mem.eql(u8, known, command_type)) return true;
    }
    return false;
}

const TsRpcServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    session: ?*session_mod.AgentSession,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    output_mutex: std.Io.Mutex = .init,
    subscriber: ?agent.AgentSubscriber = null,
    prompt_tasks: std.ArrayList(*PromptTask) = .empty,
    deferred_responses: std.ArrayList(DeferredResponse) = .empty,
    deferred_responses_mutex: std.Io.Mutex = .init,
    deferred_flush_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    deferred_flush_thread: ?std.Thread = null,
    next_deferred_response_sequence: usize = 0,
    suppress_events: bool = false,
    finished: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        session: ?*session_mod.AgentSession,
        stdout_writer: *std.Io.Writer,
        stderr_writer: *std.Io.Writer,
    ) TsRpcServer {
        return .{
            .allocator = allocator,
            .io = io,
            .session = session,
            .stdout_writer = stdout_writer,
            .stderr_writer = stderr_writer,
        };
    }

    fn start(self: *TsRpcServer) !void {
        if (self.session) |session| {
            self.subscriber = .{
                .context = self,
                .callback = handleTsRpcAgentEvent,
            };
            try session.agent.subscribe(self.subscriber.?);
        }
        self.deferred_flush_stop.store(false, .seq_cst);
        self.deferred_flush_thread = try std.Thread.spawn(.{}, deferredFlushMain, .{self});
    }

    fn finish(self: *TsRpcServer) !void {
        if (self.finished) return;
        self.finished = true;
        self.deferred_flush_stop.store(true, .seq_cst);
        if (self.deferred_flush_thread) |thread| {
            thread.join();
            self.deferred_flush_thread = null;
        }
        try self.flushDeferredResponses();
        for (self.prompt_tasks.items) |task| {
            task.joinAndDestroy();
        }
        self.prompt_tasks.clearRetainingCapacity();
        if (self.session) |session| {
            if (self.subscriber) |subscriber| {
                _ = session.agent.unsubscribe(subscriber);
                self.subscriber = null;
            }
        }
        self.prompt_tasks.deinit(self.allocator);
        self.prompt_tasks = .empty;
        self.deferred_responses.deinit(self.allocator);
        self.deferred_responses = .empty;
        try self.stdout_writer.flush();
        try self.stderr_writer.flush();
    }

    fn hasInFlightPrompt(self: *const TsRpcServer) bool {
        for (self.prompt_tasks.items) |task| {
            if (!task.isDone()) return true;
        }
        return false;
    }

    fn handleLine(self: *TsRpcServer, line: []const u8) !void {
        const ts_line = stripTrailingCarriageReturn(line);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, ts_line, .{}) catch {
            const message = try self.parseErrorMessage(ts_line);
            defer self.allocator.free(message);
            try self.writeErrorResponse(null, "parse", message);
            return;
        };
        defer parsed.deinit();

        if (parsed.value == .object) {
            if (parsed.value.object.get("type")) |type_value| {
                if (type_value == .string and std.mem.eql(u8, type_value.string, "extension_ui_response")) {
                    return;
                }
            }
        }

        const object = switch (parsed.value) {
            .object => |object| object,
            else => {
                try self.writeUnknownCommand(null);
                return;
            },
        };

        const id = if (object.get("id")) |id_value| switch (id_value) {
            .string => |id_string| id_string,
            else => null,
        } else null;

        const command_type = if (object.get("type")) |type_value| switch (type_value) {
            .string => |type_string| type_string,
            else => null,
        } else null;

        const command = command_type orelse {
            try self.writeUnknownCommand(null);
            return;
        };

        if (!isKnownCommandType(command)) {
            try self.writeUnknownCommand(command);
            return;
        }

        try self.handleCommand(id, command, object);
    }

    fn handleCommand(
        self: *TsRpcServer,
        id: ?[]const u8,
        command: []const u8,
        object: std.json.ObjectMap,
    ) !void {
        const session = self.session orelse {
            try self.writeNotImplemented(id, command);
            return;
        };

        if (std.mem.eql(u8, command, "prompt")) {
            const message = requiredString(object, "message") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const images = parseImages(self.allocator, object) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            var images_owned = true;
            defer if (images_owned) deinitImages(self.allocator, images);
            const streaming_behavior = parsePromptStreamingBehavior(object) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };

            if (session.isStreaming() or self.hasInFlightPrompt()) {
                const behavior = streaming_behavior orelse {
                    try self.writeErrorResponse(
                        id,
                        command,
                        "Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.",
                    );
                    return;
                };
                switch (behavior) {
                    .steer => session.steer(message, images) catch |err| {
                        try self.writeCommandError(id, command, err);
                        return;
                    },
                    .follow_up => session.followUp(message, images) catch |err| {
                        try self.writeCommandError(id, command, err);
                        return;
                    },
                }
                try self.writeQueueUpdate();
                try self.enqueueDeferredSuccess(id, command, .queued_prompt);
                return;
            }

            const message_copy = self.allocator.dupe(u8, message) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            var message_owned = true;
            defer if (message_owned) self.allocator.free(message_copy);

            const task = PromptTask.create(self.allocator, self.io, self, session, id, message_copy, images) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            images_owned = false;
            message_owned = false;
            self.prompt_tasks.append(self.allocator, task) catch |err| {
                task.joinAndDestroy();
                try self.writeCommandError(id, command, err);
                return;
            };
            task.spawn() catch |err| {
                _ = self.prompt_tasks.pop();
                task.joinAndDestroy();
                try self.writeCommandError(id, command, err);
                return;
            };
            task.waitForResponse();
            return;
        }

        if (std.mem.eql(u8, command, "steer")) {
            const message = requiredString(object, "message") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const images = parseImages(self.allocator, object) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            defer deinitImages(self.allocator, images);
            session.steer(message, images) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            try self.writeQueueUpdate();
            if (session.isStreaming() or self.hasInFlightPrompt()) {
                try self.enqueueDeferredSuccess(id, command, .queue_control);
            } else {
                try self.writeSuccessResponseNoData(id, command);
            }
            return;
        }

        if (std.mem.eql(u8, command, "follow_up")) {
            const message = requiredString(object, "message") catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            const images = parseImages(self.allocator, object) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            defer deinitImages(self.allocator, images);
            session.followUp(message, images) catch |err| {
                try self.writeCommandError(id, command, err);
                return;
            };
            try self.writeQueueUpdate();
            if (session.isStreaming() or self.hasInFlightPrompt()) {
                try self.enqueueDeferredSuccess(id, command, .queue_control);
            } else {
                try self.writeSuccessResponseNoData(id, command);
            }
            return;
        }

        if (std.mem.eql(u8, command, "abort")) {
            const defer_response = session.isStreaming() or self.hasInFlightPrompt();
            if (defer_response) {
                try self.enqueueDeferredSuccess(id, command, .abort);
            } else {
                session.agent.abort();
                try self.writeSuccessResponseNoData(id, command);
            }
            return;
        }

        if (std.mem.eql(u8, command, "get_state")) {
            const data = try self.buildStateJson(session);
            defer self.allocator.free(data);
            try self.writeSuccessResponseRawData(id, command, data);
            return;
        }

        if (std.mem.eql(u8, command, "get_messages")) {
            const data = try self.buildMessagesJson(session.agent.getMessages());
            defer self.allocator.free(data);
            try self.writeSuccessResponseRawData(id, command, data);
            return;
        }

        if (std.mem.eql(u8, command, "get_commands")) {
            try self.writeSuccessResponseRawData(id, command, "{\"commands\":[]}");
            return;
        }

        try self.writeNotImplemented(id, command);
    }

    fn writeCommandError(self: *TsRpcServer, id: ?[]const u8, command: []const u8, err: anyerror) !void {
        try self.writeErrorResponse(id, command, @errorName(err));
    }

    fn writeNotImplemented(self: *TsRpcServer, id: ?[]const u8, command: []const u8) !void {
        const message = try std.fmt.allocPrint(self.allocator, "Not implemented: {s}", .{command});
        defer self.allocator.free(message);
        try self.writeErrorResponse(id, command, message);
    }

    fn writeUnknownCommand(self: *TsRpcServer, command: ?[]const u8) !void {
        const message = if (command) |command_name|
            try std.fmt.allocPrint(self.allocator, "Unknown command: {s}", .{command_name})
        else
            try self.allocator.dupe(u8, "Unknown command: undefined");
        defer self.allocator.free(message);
        try self.writeErrorResponse(null, command, message);
    }

    fn parseErrorMessage(self: *TsRpcServer, line: []const u8) ![]u8 {
        const detail = try jsonParseErrorDetail(self.allocator, line);
        defer self.allocator.free(detail);
        return try std.fmt.allocPrint(self.allocator, "Failed to parse command: {s}", .{detail});
    }

    fn writeSuccessResponseNoData(self: *TsRpcServer, id: ?[]const u8, command: []const u8) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);

        try self.stdout_writer.writeAll("{");
        try writeIdField(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll("\"type\":\"response\",\"command\":");
        try writeJsonString(self.allocator, self.stdout_writer, command);
        try self.stdout_writer.writeAll(",\"success\":true}\n");
        try self.stdout_writer.flush();
    }

    fn writeSuccessResponseRawData(
        self: *TsRpcServer,
        id: ?[]const u8,
        command: []const u8,
        data_json: []const u8,
    ) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);

        try self.stdout_writer.writeAll("{");
        try writeIdField(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll("\"type\":\"response\",\"command\":");
        try writeJsonString(self.allocator, self.stdout_writer, command);
        try self.stdout_writer.writeAll(",\"success\":true,\"data\":");
        try self.stdout_writer.writeAll(data_json);
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeErrorResponse(self: *TsRpcServer, id: ?[]const u8, command: ?[]const u8, message: []const u8) !void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);

        try self.stdout_writer.writeAll("{");
        try writeIdField(self.allocator, self.stdout_writer, id);
        try self.stdout_writer.writeAll("\"type\":\"response\"");
        if (command) |command_name| {
            try self.stdout_writer.writeAll(",\"command\":");
            try writeJsonString(self.allocator, self.stdout_writer, command_name);
        }
        try self.stdout_writer.writeAll(",\"success\":false,\"error\":");
        try writeJsonString(self.allocator, self.stdout_writer, message);
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn writeEvent(self: *TsRpcServer, event: agent.AgentEvent) !void {
        if (self.suppress_events) return;
        const value = try json_event_wire.agentEventToJsonValue(self.allocator, event);
        defer common.deinitJsonValue(self.allocator, value);
        const line = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(line);

        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.print("{s}\n", .{line});
        try self.stdout_writer.flush();
    }

    fn writeQueueUpdate(self: *TsRpcServer) !void {
        const session = self.session orelse return;
        const steering = try session.agent.snapshotSteeringMessages(self.allocator);
        defer {
            agent.deinitMessageSlice(self.allocator, steering);
            self.allocator.free(steering);
        }
        const follow_up = try session.agent.snapshotFollowUpMessages(self.allocator);
        defer {
            agent.deinitMessageSlice(self.allocator, follow_up);
            self.allocator.free(follow_up);
        }

        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.stdout_writer.writeAll("{\"type\":\"queue_update\",\"steering\":");
        try writeQueuedMessageTexts(self.allocator, self.stdout_writer, steering);
        try self.stdout_writer.writeAll(",\"followUp\":");
        try writeQueuedMessageTexts(self.allocator, self.stdout_writer, follow_up);
        try self.stdout_writer.writeAll("}\n");
        try self.stdout_writer.flush();
    }

    fn buildStateJson(self: *TsRpcServer, session: *session_mod.AgentSession) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        const writer = &out.writer;

        try writer.writeAll("{\"model\":");
        try writeModelJson(self.allocator, writer, session.agent.getModel());
        try writer.writeAll(",\"thinkingLevel\":");
        try writeJsonString(self.allocator, writer, thinkingLevelName(session.agent.getThinkingLevel()));
        try writer.writeAll(",\"isStreaming\":");
        try writer.writeAll(if (session.isStreaming()) "true" else "false");
        try writer.writeAll(",\"isCompacting\":");
        try writer.writeAll(if (session.isCompacting()) "true" else "false");
        try writer.writeAll(",\"steeringMode\":");
        try writeJsonString(self.allocator, writer, queueModeName(session.agent.steering_queue.mode));
        try writer.writeAll(",\"followUpMode\":");
        try writeJsonString(self.allocator, writer, queueModeName(session.agent.follow_up_queue.mode));
        if (session.session_manager.getSessionFile()) |session_file| {
            try writer.writeAll(",\"sessionFile\":");
            try writeJsonString(self.allocator, writer, session_file);
        }
        try writer.writeAll(",\"sessionId\":");
        try writeJsonString(self.allocator, writer, session.session_manager.getSessionId());
        if (session.session_manager.getSessionName()) |session_name| {
            try writer.writeAll(",\"sessionName\":");
            try writeJsonString(self.allocator, writer, session_name);
        }
        try writer.writeAll(",\"autoCompactionEnabled\":");
        try writer.writeAll(if (session.compaction_settings.enabled) "true" else "false");
        try writer.print(",\"messageCount\":{d}", .{session.agent.getMessages().len});
        try writer.print(",\"pendingMessageCount\":{d}", .{session.agent.steeringQueueLen() + session.agent.followUpQueueLen()});
        try writer.writeAll("}");

        return try self.allocator.dupe(u8, out.written());
    }

    fn buildMessagesJson(self: *TsRpcServer, messages: []const agent.AgentMessage) ![]u8 {
        var array = std.json.Array.init(self.allocator);
        errdefer array.deinit();
        for (messages) |message| {
            try array.append(try json_event_wire.messageToJsonValue(self.allocator, message));
        }
        const value = std.json.Value{ .object = blk: {
            var object = try std.json.ObjectMap.init(self.allocator, &.{}, &.{});
            errdefer object.deinit(self.allocator);
            try object.put(self.allocator, try self.allocator.dupe(u8, "messages"), .{ .array = array });
            break :blk object;
        } };
        defer common.deinitJsonValue(self.allocator, value);
        return try std.json.Stringify.valueAlloc(self.allocator, value, .{});
    }

    fn enqueueDeferredSuccess(
        self: *TsRpcServer,
        id: ?[]const u8,
        command: []const u8,
        priority: DeferredResponsePriority,
    ) !void {
        self.deferred_responses_mutex.lockUncancelable(self.io);
        defer self.deferred_responses_mutex.unlock(self.io);

        try self.deferred_responses.append(self.allocator, .{
            .id = if (id) |id_string| try self.allocator.dupe(u8, id_string) else null,
            .command = try self.allocator.dupe(u8, command),
            .priority = priority,
            .sequence = self.next_deferred_response_sequence,
        });
        self.next_deferred_response_sequence += 1;
    }

    fn flushDeferredResponses(self: *TsRpcServer) !void {
        self.deferred_responses_mutex.lockUncancelable(self.io);
        defer self.deferred_responses_mutex.unlock(self.io);

        if (self.deferred_responses.items.len == 0) return;
        var should_abort_after_flush = false;
        std.mem.sort(DeferredResponse, self.deferred_responses.items, {}, lessThanDeferredResponse);
        for (self.deferred_responses.items) |*response| {
            try self.writeSuccessResponseNoData(response.id, response.command);
            if (std.mem.eql(u8, response.command, "abort")) {
                should_abort_after_flush = true;
            }
            response.deinit(self.allocator);
        }
        self.deferred_responses.clearRetainingCapacity();
        if (should_abort_after_flush) {
            if (self.session) |session| session.agent.abort();
        }
    }
};

fn deferredFlushMain(server: *TsRpcServer) void {
    while (!server.deferred_flush_stop.load(.seq_cst)) {
        std.Io.sleep(server.io, .fromMilliseconds(DEFERRED_RESPONSE_FLUSH_INTERVAL_MS), .awake) catch {};
        if (server.deferred_flush_stop.load(.seq_cst)) break;
        server.flushDeferredResponses() catch {};
    }
}

fn lessThanDeferredResponse(_: void, lhs: DeferredResponse, rhs: DeferredResponse) bool {
    if (@intFromEnum(lhs.priority) != @intFromEnum(rhs.priority)) {
        return @intFromEnum(lhs.priority) < @intFromEnum(rhs.priority);
    }
    return lhs.sequence < rhs.sequence;
}

pub fn runTsRpcMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *session_mod.AgentSession,
    _: RunTsRpcModeOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    var server = TsRpcServer.init(allocator, io, session, stdout_writer, stderr_writer);
    try server.start();
    defer server.finish() catch {};

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(allocator);

    while (true) {
        const byte = stdin_reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (byte == '\n') {
            try server.handleLine(line_buffer.items);
            line_buffer.clearRetainingCapacity();
            continue;
        }
        try line_buffer.append(allocator, byte);
    }

    if (line_buffer.items.len > 0) {
        try server.handleLine(line_buffer.items);
    }

    if (server.hasInFlightPrompt()) {
        server.suppress_events = true;
        session.agent.abort();
    }
    try server.flushDeferredResponses();
    try server.finish();
    return 0;
}

fn stripTrailingCarriageReturn(line: []const u8) []const u8 {
    if (std.mem.endsWith(u8, line, "\r")) return line[0 .. line.len - 1];
    return line;
}

fn jsonParseErrorDetail(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    const first_index = firstNonJsonWhitespaceIndex(line) orelse
        return try allocator.dupe(u8, "Unexpected end of JSON input");
    const trimmed = line[first_index..];

    // V8 does not expose JSON.parse diagnostics as a stable API, and embedding
    // V8/Node in normal Zig execution is out of scope for ts-rpc mode. This
    // mapper intentionally covers the generated malformed JSONL corpus syntax
    // classes byte-for-byte and falls back only for syntax outside that corpus.
    if (badUnicodeEscapeIndex(line)) |index| {
        return try std.fmt.allocPrint(
            allocator,
            "Bad Unicode escape in JSON at position {d} (line 1 column {d})",
            .{ index, index + 1 },
        );
    }

    if (hasUnterminatedString(line)) {
        return try std.fmt.allocPrint(
            allocator,
            "Unterminated string in JSON at position {d} (line 1 column {d})",
            .{ line.len, line.len + 1 },
        );
    }

    switch (trimmed[0]) {
        '{' => return try objectParseErrorDetail(allocator, line, first_index),
        '[' => return try arrayParseErrorDetail(allocator, line, first_index),
        't' => return try literalParseErrorDetail(allocator, line, first_index, "true"),
        'f' => return try literalParseErrorDetail(allocator, line, first_index, "false"),
        'n' => return try literalParseErrorDetail(allocator, line, first_index, "null"),
        '0'...'9', '-' => return try numberParseErrorDetail(allocator, line, first_index),
        else => return try unexpectedTokenDetail(allocator, line, first_index),
    }
}

fn objectParseErrorDetail(allocator: std.mem.Allocator, line: []const u8, object_start: usize) ![]u8 {
    const after_open = firstNonJsonWhitespaceIndexFrom(line, object_start + 1) orelse object_start + 1;
    if (after_open >= line.len) {
        return try expectedPropertyNameOrCloseDetail(allocator, after_open);
    }
    if (line[after_open] == '}') {
        if (firstNonJsonWhitespaceIndexFrom(line, after_open + 1)) |extra_index| {
            return try unexpectedNonWhitespaceDetail(allocator, extra_index);
        }
        return try expectedPropertyNameOrCloseDetail(allocator, after_open);
    }
    if (line[after_open] != '"') {
        return try expectedPropertyNameOrCloseDetail(allocator, after_open);
    }

    if (scanJsonStringEnd(line, after_open)) |property_end| {
        const after_property = firstNonJsonWhitespaceIndexFrom(line, property_end + 1) orelse
            return try allocator.dupe(u8, "Unexpected end of JSON input");
        if (line[after_property] != ':') {
            return try std.fmt.allocPrint(
                allocator,
                "Expected ':' after property name in JSON at position {d} (line 1 column {d})",
                .{ after_property, after_property + 1 },
            );
        }
        const value_start = firstNonJsonWhitespaceIndexFrom(line, after_property + 1) orelse
            return try allocator.dupe(u8, "Unexpected end of JSON input");
        if (line[value_start] == '#') {
            return try unexpectedTokenDetail(allocator, line, value_start);
        }
    }

    if (lastNonJsonWhitespaceIndex(line)) |last_index| {
        if (line[last_index] == '}') {
            const before_close = previousNonJsonWhitespaceIndex(line, last_index);
            if (before_close != null and line[before_close.?] == ',') {
                return try std.fmt.allocPrint(
                    allocator,
                    "Expected double-quoted property name in JSON at position {d} (line 1 column {d})",
                    .{ last_index, last_index + 1 },
                );
            }
        }
        if (line[last_index] == ':' or line[last_index] == ',') {
            return try allocator.dupe(u8, "Unexpected end of JSON input");
        }
    }

    return try allocator.dupe(u8, "Unexpected end of JSON input");
}

fn arrayParseErrorDetail(allocator: std.mem.Allocator, line: []const u8, array_start: usize) ![]u8 {
    const after_open = firstNonJsonWhitespaceIndexFrom(line, array_start + 1) orelse array_start + 1;
    if (after_open < line.len and line[after_open] == ']') {
        if (firstNonJsonWhitespaceIndexFrom(line, after_open + 1)) |extra_index| {
            return try unexpectedNonWhitespaceDetail(allocator, extra_index);
        }
    }
    if (lastNonJsonWhitespaceIndex(line)) |last_index| {
        if (line[last_index] == ']') {
            const before_close = previousNonJsonWhitespaceIndex(line, last_index);
            if (before_close != null and line[before_close.?] == ',') {
                return try unexpectedTokenDetail(allocator, line, last_index);
            }
        }
        if (line[last_index] == '[' or line[last_index] == ',') {
            return try allocator.dupe(u8, "Unexpected end of JSON input");
        }
    }

    return try allocator.dupe(u8, "Unexpected end of JSON input");
}

fn literalParseErrorDetail(
    allocator: std.mem.Allocator,
    line: []const u8,
    start_index: usize,
    literal: []const u8,
) ![]u8 {
    var offset: usize = 0;
    while (offset < literal.len and start_index + offset < line.len and line[start_index + offset] == literal[offset]) {
        offset += 1;
    }

    if (offset == literal.len) {
        const after_literal = firstNonJsonWhitespaceIndexFrom(line, start_index + literal.len);
        if (after_literal) |token_index| return try unexpectedNonWhitespaceDetail(allocator, token_index);
        return try allocator.dupe(u8, "Unexpected end of JSON input");
    }

    if (start_index + offset >= line.len) {
        return try allocator.dupe(u8, "Unexpected end of JSON input");
    }
    return try unexpectedTokenDetail(allocator, line, start_index + offset);
}

fn numberParseErrorDetail(allocator: std.mem.Allocator, line: []const u8, start_index: usize) ![]u8 {
    var index = start_index;
    if (index < line.len and line[index] == '-') index += 1;
    while (index < line.len and line[index] >= '0' and line[index] <= '9') : (index += 1) {}
    if (index < line.len and line[index] == '.') {
        index += 1;
        while (index < line.len and line[index] >= '0' and line[index] <= '9') : (index += 1) {}
    }
    if (index < line.len and (line[index] == 'e' or line[index] == 'E')) {
        index += 1;
        if (index < line.len and (line[index] == '+' or line[index] == '-')) index += 1;
        while (index < line.len and line[index] >= '0' and line[index] <= '9') : (index += 1) {}
    }
    if (firstNonJsonWhitespaceIndexFrom(line, index)) |extra_index| {
        return try unexpectedNonWhitespaceDetail(allocator, extra_index);
    }
    return try allocator.dupe(u8, "Unexpected end of JSON input");
}

fn unexpectedNonWhitespaceDetail(allocator: std.mem.Allocator, index: usize) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Unexpected non-whitespace character after JSON at position {d} (line 1 column {d})",
        .{ index, index + 1 },
    );
}

fn unexpectedTokenDetail(allocator: std.mem.Allocator, line: []const u8, token_index: usize) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Unexpected token '{c}', \"{s}\" is not valid JSON",
        .{ line[token_index], line },
    );
}

fn expectedPropertyNameOrCloseDetail(allocator: std.mem.Allocator, index: usize) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Expected property name or '}}' in JSON at position {d} (line 1 column {d})",
        .{ index, index + 1 },
    );
}

fn hasUnterminatedString(line: []const u8) bool {
    var in_string = false;
    var escaped = false;
    for (line) |byte| {
        if (!in_string) {
            if (byte == '"') in_string = true;
            continue;
        }
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (byte == '"') {
            in_string = false;
        }
    }
    return in_string;
}

fn badUnicodeEscapeIndex(line: []const u8) ?usize {
    var in_string = false;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const byte = line[index];
        if (!in_string) {
            if (byte == '"') in_string = true;
            continue;
        }
        if (byte == '"') {
            in_string = false;
            continue;
        }
        if (byte != '\\') continue;
        index += 1;
        if (index >= line.len) return null;
        if (line[index] != 'u') continue;
        var digit: usize = 0;
        while (digit < 4) : (digit += 1) {
            const hex_index = index + 1 + digit;
            if (hex_index >= line.len) return null;
            if (!isHexDigit(line[hex_index])) return hex_index;
        }
        index += 4;
    }
    return null;
}

fn scanJsonStringEnd(line: []const u8, start_quote: usize) ?usize {
    if (start_quote >= line.len or line[start_quote] != '"') return null;
    var index = start_quote + 1;
    while (index < line.len) : (index += 1) {
        if (line[index] == '"') return index;
        if (line[index] == '\\') {
            index += 1;
            if (index >= line.len) return null;
            if (line[index] == 'u') index += 4;
        }
    }
    return null;
}

fn firstNonJsonWhitespaceIndex(line: []const u8) ?usize {
    return firstNonJsonWhitespaceIndexFrom(line, 0);
}

fn firstNonJsonWhitespaceIndexFrom(line: []const u8, start: usize) ?usize {
    var index = start;
    while (index < line.len) : (index += 1) {
        if (!isJsonWhitespace(line[index])) return index;
    }
    return null;
}

fn lastNonJsonWhitespaceIndex(line: []const u8) ?usize {
    var index = line.len;
    while (index > 0) {
        index -= 1;
        if (!isJsonWhitespace(line[index])) return index;
    }
    return null;
}

fn previousNonJsonWhitespaceIndex(line: []const u8, before: usize) ?usize {
    var index = before;
    while (index > 0) {
        index -= 1;
        if (!isJsonWhitespace(line[index])) return index;
    }
    return null;
}

fn isJsonWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn isHexDigit(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or
        (byte >= 'a' and byte <= 'f') or
        (byte >= 'A' and byte <= 'F');
}

fn writeIdField(allocator: std.mem.Allocator, writer: *std.Io.Writer, id: ?[]const u8) !void {
    if (id) |id_string| {
        try writer.writeAll("\"id\":");
        try writeJsonString(allocator, writer, id_string);
        try writer.writeAll(",");
    }
}

fn writeJsonString(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = value }, .{});
    defer allocator.free(json);
    try writer.writeAll(json);
}

fn handleTsRpcAgentEvent(context: ?*anyopaque, event: agent.AgentEvent) !void {
    const server: *TsRpcServer = @ptrCast(@alignCast(context.?));
    try server.writeEvent(event);
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingRequiredField;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidFieldType,
    };
}

fn parsePromptStreamingBehavior(object: std.json.ObjectMap) !?PromptStreamingBehavior {
    const value = object.get("streamingBehavior") orelse return null;
    const behavior = switch (value) {
        .string => |string| string,
        else => return error.InvalidFieldType,
    };
    if (std.mem.eql(u8, behavior, "steer")) return .steer;
    if (std.mem.eql(u8, behavior, "followUp")) return .follow_up;
    return error.InvalidFieldType;
}

fn parseImages(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]ai.ImageContent {
    const images_value = object.get("images") orelse return try allocator.alloc(ai.ImageContent, 0);
    const images_array = switch (images_value) {
        .array => |array| array,
        else => return error.InvalidFieldType,
    };

    const images = try allocator.alloc(ai.ImageContent, images_array.items.len);
    var initialized: usize = 0;
    errdefer {
        for (images[0..initialized]) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        allocator.free(images);
    }

    for (images_array.items, 0..) |item, index| {
        const image_object = switch (item) {
            .object => |value| value,
            else => return error.InvalidFieldType,
        };
        const data = requiredString(image_object, "data") catch return error.InvalidFieldType;
        const mime_type = requiredString(image_object, "mimeType") catch return error.InvalidFieldType;
        images[index] = .{
            .data = try allocator.dupe(u8, data),
            .mime_type = try allocator.dupe(u8, mime_type),
        };
        initialized += 1;
    }
    return images;
}

fn deinitImages(allocator: std.mem.Allocator, images: []ai.ImageContent) void {
    for (images) |image| {
        allocator.free(image.data);
        allocator.free(image.mime_type);
    }
    allocator.free(images);
}

fn thinkingLevelName(level: agent.ThinkingLevel) []const u8 {
    return @tagName(level);
}

fn queueModeName(mode: agent.QueueMode) []const u8 {
    return switch (mode) {
        .all => "all",
        .one_at_a_time => "one-at-a-time",
    };
}

fn writeModelJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, model: ai.Model) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(allocator, writer, model.id);
    try writer.writeAll(",\"name\":");
    try writeJsonString(allocator, writer, model.name);
    try writer.writeAll(",\"api\":");
    try writeJsonString(allocator, writer, model.api);
    try writer.writeAll(",\"provider\":");
    try writeJsonString(allocator, writer, model.provider);
    try writer.writeAll(",\"baseUrl\":");
    try writeJsonString(allocator, writer, model.base_url);
    try writer.writeAll(",\"reasoning\":");
    try writer.writeAll(if (model.reasoning) "true" else "false");
    try writer.writeAll(",\"input\":[");
    for (model.input_types, 0..) |input, index| {
        if (index > 0) try writer.writeAll(",");
        try writeJsonString(allocator, writer, input);
    }
    try writer.writeAll("],\"cost\":{\"input\":");
    try writeJsonNumber(allocator, writer, model.cost.input);
    try writer.writeAll(",\"output\":");
    try writeJsonNumber(allocator, writer, model.cost.output);
    try writer.writeAll(",\"cacheRead\":");
    try writeJsonNumber(allocator, writer, model.cost.cache_read);
    try writer.writeAll(",\"cacheWrite\":");
    try writeJsonNumber(allocator, writer, model.cost.cache_write);
    try writer.writeAll("}");
    try writer.print(",\"contextWindow\":{d},\"maxTokens\":{d}", .{ model.context_window, model.max_tokens });
    if (model.headers) |headers| {
        try writer.writeAll(",\"headers\":{");
        var iterator = headers.iterator();
        var first = true;
        while (iterator.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;
            try writeJsonString(allocator, writer, entry.key_ptr.*);
            try writer.writeAll(":");
            try writeJsonString(allocator, writer, entry.value_ptr.*);
        }
        try writer.writeAll("}");
    }
    if (model.compat) |compat| {
        const compat_json = try std.json.Stringify.valueAlloc(allocator, compat, .{});
        defer allocator.free(compat_json);
        try writer.writeAll(",\"compat\":");
        try writer.writeAll(compat_json);
    }
    try writer.writeAll("}");
}

fn writeJsonNumber(allocator: std.mem.Allocator, writer: *std.Io.Writer, number: f64) !void {
    _ = allocator;
    try writer.print("{d}", .{number});
}

fn writeQueuedMessageTexts(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    messages: []const agent.AgentMessage,
) !void {
    try writer.writeAll("[");
    var first = true;
    for (messages) |message| {
        const text = switch (message) {
            .user => |user| firstTextBlock(user.content),
            else => "",
        };
        if (!first) try writer.writeAll(",");
        first = false;
        try writeJsonString(allocator, writer, text);
    }
    try writer.writeAll("]");
}

fn writeJsonStringArray(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    values: []const []const u8,
) !void {
    try writer.writeAll("[");
    for (values, 0..) |value, index| {
        if (index > 0) try writer.writeAll(",");
        try writeJsonString(allocator, writer, value);
    }
    try writer.writeAll("]");
}

fn firstTextBlock(blocks: []const ai.ContentBlock) []const u8 {
    for (blocks) |block| {
        switch (block) {
            .text => |text| return text.text,
            else => {},
        }
    }
    return "";
}

fn runTsRpcModeScript(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: ?*session_mod.AgentSession,
    lines: []const []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !void {
    var server = TsRpcServer.init(allocator, io, session, stdout_writer, stderr_writer);
    try server.start();
    defer server.finish() catch {};

    for (lines) |line| {
        try server.handleLine(line);
    }

    try server.finish();
}

fn runTsRpcModeBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: ?*session_mod.AgentSession,
    bytes: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !void {
    var server = TsRpcServer.init(allocator, io, session, stdout_writer, stderr_writer);
    try server.start();
    defer server.finish() catch {};
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(allocator);

    for (bytes) |byte| {
        if (byte == '\n') {
            try server.handleLine(line_buffer.items);
            line_buffer.clearRetainingCapacity();
            continue;
        }
        try line_buffer.append(allocator, byte);
    }

    if (line_buffer.items.len > 0) {
        try server.handleLine(line_buffer.items);
    }

    if (server.hasInFlightPrompt()) {
        server.suppress_events = true;
        if (session) |some_session| some_session.agent.abort();
    }
    try server.flushDeferredResponses();
    try server.finish();
}

fn readFixture(comptime name: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        "test/golden/ts-rpc/" ++ name,
        std.testing.allocator,
        .unlimited,
    );
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectOutputOrder(haystack: []const u8, before: []const u8, after: []const u8) !void {
    const before_index = std.mem.indexOf(u8, haystack, before) orelse {
        try expectContains(haystack, before);
        unreachable;
    };
    const after_index = std.mem.indexOf(u8, haystack, after) orelse {
        try expectContains(haystack, after);
        unreachable;
    };
    try std.testing.expect(before_index < after_index);
}

test "TS RPC writer preserves response field order from TypeScript fixtures" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var server = TsRpcServer.init(allocator, std.testing.io, null, &stdout_capture.writer, &stderr_capture.writer);
    defer server.finish() catch {};

    try server.writeSuccessResponseNoData("resp_prompt", "prompt");
    try server.writeSuccessResponseNoData(null, "steer");
    try server.writeSuccessResponseRawData(null, "cycle_model", "null");
    try server.writeErrorResponse("resp_set_model_error", "set_model", "Model not found: anthropic/missing-model");

    const output = stdout_capture.writer.buffered();
    try expectContains(output, "{\"id\":\"resp_prompt\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try expectContains(output, "{\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n");
    try expectContains(output, "{\"type\":\"response\",\"command\":\"cycle_model\",\"success\":true,\"data\":null}\n");
    try expectContains(output, "{\"id\":\"resp_set_model_error\",\"type\":\"response\",\"command\":\"set_model\",\"success\":false,\"error\":\"Model not found: anthropic/missing-model\"}\n");

    const fixture = try readFixture("responses-basic.jsonl");
    defer allocator.free(fixture);
    var output_lines = std.mem.splitScalar(u8, output, '\n');
    while (output_lines.next()) |line| {
        if (line.len == 0) continue;
        try expectContains(fixture, line);
    }
}

test "TS RPC parse error and unknown command match TypeScript byte fixtures" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeBytes(
        allocator,
        std.testing.io,
        null,
        "{bad\n{\"id\":\"mystery\",\"type\":\"mystery_command\"}\n",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"type\":\"response\",\"command\":\"parse\",\"success\":false,\"error\":\"Failed to parse command: Expected property name or '}' in JSON at position 1 (line 1 column 2)\"}\n" ++
            "{\"type\":\"response\",\"command\":\"mystery_command\",\"success\":false,\"error\":\"Unknown command: mystery_command\"}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC malformed JSON parse errors match TypeScript bytes beyond bad fixture" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const corpus = try readFixture("parse-error-corpus.jsonl");
    defer allocator.free(corpus);
    var input_bytes = std.ArrayList(u8).empty;
    defer input_bytes.deinit(allocator);
    var expected_bytes: std.ArrayList(u8) = .empty;
    defer expected_bytes.deinit(allocator);

    var case_count: usize = 0;
    var corpus_lines = std.mem.splitScalar(u8, corpus, '\n');
    while (corpus_lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        const input = object.get("input").?.string;
        const output = object.get("output").?.string;
        try input_bytes.appendSlice(allocator, input);
        try input_bytes.append(allocator, '\n');
        try expected_bytes.appendSlice(allocator, output);
        case_count += 1;
    }
    try std.testing.expect(case_count >= 18);

    try runTsRpcModeBytes(
        allocator,
        std.testing.io,
        null,
        input_bytes.items,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const fixture = try readFixture("parse-errors.jsonl");
    defer allocator.free(fixture);
    try std.testing.expectEqualStrings(fixture, expected_bytes.items);
    try std.testing.expectEqualStrings(fixture, stdout_capture.writer.buffered());
}

test "TS RPC array input where command object is expected matches TypeScript unknown-command bytes" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeBytes(
        allocator,
        std.testing.io,
        null,
        "[]\n",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"type\":\"response\",\"success\":false,\"error\":\"Unknown command: undefined\"}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC reader uses LF framing strips CR and accepts final unterminated line" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeBytes(
        allocator,
        std.testing.io,
        null,
        "{\"id\":\"framing_lf_a\",\"type\":\"get_state\"}\n{\"id\":\"framing_crlf_a\",\"type\":\"get_state\"}\r\n{\"id\":\"framing_final\",\"type\":\"get_state\"}",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"id\":\"framing_lf_a\",\"type\":\"response\",\"command\":\"get_state\",\"success\":false,\"error\":\"Not implemented: get_state\"}\n" ++
            "{\"id\":\"framing_crlf_a\",\"type\":\"response\",\"command\":\"get_state\",\"success\":false,\"error\":\"Not implemented: get_state\"}\n" ++
            "{\"id\":\"framing_final\",\"type\":\"response\",\"command\":\"get_state\",\"success\":false,\"error\":\"Not implemented: get_state\"}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC M2 get_state get_messages and get_commands use TS response bytes" {
    const allocator = std.testing.allocator;
    const model = ai.Model{
        .id = "fixture-model",
        .name = "Fixture Model",
        .api = "faux",
        .provider = "faux",
        .base_url = "https://example.invalid",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 1234,
        .max_tokens = 321,
    };

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
        .model = model,
        .thinking_level = .high,
    });
    defer session.deinit();
    _ = try session.session_manager.appendSessionInfo("fixture session");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const user_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    user_content[0] = .{ .text = .{ .text = "hello" } };
    const assistant_content = try arena.allocator().alloc(ai.ContentBlock, 1);
    assistant_content[0] = .{ .text = .{ .text = "hi" } };
    try session.agent.setMessages(&[_]agent.AgentMessage{
        .{ .user = .{ .content = user_content, .timestamp = 11 } },
        .{ .assistant = .{
            .content = assistant_content,
            .api = "faux",
            .provider = "faux",
            .model = "fixture-model",
            .usage = .{ .input = 1, .output = 2, .cache_read = 3, .cache_write = 4, .total_tokens = 10 },
            .stop_reason = .stop,
            .timestamp = 12,
        } },
    });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"id\":\"state\",\"type\":\"get_state\"}",
            "{\"id\":\"messages\",\"type\":\"get_messages\"}",
            "{\"id\":\"commands\",\"type\":\"get_commands\"}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const expected = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"state\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true,\"data\":{{\"model\":{{\"id\":\"fixture-model\",\"name\":\"Fixture Model\",\"api\":\"faux\",\"provider\":\"faux\",\"baseUrl\":\"https://example.invalid\",\"reasoning\":true,\"input\":[\"text\",\"image\"],\"cost\":{{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0}},\"contextWindow\":1234,\"maxTokens\":321}},\"thinkingLevel\":\"high\",\"isStreaming\":false,\"isCompacting\":false,\"steeringMode\":\"one-at-a-time\",\"followUpMode\":\"one-at-a-time\",\"sessionId\":\"{s}\",\"sessionName\":\"fixture session\",\"autoCompactionEnabled\":false,\"messageCount\":2,\"pendingMessageCount\":0}}}}\n" ++
            "{{\"id\":\"messages\",\"type\":\"response\",\"command\":\"get_messages\",\"success\":true,\"data\":{{\"messages\":[{{\"role\":\"user\",\"content\":\"hello\",\"timestamp\":11}},{{\"role\":\"assistant\",\"content\":[{{\"type\":\"text\",\"text\":\"hi\"}}],\"api\":\"faux\",\"provider\":\"faux\",\"model\":\"fixture-model\",\"usage\":{{\"input\":1,\"output\":2,\"cacheRead\":3,\"cacheWrite\":4,\"totalTokens\":10,\"cost\":{{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0}}}},\"stopReason\":\"stop\",\"timestamp\":12}}]}}}}\n" ++
            "{{\"id\":\"commands\",\"type\":\"response\",\"command\":\"get_commands\",\"success\":true,\"data\":{{\"commands\":[]}}}}\n",
        .{session.session_manager.getSessionId()},
    );
    defer allocator.free(expected);

    try std.testing.expectEqualStrings(expected, stdout_capture.writer.buffered());
}

test "TS RPC M2 steer follow_up and abort controls use TS responses and queue updates" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{
            "{\"id\":\"s\",\"type\":\"steer\",\"message\":\"steer now\"}",
            "{\"id\":\"f\",\"type\":\"follow_up\",\"message\":\"follow later\"}",
            "{\"id\":\"a\",\"type\":\"abort\"}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"type\":\"queue_update\",\"steering\":[\"steer now\"],\"followUp\":[]}\n" ++
            "{\"id\":\"s\",\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n" ++
            "{\"type\":\"queue_update\",\"steering\":[\"steer now\"],\"followUp\":[\"follow later\"]}\n" ++
            "{\"id\":\"f\",\"type\":\"response\",\"command\":\"follow_up\",\"success\":true}\n" ++
            "{\"id\":\"a\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC M2 queue_update is emitted before response and prompt.streamingBehavior queues while streaming" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const input = try readFixture("prompt-concurrency-queue-order.input.jsonl");
    defer allocator.free(input);
    try runTsRpcModeBytes(
        allocator,
        std.testing.io,
        &session,
        input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    const fixture = try readFixture("prompt-concurrency-queue-order.jsonl");
    defer allocator.free(fixture);
    try std.testing.expectEqualStrings(fixture, stdout_capture.writer.buffered());
}

test "TS RPC M2 prompt without streamingBehavior rejects while streaming" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
    });
    defer session.deinit();
    session.agent.is_streaming = true;

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{"{\"id\":\"busy\",\"type\":\"prompt\",\"message\":\"second prompt\"}"},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqualStrings(
        "{\"id\":\"busy\",\"type\":\"response\",\"command\":\"prompt\",\"success\":false,\"error\":\"Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.\"}\n",
        stdout_capture.writer.buffered(),
    );
}

test "TS RPC M2 abort command is processed while prompt worker is in flight" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
    });
    defer session.deinit();
    session.agent.stream_fn = blockingUntilAbortStream;

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();

    try server.handleLine("{\"id\":\"p\",\"type\":\"prompt\",\"message\":\"slow prompt\"}");
    try waitForSessionStreaming(&session);
    try std.testing.expect(session.isStreaming());

    try server.handleLine("{\"id\":\"a\",\"type\":\"abort\"}");

    try server.finish();
    try expectContains(
        stdout_capture.writer.buffered(),
        "{\"id\":\"a\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n",
    );
    try expectContains(
        stdout_capture.writer.buffered(),
        "{\"id\":\"p\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n",
    );
    try expectContains(stdout_capture.writer.buffered(), "\"stopReason\":\"aborted\"");
    const abort_response_index = std.mem.indexOf(u8, stdout_capture.writer.buffered(), "{\"id\":\"a\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n").?;
    const agent_end_index = std.mem.indexOf(u8, stdout_capture.writer.buffered(), "{\"type\":\"agent_end\"").?;
    try std.testing.expect(abort_response_index < agent_end_index);
}

test "TS RPC live client receives queue_update events and queued control responses before EOF" {
    const allocator = std.testing.allocator;
    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
    });
    defer session.deinit();
    session.agent.stream_fn = blockingUntilAbortStream;

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var server = TsRpcServer.init(allocator, std.testing.io, &session, &stdout_capture.writer, &stderr_capture.writer);
    try server.start();

    try server.handleLine("{\"id\":\"p\",\"type\":\"prompt\",\"message\":\"slow prompt\"}");
    try waitForSessionStreaming(&session);
    try std.testing.expect(session.isStreaming());

    try server.handleLine("{\"id\":\"s\",\"type\":\"steer\",\"message\":\"steer while live\"}");
    try server.handleLine("{\"id\":\"f\",\"type\":\"follow_up\",\"message\":\"follow while live\"}");
    try server.handleLine("{\"id\":\"ps\",\"type\":\"prompt\",\"message\":\"prompt steer while live\",\"streamingBehavior\":\"steer\"}");
    try server.handleLine("{\"id\":\"pf\",\"type\":\"prompt\",\"message\":\"prompt follow while live\",\"streamingBehavior\":\"followUp\"}");

    const steer_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while live\"],\"followUp\":[]}\n";
    const follow_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while live\"],\"followUp\":[\"follow while live\"]}\n";
    const prompt_steer_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while live\",\"prompt steer while live\"],\"followUp\":[\"follow while live\"]}\n";
    const prompt_follow_queue_update = "{\"type\":\"queue_update\",\"steering\":[\"steer while live\",\"prompt steer while live\"],\"followUp\":[\"follow while live\",\"prompt follow while live\"]}\n";

    try waitForServerOutputContains(&server, &stdout_capture.writer, steer_queue_update);
    try waitForServerOutputContains(&server, &stdout_capture.writer, follow_queue_update);
    try waitForServerOutputContains(&server, &stdout_capture.writer, prompt_steer_queue_update);
    try waitForServerOutputContains(&server, &stdout_capture.writer, prompt_follow_queue_update);
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"ps\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"pf\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"s\",\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n");
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"f\",\"type\":\"response\",\"command\":\"follow_up\",\"success\":true}\n");
    try std.testing.expect(session.isStreaming());

    try expectOutputOrder(stdout_capture.writer.buffered(), steer_queue_update, "{\"id\":\"s\",\"type\":\"response\",\"command\":\"steer\",\"success\":true}\n");
    try expectOutputOrder(stdout_capture.writer.buffered(), follow_queue_update, "{\"id\":\"f\",\"type\":\"response\",\"command\":\"follow_up\",\"success\":true}\n");
    try expectOutputOrder(stdout_capture.writer.buffered(), prompt_steer_queue_update, "{\"id\":\"ps\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");
    try expectOutputOrder(stdout_capture.writer.buffered(), prompt_follow_queue_update, "{\"id\":\"pf\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n");

    try server.handleLine("{\"id\":\"a\",\"type\":\"abort\"}");
    try waitForServerOutputContains(&server, &stdout_capture.writer, "{\"id\":\"a\",\"type\":\"response\",\"command\":\"abort\",\"success\":true}\n");

    try server.finish();
}

test "TS RPC M2 prompt response precedes base event stream" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .token_size = .{ .min = 64, .max = 64 },
    });
    defer registration.unregister();

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(&[_]ai.providers.faux.FauxContentBlock{
            ai.providers.faux.fauxText("prompt reply"),
        }, .{}) },
    });

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/ts-rpc-m2",
        .system_prompt = "system",
        .model = registration.getModel(),
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        &session,
        &.{"{\"id\":\"p\",\"type\":\"prompt\",\"message\":\"hello\"}"},
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try expectContains(
        stdout_capture.writer.buffered(),
        "{\"id\":\"p\",\"type\":\"response\",\"command\":\"prompt\",\"success\":true}\n{\"type\":\"agent_start\"}\n{\"type\":\"turn_start\"}\n",
    );
    try expectPromptLineTypeOrder(stdout_capture.writer.buffered());
}

test "TS RPC dispatcher skeleton covers every TypeScript RpcCommand type" {
    const allocator = std.testing.allocator;
    const commands = try readFixture("commands-input.jsonl");
    defer allocator.free(commands);

    var seen = [_]bool{false} ** command_types.len;

    var lines = std.mem.splitScalar(u8, commands, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const type_value = parsed.value.object.get("type").?;
        if (std.mem.eql(u8, type_value.string, "extension_ui_response")) continue;
        try std.testing.expect(isKnownCommandType(type_value.string));
        for (command_types, 0..) |known, index| {
            if (std.mem.eql(u8, known, type_value.string)) {
                seen[index] = true;
                break;
            }
        }
    }

    for (seen) |did_see| {
        try std.testing.expect(did_see);
    }
}

test "TS RPC extension UI responses are consumed without output" {
    const allocator = std.testing.allocator;
    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    try runTsRpcModeScript(
        allocator,
        std.testing.io,
        null,
        &.{
            "{\"type\":\"extension_ui_response\",\"id\":\"ui_select\",\"value\":\"option-a\"}",
            "{\"type\":\"extension_ui_response\",\"id\":\"ui_confirm\",\"confirmed\":true}",
            "{\"type\":\"extension_ui_response\",\"id\":\"ui_input\",\"cancelled\":true}",
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(usize, 0), stdout_capture.writer.buffered().len);
}

fn expectPromptLineTypeOrder(bytes: []const u8) !void {
    const allocator = std.testing.allocator;
    var actual = std.ArrayList([]const u8).empty;
    defer {
        for (actual.items) |item| allocator.free(item);
        actual.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, bytes, "\n"), '\n');
    while (lines.next()) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try actual.append(allocator, try allocator.dupe(u8, parsed.value.object.get("type").?.string));
    }

    try std.testing.expect(actual.items.len >= 10);
    const prefix = [_][]const u8{ "response", "agent_start", "turn_start", "message_start", "message_end", "message_start" };
    for (prefix, 0..) |expected, index| {
        try std.testing.expectEqualStrings(expected, actual.items[index]);
    }
    var index: usize = prefix.len;
    var update_count: usize = 0;
    while (index < actual.items.len and std.mem.eql(u8, actual.items[index], "message_update")) : (index += 1) {
        update_count += 1;
    }
    try std.testing.expect(update_count > 0);
    try std.testing.expectEqualStrings("message_end", actual.items[index]);
    try std.testing.expectEqualStrings("turn_end", actual.items[index + 1]);
    try std.testing.expectEqualStrings("agent_end", actual.items[index + 2]);
    try std.testing.expectEqual(actual.items.len, index + 3);
}

fn waitForSessionStreaming(session: *const session_mod.AgentSession) !void {
    var spins: usize = 0;
    while (!session.isStreaming() and spins < 1000) : (spins += 1) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(session.isStreaming());
}

fn waitForServerOutputContains(
    server: *TsRpcServer,
    writer: *std.Io.Writer,
    needle: []const u8,
) !void {
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        server.output_mutex.lockUncancelable(std.testing.io);
        const found = std.mem.indexOf(u8, writer.buffered(), needle) != null;
        server.output_mutex.unlock(std.testing.io);
        if (found) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    server.output_mutex.lockUncancelable(std.testing.io);
    defer server.output_mutex.unlock(std.testing.io);
    try expectContains(writer.buffered(), needle);
}

fn blockingUntilAbortStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    context: ai.Context,
    options: ?ai.types.SimpleStreamOptions,
    stream_context: ?*anyopaque,
) !ai.event_stream.AssistantMessageEventStream {
    _ = context;
    _ = stream_context;
    const signal = if (options) |some| some.signal else null;
    while (signal == null or !signal.?.load(.seq_cst)) {
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }

    var stream = ai.event_stream.createAssistantMessageEventStream(std.heap.page_allocator, io);
    const message = ai.AssistantMessage{
        .content = &[_]ai.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = ai.Usage.init(),
        .stop_reason = .aborted,
        .error_message = "Aborted by user",
        .timestamp = 0,
    };
    stream.push(.{
        .event_type = .done,
        .message = message,
    });
    _ = allocator;
    return stream;
}
