const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const session_mod = @import("../session.zig");
const common = @import("../tools/common.zig");

const PREVIEW_LOGICAL_LINES: usize = 20;

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

pub fn sanitizeBashToolOutputForDisplayAlloc(allocator: std.mem.Allocator, output: []const u8) ![]u8 {
    const normalized = try stripAnsiAndNormalizeAlloc(allocator, output);
    defer allocator.free(normalized);

    const without_running = stripTrailingBracketedRunningNote(normalized);
    const without_aborted = stripTrailingLiteralStatus(without_running, "Command aborted");
    const without_timeout = stripTrailingStatusPrefix(without_aborted, "Command timed out after ");
    const without_exit = stripTrailingStatusPrefix(without_timeout, "Command exited with code ");
    return allocator.dupe(u8, without_exit);
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
    return formatBashExecutionDisplayExpanded(
        allocator,
        command,
        output,
        exit_code,
        cancelled,
        truncated,
        full_output_path,
        exclude_from_context,
        running,
        false,
    );
}

pub fn formatBashExecutionDisplayExpanded(
    allocator: std.mem.Allocator,
    command: []const u8,
    output: []const u8,
    exit_code: ?u8,
    cancelled: bool,
    truncated: bool,
    full_output_path: ?[]const u8,
    exclude_from_context: bool,
    running: bool,
    expanded: bool,
) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    try appendFmt(&builder, allocator, "$ {s}", .{command});
    if (exclude_from_context) try builder.appendSlice(allocator, " [excluded from context]");

    const clean_output = try sanitizeBashToolOutputForDisplayAlloc(allocator, output);
    defer allocator.free(clean_output);

    const has_display_output = clean_output.len > 0 and !(running and std.mem.eql(u8, clean_output, "Running..."));
    if (has_display_output) {
        try builder.appendSlice(allocator, "\n");
        if (expanded) {
            try builder.appendSlice(allocator, clean_output);
        } else {
            try appendTailPreview(&builder, allocator, clean_output, PREVIEW_LOGICAL_LINES);
        }
    }
    if (running) {
        try builder.appendSlice(allocator, "\nRunning... (Esc to cancel)");
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

fn appendTailPreview(
    builder: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    output: []const u8,
    preview_lines: usize,
) !void {
    const total_lines = logicalLineCount(output);
    const hidden_lines = total_lines -| preview_lines;
    if (hidden_lines == 0) {
        try builder.appendSlice(allocator, output);
        return;
    }

    const tail = tailLogicalLines(output, preview_lines);
    try appendFmt(builder, allocator, "... {d} more lines (Ctrl+O to expand)\n", .{hidden_lines});
    try builder.appendSlice(allocator, tail);
}

fn logicalLineCount(output: []const u8) usize {
    if (output.len == 0) return 0;
    var count: usize = 1;
    for (output) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn tailLogicalLines(output: []const u8, max_lines: usize) []const u8 {
    if (max_lines == 0 or output.len == 0) return "";
    var remaining_newlines = max_lines;
    var index = output.len;
    while (index > 0) {
        index -= 1;
        if (output[index] == '\n') {
            if (index + 1 == output.len) continue;
            remaining_newlines -|= 1;
            if (remaining_newlines == 0) return output[index + 1 ..];
        }
    }
    return output;
}

fn stripTrailingBracketedRunningNote(output: []const u8) []const u8 {
    const marker = "\n\n[Running...";
    const index = std.mem.lastIndexOf(u8, output, marker) orelse return output;
    const suffix = output[index + marker.len ..];
    if (std.mem.indexOf(u8, suffix, " elapsed]") == null) return output;
    return output[0..index];
}

fn stripTrailingLiteralStatus(output: []const u8, status: []const u8) []const u8 {
    if (std.mem.endsWith(u8, output, status)) {
        const prefix_len = output.len - status.len;
        if (prefix_len >= 2 and std.mem.eql(u8, output[prefix_len - 2 .. prefix_len], "\n\n")) {
            return output[0 .. prefix_len - 2];
        }
        if (prefix_len == 0) return "";
    }
    return output;
}

fn stripTrailingStatusPrefix(output: []const u8, status_prefix: []const u8) []const u8 {
    const marker = "\n\n";
    const index = std.mem.lastIndexOf(u8, output, marker) orelse return output;
    const tail = output[index + marker.len ..];
    if (!std.mem.startsWith(u8, tail, status_prefix)) return output;
    return output[0..index];
}

fn stripAnsiAndNormalizeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte == 0x1b and index + 1 < text.len) {
            const next = text[index + 1];
            if (next == '[') {
                index += 2;
                while (index < text.len) : (index += 1) {
                    const c = text[index];
                    if (c >= 0x40 and c <= 0x7e) {
                        index += 1;
                        break;
                    }
                }
                continue;
            }
            if (next == ']') {
                index += 2;
                while (index < text.len) : (index += 1) {
                    if (text[index] == 0x07) {
                        index += 1;
                        break;
                    }
                    if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '\\') {
                        index += 2;
                        break;
                    }
                }
                continue;
            }
        }
        if (byte == '\r') {
            if (index + 1 >= text.len or text[index + 1] != '\n') {
                try out.append(allocator, '\n');
            }
            index += 1;
            continue;
        }
        try out.append(allocator, byte);
        index += 1;
    }
    return try out.toOwnedSlice(allocator);
}

test "formatBashExecutionDisplay renders TS visible states and tail preview" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, "\x1b[31mred\x1b[0m\r\n");
    for (0..25) |index| {
        try appendFmt(&output, allocator, "line {d}\n", .{index + 1});
    }

    const collapsed = try formatBashExecutionDisplay(allocator, "printf test", output.items, 7, false, true, "/tmp/full.log", false, false);
    defer allocator.free(collapsed);
    try std.testing.expect(std.mem.indexOf(u8, collapsed, "\x1b[31m") == null);
    try std.testing.expect(std.mem.indexOf(u8, collapsed, "line 25") != null);
    try std.testing.expect(std.mem.indexOf(u8, collapsed, "red") == null);
    try std.testing.expect(std.mem.indexOf(u8, collapsed, "... 7 more lines") != null);
    try std.testing.expect(std.mem.indexOf(u8, collapsed, "line 25") != null);
    try std.testing.expect(std.mem.indexOf(u8, collapsed, "(exit 7)") != null);
    try std.testing.expect(std.mem.indexOf(u8, collapsed, "Output truncated. Full output: /tmp/full.log") != null);

    const running = try formatBashExecutionDisplay(allocator, "sleep 1", "Running...", null, false, false, null, false, true);
    defer allocator.free(running);
    try std.testing.expectEqualStrings("$ sleep 1\nRunning... (Esc to cancel)", running);

    const cancelled = try formatBashExecutionDisplay(allocator, "sleep 1", "partial", null, true, false, null, true, false);
    defer allocator.free(cancelled);
    try std.testing.expect(std.mem.indexOf(u8, cancelled, "[excluded from context]") != null);
    try std.testing.expect(std.mem.indexOf(u8, cancelled, "(cancelled)") != null);
}

test "sanitizeBashToolOutputForDisplay removes tool status notes" {
    const allocator = std.testing.allocator;
    const rendered = try sanitizeBashToolOutputForDisplayAlloc(
        allocator,
        "line 1\r\n\x1b[32mline 2\x1b[0m\n\n[Running... 0.1s elapsed]\n\nCommand exited with code 7",
    );
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("line 1\nline 2", rendered);
}
