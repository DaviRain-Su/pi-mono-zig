const std = @import("std");
const types = @import("types.zig");

/// Generic event stream for async iteration.
/// T is the event type, R is the result type.
pub fn EventStream(comptime T: type, comptime R: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        queue: std.ArrayList(T),
        done: bool = false,
        final_result: ?R = null,
        mutex: std.Io.Mutex = .init,
        condition: std.Io.Condition = .init,
        io: std.Io,
        is_complete_fn: *const fn (event: T) bool,
        extract_result_fn: *const fn (event: T) R,

        pub const IteratorResult = struct {
            value: ?T,
            done: bool,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            is_complete: *const fn (event: T) bool,
            extract_result: *const fn (event: T) R,
        ) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .queue = std.ArrayList(T).empty,
                .done = false,
                .final_result = null,
                .is_complete_fn = is_complete,
                .extract_result_fn = extract_result,
            };
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit(self.allocator);
        }

        pub fn push(self: *Self, event: T) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.done) return;

            if (self.is_complete_fn(event)) {
                self.done = true;
                self.final_result = self.extract_result_fn(event);
            }

            self.queue.append(self.allocator, event) catch {
                self.done = true;
                self.condition.broadcast(self.io);
                return;
            };
            self.condition.signal(self.io);
        }

        pub fn end(self: *Self, final_result: ?R) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.done = true;
            if (final_result) |r| {
                self.final_result = r;
            }

            self.condition.broadcast(self.io);
        }

        pub fn next(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            while (self.queue.items.len == 0 and !self.done) {
                self.condition.waitUncancelable(self.io, &self.mutex);
            }

            if (self.queue.items.len > 0) {
                return self.queue.orderedRemove(0);
            }

            return null;
        }

        pub fn result(self: *Self) ?R {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.final_result;
        }
    };
}

/// Check if an AssistantMessageEvent indicates completion
fn isCompleteEvent(event: types.AssistantMessageEvent) bool {
    return event.event_type == .done or event.event_type == .error_event;
}

/// Extract the final result from a completion event
fn extractResult(event: types.AssistantMessageEvent) types.AssistantMessage {
    if (event.event_type == .done) {
        return event.message.?;
    } else if (event.event_type == .error_event) {
        // For error events, create an error message
        return .{
            .role = "assistant",
            .content = &[_]types.ContentBlock{},
            .api = "",
            .provider = "",
            .model = "",
            .usage = types.Usage.init(),
            .stop_reason = .error_reason,
            .error_message = event.error_message,
            .timestamp = 0,
        };
    }
    unreachable;
}

pub const AssistantMessageEventStream = EventStream(types.AssistantMessageEvent, types.AssistantMessage);

pub fn createAssistantMessageEventStream(allocator: std.mem.Allocator, io: std.Io) AssistantMessageEventStream {
    return AssistantMessageEventStream.init(
        allocator,
        io,
        isCompleteEvent,
        extractResult,
    );
}

test "EventStream basic operations" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    var stream = AssistantMessageEventStream.init(
        allocator,
        io,
        isCompleteEvent,
        extractResult,
    );
    defer stream.deinit();

    // Push a start event
    stream.push(.{
        .event_type = .start,
    });

    // Push a text delta event
    stream.push(.{
        .event_type = .text_delta,
        .delta = "Hello",
    });

    // Push done event
    const msg = types.AssistantMessage{
        .role = "assistant",
        .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4",
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1234567890,
    };
    stream.push(.{
        .event_type = .done,
        .message = msg,
    });

    // Read events
    const event1 = stream.next().?;
    try std.testing.expectEqual(types.EventType.start, event1.event_type);

    const event2 = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, event2.event_type);
    try std.testing.expectEqualStrings("Hello", event2.delta.?);

    const event3 = stream.next().?;
    try std.testing.expectEqual(types.EventType.done, event3.event_type);

    // Stream should be done
    try std.testing.expect(stream.next() == null);

    // Check final result
    const result = stream.result().?;
    try std.testing.expectEqualStrings("gpt-4", result.model);
}

test "EventStream end without events" {
    const allocator = std.testing.allocator;
    const io = std.Io.failing;
    var stream = AssistantMessageEventStream.init(
        allocator,
        io,
        isCompleteEvent,
        extractResult,
    );
    defer stream.deinit();

    const msg = types.AssistantMessage{
        .role = "assistant",
        .content = &[_]types.ContentBlock{},
        .api = "openai-completions",
        .provider = "openai",
        .model = "gpt-4",
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 1234567890,
    };

    stream.end(msg);

    try std.testing.expect(stream.next() == null);
    const result = stream.result().?;
    try std.testing.expectEqualStrings("gpt-4", result.model);
}

test "EventStream next blocks until producer pushes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var stream = AssistantMessageEventStream.init(
        allocator,
        io,
        isCompleteEvent,
        extractResult,
    );
    defer stream.deinit();

    const TestContext = struct {
        stream: *AssistantMessageEventStream,

        fn producer(ctx: *@This()) void {
            std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch {};
            ctx.stream.push(.{ .event_type = .start });
        }
    };

    var ctx = TestContext{ .stream = &stream };
    const producer_thread = try std.Thread.spawn(.{}, TestContext.producer, .{&ctx});
    defer producer_thread.join();

    const started_at = std.Io.Clock.awake.now(io);
    const event = stream.next().?;
    const elapsed_ns = started_at.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;

    try std.testing.expectEqual(types.EventType.start, event.event_type);
    try std.testing.expect(elapsed_ns >= 20 * std.time.ns_per_ms);
}

test "EventStream supports single-producer single-consumer concurrency" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const IntStream = EventStream(u32, u32);
    const intIsComplete = struct {
        fn f(_: u32) bool {
            return false;
        }
    }.f;
    const intExtractResult = struct {
        fn f(event: u32) u32 {
            return event;
        }
    }.f;

    var stream = IntStream.init(
        allocator,
        io,
        intIsComplete,
        intExtractResult,
    );
    defer stream.deinit();

    const TestContext = struct {
        stream: *IntStream,
        count: u32,

        fn producer(ctx: *@This()) void {
            for (0..ctx.count) |index| {
                ctx.stream.push(@intCast(index));
            }
            ctx.stream.end(null);
        }
    };

    var ctx = TestContext{
        .stream = &stream,
        .count = 128,
    };

    const producer_thread = try std.Thread.spawn(.{}, TestContext.producer, .{&ctx});
    defer producer_thread.join();

    var expected: u32 = 0;
    while (stream.next()) |value| {
        try std.testing.expectEqual(expected, value);
        expected += 1;
    }

    try std.testing.expectEqual(ctx.count, expected);
}
