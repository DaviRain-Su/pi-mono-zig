const std = @import("std");
const session = @import("session_manager.zig");
const tools = @import("tools.zig");

pub const ModelOutput = union(enum) {
    final_text: []const u8,
    tool_call: tools.ToolCall,
};

/// A tiny deterministic "model" to prove the agent loop + tools + session persistence.
/// Rules:
/// - If last user message starts with "echo:", call tool echo with remainder.
/// - If last user message starts with "sh:", call tool shell with remainder.
/// - Else respond with "ok: <text>".
pub fn next(arena: std.mem.Allocator, messages: []const session.MessageEntry) !ModelOutput {
    // If we just got a tool result, produce a final response.
    if (messages.len > 0) {
        const last = messages[messages.len - 1];
        if (std.mem.eql(u8, last.role, "tool") and std.mem.startsWith(u8, last.content, "tool_result")) {
            return ModelOutput{ .final_text = try std.fmt.allocPrint(arena, "ack: {s}", .{last.content}) };
        }
        if (std.mem.eql(u8, last.role, "tool") and std.mem.startsWith(u8, last.content, "tool_error")) {
            return ModelOutput{ .final_text = try std.fmt.allocPrint(arena, "error: {s}", .{last.content}) };
        }
    }

    var last_user: ?[]const u8 = null;
    var i: usize = messages.len;
    while (i > 0) : (i -= 1) {
        const m = messages[i - 1];
        if (std.mem.eql(u8, m.role, "user")) {
            last_user = m.content;
            break;
        }
    }
    const text = last_user orelse return ModelOutput{ .final_text = "(no user input)" };

    if (std.mem.startsWith(u8, text, "echo:")) {
        const arg = std.mem.trimLeft(u8, text[5..], " ");
        return ModelOutput{ .tool_call = .{ .tool = "echo", .arg = arg } };
    }
    if (std.mem.startsWith(u8, text, "sh:")) {
        const arg = std.mem.trimLeft(u8, text[3..], " ");
        return ModelOutput{ .tool_call = .{ .tool = "shell", .arg = arg } };
    }

    return ModelOutput{ .final_text = try std.fmt.allocPrint(arena, "ok: {s}", .{text}) };
}
