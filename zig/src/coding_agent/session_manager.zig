const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const common = @import("tools/common.zig");

pub const CURRENT_SESSION_VERSION: u32 = 3;

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
        allocator.free(self.messages);
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

pub const SessionEntry = union(enum) {
    message: SessionMessageEntry,
    thinking_level_change: ThinkingLevelChangeEntry,
    model_change: ModelChangeEntry,
    compaction: CompactionEntry,

    pub fn id(self: *const SessionEntry) []const u8 {
        return switch (self.*) {
            .message => |entry| entry.id,
            .thinking_level_change => |entry| entry.id,
            .model_change => |entry| entry.id,
            .compaction => |entry| entry.id,
        };
    }

    pub fn parentId(self: *const SessionEntry) ?[]const u8 {
        return switch (self.*) {
            .message => |entry| entry.parent_id,
            .thinking_level_change => |entry| entry.parent_id,
            .model_change => |entry| entry.parent_id,
            .compaction => |entry| entry.parent_id,
        };
    }

    pub fn timestamp(self: *const SessionEntry) []const u8 {
        return switch (self.*) {
            .message => |entry| entry.timestamp,
            .thinking_level_change => |entry| entry.timestamp,
            .model_change => |entry| entry.timestamp,
            .compaction => |entry| entry.timestamp,
        };
    }
};

