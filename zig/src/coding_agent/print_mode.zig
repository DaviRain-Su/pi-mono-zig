const builtin = @import("builtin");
const std = @import("std");
const ai = @import("ai");

pub const OutputMode = enum {
    text,
    json,
};

pub const RunPrintModeOptions = struct {
    mode: OutputMode = .text,
    signal: ?*std.atomic.Value(bool) = null,
    install_signal_handlers: bool = true,
};

const JsonToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: std.json.Value,
};

const JsonUsage = struct {
    input: u32,
    output: u32,
    cache_read: u32,
    cache_write: u32,
    total_tokens: u32,
};

const JsonMessage = struct {
    api: []const u8,
    provider: []const u8,
    model: []const u8,
    stop_reason: []const u8,
    error_message: ?[]const u8 = null,
    usage: JsonUsage,
};

const JsonEvent = struct {
    event_type: []const u8,
    content_index: ?u32 = null,
    delta: ?[]const u8 = null,
    content: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    tool_call: ?JsonToolCall = null,
    message: ?JsonMessage = null,
};

const SignalGuard = struct {
    previous_sigint: ?std.posix.Sigaction = null,
    installed: bool = false,

    fn install(signal: *std.atomic.Value(bool)) SignalGuard {
        if (!supportsPosixSignals()) return .{};

        active_abort_signal = signal;
        const action: std.posix.Sigaction = .{
            .handler = .{ .sigaction = handleSigint },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO | std.posix.SA.RESTART,
        };

        var previous: std.posix.Sigaction = undefined;
        std.posix.sigaction(.INT, &action, &previous);
        return .{
            .previous_sigint = previous,
            .installed = true,
        };
    }

    fn deinit(self: *SignalGuard) void {
        if (!self.installed or !supportsPosixSignals()) return;
        if (self.previous_sigint) |previous| {
            std.posix.sigaction(.INT, &previous, null);
        }
        active_abort_signal = null;
        self.* = .{};
    }
};

var active_abort_signal: ?*std.atomic.Value(bool) = null;

fn supportsPosixSignals() bool {
    return switch (builtin.os.tag) {
        .windows, .wasi, .emscripten, .freestanding => false,
        else => true,
    };
}

fn handleSigint(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    _ = info;
    _ = ctx_ptr;
    if (sig != .INT) return;
    if (active_abort_signal) |signal| {
        signal.store(true, .seq_cst);
    }
}

pub fn runPrintMode(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    context: ai.Context,
    stream_options: ai.StreamOptions,
    options: RunPrintModeOptions,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    var local_abort_signal = std.atomic.Value(bool).init(false);
    const abort_signal = options.signal orelse &local_abort_signal;

    var signal_guard = if (options.install_signal_handlers and options.signal == null)
        SignalGuard.install(abort_signal)
    else
        SignalGuard{};
    defer signal_guard.deinit();

    var effective_options = stream_options;
    effective_options.signal = abort_signal;

    var stream_instance = ai.stream(allocator, io, model, context, effective_options) catch |err| {
        try stderr_writer.print("Error: {s}\n", .{@errorName(err)});
        try stderr_writer.flush();
        return 1;
    };
    defer stream_instance.deinit();

    while (stream_instance.next()) |event| {
        if (options.mode == .json) {
            try writeJsonEventLine(allocator, stdout_writer, event);
        }
    }

    const message = stream_instance.result() orelse {
        try stderr_writer.writeAll("Error: missing completion result\n");
        try stderr_writer.flush();
        return 1;
    };

    if (options.mode == .text) {
        const exit_code = try writeTextOutput(stdout_writer, stderr_writer, message);
        try stdout_writer.flush();
        try stderr_writer.flush();
        return exit_code;
    }

    const exit_code = exitCodeForMessage(message);
    if (exit_code != 0) {
        try stderr_writer.print("{s}\n", .{message.error_message orelse defaultStopReasonMessage(message.stop_reason)});
    }
    try stdout_writer.flush();
    try stderr_writer.flush();
    return exit_code;
}

fn writeTextOutput(
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    message: ai.AssistantMessage,
) !u8 {
    const exit_code = exitCodeForMessage(message);
    if (exit_code != 0) {
        try stderr_writer.print("{s}\n", .{message.error_message orelse defaultStopReasonMessage(message.stop_reason)});
        return exit_code;
    }

    for (message.content) |content| {
        switch (content) {
            .text => |text| try stdout_writer.print("{s}\n", .{text.text}),
            else => {},
        }
    }
    return 0;
}

fn exitCodeForMessage(message: ai.AssistantMessage) u8 {
    return switch (message.stop_reason) {
        .error_reason, .aborted => 1,
        else => 0,
    };
}

