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
    parentId: ?[]const u8 = null,
    timestamp: []const u8,
    role: []const u8, // user|assistant|tool
    content: []const u8,
};

pub const ToolCallEntry = struct {
    type: []const u8 = "tool_call",
    id: []const u8,
    parentId: ?[]const u8 = null,
    timestamp: []const u8,
    tool: []const u8,
    arg: []const u8,
};

pub const ToolResultEntry = struct {
    type: []const u8 = "tool_result",
    id: []const u8,
    parentId: ?[]const u8 = null,
    timestamp: []const u8,
    tool: []const u8,
    ok: bool,
    content: []const u8,
};

pub const LeafEntry = struct {
    type: []const u8 = "leaf",
    timestamp: []const u8,
    targetId: ?[]const u8,
};

pub const LabelEntry = struct {
    type: []const u8 = "label",
    id: []const u8,
    timestamp: []const u8,
    targetId: []const u8,
    label: ?[]const u8, // if null => delete label
};

pub const TurnStartEntry = struct {
    type: []const u8 = "turn_start",
    id: []const u8,
    parentId: ?[]const u8 = null,
    timestamp: []const u8,
    turn: u64,
    userMessageId: ?[]const u8 = null,
    turnGroupId: ?[]const u8 = null,
    phase: ?[]const u8 = null, // e.g. "step"
};

pub const TurnEndEntry = struct {
    type: []const u8 = "turn_end",
    id: []const u8,
    parentId: ?[]const u8 = null,
    timestamp: []const u8,
    turn: u64,
    userMessageId: ?[]const u8 = null,
    turnGroupId: ?[]const u8 = null,
    phase: ?[]const u8 = null, // e.g. "tool"|"final"|"error"
};

pub const SummaryEntry = struct {
    type: []const u8 = "summary",
    id: []const u8,
    parentId: ?[]const u8 = null,
    timestamp: []const u8,

    /// Why this summary was created (manual|auto_chars|auto_tokens|...)
    reason: ?[]const u8 = null,

    /// "text" (legacy) or "json" (structured)
    format: []const u8 = "text",

    /// Summary payload. If format=json, this is a JSON string.
    content: []const u8,

    /// Optional stats snapshots for debugging/verification
    totalChars: ?usize = null,
    totalTokensEst: ?usize = null,
    keepLast: ?usize = null,
    thresholdChars: ?usize = null,
    thresholdTokensEst: ?usize = null,
};

pub const Entry = union(enum) {
    session: SessionHeader,
    message: MessageEntry,
    tool_call: ToolCallEntry,
    tool_result: ToolResultEntry,
    turn_start: TurnStartEntry,
    turn_end: TurnEndEntry,
    summary: SummaryEntry,
    leaf: LeafEntry,
    label: LabelEntry,
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

pub fn idOf(e: Entry) ?[]const u8 {
    return switch (e) {
        .message => |m| m.id,
        .tool_call => |t| t.id,
        .tool_result => |t| t.id,
        .turn_start => |t| t.id,
        .turn_end => |t| t.id,
        .summary => |s| s.id,
        else => null,
    };
}

pub fn parentIdOf(e: Entry) ?[]const u8 {
    return switch (e) {
        .message => |m| m.parentId,
        .tool_call => |t| t.parentId,
        .tool_result => |t| t.parentId,
        .turn_start => |t| t.parentId,
        .turn_end => |t| t.parentId,
        .summary => |s| s.parentId,
        else => null,
    };
}
