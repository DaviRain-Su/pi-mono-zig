const std = @import("std");
const ai = @import("../root.zig");

const DEFAULT_API = "faux";
const DEFAULT_PROVIDER = "faux";
const DEFAULT_MODEL_ID = "faux-1";
const DEFAULT_MODEL_NAME = "Faux Model";
const DEFAULT_BASE_URL = "http://localhost:0";
const DEFAULT_MIN_TOKEN_SIZE = 3;
const DEFAULT_MAX_TOKEN_SIZE = 5;

pub fn fauxText(text: []const u8) ai.ContentBlock {
    return .{ .text = .{ .text = text } };
}

pub fn fauxThinking(thinking: []const u8) ai.ContentBlock {
    return .{ .thinking = .{ .thinking = thinking } };
}

pub fn fauxToolCall(name: []const u8, args: std.json.Value, id: ?[]const u8) ai.ContentBlock {
    return .{ .tool_call = .{
        .id = id orelse "tool:1",
        .name = name,
        .arguments = args,
    } };
}

pub fn fauxAssistantMessage(content: []const ai.ContentBlock, stop_reason: ai.StopReason) ai.AssistantMessage {
    return .{
        .role = "assistant",
        .content = @constCast(content),
        .api = .{ .known = .faux },
        .provider = .{ .known = .faux },
        .model = DEFAULT_MODEL_ID,
        .usage = .{},
        .stop_reason = stop_reason,
        .timestamp = blk: {
            const ts = std.posix.clock_gettime(std.os.linux.CLOCK.REALTIME) catch break :blk 0;
            break :blk @as(i64, ts.sec) * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms);
        },
    };
}

fn estimateTokens(text: []const u8) usize {
    return @max(1, (text.len + 3) / 4);
}

fn splitStringByTokenSize(gpa: std.mem.Allocator, text: []const u8, min_tok: usize, max_tok: usize) ![]const []const u8 {
    var chunks = std.ArrayList([]const u8).empty;
    var index: usize = 0;
    while (index < text.len) {
        const token_size = min_tok + @mod(@as(usize, @intCast(text.len + index)), max_tok - min_tok + 1);
        const char_size = @max(1, token_size * 4);
        const end = @min(index + char_size, text.len);
        try chunks.append(gpa, text[index..end]);
        index = end;
    }
    if (chunks.items.len == 0) {
        try chunks.append(gpa, "");
    }
    return try chunks.toOwnedSlice(gpa);
}

