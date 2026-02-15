const std = @import("std");
const json_util = @import("json_util.zig");
const st = @import("session_types.zig");

var idBaseInstant: ?std.time.Instant = null;

fn compatIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn compatCwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

pub const SessionHeader = st.SessionHeader;
pub const MessageEntry = st.MessageEntry;
pub const ToolCallEntry = st.ToolCallEntry;
pub const ToolResultEntry = st.ToolResultEntry;
pub const ThinkingLevelChangeEntry = st.ThinkingLevelChangeEntry;
pub const ModelChangeEntry = st.ModelChangeEntry;
pub const CompactionEntry = st.CompactionEntry;
pub const BranchSummaryEntry = st.BranchSummaryEntry;
pub const CustomEntry = st.CustomEntry;
pub const CustomMessageEntry = st.CustomMessageEntry;
pub const SessionInfoEntry = st.SessionInfoEntry;
pub const LeafEntry = st.LeafEntry;
pub const LabelEntry = st.LabelEntry;
pub const TurnStartEntry = st.TurnStartEntry;
pub const TurnEndEntry = st.TurnEndEntry;
pub const SummaryEntry = st.SummaryEntry;
pub const Entry = st.Entry;

pub const SessionManager = struct {
    arena: std.mem.Allocator,
    session_path: []const u8,
    cwd: []const u8,
    seq: u64 = 0,

    pub fn init(arena: std.mem.Allocator, session_path: []const u8, cwd: []const u8) SessionManager {
        return .{ .arena = arena, .session_path = session_path, .cwd = cwd };
    }

    fn nowIso(arena: std.mem.Allocator) ![]const u8 {
        const now = try std.time.Instant.now();
        const base = if (idBaseInstant) |b| b else blk: {
            idBaseInstant = now;
            break :blk now;
        };
        const ms = now.since(base) / std.time.ns_per_ms;
        return try std.fmt.allocPrint(arena, "{d}", .{ms});
    }

    fn newId(self: *SessionManager) ![]const u8 {
        self.seq += 1;
        const id = try nowIso(self.arena);
        return try std.fmt.allocPrint(self.arena, "e_{s}_{d}", .{ id, self.seq });
    }

    pub fn ensure(self: *SessionManager) !void {
        const io = compatIo();
        const cwd = compatCwd();
        // if file exists and non-empty, assume ok
        const stat_res = cwd.statFile(io, self.session_path, .{});
        if (stat_res) |_| {
            // If empty, rewrite header
            var f = try cwd.openFile(io, self.session_path, .{ .mode = .read_only });
            defer f.close(io);
            const stat = try f.length(io);
            if (stat > 0) return;
        } else |_| {
            // create parent dir
            if (std.fs.path.dirname(self.session_path)) |dir| {
                cwd.createDirPath(io, dir) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };
            }
            _ = try cwd.createFile(io, self.session_path, .{ .truncate = true });
        }

        // write header line
        const sid = try std.fmt.allocPrint(self.arena, "s_{s}", .{try nowIso(self.arena)});
        const header = SessionHeader{
            .id = sid,
            .version = 3,
            .timestamp = try nowIso(self.arena),
            .cwd = self.cwd,
            .parentSession = null,
        };
        try json_util.writeJsonLine(self.session_path, header);
    }

    fn currentLeafId(self: *SessionManager) !?[]const u8 {
        const entries = try self.loadEntries();
        var leaf: ?[]const u8 = null;
        for (entries) |e| {
            switch (e) {
                .leaf => |l| leaf = l.targetId,
                else => {},
            }
        }
        if (leaf) |id| return id;

        // If no explicit leaf, use last node entry id if any.
        var last: ?[]const u8 = null;
        for (entries) |e| {
            if (st.idOf(e)) |id| last = id;
        }
        return last;
    }

    fn setLeaf(self: *SessionManager, target: ?[]const u8) !void {
        const entry = LeafEntry{ .timestamp = try nowIso(self.arena), .targetId = target };
        try json_util.appendJsonLine(self.session_path, entry);
    }

    pub fn branchTo(self: *SessionManager, targetId: ?[]const u8) !void {
        try self.setLeaf(targetId);
    }

    pub fn setLabel(self: *SessionManager, targetId: []const u8, label: ?[]const u8) ![]const u8 {
        const id = try self.newId();
        const entry = LabelEntry{
            .id = id,
            .timestamp = try nowIso(self.arena),
            .targetId = targetId,
            .label = label,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        return id;
    }

    pub fn appendSummary(
        self: *SessionManager,
        content: []const u8,
        reason: ?[]const u8,
        format: []const u8,
        totalChars: ?usize,
        totalTokensEst: ?usize,
        keepLast: ?usize,
        keepLastGroups: ?usize,
        thresholdChars: ?usize,
        thresholdTokensEst: ?usize,
    ) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = SummaryEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .reason = reason,
            .format = format,
            .content = content,
            .totalChars = totalChars,
            .totalTokensEst = totalTokensEst,
            .keepLast = keepLast,
            .keepLastGroups = keepLastGroups,
            .thresholdChars = thresholdChars,
            .thresholdTokensEst = thresholdTokensEst,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendMessage(self: *SessionManager, role: []const u8, content: []const u8) ![]const u8 {
        return try self.appendMessageWithMetadata(role, content, null, null, null, null, null);
    }

    pub fn appendMessageWithMetadata(
        self: *SessionManager,
        role: []const u8,
        content: []const u8,
        tokens_est: ?usize,
        usage_total_tokens: ?usize,
        details_json: ?[]const u8,
        model: ?[]const u8,
        thinking: ?[]const u8,
    ) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = MessageEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .role = role,
            .content = content,
            .tokensEst = tokens_est,
            .usageTotalTokens = usage_total_tokens,
            .detailsJson = details_json,
            .model = model,
            .thinking = thinking,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendMessageWithTokensEst(self: *SessionManager, role: []const u8, content: []const u8, tokens_est: ?usize) ![]const u8 {
        return try self.appendMessageWithMetadata(role, content, tokens_est, null, null, null, null);
    }

    pub fn appendToolCall(self: *SessionManager, tool: []const u8, arg: []const u8) ![]const u8 {
        return try self.appendToolCallWithTokensEst(tool, arg, null);
    }

    pub fn appendToolCallWithTokensEst(self: *SessionManager, tool: []const u8, arg: []const u8, tokens_est: ?usize) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = ToolCallEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .tool = tool,
            .arg = arg,
            .tokensEst = tokens_est,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendToolResult(self: *SessionManager, tool: []const u8, ok: bool, content: []const u8) ![]const u8 {
        return try self.appendToolResultWithTokensEst(tool, ok, content, null);
    }

    pub fn appendToolResultWithTokensEst(self: *SessionManager, tool: []const u8, ok: bool, content: []const u8, tokens_est: ?usize) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = ToolResultEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .tool = tool,
            .ok = ok,
            .content = content,
            .tokensEst = tokens_est,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendThinkingLevelChange(self: *SessionManager, thinkingLevel: []const u8) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = ThinkingLevelChangeEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .thinkingLevel = thinkingLevel,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendModelChange(self: *SessionManager, provider: []const u8, modelId: []const u8) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = ModelChangeEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .provider = provider,
            .modelId = modelId,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendCompaction(
        self: *SessionManager,
        summary: []const u8,
        firstKeptEntryId: []const u8,
        tokensBefore: usize,
        details: ?[]const u8,
        fromHook: bool,
    ) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = CompactionEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .summary = summary,
            .firstKeptEntryId = firstKeptEntryId,
            .tokensBefore = tokensBefore,
            .details = details,
            .fromHook = fromHook,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendBranchSummary(self: *SessionManager, fromId: []const u8, summary: []const u8, details: ?[]const u8, fromHook: bool) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = BranchSummaryEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .fromId = fromId,
            .summary = summary,
            .details = details,
            .fromHook = fromHook,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendCustom(self: *SessionManager, customType: []const u8, data: ?[]const u8) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = CustomEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .customType = customType,
            .data = data,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendCustomMessage(self: *SessionManager, customType: []const u8, content: []const u8, display: bool, details: ?[]const u8) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = CustomMessageEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .customType = customType,
            .content = content,
            .display = display,
            .details = details,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendSessionInfo(self: *SessionManager, name: []const u8) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = SessionInfoEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .name = name,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendTurnStart(self: *SessionManager, turn: u64, userMessageId: ?[]const u8, turnGroupId: ?[]const u8, phase: ?[]const u8) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = TurnStartEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .turn = turn,
            .userMessageId = userMessageId,
            .turnGroupId = turnGroupId,
            .phase = phase,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendTurnEnd(self: *SessionManager, turn: u64, userMessageId: ?[]const u8, turnGroupId: ?[]const u8, phase: ?[]const u8) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = TurnEndEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .turn = turn,
            .userMessageId = userMessageId,
            .turnGroupId = turnGroupId,
            .phase = phase,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn loadEntries(self: *SessionManager) ![]Entry {
        const io = compatIo();
        const cwd = compatCwd();
        var f = try cwd.openFile(io, self.session_path, .{ .mode = .read_only });
        defer f.close(io);
        const file_size = try f.length(io);
        const max_size: usize = 64 * 1024 * 1024;
        if (file_size > max_size) return error.OutOfMemory;
        const bytes = try self.arena.alloc(u8, @as(usize, file_size));
        const size = try f.readPositionalAll(io, bytes, 0);
        const bytes_read = bytes[0..size];

        var out = try std.ArrayList(Entry).initCapacity(self.arena, 0);
        defer out.deinit(self.arena);

        const LegacyCompactionPatch = struct {
            out_index: usize,
            legacy_index: usize,
        };

        var legacy_index_to_id = try std.ArrayList(?[]const u8).initCapacity(self.arena, 0);
        defer legacy_index_to_id.deinit(self.arena);
        var legacy_prev_id: ?[]const u8 = null;
        var pending_compaction = try std.ArrayList(LegacyCompactionPatch).initCapacity(self.arena, 0);
        defer pending_compaction.deinit(self.arena);

        var file_version: u32 = 1;

        var it = std.mem.splitScalar(u8, bytes_read, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            var parsed = try json_util.parseJson(self.arena, line);
            defer parsed.deinit();
            const obj = switch (parsed.value) {
                .object => |o| o,
                else => continue,
            };
            const typ = switch (obj.get("type") orelse continue) {
                .string => |s| s,
                else => continue,
            };

            const dup = struct {
                fn s(a: std.mem.Allocator, x: []const u8) ![]const u8 {
                    return try a.dupe(u8, x);
                }
                fn os(a: std.mem.Allocator, x: ?[]const u8) !?[]const u8 {
                    if (x) |v| return try a.dupe(u8, v);
                    return null;
                }
            };

            const legacy_line_index: ?usize = if (file_version < 2) blk: {
                const idx = legacy_index_to_id.items.len;
                try legacy_index_to_id.append(self.arena, null);
                break :blk idx;
            } else null;

            if (std.mem.eql(u8, typ, "session")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const ts0 = if (obj.get("timestamp")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const cwd0 = if (obj.get("cwd")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const version0: u32 = if (obj.get("version")) |v| switch (v) {
                    .integer => |x| @as(u32, @intCast(x)),
                    else => 1,
                } else 1;
                const parent_session0 = if (obj.get("parentSession")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;

                file_version = version0;

                const id = try dup.os(self.arena, id0) orelse try self.newId();
                const ts = try dup.os(self.arena, ts0) orelse try nowIso(self.arena);
                const file_cwd = try dup.os(self.arena, cwd0) orelse ".";
                const parent_session = try dup.os(self.arena, parent_session0);
                if (file_version < 2) {
                    if (legacy_line_index) |li| legacy_index_to_id.items[li] = id;
                    legacy_prev_id = id;
                }
                try out.append(self.arena, .{ .session = .{ .id = id, .version = version0, .timestamp = ts, .cwd = file_cwd, .parentSession = parent_session } });
                continue;
            }

            if (std.mem.eql(u8, typ, "message")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const role0 = switch (obj.get("role") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const id = try dup.s(self.arena, if (id0) |s| s else try self.newId());
                const pid = if (file_version < 2) (if (pid0) |p| try dup.s(self.arena, p) else legacy_prev_id) else try dup.os(self.arena, pid0);
                const content0 = switch (obj.get("content") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const tokens_est0 = if (obj.get("tokensEst")) |v| switch (v) {
                    .integer => |x| @as(?usize, @intCast(x)),
                    else => null,
                } else null;
                const usage_total_tokens0 = if (obj.get("usageTotalTokens")) |v| switch (v) {
                    .integer => |x| @as(?usize, @intCast(x)),
                    else => null,
                } else null;
                const details_json0 = if (obj.get("detailsJson")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const model0 = if (obj.get("model")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const thinking0 = if (obj.get("thinking")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                if (file_version < 2) {
                    if (legacy_line_index) |li| legacy_index_to_id.items[li] = id;
                    legacy_prev_id = id;
                }
                const ts = try dup.s(self.arena, ts0);
                const role = if (file_version < 3 and std.mem.eql(u8, role0, "hookMessage"))
                    "custom"
                else
                    role0;
                const role_dup = try dup.s(self.arena, role);
                const content = try dup.s(self.arena, content0);
                const details_json = try dup.os(self.arena, details_json0);
                const model = try dup.os(self.arena, model0);
                const thinking = try dup.os(self.arena, thinking0);
                try out.append(self.arena, .{ .message = .{ .id = id, .parentId = pid, .timestamp = ts, .role = role_dup, .content = content, .tokensEst = tokens_est0, .usageTotalTokens = usage_total_tokens0, .detailsJson = details_json, .model = model, .thinking = thinking } });
                continue;
            }

            if (std.mem.eql(u8, typ, "tool_call")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const tool0 = switch (obj.get("tool") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const arg0 = switch (obj.get("arg") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const tokens_est0 = if (obj.get("tokensEst")) |v| switch (v) {
                    .integer => |x| @as(?usize, @intCast(x)),
                    else => null,
                } else null;
                const id = try dup.s(self.arena, if (id0) |s| s else try self.newId());
                const pid = if (file_version < 2) (if (pid0) |p| try dup.s(self.arena, p) else legacy_prev_id) else try dup.os(self.arena, pid0);
                if (file_version < 2) {
                    if (legacy_line_index) |li| legacy_index_to_id.items[li] = id;
                    legacy_prev_id = id;
                }
                const ts = try dup.s(self.arena, ts0);
                const tool = try dup.s(self.arena, tool0);
                const arg = try dup.s(self.arena, arg0);
                try out.append(self.arena, .{ .tool_call = .{ .id = id, .parentId = pid, .timestamp = ts, .tool = tool, .arg = arg, .tokensEst = tokens_est0 } });
                continue;
            }

            if (std.mem.eql(u8, typ, "tool_result")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const tool0 = switch (obj.get("tool") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const ok = switch (obj.get("ok") orelse continue) {
                    .bool => |b| b,
                    else => continue,
                };
                const content0 = switch (obj.get("content") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const tokens_est0 = if (obj.get("tokensEst")) |v| switch (v) {
                    .integer => |x| @as(?usize, @intCast(x)),
                    else => null,
                } else null;
                const id = try dup.s(self.arena, if (id0) |s| s else try self.newId());
                const pid = if (file_version < 2) (if (pid0) |p| try dup.s(self.arena, p) else legacy_prev_id) else try dup.os(self.arena, pid0);
                if (file_version < 2) {
                    if (legacy_line_index) |li| legacy_index_to_id.items[li] = id;
                    legacy_prev_id = id;
                }
                const ts = try dup.s(self.arena, ts0);
                const tool = try dup.s(self.arena, tool0);
                const content = try dup.s(self.arena, content0);
                try out.append(self.arena, .{ .tool_result = .{ .id = id, .parentId = pid, .timestamp = ts, .tool = tool, .ok = ok, .content = content, .tokensEst = tokens_est0 } });
                continue;
            }

            if (std.mem.eql(u8, typ, "turn_start")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const turn = switch (obj.get("turn") orelse continue) {
                    .integer => |x| @as(u64, @intCast(x)),
                    else => continue,
                };
                const um0 = if (obj.get("userMessageId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const tg0 = if (obj.get("turnGroupId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ph0 = if (obj.get("phase")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const id = try dup.s(self.arena, if (id0) |s| s else try self.newId());
                const pid = if (file_version < 2) (if (pid0) |p| try dup.s(self.arena, p) else legacy_prev_id) else try dup.os(self.arena, pid0);
                if (file_version < 2) {
                    if (legacy_line_index) |li| legacy_index_to_id.items[li] = id;
                    legacy_prev_id = id;
                }
                const ts = try dup.s(self.arena, ts0);
                const um = try dup.os(self.arena, um0);
                const tg = try dup.os(self.arena, tg0);
                const ph = try dup.os(self.arena, ph0);
                try out.append(self.arena, .{ .turn_start = .{ .id = id, .parentId = pid, .timestamp = ts, .turn = turn, .userMessageId = um, .turnGroupId = tg, .phase = ph } });
                continue;
            }

            if (std.mem.eql(u8, typ, "turn_end")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const turn = switch (obj.get("turn") orelse continue) {
                    .integer => |x| @as(u64, @intCast(x)),
                    else => continue,
                };
                const um0 = if (obj.get("userMessageId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const tg0 = if (obj.get("turnGroupId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ph0 = if (obj.get("phase")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const id = try dup.s(self.arena, if (id0) |s| s else try self.newId());
                const pid = if (file_version < 2) (if (pid0) |p| try dup.s(self.arena, p) else legacy_prev_id) else try dup.os(self.arena, pid0);
                if (file_version < 2) {
                    if (legacy_line_index) |li| legacy_index_to_id.items[li] = id;
                    legacy_prev_id = id;
                }
                const ts = try dup.s(self.arena, ts0);
                const um = try dup.os(self.arena, um0);
                const tg = try dup.os(self.arena, tg0);
                const ph = try dup.os(self.arena, ph0);
                try out.append(self.arena, .{ .turn_end = .{ .id = id, .parentId = pid, .timestamp = ts, .turn = turn, .userMessageId = um, .turnGroupId = tg, .phase = ph } });
                continue;
            }

            if (std.mem.eql(u8, typ, "thinking_level_change")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const thinking0 = switch (obj.get("thinkingLevel") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const id = try dup.s(self.arena, if (id0) |s| s else try self.newId());
                const pid = if (file_version < 2) (if (pid0) |p| try dup.s(self.arena, p) else legacy_prev_id) else try dup.os(self.arena, pid0);
                if (file_version < 2) {
                    if (legacy_line_index) |li| legacy_index_to_id.items[li] = id;
                    legacy_prev_id = id;
                }
                const ts = try dup.s(self.arena, ts0);
                const thinking = try dup.s(self.arena, thinking0);
                try out.append(self.arena, .{ .thinking_level_change = .{ .id = id, .parentId = pid, .timestamp = ts, .thinkingLevel = thinking } });
                continue;
            }

            if (std.mem.eql(u8, typ, "model_change")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const provider0 = switch (obj.get("provider") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const model_id0 = switch (obj.get("modelId") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const id = try dup.s(self.arena, if (id0) |s| s else try self.newId());
                const pid = if (file_version < 2) (if (pid0) |p| try dup.s(self.arena, p) else legacy_prev_id) else try dup.os(self.arena, pid0);
                if (file_version < 2) {
                    if (legacy_line_index) |li| legacy_index_to_id.items[li] = id;
                    legacy_prev_id = id;
                }
                const ts = try dup.s(self.arena, ts0);
                const provider = try dup.s(self.arena, provider0);
                const model_id = try dup.s(self.arena, model_id0);
                try out.append(self.arena, .{ .model_change = .{ .id = id, .parentId = pid, .timestamp = ts, .provider = provider, .modelId = model_id } });
                continue;
            }

            if (std.mem.eql(u8, typ, "compaction")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const summary0 = switch (obj.get("summary") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const first_kept0 = if (obj.get("firstKeptEntryId")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const first_kept_index0 = if (obj.get("firstKeptEntryIndex")) |v| switch (v) {
                    .integer => |x| x,
                    else => null,
                } else null;
                const tokens_before0 = switch (obj.get("tokensBefore") orelse continue) {
                    .integer => |x| x,
                    else => continue,
                };
                const details0 = if (obj.get("details")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const from_hook0 = if (obj.get("fromHook")) |v| switch (v) {
                    .bool => |b| b,
                    else => false,
                } else false;
                const id = try dup.s(self.arena, if (id0) |s| s else try self.newId());
                const pid = if (file_version < 2) (if (pid0) |p| try dup.s(self.arena, p) else legacy_prev_id) else try dup.os(self.arena, pid0);
                if (file_version < 2) {
                    if (legacy_line_index) |li| legacy_index_to_id.items[li] = id;
                    legacy_prev_id = id;
                }
                const ts = try dup.s(self.arena, ts0);
                const summary = try dup.s(self.arena, summary0);
                const firstKept = try dup.s(self.arena, first_kept0 orelse "");
                const out_index = out.items.len;
                const tokens_before = @as(usize, @intCast(tokens_before0));
                const details = try dup.os(self.arena, details0);
                try out.append(self.arena, .{ .compaction = .{ .id = id, .parentId = pid, .timestamp = ts, .summary = summary, .firstKeptEntryId = firstKept, .tokensBefore = tokens_before, .details = details, .fromHook = from_hook0 } });
                if (first_kept0 == null) {
                    if (first_kept_index0) |idx| {
                        if (idx >= 0) {
                            const legacy_index = @as(usize, @intCast(idx));
                            try pending_compaction.append(self.arena, .{ .out_index = out_index, .legacy_index = legacy_index });
                        }
                    }
                }
                continue;
            }

            if (std.mem.eql(u8, typ, "branch_summary")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const from_id0 = switch (obj.get("fromId") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const summary0 = switch (obj.get("summary") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const details0 = if (obj.get("details")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const from_hook0 = if (obj.get("fromHook")) |v| switch (v) {
                    .bool => |b| b,
                    else => false,
                } else false;
                const id = try dup.s(self.arena, if (id0) |s| s else try self.newId());
                const pid = if (file_version < 2) (if (pid0) |p| try dup.s(self.arena, p) else legacy_prev_id) else try dup.os(self.arena, pid0);
                if (file_version < 2) {
                    if (legacy_line_index) |li| legacy_index_to_id.items[li] = id;
                    legacy_prev_id = id;
                }
                const ts = try dup.s(self.arena, ts0);
                const from_id = try dup.s(self.arena, from_id0);
                const summary = try dup.s(self.arena, summary0);
                const details = try dup.os(self.arena, details0);
                try out.append(self.arena, .{ .branch_summary = .{ .id = id, .parentId = pid, .timestamp = ts, .fromId = from_id, .summary = summary, .details = details, .fromHook = from_hook0 } });
                continue;
            }

            if (std.mem.eql(u8, typ, "custom")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const custom_type0 = switch (obj.get("customType") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const data0 = if (obj.get("data")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const id = try dup.s(self.arena, if (id0) |s| s else try self.newId());
                const pid = if (file_version < 2) (if (pid0) |p| try dup.s(self.arena, p) else legacy_prev_id) else try dup.os(self.arena, pid0);
                if (file_version < 2) {
                    if (legacy_line_index) |li| legacy_index_to_id.items[li] = id;
                    legacy_prev_id = id;
                }
                const ts = try dup.s(self.arena, ts0);
                const custom_type = try dup.s(self.arena, custom_type0);
                const data = try dup.os(self.arena, data0);
                try out.append(self.arena, .{ .custom = .{ .id = id, .parentId = pid, .timestamp = ts, .customType = custom_type, .data = data } });
                continue;
            }

            if (std.mem.eql(u8, typ, "custom_message")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const custom_type0 = switch (obj.get("customType") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const content0 = switch (obj.get("content") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const display0 = if (obj.get("display")) |v| switch (v) {
                    .bool => |b| b,
                    else => true,
                } else true;
                const details0 = if (obj.get("details")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const id = try dup.s(self.arena, if (id0) |s| s else try self.newId());
                const pid = if (file_version < 2) (if (pid0) |p| try dup.s(self.arena, p) else legacy_prev_id) else try dup.os(self.arena, pid0);
                if (file_version < 2) {
                    if (legacy_line_index) |li| legacy_index_to_id.items[li] = id;
                    legacy_prev_id = id;
                }
                const ts = try dup.s(self.arena, ts0);
                const custom_type = try dup.s(self.arena, custom_type0);
                const content = try dup.s(self.arena, content0);
                const details = try dup.os(self.arena, details0);
                try out.append(self.arena, .{ .custom_message = .{ .id = id, .parentId = pid, .timestamp = ts, .customType = custom_type, .content = content, .display = display0, .details = details } });
                continue;
            }

            if (std.mem.eql(u8, typ, "session_info")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const name0 = if (obj.get("name")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const id = try dup.s(self.arena, if (id0) |s| s else try self.newId());
                const pid = if (file_version < 2) (if (pid0) |p| try dup.s(self.arena, p) else legacy_prev_id) else try dup.os(self.arena, pid0);
                if (file_version < 2) {
                    if (legacy_line_index) |li| legacy_index_to_id.items[li] = id;
                    legacy_prev_id = id;
                }
                const ts = try dup.s(self.arena, ts0);
                const name = try dup.os(self.arena, name0);
                try out.append(self.arena, .{ .session_info = .{ .id = id, .parentId = pid, .timestamp = ts, .name = name } });
                continue;
            }

            if (std.mem.eql(u8, typ, "leaf")) {
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const tid0 = if (obj.get("targetId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts = try dup.s(self.arena, ts0);
                const tid = try dup.os(self.arena, tid0);
                try out.append(self.arena, .{ .leaf = .{ .timestamp = ts, .targetId = tid } });
                continue;
            }

            if (std.mem.eql(u8, typ, "label")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const target0 = switch (obj.get("targetId") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const label0 = if (obj.get("label")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const id = try dup.s(self.arena, if (id0) |s| s else try self.newId());
                const ts = try dup.s(self.arena, ts0);
                const targetId = try dup.s(self.arena, target0);
                const label = try dup.os(self.arena, label0);
                try out.append(self.arena, .{ .label = .{ .id = id, .timestamp = ts, .targetId = targetId, .label = label } });
                continue;
            }

            if (std.mem.eql(u8, typ, "summary")) {
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const reason0 = if (obj.get("reason")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const format0 = if (obj.get("format")) |v| switch (v) {
                    .string => |s| s,
                    else => "text",
                } else "text";
                const content0 = switch (obj.get("content") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };

                const totalChars0 = if (obj.get("totalChars")) |v| switch (v) {
                    .integer => |x| @as(?usize, @intCast(x)),
                    else => null,
                } else null;
                const totalTokensEst0 = if (obj.get("totalTokensEst")) |v| switch (v) {
                    .integer => |x| @as(?usize, @intCast(x)),
                    else => null,
                } else null;
                const keepLast0 = if (obj.get("keepLast")) |v| switch (v) {
                    .integer => |x| @as(?usize, @intCast(x)),
                    else => null,
                } else null;
                const keepLastGroups0 = if (obj.get("keepLastGroups")) |v| switch (v) {
                    .integer => |x| @as(?usize, @intCast(x)),
                    else => null,
                } else null;
                const thresholdChars0 = if (obj.get("thresholdChars")) |v| switch (v) {
                    .integer => |x| @as(?usize, @intCast(x)),
                    else => null,
                } else null;
                const thresholdTokensEst0 = if (obj.get("thresholdTokensEst")) |v| switch (v) {
                    .integer => |x| @as(?usize, @intCast(x)),
                    else => null,
                } else null;

                const id = try dup.s(self.arena, if (id0) |s| s else try self.newId());
                const pid = if (file_version < 2) (if (pid0) |p| try dup.s(self.arena, p) else legacy_prev_id) else try dup.os(self.arena, pid0);
                if (file_version < 2) {
                    if (legacy_line_index) |li| legacy_index_to_id.items[li] = id;
                    legacy_prev_id = id;
                }
                const ts = try dup.s(self.arena, ts0);
                const reason = try dup.os(self.arena, reason0);
                const format = try dup.s(self.arena, format0);
                const content = try dup.s(self.arena, content0);

                try out.append(self.arena, .{ .summary = .{
                    .id = id,
                    .parentId = pid,
                    .timestamp = ts,
                    .reason = reason,
                    .format = format,
                    .content = content,
                    .totalChars = totalChars0,
                    .totalTokensEst = totalTokensEst0,
                    .keepLast = keepLast0,
                    .keepLastGroups = keepLastGroups0,
                    .thresholdChars = thresholdChars0,
                    .thresholdTokensEst = thresholdTokensEst0,
                } });
                continue;
            }

            // ignore unknown types for forward compatibility
        }

        if (file_version < 2) {
            for (pending_compaction.items) |patch| {
                if (patch.legacy_index < legacy_index_to_id.items.len) {
                    if (legacy_index_to_id.items[patch.legacy_index]) |legacy_id| {
                        switch (out.items[patch.out_index]) {
                            .compaction => |*c| c.firstKeptEntryId = legacy_id,
                            else => {},
                        }
                    }
                }
            }
        }

        return try out.toOwnedSlice(self.arena);
    }

    pub fn loadMessages(self: *SessionManager) ![]MessageEntry {
        // compatibility helper for existing code
        const entries = try self.loadEntries();
        var out = try std.ArrayList(MessageEntry).initCapacity(self.arena, 0);
        defer out.deinit(self.arena);
        for (entries) |e| {
            switch (e) {
                .message => |m| try out.append(self.arena, m),
                else => {},
            }
        }
        return try out.toOwnedSlice(self.arena);
    }

    fn isBusinessEntry(e: Entry) bool {
        return switch (e) {
            .message, .tool_call, .tool_result, .summary => true,
            else => false,
        };
    }

    pub fn buildContextEntries(self: *SessionManager) ![]Entry {
        return try self.buildContextEntriesMode(false);
    }

    pub fn buildContextEntriesVerbose(self: *SessionManager) ![]Entry {
        return try self.buildContextEntriesMode(true);
    }

    /// Build context for model consumption (TS-like), converting compaction, branch_summary
    /// and custom_message entries into message entries and dropping extension-only custom entries.
    pub fn buildSessionContext(self: *SessionManager) ![]Entry {
        return try self.buildSessionContextMode(false);
    }

    /// Verbose variant of model-context assembly.
    pub fn buildSessionContextVerbose(self: *SessionManager) ![]Entry {
        return try self.buildSessionContextMode(true);
    }

    fn buildContextEntriesMode(self: *SessionManager, include_structural: bool) ![]Entry {
        const entries = try self.loadEntries();
        var leaf: ?[]const u8 = null;

        // Find leaf
        for (entries) |e| {
            switch (e) {
                .leaf => |l| leaf = l.targetId,
                else => {},
            }
        }
        if (leaf == null) {
            // no explicit leaf => return all non-session entries (filtered by mode)
            var out_all = try std.ArrayList(Entry).initCapacity(self.arena, entries.len);
            defer out_all.deinit(self.arena);
            for (entries) |e| {
                if (!include_structural and !isBusinessEntry(e)) continue;
                switch (e) {
                    .session, .leaf => {},
                    else => try out_all.append(self.arena, e),
                }
            }
            return try out_all.toOwnedSlice(self.arena);
        }

        // Build id -> entry map for node entries
        var by_id = std.StringHashMap(Entry).init(self.arena);
        defer by_id.deinit();
        for (entries) |e| {
            if (st.idOf(e)) |id| {
                // ignore duplicates; last wins
                try by_id.put(id, e);
            }
        }

        // Walk back from leaf to root
        var path = try std.ArrayList(Entry).initCapacity(self.arena, 64);
        defer path.deinit(self.arena);
        var cur = leaf;
        while (cur) |cid| {
            const e = by_id.get(cid) orelse break;
            try path.append(self.arena, e);
            cur = st.parentIdOf(e);
        }

        // Reverse to root->leaf (filtered by mode)
        var out = try std.ArrayList(Entry).initCapacity(self.arena, path.items.len);
        defer out.deinit(self.arena);
        var i: usize = path.items.len;
        while (i > 0) : (i -= 1) {
            const e = path.items[i - 1];
            if (!include_structural and !isBusinessEntry(e)) continue;
            try out.append(self.arena, e);
        }
        return try out.toOwnedSlice(self.arena);
    }

    fn appendContextEntryMessage(
        self: *SessionManager,
        out: *std.ArrayList(Entry),
        source: Entry,
        role: []const u8,
        content: []const u8,
    ) !void {
        const id = st.idOf(source) orelse "";
        const pid = st.parentIdOf(source);
        const ts = switch (source) {
            .message => |m| m.timestamp,
            .tool_call => |tc| tc.timestamp,
            .tool_result => |tr| tr.timestamp,
            .thinking_level_change => |l| l.timestamp,
            .model_change => |m| m.timestamp,
            .compaction => |c| c.timestamp,
            .branch_summary => |b| b.timestamp,
            .custom => |c| c.timestamp,
            .custom_message => |c| c.timestamp,
            .session_info => |s| s.timestamp,
            .leaf => |l| l.timestamp,
            .label => |l| l.timestamp,
            .turn_start => |t| t.timestamp,
            .turn_end => |t| t.timestamp,
            .summary => |s| s.timestamp,
            .session => |s| s.timestamp,
        };
        try out.append(self.arena, .{ .message = .{ .id = id, .parentId = pid, .timestamp = ts, .role = role, .content = content, .tokensEst = null, .usageTotalTokens = null, .detailsJson = null, .model = null, .thinking = null } });
    }

    fn appendSessionContextEntry(
        self: *SessionManager,
        out: *std.ArrayList(Entry),
        source: Entry,
        include_structural: bool,
    ) !void {
        switch (source) {
            .custom => {},
            .session, .leaf => {},
            .custom_message => |c| {
                try self.appendContextEntryMessage(out, source, "user", c.content);
            },
            .branch_summary => |b| {
                const label = if (b.fromHook) " [fromHook]" else "";
                const summary = try std.fmt.allocPrint(
                    self.arena,
                    "{s}{s}\\n\\n{s}",
                    .{ "The following is a summary of a branch that this conversation came back from", label, b.summary },
                );
                try self.appendContextEntryMessage(out, source, "user", summary);
            },
            .compaction => {},
            .message, .tool_call, .tool_result, .summary => {
                if (!include_structural) {
                    try out.append(self.arena, source);
                } else {
                    // structural context can also expose these directly
                    try out.append(self.arena, source);
                }
            },
            .session_info, .thinking_level_change, .model_change, .turn_start, .turn_end => {
                if (include_structural) {
                    try out.append(self.arena, source);
                }
            },
            else => {
                if (include_structural) {
                    try out.append(self.arena, source);
                }
            },
        }
    }

    fn buildSessionContextMode(self: *SessionManager, include_structural: bool) ![]Entry {
        var out = try std.ArrayList(Entry).initCapacity(self.arena, 0);
        defer out.deinit(self.arena);

        const chain = try self.buildContextEntriesMode(true);

        var compaction_idx: ?usize = null;
        for (chain, 0..) |e, i| {
            switch (e) {
                .compaction => compaction_idx = i,
                else => {},
            }
        }

        if (compaction_idx == null) {
            for (chain) |e| {
                try self.appendSessionContextEntry(&out, e, include_structural);
            }
            return try out.toOwnedSlice(self.arena);
        }

        // Keep last compaction window and convert it into a summary message,
        // then keep a bounded range from firstKeptEntryId onward.
        const cidx = compaction_idx.?;
        const comp = chain[cidx].compaction;
        const compaction_prefix = if (comp.fromHook) " [fromHook]" else "";
        const compaction_summary = try std.fmt.allocPrint(
            self.arena,
            "{s}{s}\\n(tokens before: {d})\\n{s}",
            .{ "The following is a summary of the conversation history before this point", compaction_prefix, comp.tokensBefore, comp.summary },
        );
        try self.appendContextEntryMessage(&out, chain[cidx], "user", compaction_summary);

        // Kept window starts when firstKeptEntryId is found.
        var found = false;
        var i: usize = 0;
        while (i < cidx) : (i += 1) {
            const e = chain[i];
            if (st.idOf(e)) |eid| {
                if (std.mem.eql(u8, eid, comp.firstKeptEntryId)) {
                    found = true;
                }
            }
            if (!found) continue;
            switch (e) {
                .compaction => {},
                else => try self.appendSessionContextEntry(&out, e, include_structural),
            }
        }

        var j: usize = cidx + 1;
        while (j < chain.len) : (j += 1) {
            const e = chain[j];
            switch (e) {
                .compaction => {},
                else => try self.appendSessionContextEntry(&out, e, include_structural),
            }
        }

        return try out.toOwnedSlice(self.arena);
    }
};