fn writeJsonEventLine(
    allocator: std.mem.Allocator,
    stdout_writer: *std.Io.Writer,
    event: ai.AssistantMessageEvent,
) !void {
    const payload = JsonEvent{
        .event_type = @tagName(event.event_type),
        .content_index = event.content_index,
        .delta = event.delta,
        .content = event.content,
        .error_message = event.error_message,
        .tool_call = if (event.tool_call) |tool_call| .{
            .id = tool_call.id,
            .name = tool_call.name,
            .arguments = tool_call.arguments,
        } else null,
        .message = if (event.message) |message| .{
            .api = message.api,
            .provider = message.provider,
            .model = message.model,
            .stop_reason = stopReasonString(message.stop_reason),
            .error_message = message.error_message,
            .usage = .{
                .input = message.usage.input,
                .output = message.usage.output,
                .cache_read = message.usage.cache_read,
                .cache_write = message.usage.cache_write,
                .total_tokens = message.usage.total_tokens,
            },
        } else null,
    };

    const line = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(line);

    try stdout_writer.print("{s}\n", .{line});
}

fn defaultStopReasonMessage(stop_reason: ai.StopReason) []const u8 {
    return switch (stop_reason) {
        .stop => "Request stopped",
        .length => "Request reached output limit",
        .tool_use => "Request ended with tool use",
        .error_reason => "Request failed",
        .aborted => "Request was aborted",
    };
}

fn stopReasonString(stop_reason: ai.StopReason) []const u8 {
    return switch (stop_reason) {
        .error_reason => "error",
        else => @tagName(stop_reason),
    };
}

test "print mode text outputs assistant text to stdout" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    const content = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    defer allocator.free(content);
    content[0] = ai.providers.faux.fauxText("hello from faux");

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(content, .{}) },
    });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const user_content = [_]ai.ContentBlock{.{ .text = .{ .text = "hello" } }};
    const messages = [_]ai.Message{.{ .user = .{
        .content = user_content[0..],
        .timestamp = 1,
    } }};
    const context = ai.Context{
        .system_prompt = "sys",
        .messages = messages[0..],
    };

    const exit_code = try runPrintMode(
        allocator,
        std.testing.io,
        registration.getModel(),
        context,
        .{},
        .{
            .mode = .text,
            .install_signal_handlers = false,
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("hello from faux\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "print mode json outputs valid JSON lines for all events" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    const content = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    defer allocator.free(content);
    content[0] = ai.providers.faux.fauxText("json output");

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(content, .{}) },
    });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const user_content = [_]ai.ContentBlock{.{ .text = .{ .text = "hello" } }};
    const messages = [_]ai.Message{.{ .user = .{
        .content = user_content[0..],
        .timestamp = 1,
    } }};
    const context = ai.Context{
        .system_prompt = "sys",
        .messages = messages[0..],
    };

    const exit_code = try runPrintMode(
        allocator,
        std.testing.io,
        registration.getModel(),
        context,
        .{},
        .{
            .mode = .json,
            .install_signal_handlers = false,
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    var lines = std.mem.splitScalar(u8, stdout_capture.writer.buffered(), '\n');
    var saw_start = false;
    var saw_done = false;
    var line_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        const event_type = parsed.value.object.get("event_type").?.string;
        if (std.mem.eql(u8, event_type, "start")) saw_start = true;
        if (std.mem.eql(u8, event_type, "done")) saw_done = true;
    }

    try std.testing.expect(line_count >= 3);
    try std.testing.expect(saw_start);
    try std.testing.expect(saw_done);
}

test "print mode returns exit code one and writes stderr on provider error" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();

    const content = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    defer allocator.free(content);
    content[0] = ai.providers.faux.fauxText("boom");

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(content, .{
            .stop_reason = .error_reason,
            .error_message = "faux failure",
        }) },
    });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const user_content = [_]ai.ContentBlock{.{ .text = .{ .text = "hello" } }};
    const messages = [_]ai.Message{.{ .user = .{
        .content = user_content[0..],
        .timestamp = 1,
    } }};
    const context = ai.Context{
        .system_prompt = "sys",
        .messages = messages[0..],
    };

    const exit_code = try runPrintMode(
        allocator,
        std.testing.io,
        registration.getModel(),
        context,
        .{},
        .{
            .mode = .text,
            .install_signal_handlers = false,
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "faux failure\n") != null);
}

test "print mode treats abort as failure" {
    const allocator = std.testing.allocator;
    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{
        .tokens_per_second = 10,
    });
    defer registration.unregister();

    const long_text = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";
    const content = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    defer allocator.free(content);
    content[0] = ai.providers.faux.fauxText(long_text);

    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .message = ai.providers.faux.fauxAssistantMessage(content, .{}) },
    });

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const user_content = [_]ai.ContentBlock{.{ .text = .{ .text = "hello" } }};
    const messages = [_]ai.Message{.{ .user = .{
        .content = user_content[0..],
        .timestamp = 1,
    } }};
    const context = ai.Context{
        .system_prompt = "sys",
        .messages = messages[0..],
    };

    var abort_signal = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(signal: *std.atomic.Value(bool)) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake) catch {};
            signal.store(true, .seq_cst);
        }
    }.run, .{&abort_signal});
    defer thread.join();

    const exit_code = try runPrintMode(
        allocator,
        std.testing.io,
        registration.getModel(),
        context,
        .{},
        .{
            .mode = .text,
            .signal = &abort_signal,
            .install_signal_handlers = false,
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "Request was aborted\n") != null);
}
