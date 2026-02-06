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
    // NOTE: caller should already provide a business-only context (no turn/leaf/label).
    // We still defensively skip structural entries for forward compatibility.
    // Find last significant entry
    var last_sig: ?st.Entry = null;
    var j: usize = entries.len;
    while (j > 0) : (j -= 1) {
        const e = entries[j - 1];
        switch (e) {
            .session, .leaf, .label, .turn_start, .turn_end, .thinking_level_change, .model_change => continue,
            else => {
                last_sig = e;
                break;
            },
        }
    }

    if (last_sig) |last| {
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

    const text = blk: {
        var i: usize = entries.len;
        while (i > 0) : (i -= 1) {
            const e = entries[i - 1];
            switch (e) {
                .message => |m| {
                    if (std.mem.eql(u8, m.role, "user")) break :blk m.content;
                },
                else => {},
            }
        }
        break :blk null;
    } orelse return .{ .final_text = "(no user input)" };

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
