const std = @import("std");
const st = @import("session_types.zig");
const tools = @import("tools.zig");

pub const ModelOutput = union(enum) {
    final_text: []const u8,
    tool_call: tools.ToolCall,
};

/// A tiny deterministic "model" to prove the agent loop + tools + session persistence.
/// Rules:
/// - If last entry is tool_result: respond with ack/error
/// - Else look for last user message:
///   - "echo:" => tool_call echo
///   - "sh:" => tool_call shell
///   - else => final ok
pub fn next(arena: std.mem.Allocator, entries: []const st.Entry) !ModelOutput {
    if (entries.len > 0) {
        const last = entries[entries.len - 1];
        switch (last) {
            .tool_result => |tr| {
                if (tr.ok) {
                    return .{ .final_text = try std.fmt.allocPrint(arena, "ack: tool_result {s}: {s}", .{ tr.tool, tr.content }) };
                }
                return .{ .final_text = try std.fmt.allocPrint(arena, "error: tool_result {s}: {s}", .{ tr.tool, tr.content }) };
            },
            else => {},
        }
    }

    var last_user: ?[]const u8 = null;
    var i: usize = entries.len;
    while (i > 0) : (i -= 1) {
        const e = entries[i - 1];
        switch (e) {
            .message => |m| {
                if (std.mem.eql(u8, m.role, "user")) {
                    last_user = m.content;
                    break;
                }
            },
            else => {},
        }
    }

    const text = last_user orelse return .{ .final_text = "(no user input)" };

    if (std.mem.startsWith(u8, text, "echo:")) {
        const arg = std.mem.trimLeft(u8, text[5..], " ");
        return .{ .tool_call = .{ .tool = "echo", .arg = arg } };
    }
    if (std.mem.startsWith(u8, text, "sh:")) {
        const arg = std.mem.trimLeft(u8, text[3..], " ");
        return .{ .tool_call = .{ .tool = "shell", .arg = arg } };
    }

    return .{ .final_text = try std.fmt.allocPrint(arena, "ok: {s}", .{text}) };
}
