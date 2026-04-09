const std = @import("std");
const ai = @import("root.zig");

pub const NormalizeToolCallIdFn = *const fn (id: []const u8, model: ai.Model, source: ai.AssistantMessage) []const u8;

/// Transforms messages for cross-provider compatibility.
/// - Normalizes tool call IDs across providers
/// - Converts thinking blocks to text when crossing models
/// - Filters out errored/aborted assistant messages
/// - Inserts synthetic tool results for orphaned tool calls
pub fn transformMessages(
    gpa: std.mem.Allocator,
    messages: []const ai.Message,
    model: ai.Model,
    normalize_tool_call_id: ?NormalizeToolCallIdFn,
) ![]ai.Message {
    // First pass: build tool call id map and transform assistant messages
    var tool_call_id_map = std.StringHashMap([]const u8).init(gpa);
    defer tool_call_id_map.deinit();

    var first_pass = std.ArrayList(ai.Message).init(gpa);
    defer first_pass.deinit();

    for (messages) |msg| {
        switch (msg) {
            .user => try first_pass.append(msg),
            .tool_result => {
                const normalized_id = tool_call_id_map.get(msg.tool_result.tool_call_id);
                if (normalized_id) |nid| {
                    if (!std.mem.eql(u8, nid, msg.tool_result.tool_call_id)) {
                        var copy = msg.tool_result;
                        copy.tool_call_id = nid;
                        try first_pass.append(.{ .tool_result = copy });
                        continue;
                    }
                }
                try first_pass.append(msg);
            },
            .assistant => |a| {
                const is_same_model = std.mem.eql(u8, a.provider, model.provider) and
                    std.mem.eql(u8, a.model, model.id) and model_api_eql(a.api, model.api);

                var new_content = std.ArrayList(ai.ContentBlock).init(gpa);
                defer new_content.deinit();

                for (a.content) |block| {
                    switch (block) {
                        .thinking => |th| {
                            if (th.redacted) {
                                if (is_same_model) try new_content.append(block);
                                continue;
                            }
                            if (is_same_model and th.thinking_signature != null and th.thinking_signature.?.len > 0) {
                                try new_content.append(block);
                                continue;
                            }
                            if (th.thinking.len == 0 or std.mem.trim(u8, th.thinking, " \t\r\n").len == 0) {
                                continue;
                            }
                            if (is_same_model) {
                                try new_content.append(block);
                            } else {
                                try new_content.append(.{ .text = .{ .text = th.thinking } });
                            }
                        },
                        .text => {
                            try new_content.append(block);
                        },
                        .tool_call => |tc| {
                            var copy = tc;
                            if (!is_same_model and tc.thought_signature != null) {
                                copy.thought_signature = null;
                            }
                            if (!is_same_model and normalize_tool_call_id != null) {
                                const norm = normalize_tool_call_id.?(tc.id, model, a);
                                if (!std.mem.eql(u8, norm, tc.id)) {
                                    try tool_call_id_map.put(tc.id, norm);
                                    copy.id = norm;
                                }
                            }
                            try new_content.append(.{ .tool_call = copy });
                        },
                        else => try new_content.append(block),
                    }
                }

                var copy = a;
                copy.content = try new_content.toOwnedSlice();
                try first_pass.append(.{ .assistant = copy });
            },
        }
    }

    // Second pass: filter errored assistant messages and insert synthetic tool results
    var result = std.ArrayList(ai.Message).init(gpa);
    defer result.deinit();

    var pending_tool_calls: std.ArrayList(ai.ToolCall) = .empty;
    defer pending_tool_calls.deinit(gpa);

    var existing_tool_result_ids = std.StringHashMap(void).init(gpa);
    defer existing_tool_result_ids.deinit();

    for (first_pass.items) |msg| {
        switch (msg) {
            .assistant => |a| {
                // Insert synthetic results for previous orphaned tool calls
                if (pending_tool_calls.items.len > 0) {
                    for (pending_tool_calls.items) |tc| {
                        if (!existing_tool_result_ids.contains(tc.id)) {
                            try result.append(.{ .tool_result = syntheticToolResult(tc) });
                        }
                    }
                    pending_tool_calls.clearRetainingCapacity();
                    existing_tool_result_ids.clearRetainingCapacity();
                }

                // Skip errored/aborted assistant messages
                if (a.stop_reason == .err or a.stop_reason == .aborted) {
                    continue;
                }

                // Track tool calls in this message
                for (a.content) |block| {
                    if (block == .tool_call) {
                        try pending_tool_calls.append(block.tool_call);
                    }
                }
                if (pending_tool_calls.items.len > 0) {
                    existing_tool_result_ids.clearRetainingCapacity();
                }

                try result.append(msg);
            },
            .tool_result => |tr| {
                _ = try existing_tool_result_ids.put(tr.tool_call_id, {});
                try result.append(msg);
            },
            .user => {
                // User message interrupts tool flow - insert synthetics
                if (pending_tool_calls.items.len > 0) {
                    for (pending_tool_calls.items) |tc| {
                        if (!existing_tool_result_ids.contains(tc.id)) {
                            try result.append(.{ .tool_result = syntheticToolResult(tc) });
                        }
                    }
                    pending_tool_calls.clearRetainingCapacity();
                    existing_tool_result_ids.clearRetainingCapacity();
                }
                try result.append(msg);
            },
        }
    }

    // After loop, any remaining pending tool calls at end should also get synthetics
    if (pending_tool_calls.items.len > 0) {
        for (pending_tool_calls.items) |tc| {
            if (!existing_tool_result_ids.contains(tc.id)) {
                try result.append(.{ .tool_result = syntheticToolResult(gpa, tc) });
            }
        }
    }

    return try result.toOwnedSlice();
}

