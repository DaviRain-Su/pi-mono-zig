const std = @import("std");

const provider_json = @import("provider_json.zig");
const types = @import("../types.zig");

pub fn appendInlineToolCall(
    allocator: std.mem.Allocator,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    owned_tool_call: types.ToolCall,
) !void {
    try storeInlineToolCall(allocator, content_blocks, tool_calls, null, owned_tool_call);
}

pub fn insertInlineToolCall(
    allocator: std.mem.Allocator,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    insert_index: usize,
    owned_tool_call: types.ToolCall,
) !void {
    try storeInlineToolCall(allocator, content_blocks, tool_calls, insert_index, owned_tool_call);
}

fn storeInlineToolCall(
    allocator: std.mem.Allocator,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    maybe_insert_index: ?usize,
    owned_tool_call: types.ToolCall,
) !void {
    var transferred = false;
    errdefer {
        if (!transferred) freeToolCallOwned(allocator, owned_tool_call);
    }

    try tool_calls.append(allocator, owned_tool_call);
    errdefer {
        if (!transferred) _ = tool_calls.pop();
    }

    if (maybe_insert_index) |insert_index| {
        try content_blocks.insert(allocator, insert_index, .{ .tool_call = owned_tool_call });
    } else {
        try content_blocks.append(allocator, .{ .tool_call = owned_tool_call });
    }
    transferred = true;
}

pub fn freeToolCallOwned(allocator: std.mem.Allocator, tool_call: types.ToolCall) void {
    allocator.free(tool_call.id);
    allocator.free(tool_call.name);
    if (tool_call.thought_signature) |signature| allocator.free(signature);
    provider_json.freeValue(allocator, tool_call.arguments);
}

fn makeTestToolCall(
    allocator: std.mem.Allocator,
    comptime include_signature: bool,
) !types.ToolCall {
    return .{
        .id = try allocator.dupe(u8, "call_1"),
        .name = try allocator.dupe(u8, "lookup"),
        .arguments = .null,
        .thought_signature = if (include_signature) try allocator.dupe(u8, "thought-sig") else null,
    };
}

test "appendInlineToolCall transfers owned data inline and keeps borrow-only copy" {
    const allocator = std.testing.allocator;
    var content_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer content_blocks.deinit(allocator);
    var tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);

    const tool_call = try makeTestToolCall(allocator, true);
    try appendInlineToolCall(allocator, &content_blocks, &tool_calls, tool_call);
    defer freeToolCallOwned(allocator, content_blocks.items[0].tool_call);

    try std.testing.expectEqual(@as(usize, 1), content_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), tool_calls.items.len);
    try std.testing.expectEqualStrings("call_1", content_blocks.items[0].tool_call.id);
    try std.testing.expectEqualStrings("lookup", content_blocks.items[0].tool_call.name);
    try std.testing.expectEqualStrings("thought-sig", content_blocks.items[0].tool_call.thought_signature.?);
    try std.testing.expectEqual(content_blocks.items[0].tool_call.id.ptr, tool_calls.items[0].id.ptr);
    try std.testing.expectEqual(content_blocks.items[0].tool_call.name.ptr, tool_calls.items[0].name.ptr);
    try std.testing.expectEqual(content_blocks.items[0].tool_call.thought_signature.?.ptr, tool_calls.items[0].thought_signature.?.ptr);
}

test "insertInlineToolCall transfers owned data at requested content index" {
    const allocator = std.testing.allocator;
    var content_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer content_blocks.deinit(allocator);
    var tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);

    try content_blocks.append(allocator, .{ .text = .{ .text = "before" } });
    try content_blocks.append(allocator, .{ .text = .{ .text = "after" } });

    const tool_call = try makeTestToolCall(allocator, false);
    try insertInlineToolCall(allocator, &content_blocks, &tool_calls, 1, tool_call);
    defer freeToolCallOwned(allocator, content_blocks.items[1].tool_call);

    try std.testing.expectEqual(@as(usize, 3), content_blocks.items.len);
    try std.testing.expect(content_blocks.items[1] == .tool_call);
    try std.testing.expectEqual(@as(usize, 1), tool_calls.items.len);
    try std.testing.expectEqual(content_blocks.items[1].tool_call.id.ptr, tool_calls.items[0].id.ptr);
}

test "appendInlineToolCall frees owned data when tool-call bookkeeping append fails" {
    var failing_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    const allocator = failing_state.allocator();
    var content_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer content_blocks.deinit(allocator);
    var tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);

    const tool_call = try makeTestToolCall(allocator, false);
    try std.testing.expectError(error.OutOfMemory, appendInlineToolCall(allocator, &content_blocks, &tool_calls, tool_call));
    try std.testing.expectEqual(@as(usize, 0), content_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), tool_calls.items.len);
}

test "appendInlineToolCall rolls back bookkeeping when inline append fails" {
    var failing_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 4 });
    const allocator = failing_state.allocator();
    var content_blocks: std.ArrayList(types.ContentBlock) = .empty;
    defer content_blocks.deinit(allocator);
    var tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer tool_calls.deinit(allocator);

    const tool_call = try makeTestToolCall(allocator, true);
    try std.testing.expectError(error.OutOfMemory, appendInlineToolCall(allocator, &content_blocks, &tool_calls, tool_call));
    try std.testing.expectEqual(@as(usize, 0), content_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), tool_calls.items.len);
}
