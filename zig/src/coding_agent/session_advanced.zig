const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const session_mod = @import("session.zig");
const session_manager_mod = @import("session_manager.zig");
const common = @import("tools/common.zig");

pub const ContextUsage = struct {
    tokens: ?u32,
    context_window: u32,
    percent: ?f64,
};

pub const SessionStats = struct {
    session_file: ?[]const u8,
    session_id: []const u8,
    session_name: ?[]const u8,
    user_messages: usize,
    assistant_messages: usize,
    tool_calls: usize,
    tool_results: usize,
    total_messages: usize,
    tokens: struct {
        input: u64,
        output: u64,
        cache_read: u64,
        cache_write: u64,
        total: u64,
    },
    cost: f64,
    context_usage: ?ContextUsage,
};

pub fn getSessionStats(session: *const session_mod.AgentSession) SessionStats {
    const messages = session.agent.getMessages();

    var user_messages: usize = 0;
    var assistant_messages: usize = 0;
    var tool_calls: usize = 0;
    var tool_results: usize = 0;
    var total_input: u64 = 0;
    var total_output: u64 = 0;
    var total_cache_read: u64 = 0;
    var total_cache_write: u64 = 0;
    var total_cost: f64 = 0;

    for (messages) |message| {
        switch (message) {
            .user => user_messages += 1,
            .assistant => |assistant_message| {
                assistant_messages += 1;
                if (assistant_message.tool_calls) |calls| tool_calls += calls.len;
                total_input += assistant_message.usage.input;
                total_output += assistant_message.usage.output;
                total_cache_read += assistant_message.usage.cache_read;
                total_cache_write += assistant_message.usage.cache_write;
                total_cost += assistant_message.usage.cost.total;
            },
            .tool_result => tool_results += 1,
        }
    }

    return .{
        .session_file = session.session_manager.getSessionFile(),
        .session_id = session.session_manager.getSessionId(),
        .session_name = session.session_manager.getSessionName(),
        .user_messages = user_messages,
        .assistant_messages = assistant_messages,
        .tool_calls = tool_calls,
        .tool_results = tool_results,
        .total_messages = messages.len,
        .tokens = .{
            .input = total_input,
            .output = total_output,
            .cache_read = total_cache_read,
            .cache_write = total_cache_write,
            .total = total_input + total_output + total_cache_read + total_cache_write,
        },
        .cost = total_cost,
        .context_usage = getContextUsage(session),
    };
}

pub fn exportToJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const session_mod.AgentSession,
    output_path: ?[]const u8,
) ![]const u8 {
    const resolved_path = try resolveExportPath(allocator, session, output_path, ".json");
    errdefer allocator.free(resolved_path);
    try session.session_manager.exportJson(allocator, io, resolved_path);
    return resolved_path;
}

pub fn exportToMarkdown(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const session_mod.AgentSession,
    output_path: ?[]const u8,
) ![]const u8 {
    const resolved_path = try resolveExportPath(allocator, session, output_path, ".md");
    errdefer allocator.free(resolved_path);

    const stats = getSessionStats(session);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.print("# Session {s}\n\n", .{stats.session_name orelse stats.session_id});
    try writer.writer.print("- Session ID: `{s}`\n", .{stats.session_id});
    try writer.writer.print("- Session file: `{s}`\n", .{stats.session_file orelse "in-memory"});
    try writer.writer.print("- Working directory: `{s}`\n", .{session.cwd});
    try writer.writer.print("- Model: `{s}` / `{s}`\n", .{ session.agent.getModel().provider, session.agent.getModel().id });
    try writer.writer.print("- User messages: {d}\n", .{stats.user_messages});
    try writer.writer.print("- Assistant messages: {d}\n", .{stats.assistant_messages});
    try writer.writer.print("- Tool calls: {d}\n", .{stats.tool_calls});
    try writer.writer.print("- Tool results: {d}\n", .{stats.tool_results});
    try writer.writer.print("- Tokens: {d}\n", .{stats.tokens.total});
    try writer.writer.print("- Cost: {d:.4}\n\n", .{stats.cost});
    try writer.writer.writeAll("## Transcript\n\n");

    for (session.agent.getMessages(), 0..) |message, index| {
        try writer.writer.print("### {d}. {s}\n\n", .{ index + 1, messageTitle(message) });
        const text = try messageToMarkdown(allocator, message);
        defer allocator.free(text);
        if (text.len == 0) {
            try writer.writer.writeAll("_No text content_\n\n");
        } else {
            try writer.writer.print("{s}\n\n", .{text});
        }
    }

    try common.writeFileAbsolute(io, resolved_path, writer.written(), true);
    return resolved_path;
}

