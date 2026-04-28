const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const tui = @import("tui");
const common = @import("tools/common.zig");

pub const CURRENT_SESSION_VERSION: u32 = 3;
pub const BRANCH_SUMMARY_PREFIX =
    "The following is a summary of a branch that this conversation came back from:\n\n<summary>\n";
pub const BRANCH_SUMMARY_SUFFIX = "</summary>";

/// Process-wide monotonic counter used as entropy for generated session entry
/// IDs. It intentionally remains global so IDs keep increasing across all
/// session managers created in this process, and the atomic value keeps that
/// invariant safe when concurrent prompts append session records.
var global_id_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub const SessionHeader = struct {
    id: []const u8,
    timestamp: []const u8,
    cwd: []const u8,
    parent_session: ?[]const u8 = null,
};

pub const SessionModelRef = struct {
    api: ?[]const u8 = null,
    provider: []const u8,
    model_id: []const u8,
};

pub const SessionContext = struct {
    messages: []const agent.AgentMessage,
    thinking_level: agent.ThinkingLevel = .off,
    model: ?SessionModelRef = null,

    pub fn deinit(self: *SessionContext, allocator: std.mem.Allocator) void {
        for (@constCast(self.messages)) |*message| {
            deinitMessage(allocator, message);
        }
        allocator.free(@constCast(self.messages));
        self.* = .{
            .messages = &.{},
        };
    }
};

pub const SessionMessageEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    message: agent.AgentMessage,
};

pub const ThinkingLevelChangeEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    thinking_level: agent.ThinkingLevel,
};

pub const ModelChangeEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    provider: []const u8,
    model_id: []const u8,
};

pub const CompactionEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u32,
    message: agent.AgentMessage,
};

pub const BranchSummaryEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    from_id: []const u8,
    summary: []const u8,
    details: ?std.json.Value = null,
    from_hook: ?bool = null,
};

pub const CustomEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    custom_type: []const u8,
    data: ?std.json.Value = null,
};

pub const CustomMessageContent = union(enum) {
    text: []const u8,
    blocks: []const ai.ContentBlock,

    pub fn deinit(self: *CustomMessageContent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |text| allocator.free(text),
            .blocks => |blocks| common.deinitContentBlocks(allocator, blocks),
        }
        self.* = undefined;
    }
};

pub const CustomMessageEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    custom_type: []const u8,
    content: CustomMessageContent,
    details: ?std.json.Value = null,
    display: bool,
};

pub const LabelEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    target_id: []const u8,
    label: ?[]const u8,
};

pub const SessionInfoEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    name: ?[]const u8,
};

pub const SessionEntry = union(enum) {
    message: SessionMessageEntry,
    thinking_level_change: ThinkingLevelChangeEntry,
    model_change: ModelChangeEntry,
    compaction: CompactionEntry,
    branch_summary: BranchSummaryEntry,
    custom: CustomEntry,
    custom_message: CustomMessageEntry,
    label: LabelEntry,
    session_info: SessionInfoEntry,

    pub fn id(self: *const SessionEntry) []const u8 {
        return switch (self.*) {
            .message => |entry| entry.id,
            .thinking_level_change => |entry| entry.id,
            .model_change => |entry| entry.id,
            .compaction => |entry| entry.id,
            .branch_summary => |entry| entry.id,
            .custom => |entry| entry.id,
            .custom_message => |entry| entry.id,
            .label => |entry| entry.id,
            .session_info => |entry| entry.id,
        };
    }

    pub fn parentId(self: *const SessionEntry) ?[]const u8 {
        return switch (self.*) {
            .message => |entry| entry.parent_id,
            .thinking_level_change => |entry| entry.parent_id,
            .model_change => |entry| entry.parent_id,
            .compaction => |entry| entry.parent_id,
            .branch_summary => |entry| entry.parent_id,
            .custom => |entry| entry.parent_id,
            .custom_message => |entry| entry.parent_id,
            .label => |entry| entry.parent_id,
            .session_info => |entry| entry.parent_id,
        };
    }

    pub fn timestamp(self: *const SessionEntry) []const u8 {
        return switch (self.*) {
            .message => |entry| entry.timestamp,
            .thinking_level_change => |entry| entry.timestamp,
            .model_change => |entry| entry.timestamp,
            .compaction => |entry| entry.timestamp,
            .branch_summary => |entry| entry.timestamp,
            .custom => |entry| entry.timestamp,
            .custom_message => |entry| entry.timestamp,
            .label => |entry| entry.timestamp,
            .session_info => |entry| entry.timestamp,
        };
    }
};

pub const SessionTreeNode = struct {
    entry: *const SessionEntry,
    children: []SessionTreeNode,
    label: ?[]const u8 = null,
    label_timestamp: ?[]const u8 = null,

    pub fn deinit(self: *SessionTreeNode, allocator: std.mem.Allocator) void {
        for (self.children) |*child| child.deinit(allocator);
        allocator.free(self.children);
        self.* = .{
            .entry = self.entry,
            .children = &.{},
            .label = null,
            .label_timestamp = null,
        };
    }
};

pub const SessionSearchInfo = struct {
    path: []const u8,
    id: []const u8,
    cwd: []const u8,
    name: ?[]const u8 = null,
    parent_session: ?[]const u8 = null,
    created_timestamp: []const u8,
    modified_timestamp: []const u8,
    message_count: usize,
    first_message: []const u8,
    all_messages_text: []const u8,
    search_text: []const u8,

    pub fn deinit(self: *SessionSearchInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.id);
        allocator.free(self.cwd);
        if (self.name) |name| allocator.free(name);
        if (self.parent_session) |parent_session| allocator.free(parent_session);
        allocator.free(self.created_timestamp);
        allocator.free(self.modified_timestamp);
        allocator.free(self.first_message);
        allocator.free(self.all_messages_text);
        allocator.free(self.search_text);
        self.* = undefined;
    }
};

pub const SessionSearchSortMode = enum {
    recent,
    relevance,
};

pub const SessionSearchNameFilter = enum {
    all,
    named,
};

pub const SessionSearchField = enum {
    any,
    name,
    content,
    cwd,
    id,
};

pub const SessionSearchTokenKind = enum {
    fuzzy,
    phrase,
};

pub const SessionSearchToken = struct {
    field: SessionSearchField = .any,
    kind: SessionSearchTokenKind,
    value: []const u8,
};

pub const ParsedSessionSearchQuery = struct {
    tokens: []const SessionSearchToken,

    pub fn deinit(self: *ParsedSessionSearchQuery, allocator: std.mem.Allocator) void {
        allocator.free(self.tokens);
        self.* = .{
            .tokens = &.{},
        };
    }
};

pub const SessionSearchMatch = struct {
    session_index: usize,
    score: i32,
};

pub const SessionSearchOptions = struct {
    sort_mode: SessionSearchSortMode = .relevance,
    name_filter: SessionSearchNameFilter = .all,
};