pub const SessionTreeNode = struct {
    entry: *const SessionEntry,
    children: []SessionTreeNode,

    pub fn deinit(self: *SessionTreeNode, allocator: std.mem.Allocator) void {
        for (self.children) |*child| child.deinit(allocator);
        allocator.free(self.children);
        self.* = .{
            .entry = self.entry,
            .children = &.{},
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

    pub fn branch(self: *SessionManager, entry_id: []const u8) !void {
        if (self.getEntry(entry_id) == null) return error.EntryNotFound;
        self.leaf_id = entry_id;
    }

    pub fn resetLeaf(self: *SessionManager) void {
        self.leaf_id = null;
    }

    pub fn buildSessionContext(self: *const SessionManager, allocator: std.mem.Allocator) !SessionContext {
        if (self.leaf_id == null) {
            return .{ .messages = try allocator.alloc(agent.AgentMessage, 0) };
        }

        const branch_entries = try self.getBranch(allocator, null);
        defer allocator.free(branch_entries);

        var messages = std.ArrayList(agent.AgentMessage).empty;
        errdefer messages.deinit(allocator);

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
            }
        }

        if (latest_compaction) |compaction_entry| {
            try appendVisibleMessage(&messages, compaction_entry.message, allocator);

            const compaction_index = findEntryIndex(branch_entries, compaction_entry.id) orelse return error.InvalidSessionTree;
            var found_first_kept = false;
            var index: usize = 0;
            while (index < compaction_index) : (index += 1) {
                const entry = branch_entries[index];
                if (std.mem.eql(u8, entry.id(), compaction_entry.first_kept_entry_id)) {
                    found_first_kept = true;
                }
                if (found_first_kept) {
                    switch (entry.*) {
                        .message => |message_entry| {
                            updateModelFromMessage(&model, message_entry.message);
                            try appendVisibleMessage(&messages, message_entry.message, allocator);
                        },
                        .compaction => {},
                        else => {},
                    }
                }
            }

            index = compaction_index + 1;
            while (index < branch_entries.len) : (index += 1) {
                switch (branch_entries[index].*) {
                    .message => |message_entry| {
                        updateModelFromMessage(&model, message_entry.message);
                        try appendVisibleMessage(&messages, message_entry.message, allocator);
                    },
                    .compaction => {},
                    else => {},
                }
            }
        } else {
            for (branch_entries) |entry| {
                if (entry.* != .message) continue;
                const message_entry = entry.message;
                updateModelFromMessage(&model, message_entry.message);
                try appendVisibleMessage(&messages, message_entry.message, allocator);
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
    }
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

fn appendVisibleMessage(
    messages: *std.ArrayList(agent.AgentMessage),
    message: agent.AgentMessage,
    allocator: std.mem.Allocator,
) !void {
    switch (message) {
        .assistant => |assistant_message| {
            if (assistant_message.stop_reason == .error_reason) return;
        },
        else => {},
    }
    try messages.append(allocator, message);
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

    const object = requireObject(parsed.value);
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

    const object = requireObject(parsed.value);
    const entry_type = try getRequiredString(object, "type");

    if (std.mem.eql(u8, entry_type, "message")) {
        return .{ .message = .{
            .id = try allocator.dupe(u8, try getRequiredString(object, "id")),
            .parent_id = if (getOptionalString(object, "parentId")) |parent_id| try allocator.dupe(u8, parent_id) else null,
            .timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp")),
            .message = try parseMessageValue(allocator, object.get("message") orelse return error.InvalidSessionEntry),
        } };
    }

    if (std.mem.eql(u8, entry_type, "thinking_level_change")) {
        return .{ .thinking_level_change = .{
            .id = try allocator.dupe(u8, try getRequiredString(object, "id")),
            .parent_id = if (getOptionalString(object, "parentId")) |parent_id| try allocator.dupe(u8, parent_id) else null,
            .timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp")),
            .thinking_level = try parseThinkingLevel(try getRequiredString(object, "thinkingLevel")),
        } };
    }

    if (std.mem.eql(u8, entry_type, "model_change")) {
        return .{ .model_change = .{
            .id = try allocator.dupe(u8, try getRequiredString(object, "id")),
            .parent_id = if (getOptionalString(object, "parentId")) |parent_id| try allocator.dupe(u8, parent_id) else null,
            .timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp")),
            .provider = try allocator.dupe(u8, try getRequiredString(object, "provider")),
            .model_id = try allocator.dupe(u8, try getRequiredString(object, "modelId")),
        } };
    }

    if (std.mem.eql(u8, entry_type, "compaction")) {
        const summary = try getRequiredString(object, "summary");
        return .{ .compaction = .{
            .id = try allocator.dupe(u8, try getRequiredString(object, "id")),
            .parent_id = if (getOptionalString(object, "parentId")) |parent_id| try allocator.dupe(u8, parent_id) else null,
            .timestamp = try allocator.dupe(u8, try getRequiredString(object, "timestamp")),
            .first_kept_entry_id = try allocator.dupe(u8, try getRequiredString(object, "firstKeptEntryId")),
            .tokens_before = @intCast(try getRequiredInteger(object, "tokensBefore")),
            .message = try createCompactionSummaryMessage(allocator, summary, 0),
        } };
    }

    return error.UnsupportedSessionEntryType;
}

fn parseMessageValue(allocator: std.mem.Allocator, value: std.json.Value) !agent.AgentMessage {
    const object = requireObject(value);
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
            .is_error = getOptionalBool(object, "isError") orelse false,
            .timestamp = try getRequiredI64(object, "timestamp"),
        } };
    }

    return error.UnsupportedSessionMessageRole;
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
    const array = requireArray(value);

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
        const object = requireObject(item);
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
    const array = requireArray(value);
    const blocks = try allocator.alloc(ai.ContentBlock, array.items.len);
    errdefer allocator.free(blocks);

    for (array.items, 0..) |item, index| {
        blocks[index] = try parseContentBlockObject(allocator, requireObject(item));
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
    const object = requireObject(value);
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
    const object = requireObject(value);
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

fn requireObject(value: std.json.Value) std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => @panic("expected json object"),
    };
}

fn requireArray(value: std.json.Value) std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => @panic("expected json array"),
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

fn countJsonLines(bytes: []const u8) usize {
    var count: usize = 0;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
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

    const session_file = try std.testing.allocator.dupe(u8, manager.getSessionFile().?);
    defer std.testing.allocator.free(session_file);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, session_file, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);

    try std.testing.expectEqual(@as(usize, 3), countJsonLines(written));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"role\":\"user\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, written, 1, "\"role\":\"assistant\""));

    var reopened = try SessionManager.open(std.testing.allocator, std.testing.io, session_file, null);
    defer reopened.deinit();

    var context = try reopened.buildSessionContext(std.testing.allocator);
    defer context.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqualStrings("hello", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("world", context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("faux", context.model.?.provider);
    try std.testing.expectEqualStrings("faux-session", context.model.?.model_id);
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