fn streamWithDeltas(
    gpa: std.mem.Allocator,
    es: *ai.AssistantMessageEventStream,
    message: ai.AssistantMessage,
    min_tok: usize,
    max_tok: usize,
) !void {
    var partial: ai.AssistantMessage = .{
        .role = message.role,
        .content = &.{},
        .api = message.api,
        .provider = message.provider,
        .model = message.model,
        .usage = message.usage,
        .stop_reason = message.stop_reason,
        .timestamp = message.timestamp,
    };

    es.push(.{ .start = .{ .partial = partial } });

    for (message.content, 0..) |block, idx| {
        switch (block) {
            .thinking => |th| {
                var curr = partial;
                var new_content = try gpa.alloc(ai.ContentBlock, partial.content.len + 1);
                @memcpy(new_content[0..partial.content.len], partial.content);
                new_content[partial.content.len] = .{ .thinking = .{ .thinking = "" } };
                curr.content = new_content;
                partial = curr;
                es.push(.{ .thinking_start = .{ .content_index = idx, .partial = partial } });

                const chunks = try splitStringByTokenSize(gpa, th.thinking, min_tok, max_tok);
                defer gpa.free(chunks);
                for (chunks) |chunk| {
                    _ = std.os.linux.nanosleep(&.{ .sec = 0, .nsec = 1_000_000 }, null); // 1ms micro-delay
                    var thinking_block = &partial.content[idx].thinking;
                    const old = thinking_block.thinking;
                    const combined = try std.fmt.allocPrint(gpa, "{s}{s}", .{ old, chunk });
                    if (old.len > 0) gpa.free(old);
                    thinking_block.*.thinking = combined;
                    es.push(.{ .thinking_delta = .{ .content_index = idx, .delta = chunk, .partial = partial } });
                }
                es.push(.{ .thinking_end = .{ .content_index = idx, .content = th.thinking, .partial = partial } });
            },
            .text => |txt| {
                var curr = partial;
                var new_content = try gpa.alloc(ai.ContentBlock, partial.content.len + 1);
                @memcpy(new_content[0..partial.content.len], partial.content);
                new_content[partial.content.len] = .{ .text = .{ .text = "" } };
                curr.content = new_content;
                partial = curr;
                es.push(.{ .text_start = .{ .content_index = idx, .partial = partial } });

                const chunks = try splitStringByTokenSize(gpa, txt.text, min_tok, max_tok);
                defer gpa.free(chunks);
                for (chunks) |chunk| {
                    _ = std.os.linux.nanosleep(&.{ .sec = 0, .nsec = 1_000_000 }, null);
                    var text_block = &partial.content[idx].text;
                    const old = text_block.text;
                    const combined = try std.fmt.allocPrint(gpa, "{s}{s}", .{ old, chunk });
                    if (old.len > 0) gpa.free(old);
                    text_block.*.text = combined;
                    es.push(.{ .text_delta = .{ .content_index = idx, .delta = chunk, .partial = partial } });
                }
                es.push(.{ .text_end = .{ .content_index = idx, .content = txt.text, .partial = partial } });
            },
            .tool_call => |tc| {
                var curr = partial;
                var new_content = try gpa.alloc(ai.ContentBlock, partial.content.len + 1);
                @memcpy(new_content[0..partial.content.len], partial.content);
                const empty_args = std.json.ObjectMap.init(gpa);
                new_content[partial.content.len] = .{ .tool_call = .{ .id = tc.id, .name = tc.name, .arguments = .{ .object = empty_args } } };
                curr.content = new_content;
                partial = curr;
                es.push(.{ .toolcall_start = .{ .content_index = idx, .partial = partial } });

                const args_str = try std.fmt.allocPrint(gpa, "{f}", .{std.json.fmt(tc.arguments, .{})});
                defer gpa.free(args_str);
                const chunks = try splitStringByTokenSize(gpa, args_str, min_tok, max_tok);
                defer gpa.free(chunks);
                for (chunks) |chunk| {
                    _ = std.os.linux.nanosleep(&.{ .sec = 0, .nsec = 1_000_000 }, null);
                    es.push(.{ .toolcall_delta = .{ .content_index = idx, .delta = chunk, .partial = partial } });
                }
                partial.content[idx].tool_call.arguments = tc.arguments;
                es.push(.{ .toolcall_end = .{ .content_index = idx, .tool_call = tc, .partial = partial } });
            },
            else => {},
        }
    }

    if (message.stop_reason == .err or message.stop_reason == .aborted) {
        es.push(.{ .err_event = .{ .reason = message.stop_reason, .err_msg = message } });
        es.end(message);
        return;
    }

    es.push(.{ .done = .{ .reason = message.stop_reason, .message = message } });
    es.end(message);
}

var faux_responses = std.ArrayList(ai.AssistantMessage).empty;
var faux_mutex = std.Thread.Mutex{};
var registered = std.atomic.Value(bool).init(false);