pub const SessionSearchResults = struct {
    sessions: []const SessionSearchInfo,
    matches: []const SessionSearchMatch,

    pub fn deinit(self: *SessionSearchResults, allocator: std.mem.Allocator) void {
        for (@constCast(self.sessions)) |*session| session.deinit(allocator);
        allocator.free(@constCast(self.sessions));
        allocator.free(@constCast(self.matches));
        self.* = .{
            .sessions = &.{},
            .matches = &.{},
        };
    }
};

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    header: SessionHeader,
    session_dir: []const u8,
    session_file: ?[]const u8,
    persist: bool,
    entries: std.ArrayList(SessionEntry),
    by_id: std.StringHashMap(usize),
    labels_by_id: std.StringHashMap([]const u8),
    label_timestamps_by_id: std.StringHashMap([]const u8),
    leaf_id: ?[]const u8,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: []const u8,
    ) !SessionManager {
        var manager = try initEmpty(allocator, io, cwd, session_dir, true, null);
        errdefer manager.deinit();
        try manager.persistToDisk();
        return manager;
    }

    pub fn createWithParent(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: []const u8,
        parent_session: ?[]const u8,
    ) !SessionManager {
        var manager = try initEmpty(allocator, io, cwd, session_dir, true, parent_session);
        errdefer manager.deinit();
        try manager.persistToDisk();
        return manager;
    }

    pub fn inMemory(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
    ) !SessionManager {
        return initEmpty(allocator, io, cwd, "", false, null);
    }

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        session_file: []const u8,
        cwd_override: ?[]const u8,
    ) !SessionManager {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
        return openWithWarningWriter(allocator, io, session_file, cwd_override, &stderr_writer.interface);
    }

    fn openWithWarningWriter(
        allocator: std.mem.Allocator,
        io: std.Io,
        session_file: []const u8,
        cwd_override: ?[]const u8,
        warning_writer: ?*std.Io.Writer,
    ) !SessionManager {
        const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, session_file, allocator, .unlimited);
        defer allocator.free(bytes);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        const header_line = lines.next() orelse return error.InvalidSessionFile;
        var header = try parseHeaderLine(allocator, header_line);
        errdefer deinitHeader(allocator, &header);

        if (cwd_override) |cwd| {
            allocator.free(header.cwd);
            header.cwd = try allocator.dupe(u8, cwd);
        }

        var manager = SessionManager{
            .allocator = allocator,
            .io = io,
            .header = header,
            .session_dir = try deriveSessionDir(allocator, session_file),
            .session_file = try allocator.dupe(u8, session_file),
            .persist = true,
            .entries = .empty,
            .by_id = std.StringHashMap(usize).init(allocator),
            .labels_by_id = std.StringHashMap([]const u8).init(allocator),
            .label_timestamps_by_id = std.StringHashMap([]const u8).init(allocator),
            .leaf_id = null,
        };
        errdefer manager.deinit();

        var skipped_corrupted_lines: usize = 0;
        var line_number: usize = 2;
        while (lines.next()) |line| : (line_number += 1) {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            const entry = parseEntryLine(allocator, line) catch |err| {
                skipped_corrupted_lines += 1;
                if (warning_writer) |writer| {
                    logCorruptedSessionLine(writer, session_file, line_number, err) catch {};
                }
                continue;
            };
            try manager.appendLoadedEntry(entry);
        }

        if (skipped_corrupted_lines > 0 and warning_writer != null) {
            logCorruptedSessionDataLoss(
                warning_writer.?,
                session_file,
                skipped_corrupted_lines,
            ) catch {};
            warning_writer.?.flush() catch {};
        }

        return manager;
    }

    pub fn continueRecent(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        session_dir: []const u8,
    ) !SessionManager {
        const latest = try findMostRecentSession(allocator, io, session_dir);
        defer if (latest) |path| allocator.free(path);

        if (latest) |path| {
            return open(allocator, io, path, cwd);
        }

        return create(allocator, io, cwd, session_dir);
    }

    pub fn deinit(self: *SessionManager) void {
        for (self.entries.items) |*entry| deinitEntry(self.allocator, entry);
        self.entries.deinit(self.allocator);
        self.by_id.deinit();
        self.labels_by_id.deinit();
        self.label_timestamps_by_id.deinit();
        deinitHeader(self.allocator, &self.header);
        self.allocator.free(self.session_dir);
        if (self.session_file) |path| self.allocator.free(path);
        self.* = undefined;
    }

    pub fn isPersisted(self: *const SessionManager) bool {
        return self.persist;
    }

    pub fn getHeader(self: *const SessionManager) SessionHeader {
        return self.header;
    }

    pub fn getCwd(self: *const SessionManager) []const u8 {
        return self.header.cwd;
    }

    pub fn getSessionDir(self: *const SessionManager) []const u8 {
        return self.session_dir;
    }

    pub fn getSessionId(self: *const SessionManager) []const u8 {
        return self.header.id;
    }

    pub fn getSessionFile(self: *const SessionManager) ?[]const u8 {
        return self.session_file;
    }

    pub fn getSessionName(self: *const SessionManager) ?[]const u8 {
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            switch (self.entries.items[index]) {
                .session_info => |entry| {
                    const name = entry.name orelse return null;
                    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
                    if (trimmed.len == 0) return null;
                    return trimmed;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn getLeafId(self: *const SessionManager) ?[]const u8 {
        return self.leaf_id;
    }

    pub fn getEntries(self: *const SessionManager) []const SessionEntry {
        return self.entries.items;
    }

    pub fn getEntry(self: *const SessionManager, id: []const u8) ?*const SessionEntry {
        const index = self.by_id.get(id) orelse return null;
        return &self.entries.items[index];
    }

    pub fn appendMessage(self: *SessionManager, message: agent.AgentMessage) ![]const u8 {
        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const entry = SessionEntry{
            .message = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .message = try cloneMessage(self.allocator, message),
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn appendThinkingLevelChange(self: *SessionManager, thinking_level: agent.ThinkingLevel) ![]const u8 {
        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const entry = SessionEntry{
            .thinking_level_change = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .thinking_level = thinking_level,
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn appendModelChange(self: *SessionManager, provider: []const u8, model_id: []const u8) ![]const u8 {
        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const entry = SessionEntry{
            .model_change = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .provider = try self.allocator.dupe(u8, provider),
                .model_id = try self.allocator.dupe(u8, model_id),
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn appendCompaction(
        self: *SessionManager,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: u32,
    ) ![]const u8 {
        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const summary_message = try createCompactionSummaryMessage(self.allocator, summary, 0);
        errdefer {
            var cleanup = summary_message;
            deinitMessage(self.allocator, &cleanup);
        }

        const entry = SessionEntry{
            .compaction = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .first_kept_entry_id = try self.allocator.dupe(u8, first_kept_entry_id),
                .tokens_before = tokens_before,
                .message = summary_message,
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn appendCustomEntry(self: *SessionManager, custom_type: []const u8, data: ?std.json.Value) ![]const u8 {
        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const owned_data = if (data) |value| try common.cloneJsonValue(self.allocator, value) else null;
        errdefer if (owned_data) |value| common.deinitJsonValue(self.allocator, value);

        const entry = SessionEntry{
            .custom = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .custom_type = try self.allocator.dupe(u8, custom_type),
                .data = owned_data,
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn appendCustomMessageEntry(
        self: *SessionManager,
        custom_type: []const u8,
        content: CustomMessageContent,
        display: bool,
        details: ?std.json.Value,
    ) ![]const u8 {
        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const owned_content = try cloneCustomMessageContent(self.allocator, content);
        errdefer {
            var cleanup_content = owned_content;
            cleanup_content.deinit(self.allocator);
        }

        const owned_details = if (details) |value| try common.cloneJsonValue(self.allocator, value) else null;
        errdefer if (owned_details) |value| common.deinitJsonValue(self.allocator, value);

        const entry = SessionEntry{
            .custom_message = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .custom_type = try self.allocator.dupe(u8, custom_type),
                .content = owned_content,
                .details = owned_details,
                .display = display,
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn appendSessionInfo(self: *SessionManager, name: []const u8) ![]const u8 {
        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
        const owned_name = if (trimmed.len == 0) null else try self.allocator.dupe(u8, trimmed);
        errdefer if (owned_name) |value| self.allocator.free(value);

        const entry = SessionEntry{
            .session_info = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .name = owned_name,
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn getLabel(self: *const SessionManager, id: []const u8) ?[]const u8 {
        return self.labels_by_id.get(id);
    }

    pub fn appendLabelChange(self: *SessionManager, target_id: []const u8, label: ?[]const u8) ![]const u8 {
        if (self.getEntry(target_id) == null) return error.EntryNotFound;

        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const trimmed = if (label) |value| std.mem.trim(u8, value, &std.ascii.whitespace) else "";
        const owned_label = if (trimmed.len == 0) null else try self.allocator.dupe(u8, trimmed);
        errdefer if (owned_label) |value| self.allocator.free(value);

        const entry = SessionEntry{
            .label = .{
                .id = id,
                .parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null,
                .timestamp = timestamp,
                .target_id = try self.allocator.dupe(u8, target_id),
                .label = owned_label,
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn branch(self: *SessionManager, entry_id: []const u8) !void {
        if (self.getEntry(entry_id) == null) return error.EntryNotFound;
        self.leaf_id = entry_id;
    }

    pub fn branchWithSummary(
        self: *SessionManager,
        branch_from_id: ?[]const u8,
        summary: []const u8,
        details: ?std.json.Value,
        from_hook: ?bool,
    ) ![]const u8 {
        if (branch_from_id) |entry_id| {
            if (self.getEntry(entry_id) == null) return error.EntryNotFound;
        }
        self.leaf_id = branch_from_id;

        const id = try generateUniqueId(self.allocator, &self.by_id);
        errdefer self.allocator.free(id);

        const timestamp = try nowTimestamp(self.allocator, self.io);
        errdefer self.allocator.free(timestamp);

        const owned_details = if (details) |value| try common.cloneJsonValue(self.allocator, value) else null;
        errdefer if (owned_details) |value| common.deinitJsonValue(self.allocator, value);

        const entry = SessionEntry{
            .branch_summary = .{
                .id = id,
                .parent_id = if (branch_from_id) |entry_id| try self.allocator.dupe(u8, entry_id) else null,
                .timestamp = timestamp,
                .from_id = try self.allocator.dupe(u8, branch_from_id orelse "root"),
                .summary = try self.allocator.dupe(u8, summary),
                .details = owned_details,
                .from_hook = from_hook,
            },
        };

        try self.appendEntry(entry);
        return self.leaf_id.?;
    }

    pub fn resetLeaf(self: *SessionManager) void {
        self.leaf_id = null;
    }

    /// Create a new session manager containing only the path from root to
    /// `leaf_id`. The returned manager owns cloned entries and has a fresh
    /// session id. For persisted managers, it writes a new session file in the
    /// same session directory with the current file recorded as parent.
    pub fn createBranchedSession(self: *const SessionManager, leaf_id: []const u8) !SessionManager {
        const path = try self.getBranch(self.allocator, leaf_id);
        defer self.allocator.free(path);
        if (path.len == 0) return error.EntryNotFound;

        var manager = try initEmpty(
            self.allocator,
            self.io,
            self.header.cwd,
            self.session_dir,
            self.persist,
            if (self.persist) self.session_file else null,
        );
        errdefer manager.deinit();

        for (path) |entry| {
            if (entry.* == .label) continue;
            try manager.appendLoadedEntry(try cloneEntry(self.allocator, entry.*));
        }

        try appendBranchedLabelEntries(self, &manager, path);

        try manager.persistToDisk();
        return manager;
    }

    pub fn buildSessionContext(self: *const SessionManager, allocator: std.mem.Allocator) !SessionContext {
        if (self.leaf_id == null) {
            return .{ .messages = try allocator.alloc(agent.AgentMessage, 0) };
        }

        const branch_entries = try self.getBranch(allocator, null);
        defer allocator.free(branch_entries);

        var messages = std.ArrayList(agent.AgentMessage).empty;
        errdefer {
            for (messages.items) |*message| deinitMessage(allocator, message);
            messages.deinit(allocator);
        }

        var thinking_level = agent.ThinkingLevel.off;
        var model: ?SessionModelRef = null;
        var latest_compaction: ?*const CompactionEntry = null;

        for (branch_entries) |entry| {
            switch (entry.*) {
                .message => |message_entry| {
                    updateModelFromMessage(&model, message_entry.message);
                },
                .thinking_level_change => |thinking_entry| {
                    thinking_level = thinking_entry.thinking_level;
                },
                .model_change => |model_entry| {
                    model = .{
                        .provider = model_entry.provider,
                        .model_id = model_entry.model_id,
                    };
                },
                .compaction => |*compaction_entry| {
                    latest_compaction = compaction_entry;
                },
                .branch_summary, .custom, .custom_message, .label, .session_info => {},
            }
        }

        if (latest_compaction) |compaction_entry| {
            try appendClonedVisibleMessage(&messages, compaction_entry.message, allocator);

            const compaction_index = findEntryIndex(branch_entries, compaction_entry.id) orelse return error.InvalidSessionTree;
            var found_first_kept = false;
            var index: usize = 0;
            while (index < compaction_index) : (index += 1) {
                const entry = branch_entries[index];
                if (std.mem.eql(u8, entry.id(), compaction_entry.first_kept_entry_id)) {
                    found_first_kept = true;
                }
                if (found_first_kept) {
                    try appendContextEntry(&messages, entry.*, allocator, &model);
                }
            }

            index = compaction_index + 1;
            while (index < branch_entries.len) : (index += 1) {
                try appendContextEntry(&messages, branch_entries[index].*, allocator, &model);
            }
        } else {
            for (branch_entries) |entry| {
                try appendContextEntry(&messages, entry.*, allocator, &model);
            }
        }

        return .{
            .messages = try messages.toOwnedSlice(allocator),
            .thinking_level = thinking_level,
            .model = model,
        };
    }

    pub fn getBranch(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        from_id: ?[]const u8,
    ) ![]const *const SessionEntry {
        const start_id = from_id orelse self.leaf_id orelse return try allocator.alloc(*const SessionEntry, 0);
        var current = self.getEntry(start_id) orelse return error.EntryNotFound;

        var reversed = std.ArrayList(*const SessionEntry).empty;
        defer reversed.deinit(allocator);

        while (true) {
            try reversed.append(allocator, current);
            const parent_id = current.parentId() orelse break;
            current = self.getEntry(parent_id) orelse return error.InvalidSessionTree;
        }

        const ordered = try allocator.alloc(*const SessionEntry, reversed.items.len);
        for (reversed.items, 0..) |entry, index| {
            ordered[reversed.items.len - index - 1] = entry;
        }
        return ordered;
    }

    pub fn getTree(self: *const SessionManager, allocator: std.mem.Allocator) ![]SessionTreeNode {
        var roots = std.ArrayList(SessionTreeNode).empty;
        errdefer {
            for (roots.items) |*root| root.deinit(allocator);
            roots.deinit(allocator);
        }

        for (self.entries.items) |*entry| {
            if (entry.parentId() == null) {
                try roots.append(allocator, try self.buildTreeNode(allocator, entry));
            }
        }

        return try roots.toOwnedSlice(allocator);
    }

    pub fn exportJson(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        io: std.Io,
        output_path: []const u8,
    ) !void {
        var entries = std.json.Array.init(allocator);
        errdefer common.deinitJsonValue(allocator, .{ .array = entries });

        for (self.entries.items) |entry| {
            try entries.append(try entryToJsonValue(allocator, entry));
        }

        var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer common.deinitJsonValue(allocator, .{ .object = root });
        try root.put(allocator, try allocator.dupe(u8, "header"), try headerToJsonValue(allocator, self.header));
        try root.put(allocator, try allocator.dupe(u8, "entries"), .{ .array = entries });

        const json_value = std.json.Value{ .object = root };
        defer common.deinitJsonValue(allocator, json_value);
        const bytes = try std.json.Stringify.valueAlloc(allocator, json_value, .{ .whitespace = .indent_2 });
        defer allocator.free(bytes);
        try common.writeFileAbsolute(io, output_path, bytes, true);
    }

    fn buildTreeNode(self: *const SessionManager, allocator: std.mem.Allocator, entry: *const SessionEntry) !SessionTreeNode {
        const child_count = self.countChildren(entry.id());
        var children = try allocator.alloc(SessionTreeNode, child_count);
        errdefer allocator.free(children);

        var index: usize = 0;
        for (self.entries.items) |*candidate| {
            const parent_id = candidate.parentId() orelse continue;
            if (!std.mem.eql(u8, parent_id, entry.id())) continue;
            children[index] = try self.buildTreeNode(allocator, candidate);
            index += 1;
        }

        return .{
            .entry = entry,
            .children = children,
            .label = self.labels_by_id.get(entry.id()),
            .label_timestamp = self.label_timestamps_by_id.get(entry.id()),
        };
    }

    fn countChildren(self: *const SessionManager, parent_id: []const u8) usize {
        var count: usize = 0;
        for (self.entries.items) |*entry| {
            const candidate_parent = entry.parentId() orelse continue;
            if (std.mem.eql(u8, candidate_parent, parent_id)) count += 1;
        }
        return count;
    }

    fn appendLoadedEntry(self: *SessionManager, entry: SessionEntry) !void {
        switch (entry) {
            .label => |label_entry| {
                if (label_entry.label) |label| {
                    try self.labels_by_id.put(label_entry.target_id, label);
                    try self.label_timestamps_by_id.put(label_entry.target_id, label_entry.timestamp);
                } else {
                    _ = self.labels_by_id.remove(label_entry.target_id);
                    _ = self.label_timestamps_by_id.remove(label_entry.target_id);
                }
            },
            else => {},
        }
        try self.entries.append(self.allocator, entry);
        const index = self.entries.items.len - 1;
        try self.by_id.put(entry.id(), index);
        self.leaf_id = entry.id();
    }

    fn appendEntry(self: *SessionManager, entry: SessionEntry) !void {
        try self.appendLoadedEntry(entry);
        try self.persistToDisk();
    }

    fn persistToDisk(self: *SessionManager) !void {
        if (!self.persist) return;
        const path = self.session_file orelse return;

        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(self.allocator);

        const header_json = try headerToJsonValue(self.allocator, self.header);
        defer common.deinitJsonValue(self.allocator, header_json);
        const header_line = try std.json.Stringify.valueAlloc(self.allocator, header_json, .{});
        defer self.allocator.free(header_line);
        try bytes.appendSlice(self.allocator, header_line);
        try bytes.append(self.allocator, '\n');

        for (self.entries.items) |entry| {
            const json_value = try entryToJsonValue(self.allocator, entry);
            defer common.deinitJsonValue(self.allocator, json_value);
            const line = try std.json.Stringify.valueAlloc(self.allocator, json_value, .{});
            defer self.allocator.free(line);
            try bytes.appendSlice(self.allocator, line);
            try bytes.append(self.allocator, '\n');
        }

        try common.writeFileAbsolute(self.io, path, bytes.items, true);
    }
};

pub fn findMostRecentSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
) !?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, session_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    var best_name: ?[]const u8 = null;
    defer if (best_name) |name| allocator.free(name);

    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        if (best_name == null or std.mem.order(u8, entry.name, best_name.?) == .gt) {
            if (best_name) |previous| allocator.free(previous);
            best_name = try allocator.dupe(u8, entry.name);
        }
    }

    if (best_name) |name| {
        return try std.fs.path.join(allocator, &[_][]const u8{ session_dir, name });
    }

    return null;
}

pub fn listAllSessionsUnder(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
) ![]SessionSearchInfo {
    var sessions = std.ArrayList(SessionSearchInfo).empty;
    errdefer {
        for (sessions.items) |*session| session.deinit(allocator);
        sessions.deinit(allocator);
    }

    collectSessionsUnder(allocator, io, root_dir, &sessions) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    std.mem.sort(SessionSearchInfo, sessions.items, {}, struct {
        fn lessThan(_: void, lhs: SessionSearchInfo, rhs: SessionSearchInfo) bool {
            const modified_order = std.mem.order(u8, lhs.modified_timestamp, rhs.modified_timestamp);
            if (modified_order != .eq) return modified_order == .gt;
            return std.mem.order(u8, lhs.path, rhs.path) == .lt;
        }
    }.lessThan);

    return try sessions.toOwnedSlice(allocator);
}

pub fn parseSessionSearchQuery(
    allocator: std.mem.Allocator,
    query: []const u8,
) !ParsedSessionSearchQuery {
    var tokens = std.ArrayList(SessionSearchToken).empty;
    errdefer tokens.deinit(allocator);

    var index: usize = 0;
    while (index < query.len) {
        while (index < query.len and std.ascii.isWhitespace(query[index])) : (index += 1) {}
        if (index >= query.len) break;

        var field: SessionSearchField = .any;
        if (detectSessionSearchField(query[index..])) |match| {
            field = match.field;
            index += match.consumed;
        }

        if (index >= query.len) break;

        if (query[index] == '"') {
            index += 1;
            const start = index;
            while (index < query.len and query[index] != '"') : (index += 1) {}
            const value = std.mem.trim(u8, query[start..@min(index, query.len)], &std.ascii.whitespace);
            if (value.len > 0) {
                try tokens.append(allocator, .{
                    .field = field,
                    .kind = .phrase,
                    .value = value,
                });
            }
            if (index < query.len and query[index] == '"') index += 1;
            continue;
        }

        const start = index;
        while (index < query.len and !std.ascii.isWhitespace(query[index])) : (index += 1) {}
        const value = std.mem.trim(u8, query[start..index], &std.ascii.whitespace);
        if (value.len == 0) continue;

        try tokens.append(allocator, .{
            .field = field,
            .kind = .fuzzy,
            .value = value,
        });
    }

    return .{
        .tokens = try tokens.toOwnedSlice(allocator),
    };
}

pub fn filterAndSortSessions(
    allocator: std.mem.Allocator,
    sessions: []const SessionSearchInfo,
    query: []const u8,
    options: SessionSearchOptions,
) ![]SessionSearchMatch {
    const trimmed_query = std.mem.trim(u8, query, &std.ascii.whitespace);
    var parsed = try parseSessionSearchQuery(allocator, trimmed_query);
    defer parsed.deinit(allocator);

    var matches = std.ArrayList(SessionSearchMatch).empty;
    errdefer matches.deinit(allocator);

    for (sessions, 0..) |session, index| {
        if (!matchesSessionNameFilter(session, options.name_filter)) continue;
        if (trimmed_query.len == 0) {
            try matches.append(allocator, .{
                .session_index = index,
                .score = 0,
            });
            continue;
        }

        const result = matchSessionSearchQuery(session, parsed);
        if (!result.matches) continue;

        try matches.append(allocator, .{
            .session_index = index,
            .score = result.score,
        });
    }

    if (trimmed_query.len > 0 and options.sort_mode == .relevance) {
        std.mem.sort(SessionSearchMatch, matches.items, sessions, struct {
            fn lessThan(all_sessions: []const SessionSearchInfo, lhs: SessionSearchMatch, rhs: SessionSearchMatch) bool {
                if (lhs.score != rhs.score) return lhs.score < rhs.score;

                const lhs_session = all_sessions[lhs.session_index];
                const rhs_session = all_sessions[rhs.session_index];
                const modified_order = std.mem.order(u8, lhs_session.modified_timestamp, rhs_session.modified_timestamp);
                if (modified_order != .eq) return modified_order == .gt;
                return std.mem.order(u8, lhs_session.path, rhs_session.path) == .lt;
            }
        }.lessThan);
    }

    return try matches.toOwnedSlice(allocator);
}

pub fn searchSessionsUnder(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    query: []const u8,
    options: SessionSearchOptions,
) !SessionSearchResults {
    const sessions = try listAllSessionsUnder(allocator, io, root_dir);
    errdefer {
        for (@constCast(sessions)) |*session| session.deinit(allocator);
        allocator.free(@constCast(sessions));
    }

    const matches = try filterAndSortSessions(allocator, sessions, query, options);
    errdefer allocator.free(matches);

    return .{
        .sessions = sessions,
        .matches = matches,
    };
}

fn collectSessionsUnder(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    sessions: *std.ArrayList(SessionSearchInfo),
) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, root_dir, .{ .iterate = true });
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const child_path = try std.fs.path.join(allocator, &[_][]const u8{ root_dir, entry.name });
        defer allocator.free(child_path);

        switch (entry.kind) {
            .directory => try collectSessionsUnder(allocator, io, child_path, sessions),
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
                const session_info = buildSessionSearchInfo(allocator, io, child_path) catch continue;
                try sessions.append(allocator, session_info);
            },
            else => {},
        }
    }
}

fn buildSessionSearchInfo(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_file: []const u8,
) !SessionSearchInfo {
    var manager = try SessionManager.openWithWarningWriter(allocator, io, session_file, null, null);
    defer manager.deinit();

    const header = manager.getHeader();

    var all_messages = std.ArrayList(u8).empty;
    defer all_messages.deinit(allocator);

    var first_message: ?[]u8 = null;
    defer if (first_message) |message| allocator.free(message);

    var message_count: usize = 0;
    var modified_timestamp = header.timestamp;

    for (manager.getEntries()) |entry| {
        modified_timestamp = entry.timestamp();

        switch (entry) {
            .message => |message_entry| {
                message_count += 1;
                try appendMessageSearchText(&all_messages, allocator, message_entry.message);

                if (first_message == null and message_entry.message == .user) {
                    first_message = try blocksToSearchTextAlloc(allocator, message_entry.message.user.content);
                }
            },
            .compaction => |compaction_entry| try appendMessageSearchText(&all_messages, allocator, compaction_entry.message),
            .branch_summary => |branch_summary_entry| try appendSearchText(&all_messages, allocator, branch_summary_entry.summary),
            .custom_message => |custom_message_entry| try appendCustomMessageContentSearchText(&all_messages, allocator, custom_message_entry.content),
            else => {},
        }
    }

    const owned_name = if (manager.getSessionName()) |name| try allocator.dupe(u8, name) else null;
    errdefer if (owned_name) |name| allocator.free(name);

    const owned_path = try allocator.dupe(u8, session_file);
    errdefer allocator.free(owned_path);
    const owned_id = try allocator.dupe(u8, header.id);
    errdefer allocator.free(owned_id);
    const owned_cwd = try allocator.dupe(u8, header.cwd);
    errdefer allocator.free(owned_cwd);
    const owned_parent_session = if (header.parent_session) |parent_session|
        try allocator.dupe(u8, parent_session)
    else
        null;
    errdefer if (owned_parent_session) |parent_session| allocator.free(parent_session);
    const owned_created = try allocator.dupe(u8, header.timestamp);
    errdefer allocator.free(owned_created);
    const owned_modified = try allocator.dupe(u8, modified_timestamp);
    errdefer allocator.free(owned_modified);
    const owned_first_message = if (first_message) |message|
        try allocator.dupe(u8, message)
    else
        try allocator.dupe(u8, "(no messages)");
    errdefer allocator.free(owned_first_message);
    const owned_all_messages = try allocator.dupe(u8, all_messages.items);
    errdefer allocator.free(owned_all_messages);
    const search_text = try std.fmt.allocPrint(
        allocator,
        "{s} {s} {s} {s}",
        .{
            header.id,
            owned_name orelse "",
            all_messages.items,
            header.cwd,
        },
    );
    errdefer allocator.free(search_text);

    return .{
        .path = owned_path,
        .id = owned_id,
        .cwd = owned_cwd,
        .name = owned_name,
        .parent_session = owned_parent_session,
        .created_timestamp = owned_created,
        .modified_timestamp = owned_modified,
        .message_count = message_count,
        .first_message = owned_first_message,
        .all_messages_text = owned_all_messages,
        .search_text = search_text,
    };
}

fn appendMessageSearchText(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    message: agent.AgentMessage,
) !void {
    switch (message) {
        .user => |user_message| try appendContentBlocksSearchText(out, allocator, user_message.content),
        .assistant => |assistant_message| try appendContentBlocksSearchText(out, allocator, assistant_message.content),
        .tool_result => |tool_result| try appendContentBlocksSearchText(out, allocator, tool_result.content),
    }
}

fn appendCustomMessageContentSearchText(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    content: CustomMessageContent,
) !void {
    switch (content) {
        .text => |text| try appendSearchText(out, allocator, text),
        .blocks => |blocks| try appendContentBlocksSearchText(out, allocator, blocks),
    }
}

fn appendContentBlocksSearchText(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    blocks: []const ai.ContentBlock,
) !void {
    for (blocks) |block| {
        switch (block) {
            .text => |text| try appendSearchText(out, allocator, text.text),
            .thinking => |thinking| try appendSearchText(out, allocator, thinking.thinking),
            .image => {},
        }
    }
}

fn appendSearchText(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    if (out.items.len > 0) try out.append(allocator, ' ');
    try out.appendSlice(allocator, trimmed);
}

fn blocksToSearchTextAlloc(
    allocator: std.mem.Allocator,
    blocks: []const ai.ContentBlock,
) !?[]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try appendContentBlocksSearchText(&out, allocator, blocks);
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(allocator);
}

fn detectSessionSearchField(query: []const u8) ?struct {
    field: SessionSearchField,
    consumed: usize,
} {
    const prefix_matches = [_]struct {
        prefix: []const u8,
        field: SessionSearchField,
    }{
        .{ .prefix = "name:", .field = .name },
        .{ .prefix = "content:", .field = .content },
        .{ .prefix = "cwd:", .field = .cwd },
        .{ .prefix = "id:", .field = .id },
    };

    inline for (prefix_matches) |candidate| {
        if (std.mem.startsWith(u8, query, candidate.prefix)) {
            return .{
                .field = candidate.field,
                .consumed = candidate.prefix.len,
            };
        }
    }

    return null;
}

fn matchesSessionNameFilter(session: SessionSearchInfo, filter: SessionSearchNameFilter) bool {
    return switch (filter) {
        .all => true,
        .named => if (session.name) |name|
            std.mem.trim(u8, name, &std.ascii.whitespace).len > 0
        else
            false,
    };
}

const SessionSearchMatchResult = struct {
    matches: bool,
    score: i32,
};

fn matchSessionSearchQuery(
    session: SessionSearchInfo,
    query: ParsedSessionSearchQuery,
) SessionSearchMatchResult {
    if (query.tokens.len == 0) return .{ .matches = true, .score = 0 };

    var total_score: i32 = 0;
    for (query.tokens) |token| {
        const text = switch (token.field) {
            .any => session.search_text,
            .name => session.name orelse "",
            .content => session.all_messages_text,
            .cwd => session.cwd,
            .id => session.id,
        };

        switch (token.kind) {
            .phrase => {
                const match_index = indexOfCaseInsensitive(text, token.value) orelse return .{
                    .matches = false,
                    .score = 0,
                };
                total_score += @as(i32, @intCast(match_index * 10));
            },
            .fuzzy => {
                const match = tui.components.autocomplete.fuzzyMatch(token.value, text);
                if (!match.matches) {
                    return .{
                        .matches = false,
                        .score = 0,
                    };
                }
                total_score += match.score;
            },
        }
    }

    return .{
        .matches = true,
        .score = total_score,
    };
}

fn indexOfCaseInsensitive(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        var needle_index: usize = 0;
        while (needle_index < needle.len) : (needle_index += 1) {
            if (std.ascii.toLower(haystack[start + needle_index]) != std.ascii.toLower(needle[needle_index])) {
                matched = false;
                break;
            }
        }
        if (matched) return start;
    }

    return null;
}

fn initEmpty(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    session_dir: []const u8,
    persist: bool,
    parent_session: ?[]const u8,
) !SessionManager {
    const session_id = try generateSessionId(allocator);
    errdefer allocator.free(session_id);

    const timestamp = try nowTimestamp(allocator, io);
    errdefer allocator.free(timestamp);

    const session_dir_copy = try allocator.dupe(u8, session_dir);
    errdefer allocator.free(session_dir_copy);

    const session_file = if (persist)
        try buildSessionFilePath(allocator, session_dir, timestamp, session_id)
    else
        null;
    errdefer if (session_file) |path| allocator.free(path);

    return .{
        .allocator = allocator,
        .io = io,
        .header = .{
            .id = session_id,
            .timestamp = timestamp,
            .cwd = try allocator.dupe(u8, cwd),
            .parent_session = if (parent_session) |path| try allocator.dupe(u8, path) else null,
        },
        .session_dir = session_dir_copy,
        .session_file = session_file,
        .persist = persist,
        .entries = .empty,
        .by_id = std.StringHashMap(usize).init(allocator),
        .labels_by_id = std.StringHashMap([]const u8).init(allocator),
        .label_timestamps_by_id = std.StringHashMap([]const u8).init(allocator),
        .leaf_id = null,
    };
}

fn deinitHeader(allocator: std.mem.Allocator, header: *SessionHeader) void {
    allocator.free(header.id);
    allocator.free(header.timestamp);
    allocator.free(header.cwd);
    if (header.parent_session) |path| allocator.free(path);
}

fn deinitEntry(allocator: std.mem.Allocator, entry: *SessionEntry) void {
    switch (entry.*) {
        .message => |*message_entry| {
            allocator.free(message_entry.id);
            if (message_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(message_entry.timestamp);
            deinitMessage(allocator, &message_entry.message);
        },
        .thinking_level_change => |*thinking_entry| {
            allocator.free(thinking_entry.id);
            if (thinking_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(thinking_entry.timestamp);
        },
        .model_change => |*model_entry| {
            allocator.free(model_entry.id);
            if (model_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(model_entry.timestamp);
            allocator.free(model_entry.provider);
            allocator.free(model_entry.model_id);
        },
        .compaction => |*compaction_entry| {
            allocator.free(compaction_entry.id);
            if (compaction_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(compaction_entry.timestamp);
            allocator.free(compaction_entry.first_kept_entry_id);
            deinitMessage(allocator, &compaction_entry.message);
        },
        .branch_summary => |*branch_summary_entry| {
            allocator.free(branch_summary_entry.id);
            if (branch_summary_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(branch_summary_entry.timestamp);
            allocator.free(branch_summary_entry.from_id);
            allocator.free(branch_summary_entry.summary);
            if (branch_summary_entry.details) |details| common.deinitJsonValue(allocator, details);
        },
        .custom => |*custom_entry| {
            allocator.free(custom_entry.id);
            if (custom_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(custom_entry.timestamp);
            allocator.free(custom_entry.custom_type);
            if (custom_entry.data) |data| common.deinitJsonValue(allocator, data);
        },
        .custom_message => |*custom_message_entry| {
            allocator.free(custom_message_entry.id);
            if (custom_message_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(custom_message_entry.timestamp);
            allocator.free(custom_message_entry.custom_type);
            custom_message_entry.content.deinit(allocator);
            if (custom_message_entry.details) |details| common.deinitJsonValue(allocator, details);
        },
        .label => |*label_entry| {
            allocator.free(label_entry.id);
            if (label_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(label_entry.timestamp);
            allocator.free(label_entry.target_id);
            if (label_entry.label) |label| allocator.free(label);
        },
        .session_info => |*session_info_entry| {
            allocator.free(session_info_entry.id);
            if (session_info_entry.parent_id) |parent_id| allocator.free(parent_id);
            allocator.free(session_info_entry.timestamp);
            if (session_info_entry.name) |name| allocator.free(name);
        },
    }
}

fn branchContainsEntry(branch: []const *const SessionEntry, id: []const u8) bool {
    for (branch) |entry| {
        if (std.mem.eql(u8, entry.id(), id)) return true;
    }
    return false;
}

fn orderedLabelTargetIndex(targets: []const []const u8, target_id: []const u8) ?usize {
    for (targets, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, target_id)) return index;
    }
    return null;
}

fn appendBranchedLabelEntries(
    source: *const SessionManager,
    manager: *SessionManager,
    branch_path: []const *const SessionEntry,
) !void {
    var ordered_targets = std.ArrayList([]const u8).empty;
    defer ordered_targets.deinit(source.allocator);

    for (source.entries.items) |entry| {
        if (entry != .label) continue;
        const label_entry = entry.label;
        if (!branchContainsEntry(branch_path, label_entry.target_id)) continue;

        if (label_entry.label == null) {
            if (orderedLabelTargetIndex(ordered_targets.items, label_entry.target_id)) |index| {
                _ = ordered_targets.orderedRemove(index);
            }
            continue;
        }

        if (orderedLabelTargetIndex(ordered_targets.items, label_entry.target_id) == null) {
            try ordered_targets.append(source.allocator, label_entry.target_id);
        }
    }

    for (ordered_targets.items) |target_id| {
        const resolved_label = source.labels_by_id.get(target_id) orelse continue;
        const label_timestamp = source.label_timestamps_by_id.get(target_id) orelse continue;

        var id: ?[]u8 = try generateUniqueId(manager.allocator, &manager.by_id);
        errdefer if (id) |value| manager.allocator.free(value);

        var parent_id: ?[]u8 = if (manager.leaf_id) |leaf_id| try manager.allocator.dupe(u8, leaf_id) else null;
        errdefer if (parent_id) |value| manager.allocator.free(value);

        var timestamp: ?[]u8 = try manager.allocator.dupe(u8, label_timestamp);
        errdefer if (timestamp) |value| manager.allocator.free(value);

        var owned_target_id: ?[]u8 = try manager.allocator.dupe(u8, target_id);
        errdefer if (owned_target_id) |value| manager.allocator.free(value);

        var owned_label: ?[]u8 = try manager.allocator.dupe(u8, resolved_label);
        errdefer if (owned_label) |value| manager.allocator.free(value);

        var entry = SessionEntry{ .label = .{
            .id = id.?,
            .parent_id = parent_id,
            .timestamp = timestamp.?,
            .target_id = owned_target_id.?,
            .label = owned_label,
        } };
        id = null;
        parent_id = null;
        timestamp = null;
        owned_target_id = null;
        owned_label = null;

        var committed = false;
        errdefer if (!committed) deinitEntry(manager.allocator, &entry);
        try manager.appendLoadedEntry(entry);
        committed = true;
    }
}

fn cloneParentId(allocator: std.mem.Allocator, parent_id: ?[]const u8) !?[]const u8 {
    return if (parent_id) |value| try allocator.dupe(u8, value) else null;
}

fn cloneEntry(allocator: std.mem.Allocator, entry: SessionEntry) !SessionEntry {
    return switch (entry) {
        .message => |message_entry| .{ .message = .{
            .id = try allocator.dupe(u8, message_entry.id),
            .parent_id = try cloneParentId(allocator, message_entry.parent_id),
            .timestamp = try allocator.dupe(u8, message_entry.timestamp),
            .message = try cloneMessage(allocator, message_entry.message),
        } },
        .thinking_level_change => |thinking_entry| .{ .thinking_level_change = .{
            .id = try allocator.dupe(u8, thinking_entry.id),
            .parent_id = try cloneParentId(allocator, thinking_entry.parent_id),
            .timestamp = try allocator.dupe(u8, thinking_entry.timestamp),
            .thinking_level = thinking_entry.thinking_level,
        } },
        .model_change => |model_entry| .{ .model_change = .{
            .id = try allocator.dupe(u8, model_entry.id),
            .parent_id = try cloneParentId(allocator, model_entry.parent_id),
            .timestamp = try allocator.dupe(u8, model_entry.timestamp),
            .provider = try allocator.dupe(u8, model_entry.provider),
            .model_id = try allocator.dupe(u8, model_entry.model_id),
        } },
        .compaction => |compaction_entry| .{ .compaction = .{
            .id = try allocator.dupe(u8, compaction_entry.id),
            .parent_id = try cloneParentId(allocator, compaction_entry.parent_id),
            .timestamp = try allocator.dupe(u8, compaction_entry.timestamp),
            .first_kept_entry_id = try allocator.dupe(u8, compaction_entry.first_kept_entry_id),
            .tokens_before = compaction_entry.tokens_before,
            .message = try cloneMessage(allocator, compaction_entry.message),
        } },
        .branch_summary => |branch_summary_entry| .{ .branch_summary = .{
            .id = try allocator.dupe(u8, branch_summary_entry.id),
            .parent_id = try cloneParentId(allocator, branch_summary_entry.parent_id),
            .timestamp = try allocator.dupe(u8, branch_summary_entry.timestamp),
            .from_id = try allocator.dupe(u8, branch_summary_entry.from_id),
            .summary = try allocator.dupe(u8, branch_summary_entry.summary),
            .details = if (branch_summary_entry.details) |details| try common.cloneJsonValue(allocator, details) else null,
            .from_hook = branch_summary_entry.from_hook,
        } },
        .custom => |custom_entry| .{ .custom = .{
            .id = try allocator.dupe(u8, custom_entry.id),
            .parent_id = try cloneParentId(allocator, custom_entry.parent_id),
            .timestamp = try allocator.dupe(u8, custom_entry.timestamp),
            .custom_type = try allocator.dupe(u8, custom_entry.custom_type),
            .data = if (custom_entry.data) |data| try common.cloneJsonValue(allocator, data) else null,
        } },
        .custom_message => |custom_message_entry| .{ .custom_message = .{
            .id = try allocator.dupe(u8, custom_message_entry.id),
            .parent_id = try cloneParentId(allocator, custom_message_entry.parent_id),
            .timestamp = try allocator.dupe(u8, custom_message_entry.timestamp),
            .custom_type = try allocator.dupe(u8, custom_message_entry.custom_type),
            .content = try cloneCustomMessageContent(allocator, custom_message_entry.content),
            .details = if (custom_message_entry.details) |details| try common.cloneJsonValue(allocator, details) else null,
            .display = custom_message_entry.display,
        } },
        .label => |label_entry| .{ .label = .{
            .id = try allocator.dupe(u8, label_entry.id),
            .parent_id = try cloneParentId(allocator, label_entry.parent_id),
            .timestamp = try allocator.dupe(u8, label_entry.timestamp),
            .target_id = try allocator.dupe(u8, label_entry.target_id),
            .label = if (label_entry.label) |label| try allocator.dupe(u8, label) else null,
        } },
        .session_info => |session_info_entry| .{ .session_info = .{
            .id = try allocator.dupe(u8, session_info_entry.id),
            .parent_id = try cloneParentId(allocator, session_info_entry.parent_id),
            .timestamp = try allocator.dupe(u8, session_info_entry.timestamp),
            .name = if (session_info_entry.name) |name| try allocator.dupe(u8, name) else null,
        } },
    };
}

pub fn cloneMessage(allocator: std.mem.Allocator, message: agent.AgentMessage) !agent.AgentMessage {
    return switch (message) {
        .user => |user| .{ .user = .{
            .role = try allocator.dupe(u8, user.role),
            .content = try cloneContentBlocks(allocator, user.content),
            .timestamp = user.timestamp,
        } },
        .assistant => |assistant| .{ .assistant = .{
            .role = try allocator.dupe(u8, assistant.role),
            .content = try cloneContentBlocks(allocator, assistant.content),
            .tool_calls = if (assistant.tool_calls) |tool_calls| try cloneToolCalls(allocator, tool_calls) else null,
            .api = try allocator.dupe(u8, assistant.api),
            .provider = try allocator.dupe(u8, assistant.provider),
            .model = try allocator.dupe(u8, assistant.model),
            .response_id = if (assistant.response_id) |response_id| try allocator.dupe(u8, response_id) else null,
            .usage = assistant.usage,
            .stop_reason = assistant.stop_reason,
            .error_message = if (assistant.error_message) |error_message| try allocator.dupe(u8, error_message) else null,
            .timestamp = assistant.timestamp,
        } },
        .tool_result => |tool_result| .{ .tool_result = .{
            .role = try allocator.dupe(u8, tool_result.role),
            .tool_call_id = try allocator.dupe(u8, tool_result.tool_call_id),
            .tool_name = try allocator.dupe(u8, tool_result.tool_name),
            .content = try cloneContentBlocks(allocator, tool_result.content),
            .details = if (tool_result.details) |details| try common.cloneJsonValue(allocator, details) else null,
            .is_error = tool_result.is_error,
            .timestamp = tool_result.timestamp,
        } },
    };
}

pub fn deinitMessage(allocator: std.mem.Allocator, message: *agent.AgentMessage) void {
    switch (message.*) {
        .user => |*user| {
            allocator.free(user.role);
            common.deinitContentBlocks(allocator, user.content);
        },
        .assistant => |*assistant| {
            allocator.free(assistant.role);
            common.deinitContentBlocks(allocator, assistant.content);
            if (assistant.tool_calls) |tool_calls| deinitToolCalls(allocator, tool_calls);
            allocator.free(assistant.api);
            allocator.free(assistant.provider);
            allocator.free(assistant.model);
            if (assistant.response_id) |response_id| allocator.free(response_id);
            if (assistant.error_message) |error_message| allocator.free(error_message);
        },
        .tool_result => |*tool_result| {
            allocator.free(tool_result.role);
            allocator.free(tool_result.tool_call_id);
            allocator.free(tool_result.tool_name);
            common.deinitContentBlocks(allocator, tool_result.content);
            if (tool_result.details) |details| common.deinitJsonValue(allocator, details);
        },
    }
}

fn updateModelFromMessage(model: *?SessionModelRef, message: agent.AgentMessage) void {
    switch (message) {
        .assistant => |assistant_message| {
            model.* = .{
                .api = assistant_message.api,
                .provider = assistant_message.provider,
                .model_id = assistant_message.model,
            };
        },
        else => {},
    }
}

fn cloneCustomMessageContent(
    allocator: std.mem.Allocator,
    content: CustomMessageContent,
) !CustomMessageContent {
    return switch (content) {
        .text => |text| .{ .text = try allocator.dupe(u8, text) },
        .blocks => |blocks| .{ .blocks = try cloneContentBlocks(allocator, blocks) },
    };
}

fn appendContextEntry(
    messages: *std.ArrayList(agent.AgentMessage),
    entry: SessionEntry,
    allocator: std.mem.Allocator,
    model: *?SessionModelRef,
) !void {
    switch (entry) {
        .message => |message_entry| {
            updateModelFromMessage(model, message_entry.message);
            try appendClonedVisibleMessage(messages, message_entry.message, allocator);
        },
        .branch_summary => |branch_summary_entry| {
            var message = try createBranchSummaryContextMessage(
                allocator,
                branch_summary_entry.summary,
                branch_summary_entry.timestamp,
            );
            errdefer deinitMessage(allocator, &message);
            try appendOwnedVisibleMessage(messages, allocator, message);
        },
        .custom_message => |custom_message_entry| {
            var message = try createCustomContextMessage(
                allocator,
                custom_message_entry.content,
                custom_message_entry.timestamp,
            );
            errdefer deinitMessage(allocator, &message);
            try appendOwnedVisibleMessage(messages, allocator, message);
        },
        .thinking_level_change,
        .model_change,
        .compaction,
        .custom,
        .label,
        .session_info,
        => {},
    }
}

fn appendClonedVisibleMessage(
    messages: *std.ArrayList(agent.AgentMessage),
    message: agent.AgentMessage,
    allocator: std.mem.Allocator,
) !void {
    var owned = try cloneMessage(allocator, message);
    errdefer deinitMessage(allocator, &owned);
    try appendOwnedVisibleMessage(messages, allocator, owned);
}

fn appendOwnedVisibleMessage(
    messages: *std.ArrayList(agent.AgentMessage),
    allocator: std.mem.Allocator,
    message: agent.AgentMessage,
) !void {
    var owned = message;
    switch (message) {
        .assistant => |assistant_message| {
            if (assistant_message.stop_reason == .error_reason) {
                deinitMessage(allocator, &owned);
                return;
            }
        },
        else => {},
    }
    try messages.append(allocator, owned);
}

fn createBranchSummaryContextMessage(
    allocator: std.mem.Allocator,
    summary: []const u8,
    timestamp: []const u8,
) !agent.AgentMessage {
    const text = try std.fmt.allocPrint(
        allocator,
        "{s}{s}\n{s}",
        .{ BRANCH_SUMMARY_PREFIX, summary, BRANCH_SUMMARY_SUFFIX },
    );
    errdefer allocator.free(text);
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = text } };
    return .{ .user = .{
        .role = try allocator.dupe(u8, "user"),
        .content = blocks,
        .timestamp = parseContextTimestamp(timestamp),
    } };
}

fn createCustomContextMessage(
    allocator: std.mem.Allocator,
    content: CustomMessageContent,
    timestamp: []const u8,
) !agent.AgentMessage {
    return .{ .user = .{
        .role = try allocator.dupe(u8, "user"),
        .content = switch (content) {
            .text => |text| try common.makeTextContent(allocator, text),
            .blocks => |blocks| try cloneContentBlocks(allocator, blocks),
        },
        .timestamp = parseContextTimestamp(timestamp),
    } };
}

fn parseContextTimestamp(timestamp: []const u8) i64 {
    return std.fmt.parseInt(i64, timestamp, 10) catch 0;
}

fn findEntryIndex(entries: []const *const SessionEntry, id: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.id(), id)) return index;
    }
    return null;
}

fn createCompactionSummaryMessage(
    allocator: std.mem.Allocator,
    summary: []const u8,
    timestamp: i64,
) !agent.AgentMessage {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.fmt.allocPrint(allocator, "[compaction]\n{s}", .{summary}) } };
    return .{ .user = .{
        .role = try allocator.dupe(u8, "user"),
        .content = blocks,
        .timestamp = timestamp,
    } };
}

pub fn getCompactionSummary(entry: CompactionEntry) ![]const u8 {
    return switch (entry.message) {
        .user => |user| blk: {
            if (user.content.len == 0 or user.content[0] != .text) return error.InvalidSessionEntry;
            const text = user.content[0].text.text;
            const prefix = "[compaction]\n";
            if (std.mem.startsWith(u8, text, prefix)) {
                break :blk text[prefix.len..];
            }
            break :blk text;
        },
        else => error.InvalidSessionEntry,
    };
}

fn cloneContentBlocks(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]const ai.ContentBlock {
    const cloned = try allocator.alloc(ai.ContentBlock, blocks.len);
    for (blocks, 0..) |block, index| {
        cloned[index] = cloneContentBlock(allocator, block) catch |err| {
            var cleanup_index: usize = 0;
            while (cleanup_index < index) : (cleanup_index += 1) {
                switch (cloned[cleanup_index]) {
                    .text => |text| allocator.free(text.text),
                    .image => |image| {
                        allocator.free(image.data);
                        allocator.free(image.mime_type);
                    },
                    .thinking => |thinking| {
                        allocator.free(thinking.thinking);
                        if (thinking.signature) |signature| allocator.free(signature);
                    },
                }
            }
            allocator.free(cloned);
            return err;
        };
    }

    return cloned;
}

fn cloneContentBlock(allocator: std.mem.Allocator, block: ai.ContentBlock) !ai.ContentBlock {
    return switch (block) {
        .text => |text| ai.ContentBlock{ .text = .{ .text = try allocator.dupe(u8, text.text) } },
        .image => |image| ai.ContentBlock{ .image = .{
            .data = try allocator.dupe(u8, image.data),
            .mime_type = try allocator.dupe(u8, image.mime_type),
        } },
        .thinking => |thinking| ai.ContentBlock{ .thinking = .{
            .thinking = try allocator.dupe(u8, thinking.thinking),
            .signature = if (thinking.signature) |signature| try allocator.dupe(u8, signature) else null,
            .redacted = thinking.redacted,
        } },
    };
}

fn cloneToolCalls(allocator: std.mem.Allocator, tool_calls: []const ai.ToolCall) ![]const ai.ToolCall {
    const cloned = try allocator.alloc(ai.ToolCall, tool_calls.len);
    errdefer allocator.free(cloned);

    for (tool_calls, 0..) |tool_call, index| {
        cloned[index] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments = try common.cloneJsonValue(allocator, tool_call.arguments),
        };
    }

    return cloned;
}

fn deinitToolCalls(allocator: std.mem.Allocator, tool_calls: []const ai.ToolCall) void {
    for (tool_calls) |tool_call| {
        allocator.free(tool_call.id);
        allocator.free(tool_call.name);
        common.deinitJsonValue(allocator, tool_call.arguments);
    }
    allocator.free(tool_calls);
}

fn buildSessionFilePath(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    timestamp: []const u8,
    session_id: []const u8,
) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}_{s}.jsonl", .{ timestamp, session_id });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &[_][]const u8{ session_dir, filename });
}

fn deriveSessionDir(allocator: std.mem.Allocator, session_file: []const u8) ![]u8 {
    const dirname = std.fs.path.dirname(session_file) orelse ".";
    return allocator.dupe(u8, dirname);
}

fn nowTimestamp(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const nanos = std.Io.Clock.now(.real, io).nanoseconds;
    return std.fmt.allocPrint(allocator, "{d}", .{nanos});
}

fn generateSessionId(allocator: std.mem.Allocator) ![]u8 {
    const counter = global_id_counter.fetchAdd(1, .seq_cst);
    return std.fmt.allocPrint(allocator, "{d}-{d}", .{ counter, counter + 1 });
}

fn generateUniqueId(allocator: std.mem.Allocator, by_id: *const std.StringHashMap(usize)) ![]u8 {
    while (true) {
        const counter = global_id_counter.fetchAdd(1, .seq_cst);
        const candidate = try std.fmt.allocPrint(allocator, "{x:0>8}", .{counter});
        if (!by_id.contains(candidate)) return candidate;
        allocator.free(candidate);
    }
}

fn headerToJsonValue(allocator: std.mem.Allocator, header: SessionHeader) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "session") });
    try object.put(allocator, try allocator.dupe(u8, "version"), .{ .integer = CURRENT_SESSION_VERSION });
    try object.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, header.id) });
    try object.put(allocator, try allocator.dupe(u8, "timestamp"), .{ .string = try allocator.dupe(u8, header.timestamp) });
    try object.put(allocator, try allocator.dupe(u8, "cwd"), .{ .string = try allocator.dupe(u8, header.cwd) });
    if (header.parent_session) |parent_session| {
        try object.put(allocator, try allocator.dupe(u8, "parentSession"), .{ .string = try allocator.dupe(u8, parent_session) });
    }
    return .{ .object = object };
}