fn resolveExportPath(
    allocator: std.mem.Allocator,
    session: *const session_mod.AgentSession,
    output_path: ?[]const u8,
    extension: []const u8,
) ![]const u8 {
    if (output_path) |path| {
        return common.resolvePath(allocator, session.cwd, path);
    }

    const base_dir = if (session.session_manager.getSessionDir().len > 0)
        session.session_manager.getSessionDir()
    else
        session.cwd;
    const filename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ session.session_manager.getSessionId(), extension });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &[_][]const u8{ base_dir, filename });
}

fn messageTitle(message: agent.AgentMessage) []const u8 {
    return switch (message) {
        .user => "User",
        .assistant => "Assistant",
        .tool_result => "Tool Result",
    };
}

fn messageToMarkdown(allocator: std.mem.Allocator, message: agent.AgentMessage) ![]u8 {
    return switch (message) {
        .user => |user_message| blocksToText(allocator, user_message.content),
        .assistant => |assistant_message| blk: {
            const text = try blocksToText(allocator, assistant_message.content);
            if (text.len > 0) break :blk text;
            if (assistant_message.tool_calls) |calls| {
                var writer: std.Io.Writer.Allocating = .init(allocator);
                defer writer.deinit();
                for (calls, 0..) |tool_call, index| {
                    if (index > 0) try writer.writer.writeAll("\n");
                    const args = try std.json.Stringify.valueAlloc(allocator, tool_call.arguments, .{ .whitespace = .indent_2 });
                    defer allocator.free(args);
                    try writer.writer.print("- `{s}` `{s}`\n```json\n{s}\n```", .{ tool_call.name, tool_call.id, args });
                }
                break :blk try allocator.dupe(u8, writer.written());
            }
            break :blk allocator.dupe(u8, "");
        },
        .tool_result => |tool_result| blk: {
            const text = try blocksToText(allocator, tool_result.content);
            defer allocator.free(text);
            if (text.len == 0) {
                break :blk try std.fmt.allocPrint(allocator, "`{s}` returned no text content", .{tool_result.tool_name});
            }
            break :blk try std.fmt.allocPrint(allocator, "`{s}`\n\n{s}", .{ tool_result.tool_name, text });
        },
    };
}

fn blocksToText(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var wrote_any = false;
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                if (text.text.len == 0) continue;
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.writeAll(text.text);
                wrote_any = true;
            },
            .thinking => |thinking| {
                if (thinking.thinking.len == 0) continue;
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.print("_Thinking:_ {s}", .{thinking.thinking});
                wrote_any = true;
            },
            .image => |image| {
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.print("![image](data:{s};base64,{s})", .{ image.mime_type, image.data });
                wrote_any = true;
            },
        }
    }

    return try allocator.dupe(u8, writer.written());
}

fn getContextUsage(session: *const session_mod.AgentSession) ?ContextUsage {
    const context_window = session.agent.getModel().context_window;
    if (context_window == 0) return null;

    const tokens = estimateContextTokens(session.agent.getMessages());
    return .{
        .tokens = tokens,
        .context_window = context_window,
        .percent = (@as(f64, @floatFromInt(tokens)) / @as(f64, @floatFromInt(context_window))) * 100.0,
    };
}

fn estimateContextTokens(messages: []const agent.AgentMessage) u32 {
    var total: u32 = 0;
    for (messages) |message| {
        total +|= estimateMessageTokens(message);
    }
    return total;
}

