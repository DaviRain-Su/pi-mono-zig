const std = @import("std");
const json_util = @import("json_util.zig");
const st = @import("session_types.zig");

pub const SessionHeader = st.SessionHeader;
pub const MessageEntry = st.MessageEntry;
pub const ToolCallEntry = st.ToolCallEntry;
pub const ToolResultEntry = st.ToolResultEntry;
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
        // good enough for MVP: unixms as string
        return try std.fmt.allocPrint(arena, "{d}", .{std.time.milliTimestamp()});
    }

    fn newId(self: *SessionManager) ![]const u8 {
        self.seq += 1;
        return try std.fmt.allocPrint(self.arena, "e_{d}_{d}", .{ std.time.milliTimestamp(), self.seq });
    }

    pub fn ensure(self: *SessionManager) !void {
        // if file exists and non-empty, assume ok
        const stat_res = std.fs.cwd().statFile(self.session_path);
        if (stat_res) |_| {
            // If empty, rewrite header
            const f = try std.fs.cwd().openFile(self.session_path, .{});
            defer f.close();
            const stat = try f.stat();
            if (stat.size > 0) return;
        } else |_| {
            // create parent dir
            if (std.fs.path.dirname(self.session_path)) |dir| {
                std.fs.cwd().makePath(dir) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => return e,
                };
            }
            _ = try std.fs.cwd().createFile(self.session_path, .{ .truncate = true });
        }

        // write header line
        const sid = try std.fmt.allocPrint(self.arena, "s_{d}", .{std.time.milliTimestamp()});
        const header = SessionHeader{
            .id = sid,
            .timestamp = try nowIso(self.arena),
            .cwd = self.cwd,
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
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = MessageEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .role = role,
            .content = content,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendToolCall(self: *SessionManager, tool: []const u8, arg: []const u8) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = ToolCallEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .tool = tool,
            .arg = arg,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendToolResult(self: *SessionManager, tool: []const u8, ok: bool, content: []const u8) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = ToolResultEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .tool = tool,
            .ok = ok,
            .content = content,
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
        var f = try std.fs.cwd().openFile(self.session_path, .{});
        defer f.close();
        const bytes = try f.readToEndAlloc(self.arena, 64 * 1024 * 1024);

        var out = try std.ArrayList(Entry).initCapacity(self.arena, 0);
        defer out.deinit(self.arena);

        var it = std.mem.splitScalar(u8, bytes, '\n');
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

            if (std.mem.eql(u8, typ, "message")) {
                const id0 = switch (obj.get("id") orelse continue) { .string => |s| s, else => continue };
                const pid0 = if (obj.get("parentId")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) { .string => |s| s, else => continue };
                const role0 = switch (obj.get("role") orelse continue) { .string => |s| s, else => continue };
                const content0 = switch (obj.get("content") orelse continue) { .string => |s| s, else => continue };
                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const role = try dup.s(self.arena, role0);
                const content = try dup.s(self.arena, content0);
                try out.append(self.arena, .{ .message = .{ .id = id, .parentId = pid, .timestamp = ts, .role = role, .content = content } });
                continue;
            }

            if (std.mem.eql(u8, typ, "tool_call")) {
                const id0 = switch (obj.get("id") orelse continue) { .string => |s| s, else => continue };
                const pid0 = if (obj.get("parentId")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) { .string => |s| s, else => continue };
                const tool0 = switch (obj.get("tool") orelse continue) { .string => |s| s, else => continue };
                const arg0 = switch (obj.get("arg") orelse continue) { .string => |s| s, else => continue };
                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const tool = try dup.s(self.arena, tool0);
                const arg = try dup.s(self.arena, arg0);
                try out.append(self.arena, .{ .tool_call = .{ .id = id, .parentId = pid, .timestamp = ts, .tool = tool, .arg = arg } });
                continue;
            }

            if (std.mem.eql(u8, typ, "tool_result")) {
                const id0 = switch (obj.get("id") orelse continue) { .string => |s| s, else => continue };
                const pid0 = if (obj.get("parentId")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) { .string => |s| s, else => continue };
                const tool0 = switch (obj.get("tool") orelse continue) { .string => |s| s, else => continue };
                const ok = switch (obj.get("ok") orelse continue) { .bool => |b| b, else => continue };
                const content0 = switch (obj.get("content") orelse continue) { .string => |s| s, else => continue };
                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const tool = try dup.s(self.arena, tool0);
                const content = try dup.s(self.arena, content0);
                try out.append(self.arena, .{ .tool_result = .{ .id = id, .parentId = pid, .timestamp = ts, .tool = tool, .ok = ok, .content = content } });
                continue;
            }

            if (std.mem.eql(u8, typ, "turn_start")) {
                const id0 = switch (obj.get("id") orelse continue) { .string => |s| s, else => continue };
                const pid0 = if (obj.get("parentId")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) { .string => |s| s, else => continue };
                const turn = switch (obj.get("turn") orelse continue) { .integer => |x| @as(u64, @intCast(x)), else => continue };
                const um0 = if (obj.get("userMessageId")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const tg0 = if (obj.get("turnGroupId")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const ph0 = if (obj.get("phase")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const um = try dup.os(self.arena, um0);
                const tg = try dup.os(self.arena, tg0);
                const ph = try dup.os(self.arena, ph0);
                try out.append(self.arena, .{ .turn_start = .{ .id = id, .parentId = pid, .timestamp = ts, .turn = turn, .userMessageId = um, .turnGroupId = tg, .phase = ph } });
                continue;
            }

            if (std.mem.eql(u8, typ, "turn_end")) {
                const id0 = switch (obj.get("id") orelse continue) { .string => |s| s, else => continue };
                const pid0 = if (obj.get("parentId")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) { .string => |s| s, else => continue };
                const turn = switch (obj.get("turn") orelse continue) { .integer => |x| @as(u64, @intCast(x)), else => continue };
                const um0 = if (obj.get("userMessageId")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const tg0 = if (obj.get("turnGroupId")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const ph0 = if (obj.get("phase")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const um = try dup.os(self.arena, um0);
                const tg = try dup.os(self.arena, tg0);
                const ph = try dup.os(self.arena, ph0);
                try out.append(self.arena, .{ .turn_end = .{ .id = id, .parentId = pid, .timestamp = ts, .turn = turn, .userMessageId = um, .turnGroupId = tg, .phase = ph } });
                continue;
            }

            if (std.mem.eql(u8, typ, "leaf")) {
                const ts0 = switch (obj.get("timestamp") orelse continue) { .string => |s| s, else => continue };
                const tid0 = if (obj.get("targetId")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const ts = try dup.s(self.arena, ts0);
                const tid = try dup.os(self.arena, tid0);
                try out.append(self.arena, .{ .leaf = .{ .timestamp = ts, .targetId = tid } });
                continue;
            }

            if (std.mem.eql(u8, typ, "label")) {
                const id0 = switch (obj.get("id") orelse continue) { .string => |s| s, else => continue };
                const ts0 = switch (obj.get("timestamp") orelse continue) { .string => |s| s, else => continue };
                const target0 = switch (obj.get("targetId") orelse continue) { .string => |s| s, else => continue };
                const label0 = if (obj.get("label")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const id = try dup.s(self.arena, id0);
                const ts = try dup.s(self.arena, ts0);
                const targetId = try dup.s(self.arena, target0);
                const label = try dup.os(self.arena, label0);
                try out.append(self.arena, .{ .label = .{ .id = id, .timestamp = ts, .targetId = targetId, .label = label } });
                continue;
            }

            if (std.mem.eql(u8, typ, "summary")) {
                const id0 = switch (obj.get("id") orelse continue) { .string => |s| s, else => continue };
                const pid0 = if (obj.get("parentId")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) { .string => |s| s, else => continue };
                const reason0 = if (obj.get("reason")) |v| switch (v) { .string => |s| @as(?[]const u8, s), else => null } else null;
                const format0 = if (obj.get("format")) |v| switch (v) { .string => |s| s, else => "text" } else "text";
                const content0 = switch (obj.get("content") orelse continue) { .string => |s| s, else => continue };

                const totalChars0 = if (obj.get("totalChars")) |v| switch (v) { .integer => |x| @as(?usize, @intCast(x)), else => null } else null;
                const totalTokensEst0 = if (obj.get("totalTokensEst")) |v| switch (v) { .integer => |x| @as(?usize, @intCast(x)), else => null } else null;
                const keepLast0 = if (obj.get("keepLast")) |v| switch (v) { .integer => |x| @as(?usize, @intCast(x)), else => null } else null;
                const keepLastGroups0 = if (obj.get("keepLastGroups")) |v| switch (v) { .integer => |x| @as(?usize, @intCast(x)), else => null } else null;
                const thresholdChars0 = if (obj.get("thresholdChars")) |v| switch (v) { .integer => |x| @as(?usize, @intCast(x)), else => null } else null;
                const thresholdTokensEst0 = if (obj.get("thresholdTokensEst")) |v| switch (v) { .integer => |x| @as(?usize, @intCast(x)), else => null } else null;

                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
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

    pub fn buildContextEntries(self: *SessionManager) ![]Entry {
        const entries = try self.loadEntries();

        // Find leaf
        var leaf: ?[]const u8 = null;
        for (entries) |e| {
            switch (e) {
                .leaf => |l| leaf = l.targetId,
                else => {},
            }
        }
        if (leaf == null) {
            // no explicit leaf => return all non-session entries
            var out_all = try std.ArrayList(Entry).initCapacity(self.arena, entries.len);
            defer out_all.deinit(self.arena);
            for (entries) |e| {
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

        // Reverse to root->leaf
        var out = try std.ArrayList(Entry).initCapacity(self.arena, path.items.len);
        defer out.deinit(self.arena);
        var i: usize = path.items.len;
        while (i > 0) : (i -= 1) {
            try out.append(self.arena, path.items[i - 1]);
        }
        return try out.toOwnedSlice(self.arena);
    }
};