fn entryToJsonValue(allocator: std.mem.Allocator, entry: SessionEntry) !std.json.Value {
    return switch (entry) {
        .message => |message_entry| blk: {
            var object = try baseEntryObject(allocator, "message", message_entry.id, message_entry.parent_id, message_entry.timestamp);
            try object.put(allocator, try allocator.dupe(u8, "message"), try messageToJsonValue(allocator, message_entry.message));
            break :blk .{ .object = object };
        },
        .thinking_level_change => |thinking_entry| blk: {
            var object = try baseEntryObject(allocator, "thinking_level_change", thinking_entry.id, thinking_entry.parent_id, thinking_entry.timestamp);
            try object.put(allocator, try allocator.dupe(u8, "thinkingLevel"), .{ .string = try allocator.dupe(u8, thinkingLevelToString(thinking_entry.thinking_level)) });
            break :blk .{ .object = object };
        },
        .model_change => |model_entry| blk: {
            var object = try baseEntryObject(allocator, "model_change", model_entry.id, model_entry.parent_id, model_entry.timestamp);
            try object.put(allocator, try allocator.dupe(u8, "provider"), .{ .string = try allocator.dupe(u8, model_entry.provider) });
            try object.put(allocator, try allocator.dupe(u8, "modelId"), .{ .string = try allocator.dupe(u8, model_entry.model_id) });
            break :blk .{ .object = object };
        },
        .compaction => |compaction_entry| blk: {
            var object = try baseEntryObject(allocator, "compaction", compaction_entry.id, compaction_entry.parent_id, compaction_entry.timestamp);
            try object.put(
                allocator,
                try allocator.dupe(u8, "firstKeptEntryId"),
                .{ .string = try allocator.dupe(u8, compaction_entry.first_kept_entry_id) },
            );
            try object.put(allocator, try allocator.dupe(u8, "tokensBefore"), .{ .integer = compaction_entry.tokens_before });
            try object.put(
                allocator,
                try allocator.dupe(u8, "summary"),
                .{ .string = try allocator.dupe(u8, try getCompactionSummary(compaction_entry)) },
            );
            break :blk .{ .object = object };
        },
        .branch_summary => |branch_summary_entry| blk: {
            var object = try baseEntryObject(allocator, "branch_summary", branch_summary_entry.id, branch_summary_entry.parent_id, branch_summary_entry.timestamp);
            try object.put(allocator, try allocator.dupe(u8, "fromId"), .{ .string = try allocator.dupe(u8, branch_summary_entry.from_id) });
            try object.put(allocator, try allocator.dupe(u8, "summary"), .{ .string = try allocator.dupe(u8, branch_summary_entry.summary) });
            if (branch_summary_entry.details) |details| {
                try object.put(allocator, try allocator.dupe(u8, "details"), try common.cloneJsonValue(allocator, details));
            }
            if (branch_summary_entry.from_hook) |from_hook| {
                try object.put(allocator, try allocator.dupe(u8, "fromHook"), .{ .bool = from_hook });
            }
            break :blk .{ .object = object };
        },
        .custom => |custom_entry| blk: {
            var object = try baseEntryObject(allocator, "custom", custom_entry.id, custom_entry.parent_id, custom_entry.timestamp);
            try object.put(allocator, try allocator.dupe(u8, "customType"), .{ .string = try allocator.dupe(u8, custom_entry.custom_type) });
            if (custom_entry.data) |data| {
                try object.put(allocator, try allocator.dupe(u8, "data"), try common.cloneJsonValue(allocator, data));
            }
            break :blk .{ .object = object };
        },
        .custom_message => |custom_message_entry| blk: {
            var object = try baseEntryObject(allocator, "custom_message", custom_message_entry.id, custom_message_entry.parent_id, custom_message_entry.timestamp);
            try object.put(allocator, try allocator.dupe(u8, "customType"), .{ .string = try allocator.dupe(u8, custom_message_entry.custom_type) });
            try object.put(allocator, try allocator.dupe(u8, "content"), try customMessageContentToJsonValue(allocator, custom_message_entry.content));
            try object.put(allocator, try allocator.dupe(u8, "display"), .{ .bool = custom_message_entry.display });
            if (custom_message_entry.details) |details| {
                try object.put(allocator, try allocator.dupe(u8, "details"), try common.cloneJsonValue(allocator, details));
            }
            break :blk .{ .object = object };
        },
        .label => |label_entry| blk: {
            var object = try baseEntryObject(allocator, "label", label_entry.id, label_entry.parent_id, label_entry.timestamp);
            try object.put(allocator, try allocator.dupe(u8, "targetId"), .{ .string = try allocator.dupe(u8, label_entry.target_id) });
            try object.put(
                allocator,
                try allocator.dupe(u8, "label"),
                if (label_entry.label) |label| .{ .string = try allocator.dupe(u8, label) } else .null,
            );
            break :blk .{ .object = object };
        },
        .session_info => |session_info_entry| blk: {
            var object = try baseEntryObject(allocator, "session_info", session_info_entry.id, session_info_entry.parent_id, session_info_entry.timestamp);
            if (session_info_entry.name) |name| {
                try object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, name) });
            } else {
                try object.put(allocator, try allocator.dupe(u8, "name"), .null);
            }
            break :blk .{ .object = object };
        },
    };
}