fn estimateMessageTokens(message: agent.AgentMessage) u32 {
    var chars: usize = 0;
    switch (message) {
        .user => |user_message| chars += estimateContentBlockChars(user_message.content),
        .assistant => |assistant_message| {
            if (assistant_message.stop_reason == .error_reason) return 0;
            chars += estimateContentBlockChars(assistant_message.content);
            if (assistant_message.tool_calls) |calls| {
                for (calls) |call| {
                    chars += call.name.len;
                    chars += jsonValueCharCount(call.arguments);
                }
            }
        },
        .tool_result => |tool_result| chars += estimateContentBlockChars(tool_result.content),
    }
    return @intCast((chars + 3) / 4);
}

fn estimateContentBlockChars(blocks: []const ai.ContentBlock) usize {
    var chars: usize = 0;
    for (blocks) |block| {
        switch (block) {
            .text => |text| chars += text.text.len,
            .thinking => |thinking| chars += thinking.thinking.len,
            .image => chars += 4800,
        }
    }
    return chars;
}

fn jsonValueCharCount(value: std.json.Value) usize {
    return switch (value) {
        .null => 4,
        .bool => |bool_value| if (bool_value) 4 else 5,
        .integer => |integer| std.fmt.count("{}", .{integer}),
        .float => |float_value| std.fmt.count("{d}", .{float_value}),
        .number_string => |number_string| number_string.len,
        .string => |string| string.len,
        .array => |array| blk: {
            var total: usize = 2;
            for (array.items, 0..) |item, index| {
                if (index > 0) total += 1;
                total += jsonValueCharCount(item);
            }
            break :blk total;
        },
        .object => |object| blk: {
            var total: usize = 2;
            var iterator = object.iterator();
            var first = true;
            while (iterator.next()) |entry| {
                if (!first) total += 1;
                first = false;
                total += entry.key_ptr.*.len + jsonValueCharCount(entry.value_ptr.*) + 1;
            }
            break :blk total;
        },
    };
}

test "session advanced stats and exports cover markdown and json output" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer allocator.free(relative_dir);

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const absolute_dir = try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_dir });
    defer allocator.free(absolute_dir);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "system",
        .model = agent.DEFAULT_MODEL,
        .session_dir = absolute_dir,
    });
    defer session.deinit();

    var user = try makeUserMessage("document this session", 1);
    defer session_manager_mod.deinitMessage(allocator, &user);
    _ = try session.session_manager.appendMessage(user);

    var assistant = try makeAssistantMessage("done", 2);
    defer session_manager_mod.deinitMessage(allocator, &assistant);
    _ = try session.session_manager.appendMessage(assistant);

    try session.agent.setMessages(&[_]agent.AgentMessage{ user, assistant });

    const stats = getSessionStats(&session);
    try std.testing.expectEqual(@as(usize, 1), stats.user_messages);
    try std.testing.expectEqual(@as(usize, 1), stats.assistant_messages);

    const json_path = try exportToJson(allocator, std.testing.io, &session, null);
    defer allocator.free(json_path);
    const markdown_path = try exportToMarkdown(allocator, std.testing.io, &session, null);
    defer allocator.free(markdown_path);

    const json_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, json_path, allocator, .limited(1024 * 1024));
    defer allocator.free(json_bytes);
    const markdown_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, markdown_path, allocator, .limited(1024 * 1024));
    defer allocator.free(markdown_bytes);

    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown_bytes, "# Session") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown_bytes, "document this session") != null);
}

fn makeUserMessage(text: []const u8, timestamp: i64) !agent.AgentMessage {
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, text) } };
    return .{ .user = .{
        .role = try std.testing.allocator.dupe(u8, "user"),
        .content = blocks,
        .timestamp = timestamp,
    } };
}

fn makeAssistantMessage(text: []const u8, timestamp: i64) !agent.AgentMessage {
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, text) } };
    return .{ .assistant = .{
        .role = try std.testing.allocator.dupe(u8, "assistant"),
        .content = blocks,
        .tool_calls = null,
        .api = try std.testing.allocator.dupe(u8, agent.DEFAULT_MODEL.api),
        .provider = try std.testing.allocator.dupe(u8, agent.DEFAULT_MODEL.provider),
        .model = try std.testing.allocator.dupe(u8, agent.DEFAULT_MODEL.id),
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = timestamp,
    } };
}
