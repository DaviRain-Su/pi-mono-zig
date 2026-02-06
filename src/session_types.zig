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

    /// Optional per-entry usage estimate (best-effort). When present, sizing prefers this.
    tokensEst: ?usize = null,

    /// Optional context-usage snapshot (TS-style totalTokens from assistant usage).
    /// When present on assistant messages, compaction sizing can do usage+trailing estimation.
    usageTotalTokens: ?usize = null,
};

pub const ToolCallEntry = struct {
    type: []const u8 = "tool_call",
    id: []const u8,
    parentId: ?[]const u8 = null,
    timestamp: []const u8,
    tool: []const u8,
    arg: []const u8,

    tokensEst: ?usize = null,
};

pub const ToolResultEntry = struct {
    type: []const u8 = "tool_result",
    id: []const u8,
    parentId: ?[]const u8 = null,
    timestamp: []const u8,
    tool: []const u8,
    ok: bool,
    content: []const u8,

    tokensEst: ?usize = null,
};

pub const ThinkingLevelChangeEntry = struct {
    type: []const u8 = "thinking_level_change",
    id: []const u8,
    parentId: ?[]const u8 = null,
    timestamp: []const u8,
    thinkingLevel: []const u8,
};

pub const ModelChangeEntry = struct {
    type: []const u8 = "model_change",
    id: []const u8,
    parentId: ?[]const u8 = null,
    timestamp: []const u8,
    provider: []const u8,
    modelId: []const u8,
};

pub const BranchSummaryEntry = struct {
    type: []const u8 = "branch_summary",
    id: []const u8,
    parentId: ?[]const u8 = null,
    timestamp: []const u8,
    fromId: []const u8,
    summary: []const u8,
    fromHook: ?bool = null,
};

pub const CustomEntry = struct {
    type: []const u8 = "custom",
    id: []const u8,
    parentId: ?[]const u8 = null,
    timestamp: []const u8,
    customType: []const u8,
};

pub const CustomMessageEntry = struct {
    type: []const u8 = "custom_message",
    id: []const u8,
    parentId: ?[]const u8 = null,
    timestamp: []const u8,
    customType: []const u8,
    // MVP compatibility: only string content is preserved verbatim.
    // Non-string content is represented with a marker string.
    content: []const u8,
    display: bool = true,
};

pub const SessionInfoEntry = struct {
    type: []const u8 = "session_info",
    id: []const u8,
    parentId: ?[]const u8 = null,
    timestamp: []const u8,
    name: ?[]const u8 = null,
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
    /// TS compatibility: persisted as "compaction" (legacy sessions may contain "summary").
    type: []const u8 = "compaction",
    id: []const u8,
    parentId: ?[]const u8 = null,
    timestamp: []const u8,

    /// Why this summary was created (manual|auto_chars|auto_tokens|...)
    reason: ?[]const u8 = null,

    /// "text" (legacy) or "json" (structured)
    format: []const u8 = "text",

    /// Summary payload. If format=json, this is a JSON string.
    /// TS-compatible key name: "summary".
    summary: []const u8,

    /// TS-style compaction marker: first kept entry in the historical prefix.
    /// If null, this summary is treated as legacy (pre-marker format).
    firstKeptEntryId: ?[]const u8 = null,

    /// TS compaction snapshot (historical context size before compaction).
    /// Kept alongside totalTokensEst for backward compatibility with existing zig sessions.
    tokensBefore: ?usize = null,
    fromHook: ?bool = null,

    /// Best-effort file ops (TS-style compaction details). Stored on the entry, and may also
    /// be rendered into the content for markdown summaries.
    readFiles: ?[]const []const u8 = null,
    modifiedFiles: ?[]const []const u8 = null,

    /// Optional stats snapshots for debugging/verification
    totalChars: ?usize = null,
    totalTokensEst: ?usize = null,
    keepLast: ?usize = null,
    keepLastGroups: ?usize = null,
    thresholdChars: ?usize = null,
    thresholdTokensEst: ?usize = null,
};

pub const Entry = union(enum) {
    session: SessionHeader,
    message: MessageEntry,
    tool_call: ToolCallEntry,
    tool_result: ToolResultEntry,
    thinking_level_change: ThinkingLevelChangeEntry,
    model_change: ModelChangeEntry,
    branch_summary: BranchSummaryEntry,
    custom: CustomEntry,
    custom_message: CustomMessageEntry,
    session_info: SessionInfoEntry,
    turn_start: TurnStartEntry,
    turn_end: TurnEndEntry,
    summary: SummaryEntry,
    leaf: LeafEntry,
    label: LabelEntry,
};

pub fn roleOf(e: Entry) ?[]const u8 {
    return switch (e) {
        .message => |m| m.role,
        .custom_message => "user",
        else => null,
    };
}

pub fn contentOf(e: Entry) ?[]const u8 {
    return switch (e) {
        .message => |m| m.content,
        .custom_message => |m| m.content,
        else => null,
    };
}

pub fn idOf(e: Entry) ?[]const u8 {
    return switch (e) {
        .message => |m| m.id,
        .tool_call => |t| t.id,
        .tool_result => |t| t.id,
        .thinking_level_change => |t| t.id,
        .model_change => |m| m.id,
        .branch_summary => |b| b.id,
        .custom => |c| c.id,
        .custom_message => |c| c.id,
        .session_info => |s| s.id,
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
        .thinking_level_change => |t| t.parentId,
        .model_change => |m| m.parentId,
        .branch_summary => |b| b.parentId,
        .custom => |c| c.parentId,
        .custom_message => |c| c.parentId,
        .session_info => |s| s.parentId,
        .turn_start => |t| t.parentId,
        .turn_end => |t| t.parentId,
        .summary => |s| s.parentId,
        else => null,
    };
}