fn baseEntryObject(
    allocator: std.mem.Allocator,
    entry_type: []const u8,
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
) !std.json.ObjectMap {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, entry_type) });
    try object.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, id) });
    try object.put(
        allocator,
        try allocator.dupe(u8, "parentId"),
        if (parent_id) |value| .{ .string = try allocator.dupe(u8, value) } else .null,
    );
    try object.put(allocator, try allocator.dupe(u8, "timestamp"), .{ .string = try allocator.dupe(u8, timestamp) });
    return object;
}

fn messageToJsonValue(allocator: std.mem.Allocator, message: agent.AgentMessage) !std.json.Value {
    return switch (message) {
        .user => |user| blk: {
            var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "user") });
            if (user.content.len == 1 and user.content[0] == .text) {
                try object.put(allocator, try allocator.dupe(u8, "content"), .{ .string = try allocator.dupe(u8, user.content[0].text.text) });
            } else {
                try object.put(allocator, try allocator.dupe(u8, "content"), try contentBlocksToJsonValue(allocator, user.content, null));
            }
            try object.put(allocator, try allocator.dupe(u8, "timestamp"), .{ .integer = user.timestamp });
            break :blk .{ .object = object };
        },
        .assistant => |assistant| blk: {
            var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "assistant") });
            try object.put(allocator, try allocator.dupe(u8, "content"), try contentBlocksToJsonValue(allocator, assistant.content, assistant.tool_calls));
            try object.put(allocator, try allocator.dupe(u8, "api"), .{ .string = try allocator.dupe(u8, assistant.api) });
            try object.put(allocator, try allocator.dupe(u8, "provider"), .{ .string = try allocator.dupe(u8, assistant.provider) });
            try object.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, assistant.model) });
            if (assistant.response_id) |response_id| {
                try object.put(allocator, try allocator.dupe(u8, "responseId"), .{ .string = try allocator.dupe(u8, response_id) });
            }
            try object.put(allocator, try allocator.dupe(u8, "usage"), try usageToJsonValue(allocator, assistant.usage));
            try object.put(allocator, try allocator.dupe(u8, "stopReason"), .{ .string = try allocator.dupe(u8, stopReasonToString(assistant.stop_reason)) });
            if (assistant.error_message) |error_message| {
                try object.put(allocator, try allocator.dupe(u8, "errorMessage"), .{ .string = try allocator.dupe(u8, error_message) });
            }
            try object.put(allocator, try allocator.dupe(u8, "timestamp"), .{ .integer = assistant.timestamp });
            break :blk .{ .object = object };
        },
        .tool_result => |tool_result| blk: {
            var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "toolResult") });
            try object.put(allocator, try allocator.dupe(u8, "toolCallId"), .{ .string = try allocator.dupe(u8, tool_result.tool_call_id) });
            try object.put(allocator, try allocator.dupe(u8, "toolName"), .{ .string = try allocator.dupe(u8, tool_result.tool_name) });
            try object.put(allocator, try allocator.dupe(u8, "content"), try contentBlocksToJsonValue(allocator, tool_result.content, null));
            if (tool_result.details) |details| {
                try object.put(allocator, try allocator.dupe(u8, "details"), try common.cloneJsonValue(allocator, details));
            }
            try object.put(allocator, try allocator.dupe(u8, "isError"), .{ .bool = tool_result.is_error });
            try object.put(allocator, try allocator.dupe(u8, "timestamp"), .{ .integer = tool_result.timestamp });
            break :blk .{ .object = object };
        },
    };
}

