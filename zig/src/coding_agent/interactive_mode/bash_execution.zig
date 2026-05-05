const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const session_mod = @import("../session.zig");
const common = @import("../tools/common.zig");

pub fn contentBlocksTextAlloc(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(allocator);

    for (blocks, 0..) |block, index| {
        if (index > 0) try text.append(allocator, '\n');
        switch (block) {
            .text => |text_block| try text.appendSlice(allocator, text_block.text),
            .image => try text.appendSlice(allocator, "[image]"),
            .thinking => |thinking| try text.appendSlice(allocator, thinking.thinking),
            .tool_call => |tool_call| try text.appendSlice(allocator, tool_call.name),
        }
    }

    return try text.toOwnedSlice(allocator);
}

fn appendFmt(
    builder: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try builder.appendSlice(allocator, text);
}

pub fn bashContextTextAlloc(
    allocator: std.mem.Allocator,
    command: []const u8,
    output: []const u8,
    exit_code: ?u8,
    cancelled: bool,
    truncated: bool,
    full_output_path: ?[]const u8,
) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    try appendFmt(&builder, allocator, "Ran `{s}`\n", .{command});
    if (output.len > 0) {
        try builder.appendSlice(allocator, "```\n");
        try builder.appendSlice(allocator, output);
        try builder.appendSlice(allocator, "\n```");
    } else {
        try builder.appendSlice(allocator, "(no output)");
    }
    if (cancelled) {
        try builder.appendSlice(allocator, "\n\n(command cancelled)");
    } else if (exit_code) |code| {
        if (code != 0) try appendFmt(&builder, allocator, "\n\nCommand exited with code {d}", .{code});
    }
    if (truncated) {
        if (full_output_path) |path| {
            try appendFmt(&builder, allocator, "\n\n[Output truncated. Full output: {s}]", .{path});
        }
    }

    return try builder.toOwnedSlice(allocator);
}

pub fn bashDetailsJsonValue(
    allocator: std.mem.Allocator,
    command: []const u8,
    output: []const u8,
    exit_code: ?u8,
    cancelled: bool,
    truncated: bool,
    full_output_path: ?[]const u8,
    exclude_from_context: bool,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer common.deinitJsonValue(allocator, .{ .object = object });

    try object.put(allocator, try allocator.dupe(u8, "command"), .{ .string = try allocator.dupe(u8, command) });
    try object.put(allocator, try allocator.dupe(u8, "output"), .{ .string = try allocator.dupe(u8, output) });
    if (exit_code) |code| {
        try object.put(allocator, try allocator.dupe(u8, "exitCode"), .{ .integer = @intCast(code) });
    }
    try object.put(allocator, try allocator.dupe(u8, "cancelled"), .{ .bool = cancelled });
    try object.put(allocator, try allocator.dupe(u8, "truncated"), .{ .bool = truncated });
    if (full_output_path) |path| {
        try object.put(allocator, try allocator.dupe(u8, "fullOutputPath"), .{ .string = try allocator.dupe(u8, path) });
    }
    try object.put(allocator, try allocator.dupe(u8, "excludeFromContext"), .{ .bool = exclude_from_context });

    return .{ .object = object };
}

pub fn recordBashExecution(
    allocator: std.mem.Allocator,
    session: *session_mod.AgentSession,
    command: []const u8,
    output: []const u8,
    exit_code: ?u8,
    cancelled: bool,
    truncated: bool,
    full_output_path: ?[]const u8,
    exclude_from_context: bool,
) !void {
    const context_text = try bashContextTextAlloc(
        allocator,
        command,
        output,
        exit_code,
        cancelled,
        truncated,
        full_output_path,
    );
    defer allocator.free(context_text);

    if (!exclude_from_context) {
        var context_message = agent.AgentMessage{ .user = .{
            .role = try allocator.dupe(u8, "user"),
            .content = try common.makeTextContent(allocator, context_text),
            .timestamp = agent.nowMilliseconds(),
        } };
        defer agent.deinitMessage(allocator, &context_message);
        try session.agent.appendMessage(context_message);
    }

    const details = try bashDetailsJsonValue(
        allocator,
        command,
        output,
        exit_code,
        cancelled,
        truncated,
        full_output_path,
        exclude_from_context,
    );
    defer common.deinitJsonValue(allocator, details);

    _ = try session.session_manager.appendCustomMessageEntry(
        "bashExecution",
        .{ .text = context_text },
        true,
        details,
    );
}

pub fn formatBashExecutionDisplay(
    allocator: std.mem.Allocator,
    command: []const u8,
    output: []const u8,
    exit_code: ?u8,
    cancelled: bool,
    truncated: bool,
    full_output_path: ?[]const u8,
    exclude_from_context: bool,
    running: bool,
) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    try appendFmt(&builder, allocator, "$ {s}", .{command});
    if (exclude_from_context) try builder.appendSlice(allocator, " [excluded from context]");
    if (output.len > 0) {
        try builder.appendSlice(allocator, "\n");
        try builder.appendSlice(allocator, output);
    }
    if (running) {
        try builder.appendSlice(allocator, "\n(Running... Esc to cancel)");
    } else if (cancelled) {
        try builder.appendSlice(allocator, "\n(cancelled)");
    } else if (exit_code) |code| {
        if (code != 0) try appendFmt(&builder, allocator, "\n(exit {d})", .{code});
    }
    if (truncated) {
        if (full_output_path) |path| {
            try appendFmt(&builder, allocator, "\nOutput truncated. Full output: {s}", .{path});
        }
    }
    return try builder.toOwnedSlice(allocator);
}
