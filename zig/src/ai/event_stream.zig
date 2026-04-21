const std = @import("std");
const types = @import("types.zig");

/// Generic event stream for async iteration.
/// T is the event type, R is the result type.
pub fn EventStream(comptime T: type, comptime R: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        queue: std.ArrayList(T),
        waiting: std.ArrayList(*IteratorResult),
        done: bool = false,
        final_result: ?R = null,
        mutex: std.Io.Mutex = .init,
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
                .waiting = std.ArrayList(*IteratorResult).empty,
                .done = false,
                .final_result = null,
                .is_complete_fn = is_complete,
                .extract_result_fn = extract_result,
            };
        }

        pub fn deinit(self: *Self) void {
            self.queue.deinit(self.allocator);
            self.waiting.deinit(self.allocator);
        }

        pub fn push(self: *Self, event: T) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.done) return;

            if (self.is_complete_fn(event)) {
                self.done = true;
                self.final_result = self.extract_result_fn(event);
            }

            // Deliver to waiting consumer or queue it
            if (self.waiting.items.len > 0) {
                const waiter = self.waiting.orderedRemove(0);
                waiter.* = .{ .value = event, .done = false };
            } else {
                self.queue.append(self.allocator, event) catch {};
            }
        }

        pub fn end(self: *Self, final_result: ?R) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.done = true;
            if (final_result) |r| {
                self.final_result = r;
            }

            // Notify all waiting consumers that we're done
            for (self.waiting.items) |waiter| {
                waiter.* = .{ .value = null, .done = true };
            }
            self.waiting.clearRetainingCapacity();
        }

        pub fn next(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            while (true) {
                if (self.queue.items.len > 0) {
                    return self.queue.orderedRemove(0);
                } else if (self.done) {
                    return null;
                } else {
                    // Wait for an event
                    var iter_result: IteratorResult = .{ .value = null, .done = false };
                    self.waiting.append(self.allocator, &iter_result) catch {
                        return null;
                    };
                    self.mutex.unlock(self.io);
                    // Busy wait for result
                    while (!iter_result.done and iter_result.value == null) {
                        std.Thread.yield() catch {};
                    }
                    self.mutex.lockUncancelable(self.io);
                    self.waiting.clearRetainingCapacity();

                    if (iter_result.done) return null;
                    if (iter_result.value) |value| return value;
                }
            }
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