fn contentBlocksToJsonValue(
    allocator: std.mem.Allocator,
    content: []const ai.ContentBlock,
    tool_calls: ?[]const ai.ToolCall,
) !std.json.Value {
    var array = std.json.Array.init(allocator);

    for (content) |block| {
        var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        switch (block) {
            .text => |text| {
                try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
                try object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text.text) });
            },
            .image => |image| {
                try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "image") });
                try object.put(allocator, try allocator.dupe(u8, "data"), .{ .string = try allocator.dupe(u8, image.data) });
                try object.put(allocator, try allocator.dupe(u8, "mimeType"), .{ .string = try allocator.dupe(u8, image.mime_type) });
            },
            .thinking => |thinking| {
                try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "thinking") });
                try object.put(allocator, try allocator.dupe(u8, "thinking"), .{ .string = try allocator.dupe(u8, thinking.thinking) });
                if (thinking.signature) |signature| {
                    try object.put(allocator, try allocator.dupe(u8, "signature"), .{ .string = try allocator.dupe(u8, signature) });
                }
                if (thinking.redacted) {
                    try object.put(allocator, try allocator.dupe(u8, "redacted"), .{ .bool = true });
                }
            },
        }
        try array.append(.{ .object = object });
    }

    if (tool_calls) |calls| {
        for (calls) |tool_call| {
            var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "toolCall") });
            try object.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, tool_call.id) });
            try object.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool_call.name) });
            try object.put(allocator, try allocator.dupe(u8, "arguments"), try common.cloneJsonValue(allocator, tool_call.arguments));
            try array.append(.{ .object = object });
        }
    }

    return .{ .array = array };
}

fn customMessageContentToJsonValue(
    allocator: std.mem.Allocator,
    content: CustomMessageContent,
) !std.json.Value {
    return switch (content) {
        .text => |text| .{ .string = try allocator.dupe(u8, text) },
        .blocks => |blocks| try contentBlocksToJsonValue(allocator, blocks, null),
    };
}

