const std = @import("std");

pub const SessionHeader = struct {
    type: []const u8 = "session",
    version: u32 = 1,
    id: []const u8,
    timestamp: []const u8,
    cwd: []const u8,
};

pub const MessageEntry = struct {
    type: []const u8 = "message",
    id: []const u8,
    timestamp: []const u8,
    role: []const u8, // user|assistant|tool
    content: []const u8,
};

pub const ToolCallEntry = struct {
    type: []const u8 = "tool_call",
    id: []const u8,
    timestamp: []const u8,
    tool: []const u8,
    arg: []const u8,
};

pub const ToolResultEntry = struct {
    type: []const u8 = "tool_result",
    id: []const u8,
    timestamp: []const u8,
    tool: []const u8,
    ok: bool,
    content: []const u8,
};

pub const Entry = union(enum) {
    session: SessionHeader,
    message: MessageEntry,
    tool_call: ToolCallEntry,
    tool_result: ToolResultEntry,
};

pub fn roleOf(e: Entry) ?[]const u8 {
    return switch (e) {
        .message => |m| m.role,
        else => null,
    };
}

pub fn contentOf(e: Entry) ?[]const u8 {
    return switch (e) {
        .message => |m| m.content,
        else => null,
    };
}