fn model_api_eql(a: ai.Api, b: ai.Api) bool {
    return switch (a) {
        .known => |ak| switch (b) {
            .known => |bk| ak == bk,
            else => false,
        },
        .custom => |ac| switch (b) {
            .custom => |bc| std.mem.eql(u8, ac, bc),
            else => false,
        },
    };
}

fn syntheticToolResult(tc: ai.ToolCall) ai.ToolResultMessage {
    const empty_details = std.json.ObjectMap.init(std.heap.page_allocator);
    return .{
        .tool_call_id = tc.id,
        .tool_name = tc.name,
        .content = @constCast(&[_]ai.ContentBlock{.{ .text = .{ .text = "No result provided" } }}),
        .is_error = true,
        .timestamp = currentMs(),
        .details = .{ .object = empty_details },
    };
}

fn currentMs() i64 {
    const ts = std.posix.clock_gettime(std.os.linux.CLOCK.REALTIME) catch return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms);
}

test "transformMessages passes through user messages" {
    const gpa = std.testing.allocator;
    const model = testModel();
    const msgs = &[_]ai.Message{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } },
    };
    const out = try transformMessages(gpa, msgs, model, null);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(out[0] == .user);
}

test "transformMessages filters errored assistant messages" {
    const gpa = std.testing.allocator;
    const model = testModel();
    const msgs = &[_]ai.Message{
        .{ .assistant = .{
            .role = "assistant",
            .content = @constCast(&[_]ai.ContentBlock{.{ .text = .{ .text = "oops" } }}),
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = .{},
            .stop_reason = .err,
            .timestamp = 0,
        } },
    };
    const out = try transformMessages(gpa, msgs, model, null);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "transformMessages inserts synthetic tool result for orphaned tool call" {
    const gpa = std.testing.allocator;
    const model = testModel();
    const empty_args0 = std.json.ObjectMap.init(gpa);
    var content0 = [_]ai.ContentBlock{.{ .tool_call = .{ .id = "tc1", .name = "Read", .arguments = .{ .object = empty_args0 } } }};
    const msgs = &[_]ai.Message{
        .{ .assistant = .{
            .role = "assistant",
            .content = @constCast(&content0),
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        } },
        .{ .user = .{ .content = .{ .text = "next" }, .timestamp = 0 } },
    };
    const out = try transformMessages(gpa, msgs, model, null);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expect(out[0] == .assistant);
    try std.testing.expect(out[1] == .tool_result);
    try std.testing.expect(out[2] == .user);
}

test "transformMessages converts thinking to text for cross-model" {
    const gpa = std.testing.allocator;
    const model = testModel();
    var model2 = model;
    model2.id = "other";
    var content1 = [_]ai.ContentBlock{.{ .thinking = .{ .thinking = "deep thought" } }};
    const msgs = &[_]ai.Message{
        .{ .assistant = .{
            .role = "assistant",
            .content = @constCast(&content1),
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        } },
    };
    const out = try transformMessages(gpa, msgs, model2, null);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(out[0].assistant.content[0] == .text);
    try std.testing.expectEqualStrings("deep thought", out[0].assistant.content[0].text.text);
}

test "transformMessages normalizes tool call ids" {
    const gpa = std.testing.allocator;
    const model = testModel();
    var model2 = model;
    model2.id = "other";

    const normFn = struct {
        fn f(id: []const u8, _: ai.Model, _: ai.AssistantMessage) []const u8 {
            _ = id;
            return "norm-id";
        }
    }.f;

    const empty_args1 = std.json.ObjectMap.init(gpa);
    var content2 = [_]ai.ContentBlock{.{ .tool_call = .{ .id = "long-id-with-special-chars", .name = "Read", .arguments = .{ .object = empty_args1 } } }};
    var content3 = [_]ai.ContentBlock{.{ .text = .{ .text = "ok" } }};
    const msgs = &[_]ai.Message{
        .{ .assistant = .{
            .role = "assistant",
            .content = @constCast(&content2),
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        } },
        .{ .tool_result = .{
            .tool_call_id = "long-id-with-special-chars",
            .tool_name = "Read",
            .content = &content3,
            .timestamp = 0,
        } },
    };
    const out = try transformMessages(gpa, msgs, model2, normFn);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("norm-id", out[0].assistant.content[0].tool_call.id);
    try std.testing.expectEqualStrings("norm-id", out[1].tool_result.tool_call_id);
}

test "transformMessages keeps thinking for same model" {
    const gpa = std.testing.allocator;
    const model = testModel();
    var content = [_]ai.ContentBlock{.{ .thinking = .{ .thinking = "deep thought", .thinking_signature = "sig123" } }};
    const msgs = &[_]ai.Message{
        .{ .assistant = .{
            .role = "assistant",
            .content = @constCast(&content),
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        } },
    };
    const out = try transformMessages(gpa, msgs, model, null);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(out[0].assistant.content[0] == .thinking);
    try std.testing.expectEqualStrings("deep thought", out[0].assistant.content[0].thinking.thinking);
    try std.testing.expectEqualStrings("sig123", out[0].assistant.content[0].thinking.thinking_signature.?);
}

test "transformMessages drops redacted thinking for cross-model" {
    const gpa = std.testing.allocator;
    const model = testModel();
    var model2 = model;
    model2.id = "other";
    var content = [_]ai.ContentBlock{.{ .thinking = .{ .thinking = "secret", .redacted = true } }};
    const msgs = &[_]ai.Message{
        .{ .assistant = .{
            .role = "assistant",
            .content = @constCast(&content),
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        } },
    };
    const out = try transformMessages(gpa, msgs, model2, null);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "transformMessages drops empty thinking blocks" {
    const gpa = std.testing.allocator;
    const model = testModel();
    var content = [_]ai.ContentBlock{.{ .thinking = .{ .thinking = "   " } }};
    const msgs = &[_]ai.Message{
        .{ .assistant = .{
            .role = "assistant",
            .content = @constCast(&content),
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        } },
    };
    const out = try transformMessages(gpa, msgs, model, null);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "transformMessages filters aborted assistant and orphans" {
    const gpa = std.testing.allocator;
    const model = testModel();
    const empty_args = std.json.ObjectMap.init(gpa);
    var content = [_]ai.ContentBlock{.{ .tool_call = .{ .id = "tc1", .name = "Read", .arguments = .{ .object = empty_args } } }};
    const msgs = &[_]ai.Message{
        .{ .assistant = .{
            .role = "assistant",
            .content = @constCast(&content),
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = .{},
            .stop_reason = .aborted,
            .timestamp = 0,
        } },
    };
    const out = try transformMessages(gpa, msgs, model, null);
    defer gpa.free(out);
    // Aborted assistant is filtered, and orphan tool result is appended
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(out[0] == .tool_result);
}

test "transformMessages inserts synthetic tool result at end of stream" {
    const gpa = std.testing.allocator;
    const model = testModel();
    const empty_args = std.json.ObjectMap.init(gpa);
    var content = [_]ai.ContentBlock{.{ .tool_call = .{ .id = "tc1", .name = "Read", .arguments = .{ .object = empty_args } } }};
    const msgs = &[_]ai.Message{
        .{ .assistant = .{
            .role = "assistant",
            .content = @constCast(&content),
            .api = model.api,
            .provider = model.provider,
            .model = model.id,
            .usage = .{},
            .stop_reason = .stop,
            .timestamp = 0,
        } },
    };
    const out = try transformMessages(gpa, msgs, model, null);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expect(out[0] == .assistant);
    try std.testing.expect(out[1] == .tool_result);
    try std.testing.expectEqualStrings("tc1", out[1].tool_result.tool_call_id);
}

fn testModel() ai.Model {
    return .{
        .id = "test-model",
        .name = "Test",
        .api = .{ .known = .openai_completions },
        .provider = .{ .known = .openai },
        .max_tokens = 32000,
    };
}