fn usageToJsonValue(allocator: std.mem.Allocator, usage: ai.Usage) !std.json.Value {
    var cost_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try cost_object.put(allocator, try allocator.dupe(u8, "input"), .{ .float = usage.cost.input });
    try cost_object.put(allocator, try allocator.dupe(u8, "output"), .{ .float = usage.cost.output });
    try cost_object.put(allocator, try allocator.dupe(u8, "cacheRead"), .{ .float = usage.cost.cache_read });
    try cost_object.put(allocator, try allocator.dupe(u8, "cacheWrite"), .{ .float = usage.cost.cache_write });
    try cost_object.put(allocator, try allocator.dupe(u8, "total"), .{ .float = usage.cost.total });

    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try object.put(allocator, try allocator.dupe(u8, "input"), .{ .integer = usage.input });
    try object.put(allocator, try allocator.dupe(u8, "output"), .{ .integer = usage.output });
    try object.put(allocator, try allocator.dupe(u8, "cacheRead"), .{ .integer = usage.cache_read });
    try object.put(allocator, try allocator.dupe(u8, "cacheWrite"), .{ .integer = usage.cache_write });
    try object.put(allocator, try allocator.dupe(u8, "totalTokens"), .{ .integer = usage.total_tokens });
    try object.put(allocator, try allocator.dupe(u8, "cost"), .{ .object = cost_object });
    return .{ .object = object };
}

fn logCorruptedSessionLine(
    writer: *std.Io.Writer,
    session_file: []const u8,
    line_number: usize,
    err: anyerror,
) !void {
    try writer.print(
        "Warning: skipped corrupted session line {d} in {s}: {s}\n",
        .{ line_number, session_file, @errorName(err) },
    );
}

fn logCorruptedSessionDataLoss(
    writer: *std.Io.Writer,
    session_file: []const u8,
    skipped_corrupted_lines: usize,
) !void {
    try writer.print(
        "Warning: loaded session {s} with {d} corrupted line{s} skipped; valid entries were preserved but some session data was lost.\n",
        .{
            session_file,
            skipped_corrupted_lines,
            if (skipped_corrupted_lines == 1) "" else "s",
        },
    );
}

fn parseHeaderLine(allocator: std.mem.Allocator, line: []const u8) !SessionHeader {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    const object = try requireObject(parsed.value);
    const entry_type = try getRequiredString(object, "type");
    if (!std.mem.eql(u8, entry_type, "session")) return error.InvalidSessionFile;

    return .{
        .id = try allocator.dupe(u8, try getRequiredString(object, "id")),
        .timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp")),
        .cwd = try allocator.dupe(u8, try getRequiredString(object, "cwd")),
        .parent_session = if (getOptionalString(object, "parentSession")) |value| try allocator.dupe(u8, value) else null,
    };
}

fn parseEntryLine(allocator: std.mem.Allocator, line: []const u8) !SessionEntry {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    const object = try requireObject(parsed.value);
    const entry_type = try getRequiredString(object, "type");

    if (std.mem.eql(u8, entry_type, "message")) {
        const id = try allocator.dupe(u8, try getRequiredString(object, "id"));
        errdefer allocator.free(id);
        const parent_id = if (getOptionalString(object, "parentId")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (parent_id) |value| allocator.free(value);
        const timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp"));
        errdefer allocator.free(timestamp);
        var message = try parseMessageValue(allocator, object.get("message") orelse return error.InvalidSessionEntry);
        errdefer deinitMessage(allocator, &message);

        return .{ .message = .{
            .id = id,
            .parent_id = parent_id,
            .timestamp = timestamp,
            .message = message,
        } };
    }

    if (std.mem.eql(u8, entry_type, "thinking_level_change")) {
        const id = try allocator.dupe(u8, try getRequiredString(object, "id"));
        errdefer allocator.free(id);
        const parent_id = if (getOptionalString(object, "parentId")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (parent_id) |value| allocator.free(value);
        const timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp"));
        errdefer allocator.free(timestamp);
        const thinking_level = try parseThinkingLevel(try getRequiredString(object, "thinkingLevel"));

        return .{ .thinking_level_change = .{
            .id = id,
            .parent_id = parent_id,
            .timestamp = timestamp,
            .thinking_level = thinking_level,
        } };
    }

    if (std.mem.eql(u8, entry_type, "model_change")) {
        const id = try allocator.dupe(u8, try getRequiredString(object, "id"));
        errdefer allocator.free(id);
        const parent_id = if (getOptionalString(object, "parentId")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (parent_id) |value| allocator.free(value);
        const timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp"));
        errdefer allocator.free(timestamp);
        const provider = try allocator.dupe(u8, try getRequiredString(object, "provider"));
        errdefer allocator.free(provider);
        const model_id = try allocator.dupe(u8, try getRequiredString(object, "modelId"));
        errdefer allocator.free(model_id);

        return .{ .model_change = .{
            .id = id,
            .parent_id = parent_id,
            .timestamp = timestamp,
            .provider = provider,
            .model_id = model_id,
        } };
    }

    if (std.mem.eql(u8, entry_type, "compaction")) {
        const summary = try getRequiredString(object, "summary");
        const id = try allocator.dupe(u8, try getRequiredString(object, "id"));
        errdefer allocator.free(id);
        const parent_id = if (getOptionalString(object, "parentId")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (parent_id) |value| allocator.free(value);
        const timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp"));
        errdefer allocator.free(timestamp);
        const first_kept_entry_id = try allocator.dupe(u8, try getRequiredString(object, "firstKeptEntryId"));
        errdefer allocator.free(first_kept_entry_id);
        var message = try createCompactionSummaryMessage(allocator, summary, 0);
        errdefer deinitMessage(allocator, &message);

        return .{ .compaction = .{
            .id = id,
            .parent_id = parent_id,
            .timestamp = timestamp,
            .first_kept_entry_id = first_kept_entry_id,
            .tokens_before = @intCast(try getRequiredInteger(object, "tokensBefore")),
            .message = message,
        } };
    }

    if (std.mem.eql(u8, entry_type, "branch_summary")) {
        const id = try allocator.dupe(u8, try getRequiredString(object, "id"));
        errdefer allocator.free(id);
        const parent_id = if (getOptionalString(object, "parentId")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (parent_id) |value| allocator.free(value);
        const timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp"));
        errdefer allocator.free(timestamp);
        const from_id = try allocator.dupe(u8, try getRequiredString(object, "fromId"));
        errdefer allocator.free(from_id);
        const summary = try allocator.dupe(u8, try getRequiredString(object, "summary"));
        errdefer allocator.free(summary);
        const details = if (object.get("details")) |value| try common.cloneJsonValue(allocator, value) else null;
        errdefer if (details) |value| common.deinitJsonValue(allocator, value);

        return .{ .branch_summary = .{
            .id = id,
            .parent_id = parent_id,
            .timestamp = timestamp,
            .from_id = from_id,
            .summary = summary,
            .details = details,
            .from_hook = getOptionalBool(object, "fromHook"),
        } };
    }

    if (std.mem.eql(u8, entry_type, "custom")) {
        const id = try allocator.dupe(u8, try getRequiredString(object, "id"));
        errdefer allocator.free(id);
        const parent_id = if (getOptionalString(object, "parentId")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (parent_id) |value| allocator.free(value);
        const timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp"));
        errdefer allocator.free(timestamp);
        const custom_type = try allocator.dupe(u8, try getRequiredString(object, "customType"));
        errdefer allocator.free(custom_type);
        const data = if (object.get("data")) |value| try common.cloneJsonValue(allocator, value) else null;
        errdefer if (data) |value| common.deinitJsonValue(allocator, value);

        return .{ .custom = .{
            .id = id,
            .parent_id = parent_id,
            .timestamp = timestamp,
            .custom_type = custom_type,
            .data = data,
        } };
    }

    if (std.mem.eql(u8, entry_type, "custom_message")) {
        const id = try allocator.dupe(u8, try getRequiredString(object, "id"));
        errdefer allocator.free(id);
        const parent_id = if (getOptionalString(object, "parentId")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (parent_id) |value| allocator.free(value);
        const timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp"));
        errdefer allocator.free(timestamp);
        const custom_type = try allocator.dupe(u8, try getRequiredString(object, "customType"));
        errdefer allocator.free(custom_type);
        const content = try parseCustomMessageContentValue(allocator, object.get("content") orelse return error.InvalidSessionEntry);
        errdefer {
            var cleanup_content = content;
            cleanup_content.deinit(allocator);
        }
        const details = if (object.get("details")) |value| try common.cloneJsonValue(allocator, value) else null;
        errdefer if (details) |value| common.deinitJsonValue(allocator, value);

        return .{ .custom_message = .{
            .id = id,
            .parent_id = parent_id,
            .timestamp = timestamp,
            .custom_type = custom_type,
            .content = content,
            .details = details,
            .display = try getRequiredBool(object, "display"),
        } };
    }

    if (std.mem.eql(u8, entry_type, "label")) {
        const id = try allocator.dupe(u8, try getRequiredString(object, "id"));
        errdefer allocator.free(id);
        const parent_id = if (getOptionalString(object, "parentId")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (parent_id) |value| allocator.free(value);
        const timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp"));
        errdefer allocator.free(timestamp);
        const target_id = try allocator.dupe(u8, try getRequiredString(object, "targetId"));
        errdefer allocator.free(target_id);
        const label = if (getOptionalString(object, "label")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (label) |value| allocator.free(value);

        return .{ .label = .{
            .id = id,
            .parent_id = parent_id,
            .timestamp = timestamp,
            .target_id = target_id,
            .label = label,
        } };
    }

    if (std.mem.eql(u8, entry_type, "session_info")) {
        const id = try allocator.dupe(u8, try getRequiredString(object, "id"));
        errdefer allocator.free(id);
        const parent_id = if (getOptionalString(object, "parentId")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (parent_id) |value| allocator.free(value);
        const timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp"));
        errdefer allocator.free(timestamp);
        const name = if (getOptionalString(object, "name")) |value| try allocator.dupe(u8, value) else null;
        errdefer if (name) |value| allocator.free(value);

        return .{ .session_info = .{
            .id = id,
            .parent_id = parent_id,
            .timestamp = timestamp,
            .name = name,
        } };
    }

    return error.UnsupportedSessionEntryType;
}

fn parseMessageValue(allocator: std.mem.Allocator, value: std.json.Value) !agent.AgentMessage {
    const object = try requireObject(value);
    const role = try getRequiredString(object, "role");

    if (std.mem.eql(u8, role, "user")) {
        return .{ .user = .{
            .role = try allocator.dupe(u8, "user"),
            .content = try parseUserContentValue(allocator, object.get("content") orelse return error.InvalidSessionMessage),
            .timestamp = try getRequiredI64(object, "timestamp"),
        } };
    }

    if (std.mem.eql(u8, role, "assistant")) {
        const parsed_content = try parseAssistantContentValue(allocator, object.get("content") orelse return error.InvalidSessionMessage);
        return .{ .assistant = .{
            .role = try allocator.dupe(u8, "assistant"),
            .content = parsed_content.content,
            .tool_calls = parsed_content.tool_calls,
            .api = try allocator.dupe(u8, try getRequiredString(object, "api")),
            .provider = try allocator.dupe(u8, try getRequiredString(object, "provider")),
            .model = try allocator.dupe(u8, try getRequiredString(object, "model")),
            .response_id = if (getOptionalString(object, "responseId")) |response_id| try allocator.dupe(u8, response_id) else null,
            .usage = try parseUsageValue(object.get("usage") orelse return error.InvalidSessionMessage),
            .stop_reason = try parseStopReason(try getRequiredString(object, "stopReason")),
            .error_message = if (getOptionalString(object, "errorMessage")) |error_message| try allocator.dupe(u8, error_message) else null,
            .timestamp = try getRequiredI64(object, "timestamp"),
        } };
    }

    if (std.mem.eql(u8, role, "toolResult")) {
        return .{ .tool_result = .{
            .role = try allocator.dupe(u8, "toolResult"),
            .tool_call_id = try allocator.dupe(u8, try getRequiredString(object, "toolCallId")),
            .tool_name = try allocator.dupe(u8, try getRequiredString(object, "toolName")),
            .content = try parseGenericContentValue(allocator, object.get("content") orelse return error.InvalidSessionMessage),
            .details = if (object.get("details")) |details| try common.cloneJsonValue(allocator, details) else null,
            .is_error = getOptionalBool(object, "isError") orelse false,
            .timestamp = try getRequiredI64(object, "timestamp"),
        } };
    }

    return error.UnsupportedSessionMessageRole;
}

fn parseCustomMessageContentValue(allocator: std.mem.Allocator, value: std.json.Value) !CustomMessageContent {
    return switch (value) {
        .string => |text| .{ .text = try allocator.dupe(u8, text) },
        .array => .{ .blocks = try parseGenericContentValue(allocator, value) },
        else => error.InvalidSessionEntry,
    };
}

fn parseUserContentValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const ai.ContentBlock {
    return switch (value) {
        .string => |text| blk: {
            const blocks = try allocator.alloc(ai.ContentBlock, 1);
            blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
            break :blk blocks;
        },
        .array => try parseGenericContentValue(allocator, value),
        else => error.InvalidSessionMessage,
    };
}

fn parseAssistantContentValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !struct { content: []const ai.ContentBlock, tool_calls: ?[]const ai.ToolCall } {
    const array = try requireArray(value);

    var content = std.ArrayList(ai.ContentBlock).empty;
    errdefer {
        const owned = content.toOwnedSlice(allocator) catch &[_]ai.ContentBlock{};
        if (owned.len > 0) common.deinitContentBlocks(allocator, owned);
    }

    var tool_calls = std.ArrayList(ai.ToolCall).empty;
    errdefer {
        const owned = tool_calls.toOwnedSlice(allocator) catch &[_]ai.ToolCall{};
        if (owned.len > 0) deinitToolCalls(allocator, owned);
    }

    for (array.items) |item| {
        const object = try requireObject(item);
        const item_type = try getRequiredString(object, "type");

        if (std.mem.eql(u8, item_type, "toolCall")) {
            try tool_calls.append(allocator, .{
                .id = try allocator.dupe(u8, try getRequiredString(object, "id")),
                .name = try allocator.dupe(u8, try getRequiredString(object, "name")),
                .arguments = try common.cloneJsonValue(allocator, object.get("arguments") orelse .null),
            });
            continue;
        }

        try content.append(allocator, try parseContentBlockObject(allocator, object));
    }

    return .{
        .content = try content.toOwnedSlice(allocator),
        .tool_calls = if (tool_calls.items.len == 0) null else try tool_calls.toOwnedSlice(allocator),
    };
}

fn parseGenericContentValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const ai.ContentBlock {
    const array = try requireArray(value);
    const blocks = try allocator.alloc(ai.ContentBlock, array.items.len);
    errdefer allocator.free(blocks);

    for (array.items, 0..) |item, index| {
        blocks[index] = try parseContentBlockObject(allocator, try requireObject(item));
    }

    return blocks;
}

fn parseContentBlockObject(allocator: std.mem.Allocator, object: std.json.ObjectMap) !ai.ContentBlock {
    const item_type = try getRequiredString(object, "type");

    if (std.mem.eql(u8, item_type, "text")) {
        return .{ .text = .{ .text = try allocator.dupe(u8, try getRequiredString(object, "text")) } };
    }

    if (std.mem.eql(u8, item_type, "image")) {
        return .{ .image = .{
            .data = try allocator.dupe(u8, try getRequiredString(object, "data")),
            .mime_type = try allocator.dupe(u8, try getRequiredString(object, "mimeType")),
        } };
    }

    if (std.mem.eql(u8, item_type, "thinking")) {
        return .{ .thinking = .{
            .thinking = try allocator.dupe(u8, try getRequiredString(object, "thinking")),
            .signature = if (getOptionalString(object, "signature")) |signature| try allocator.dupe(u8, signature) else null,
            .redacted = getOptionalBool(object, "redacted") orelse false,
        } };
    }

    return error.UnsupportedContentType;
}

fn parseUsageValue(value: std.json.Value) !ai.Usage {
    const object = try requireObject(value);
    const cost_value = object.get("cost");
    const cost = if (cost_value) |raw_cost| try parseUsageCost(raw_cost) else ai.types.UsageCost.init();

    return .{
        .input = try getRequiredU32(object, "input"),
        .output = try getRequiredU32(object, "output"),
        .cache_read = try getRequiredU32(object, "cacheRead"),
        .cache_write = try getRequiredU32(object, "cacheWrite"),
        .total_tokens = try getRequiredU32(object, "totalTokens"),
        .cost = cost,
    };
}

fn parseUsageCost(value: std.json.Value) !ai.types.UsageCost {
    const object = try requireObject(value);
    return .{
        .input = getNumber(object, "input") orelse 0,
        .output = getNumber(object, "output") orelse 0,
        .cache_read = getNumber(object, "cacheRead") orelse 0,
        .cache_write = getNumber(object, "cacheWrite") orelse 0,
        .total = getNumber(object, "total") orelse 0,
    };
}

fn thinkingLevelToString(level: agent.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn parseThinkingLevel(value: []const u8) !agent.ThinkingLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return error.InvalidThinkingLevel;
}

fn stopReasonToString(reason: ai.StopReason) []const u8 {
    return switch (reason) {
        .stop => "stop",
        .length => "length",
        .tool_use => "toolUse",
        .error_reason => "error",
        .aborted => "aborted",
    };
}

fn parseStopReason(value: []const u8) !ai.StopReason {
    if (std.mem.eql(u8, value, "stop")) return .stop;
    if (std.mem.eql(u8, value, "length")) return .length;
    if (std.mem.eql(u8, value, "toolUse") or std.mem.eql(u8, value, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, value, "error") or std.mem.eql(u8, value, "error_reason")) return .error_reason;
    if (std.mem.eql(u8, value, "aborted")) return .aborted;
    return error.InvalidStopReason;
}

fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidSessionFile,
    };
}

fn requireArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.InvalidSessionFile,
    };
}

fn getRequiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidField,
    };
}

fn getRequiredInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .integer => |integer| integer,
        else => error.InvalidField,
    };
}

fn getOptionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        .null => null,
        else => null,
    };
}