pub fn registerFauxProvider() void {
    if (registered.swap(true, .acq_rel)) return;
    faux_mutex.lock();
    defer faux_mutex.unlock();
    faux_responses = std.ArrayList(ai.AssistantMessage).empty;

    const model = ai.Model{
        .id = DEFAULT_MODEL_ID,
        .name = DEFAULT_MODEL_NAME,
        .api = .{ .known = .faux },
        .provider = .{ .known = .faux },
        .base_url = DEFAULT_BASE_URL,
        .reasoning = false,
        .input_types = &.{ "text", "image" },
        .context_window = 128000,
        .max_tokens = 16384,
    };
    ai.registerModel(model);

    const stream_fn: ai.api_registry.ApiStreamFunction = struct {
        fn f(request_model: ai.Model, context: ai.Context, options: ?ai.types.StreamOptions) ai.AssistantMessageEventStream {
            _ = context;
            _ = options;
            const gpa = std.heap.page_allocator;
            var es = ai.createAssistantMessageEventStream(gpa) catch @panic("OOM");

            faux_mutex.lock();
            const step = if (faux_responses.items.len > 0) faux_responses.orderedRemove(0) else null;
            faux_mutex.unlock();

            if (step == null) {
                const err_msg = ai.AssistantMessage{
                    .role = "assistant",
                    .content = &.{},
                    .api = request_model.api,
                    .provider = request_model.provider,
                    .model = request_model.id,
                    .usage = .{},
                    .stop_reason = .err,
                    .error_message = "No more faux responses queued",
                    .timestamp = currentMs(),
                };
                es.push(.{ .err_event = .{ .reason = .err, .err_msg = err_msg } });
                es.end(err_msg);
                return es;
            }

            const msg = step.?;
            var cloned = msg;
            cloned.model = request_model.id;
            cloned.api = request_model.api;
            cloned.provider = request_model.provider;

            // Estimate tokens
            var usage = ai.Usage{};
            usage.input = 0;
            usage.output = @intCast(estimateTokens("faux output"));
            usage.total_tokens = usage.input + usage.output;
            cloned.usage = usage;

            const es_ptr = gpa.create(ai.AssistantMessageEventStream) catch @panic("OOM");
            es_ptr.* = es;

            const thread = std.Thread.spawn(.{}, struct {
                fn run(g: std.mem.Allocator, e: *ai.AssistantMessageEventStream, m: ai.AssistantMessage) !void {
                    try streamWithDeltas(g, e, m, DEFAULT_MIN_TOKEN_SIZE, DEFAULT_MAX_TOKEN_SIZE);
                    g.destroy(e);
                }
            }.run, .{ gpa, es_ptr, cloned }) catch @panic("OOM");
            thread.detach();

            return es;
        }
    }.f;

    const stream_simple: ai.api_registry.ApiStreamSimpleFunction = struct {
        fn f(m: ai.Model, c: ai.Context, o: ?ai.SimpleStreamOptions) ai.AssistantMessageEventStream {
            return stream_fn(m, c, if (o) |so| so.base else null);
        }
    }.f;

    ai.registerApiProvider(.{
        .api = .{ .known = .faux },
        .stream = stream_fn,
        .stream_simple = stream_simple,
    });
}

/// Clear queue and set new responses.
pub fn setFauxResponses(responses: []const ai.AssistantMessage) void {
    faux_mutex.lock();
    defer faux_mutex.unlock();
    faux_responses.clearRetainingCapacity();
    for (responses) |r| {
        faux_responses.append(std.heap.page_allocator, r) catch @panic("OOM");
    }
}

/// Append responses without clearing the queue so multiple tests can queue sequentially.
pub fn addFauxResponses(responses: []const ai.AssistantMessage) void {
    faux_mutex.lock();
    defer faux_mutex.unlock();
    for (responses) |r| {
        faux_responses.append(std.heap.page_allocator, r) catch @panic("OOM");
    }
}

/// Convenience wrapper to add a single text response.
pub fn addFauxTextResponse(text: []const u8) void {
    const gpa = std.heap.page_allocator;
    const content = gpa.alloc(ai.ContentBlock, 1) catch @panic("OOM");
    content[0] = fauxText(text);
    const msg = fauxAssistantMessage(content, .stop);
    addFauxResponses(&[_]ai.AssistantMessage{msg});
}

fn currentMs() i64 {
    const ts = std.posix.clock_gettime(std.os.linux.CLOCK.REALTIME) catch return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms);
}
