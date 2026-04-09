const std = @import("std");
const types = @import("types.zig");

pub const AssistantMessageEvent = union(enum) {
    start: struct { partial: types.AssistantMessage },
    text_start: struct { content_index: usize, partial: types.AssistantMessage },
    text_delta: struct { content_index: usize, delta: []const u8, partial: types.AssistantMessage },
    text_end: struct { content_index: usize, content: []const u8, partial: types.AssistantMessage },
    thinking_start: struct { content_index: usize, partial: types.AssistantMessage },
    thinking_delta: struct { content_index: usize, delta: []const u8, partial: types.AssistantMessage },
    thinking_end: struct { content_index: usize, content: []const u8, partial: types.AssistantMessage },
    toolcall_start: struct { content_index: usize, partial: types.AssistantMessage },
    toolcall_delta: struct { content_index: usize, delta: []const u8, partial: types.AssistantMessage },
    toolcall_end: struct { content_index: usize, tool_call: types.ToolCall, partial: types.AssistantMessage },
    done: struct { reason: types.StopReason, message: types.AssistantMessage },
    err_event: struct { reason: types.StopReason, err_msg: types.AssistantMessage },
};

/// zig version of TS EventStream.
/// Generic over Event type and Result type.
pub fn EventStream(comptime Event: type, comptime Result: type) type {
    return struct {
        const Self = @This();
        const Inner = struct {
            mutex: std.Thread.Mutex = .{},
            cond: std.Thread.Condition = .{},
            queue: std.ArrayList(Event) = .empty,
            done: bool = false,
            result: ?Result = null,
            gpa: std.mem.Allocator,
            is_complete_fn: *const fn (event: Event) bool,
            extract_result_fn: *const fn (event: Event) Result,
        };
        inner: *Inner,

        pub fn init(
            gpa_: std.mem.Allocator,
            is_complete: *const fn (event: Event) bool,
            extract_result: *const fn (event: Event) Result,
        ) !Self {
            const ptr = try gpa_.create(Inner);
            ptr.* = .{
                .mutex = .{},
                .cond = .{},
                .queue = .empty,
                .done = false,
                .result = null,
                .gpa = gpa_,
                .is_complete_fn = is_complete,
                .extract_result_fn = extract_result,
            };
            return .{ .inner = ptr };
        }

        pub fn deinit(self: *Self) void {
            self.inner.mutex.lock();
            self.inner.queue.deinit(self.inner.gpa);
            const gpa = self.inner.gpa;
            gpa.destroy(self.inner);
            // Defensive: make subsequent accidental access to self.inner fail
            // under safety checks instead of causing silent UAF.
            self.inner = undefined;
        }

        pub fn push(self: *Self, event: Event) void {
            const s = self.inner;
            s.mutex.lock();
            defer s.mutex.unlock();
            if (s.done) return;
            if (s.is_complete_fn(event)) {
                s.result = s.extract_result_fn(event);
                s.done = true;
            }
            s.queue.append(s.gpa, event) catch @panic("OOM");
            s.cond.broadcast();
        }

        pub fn end(self: *Self, r: ?Result) void {
            const s = self.inner;
            s.mutex.lock();
            defer s.mutex.unlock();
            s.done = true;
            if (r) |val| s.result = val;
            s.cond.broadcast();
        }

        pub fn next(self: *Self) ?Event {
            const s = self.inner;
            s.mutex.lock();
            defer s.mutex.unlock();
            while (s.queue.items.len == 0 and !s.done) {
                s.cond.wait(&s.mutex);
            }
            if (s.queue.items.len == 0) return null;
            return s.queue.orderedRemove(0);
        }

        pub fn getResult(self: *Self) ?Result {
            const s = self.inner;
            s.mutex.lock();
            defer s.mutex.unlock();
            return s.result;
        }

        pub fn waitResult(self: *Self) ?Result {
            const s = self.inner;
            s.mutex.lock();
            defer s.mutex.unlock();
            while (!s.done) {
                s.cond.wait(&s.mutex);
            }
            return s.result;
        }
    };
}

pub const AssistantMessageEventStream = EventStream(AssistantMessageEvent, types.AssistantMessage);

pub fn createAssistantMessageEventStream(gpa: std.mem.Allocator) !AssistantMessageEventStream {
    return try AssistantMessageEventStream.init(gpa, isComplete, extractResult);
}

fn isComplete(event: AssistantMessageEvent) bool {
    return switch (event) {
        .done, .err_event => true,
        else => false,
    };
}

fn extractResult(event: AssistantMessageEvent) types.AssistantMessage {
    return switch (event) {
        .done => |d| d.message,
        .err_event => |e| e.err_msg,
        else => unreachable,
    };
}

test "EventStream basic push and next" {
    const gpa = std.testing.allocator;
    var es = try createAssistantMessageEventStream(gpa);
    defer es.deinit();

    const msg = types.AssistantMessage{ .role = "assistant", .content = &[_]types.ContentBlock{}, .api = .{ .known = .faux }, .provider = .{ .known = .openai }, .model = "test", .usage = .{}, .stop_reason = .stop, .timestamp = 0 };
    es.push(.{ .start = .{ .partial = msg } });
    es.push(.{ .done = .{ .reason = .stop, .message = msg } });

    const ev1 = es.next().?;
    try std.testing.expect(ev1 == .start);

    const ev2 = es.next().?;
    try std.testing.expect(ev2 == .done);

    try std.testing.expectEqual(@as(?types.AssistantMessage, null), es.next());
}

test "EventStream waitResult" {
    const gpa = std.testing.allocator;
    var es = try createAssistantMessageEventStream(gpa);

    const msg = types.AssistantMessage{ .role = "assistant", .content = &[_]types.ContentBlock{}, .api = .{ .known = .faux }, .provider = .{ .known = .openai }, .model = "test", .usage = .{}, .stop_reason = .stop, .timestamp = 0 };
    const thread = std.Thread.spawn(.{}, struct {
        fn run(e: *AssistantMessageEventStream, m: types.AssistantMessage) void {
            e.push(.{ .start = .{ .partial = m } });
            e.push(.{ .done = .{ .reason = .stop, .message = m } });
        }
    }.run, .{ &es, msg }) catch @panic("spawn");

    const result = es.waitResult();
    thread.join();
    es.deinit();
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("assistant", result.?.role);
}