fn getOptionalBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |bool_value| bool_value,
        else => null,
    };
}

fn getRequiredBool(object: std.json.ObjectMap, key: []const u8) !bool {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .bool => |bool_value| bool_value,
        else => error.InvalidField,
    };
}

fn getRequiredI64(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .integer => |integer| @intCast(integer),
        else => error.InvalidField,
    };
}

fn getRequiredU32(object: std.json.ObjectMap, key: []const u8) !u32 {
    const value = object.get(key) orelse return error.MissingField;
    return switch (value) {
        .integer => |integer| std.math.cast(u32, integer) orelse return error.InvalidField,
        else => error.InvalidField,
    };
}

fn getNumber(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float_value| float_value,
        else => null,
    };
}

fn makeAbsoluteTestPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

fn userTextMessage(allocator: std.mem.Allocator, text: []const u8, timestamp: i64) !agent.AgentMessage {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return .{ .user = .{
        .role = try allocator.dupe(u8, "user"),
        .content = blocks,
        .timestamp = timestamp,
    } };
}

fn assistantTextMessage(
    allocator: std.mem.Allocator,
    text: []const u8,
    model: ai.Model,
    timestamp: i64,
) !agent.AgentMessage {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return .{ .assistant = .{
        .role = try allocator.dupe(u8, "assistant"),
        .content = blocks,
        .tool_calls = null,
        .api = try allocator.dupe(u8, model.api),
        .provider = try allocator.dupe(u8, model.provider),
        .model = try allocator.dupe(u8, model.id),
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = timestamp,
    } };
}

fn toolResultTextMessage(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    tool_name: []const u8,
    text: []const u8,
    timestamp: i64,
) !agent.AgentMessage {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return .{ .tool_result = .{
        .role = try allocator.dupe(u8, "toolResult"),
        .tool_call_id = try allocator.dupe(u8, tool_call_id),
        .tool_name = try allocator.dupe(u8, tool_name),
        .content = blocks,
        .details = null,
        .is_error = false,
        .timestamp = timestamp,
    } };
}

fn sessionSearchTestModel() ai.Model {
    return .{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };
}

fn countJsonLines(bytes: []const u8) usize {
    var count: usize = 0;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn parseJsonTestValue(allocator: std.mem.Allocator, json: []const u8) !std.json.Value {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    return try common.cloneJsonValue(allocator, parsed.value);
}

test "session manager creates empty session with metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer manager.deinit();

    try std.testing.expectEqualStrings("/tmp/project", manager.getCwd());
    try std.testing.expect(manager.getSessionFile() != null);
    try std.testing.expectEqual(@as(usize, 0), manager.getEntries().len);
    try std.testing.expect(manager.getLeafId() == null);
    try std.testing.expectEqual(CURRENT_SESSION_VERSION, CURRENT_SESSION_VERSION);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, manager.getSessionFile().?, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);

    try std.testing.expect(countJsonLines(written) == 1);
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"type\":\"session\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"cwd\":\"/tmp/project\""));
}

test "session manager persists messages to jsonl and resumes from disk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer manager.deinit();

    var user = try userTextMessage(std.testing.allocator, "hello", 1);
    defer deinitMessage(std.testing.allocator, &user);
    _ = try manager.appendMessage(user);

    var assistant = try assistantTextMessage(std.testing.allocator, "world", model, 2);
    defer deinitMessage(std.testing.allocator, &assistant);
    _ = try manager.appendMessage(assistant);

    const tool_result_timestamp = agent.nowMilliseconds();
    try std.testing.expect(tool_result_timestamp > 0);
    var tool_result = try toolResultTextMessage(std.testing.allocator, "tool-1", "bash", "tool output", tool_result_timestamp);
    defer deinitMessage(std.testing.allocator, &tool_result);
    _ = try manager.appendMessage(tool_result);

    const session_file = try std.testing.allocator.dupe(u8, manager.getSessionFile().?);
    defer std.testing.allocator.free(session_file);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);

    try std.testing.expectEqual(@as(usize, 4), countJsonLines(written));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"role\":\"user\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"role\":\"assistant\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"role\":\"toolResult\""));

    var reopened = try SessionManager.open(std.testing.allocator, std.testing.io, session_file, null);
    defer reopened.deinit();

    var context = try reopened.buildSessionContext(std.testing.allocator);
    defer context.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), context.messages.len);
    try std.testing.expectEqualStrings("hello", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("world", context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("tool output", context.messages[2].tool_result.content[0].text.text);
    try std.testing.expectEqual(tool_result_timestamp, context.messages[2].tool_result.timestamp);
    try std.testing.expectEqualStrings("faux", context.model.?.provider);
    try std.testing.expectEqualStrings("faux-session", context.model.?.model_id);
}

test "session manager persists session names and labels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer manager.deinit();

    var user = try userTextMessage(std.testing.allocator, "hello", 1);
    defer deinitMessage(std.testing.allocator, &user);
    const user_id = try manager.appendMessage(user);

    _ = try manager.appendSessionInfo("Night Shift");
    _ = try manager.appendLabelChange(user_id, "bookmark");

    try std.testing.expectEqualStrings("Night Shift", manager.getSessionName().?);
    try std.testing.expectEqualStrings("bookmark", manager.getLabel(user_id).?);

    const tree = try manager.getTree(std.testing.allocator);
    defer {
        for (tree) |*node| node.deinit(std.testing.allocator);
        std.testing.allocator.free(tree);
    }

    try std.testing.expectEqual(@as(usize, 1), tree.len);
    try std.testing.expectEqualStrings("bookmark", tree[0].label.?);

    const session_file = try std.testing.allocator.dupe(u8, manager.getSessionFile().?);
    defer std.testing.allocator.free(session_file);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"session_info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"name\":\"Night Shift\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"label\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"label\":\"bookmark\"") != null);

    var reopened = try SessionManager.open(std.testing.allocator, std.testing.io, session_file, null);
    defer reopened.deinit();

    try std.testing.expectEqualStrings("Night Shift", reopened.getSessionName().?);
    try std.testing.expectEqualStrings("bookmark", reopened.getLabel(user_id).?);
}

test "session manager createBranchedSession recreates label parent chain from branch tail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer manager.deinit();

    var first = try userTextMessage(std.testing.allocator, "first", 1);
    defer deinitMessage(std.testing.allocator, &first);
    const first_id = try manager.appendMessage(first);

    var second = try assistantTextMessage(std.testing.allocator, "second", model, 2);
    defer deinitMessage(std.testing.allocator, &second);
    const second_id = try manager.appendMessage(second);

    var third = try userTextMessage(std.testing.allocator, "third", 3);
    defer deinitMessage(std.testing.allocator, &third);
    _ = try manager.appendMessage(third);

    const obsolete_first_label_id = try manager.appendLabelChange(first_id, "first draft");
    const second_label_id = try manager.appendLabelChange(second_id, "second label");
    const final_first_label_id = try manager.appendLabelChange(first_id, "first final");

    var branched = try manager.createBranchedSession(second_id);
    defer branched.deinit();

    const entries = branched.getEntries();
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expect(entries[0] == .message);
    try std.testing.expect(entries[1] == .message);
    try std.testing.expect(entries[2] == .label);
    try std.testing.expect(entries[3] == .label);
    try std.testing.expectEqualStrings(first_id, entries[0].message.id);
    try std.testing.expectEqualStrings(second_id, entries[1].message.id);

    try std.testing.expect(entries[2].label.parent_id != null);
    try std.testing.expectEqualStrings(second_id, entries[2].label.parent_id.?);
    try std.testing.expectEqualStrings(first_id, entries[2].label.target_id);
    try std.testing.expectEqualStrings("first final", entries[2].label.label.?);
    try std.testing.expect(!std.mem.eql(u8, obsolete_first_label_id, entries[2].label.id));
    try std.testing.expect(!std.mem.eql(u8, final_first_label_id, entries[2].label.id));

    try std.testing.expect(entries[3].label.parent_id != null);
    try std.testing.expectEqualStrings(entries[2].label.id, entries[3].label.parent_id.?);
    try std.testing.expectEqualStrings(second_id, entries[3].label.target_id);
    try std.testing.expectEqualStrings("second label", entries[3].label.label.?);
    try std.testing.expect(!std.mem.eql(u8, second_label_id, entries[3].label.id));

    try std.testing.expectEqualStrings("first final", branched.getLabel(first_id).?);
    try std.testing.expectEqualStrings("second label", branched.getLabel(second_id).?);
}

test "session manager persists branch summaries and custom entry types" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer manager.deinit();

    var user = try userTextMessage(std.testing.allocator, "hello", 1);
    defer deinitMessage(std.testing.allocator, &user);
    const user_id = try manager.appendMessage(user);

    const custom_data = try parseJsonTestValue(std.testing.allocator, "{\"step\":1,\"state\":\"warm\"}");
    defer common.deinitJsonValue(std.testing.allocator, custom_data);
    _ = try manager.appendCustomEntry("ext.state", custom_data);

    const custom_details = try parseJsonTestValue(std.testing.allocator, "{\"visible\":true}");
    defer common.deinitJsonValue(std.testing.allocator, custom_details);
    _ = try manager.appendCustomMessageEntry(
        "ext.note",
        .{ .text = "remember this branch" },
        true,
        custom_details,
    );

    const branch_details = try parseJsonTestValue(std.testing.allocator, "{\"files\":[\"a.txt\",\"b.txt\"]}");
    defer common.deinitJsonValue(std.testing.allocator, branch_details);
    const summary_id = try manager.branchWithSummary(manager.getLeafId(), "branched away from alternate draft", branch_details, true);

    _ = try manager.appendLabelChange(user_id, "bookmark");
    _ = try manager.appendSessionInfo("Night Shift");

    var context = try manager.buildSessionContext(std.testing.allocator);
    defer context.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), context.messages.len);
    try std.testing.expectEqualStrings("hello", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("remember this branch", context.messages[1].user.content[0].text.text);
    try std.testing.expect(std.mem.indexOf(u8, context.messages[2].user.content[0].text.text, "branched away from alternate draft") != null);

    try std.testing.expectEqualStrings("Night Shift", manager.getSessionName().?);
    try std.testing.expectEqualStrings("bookmark", manager.getLabel(user_id).?);

    const session_file = try std.testing.allocator.dupe(u8, manager.getSessionFile().?);
    defer std.testing.allocator.free(session_file);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"custom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"custom_message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"type\":\"branch_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"customType\":\"ext.note\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"fromHook\":true") != null);

    var reopened = try SessionManager.open(std.testing.allocator, std.testing.io, session_file, null);
    defer reopened.deinit();

    try std.testing.expectEqualStrings("Night Shift", reopened.getSessionName().?);
    try std.testing.expectEqualStrings("bookmark", reopened.getLabel(user_id).?);

    const reopened_summary = reopened.getEntry(summary_id);
    try std.testing.expect(reopened_summary != null);
    try std.testing.expect(reopened_summary.?.* == .branch_summary);
    try std.testing.expectEqualStrings("branched away from alternate draft", reopened_summary.?.branch_summary.summary);
    try std.testing.expectEqual(true, reopened_summary.?.branch_summary.from_hook.?);

    const entries = reopened.getEntries();
    try std.testing.expectEqual(@as(usize, 6), entries.len);
    try std.testing.expect(entries[1] == .custom);
    try std.testing.expect(entries[2] == .custom_message);
    try std.testing.expect(entries[3] == .branch_summary);

    var reopened_context = try reopened.buildSessionContext(std.testing.allocator);
    defer reopened_context.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), reopened_context.messages.len);
    try std.testing.expect(std.mem.indexOf(u8, reopened_context.messages[2].user.content[0].text.text, BRANCH_SUMMARY_PREFIX) != null);
}

