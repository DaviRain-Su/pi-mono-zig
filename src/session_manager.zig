const std = @import("std");
const json_util = @import("json_util.zig");
const st = @import("session_types.zig");

pub const SessionHeader = st.SessionHeader;
pub const MessageEntry = st.MessageEntry;
pub const ToolCallEntry = st.ToolCallEntry;
pub const ToolResultEntry = st.ToolResultEntry;
pub const ThinkingLevelChangeEntry = st.ThinkingLevelChangeEntry;
pub const ModelChangeEntry = st.ModelChangeEntry;
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
        const ms = std.time.milliTimestamp();
        const secs = @as(u64, @intCast(@divTrunc(ms, 1000)));
        const ms_part = @as(u16, @intCast(@mod(ms, 1000)));

        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();

        return try std.fmt.allocPrint(
            arena,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
            .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                day_seconds.getHoursIntoDay(),
                day_seconds.getMinutesIntoHour(),
                day_seconds.getSecondsIntoMinute(),
                ms_part,
            },
        );
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

    const LeafResolution = struct {
        saw_explicit_leaf: bool,
        explicit_leaf_target: ?[]const u8,
        selected_leaf: ?[]const u8,
    };

    fn resolveLeaf(entries: []const Entry) LeafResolution {
        var saw_leaf = false;
        var explicit_leaf: ?[]const u8 = null;
        var last_node: ?[]const u8 = null;

        for (entries) |e| {
            switch (e) {
                .leaf => |l| {
                    saw_leaf = true;
                    explicit_leaf = l.targetId;
                },
                else => {},
            }
            if (st.idOf(e)) |id| {
                last_node = id;
            }
        }

        if (!saw_leaf) {
            return .{
                .saw_explicit_leaf = false,
                .explicit_leaf_target = null,
                .selected_leaf = last_node,
            };
        }

        if (explicit_leaf == null) {
            // Explicit root navigation (leaf=null): context should be empty and appends should start at root.
            return .{
                .saw_explicit_leaf = true,
                .explicit_leaf_target = null,
                .selected_leaf = null,
            };
        }

        const wanted = explicit_leaf.?;
        for (entries) |e| {
            if (st.idOf(e)) |id| {
                if (std.mem.eql(u8, id, wanted)) {
                    return .{
                        .saw_explicit_leaf = true,
                        .explicit_leaf_target = wanted,
                        .selected_leaf = wanted,
                    };
                }
            }
        }

        // Corrupt/unknown explicit leaf id: fall back to last node (TS behavior).
        return .{
            .saw_explicit_leaf = true,
            .explicit_leaf_target = wanted,
            .selected_leaf = last_node,
        };
    }

    fn currentLeafId(self: *SessionManager) !?[]const u8 {
        const entries = try self.loadEntries();
        return resolveLeaf(entries).selected_leaf;
    }

    fn setLeaf(self: *SessionManager, target: ?[]const u8) !void {
        const id = try self.newId();
        const entry = LeafEntry{
            .id = id,
            .parentId = target,
            .timestamp = try nowIso(self.arena),
            .targetId = target,
        };
        try json_util.appendJsonLine(self.session_path, entry);
    }

    fn hasEntryId(self: *SessionManager, target_id: []const u8) !bool {
        const entries = try self.loadEntries();
        for (entries) |e| {
            if (st.idOf(e)) |id| {
                if (std.mem.eql(u8, id, target_id)) {
                    return true;
                }
            }
        }
        return false;
    }

    fn normalizeMessageRole(role: []const u8) []const u8 {
        if (std.mem.eql(u8, role, "toolResult")) return "tool";
        if (std.mem.eql(u8, role, "branchSummary")) return "user";
        if (std.mem.eql(u8, role, "compactionSummary")) return "user";
        if (std.mem.eql(u8, role, "custom")) return "user";
        if (std.mem.eql(u8, role, "bashExecution")) return "user";
        return role;
    }

    fn extractTextFromContentValue(allocator: std.mem.Allocator, v: std.json.Value) ![]const u8 {
        switch (v) {
            .string => |s| return try allocator.dupe(u8, s),
            .array => |a| {
                var out = try std.ArrayList(u8).initCapacity(allocator, 0);
                defer out.deinit(allocator);

                var wrote_any = false;
                for (a.items) |it| {
                    var chunk: ?[]const u8 = null;
                    switch (it) {
                        .string => |s| chunk = s,
                        .object => |o| {
                            const tpe = if (o.get("type")) |tv| switch (tv) {
                                .string => |s| s,
                                else => "",
                            } else "";

                            if (o.get("text")) |tv| switch (tv) {
                                .string => |s| chunk = s,
                                else => {},
                            };

                            if (chunk == null) {
                                if (o.get("content")) |cv| switch (cv) {
                                    .string => |s| chunk = s,
                                    else => {},
                                };
                            }

                            if (chunk == null and
                                (std.mem.eql(u8, tpe, "image") or
                                    std.mem.eql(u8, tpe, "input_image") or
                                    std.mem.eql(u8, tpe, "image_url")))
                            {
                                chunk = "[image]";
                            }
                        },
                        else => {},
                    }

                    if (chunk) |c| {
                        if (c.len == 0) continue;
                        if (wrote_any) try out.appendSlice(allocator, "\n");
                        try out.appendSlice(allocator, c);
                        wrote_any = true;
                    }
                }

                if (!wrote_any) return try allocator.dupe(u8, "[non-text content]");
                return try out.toOwnedSlice(allocator);
            },
            .object => |o| {
                if (o.get("text")) |tv| switch (tv) {
                    .string => |s| return try allocator.dupe(u8, s),
                    else => {},
                };
                return try allocator.dupe(u8, "[object content]");
            },
            else => return try allocator.dupe(u8, "[non-text content]"),
        }
    }

    fn jsonValueToString(allocator: std.mem.Allocator, v: std.json.Value) ![]const u8 {
        return try std.json.Stringify.valueAlloc(allocator, v, .{});
    }

    pub fn branchTo(self: *SessionManager, targetId: ?[]const u8) !void {
        if (targetId) |tid| {
            if (!try self.hasEntryId(tid)) {
                return error.EntryNotFound;
            }
        }
        try self.setLeaf(targetId);
    }

    pub fn leafId(self: *SessionManager) !?[]const u8 {
        return try self.currentLeafId();
    }

    pub fn setLabel(self: *SessionManager, targetId: []const u8, label: ?[]const u8) ![]const u8 {
        if (targetId.len == 0) return error.EntryNotFound;
        if (!try self.hasEntryId(targetId)) return error.EntryNotFound;
        const id = try self.newId();
        const pid = try self.currentLeafId();
        const entry = LabelEntry{
            .id = id,
            .parentId = pid,
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
        firstKeptEntryId: ?[]const u8,
        totalChars: ?usize,
        totalTokensEst: ?usize,
        keepLast: ?usize,
        keepLastGroups: ?usize,
        thresholdChars: ?usize,
        thresholdTokensEst: ?usize,
    ) ![]const u8 {
        return try self.appendSummaryWithFiles(
            content,
            reason,
            format,
            firstKeptEntryId,
            null,
            null,
            totalChars,
            totalTokensEst,
            keepLast,
            keepLastGroups,
            thresholdChars,
            thresholdTokensEst,
        );
    }

    pub fn appendSummaryWithFiles(
        self: *SessionManager,
        content: []const u8,
        reason: ?[]const u8,
        format: []const u8,
        firstKeptEntryId: ?[]const u8,
        readFiles: ?[]const []const u8,
        modifiedFiles: ?[]const []const u8,
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
            .summary = content,
            .firstKeptEntryId = firstKeptEntryId,
            .tokensBefore = totalTokensEst,
            .readFiles = readFiles,
            .modifiedFiles = modifiedFiles,
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
        return try self.appendMessageWithTokensEst(role, content, null);
    }

    pub fn appendMessageWithTokensEst(self: *SessionManager, role: []const u8, content: []const u8, tokens_est: ?usize) ![]const u8 {
        return try self.appendMessageWithMeta(role, content, tokens_est, null);
    }

    pub fn appendMessageWithUsage(
        self: *SessionManager,
        role: []const u8,
        content: []const u8,
        usage_total_tokens: ?usize,
    ) ![]const u8 {
        return try self.appendMessageWithMeta(role, content, null, usage_total_tokens);
    }

    pub fn appendMessageWithMeta(
        self: *SessionManager,
        role: []const u8,
        content: []const u8,
        tokens_est: ?usize,
        usage_total_tokens: ?usize,
    ) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const nested_usage: ?MessageEntry.Usage = if (usage_total_tokens) |u| .{ .totalTokens = u } else null;
        const entry = MessageEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .role = role,
            .content = content,
            .message = .{
                .role = role,
                .content = content,
                .usage = nested_usage,
            },
            .tokensEst = tokens_est,
            .usageTotalTokens = usage_total_tokens,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
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

    pub fn appendThinkingLevelChange(self: *SessionManager, thinking_level: []const u8) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = ThinkingLevelChangeEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .thinkingLevel = thinking_level,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendModelChange(self: *SessionManager, provider: []const u8, model_id: []const u8) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = ModelChangeEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .provider = provider,
            .modelId = model_id,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendBranchSummary(self: *SessionManager, from_id: []const u8, summary: []const u8) ![]const u8 {
        const pid = try self.currentLeafId();
        const id = try self.newId();
        const entry = BranchSummaryEntry{
            .id = id,
            .parentId = pid,
            .timestamp = try nowIso(self.arena),
            .fromId = from_id,
            .summary = summary,
            .fromHook = null,
            .detailsJson = null,
        };
        try json_util.appendJsonLine(self.session_path, entry);
        try self.setLeaf(id);
        return id;
    }

    pub fn appendSessionInfo(self: *SessionManager, name: ?[]const u8) ![]const u8 {
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

    pub fn latestSessionName(self: *SessionManager) !?[]const u8 {
        const entries = try self.loadEntries();
        var i: usize = entries.len;
        while (i > 0) : (i -= 1) {
            const e = entries[i - 1];
            switch (e) {
                .session_info => |si| return si.name,
                else => {},
            }
        }
        return null;
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
                const id0 = switch (obj.get("id") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const msg_obj = if (obj.get("message")) |mv| switch (mv) {
                    .object => |o| @as(?std.json.ObjectMap, o),
                    else => null,
                } else null;

                const role0 = if (obj.get("role")) |v| switch (v) {
                    .string => |s| s,
                    else => continue,
                } else if (msg_obj) |mo| switch (mo.get("role") orelse continue) {
                    .string => |s| s,
                    else => continue,
                } else continue;
                const role_norm0 = normalizeMessageRole(role0);

                const content_val = if (obj.get("content")) |v| v else if (msg_obj) |mo| (mo.get("content") orelse continue) else continue;
                const content = try extractTextFromContentValue(self.arena, content_val);

                const tokens_est0 = if (obj.get("tokensEst")) |v| switch (v) {
                    .integer => |x| @as(?usize, @intCast(x)),
                    else => null,
                } else null;
                const usage_total_tokens0 = if (obj.get("usageTotalTokens")) |v| switch (v) {
                    .integer => |x| @as(?usize, @intCast(x)),
                    else => null,
                } else if (msg_obj) |mo| blk: {
                    const usage_v = mo.get("usage") orelse break :blk null;
                    switch (usage_v) {
                        .object => |uobj| {
                            const tt_v = uobj.get("totalTokens") orelse break :blk null;
                            switch (tt_v) {
                                .integer => |x| break :blk @as(?usize, @intCast(x)),
                                else => break :blk null,
                            }
                        },
                        else => break :blk null,
                    }
                } else null;
                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const role = try dup.s(self.arena, role_norm0);
                try out.append(self.arena, .{ .message = .{
                    .id = id,
                    .parentId = pid,
                    .timestamp = ts,
                    .role = role,
                    .content = content,
                    .tokensEst = tokens_est0,
                    .usageTotalTokens = usage_total_tokens0,
                } });
                continue;
            }

            if (std.mem.eql(u8, typ, "tool_call")) {
                const id0 = switch (obj.get("id") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
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
                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const tool = try dup.s(self.arena, tool0);
                const arg = try dup.s(self.arena, arg0);
                try out.append(self.arena, .{ .tool_call = .{ .id = id, .parentId = pid, .timestamp = ts, .tool = tool, .arg = arg, .tokensEst = tokens_est0 } });
                continue;
            }

            if (std.mem.eql(u8, typ, "tool_result")) {
                const id0 = switch (obj.get("id") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
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
                const content0 = if (obj.get("content")) |v| switch (v) {
                    .string => |s| s,
                    else => continue,
                } else continue;
                const tokens_est0 = if (obj.get("tokensEst")) |v| switch (v) {
                    .integer => |x| @as(?usize, @intCast(x)),
                    else => null,
                } else null;
                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const tool = try dup.s(self.arena, tool0);
                const content = try dup.s(self.arena, content0);
                try out.append(self.arena, .{ .tool_result = .{ .id = id, .parentId = pid, .timestamp = ts, .tool = tool, .ok = ok, .content = content, .tokensEst = tokens_est0 } });
                continue;
            }

            if (std.mem.eql(u8, typ, "thinking_level_change")) {
                const id0 = switch (obj.get("id") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const lvl0 = switch (obj.get("thinkingLevel") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const lvl = try dup.s(self.arena, lvl0);
                try out.append(self.arena, .{ .thinking_level_change = .{
                    .id = id,
                    .parentId = pid,
                    .timestamp = ts,
                    .thinkingLevel = lvl,
                } });
                continue;
            }

            if (std.mem.eql(u8, typ, "model_change")) {
                const id0 = switch (obj.get("id") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
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
                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const provider = try dup.s(self.arena, provider0);
                const model_id = try dup.s(self.arena, model_id0);
                try out.append(self.arena, .{ .model_change = .{
                    .id = id,
                    .parentId = pid,
                    .timestamp = ts,
                    .provider = provider,
                    .modelId = model_id,
                } });
                continue;
            }

            if (std.mem.eql(u8, typ, "branch_summary")) {
                const id0 = switch (obj.get("id") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const ts0 = switch (obj.get("timestamp") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const from0 = switch (obj.get("fromId") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const summary0 = switch (obj.get("summary") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const from_hook0 = if (obj.get("fromHook")) |v| switch (v) {
                    .bool => |b| @as(?bool, b),
                    else => null,
                } else null;
                const details_json0 = if (obj.get("details")) |v| try jsonValueToString(self.arena, v) else null;
                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const from = try dup.s(self.arena, from0);
                const summary = try dup.s(self.arena, summary0);
                try out.append(self.arena, .{ .branch_summary = .{
                    .id = id,
                    .parentId = pid,
                    .timestamp = ts,
                    .fromId = from,
                    .summary = summary,
                    .fromHook = from_hook0,
                    .detailsJson = details_json0,
                } });
                continue;
            }

            if (std.mem.eql(u8, typ, "custom")) {
                const id0 = switch (obj.get("id") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
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
                const data_json0 = if (obj.get("data")) |v| try jsonValueToString(self.arena, v) else null;
                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const custom_type = try dup.s(self.arena, custom_type0);
                try out.append(self.arena, .{ .custom = .{
                    .id = id,
                    .parentId = pid,
                    .timestamp = ts,
                    .customType = custom_type,
                    .dataJson = data_json0,
                } });
                continue;
            }

            if (std.mem.eql(u8, typ, "custom_message")) {
                const id0 = switch (obj.get("id") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
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
                const content_v = obj.get("content") orelse continue;
                const display0 = if (obj.get("display")) |v| switch (v) {
                    .bool => |b| b,
                    else => true,
                } else true;
                const content_json0 = try jsonValueToString(self.arena, content_v);
                const details_json0 = if (obj.get("details")) |v| try jsonValueToString(self.arena, v) else null;

                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const custom_type = try dup.s(self.arena, custom_type0);
                const content = try extractTextFromContentValue(self.arena, content_v);

                try out.append(self.arena, .{ .custom_message = .{
                    .id = id,
                    .parentId = pid,
                    .timestamp = ts,
                    .customType = custom_type,
                    .content = content,
                    .display = display0,
                    .contentJson = content_json0,
                    .detailsJson = details_json0,
                } });
                continue;
            }

            if (std.mem.eql(u8, typ, "session_info")) {
                const id0 = switch (obj.get("id") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
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

                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const name = try dup.os(self.arena, name0);

                try out.append(self.arena, .{ .session_info = .{
                    .id = id,
                    .parentId = pid,
                    .timestamp = ts,
                    .name = name,
                } });
                continue;
            }

            if (std.mem.eql(u8, typ, "turn_start")) {
                const id0 = switch (obj.get("id") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
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
                const id0 = switch (obj.get("id") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
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
                const id0 = if (obj.get("id")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
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
                const tid0 = if (obj.get("targetId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const id = try dup.os(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const tid = try dup.os(self.arena, tid0);
                try out.append(self.arena, .{ .leaf = .{
                    .id = id,
                    .parentId = pid,
                    .timestamp = ts,
                    .targetId = tid,
                } });
                continue;
            }

            if (std.mem.eql(u8, typ, "label")) {
                const id0 = switch (obj.get("id") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const pid0 = if (obj.get("parentId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
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
                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const targetId = try dup.s(self.arena, target0);
                const label = try dup.os(self.arena, label0);
                try out.append(self.arena, .{ .label = .{
                    .id = id,
                    .parentId = pid,
                    .timestamp = ts,
                    .targetId = targetId,
                    .label = label,
                } });
                continue;
            }

            if (std.mem.eql(u8, typ, "summary") or std.mem.eql(u8, typ, "compaction")) {
                const id0 = switch (obj.get("id") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
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
                const content0 = if (obj.get("summary")) |v| switch (v) {
                    .string => |s| s,
                    else => continue,
                } else if (obj.get("content")) |v| switch (v) {
                    .string => |s| s,
                    else => continue,
                } else continue;
                const firstKeptEntryId0 = if (obj.get("firstKeptEntryId")) |v| switch (v) {
                    .string => |s| @as(?[]const u8, s),
                    else => null,
                } else null;
                const tokensBefore0 = if (obj.get("tokensBefore")) |v| switch (v) {
                    .integer => |x| @as(?usize, @intCast(x)),
                    else => null,
                } else null;
                const fromHook0 = if (obj.get("fromHook")) |v| switch (v) {
                    .bool => |b| @as(?bool, b),
                    else => null,
                } else null;
                const detailsJson0 = if (obj.get("details")) |v| try jsonValueToString(self.arena, v) else null;

                const details_obj = if (obj.get("details")) |dv| switch (dv) {
                    .object => |o| @as(?std.json.ObjectMap, o),
                    else => null,
                } else null;

                const readFiles0 = if (obj.get("readFiles")) |v| v else if (details_obj) |dobj| dobj.get("readFiles") else null;
                const modifiedFiles0 = if (obj.get("modifiedFiles")) |v| v else if (details_obj) |dobj| dobj.get("modifiedFiles") else null;

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

                const totalTokensEstResolved = totalTokensEst0 orelse tokensBefore0;
                const tokensBeforeResolved = tokensBefore0 orelse totalTokensEst0;

                const id = try dup.s(self.arena, id0);
                const pid = try dup.os(self.arena, pid0);
                const ts = try dup.s(self.arena, ts0);
                const reason = try dup.os(self.arena, reason0);
                const format = try dup.s(self.arena, format0);
                const content = try dup.s(self.arena, content0);
                const first_kept_entry_id = try dup.os(self.arena, firstKeptEntryId0);

                var rf_list = try std.ArrayList([]const u8).initCapacity(self.arena, 0);
                defer rf_list.deinit(self.arena);
                if (readFiles0) |rv| switch (rv) {
                    .array => |a| for (a.items) |v_it| if (v_it == .string) try rf_list.append(self.arena, try dup.s(self.arena, v_it.string)),
                    else => {},
                };

                var mf_list = try std.ArrayList([]const u8).initCapacity(self.arena, 0);
                defer mf_list.deinit(self.arena);
                if (modifiedFiles0) |mv| switch (mv) {
                    .array => |a| for (a.items) |v_it| if (v_it == .string) try mf_list.append(self.arena, try dup.s(self.arena, v_it.string)),
                    else => {},
                };

                const rf_slice = if (rf_list.items.len > 0) try rf_list.toOwnedSlice(self.arena) else null;
                const mf_slice = if (mf_list.items.len > 0) try mf_list.toOwnedSlice(self.arena) else null;

                try out.append(self.arena, .{ .summary = .{
                    .id = id,
                    .parentId = pid,
                    .timestamp = ts,
                    .reason = reason,
                    .format = format,
                    .summary = content,
                    .firstKeptEntryId = first_kept_entry_id,
                    .tokensBefore = tokensBeforeResolved,
                    .fromHook = fromHook0,
                    .detailsJson = detailsJson0,
                    .readFiles = rf_slice,
                    .modifiedFiles = mf_slice,
                    .totalChars = totalChars0,
                    .totalTokensEst = totalTokensEstResolved,
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

    fn isBusinessEntry(e: Entry) bool {
        return switch (e) {
            .message,
            .tool_call,
            .tool_result,
            .summary,
            .branch_summary,
            .custom_message,
            .model_change,
            .thinking_level_change,
            => true,
            else => false,
        };
    }

    pub fn buildContextEntries(self: *SessionManager) ![]Entry {
        return try self.buildContextEntriesMode(false);
    }

    pub fn buildContextEntriesVerbose(self: *SessionManager) ![]Entry {
        return try self.buildContextEntriesMode(true);
    }

    fn buildContextEntriesMode(self: *SessionManager, include_structural: bool) ![]Entry {
        const entries = try self.loadEntries();

        const leaf_resolution = resolveLeaf(entries);

        // Explicit root navigation (leaf=null) -> no context.
        if (leaf_resolution.saw_explicit_leaf and leaf_resolution.explicit_leaf_target == null) {
            return try self.arena.alloc(Entry, 0);
        }

        const leaf = leaf_resolution.selected_leaf;
        if (leaf == null) {
            return try self.arena.alloc(Entry, 0);
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

        // Reverse to root->leaf first.
        var root_path = try std.ArrayList(Entry).initCapacity(self.arena, path.items.len);
        defer root_path.deinit(self.arena);
        var i: usize = path.items.len;
        while (i > 0) : (i -= 1) {
            try root_path.append(self.arena, path.items[i - 1]);
        }

        // Fast path: no summary node in branch => regular filtered projection.
        var latest_summary_idx: ?usize = null;
        var latest_first_kept: ?[]const u8 = null;
        var k: usize = root_path.items.len;
        while (k > 0) : (k -= 1) {
            const e = root_path.items[k - 1];
            switch (e) {
                .summary => |s| {
                    latest_summary_idx = k - 1;
                    latest_first_kept = s.firstKeptEntryId;
                    break;
                },
                else => {},
            }
        }

        var out = try std.ArrayList(Entry).initCapacity(self.arena, root_path.items.len);
        defer out.deinit(self.arena);

        if (latest_summary_idx == null) {
            for (root_path.items) |e| {
                if (!include_structural and !isBusinessEntry(e)) continue;
                try out.append(self.arena, e);
            }
            return try out.toOwnedSlice(self.arena);
        }

        const si = latest_summary_idx.?;
        const summary_entry = root_path.items[si];
        if (include_structural or isBusinessEntry(summary_entry)) {
            try out.append(self.arena, summary_entry);
        }

        // TS-style compaction view:
        // - with firstKeptEntryId: summary + kept pre-summary tail + post-summary suffix
        // - legacy (no firstKeptEntryId): summary + post-summary suffix only
        if (latest_first_kept) |first_kept_id| {
            var found: bool = false;
            var pre_i: usize = 0;
            while (pre_i < si) : (pre_i += 1) {
                const e = root_path.items[pre_i];
                if (!found) {
                    if (st.idOf(e)) |eid| {
                        if (std.mem.eql(u8, eid, first_kept_id)) {
                            found = true;
                        }
                    }
                }
                if (!found) continue;
                if (!include_structural and !isBusinessEntry(e)) continue;
                try out.append(self.arena, e);
            }
        }

        var post_i: usize = si + 1;
        while (post_i < root_path.items.len) : (post_i += 1) {
            const e = root_path.items[post_i];
            if (!include_structural and !isBusinessEntry(e)) continue;
            try out.append(self.arena, e);
        }

        return try out.toOwnedSlice(self.arena);
    }
};