test "session manager logs corrupted lines while preserving valid entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer manager.deinit();

    var user = try userTextMessage(std.testing.allocator, "hello", 1);
    defer deinitMessage(std.testing.allocator, &user);
    _ = try manager.appendMessage(user);

    var assistant = try assistantTextMessage(std.testing.allocator, "world", model, 2);
    defer deinitMessage(std.testing.allocator, &assistant);
    _ = try manager.appendMessage(assistant);

    const session_file = try std.testing.allocator.dupe(u8, manager.getSessionFile().?);
    defer std.testing.allocator.free(session_file);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);

    var rebuilt = std.ArrayList(u8).empty;
    defer rebuilt.deinit(std.testing.allocator);

    var lines = std.mem.splitScalar(u8, written, '\n');
    const header_line = lines.next().?;
    const user_line = lines.next().?;
    const assistant_line = lines.next().?;

    try rebuilt.appendSlice(std.testing.allocator, header_line);
    try rebuilt.append(std.testing.allocator, '\n');
    try rebuilt.appendSlice(std.testing.allocator, user_line);
    try rebuilt.append(std.testing.allocator, '\n');
    try rebuilt.appendSlice(std.testing.allocator, "{\"type\":\"corrupted\"}");
    try rebuilt.append(std.testing.allocator, '\n');
    try rebuilt.appendSlice(std.testing.allocator, assistant_line);
    try rebuilt.append(std.testing.allocator, '\n');

    try common.writeFileAbsolute(std.testing.io, session_file, rebuilt.items, true);

    var warning_capture: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer warning_capture.deinit();

    var reopened = try SessionManager.openWithWarningWriter(
        std.testing.allocator,
        std.testing.io,
        session_file,
        null,
        &warning_capture.writer,
    );
    defer reopened.deinit();

    var context = try reopened.buildSessionContext(std.testing.allocator);
    defer context.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqualStrings("hello", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("world", context.messages[1].assistant.content[0].text.text);

    const warnings = warning_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, warnings, "line 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "UnsupportedSessionEntryType") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "data was lost") != null);
}

test "session manager skips invalid json shapes without panicking" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer std.testing.allocator.free(relative_dir);
    const session_dir = try makeAbsoluteTestPath(std.testing.allocator, relative_dir);
    defer std.testing.allocator.free(session_dir);

    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var manager = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project", session_dir);
    defer manager.deinit();

    var user = try userTextMessage(std.testing.allocator, "hello", 1);
    defer deinitMessage(std.testing.allocator, &user);
    _ = try manager.appendMessage(user);

    var assistant = try assistantTextMessage(std.testing.allocator, "world", model, 2);
    defer deinitMessage(std.testing.allocator, &assistant);
    _ = try manager.appendMessage(assistant);

    const session_file = try std.testing.allocator.dupe(u8, manager.getSessionFile().?);
    defer std.testing.allocator.free(session_file);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);

    var rebuilt = std.ArrayList(u8).empty;
    defer rebuilt.deinit(std.testing.allocator);

    var lines = std.mem.splitScalar(u8, written, '\n');
    const header_line = lines.next().?;
    const user_line = lines.next().?;
    const assistant_line = lines.next().?;

    try rebuilt.appendSlice(std.testing.allocator, header_line);
    try rebuilt.append(std.testing.allocator, '\n');
    try rebuilt.appendSlice(std.testing.allocator, user_line);
    try rebuilt.append(std.testing.allocator, '\n');
    try rebuilt.appendSlice(
        std.testing.allocator,
        "{\"type\":\"message\",\"id\":\"bad-object\",\"parentId\":null,\"timestamp\":\"2026-04-25T00:00:00.000Z\",\"message\":[]}",
    );
    try rebuilt.append(std.testing.allocator, '\n');
    try rebuilt.appendSlice(
        std.testing.allocator,
        "{\"type\":\"message\",\"id\":\"bad-array\",\"parentId\":\"bad-object\",\"timestamp\":\"2026-04-25T00:00:00.000Z\",\"message\":{\"role\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"oops\"},\"api\":\"faux\",\"provider\":\"faux\",\"model\":\"faux-session\",\"usage\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":0},\"stopReason\":\"stop\",\"timestamp\":2}}",
    );
    try rebuilt.append(std.testing.allocator, '\n');
    try rebuilt.appendSlice(std.testing.allocator, assistant_line);
    try rebuilt.append(std.testing.allocator, '\n');

    try common.writeFileAbsolute(std.testing.io, session_file, rebuilt.items, true);

    var warning_capture: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer warning_capture.deinit();

    var reopened = try SessionManager.openWithWarningWriter(
        std.testing.allocator,
        std.testing.io,
        session_file,
        null,
        &warning_capture.writer,
    );
    defer reopened.deinit();

    var context = try reopened.buildSessionContext(std.testing.allocator);
    defer context.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqualStrings("hello", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("world", context.messages[1].assistant.content[0].text.text);

    const warnings = warning_capture.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, warnings, "line 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "line 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "InvalidSessionFile") != null);
    try std.testing.expect(std.mem.indexOf(u8, warnings, "2 corrupted lines skipped") != null);
}

test "session manager supports branching and branch navigation" {
    var manager = try SessionManager.inMemory(std.testing.allocator, std.testing.io, "/tmp/project");
    defer manager.deinit();

    const model = ai.Model{
        .id = "faux-session",
        .name = "Faux Session",
        .api = "faux",
        .provider = "faux",
        .base_url = "",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    var first = try userTextMessage(std.testing.allocator, "first", 1);
    defer deinitMessage(std.testing.allocator, &first);
    const first_id = try manager.appendMessage(first);

    var second = try assistantTextMessage(std.testing.allocator, "second", model, 2);
    defer deinitMessage(std.testing.allocator, &second);
    const second_id = try manager.appendMessage(second);

    var third = try userTextMessage(std.testing.allocator, "third", 3);
    defer deinitMessage(std.testing.allocator, &third);
    _ = try manager.appendMessage(third);

    try manager.branch(first_id);

    var alternate = try userTextMessage(std.testing.allocator, "alternate", 4);
    defer deinitMessage(std.testing.allocator, &alternate);
    const alternate_id = try manager.appendMessage(alternate);

    var branch = try manager.getBranch(std.testing.allocator, null);
    defer std.testing.allocator.free(branch);

    try std.testing.expectEqual(@as(usize, 2), branch.len);
    try std.testing.expectEqualStrings(first_id, branch[0].id());
    try std.testing.expectEqualStrings(alternate_id, branch[1].id());

    var tree = try manager.getTree(std.testing.allocator);
    defer {
        for (tree) |*root| root.deinit(std.testing.allocator);
        std.testing.allocator.free(tree);
    }

    try std.testing.expectEqual(@as(usize, 1), tree.len);
    try std.testing.expectEqualStrings(first_id, tree[0].entry.id());
    try std.testing.expectEqual(@as(usize, 2), tree[0].children.len);
    try std.testing.expectEqualStrings(second_id, tree[0].children[0].entry.id());
    try std.testing.expectEqualStrings(alternate_id, tree[0].children[1].entry.id());

    try manager.branch(second_id);
    var resumed_branch = try manager.buildSessionContext(std.testing.allocator);
    defer resumed_branch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), resumed_branch.messages.len);
    try std.testing.expectEqualStrings("second", resumed_branch.messages[1].assistant.content[0].text.text);
}

test "session search query parser supports field prefixes and phrases" {
    var parsed = try parseSessionSearchQuery(
        std.testing.allocator,
        "name:\"Night Shift\" content:panic cwd:/tmp/project id:session-1",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), parsed.tokens.len);
    try std.testing.expectEqual(SessionSearchField.name, parsed.tokens[0].field);
    try std.testing.expectEqual(SessionSearchTokenKind.phrase, parsed.tokens[0].kind);
    try std.testing.expectEqualStrings("Night Shift", parsed.tokens[0].value);
    try std.testing.expectEqual(SessionSearchField.content, parsed.tokens[1].field);
    try std.testing.expectEqualStrings("panic", parsed.tokens[1].value);
    try std.testing.expectEqual(SessionSearchField.cwd, parsed.tokens[2].field);
    try std.testing.expectEqualStrings("/tmp/project", parsed.tokens[2].value);
    try std.testing.expectEqual(SessionSearchField.id, parsed.tokens[3].field);
    try std.testing.expectEqualStrings("session-1", parsed.tokens[3].value);
}

test "session search scans all session files and ranks name and content matches by relevance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root_relative = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "search-root",
    });
    defer std.testing.allocator.free(root_relative);
    const search_root = try makeAbsoluteTestPath(std.testing.allocator, root_relative);
    defer std.testing.allocator.free(search_root);

    const project_a_sessions = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        search_root,
        "project-a",
        ".pi",
        "sessions",
    });
    defer std.testing.allocator.free(project_a_sessions);
    const project_b_sessions = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        search_root,
        "project-b",
        ".pi",
        "sessions",
    });
    defer std.testing.allocator.free(project_b_sessions);

    const model = sessionSearchTestModel();

    var night_shift = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project-a", project_a_sessions);
    defer night_shift.deinit();
    _ = try night_shift.appendSessionInfo("Night Shift");

    var night_shift_user = try userTextMessage(std.testing.allocator, "investigate auth timeout", 1);
    defer deinitMessage(std.testing.allocator, &night_shift_user);
    _ = try night_shift.appendMessage(night_shift_user);

    var night_shift_assistant = try assistantTextMessage(std.testing.allocator, "auth retry fixed after inspecting logs", model, 2);
    defer deinitMessage(std.testing.allocator, &night_shift_assistant);
    _ = try night_shift.appendMessage(night_shift_assistant);

    const night_shift_path = try std.testing.allocator.dupe(u8, night_shift.getSessionFile().?);
    defer std.testing.allocator.free(night_shift_path);

    var parser_panic = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project-b", project_b_sessions);
    defer parser_panic.deinit();

    var parser_user = try userTextMessage(std.testing.allocator, "parser panic while compiling release build", 3);
    defer deinitMessage(std.testing.allocator, &parser_user);
    _ = try parser_panic.appendMessage(parser_user);

    var parser_assistant = try assistantTextMessage(std.testing.allocator, "panic came from stale generated parser output", model, 4);
    defer deinitMessage(std.testing.allocator, &parser_assistant);
    _ = try parser_panic.appendMessage(parser_assistant);

    const parser_path = try std.testing.allocator.dupe(u8, parser_panic.getSessionFile().?);
    defer std.testing.allocator.free(parser_path);

    var checklist = try SessionManager.create(std.testing.allocator, std.testing.io, "/tmp/project-b", project_b_sessions);
    defer checklist.deinit();

    var checklist_user = try userTextMessage(std.testing.allocator, "night shift release checklist", 5);
    defer deinitMessage(std.testing.allocator, &checklist_user);
    _ = try checklist.appendMessage(checklist_user);

    var checklist_assistant = try assistantTextMessage(std.testing.allocator, "review migrations and smoke tests", model, 6);
    defer deinitMessage(std.testing.allocator, &checklist_assistant);
    _ = try checklist.appendMessage(checklist_assistant);

    const checklist_path = try std.testing.allocator.dupe(u8, checklist.getSessionFile().?);
    defer std.testing.allocator.free(checklist_path);

    const all_sessions = try listAllSessionsUnder(std.testing.allocator, std.testing.io, search_root);
    defer {
        for (@constCast(all_sessions)) |*session| session.deinit(std.testing.allocator);
        std.testing.allocator.free(@constCast(all_sessions));
    }

    try std.testing.expectEqual(@as(usize, 3), all_sessions.len);

    var name_results = try searchSessionsUnder(std.testing.allocator, std.testing.io, search_root, "name:\"Night Shift\"", .{});
    defer name_results.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), name_results.matches.len);
    const name_match = name_results.sessions[name_results.matches[0].session_index];
    try std.testing.expectEqualStrings("Night Shift", name_match.name.?);
    try std.testing.expectEqualStrings(night_shift_path, name_match.path);

    var content_results = try searchSessionsUnder(std.testing.allocator, std.testing.io, search_root, "content:\"parser panic\"", .{});
    defer content_results.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), content_results.matches.len);
    const content_match = content_results.sessions[content_results.matches[0].session_index];
    try std.testing.expectEqualStrings(parser_path, content_match.path);
    try std.testing.expect(std.mem.indexOf(u8, content_match.all_messages_text, "parser panic") != null);

    var relevance_results = try searchSessionsUnder(std.testing.allocator, std.testing.io, search_root, "night shift", .{});
    defer relevance_results.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), relevance_results.matches.len);
    const first_relevance = relevance_results.sessions[relevance_results.matches[0].session_index];
    const second_relevance = relevance_results.sessions[relevance_results.matches[1].session_index];
    try std.testing.expectEqualStrings(night_shift_path, first_relevance.path);
    try std.testing.expectEqualStrings(checklist_path, second_relevance.path);

    const named_only = try filterAndSortSessions(
        std.testing.allocator,
        all_sessions,
        "",
        .{ .sort_mode = .recent, .name_filter = .named },
    );
    defer std.testing.allocator.free(named_only);

    try std.testing.expectEqual(@as(usize, 1), named_only.len);
    try std.testing.expectEqualStrings(night_shift_path, all_sessions[named_only[0].session_index].path);
}
