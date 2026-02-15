const std = @import("std");
const root = @import("root.zig");
const session = @import("session_manager.zig");
const tools = @import("tools.zig");
const agent_loop = @import("agent_loop.zig");
const events = @import("events.zig");
const st = @import("session_types.zig");

fn usage() void {
    std.debug.print(
        \\pi-mono-zig (MVP)\n\n\
        \\Usage:\n\
        \\  pi-mono-zig run --plan <plan.json> [--out runs]\n\
        \\  pi-mono-zig verify --run <runId> [--out runs]\n\
        \\  pi-mono-zig chat --session <path.jsonl> [--allow-shell] [--auto-compact --max-chars N --max-tokens-est N --keep-last N --keep-last-groups N]\n\
        \\  pi-mono-zig replay --session <path.jsonl> [--show-turns]\n\
        \\  pi-mono-zig session-migrate --session <path.jsonl> [--out <path.jsonl>] [--dry-run]\n\
        \\  pi-mono-zig branch --session <path.jsonl> [--to <entryId> | --root]\n\
        \\  pi-mono-zig branch-with-summary --session <path.jsonl> [--to <entryId> | --root] [--summary <text>]\n\
        \\  pi-mono-zig set-model --session <path.jsonl> --provider <name> --model <id>\n\
        \\  pi-mono-zig set-thinking --session <path.jsonl> --level <name>\n\
        \\  pi-mono-zig session-name --session <path.jsonl> [--set <name> | --clear]\n\
        \\  pi-mono-zig label --session <path.jsonl> --to <entryId> --label <name>\n\
        \\  pi-mono-zig list --session <path.jsonl> [--show-turns]\n\
        \\  pi-mono-zig show --session <path.jsonl> --id <entryId>\n\
        \\  pi-mono-zig tree --session <path.jsonl> [--max-depth N] [--show-turns]\n\
        \\  pi-mono-zig compact --session <path.jsonl> [--keep-last N] [--keep-last-groups N] [--max-chars N] [--max-tokens-est N] [--dry-run] [--label NAME] [--structured (md|json)] [--update]\n\n\
        \\Examples:\n\
        \\  zig build run -- run --plan examples/hello.plan.json\n\
        \\  zig build run -- verify --run run_123_hello\n\n\
    , .{});
}

const SessionMigrateStats = struct {
    totalLines: usize = 0,
    changedLines: usize = 0,
    parseErrors: usize = 0,
    timestampChanged: usize = 0,
    sessionChanged: usize = 0,
    messageChanged: usize = 0,
    leafChanged: usize = 0,
    labelChanged: usize = 0,
};

fn valueAsString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn valueAsUsize(v: std.json.Value) ?usize {
    return switch (v) {
        .integer => |x| blk: {
            if (x < 0) break :blk null;
            break :blk @as(usize, @intCast(x));
        },
        else => null,
    };
}

fn putStringIfMissing(obj: *std.json.ObjectMap, key: []const u8, value: ?[]const u8) !bool {
    if (value == null) return false;
    if (obj.get(key) != null) return false;
    try obj.put(key, .{ .string = value.? });
    return true;
}

fn putIntegerIfMissing(obj: *std.json.ObjectMap, key: []const u8, value: ?usize) !bool {
    if (value == null) return false;
    if (obj.get(key) != null) return false;
    try obj.put(key, .{ .integer = @as(i64, @intCast(value.?)) });
    return true;
}

fn millisToIso(allocator: std.mem.Allocator, ms: i64) ![]const u8 {
    if (ms < 0) return error.InvalidTimestamp;
    const secs = @as(u64, @intCast(@divTrunc(ms, 1000)));
    const ms_part = @as(u16, @intCast(@mod(ms, 1000)));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return try std.fmt.allocPrint(
        allocator,
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

fn timestampToIsoIfMillis(allocator: std.mem.Allocator, v: std.json.Value) !?[]const u8 {
    switch (v) {
        .integer => |x| {
            if (x < 0) return null;
            return try millisToIso(allocator, x);
        },
        .string => |s| {
            if (s.len == 0) return null;
            for (s) |c| {
                if (c < '0' or c > '9') return null;
            }
            const ms = std.fmt.parseInt(i64, s, 10) catch return null;
            if (ms < 0) return null;
            return try millisToIso(allocator, ms);
        },
        else => return null,
    }
}

fn ensureUsageTotalTokens(
    allocator: std.mem.Allocator,
    msg_obj: *std.json.ObjectMap,
    usage_total_tokens: ?usize,
) !bool {
    if (usage_total_tokens == null) return false;

    if (msg_obj.getPtr("usage")) |usage_ptr| {
        switch (usage_ptr.*) {
            .object => |*usage_obj| {
                if (usage_obj.get("totalTokens") != null) return false;
                try usage_obj.put("totalTokens", .{ .integer = @as(i64, @intCast(usage_total_tokens.?)) });
                return true;
            },
            else => {},
        }
    }

    var usage_obj = std.json.ObjectMap.init(allocator);
    try usage_obj.put("totalTokens", .{ .integer = @as(i64, @intCast(usage_total_tokens.?)) });
    try msg_obj.put("usage", .{ .object = usage_obj });
    return true;
}

fn migrateMessageObject(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
) !bool {
    var changed = false;

    const role_top = if (obj.get("role")) |v| valueAsString(v) else null;
    const content_top = if (obj.get("content")) |v| valueAsString(v) else null;
    const usage_top = if (obj.get("usageTotalTokens")) |v| valueAsUsize(v) else null;
    const provider_top = if (obj.get("provider")) |v| valueAsString(v) else null;
    const model_top = if (obj.get("model")) |v| valueAsString(v) else null;

    var usage_nested: ?usize = null;
    var role_nested: ?[]const u8 = null;
    var content_nested: ?[]const u8 = null;
    var provider_nested: ?[]const u8 = null;
    var model_nested: ?[]const u8 = null;
    var has_message_object = false;
    if (obj.get("message")) |mv| switch (mv) {
        .object => |mobj| {
            has_message_object = true;
            role_nested = if (mobj.get("role")) |v| valueAsString(v) else null;
            content_nested = if (mobj.get("content")) |v| valueAsString(v) else null;
            provider_nested = if (mobj.get("provider")) |v| valueAsString(v) else null;
            model_nested = if (mobj.get("model")) |v| valueAsString(v) else null;
            if (mobj.get("usage")) |uv| switch (uv) {
                .object => |uobj| {
                    usage_nested = if (uobj.get("totalTokens")) |tv| valueAsUsize(tv) else null;
                },
                else => {},
            };
        },
        else => {},
    };

    const role = role_top orelse role_nested;
    const content = content_top orelse content_nested;
    const usage_total = usage_top orelse usage_nested;
    const provider = provider_top orelse provider_nested;
    const model = model_top orelse model_nested;

    if (try putStringIfMissing(obj, "role", role)) changed = true;
    if (try putStringIfMissing(obj, "content", content)) changed = true;
    if (try putStringIfMissing(obj, "provider", provider)) changed = true;
    if (try putStringIfMissing(obj, "model", model)) changed = true;
    if (try putIntegerIfMissing(obj, "usageTotalTokens", usage_total)) changed = true;

    if (has_message_object) {
        if (obj.get("message")) |mv| switch (mv) {
            .object => |mobj| {
                var msg_copy = std.json.ObjectMap.init(allocator);
                var it2 = mobj.iterator();
                while (it2.next()) |kv| {
                    try msg_copy.put(kv.key_ptr.*, kv.value_ptr.*);
                }

                var msg_changed = false;
                if (try putStringIfMissing(&msg_copy, "role", role)) msg_changed = true;
                if (try putStringIfMissing(&msg_copy, "content", content)) msg_changed = true;
                if (try putStringIfMissing(&msg_copy, "provider", provider)) msg_changed = true;
                if (try putStringIfMissing(&msg_copy, "model", model)) msg_changed = true;
                if (try ensureUsageTotalTokens(allocator, &msg_copy, usage_total)) msg_changed = true;

                if (msg_changed) {
                    try obj.put("message", .{ .object = msg_copy });
                    changed = true;
                }
            },
            else => {},
        };
    } else {
        var msg_obj = std.json.ObjectMap.init(allocator);
        if (role) |r| try msg_obj.put("role", .{ .string = r });
        if (content) |c| try msg_obj.put("content", .{ .string = c });
        if (provider) |p| try msg_obj.put("provider", .{ .string = p });
        if (model) |m| try msg_obj.put("model", .{ .string = m });
        _ = try ensureUsageTotalTokens(allocator, &msg_obj, usage_total);
        try obj.put("message", .{ .object = msg_obj });
        changed = true;
    }

    return changed;
}

fn migrateLeafObject(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    generated_counter: *usize,
) !bool {
    var changed = false;

    const target_id = if (obj.get("targetId")) |v| valueAsString(v) else null;
    if (obj.get("id") == null) {
        generated_counter.* += 1;
        const gen_id = try std.fmt.allocPrint(allocator, "leaf_migr_{d}_{d}", .{ std.time.milliTimestamp(), generated_counter.* });
        try obj.put("id", .{ .string = gen_id });
        changed = true;
    }
    if (obj.get("parentId") == null) {
        if (target_id) |tid| {
            try obj.put("parentId", .{ .string = tid });
        } else {
            try obj.put("parentId", .null);
        }
        changed = true;
    }
    return changed;
}

fn migrateLabelObject(
    obj: *std.json.ObjectMap,
    last_node_id: ?[]const u8,
) !bool {
    if (obj.get("parentId") != null) return false;
    if (last_node_id) |pid| {
        try obj.put("parentId", .{ .string = pid });
    } else {
        try obj.put("parentId", .null);
    }
    return true;
}

fn migrateSessionFile(
    allocator: std.mem.Allocator,
    session_path: []const u8,
    out_path: ?[]const u8,
    dry_run: bool,
) !SessionMigrateStats {
    var stable_arena = std.heap.ArenaAllocator.init(allocator);
    defer stable_arena.deinit();
    const stable_alloc = stable_arena.allocator();

    const raw = try readFileAlloc(allocator, session_path);
    var out = try std.ArrayList(u8).initCapacity(allocator, raw.len + 1024);
    defer out.deinit(allocator);

    var stats: SessionMigrateStats = .{};
    var last_node_id: ?[]const u8 = null;
    var generated_counter: usize = 0;

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        stats.totalLines += 1;

        var changed_line = false;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            stats.parseErrors += 1;
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            continue;
        };
        defer parsed.deinit();

        switch (parsed.value) {
            .object => |*obj| {
                const typ = if (obj.get("type")) |tv| valueAsString(tv) else null;
                if (obj.get("timestamp")) |tsv| {
                    if (try timestampToIsoIfMillis(allocator, tsv)) |iso_ts| {
                        try obj.put("timestamp", .{ .string = iso_ts });
                        changed_line = true;
                        stats.timestampChanged += 1;
                    }
                }
                if (typ) |t| {
                    if (std.mem.eql(u8, t, "session")) {
                        const v = if (obj.get("version")) |vv| valueAsUsize(vv) else null;
                        if (v == null or v.? < 3) {
                            try obj.put("version", .{ .integer = 3 });
                            changed_line = true;
                            stats.sessionChanged += 1;
                        }
                    } else if (std.mem.eql(u8, t, "message")) {
                        if (try migrateMessageObject(allocator, obj)) {
                            changed_line = true;
                            stats.messageChanged += 1;
                        }
                    } else if (std.mem.eql(u8, t, "leaf")) {
                        if (try migrateLeafObject(allocator, obj, &generated_counter)) {
                            changed_line = true;
                            stats.leafChanged += 1;
                        }
                    } else if (std.mem.eql(u8, t, "label")) {
                        if (try migrateLabelObject(obj, last_node_id)) {
                            changed_line = true;
                            stats.labelChanged += 1;
                        }
                    }

                    if (!std.mem.eql(u8, t, "session")) {
                        if (obj.get("id")) |idv| {
                            if (valueAsString(idv)) |id| {
                                last_node_id = try stable_alloc.dupe(u8, id);
                            }
                        }
                    }
                }
            },
            else => {},
        }

        if (changed_line) stats.changedLines += 1;
        const json_line = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
        try out.appendSlice(allocator, json_line);
        try out.append(allocator, '\n');
    }

    if (dry_run) return stats;

    const dst = out_path orelse session_path;
    if (out_path != null or stats.changedLines > 0) {
        var f = try std.fs.cwd().createFile(dst, .{ .truncate = true });
        defer f.close();
        try f.writeAll(out.items);
    }

    return stats;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    return try f.readToEndAlloc(allocator, stat.size);
}

fn parseJsonFile(arena: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
    const raw = try readFileAlloc(arena, path);
    // NOTE: raw is arena-owned, no free.
    return try std.json.parseFromSlice(std.json.Value, arena, raw, .{});
}

fn safeId(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        out[i] = if (ok) c else '_';
    }
    return out;
}

fn tokensEstFromChars(chars: usize) usize {
    // crude heuristic, good enough for MVP debug: ~4 chars per token
    return (chars + 3) / 4;
}

fn tokensEstForEntry(e: st.Entry) usize {
    return switch (e) {
        .message => |m| m.tokensEst orelse tokensEstFromChars(m.content.len),
        .custom_message => |cm| tokensEstFromChars(cm.content.len),
        // tool call/results tend to be denser / more verbose
        .tool_call => |tc| tc.tokensEst orelse (tokensEstFromChars(tc.arg.len) + 8),
        .tool_result => |tr| tr.tokensEst orelse (tokensEstFromChars(tr.content.len) + 8),
        .branch_summary => |b| tokensEstFromChars(b.summary.len),
        .turn_start => 2,
        .turn_end => 2,
        .thinking_level_change, .model_change => 0,
        .summary => |s| tokensEstFromChars(s.summary.len),
        else => 0,
    };
}

const BoundaryTokenEstimate = struct {
    tokens: usize,
    usageTokens: usize,
    trailingTokens: usize,
    lastUsageIndex: ?usize,
};

fn estimateBoundaryTokens(entries: []const st.Entry, boundary_from: usize) BoundaryTokenEstimate {
    var last_usage_idx: ?usize = null;
    var usage_tokens: usize = 0;

    var i: usize = boundary_from;
    while (i < entries.len) : (i += 1) {
        const e = entries[i];
        switch (e) {
            .message => |m| {
                if (std.mem.eql(u8, m.role, "assistant")) {
                    if (m.usageTotalTokens) |u| {
                        last_usage_idx = i;
                        usage_tokens = u;
                    }
                }
            },
            else => {},
        }
    }

    if (last_usage_idx == null) {
        var est: usize = 0;
        i = boundary_from;
        while (i < entries.len) : (i += 1) {
            est += tokensEstForEntry(entries[i]);
        }
        return .{
            .tokens = est,
            .usageTokens = 0,
            .trailingTokens = est,
            .lastUsageIndex = null,
        };
    }

    var trailing: usize = 0;
    i = last_usage_idx.? + 1;
    while (i < entries.len) : (i += 1) {
        trailing += tokensEstForEntry(entries[i]);
    }

    return .{
        .tokens = usage_tokens + trailing,
        .usageTokens = usage_tokens,
        .trailingTokens = trailing,
        .lastUsageIndex = last_usage_idx,
    };
}

const BranchSummaryFileOps = struct {
    readFiles: []const []const u8,
    modifiedFiles: []const []const u8,
};

const ShellFileOps = struct {
    fn trimToken(tok0: []const u8) []const u8 {
        var tok = tok0;
        tok = std.mem.trim(u8, tok, " \t\r\n");
        tok = std.mem.trim(u8, tok, "\"'");
        return tok;
    }

    fn looksLikePath(tok: []const u8) bool {
        if (tok.len == 0) return false;
        if (tok[0] == '-') return false;
        if (std.mem.indexOfScalar(u8, tok, '|') != null) return false;
        if (std.mem.indexOfScalar(u8, tok, ';') != null) return false;
        if (std.mem.indexOfScalar(u8, tok, '&') != null) return false;
        if (std.mem.indexOfScalar(u8, tok, '$') != null) return false;
        if (std.mem.indexOf(u8, tok, "..") != null and tok.len <= 2) return false;

        if (std.mem.indexOfScalar(u8, tok, '/') != null) return true;
        const exts = [_][]const u8{ ".zig", ".md", ".json", ".txt", ".service", ".ts", ".js", ".mjs", ".yaml", ".yml" };
        for (exts) |e| if (std.mem.endsWith(u8, tok, e)) return true;
        return false;
    }

    fn addUnique(
        alloc: std.mem.Allocator,
        list: *std.ArrayList([]const u8),
        seen: *std.StringHashMap(bool),
        tok: []const u8,
        cap: usize,
    ) void {
        if (tok.len == 0) return;
        if (list.items.len >= cap) return;
        if (seen.contains(tok)) return;
        seen.put(tok, true) catch return;
        list.append(alloc, tok) catch return;
    }

    fn appendFromArray(
        alloc: std.mem.Allocator,
        list: *std.ArrayList([]const u8),
        seen: *std.StringHashMap(bool),
        arr: std.json.Array,
        cap: usize,
    ) void {
        for (arr.items) |v_it| {
            switch (v_it) {
                .string => |s| addUnique(alloc, list, seen, s, cap),
                else => {},
            }
        }
    }

    fn collectDetails(
        alloc: std.mem.Allocator,
        details_json: []const u8,
        read_files: *std.ArrayList([]const u8),
        modified_files: *std.ArrayList([]const u8),
        seen_rf: *std.StringHashMap(bool),
        seen_mf: *std.StringHashMap(bool),
    ) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, details_json, .{}) catch return;
        defer parsed.deinit();

        var obj: ?std.json.ObjectMap = null;
        switch (parsed.value) {
            .object => |o| obj = o,
            .string => |s| {
                var inner = std.json.parseFromSlice(std.json.Value, alloc, s, .{}) catch return;
                defer inner.deinit();
                switch (inner.value) {
                    .object => |o| obj = o,
                    else => return,
                }
            },
            else => return,
        }
        const details_obj = obj orelse return;

        if (details_obj.get("readFiles")) |v| switch (v) {
            .array => |a| appendFromArray(alloc, read_files, seen_rf, a, 200),
            else => {},
        };
        if (details_obj.get("modifiedFiles")) |v| switch (v) {
            .array => |a| appendFromArray(alloc, modified_files, seen_mf, a, 200),
            else => {},
        };
    }

    fn scanShell(
        alloc: std.mem.Allocator,
        arg: []const u8,
        rf: *std.ArrayList([]const u8),
        mf: *std.ArrayList([]const u8),
        seen_rf_map: *std.StringHashMap(bool),
        seen_mf_map: *std.StringHashMap(bool),
    ) void {
        const is_modify = (std.mem.indexOf(u8, arg, ">") != null) or
            (std.mem.indexOf(u8, arg, "sed -i") != null) or
            (std.mem.indexOf(u8, arg, "perl -pi") != null) or
            (std.mem.indexOf(u8, arg, "apply") != null) or
            (std.mem.indexOf(u8, arg, "git commit") != null) or
            (std.mem.indexOf(u8, arg, "git add") != null) or
            (std.mem.indexOf(u8, arg, "mv ") != null) or
            (std.mem.indexOf(u8, arg, "cp ") != null) or
            (std.mem.indexOf(u8, arg, "touch ") != null) or
            (std.mem.indexOf(u8, arg, "tee ") != null);

        const is_read = (std.mem.indexOf(u8, arg, "cat ") != null) or
            (std.mem.indexOf(u8, arg, "sed -n") != null) or
            (std.mem.indexOf(u8, arg, "grep ") != null) or
            (std.mem.indexOf(u8, arg, "head ") != null) or
            (std.mem.indexOf(u8, arg, "tail ") != null) or
            (std.mem.indexOf(u8, arg, "less ") != null) or
            (std.mem.indexOf(u8, arg, "git show") != null) or
            (std.mem.indexOf(u8, arg, "git diff") != null) or
            (std.mem.indexOf(u8, arg, "git status") != null);

        {
            if (std.mem.indexOfScalar(u8, arg, '>')) |pos| {
                var last = pos;
                var j: usize = pos + 1;
                while (j < arg.len) : (j += 1) {
                    if (arg[j] == '>') last = j;
                }
                const rhs = arg[last + 1 ..];
                var it2 = std.mem.tokenizeAny(u8, rhs, " \t\r\n");
                if (it2.next()) |t0| {
                    const t = trimToken(t0);
                    if (looksLikePath(t)) {
                        addUnique(alloc, mf, seen_mf_map, t, 200);
                    }
                }
            }

            if (std.mem.indexOf(u8, arg, "tee ")) |pos2| {
                const rhs = arg[pos2 + 4 ..];
                var it3 = std.mem.tokenizeAny(u8, rhs, " \t\r\n");
                while (it3.next()) |t0| {
                    const t = trimToken(t0);
                    if (t.len == 0) continue;
                    if (t[0] == '-') continue;
                    if (!looksLikePath(t)) break;
                    addUnique(alloc, mf, seen_mf_map, t, 200);
                    break;
                }
            }
        }

        var it = std.mem.tokenizeAny(u8, arg, " \t\r\n");
        while (it.next()) |t0| {
            const t = trimToken(t0);
            if (!looksLikePath(t)) continue;

            if (std.mem.eql(u8, t, "git") or
                std.mem.eql(u8, t, "rg") or
                std.mem.eql(u8, t, "grep") or
                std.mem.eql(u8, t, "sed") or
                std.mem.eql(u8, t, "cat") or
                std.mem.eql(u8, t, "sh"))
            {
                continue;
            }

            if (is_modify) {
                addUnique(alloc, mf, seen_mf_map, t, 200);
            } else if (is_read) {
                addUnique(alloc, rf, seen_rf_map, t, 200);
            } else {
                addUnique(alloc, rf, seen_rf_map, t, 200);
            }
        }
    }
};

fn collectAbandonedEntries(
    allocator: std.mem.Allocator,
    sm: *session.SessionManager,
    old_leaf: ?[]const u8,
    target: ?[]const u8,
) ![]const st.Entry {
    var by_id = std.StringHashMap(st.Entry).init(allocator);
    defer by_id.deinit();

    const entries = try sm.loadEntries();
    for (entries) |e| {
        if (st.idOf(e)) |id| {
            try by_id.put(id, e);
        }
    }

    var target_ancestors = std.StringHashMap(bool).init(allocator);
    defer target_ancestors.deinit();

    var cur_t = target;
    while (cur_t) |cid| {
        try target_ancestors.put(cid, true);
        const e = by_id.get(cid) orelse break;
        cur_t = st.parentIdOf(e);
    }

    var abandoned = try std.ArrayList(st.Entry).initCapacity(allocator, 0);
    var cur = old_leaf;
    while (cur) |cid| {
        if (target_ancestors.contains(cid)) break;
        const e = by_id.get(cid) orelse break;
        try abandoned.append(allocator, e);
        cur = st.parentIdOf(e);
    }

    return try abandoned.toOwnedSlice(allocator);
}

fn collectBranchSummaryFileOps(
    allocator: std.mem.Allocator,
    entries: []const st.Entry,
) !BranchSummaryFileOps {
    var read_files_out = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer read_files_out.deinit(allocator);
    var modified_files_out = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer modified_files_out.deinit(allocator);

    var seen_rf = std.StringHashMap(bool).init(allocator);
    defer seen_rf.deinit();
    var seen_mf = std.StringHashMap(bool).init(allocator);
    defer seen_mf.deinit();

    for (entries) |e| {
        switch (e) {
            .tool_call => |tc| {
                if (std.mem.eql(u8, tc.tool, "shell")) {
                    ShellFileOps.scanShell(
                        allocator,
                        tc.arg,
                        &read_files_out,
                        &modified_files_out,
                        &seen_rf,
                        &seen_mf,
                    );
                }
            },
            .summary => |s| {
                if (s.fromHook != true) {
                    if (s.readFiles) |rf| {
                        for (rf) |p| ShellFileOps.addUnique(allocator, &read_files_out, &seen_rf, p, 200);
                    }
                    if (s.modifiedFiles) |mf| {
                        for (mf) |p| ShellFileOps.addUnique(allocator, &modified_files_out, &seen_mf, p, 200);
                    }
                    if (s.detailsJson) |dj| try ShellFileOps.collectDetails(
                        allocator,
                        dj,
                        &read_files_out,
                        &modified_files_out,
                        &seen_rf,
                        &seen_mf,
                    );
                }
            },
            .branch_summary => |b| {
                if (b.fromHook != true) {
                    if (b.detailsJson) |dj| try ShellFileOps.collectDetails(
                        allocator,
                        dj,
                        &read_files_out,
                        &modified_files_out,
                        &seen_rf,
                        &seen_mf,
                    );
                }
            },
            else => {},
        }
    }

    const read_files = try read_files_out.toOwnedSlice(allocator);
    const modified_files = try modified_files_out.toOwnedSlice(allocator);

    return .{ .readFiles = read_files, .modifiedFiles = modified_files };
}

fn appendJsonEscapedString(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
) !void {
    try out.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x00...0x07, 0x0b...0x0c, 0x0e...0x1f => {
                try out.appendSlice(allocator, "\\u00");
                var hex_buf: [2]u8 = undefined;
                const hex = try std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{ch});
                try out.appendSlice(allocator, hex);
            },
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
}

fn appendJsonStringArray(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    values: []const []const u8,
) !void {
    try out.append(allocator, '[');
    var i: usize = 0;
    while (i < values.len) : (i += 1) {
        if (i > 0) try out.appendSlice(allocator, ",");
        try appendJsonEscapedString(allocator, out, values[i]);
    }
    try out.append(allocator, ']');
}

fn branchSummaryDetailsJson(
    allocator: std.mem.Allocator,
    read_files: []const []const u8,
    modified_files: []const []const u8,
) !?[]const u8 {
    if (read_files.len == 0 and modified_files.len == 0) return null;

    var details_out = try std.ArrayList(u8).initCapacity(allocator, 128);
    try details_out.append(allocator, '{');

    var first = true;
    if (read_files.len > 0) {
        if (!first) try details_out.appendSlice(allocator, ",");
        try details_out.appendSlice(allocator, "\"readFiles\":");
        try appendJsonStringArray(allocator, &details_out, read_files);
        first = false;
    }
    if (modified_files.len > 0) {
        if (!first) try details_out.appendSlice(allocator, ",");
        try details_out.appendSlice(allocator, "\"modifiedFiles\":");
        try appendJsonStringArray(allocator, &details_out, modified_files);
    }

    try details_out.append(allocator, '}');
    return try details_out.toOwnedSlice(allocator);
}

fn buildAutoBranchSummaryFromEntries(
    allocator: std.mem.Allocator,
    old_leaf: ?[]const u8,
    target: ?[]const u8,
    abandoned: []const st.Entry,
) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "## Goal\n");
    try out.appendSlice(allocator, "Branch from ");
    try out.appendSlice(allocator, old_leaf orelse "root");
    try out.appendSlice(allocator, " to ");
    try out.appendSlice(allocator, target orelse "root");
    try out.appendSlice(allocator, ".\n\n");

    try out.appendSlice(allocator, "## Progress\n");
    if (abandoned.len == 0) {
        try out.appendSlice(allocator, "- (none)\n");
    } else {
        var written: usize = 0;
        var i: usize = abandoned.len;
        while (i > 0 and written < 8) : (i -= 1) {
            const e = abandoned[i - 1];
            switch (e) {
                .message => |m| {
                    const preview = if (m.content.len > 80) m.content[0..80] else m.content;
                    try out.appendSlice(allocator, "- ");
                    try out.appendSlice(allocator, m.role);
                    try out.appendSlice(allocator, ": ");
                    try out.appendSlice(allocator, preview);
                    try out.appendSlice(allocator, "\n");
                    written += 1;
                },
                .tool_call => |tc| {
                    try out.appendSlice(allocator, "- tool_call ");
                    try out.appendSlice(allocator, tc.tool);
                    try out.appendSlice(allocator, "\n");
                    written += 1;
                },
                .tool_result => |tr| {
                    try out.appendSlice(allocator, "- tool_result ");
                    try out.appendSlice(allocator, tr.tool);
                    try out.appendSlice(allocator, ": ");
                    try out.appendSlice(allocator, if (tr.ok) "ok" else "error");
                    try out.appendSlice(allocator, "\n");
                    written += 1;
                },
                .summary => {
                    try out.appendSlice(allocator, "- (had compacted history)\n");
                    written += 1;
                },
                .branch_summary => {
                    try out.appendSlice(allocator, "- (had previous branch summary)\n");
                    written += 1;
                },
                else => {},
            }
        }
        if (written == 0) {
            try out.appendSlice(allocator, "- (none)\n");
        }
    }

    try out.appendSlice(allocator, "\n## Next Steps\n");
    try out.appendSlice(allocator, "1. Continue from the selected branch point using this summary as context.\n");

    return try out.toOwnedSlice(allocator);
}

fn buildAutoBranchSummary(
    allocator: std.mem.Allocator,
    sm: *session.SessionManager,
    old_leaf: ?[]const u8,
    target: ?[]const u8,
) ![]const u8 {
    const abandoned = try collectAbandonedEntries(allocator, sm, old_leaf, target);
    return try buildAutoBranchSummaryFromEntries(allocator, old_leaf, target, abandoned);
}

fn doCompact(
    allocator: std.mem.Allocator,
    sm: *session.SessionManager,
    keep_last: usize,
    keep_last_groups: ?usize,
    dry_run: bool,
    label: ?[]const u8,
    prefix: []const u8,
    reason: ?[]const u8,
    stats_total_chars: ?usize,
    stats_total_tokens_est: ?usize,
    stats_threshold_chars: ?usize,
    stats_threshold_tokens_est: ?usize,
    update_summary: bool,
) !struct { dryRun: bool, summaryText: []const u8, summaryId: ?[]const u8 } {
    // Use verbose context for compaction so we can see turn boundaries.
    const chain = try sm.buildContextEntriesVerbose();

    var nodes = try std.ArrayList(st.Entry).initCapacity(allocator, chain.len);
    defer nodes.deinit(allocator);
    for (chain) |e| {
        switch (e) {
            .session, .leaf, .label => {},
            else => try nodes.append(allocator, e),
        }
    }

    const n = nodes.items.len;

    // TS parity: define a compaction "boundary" starting AFTER the most recent summary entry.
    // We only decide cutpoints within this window (older content is already summarized).
    var boundary_from: usize = 0;
    {
        var k: usize = n;
        while (k > 0) : (k -= 1) {
            const e = nodes.items[k - 1];
            switch (e) {
                .summary => {
                    boundary_from = k;
                    break;
                },
                else => {},
            }
        }
    }

    // Choose cut start.
    // Keep_last is interpreted relative to the full leaf context, but we never cut before boundary_from.
    var start: usize = if (n > keep_last) n - keep_last else boundary_from;
    if (start < boundary_from) start = boundary_from;
    const start_initial: usize = start;

    if (keep_last_groups) |kg| {
        // Keep the last N complete turn-groups (best-effort), within the boundary window.
        // Example: kg=1 => keep last group => boundary is the END of the previous group (count == kg+1).
        var count: usize = 0;
        var idx: usize = n;
        while (idx > boundary_from) : (idx -= 1) {
            const e = nodes.items[idx - 1];
            switch (e) {
                .turn_end => |te| {
                    if (te.phase) |ph| {
                        if (std.mem.eql(u8, ph, "final") or std.mem.eql(u8, ph, "error")) {
                            count += 1;
                            if (count == kg + 1) {
                                start = idx; // start AFTER the previous group's end
                                break;
                            }
                        }
                    }
                },
                else => {},
            }
        }
        // If there aren't enough groups to skip within boundary, keep everything since boundary.
        if (count <= kg) start = boundary_from;
        if (start > n) start = n;
    }

    // TS-ish compaction cut alignment:
    // 1) Avoid starting the kept tail with a tool_result (which would split tool_call/tool_result pairs).
    while (start > boundary_from and start < n) {
        const e = nodes.items[start];
        switch (e) {
            .tool_result => start -= 1,
            else => break,
        }
    }

    // Turn-group boundary: move start backwards until it is immediately AFTER a persisted turn_end
    // that represents the end of a complete group (phase="final"|"error").
    // This avoids splitting multi-step turns that share the same turnGroupId.
    while (start > boundary_from) {
        const prev = nodes.items[start - 1];
        switch (prev) {
            .turn_end => |te| {
                if (te.phase) |ph| {
                    if (std.mem.eql(u8, ph, "final") or std.mem.eql(u8, ph, "error")) {
                        // If the tail would start with the same group, keep searching backwards.
                        const this_gid = te.turnGroupId;
                        if (this_gid != null and start < n) {
                            const first = nodes.items[start];
                            switch (first) {
                                .turn_start => |ts| {
                                    if (ts.turnGroupId != null and std.mem.eql(u8, ts.turnGroupId.?, this_gid.?)) {
                                        start -= 1;
                                        continue;
                                    }
                                },
                                else => {},
                            }
                        }
                        break;
                    }
                }
                start -= 1;
            },
            else => start -= 1,
        }
    }

    // TS parity: split-turn handling.
    // If our boundary-alignment forces `start` back to the boundary edge (meaning we can't keep
    // as much tail as intended without splitting a turn-group), we allow a cut INSIDE the turn.
    // This matches TS's "split-turn" mode (prefix summarized separately).
    const start_intended: usize = start_initial;

    if (start == boundary_from and start_intended > boundary_from) {
        // Allow cutting inside a turn. Use the intended boundary (with the same tool_result guard).
        start = start_intended;
        while (start > boundary_from and start < n) {
            const e = nodes.items[start];
            switch (e) {
                .tool_result => start -= 1,
                else => break,
            }
        }
        if (start < boundary_from) start = boundary_from;
    }

    // General TS behavior: if the cutpoint lands mid-turn, summarize the turn prefix separately.
    var split_turn: bool = false;
    var split_history_end: usize = start; // history summarized by the main structured summary
    var split_prefix_start: usize = start; // prefix-of-turn summarized by special block
    var split_prefix_end: usize = start; // == cutpoint

    // Find the most recent complete group end (turn_end final/error) before `start`.
    var last_group_end: ?usize = null;
    {
        var k: usize = start;
        while (k > boundary_from) : (k -= 1) {
            const e = nodes.items[k - 1];
            switch (e) {
                .turn_end => |te| {
                    if (te.phase) |ph| {
                        if (std.mem.eql(u8, ph, "final") or std.mem.eql(u8, ph, "error")) {
                            last_group_end = k - 1;
                            break;
                        }
                    }
                },
                else => {},
            }
        }
    }

    // Find the most recent turn_start before `start`.
    var last_turn_start: ?usize = null;
    {
        var k: usize = start;
        while (k > boundary_from) : (k -= 1) {
            const e = nodes.items[k - 1];
            switch (e) {
                .turn_start => {
                    last_turn_start = k - 1;
                    break;
                },
                else => {},
            }
        }
    }

    if (last_turn_start) |ts_i| {
        const is_mid_turn = (last_group_end == null) or (last_group_end.? < ts_i);
        if (is_mid_turn and ts_i < start) {
            split_turn = true;
            split_history_end = ts_i;
            split_prefix_start = ts_i;
            split_prefix_end = start;
        }
    }

    var sum_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer sum_buf.deinit(allocator);

    const want_json = std.mem.eql(u8, prefix, "SUMMARY_JSON");
    const want_md = std.mem.eql(u8, prefix, "SUMMARY_MD");

    // TS-style file ops tracking (best-effort). We infer these from tool_call(shell) args.
    var read_files_out = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer read_files_out.deinit(allocator);
    var modified_files_out = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer modified_files_out.deinit(allocator);
    var seen_rf = std.StringHashMap(bool).init(allocator);
    defer seen_rf.deinit();
    var seen_mf = std.StringHashMap(bool).init(allocator);
    defer seen_mf.deinit();

    const FileOps = struct {
        fn trimToken(tok0: []const u8) []const u8 {
            var tok = tok0;
            tok = std.mem.trim(u8, tok, " \t\r\n");
            tok = std.mem.trim(u8, tok, "\"'");
            return tok;
        }

        fn looksLikePath(tok: []const u8) bool {
            if (tok.len == 0) return false;
            if (tok[0] == '-') return false;
            if (std.mem.indexOfScalar(u8, tok, '|') != null) return false;
            if (std.mem.indexOfScalar(u8, tok, ';') != null) return false;
            if (std.mem.indexOfScalar(u8, tok, '&') != null) return false;
            if (std.mem.indexOfScalar(u8, tok, '$') != null) return false;
            if (std.mem.indexOf(u8, tok, "..") != null and tok.len <= 2) return false;

            if (std.mem.indexOfScalar(u8, tok, '/') != null) return true;
            // common file extensions
            const exts = [_][]const u8{ ".zig", ".md", ".json", ".txt", ".service", ".ts", ".js", ".mjs", ".yaml", ".yml" };
            for (exts) |e| if (std.mem.endsWith(u8, tok, e)) return true;
            return false;
        }

        fn addUnique(
            alloc: std.mem.Allocator,
            list: *std.ArrayList([]const u8),
            seen: *std.StringHashMap(bool),
            tok: []const u8,
            cap: usize,
        ) void {
            if (tok.len == 0) return;
            if (list.items.len >= cap) return;
            if (seen.contains(tok)) return;
            seen.put(tok, true) catch return;
            list.append(alloc, tok) catch return;
        }

        fn scanShell(
            alloc: std.mem.Allocator,
            arg: []const u8,
            rf: *std.ArrayList([]const u8),
            mf: *std.ArrayList([]const u8),
            seen_rf_map: *std.StringHashMap(bool),
            seen_mf_map: *std.StringHashMap(bool),
        ) void {
            const is_modify = (std.mem.indexOf(u8, arg, ">") != null) or
                (std.mem.indexOf(u8, arg, "sed -i") != null) or
                (std.mem.indexOf(u8, arg, "perl -pi") != null) or
                (std.mem.indexOf(u8, arg, "apply") != null) or
                (std.mem.indexOf(u8, arg, "git commit") != null) or
                (std.mem.indexOf(u8, arg, "git add") != null) or
                (std.mem.indexOf(u8, arg, "mv ") != null) or
                (std.mem.indexOf(u8, arg, "cp ") != null) or
                (std.mem.indexOf(u8, arg, "touch ") != null) or
                (std.mem.indexOf(u8, arg, "tee ") != null);

            const is_read = (std.mem.indexOf(u8, arg, "cat ") != null) or
                (std.mem.indexOf(u8, arg, "sed -n") != null) or
                (std.mem.indexOf(u8, arg, "rg ") != null) or
                (std.mem.indexOf(u8, arg, "grep ") != null) or
                (std.mem.indexOf(u8, arg, "head ") != null) or
                (std.mem.indexOf(u8, arg, "tail ") != null) or
                (std.mem.indexOf(u8, arg, "less ") != null) or
                (std.mem.indexOf(u8, arg, "git show") != null) or
                (std.mem.indexOf(u8, arg, "git diff") != null) or
                (std.mem.indexOf(u8, arg, "git status") != null);

            // Prefer explicit "redirection" targets if present.
            //   cmd > out.txt
            //   cmd >> out.txt
            //   ... | tee out.txt
            // This is intentionally shallow parsing (no quoting/escaping rules).
            {
                if (std.mem.indexOfScalar(u8, arg, '>')) |pos| {
                    // take token immediately after the last '>'
                    var last = pos;
                    var j: usize = pos + 1;
                    while (j < arg.len) : (j += 1) {
                        if (arg[j] == '>') last = j;
                    }
                    const rhs = arg[last + 1 ..];
                    var it2 = std.mem.tokenizeAny(u8, rhs, " \t\r\n");
                    if (it2.next()) |t0| {
                        const t = trimToken(t0);
                        if (looksLikePath(t)) {
                            const duped = alloc.dupe(u8, t) catch return;
                            addUnique(alloc, mf, seen_mf_map, duped, 200);
                        }
                    }
                }

                if (std.mem.indexOf(u8, arg, "tee ")) |pos2| {
                    const rhs = arg[pos2 + 4 ..];
                    var it3 = std.mem.tokenizeAny(u8, rhs, " \t\r\n");
                    // skip tee options like -a
                    while (it3.next()) |t0| {
                        const t = trimToken(t0);
                        if (t.len == 0) continue;
                        if (t[0] == '-') continue;
                        if (!looksLikePath(t)) break;
                        const duped = alloc.dupe(u8, t) catch break;
                        addUnique(alloc, mf, seen_mf_map, duped, 200);
                        break;
                    }
                }
            }

            // Tokenize and collect path-like tokens.
            var it = std.mem.tokenizeAny(u8, arg, " \t\r\n");
            while (it.next()) |t0| {
                const t = trimToken(t0);
                if (!looksLikePath(t)) continue;

                // Skip obvious executables and git subcommands.
                if (std.mem.eql(u8, t, "git") or std.mem.eql(u8, t, "rg") or std.mem.eql(u8, t, "grep") or std.mem.eql(u8, t, "sed") or std.mem.eql(u8, t, "cat") or std.mem.eql(u8, t, "sh")) continue;

                const duped = alloc.dupe(u8, t) catch continue;
                if (is_modify) {
                    addUnique(alloc, mf, seen_mf_map, duped, 200);
                } else if (is_read) {
                    addUnique(alloc, rf, seen_rf_map, duped, 200);
                } else {
                    // Unknown intent: treat as read by default.
                    addUnique(alloc, rf, seen_rf_map, duped, 200);
                }
            }
        }
    };

    // Infer file ops from the portion we are summarizing (boundary_from..summarize_end).
    const summarize_end_common: usize = if (split_turn) split_history_end else start;
    var fi: usize = boundary_from;
    while (fi < summarize_end_common) : (fi += 1) {
        const e = nodes.items[fi];
        switch (e) {
            .tool_call => |tc| {
                if (std.mem.eql(u8, tc.tool, "shell")) {
                    FileOps.scanShell(allocator, tc.arg, &read_files_out, &modified_files_out, &seen_rf, &seen_mf);
                }
            },
            else => {},
        }
    }

    // TS parity: inherit file ops from the most recent previous summary.
    // This matches TS compaction details carry-forward behavior.
    {
        var k: usize = boundary_from;
        var prev: ?st.SummaryEntry = null;
        while (k > 0) : (k -= 1) {
            const e = nodes.items[k - 1];
            switch (e) {
                .summary => |s| {
                    prev = s;
                    break;
                },
                else => {},
            }
        }

        if (prev) |ps| {
            if (ps.readFiles) |rf0| {
                for (rf0) |p| {
                    if (read_files_out.items.len >= 200) break;
                    if (seen_rf.contains(p)) continue;
                    try seen_rf.put(p, true);
                    try read_files_out.append(allocator, p);
                }
            }
            if (ps.modifiedFiles) |mf0| {
                for (mf0) |p| {
                    if (modified_files_out.items.len >= 200) break;
                    if (seen_mf.contains(p)) continue;
                    try seen_mf.put(p, true);
                    try modified_files_out.append(allocator, p);
                }
            }
        }
    }

    if (!want_json and !want_md) {
        try sum_buf.appendSlice(allocator, prefix);

        var i: usize = 0;
        while (i < start) : (i += 1) {
            const e = nodes.items[i];
            switch (e) {
                .message => |m| {
                    if (std.mem.eql(u8, m.role, "user") or std.mem.eql(u8, m.role, "assistant")) {
                        const preview = if (m.content.len > 80) m.content[0..80] else m.content;
                        try sum_buf.appendSlice(allocator, m.role);
                        try sum_buf.appendSlice(allocator, ": ");
                        try sum_buf.appendSlice(allocator, preview);
                        try sum_buf.appendSlice(allocator, "\n");
                    }
                },
                else => {},
            }
        }
    } else if (want_json) {
        // Structured JSON summary (TS-ish): can also update/merge a previous JSON summary.

        const Progress = struct {
            done: []const []const u8,
            in_progress: []const []const u8,
            blocked: []const []const u8, // human-readable blocked reasons
        };
        const BlockedTask = struct {
            task: []const u8,
            tool: ?[]const u8 = null,
            arg: ?[]const u8 = null,
            err: ?[]const u8 = null,
        };

        const DoneTask = struct {
            task: []const u8,
            tool: ?[]const u8 = null,
            arg: ?[]const u8 = null,
            result: ?[]const u8 = null,
        };

        const NextStepTask = struct {
            task: []const u8,
            why: ?[]const u8 = null,
            priority: ?u32 = null,
        };

        const InProgressTask = struct {
            task: []const u8,
            source: ?[]const u8 = null, // e.g. "next_steps"
        };

        const Payload = struct {
            schema: []const u8,
            goal: []const u8,
            constraints: []const []const u8,
            progress: Progress,
            key_decisions: []const []const u8,
            next_steps: []const []const u8, // derived view (kept for compatibility)
            critical_context: []const []const u8,
            blocked_tasks: []const BlockedTask, // structured blocked tasks (used for migration)
            done_tasks: []const DoneTask, // structured done tasks (used for migration)
            in_progress_tasks: []const InProgressTask, // structured in-progress tasks (used for migration)
            next_step_tasks: []const NextStepTask, // structured next steps (source-of-truth)
            raw: []const u8,
        };

        // Find previous json summary if update_summary is enabled.
        var prev_payload: ?Payload = null;
        var prev_idx: ?usize = null;
        if (update_summary) {
            var k: usize = start;
            while (k > 0) : (k -= 1) {
                const e = nodes.items[k - 1];
                switch (e) {
                    .summary => |s| {
                        if (std.mem.eql(u8, s.format, "json")) {
                            prev_idx = k - 1;
                            // Parse payload; if invalid, fall back to fresh.
                            const parsed = std.json.parseFromSlice(std.json.Value, allocator, s.summary, .{}) catch break;
                            defer parsed.deinit();
                            const obj = switch (parsed.value) {
                                .object => |o| o,
                                else => break,
                            };

                            const dupStr = struct {
                                fn dup(a: std.mem.Allocator, t: []const u8) ![]const u8 {
                                    return try a.dupe(u8, t);
                                }
                            };

                            const schema = if (obj.get("schema")) |v| switch (v) {
                                .string => |t| try dupStr.dup(allocator, t),
                                else => "pi.summary.v6",
                            } else "pi.summary.v6";
                            const goal = if (obj.get("goal")) |v| switch (v) {
                                .string => |t| try dupStr.dup(allocator, t),
                                else => "(unknown)",
                            } else "(unknown)";

                            const constraints_val = if (obj.get("constraints")) |v| v else null;
                            var constraints_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                            if (constraints_val) |cv| {
                                switch (cv) {
                                    .array => |a| for (a.items) |it| {
                                        if (it == .string) try constraints_list.append(allocator, try dupStr.dup(allocator, it.string));
                                    },
                                    else => {},
                                }
                            }

                            const kd_val = if (obj.get("key_decisions")) |v| v else null;
                            var kd_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                            if (kd_val) |kv| {
                                switch (kv) {
                                    .array => |a| for (a.items) |it| {
                                        if (it == .string) try kd_list.append(allocator, try dupStr.dup(allocator, it.string));
                                    },
                                    else => {},
                                }
                            }

                            const ns_val = if (obj.get("next_steps")) |v| v else null;
                            var ns_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                            if (ns_val) |nv| {
                                switch (nv) {
                                    .array => |a| for (a.items) |it| {
                                        if (it == .string) try ns_list.append(allocator, try dupStr.dup(allocator, it.string));
                                    },
                                    else => {},
                                }
                            }

                            const cc_val = if (obj.get("critical_context")) |v| v else null;
                            var cc_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                            if (cc_val) |cv| {
                                switch (cv) {
                                    .array => |a| for (a.items) |it| {
                                        if (it == .string) try cc_list.append(allocator, try dupStr.dup(allocator, it.string));
                                    },
                                    else => {},
                                }
                            }

                            var done_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                            var ip_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                            var blocked_list = try std.ArrayList([]const u8).initCapacity(allocator, 0);
                            if (obj.get("progress")) |pv| {
                                switch (pv) {
                                    .object => |po| {
                                        if (po.get("done")) |dv| switch (dv) {
                                            .array => |a| for (a.items) |it| if (it == .string) try done_list.append(allocator, try dupStr.dup(allocator, it.string)),
                                            else => {},
                                        };
                                        if (po.get("in_progress")) |iv| switch (iv) {
                                            .array => |a| for (a.items) |it| if (it == .string) try ip_list.append(allocator, try dupStr.dup(allocator, it.string)),
                                            else => {},
                                        };
                                        if (po.get("blocked")) |bv| switch (bv) {
                                            .array => |a| for (a.items) |it| if (it == .string) try blocked_list.append(allocator, try dupStr.dup(allocator, it.string)),
                                            else => {},
                                        };
                                    },
                                    else => {},
                                }
                            }

                            const raw = if (obj.get("raw")) |v| switch (v) {
                                .string => |t| try dupStr.dup(allocator, t),
                                else => "",
                            } else "";

                            const bt_val = if (obj.get("blocked_tasks")) |v| v else null;
                            var bt_list = try std.ArrayList(BlockedTask).initCapacity(allocator, 0);
                            if (bt_val) |bv| {
                                switch (bv) {
                                    .array => |a| for (a.items) |it| {
                                        switch (it) {
                                            .string => {
                                                // v2 compatibility: blocked_tasks: ["sh: ...", ...]
                                                try bt_list.append(allocator, .{ .task = try dupStr.dup(allocator, it.string) });
                                            },
                                            .object => |o| {
                                                const task0 = if (o.get("task")) |v| switch (v) {
                                                    .string => |t| t,
                                                    else => "",
                                                } else "";
                                                if (task0.len == 0) continue;
                                                const tool0 = if (o.get("tool")) |v| switch (v) {
                                                    .string => |t| @as(?[]const u8, t),
                                                    else => null,
                                                } else null;
                                                const arg0 = if (o.get("arg")) |v| switch (v) {
                                                    .string => |t| @as(?[]const u8, t),
                                                    else => null,
                                                } else null;
                                                const err0 = if (o.get("err")) |v| switch (v) {
                                                    .string => |t| @as(?[]const u8, t),
                                                    else => null,
                                                } else null;

                                                try bt_list.append(allocator, .{
                                                    .task = try dupStr.dup(allocator, task0),
                                                    .tool = if (tool0) |t| try dupStr.dup(allocator, t) else null,
                                                    .arg = if (arg0) |t| try dupStr.dup(allocator, t) else null,
                                                    .err = if (err0) |t| try dupStr.dup(allocator, t) else null,
                                                });
                                            },
                                            else => {},
                                        }
                                    },
                                    else => {},
                                }
                            }

                            // done_tasks
                            const dt_val = if (obj.get("done_tasks")) |v| v else null;
                            var dt_list = try std.ArrayList(DoneTask).initCapacity(allocator, 0);
                            if (dt_val) |dv| {
                                switch (dv) {
                                    .array => |a| for (a.items) |it| {
                                        switch (it) {
                                            .string => {
                                                try dt_list.append(allocator, .{ .task = try dupStr.dup(allocator, it.string) });
                                            },
                                            .object => |o| {
                                                const task0 = if (o.get("task")) |v| switch (v) {
                                                    .string => |t| t,
                                                    else => "",
                                                } else "";
                                                if (task0.len == 0) continue;
                                                const tool0 = if (o.get("tool")) |v| switch (v) {
                                                    .string => |t| @as(?[]const u8, t),
                                                    else => null,
                                                } else null;
                                                const arg0 = if (o.get("arg")) |v| switch (v) {
                                                    .string => |t| @as(?[]const u8, t),
                                                    else => null,
                                                } else null;
                                                const res0 = if (o.get("result")) |v| switch (v) {
                                                    .string => |t| @as(?[]const u8, t),
                                                    else => null,
                                                } else null;
                                                try dt_list.append(allocator, .{
                                                    .task = try dupStr.dup(allocator, task0),
                                                    .tool = if (tool0) |t| try dupStr.dup(allocator, t) else null,
                                                    .arg = if (arg0) |t| try dupStr.dup(allocator, t) else null,
                                                    .result = if (res0) |t| try dupStr.dup(allocator, t) else null,
                                                });
                                            },
                                            else => {},
                                        }
                                    },
                                    else => {},
                                }
                            } else {
                                // v1-v3 compatibility: infer done tasks from progress.done strings when possible.
                                for (done_list.items) |ds| {
                                    const pre = "ack: tool_result ";
                                    if (std.mem.startsWith(u8, ds, pre)) {
                                        const rest = ds[pre.len..];
                                        if (std.mem.indexOf(u8, rest, ":")) |col| {
                                            const tool = std.mem.trim(u8, rest[0..col], " ");
                                            const arg = std.mem.trim(u8, rest[col + 1 ..], " ");
                                            if (std.mem.eql(u8, tool, "echo")) {
                                                const task = try std.fmt.allocPrint(allocator, "echo: {s}", .{arg});
                                                try dt_list.append(allocator, .{ .task = task, .tool = try dupStr.dup(allocator, tool), .arg = try dupStr.dup(allocator, arg) });
                                            }
                                        }
                                    }
                                }
                            }

                            // in_progress_tasks
                            const ipt_val = if (obj.get("in_progress_tasks")) |v| v else null;
                            var ipt_list = try std.ArrayList(InProgressTask).initCapacity(allocator, 0);
                            if (ipt_val) |iv| {
                                switch (iv) {
                                    .array => |a| for (a.items) |it| {
                                        switch (it) {
                                            .string => try ipt_list.append(allocator, .{ .task = try dupStr.dup(allocator, it.string) }),
                                            .object => |o| {
                                                const task0 = if (o.get("task")) |v| switch (v) {
                                                    .string => |t| t,
                                                    else => "",
                                                } else "";
                                                if (task0.len == 0) continue;
                                                const src0 = if (o.get("source")) |v| switch (v) {
                                                    .string => |t| @as(?[]const u8, t),
                                                    else => null,
                                                } else null;
                                                try ipt_list.append(allocator, .{ .task = try dupStr.dup(allocator, task0), .source = if (src0) |t| try dupStr.dup(allocator, t) else null });
                                            },
                                            else => {},
                                        }
                                    },
                                    else => {},
                                }
                            } else {
                                // compatibility: infer from progress.in_progress
                                for (ip_list.items) |s0| {
                                    try ipt_list.append(allocator, .{ .task = try dupStr.dup(allocator, s0), .source = null });
                                }
                            }

                            // next_step_tasks
                            const nst_val = if (obj.get("next_step_tasks")) |v| v else null;
                            var nst_list = try std.ArrayList(NextStepTask).initCapacity(allocator, 0);
                            if (nst_val) |nv| {
                                switch (nv) {
                                    .array => |a| for (a.items) |it| {
                                        switch (it) {
                                            .string => try nst_list.append(allocator, .{ .task = try dupStr.dup(allocator, it.string) }),
                                            .object => |o| {
                                                const task0 = if (o.get("task")) |v| switch (v) {
                                                    .string => |t| t,
                                                    else => "",
                                                } else "";
                                                if (task0.len == 0) continue;
                                                const why0 = if (o.get("why")) |v| switch (v) {
                                                    .string => |t| @as(?[]const u8, t),
                                                    else => null,
                                                } else null;
                                                const pr0 = if (o.get("priority")) |v| switch (v) {
                                                    .integer => |x| @as(?u32, @intCast(x)),
                                                    else => null,
                                                } else null;
                                                try nst_list.append(allocator, .{
                                                    .task = try dupStr.dup(allocator, task0),
                                                    .why = if (why0) |t| try dupStr.dup(allocator, t) else null,
                                                    .priority = pr0,
                                                });
                                            },
                                            else => {},
                                        }
                                    },
                                    else => {},
                                }
                            } else {
                                // compatibility: infer from next_steps strings
                                for (ns_list.items) |s0| {
                                    try nst_list.append(allocator, .{ .task = try dupStr.dup(allocator, s0) });
                                }
                            }

                            prev_payload = Payload{
                                .schema = schema,
                                .goal = goal,
                                .constraints = try constraints_list.toOwnedSlice(allocator),
                                .progress = .{
                                    .done = try done_list.toOwnedSlice(allocator),
                                    .in_progress = try ip_list.toOwnedSlice(allocator),
                                    .blocked = try blocked_list.toOwnedSlice(allocator),
                                },
                                .key_decisions = try kd_list.toOwnedSlice(allocator),
                                .next_steps = try ns_list.toOwnedSlice(allocator),
                                .critical_context = try cc_list.toOwnedSlice(allocator),
                                .blocked_tasks = try bt_list.toOwnedSlice(allocator),
                                .done_tasks = try dt_list.toOwnedSlice(allocator),
                                .in_progress_tasks = try ipt_list.toOwnedSlice(allocator),
                                .next_step_tasks = try nst_list.toOwnedSlice(allocator),
                                .raw = raw,
                            };
                            break;
                        }
                    },
                    else => {},
                }
            }
        }

        // Collect NEW info since previous summary (or from 0 if none).
        const from_i: usize = (prev_idx orelse @as(usize, 0)) + 1;

        var new_raw_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer new_raw_buf.deinit(allocator);
        var new_next = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer new_next.deinit(allocator);
        var new_done = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer new_done.deinit(allocator);
        var new_ctx = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer new_ctx.deinit(allocator);
        var new_constraints = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer new_constraints.deinit(allocator);
        var new_decisions = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer new_decisions.deinit(allocator);
        var new_blocked = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer new_blocked.deinit(allocator);
        var new_blocked_tasks = try std.ArrayList(BlockedTask).initCapacity(allocator, 0);
        defer new_blocked_tasks.deinit(allocator);
        var new_done_tasks = try std.ArrayList(DoneTask).initCapacity(allocator, 0);
        defer new_done_tasks.deinit(allocator);

        var i: usize = from_i;
        while (i < start) : (i += 1) {
            const e = nodes.items[i];
            switch (e) {
                .tool_result => |tr| {
                    const preview = if (tr.content.len > 120) tr.content[0..120] else tr.content;

                    // Try to associate with the most recent tool_call arg for this tool in the same window.
                    var arg_opt: ?[]const u8 = null;
                    var back: usize = i;
                    while (back > from_i) : (back -= 1) {
                        const be = nodes.items[back - 1];
                        switch (be) {
                            .tool_call => |tc| {
                                if (std.mem.eql(u8, tc.tool, tr.tool)) {
                                    arg_opt = tc.arg;
                                    break;
                                }
                            },
                            else => {},
                        }
                    }

                    if (!tr.ok) {
                        const item = if (arg_opt) |a|
                            try std.fmt.allocPrint(allocator, "{s}({s}): {s}", .{ tr.tool, a, preview })
                        else
                            try std.fmt.allocPrint(allocator, "{s}: {s}", .{ tr.tool, preview });

                        try new_blocked.append(allocator, item);

                        // Also mark the originating user task as blocked (so it can be removed from next/in_progress).
                        if (arg_opt) |a| {
                            if (std.mem.eql(u8, tr.tool, "shell")) {
                                const task = try std.fmt.allocPrint(allocator, "sh: {s}", .{a});
                                try new_blocked_tasks.append(allocator, .{ .task = task, .tool = tr.tool, .arg = a, .err = preview });
                            } else if (std.mem.eql(u8, tr.tool, "echo")) {
                                const task = try std.fmt.allocPrint(allocator, "echo: {s}", .{a});
                                try new_blocked_tasks.append(allocator, .{ .task = task, .tool = tr.tool, .arg = a, .err = preview });
                            }
                        }
                    } else {
                        // ok=true => mark as done task for migration.
                        if (arg_opt) |a| {
                            if (std.mem.eql(u8, tr.tool, "echo")) {
                                const task = try std.fmt.allocPrint(allocator, "echo: {s}", .{a});
                                try new_done_tasks.append(allocator, .{ .task = task, .tool = tr.tool, .arg = a, .result = preview });
                            } else if (std.mem.eql(u8, tr.tool, "shell")) {
                                const task = try std.fmt.allocPrint(allocator, "sh: {s}", .{a});
                                try new_done_tasks.append(allocator, .{ .task = task, .tool = tr.tool, .arg = a, .result = preview });
                            }
                        }
                    }
                },
                .message => |m| {
                    if (!(std.mem.eql(u8, m.role, "user") or std.mem.eql(u8, m.role, "assistant"))) continue;
                    const preview = if (m.content.len > 120) m.content[0..120] else m.content;

                    // raw snippet
                    try new_raw_buf.appendSlice(allocator, m.role);
                    try new_raw_buf.appendSlice(allocator, ": ");
                    try new_raw_buf.appendSlice(allocator, preview);
                    try new_raw_buf.appendSlice(allocator, "\n");

                    // ctx line
                    const line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ m.role, preview });
                    try new_ctx.append(allocator, line);

                    if (std.mem.eql(u8, m.role, "user")) {
                        const item = try std.fmt.allocPrint(allocator, "{s}", .{preview});
                        try new_next.append(allocator, item);

                        // Heuristic constraints extraction
                        if (std.mem.startsWith(u8, m.content, "constraint:") or std.mem.startsWith(u8, m.content, "constraints:")) {
                            const body = std.mem.trimLeft(u8, m.content, "constraint:s ");
                            if (body.len > 0) try new_constraints.append(allocator, try std.fmt.allocPrint(allocator, "{s}", .{body}));
                        }
                        if (std.mem.startsWith(u8, m.content, "pref:") or std.mem.startsWith(u8, m.content, "preference:")) {
                            const body = std.mem.trimLeft(u8, m.content, "preference:pf ");
                            if (body.len > 0) try new_constraints.append(allocator, try std.fmt.allocPrint(allocator, "{s}", .{body}));
                        }
                    } else {
                        if (std.mem.startsWith(u8, m.content, "ack:")) {
                            const item = try std.fmt.allocPrint(allocator, "{s}", .{preview});
                            try new_done.append(allocator, item);
                        }
                        // Heuristic decision extraction
                        if (std.mem.startsWith(u8, m.content, "decision:") or std.mem.startsWith(u8, m.content, "decided:")) {
                            const body = std.mem.trimLeft(u8, m.content, "decision:d ");
                            if (body.len > 0) try new_decisions.append(allocator, try std.fmt.allocPrint(allocator, "{s}", .{body}));
                        }

                        // Heuristic blocked extraction
                        // Avoid duplicating tool_result errors already captured.
                        if (std.mem.startsWith(u8, m.content, "error:")) {
                            const body = std.mem.trimLeft(u8, m.content, "error: ");
                            if (body.len > 0) {
                                // If body looks like "tool_result <tool>: <err>", try to match existing "<tool>(...): <err>" or "<tool>: <err>".
                                var duplicate = false;
                                const tr_prefix = "tool_result ";
                                if (std.mem.startsWith(u8, body, tr_prefix)) {
                                    const rest = body[tr_prefix.len..];
                                    if (std.mem.indexOf(u8, rest, ":")) |col| {
                                        const tool = std.mem.trim(u8, rest[0..col], " ");
                                        const err = std.mem.trim(u8, rest[col + 1 ..], " ");
                                        for (new_blocked.items) |bi| {
                                            if (std.mem.startsWith(u8, bi, tool) and std.mem.indexOf(u8, bi, err) != null) {
                                                duplicate = true;
                                                break;
                                            }
                                        }
                                    }
                                }
                                if (!duplicate) {
                                    try new_blocked.append(allocator, try std.fmt.allocPrint(allocator, "assistant_error: {s}", .{body}));
                                }
                            }
                        }
                    }
                },
                .custom_message => |cm| {
                    const preview = if (cm.content.len > 120) cm.content[0..120] else cm.content;

                    try new_raw_buf.appendSlice(allocator, "user");
                    try new_raw_buf.appendSlice(allocator, ": ");
                    try new_raw_buf.appendSlice(allocator, preview);
                    try new_raw_buf.appendSlice(allocator, "\n");

                    const line = try std.fmt.allocPrint(allocator, "user: {s}", .{preview});
                    try new_ctx.append(allocator, line);
                    const item = try std.fmt.allocPrint(allocator, "{s}", .{preview});
                    try new_next.append(allocator, item);
                },
                else => {},
            }
        }

        const base = prev_payload orelse Payload{
            .schema = "pi.summary.v6",
            .goal = "(unknown)",
            .constraints = &.{},
            .progress = .{ .done = &.{}, .in_progress = &.{}, .blocked = &.{} },
            .key_decisions = &.{},
            .next_steps = &.{},
            .critical_context = &.{},
            .blocked_tasks = &.{},
            .done_tasks = &.{},
            .in_progress_tasks = &.{},
            .next_step_tasks = &.{},
            .raw = "",
        };

        const MAX_NEXT: usize = 10;
        const MAX_DONE: usize = 10;
        const MAX_CTX: usize = 20;

        // Merge helper: append unique with cap.
        const Merge = struct {
            fn uniqueAppend(
                alloc: std.mem.Allocator,
                dst: *std.ArrayList([]const u8),
                seen: *std.StringHashMap(bool),
                items: []const []const u8,
                cap: usize,
            ) !void {
                for (items) |it| {
                    if (dst.items.len >= cap) break;
                    if (seen.contains(it)) continue;
                    try seen.put(it, true);
                    try dst.append(alloc, it);
                }
            }
        };

        var next_seen = std.StringHashMap(bool).init(allocator);
        defer next_seen.deinit();
        var next_task_seen = std.StringHashMap(bool).init(allocator);
        defer next_task_seen.deinit();
        var done_seen = std.StringHashMap(bool).init(allocator);
        defer done_seen.deinit();
        var done_task_seen = std.StringHashMap(bool).init(allocator);
        defer done_task_seen.deinit();
        var ip_task_seen = std.StringHashMap(bool).init(allocator);
        defer ip_task_seen.deinit();
        var ctx_seen = std.StringHashMap(bool).init(allocator);
        defer ctx_seen.deinit();
        var cons_seen = std.StringHashMap(bool).init(allocator);
        defer cons_seen.deinit();
        var dec_seen = std.StringHashMap(bool).init(allocator);
        defer dec_seen.deinit();
        var blocked_seen = std.StringHashMap(bool).init(allocator);
        defer blocked_seen.deinit();
        var blocked_task_seen = std.StringHashMap(bool).init(allocator);
        defer blocked_task_seen.deinit();

        var next_out = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer next_out.deinit(allocator);
        var done_out = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer done_out.deinit(allocator);
        var ip_out = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer ip_out.deinit(allocator);
        var ctx_out = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer ctx_out.deinit(allocator);
        var cons_out = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer cons_out.deinit(allocator);
        var dec_out = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer dec_out.deinit(allocator);
        var blocked_out = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer blocked_out.deinit(allocator);
        var blocked_tasks_out = try std.ArrayList(BlockedTask).initCapacity(allocator, 0);
        defer blocked_tasks_out.deinit(allocator);
        var done_tasks_out = try std.ArrayList(DoneTask).initCapacity(allocator, 0);
        defer done_tasks_out.deinit(allocator);
        var ip_tasks_out = try std.ArrayList(InProgressTask).initCapacity(allocator, 0);
        defer ip_tasks_out.deinit(allocator);
        var next_tasks_out = try std.ArrayList(NextStepTask).initCapacity(allocator, 0);
        defer next_tasks_out.deinit(allocator);

        // Seed seen maps with base items so we don't duplicate.
        for (base.next_steps) |it| try next_seen.put(it, true);
        for (base.next_step_tasks) |t| try next_task_seen.put(t.task, true);
        for (base.progress.done) |it| try done_seen.put(it, true);
        for (base.critical_context) |it| try ctx_seen.put(it, true);
        for (base.constraints) |it| try cons_seen.put(it, true);
        for (base.key_decisions) |it| try dec_seen.put(it, true);
        for (base.progress.blocked) |it| try blocked_seen.put(it, true);
        // blocked_task_seen is seeded below when copying base.blocked_tasks
        // done_task_seen is seeded below when copying base.done_tasks

        // Start with base lists (capped).
        try Merge.uniqueAppend(allocator, &next_out, &next_seen, base.next_steps, MAX_NEXT);
        // next_step_tasks: merge by .task
        for (base.next_step_tasks) |nt| {
            if (next_tasks_out.items.len >= MAX_NEXT) break;
            if (next_task_seen.contains(nt.task)) continue;
            try next_task_seen.put(nt.task, true);
            try next_tasks_out.append(allocator, nt);
        }

        try Merge.uniqueAppend(allocator, &done_out, &done_seen, base.progress.done, MAX_DONE);
        // In progress: keep base, but drop anything that is now done.
        for (base.progress.in_progress) |it| {
            if (ip_out.items.len >= MAX_NEXT) break;
            if (done_seen.contains(it)) continue;
            try ip_out.append(allocator, it);
        }
        try Merge.uniqueAppend(allocator, &ctx_out, &ctx_seen, base.critical_context, MAX_CTX);
        try Merge.uniqueAppend(allocator, &cons_out, &cons_seen, base.constraints, 20);
        try Merge.uniqueAppend(allocator, &dec_out, &dec_seen, base.key_decisions, 20);
        try Merge.uniqueAppend(allocator, &blocked_out, &blocked_seen, base.progress.blocked, 20);
        // blocked_tasks: merge by .task key
        for (base.blocked_tasks) |bt| {
            if (blocked_tasks_out.items.len >= 20) break;
            if (blocked_task_seen.contains(bt.task)) continue;
            try blocked_task_seen.put(bt.task, true);
            try blocked_tasks_out.append(allocator, bt);
        }

        // done_tasks: merge by .task key
        for (base.done_tasks) |dt| {
            if (done_tasks_out.items.len >= 20) break;
            if (done_task_seen.contains(dt.task)) continue;
            try done_task_seen.put(dt.task, true);
            try done_tasks_out.append(allocator, dt);
        }

        // in_progress_tasks: merge by .task key
        for (base.in_progress_tasks) |ipt| {
            if (ip_tasks_out.items.len >= 20) break;
            if (ip_task_seen.contains(ipt.task)) continue;
            try ip_task_seen.put(ipt.task, true);
            try ip_tasks_out.append(allocator, ipt);
        }

        // Append new items.
        try Merge.uniqueAppend(allocator, &next_out, &next_seen, new_next.items, MAX_NEXT);
        // Also build structured next_step_tasks from new_next.
        for (new_next.items) |it| {
            if (next_tasks_out.items.len >= MAX_NEXT) break;
            if (next_task_seen.contains(it)) continue;
            try next_task_seen.put(it, true);
            try next_tasks_out.append(allocator, .{ .task = it, .why = null, .priority = null });
        }

        try Merge.uniqueAppend(allocator, &done_out, &done_seen, new_done.items, MAX_DONE);
        try Merge.uniqueAppend(allocator, &cons_out, &cons_seen, new_constraints.items, 20);
        try Merge.uniqueAppend(allocator, &dec_out, &dec_seen, new_decisions.items, 20);
        try Merge.uniqueAppend(allocator, &blocked_out, &blocked_seen, new_blocked.items, 20);
        for (new_blocked_tasks.items) |bt| {
            if (blocked_tasks_out.items.len >= 20) break;
            if (blocked_task_seen.contains(bt.task)) continue;
            try blocked_task_seen.put(bt.task, true);
            try blocked_tasks_out.append(allocator, bt);
        }

        for (new_done_tasks.items) |dt| {
            if (done_tasks_out.items.len >= 20) break;
            if (done_task_seen.contains(dt.task)) continue;
            try done_task_seen.put(dt.task, true);
            try done_tasks_out.append(allocator, dt);
        }

        // Generate in_progress_tasks from structured next steps (source=next_steps)
        for (next_tasks_out.items) |nt| {
            const it = nt.task;
            if (ip_tasks_out.items.len >= 20) break;
            if (done_task_seen.contains(it) or blocked_task_seen.contains(it)) continue;
            if (ip_task_seen.contains(it)) continue;
            try ip_task_seen.put(it, true);
            try ip_tasks_out.append(allocator, .{ .task = it, .source = "next_steps" });
        }

        // Sync in_progress with next steps: add items not in done.
        for (new_next.items) |it| {
            if (ip_out.items.len >= MAX_NEXT) break;
            if (done_seen.contains(it)) continue;
            if (std.mem.indexOf(u8, it, "(none)") != null) continue;
            // naive de-dup
            var already = false;
            for (ip_out.items) |x| if (std.mem.eql(u8, x, it)) {
                already = true;
                break;
            };
            if (already) continue;
            try ip_out.append(allocator, it);
        }
        try Merge.uniqueAppend(allocator, &ctx_out, &ctx_seen, new_ctx.items, MAX_CTX);

        // Replace progress.in_progress with the tasks list (stable + structured-source-of-truth)
        {
            var filtered = try std.ArrayList([]const u8).initCapacity(allocator, ip_tasks_out.items.len);
            for (ip_tasks_out.items) |ipt| {
                if (done_task_seen.contains(ipt.task)) continue;
                if (blocked_task_seen.contains(ipt.task)) continue;
                if (filtered.items.len >= MAX_NEXT) break;
                try filtered.append(allocator, ipt.task);
            }
            ip_out = filtered;
        }

        // Heuristic: mark related user tasks as done based on ack: tool_result echo: <arg>
        // This lets us drop "echo: <arg>" from next_steps/in_progress.
        for (done_out.items) |d| {
            const prefix_echo = "ack: tool_result echo:";
            if (std.mem.startsWith(u8, d, prefix_echo)) {
                const arg = std.mem.trimLeft(u8, d[prefix_echo.len..], " ");
                const task = try std.fmt.allocPrint(allocator, "echo: {s}", .{arg});
                if (!done_task_seen.contains(task)) {
                    _ = done_task_seen.put(task, true) catch {};
                    if (done_tasks_out.items.len < 20) {
                        try done_tasks_out.append(allocator, .{ .task = task, .tool = "echo", .arg = arg, .result = null });
                    }
                }
            }
        }

        // Post-process: remove next_steps that are already done/blocked.
        // NOTE: done-ness/blocked-ness are driven by done_tasks/blocked_tasks.
        {
            var filtered = try std.ArrayList([]const u8).initCapacity(allocator, next_out.items.len);
            var filtered_tasks = try std.ArrayList(NextStepTask).initCapacity(allocator, next_tasks_out.items.len);
            for (next_out.items) |it| {
                if (done_task_seen.contains(it)) continue;
                if (blocked_task_seen.contains(it)) continue;
                try filtered.append(allocator, it);
            }
            for (next_tasks_out.items) |nt| {
                if (done_task_seen.contains(nt.task)) continue;
                if (blocked_task_seen.contains(nt.task)) continue;
                if (filtered_tasks.items.len >= MAX_NEXT) break;
                try filtered_tasks.append(allocator, nt);
            }
            next_out = filtered;
            next_tasks_out = filtered_tasks;
        }

        // Also drop done/blocked items from in_progress.
        {
            var filtered = try std.ArrayList([]const u8).initCapacity(allocator, ip_out.items.len);
            for (ip_out.items) |it| {
                if (done_task_seen.contains(it)) continue;
                if (blocked_task_seen.contains(it)) continue;
                try filtered.append(allocator, it);
            }
            ip_out = filtered;
        }

        // Raw: append new snippets to previous raw.
        var raw_out = try std.ArrayList(u8).initCapacity(allocator, base.raw.len + new_raw_buf.items.len + 16);
        defer raw_out.deinit(allocator);
        if (base.raw.len > 0) {
            try raw_out.appendSlice(allocator, base.raw);
            if (!std.mem.endsWith(u8, base.raw, "\n")) try raw_out.appendSlice(allocator, "\n");
        }
        try raw_out.appendSlice(allocator, new_raw_buf.items);

        // Goal heuristic: if still unknown, use earliest user message in this summarized window.
        var goal_out = base.goal;
        if (std.mem.eql(u8, goal_out, "(unknown)")) {
            var gi: usize = 0;
            while (gi < start) : (gi += 1) {
                const e = nodes.items[gi];
                switch (e) {
                    .message => |m| {
                        if (std.mem.eql(u8, m.role, "user")) {
                            const preview = if (m.content.len > 120) m.content[0..120] else m.content;
                            goal_out = preview;
                            break;
                        }
                    },
                    else => {},
                }
            }
        }

        // Ensure progress.blocked contains a readable reason for each blocked task (if we know tool/arg/err).
        for (blocked_tasks_out.items) |bt| {
            if (bt.tool != null and bt.err != null) {
                const tool = bt.tool.?;
                const err = bt.err.?;
                const arg = bt.arg orelse "";
                const blocked_reason = if (arg.len > 0)
                    try std.fmt.allocPrint(allocator, "{s}({s}): {s}", .{ tool, arg, err })
                else
                    try std.fmt.allocPrint(allocator, "{s}: {s}", .{ tool, err });

                if (!blocked_seen.contains(blocked_reason) and blocked_out.items.len < 20) {
                    try blocked_seen.put(blocked_reason, true);
                    try blocked_out.append(allocator, blocked_reason);
                }
            }
        }

        const merged = Payload{
            .schema = base.schema,
            .goal = goal_out,
            .constraints = try cons_out.toOwnedSlice(allocator),
            .progress = .{ .done = try done_out.toOwnedSlice(allocator), .in_progress = try ip_out.toOwnedSlice(allocator), .blocked = try blocked_out.toOwnedSlice(allocator) },
            .key_decisions = try dec_out.toOwnedSlice(allocator),
            .next_steps = try next_out.toOwnedSlice(allocator),
            .critical_context = try ctx_out.toOwnedSlice(allocator),
            .blocked_tasks = try blocked_tasks_out.toOwnedSlice(allocator),
            .done_tasks = try done_tasks_out.toOwnedSlice(allocator),
            .in_progress_tasks = try ip_tasks_out.toOwnedSlice(allocator),
            .next_step_tasks = try next_tasks_out.toOwnedSlice(allocator),
            .raw = try raw_out.toOwnedSlice(allocator),
        };

        const written = try std.json.Stringify.valueAlloc(allocator, merged, .{ .whitespace = .indent_2 });
        try sum_buf.appendSlice(allocator, written);
    } else {
        // TS-aligned markdown structured summary (matches SUMMARIZATION_PROMPT format)

        // If update_summary is enabled and we have a previous md summary in the summarized prefix,
        // merge new info into that summary (naive: only appends to Critical Context).
        var prev_summary: ?[]const u8 = null;
        var prev_idx: ?usize = null;
        if (update_summary) {
            var k: usize = start;
            while (k > 0) : (k -= 1) {
                const e = nodes.items[k - 1];
                switch (e) {
                    .summary => |s| {
                        if (std.mem.eql(u8, s.format, "md")) {
                            prev_summary = s.summary;
                            prev_idx = k - 1;
                            break;
                        }
                    },
                    else => {},
                }
            }
        }

        const summarize_end: usize = if (split_turn) split_history_end else start;

        if (prev_summary == null) {
            // Naive fill: Goal unknown, Constraints none, Progress/NextSteps empty, Critical Context includes message snippets.
            try sum_buf.appendSlice(allocator, "## Goal\n(unknown)\n\n" ++
                "## Constraints & Preferences\n- (none)\n\n" ++
                "## Progress\n### Done\n- (none)\n\n### In Progress\n- (none)\n\n### Blocked\n- (none)\n\n" ++
                "## Key Decisions\n- (none)\n\n" ++
                "## Next Steps\n1. (none)\n\n" ++
                "## Critical Context\n");

            var i: usize = 0;
            while (i < summarize_end) : (i += 1) {
                const e = nodes.items[i];
                switch (e) {
                    .message => |m| {
                        if (std.mem.eql(u8, m.role, "user") or std.mem.eql(u8, m.role, "assistant")) {
                            const preview = if (m.content.len > 120) m.content[0..120] else m.content;
                            try sum_buf.appendSlice(allocator, "- ");
                            try sum_buf.appendSlice(allocator, m.role);
                            try sum_buf.appendSlice(allocator, ": ");
                            try sum_buf.appendSlice(allocator, preview);
                            try sum_buf.appendSlice(allocator, "\n");
                        }
                    },
                    .custom_message => |cm| {
                        const preview = if (cm.content.len > 120) cm.content[0..120] else cm.content;
                        try sum_buf.appendSlice(allocator, "- user: ");
                        try sum_buf.appendSlice(allocator, preview);
                        try sum_buf.appendSlice(allocator, "\n");
                    },
                    else => {},
                }
            }
            if (summarize_end == 0) {
                try sum_buf.appendSlice(allocator, "- (none)\n");
            }
        } else {
            // Merge mode
            // Naive TS-aligned updates:
            // - Patch a couple of common "(none)" placeholders.
            // - Extract a few heuristic updates from NEW messages since previous summary:
            //   - user messages -> Next Steps items
            //   - assistant messages starting with "ack:" -> Done items
            // - Append new message snippets into Critical Context (existing behavior).
            const base0 = prev_summary.?;

            // Collect heuristic updates from new messages after prev summary.
            // We'll de-duplicate and cap later to keep summary concise (TS-like).
            const MAX_NEW_DONE: usize = 10;
            const MAX_NEW_NEXT: usize = 10;
            const MAX_NEW_CTX: usize = 20;

            var next_steps_dyn = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            defer next_steps_dyn.deinit(allocator);
            var done_dyn = try std.ArrayList([]const u8).initCapacity(allocator, 0);
            defer done_dyn.deinit(allocator);

            const from_i: usize = (prev_idx orelse 0) + 1;
            var ii: usize = from_i;
            while (ii < summarize_end) : (ii += 1) {
                const e = nodes.items[ii];
                switch (e) {
                    .message => |m| {
                        if (std.mem.eql(u8, m.role, "user")) {
                            const preview = if (m.content.len > 120) m.content[0..120] else m.content;
                            const item = try std.fmt.allocPrint(allocator, "{s}", .{preview});
                            try next_steps_dyn.append(allocator, item);
                        } else if (std.mem.eql(u8, m.role, "assistant")) {
                            if (std.mem.startsWith(u8, m.content, "ack:")) {
                                const preview = if (m.content.len > 120) m.content[0..120] else m.content;
                                const item = try std.fmt.allocPrint(allocator, "{s}", .{preview});
                                try done_dyn.append(allocator, item);
                            }
                        }
                    },
                    .custom_message => |cm| {
                        const preview = if (cm.content.len > 120) cm.content[0..120] else cm.content;
                        const item = try std.fmt.allocPrint(allocator, "{s}", .{preview});
                        try next_steps_dyn.append(allocator, item);
                    },
                    else => {},
                }
            }

            // De-duplicate NEW items (keep order)
            var seen_done = std.StringHashMap(bool).init(allocator);
            defer seen_done.deinit();
            var seen_next = std.StringHashMap(bool).init(allocator);
            defer seen_next.deinit();

            var done_items = try std.ArrayList([]const u8).initCapacity(allocator, done_dyn.items.len);
            var next_items = try std.ArrayList([]const u8).initCapacity(allocator, next_steps_dyn.items.len);
            // NOTE: using arena allocator; no deinit needed for these arrays in this command.

            for (done_dyn.items) |it| {
                if (seen_done.contains(it)) continue;
                try seen_done.put(it, true);
                try done_items.append(allocator, it);
            }

            for (next_steps_dyn.items) |it| {
                if (seen_next.contains(it)) continue;
                try seen_next.put(it, true);
                try next_items.append(allocator, it);
            }

            // Preprocess: patch a couple of common "(none)" placeholders.
            var base_buf = try std.ArrayList(u8).initCapacity(allocator, base0.len + 512);
            defer base_buf.deinit(allocator);

            const pat_next = "## Next Steps\n1. (none)\n";
            const rep_next = if (next_items.items.len > 0) "## Next Steps\n" else "## Next Steps\n1. Review new messages since last checkpoint\n";
            const pat_inprog = "### In Progress\n- (none)\n";
            const rep_inprog = if (next_items.items.len > 0 or done_items.items.len > 0) "### In Progress\n- (none)\n" else "### In Progress\n- [ ] Review new messages since last checkpoint\n";
            const pat_done = "### Done\n- (none)\n";
            const rep_done = if (done_items.items.len > 0) "### Done\n" else "### Done\n- [x] (no completed items recorded yet)\n";

            var tmp = base0;
            // Apply at most once each.
            if (std.mem.indexOf(u8, tmp, pat_next)) |p| {
                try base_buf.appendSlice(allocator, tmp[0..p]);
                try base_buf.appendSlice(allocator, rep_next);
                tmp = tmp[p + pat_next.len ..];
            }
            if (std.mem.indexOf(u8, tmp, pat_inprog)) |p| {
                try base_buf.appendSlice(allocator, tmp[0..p]);
                try base_buf.appendSlice(allocator, rep_inprog);
                tmp = tmp[p + pat_inprog.len ..];
            }
            if (std.mem.indexOf(u8, tmp, pat_done)) |p| {
                try base_buf.appendSlice(allocator, tmp[0..p]);
                try base_buf.appendSlice(allocator, rep_done);
                tmp = tmp[p + pat_done.len ..];
            }
            try base_buf.appendSlice(allocator, tmp);

            var base = try base_buf.toOwnedSlice(allocator);

            // If we have real Done items, drop the Done "- (none)" placeholder.
            if (done_items.items.len > 0) {
                const pat = "### Done\n- (none)\n";
                if (std.mem.indexOf(u8, base, pat)) |p| {
                    var bfix = try std.ArrayList(u8).initCapacity(allocator, base.len);
                    defer bfix.deinit(allocator);
                    try bfix.appendSlice(allocator, base[0..p]);
                    try bfix.appendSlice(allocator, "### Done\n");
                    try bfix.appendSlice(allocator, base[p + pat.len ..]);
                    base = try bfix.toOwnedSlice(allocator);
                }
            }

            // Insert heuristic Done items into "### Done" section.
            if (done_items.items.len > 0) {
                const h = "### Done\n";
                if (std.mem.indexOf(u8, base, h)) |hp| {
                    const insert_pos = hp + h.len;
                    const tail = base[insert_pos..];
                    const next_hdr = std.mem.indexOf(u8, tail, "\n### In Progress\n") orelse tail.len;

                    var b2 = try std.ArrayList(u8).initCapacity(allocator, base.len + 256);
                    defer b2.deinit(allocator);
                    try b2.appendSlice(allocator, base[0 .. insert_pos + next_hdr]);

                    var added: usize = 0;
                    for (done_items.items) |it| {
                        if (added >= MAX_NEW_DONE) break;
                        // Skip if already present anywhere in summary
                        if (std.mem.indexOf(u8, base, it) != null) continue;
                        try b2.appendSlice(allocator, "- [x] ");
                        try b2.appendSlice(allocator, it);
                        try b2.appendSlice(allocator, "\n");
                        added += 1;
                    }
                    try b2.appendSlice(allocator, base[insert_pos + next_hdr ..]);
                    base = try b2.toOwnedSlice(allocator);
                }
            }

            // Insert heuristic Next Steps into "## Next Steps" section.
            if (next_items.items.len > 0) {
                const h = "## Next Steps\n";
                if (std.mem.indexOf(u8, base, h)) |hp| {
                    const insert_pos = hp + h.len;
                    const tail = base[insert_pos..];
                    const next_hdr = std.mem.indexOf(u8, tail, "\n## Critical Context\n") orelse tail.len;

                    // Determine next numbering (naive): count existing lines starting with digit+'.'
                    var nsteps: usize = 0;
                    {
                        var it = std.mem.splitScalar(u8, tail[0..next_hdr], '\n');
                        while (it.next()) |ln| {
                            if (ln.len >= 2 and ln[0] >= '0' and ln[0] <= '9' and ln[1] == '.') nsteps += 1;
                        }
                    }

                    var b2 = try std.ArrayList(u8).initCapacity(allocator, base.len + 256);
                    defer b2.deinit(allocator);
                    try b2.appendSlice(allocator, base[0 .. insert_pos + next_hdr]);

                    var added: usize = 0;
                    for (next_items.items) |it| {
                        if (added >= MAX_NEW_NEXT) break;
                        // Skip if already present anywhere in summary
                        if (std.mem.indexOf(u8, base, it) != null) continue;
                        nsteps += 1;
                        try b2.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}. {s}\n", .{ nsteps, it }));
                        added += 1;
                    }

                    try b2.appendSlice(allocator, base[insert_pos + next_hdr ..]);
                    base = try b2.toOwnedSlice(allocator);
                }
            }

            // TS-ish: keep "In Progress" aligned with new Next Steps, and migrate completed items.
            // - Add new next-items as "- [ ] ..." under In Progress.
            // - Remove any In Progress lines that match done items.
            {
                const h = "### In Progress\n";
                if (std.mem.indexOf(u8, base, h)) |hp| {
                    const insert_pos = hp + h.len;
                    const tail = base[insert_pos..];
                    const next_hdr = std.mem.indexOf(u8, tail, "\n### Blocked\n") orelse tail.len;
                    const section = tail[0..next_hdr];

                    var new_sec = try std.ArrayList(u8).initCapacity(allocator, 0);
                    // NOTE: arena allocator; no deinit needed.

                    // Keep existing lines but drop "- (none)" and any done-matching lines.
                    var it_lines = std.mem.splitScalar(u8, section, '\n');
                    while (it_lines.next()) |ln| {
                        if (ln.len == 0) continue;
                        if (std.mem.eql(u8, ln, "- (none)")) continue;

                        var drop = false;
                        for (done_items.items) |dit| {
                            // naive match: line contains done text
                            if (std.mem.indexOf(u8, ln, dit) != null) {
                                drop = true;
                                break;
                            }
                        }
                        if (drop) continue;

                        try new_sec.appendSlice(allocator, ln);
                        try new_sec.appendSlice(allocator, "\n");
                    }

                    // Append next items as checklist entries if not already present.
                    var added: usize = 0;
                    for (next_items.items) |nit| {
                        if (added >= MAX_NEW_NEXT) break;
                        if (std.mem.indexOf(u8, new_sec.items, nit) != null) continue;
                        var is_done = false;
                        for (done_items.items) |dit| {
                            if (std.mem.indexOf(u8, nit, dit) != null or std.mem.indexOf(u8, dit, nit) != null) {
                                is_done = true;
                                break;
                            }
                        }
                        if (is_done) continue;
                        try new_sec.appendSlice(allocator, "- [ ] ");
                        try new_sec.appendSlice(allocator, nit);
                        try new_sec.appendSlice(allocator, "\n");
                        added += 1;
                    }

                    if (new_sec.items.len == 0) {
                        try new_sec.appendSlice(allocator, "- (none)\n");
                    }

                    var b2 = try std.ArrayList(u8).initCapacity(allocator, base.len + 256);
                    defer b2.deinit(allocator);
                    try b2.appendSlice(allocator, base[0..insert_pos]);
                    try b2.appendSlice(allocator, new_sec.items);
                    try b2.appendSlice(allocator, base[insert_pos + next_hdr ..]);
                    base = try b2.toOwnedSlice(allocator);
                }
            }

            // If Next Steps ended up empty, keep a small placeholder for readability.
            {
                const h = "## Next Steps\n";
                const h2 = "\n## Critical Context\n";
                if (std.mem.indexOf(u8, base, h)) |hp| {
                    const content_start = hp + h.len;
                    const tail = base[content_start..];
                    const end_rel = std.mem.indexOf(u8, tail, h2) orelse tail.len;
                    const content = tail[0..end_rel];

                    var only_ws = true;
                    var k: usize = 0;
                    while (k < content.len) : (k += 1) {
                        const c = content[k];
                        if (!(c == ' ' or c == '\n' or c == '\r' or c == '\t')) {
                            only_ws = false;
                            break;
                        }
                    }

                    if (only_ws) {
                        var b2 = try std.ArrayList(u8).initCapacity(allocator, base.len + 32);
                        defer b2.deinit(allocator);
                        try b2.appendSlice(allocator, base[0..content_start]);
                        try b2.appendSlice(allocator, "1. (none)\n");
                        try b2.appendSlice(allocator, base[content_start + end_rel ..]);
                        base = try b2.toOwnedSlice(allocator);
                    }
                }
            }

            // Find insertion point: after "## Critical Context\n" heading.
            const needle = "## Critical Context\n";
            const pos_opt = std.mem.indexOf(u8, base, needle);
            if (pos_opt == null) {
                // fallback: just append
                try sum_buf.appendSlice(allocator, base);
                try sum_buf.appendSlice(allocator, "\n## Critical Context\n");
            } else {
                const pos = pos_opt.? + needle.len;
                try sum_buf.appendSlice(allocator, base[0..pos]);

                // If the critical context currently has "- (none)", drop it.
                const rest = base[pos..];
                if (std.mem.startsWith(u8, rest, "- (none)\n")) {
                    try sum_buf.appendSlice(allocator, rest[9..]);
                } else {
                    try sum_buf.appendSlice(allocator, rest);
                }
            }

            // Append new message snippets after previous summary node up to start.
            // De-dup + cap to keep summary concise.
            var seen_ctx = std.StringHashMap(bool).init(allocator);
            defer seen_ctx.deinit();
            var added_ctx: usize = 0;

            var i: usize = (prev_idx orelse 0) + 1;
            while (i < summarize_end) : (i += 1) {
                if (added_ctx >= MAX_NEW_CTX) break;
                const e = nodes.items[i];
                switch (e) {
                    .message => |m| {
                        if (std.mem.eql(u8, m.role, "user") or std.mem.eql(u8, m.role, "assistant")) {
                            const preview = if (m.content.len > 120) m.content[0..120] else m.content;
                            const line = try std.fmt.allocPrint(allocator, "- {s}: {s}", .{ m.role, preview });
                            if (seen_ctx.contains(line)) continue;
                            try seen_ctx.put(line, true);
                            if (std.mem.indexOf(u8, base, line) != null) continue;
                            try sum_buf.appendSlice(allocator, line);
                            try sum_buf.appendSlice(allocator, "\n");
                            added_ctx += 1;
                        }
                    },
                    .custom_message => |cm| {
                        const preview = if (cm.content.len > 120) cm.content[0..120] else cm.content;
                        const line = try std.fmt.allocPrint(allocator, "- user: {s}", .{preview});
                        if (seen_ctx.contains(line)) continue;
                        try seen_ctx.put(line, true);
                        if (std.mem.indexOf(u8, base, line) != null) continue;
                        try sum_buf.appendSlice(allocator, line);
                        try sum_buf.appendSlice(allocator, "\n");
                        added_ctx += 1;
                    },
                    else => {},
                }
            }
        }
    }

    if (want_md and split_turn) {
        // Attach TS-style split-turn prefix summary.
        try sum_buf.appendSlice(allocator, "\n---\n\n**Turn Context (split turn):**\n\n");
        try sum_buf.appendSlice(allocator, "## Original Request\n");

        // Heuristic: use the first user message in the prefix as the request.
        var req_written = false;
        var i: usize = split_prefix_start;
        while (i < split_prefix_end) : (i += 1) {
            const e = nodes.items[i];
            switch (e) {
                .message => |m| {
                    if (!req_written and std.mem.eql(u8, m.role, "user")) {
                        const preview = if (m.content.len > 300) m.content[0..300] else m.content;
                        try sum_buf.appendSlice(allocator, preview);
                        try sum_buf.appendSlice(allocator, "\n\n");
                        req_written = true;
                    }
                },
                .custom_message => |cm| {
                    if (!req_written) {
                        const preview = if (cm.content.len > 300) cm.content[0..300] else cm.content;
                        try sum_buf.appendSlice(allocator, preview);
                        try sum_buf.appendSlice(allocator, "\n\n");
                        req_written = true;
                    }
                },
                else => {},
            }
        }
        if (!req_written) {
            try sum_buf.appendSlice(allocator, "(unknown)\n\n");
        }

        try sum_buf.appendSlice(allocator, "## Early Progress\n");
        // Heuristic bullets: tool calls/results + assistant acks/errors.
        var any_progress = false;
        i = split_prefix_start;
        while (i < split_prefix_end) : (i += 1) {
            const e = nodes.items[i];
            switch (e) {
                .tool_call => |tc| {
                    const preview = if (tc.arg.len > 200) tc.arg[0..200] else tc.arg;
                    try sum_buf.appendSlice(allocator, "- tool_call ");
                    try sum_buf.appendSlice(allocator, tc.tool);
                    try sum_buf.appendSlice(allocator, ": ");
                    try sum_buf.appendSlice(allocator, preview);
                    try sum_buf.appendSlice(allocator, "\n");
                    any_progress = true;
                },
                .tool_result => |tr| {
                    const preview = if (tr.content.len > 200) tr.content[0..200] else tr.content;
                    try sum_buf.appendSlice(allocator, "- tool_result ");
                    try sum_buf.appendSlice(allocator, tr.tool);
                    try sum_buf.appendSlice(allocator, ": ");
                    try sum_buf.appendSlice(allocator, if (tr.ok) "ok" else "error");
                    try sum_buf.appendSlice(allocator, " — ");
                    try sum_buf.appendSlice(allocator, preview);
                    try sum_buf.appendSlice(allocator, "\n");
                    any_progress = true;
                },
                .message => |m| {
                    if (std.mem.eql(u8, m.role, "assistant")) {
                        if (std.mem.startsWith(u8, m.content, "ack:") or std.mem.startsWith(u8, m.content, "error:")) {
                            const preview = if (m.content.len > 200) m.content[0..200] else m.content;
                            try sum_buf.appendSlice(allocator, "- assistant: ");
                            try sum_buf.appendSlice(allocator, preview);
                            try sum_buf.appendSlice(allocator, "\n");
                            any_progress = true;
                        }
                    }
                },
                else => {},
            }
        }
        if (!any_progress) {
            try sum_buf.appendSlice(allocator, "- (none)\n");
        }

        try sum_buf.appendSlice(allocator, "\n## Context for Suffix\n");
        try sum_buf.appendSlice(allocator, "This turn was too large to keep in full. The kept suffix continues after this cutpoint.\n");
    }

    if (want_md) {
        // TS-style compaction details: append file operations.
        if (read_files_out.items.len > 0) {
            try sum_buf.appendSlice(allocator, "\n\n<read-files>\n");
            for (read_files_out.items) |p| {
                try sum_buf.appendSlice(allocator, p);
                try sum_buf.appendSlice(allocator, "\n");
            }
            try sum_buf.appendSlice(allocator, "</read-files>\n");
        }
        if (modified_files_out.items.len > 0) {
            try sum_buf.appendSlice(allocator, "\n<modified-files>\n");
            for (modified_files_out.items) |p| {
                try sum_buf.appendSlice(allocator, p);
                try sum_buf.appendSlice(allocator, "\n");
            }
            try sum_buf.appendSlice(allocator, "</modified-files>\n");
        }
    }

    const sum_text = try sum_buf.toOwnedSlice(allocator);
    const first_kept_entry_id: ?[]const u8 = if (start < n) st.idOf(nodes.items[start]) else null;

    if (dry_run) {
        return .{ .dryRun = true, .summaryText = sum_text, .summaryId = null };
    }

    const rf_slice = if (read_files_out.items.len > 0) try read_files_out.toOwnedSlice(allocator) else null;
    const mf_slice = if (modified_files_out.items.len > 0) try modified_files_out.toOwnedSlice(allocator) else null;

    const summary_id = try sm.appendSummaryWithFiles(
        sum_text,
        reason,
        if (want_json) "json" else if (want_md) "md" else "text",
        first_kept_entry_id,
        rf_slice,
        mf_slice,
        stats_total_chars,
        stats_total_tokens_est,
        keep_last,
        keep_last_groups,
        stats_threshold_chars,
        stats_threshold_tokens_est,
    );
    if (label) |lab| {
        _ = try sm.setLabel(summary_id, lab);
    }

    return .{ .dryRun = false, .summaryText = sum_text, .summaryId = summary_id };
}

fn verifyRun(arena: std.mem.Allocator, out_dir: []const u8, run_id: []const u8) !void {
    const run_path = try std.fs.path.join(arena, &.{ out_dir, run_id });
    const plan_path = try std.fs.path.join(arena, &.{ run_path, "plan.json" });
    const run_json_path = try std.fs.path.join(arena, &.{ run_path, "run.json" });
    const steps_dir = try std.fs.path.join(arena, &.{ run_path, "steps" });

    // Check presence
    _ = try std.fs.cwd().statFile(plan_path);
    _ = try std.fs.cwd().statFile(run_json_path);
    _ = try std.fs.cwd().openDir(steps_dir, .{});

    var parsed_plan = try parseJsonFile(arena, plan_path);
    defer parsed_plan.deinit();

    const pobj = switch (parsed_plan.value) {
        .object => |o| o,
        else => return error.InvalidPlan,
    };
    const steps_v = pobj.get("steps") orelse return error.InvalidPlan;
    const steps_arr = switch (steps_v) {
        .array => |a| a,
        else => return error.InvalidPlan,
    };

    // For each step in plan, ensure a step artifact exists.
    for (steps_arr.items) |sv| {
        const so = switch (sv) {
            .object => |o| o,
            else => return error.InvalidPlan,
        };
        const step_id = switch (so.get("id") orelse return error.InvalidPlan) {
            .string => |s| s,
            else => return error.InvalidPlan,
        };

        const sid = try safeId(arena, step_id);
        const step_path = try std.fs.path.join(arena, &.{ steps_dir, try std.fmt.allocPrint(arena, "{s}.json", .{sid}) });
        _ = try std.fs.cwd().statFile(step_path);

        var parsed_step = try parseJsonFile(arena, step_path);
        defer parsed_step.deinit();

        const sobj = switch (parsed_step.value) {
            .object => |o| o,
            else => return error.InvalidStepArtifact,
        };
        const ok_v = sobj.get("ok") orelse return error.InvalidStepArtifact;
        const ok_b = switch (ok_v) {
            .bool => |b| b,
            else => return error.InvalidStepArtifact,
        };
        if (!ok_b) return error.StepFailed;

        const rid_v = sobj.get("runId") orelse return error.InvalidStepArtifact;
        const rid = switch (rid_v) {
            .string => |s| s,
            else => return error.InvalidStepArtifact,
        };
        if (!std.mem.eql(u8, rid, run_id)) return error.RunIdMismatch;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var args = std.process.args();
    _ = args.next();

    const cmd = args.next() orelse {
        usage();
        return;
    };

    if (std.mem.eql(u8, cmd, "label")) {
        var session_path: ?[]const u8 = null;
        var to_id: ?[]const u8 = null;
        var label: ?[]const u8 = null;

        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--to")) {
                to_id = args.next() orelse return error.MissingTo;
            } else if (std.mem.eql(u8, a, "--label")) {
                label = args.next() orelse return error.MissingLabel;
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
                return;
            } else {
                return error.UnknownArg;
            }
        }

        const sp = session_path orelse {
            usage();
            return;
        };
        const tid = to_id orelse {
            usage();
            return;
        };

        var sm = session.SessionManager.init(allocator, sp, ".");
        try sm.ensure();
        _ = try sm.setLabel(tid, label);
        std.debug.print("ok: true\nlabel: {s} -> {s} = {s}\n", .{ sp, tid, label orelse "(null)" });
        return;
    }

    if (std.mem.eql(u8, cmd, "show")) {
        var session_path: ?[]const u8 = null;
        var id: ?[]const u8 = null;

        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--id")) {
                id = args.next() orelse return error.MissingId;
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
                return;
            } else {
                return error.UnknownArg;
            }
        }

        const sp = session_path orelse {
            usage();
            return;
        };
        const target = id orelse {
            usage();
            return;
        };

        var sm = session.SessionManager.init(allocator, sp, ".");
        try sm.ensure();
        const entries = try sm.loadEntries();
        for (entries) |e| {
            if (st: {
                if (st.idOf(e)) |eid| break :st std.mem.eql(u8, eid, target);
                break :st false;
            }) {
                switch (e) {
                    .message => |m| std.debug.print("message {s} parent={s}\nrole={s}\ncontent={s}\n", .{ m.id, m.parentId orelse "(null)", m.role, m.content }),
                    .tool_call => |tc| std.debug.print("tool_call {s} parent={s}\ntool={s}\narg={s}\n", .{ tc.id, tc.parentId orelse "(null)", tc.tool, tc.arg }),
                    .tool_result => |tr| std.debug.print("tool_result {s} parent={s}\ntool={s} ok={any}\ncontent={s}\n", .{ tr.id, tr.parentId orelse "(null)", tr.tool, tr.ok, tr.content }),
                    .branch_summary => |b| {
                        std.debug.print("branch_summary {s} parent={s}\nfromId={s}\nfromHook={any}\nsummary=\n{s}\n", .{ b.id, b.parentId orelse "(null)", b.fromId, b.fromHook, b.summary });
                        if (b.detailsJson) |dj| std.debug.print("detailsJson=\n{s}\n", .{dj});
                    },
                    .custom => |c| {
                        std.debug.print("custom {s} parent={s}\ncustomType={s}\n", .{ c.id, c.parentId orelse "(null)", c.customType });
                        if (c.dataJson) |dj| std.debug.print("dataJson=\n{s}\n", .{dj});
                    },
                    .custom_message => |c| {
                        std.debug.print("custom_message {s} parent={s}\ncustomType={s}\ndisplay={any}\ncontent={s}\n", .{ c.id, c.parentId orelse "(null)", c.customType, c.display, c.content });
                        if (c.contentJson) |cj| std.debug.print("contentJson=\n{s}\n", .{cj});
                        if (c.detailsJson) |dj| std.debug.print("detailsJson=\n{s}\n", .{dj});
                    },
                    .session_info => |s| std.debug.print("session_info {s} parent={s}\nname={s}\n", .{ s.id, s.parentId orelse "(null)", s.name orelse "(null)" }),
                    .thinking_level_change => |t| std.debug.print("thinking_level_change {s} parent={s}\nlevel={s}\n", .{ t.id, t.parentId orelse "(null)", t.thinkingLevel }),
                    .model_change => |m| std.debug.print("model_change {s} parent={s}\nprovider={s}\nmodelId={s}\n", .{ m.id, m.parentId orelse "(null)", m.provider, m.modelId }),
                    .summary => |s| {
                        std.debug.print(
                            "summary {s} parent={s}\nreason={s}\nformat={s}\nfirstKeptEntryId={s}\ntokensBefore={any}\nfromHook={any}\nkeepLast={any} keepLastGroups={any}\nchars={any} tokens_est={any}\nthresh_chars={any} thresh_tokens_est={any}\nsummary=\n{s}\n",
                            .{
                                s.id,
                                s.parentId orelse "(null)",
                                s.reason orelse "(null)",
                                s.format,
                                s.firstKeptEntryId orelse "(null)",
                                s.tokensBefore,
                                s.fromHook,
                                s.keepLast,
                                s.keepLastGroups,
                                s.totalChars,
                                s.totalTokensEst,
                                s.thresholdChars,
                                s.thresholdTokensEst,
                                s.summary,
                            },
                        );
                        if (s.readFiles) |rf| {
                            std.debug.print("readFiles:\n", .{});
                            for (rf) |p| std.debug.print("- {s}\n", .{p});
                        }
                        if (s.modifiedFiles) |mf| {
                            std.debug.print("modifiedFiles:\n", .{});
                            for (mf) |p| std.debug.print("- {s}\n", .{p});
                        }
                        if (s.detailsJson) |dj| {
                            std.debug.print("detailsJson=\n{s}\n", .{dj});
                        }
                    },
                    else => {},
                }
                return;
            }
        }
        return error.NotFound;
    }

    if (std.mem.eql(u8, cmd, "list")) {
        var session_path: ?[]const u8 = null;
        var show_turns = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--show-turns")) {
                show_turns = true;
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
                return;
            } else {
                return error.UnknownArg;
            }
        }
        const sp = session_path orelse {
            usage();
            return;
        };

        var sm = session.SessionManager.init(allocator, sp, ".");
        try sm.ensure();

        // Build label map
        const entries_all = try sm.loadEntries();
        var labels = std.StringHashMap([]const u8).init(allocator);
        defer labels.deinit();
        for (entries_all) |e| {
            switch (e) {
                .label => |l| {
                    if (l.label) |name| {
                        try labels.put(l.targetId, name);
                    } else {
                        _ = labels.remove(l.targetId);
                    }
                },
                else => {},
            }
        }

        const entries = if (show_turns) try sm.buildContextEntriesVerbose() else try sm.buildContextEntries();
        var idx: usize = 0;
        for (entries) |e| {
            idx += 1;
            if (st.idOf(e)) |eid| {
                const lab = labels.get(eid) orelse "";
                switch (e) {
                    .turn_start => |t| {
                        if (show_turns) std.debug.print("{d}. {s} turn_start turn={d} phase={s} {s}\n", .{ idx, eid, t.turn, t.phase orelse "-", if (lab.len > 0) lab else "" });
                    },
                    .turn_end => |t| {
                        if (show_turns) std.debug.print("{d}. {s} turn_end turn={d} phase={s} {s}\n", .{ idx, eid, t.turn, t.phase orelse "-", if (lab.len > 0) lab else "" });
                    },
                    .message => |m| std.debug.print("{d}. {s} message {s} {s}\n", .{ idx, eid, m.role, if (lab.len > 0) lab else "" }),
                    .custom_message => |c| std.debug.print("{d}. {s} custom_message {s} display={any} {s}\n", .{ idx, eid, c.customType, c.display, if (lab.len > 0) lab else "" }),
                    .custom => |c| std.debug.print("{d}. {s} custom {s} {s}\n", .{ idx, eid, c.customType, if (lab.len > 0) lab else "" }),
                    .session_info => |s| std.debug.print("{d}. {s} session_info {s} {s}\n", .{ idx, eid, s.name orelse "(null)", if (lab.len > 0) lab else "" }),
                    .tool_call => |tc| std.debug.print("{d}. {s} tool_call {s} arg={s} {s}\n", .{ idx, eid, tc.tool, tc.arg, if (lab.len > 0) lab else "" }),
                    .tool_result => |tr| std.debug.print("{d}. {s} tool_result {s} ok={any} {s}\n", .{ idx, eid, tr.tool, tr.ok, if (lab.len > 0) lab else "" }),
                    .branch_summary => |b| std.debug.print("{d}. {s} branch_summary from={s} {s}\n", .{ idx, eid, b.fromId, if (lab.len > 0) lab else "" }),
                    .thinking_level_change => |t| std.debug.print("{d}. {s} thinking_level_change {s} {s}\n", .{ idx, eid, t.thinkingLevel, if (lab.len > 0) lab else "" }),
                    .model_change => |m| std.debug.print("{d}. {s} model_change {s}/{s} {s}\n", .{ idx, eid, m.provider, m.modelId, if (lab.len > 0) lab else "" }),
                    .summary => std.debug.print("{d}. {s} summary {s}\n", .{ idx, eid, if (lab.len > 0) lab else "" }),
                    else => {},
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "compact")) {
        var session_path: ?[]const u8 = null;
        var keep_last: usize = 8;
        var keep_last_groups: ?usize = null;
        var max_chars: ?usize = null;
        var max_tokens_est: ?usize = null;
        var dry_run = false;
        var label: ?[]const u8 = null;
        var structured = false;
        var structured_format: []const u8 = "md"; // md|json
        var update_summary = false;

        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--keep-last")) {
                const s = args.next() orelse return error.MissingKeepLast;
                keep_last = try std.fmt.parseInt(usize, s, 10);
            } else if (std.mem.eql(u8, a, "--keep-last-groups")) {
                const s = args.next() orelse return error.MissingKeepLast;
                keep_last_groups = try std.fmt.parseInt(usize, s, 10);
            } else if (std.mem.eql(u8, a, "--max-chars")) {
                const s = args.next() orelse return error.MissingMaxChars;
                max_chars = try std.fmt.parseInt(usize, s, 10);
            } else if (std.mem.eql(u8, a, "--max-tokens-est")) {
                const s = args.next() orelse return error.MissingMaxTokensEst;
                max_tokens_est = try std.fmt.parseInt(usize, s, 10);
            } else if (std.mem.eql(u8, a, "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, a, "--label")) {
                label = args.next() orelse return error.MissingLabel;
            } else if (std.mem.eql(u8, a, "--structured")) {
                structured = true;
                // Optional: --structured json|md
                if (args.next()) |maybe| {
                    if (std.mem.eql(u8, maybe, "md") or std.mem.eql(u8, maybe, "json")) {
                        structured_format = maybe;
                    } else {
                        // push back not supported; treat as unknown arg
                        return error.UnknownArg;
                    }
                } else {
                    structured_format = "md";
                }
            } else if (std.mem.eql(u8, a, "--update")) {
                update_summary = true;
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
                return;
            } else {
                return error.UnknownArg;
            }
        }

        const sp = session_path orelse {
            usage();
            return;
        };

        var sm = session.SessionManager.init(allocator, sp, ".");
        try sm.ensure();

        // Stats snapshot (TS-like): compute totals for current leaf context boundary since last summary.
        const chain = try sm.buildContextEntries();

        var boundary_from: usize = 0;
        {
            var k: usize = chain.len;
            while (k > 0) : (k -= 1) {
                const e = chain[k - 1];
                switch (e) {
                    .summary => {
                        boundary_from = k;
                        break;
                    },
                    else => {},
                }
            }
        }

        var total_chars: usize = 0;
        var idx: usize = boundary_from;
        while (idx < chain.len) : (idx += 1) {
            const e = chain[idx];
            switch (e) {
                .message => |m| total_chars += m.content.len,
                .summary => |s| total_chars += s.summary.len,
                else => {},
            }
        }
        const token_est = estimateBoundaryTokens(chain, boundary_from);
        const total_tokens_est = token_est.tokens;

        const effective_keep_last: usize = if (keep_last_groups != null) 0 else keep_last;
        const mode = if (keep_last_groups != null) "groups" else "entries";

        const res = try doCompact(
            allocator,
            &sm,
            effective_keep_last,
            keep_last_groups,
            dry_run,
            label,
            if (structured and std.mem.eql(u8, structured_format, "json")) "SUMMARY_JSON" else if (structured) "SUMMARY_MD" else "SUMMARY (naive):\n",
            if (update_summary) "manual_update" else "manual",
            total_chars,
            total_tokens_est,
            max_chars,
            max_tokens_est,
            update_summary,
        );

        if (res.dryRun) {
            std.debug.print(
                "ok: true\ndryRun: true\nmode: {s}\nkeep_last: {d}\nkeep_last_groups: {any}\nsummaryPreview:\n{s}\n",
                .{ mode, keep_last, keep_last_groups, res.summaryText },
            );
            return;
        }

        std.debug.print(
            "ok: true\nmode: {s}\nkeep_last: {d}\nkeep_last_groups: {any}\ncompacted: {s}\nsummaryId: {s}\n",
            .{ mode, keep_last, keep_last_groups, sp, res.summaryId.? },
        );
        return;
    }

    if (std.mem.eql(u8, cmd, "tree")) {
        var session_path: ?[]const u8 = null;
        var max_depth: usize = 64;
        var show_turns = false;

        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--max-depth")) {
                const s = args.next() orelse return error.MissingMaxDepth;
                max_depth = try std.fmt.parseInt(usize, s, 10);
            } else if (std.mem.eql(u8, a, "--show-turns")) {
                show_turns = true;
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
                return;
            } else {
                return error.UnknownArg;
            }
        }

        const sp = session_path orelse {
            usage();
            return;
        };

        var sm = session.SessionManager.init(allocator, sp, ".");
        try sm.ensure();
        const entries = try sm.loadEntries();

        // label map (targetId -> label)
        var labels = std.StringHashMap([]const u8).init(allocator);
        defer labels.deinit();
        for (entries) |e| {
            switch (e) {
                .label => |l| {
                    if (l.label) |name| {
                        try labels.put(l.targetId, name);
                    } else {
                        _ = labels.remove(l.targetId);
                    }
                },
                else => {},
            }
        }

        const leaf = try sm.leafId();

        // build id -> entry map
        var by_id = std.StringHashMap(st.Entry).init(allocator);
        defer by_id.deinit();
        for (entries) |e| {
            if (st.idOf(e)) |id| {
                try by_id.put(id, e);
            }
        }

        // build leaf path set
        var on_path = std.StringHashMap(bool).init(allocator);
        defer on_path.deinit();
        var cur = leaf;
        while (cur) |cid| {
            try on_path.put(cid, true);
            const e = by_id.get(cid) orelse break;
            cur = st.parentIdOf(e);
        }

        // build parent -> children ids map
        var children = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
        defer {
            var it = children.iterator();
            while (it.next()) |kv| {
                kv.value_ptr.deinit(allocator);
            }
            children.deinit();
        }

        for (entries) |e| {
            if (st.idOf(e)) |id| {
                const pid = st.parentIdOf(e) orelse "";
                if (!children.contains(pid)) {
                    try children.put(pid, try std.ArrayList([]const u8).initCapacity(allocator, 0));
                }
                var listp = children.getPtr(pid).?;
                try listp.append(allocator, id);
            }
        }

        // sort children lists for deterministic output
        {
            var it = children.iterator();
            while (it.next()) |kv| {
                std.mem.sort([]const u8, kv.value_ptr.items, {}, struct {
                    fn lt(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.lessThan(u8, a, b);
                    }
                }.lt);
            }
        }

        const Printer = struct {
            fn printNode(
                alloc: std.mem.Allocator,
                by_id_map: *std.StringHashMap(st.Entry),
                children_map: *std.StringHashMap(std.ArrayList([]const u8)),
                labels_map: *std.StringHashMap([]const u8),
                path_map: *std.StringHashMap(bool),
                id: []const u8,
                depth: usize,
                maxd: usize,
                show_turns_flag: bool,
            ) void {
                if (depth > maxd) return;

                const e = by_id_map.get(id) orelse return;
                const mark = if (path_map.contains(id)) "*" else " ";
                const lab = labels_map.get(id) orelse "";
                const indent = depth * 2;
                std.debug.print("{s}{s}", .{ std.mem.zeroes([0]u8), "" });
                // manual indent
                var i: usize = 0;
                while (i < indent) : (i += 1) std.debug.print(" ", .{});

                switch (e) {
                    .turn_start => |t| {
                        if (!show_turns_flag) return;
                        if (lab.len > 0) {
                            std.debug.print("{s} {s} turn_start turn={d} phase={s} [{s}]\n", .{ mark, id, t.turn, t.phase orelse "-", lab });
                        } else {
                            std.debug.print("{s} {s} turn_start turn={d} phase={s}\n", .{ mark, id, t.turn, t.phase orelse "-" });
                        }
                    },
                    .turn_end => |t| {
                        if (!show_turns_flag) return;
                        if (lab.len > 0) {
                            std.debug.print("{s} {s} turn_end turn={d} phase={s} [{s}]\n", .{ mark, id, t.turn, t.phase orelse "-", lab });
                        } else {
                            std.debug.print("{s} {s} turn_end turn={d} phase={s}\n", .{ mark, id, t.turn, t.phase orelse "-" });
                        }
                    },
                    .message => |m| {
                        const preview = if (m.content.len > 40) m.content[0..40] else m.content;
                        if (lab.len > 0) {
                            std.debug.print("{s} {s} message {s} \"{s}\" [{s}]\n", .{ mark, id, m.role, preview, lab });
                        } else {
                            std.debug.print("{s} {s} message {s} \"{s}\"\n", .{ mark, id, m.role, preview });
                        }
                    },
                    .custom_message => |c| {
                        const preview = if (c.content.len > 40) c.content[0..40] else c.content;
                        if (lab.len > 0) {
                            std.debug.print("{s} {s} custom_message {s} \"{s}\" [{s}]\n", .{ mark, id, c.customType, preview, lab });
                        } else {
                            std.debug.print("{s} {s} custom_message {s} \"{s}\"\n", .{ mark, id, c.customType, preview });
                        }
                    },
                    .custom => |c| {
                        if (lab.len > 0) {
                            std.debug.print("{s} {s} custom {s} [{s}]\n", .{ mark, id, c.customType, lab });
                        } else {
                            std.debug.print("{s} {s} custom {s}\n", .{ mark, id, c.customType });
                        }
                    },
                    .session_info => |s| {
                        if (lab.len > 0) {
                            std.debug.print("{s} {s} session_info {s} [{s}]\n", .{ mark, id, s.name orelse "(null)", lab });
                        } else {
                            std.debug.print("{s} {s} session_info {s}\n", .{ mark, id, s.name orelse "(null)" });
                        }
                    },
                    .tool_call => |tc| {
                        if (lab.len > 0) {
                            std.debug.print("{s} {s} tool_call {s} arg={s} [{s}]\n", .{ mark, id, tc.tool, tc.arg, lab });
                        } else {
                            std.debug.print("{s} {s} tool_call {s} arg={s}\n", .{ mark, id, tc.tool, tc.arg });
                        }
                    },
                    .tool_result => |tr| {
                        if (lab.len > 0) {
                            std.debug.print("{s} {s} tool_result {s} ok={any} [{s}]\n", .{ mark, id, tr.tool, tr.ok, lab });
                        } else {
                            std.debug.print("{s} {s} tool_result {s} ok={any}\n", .{ mark, id, tr.tool, tr.ok });
                        }
                    },
                    .summary => |s| {
                        const preview = if (s.summary.len > 40) s.summary[0..40] else s.summary;
                        if (lab.len > 0) {
                            std.debug.print("{s} {s} summary \"{s}\" [{s}]\n", .{ mark, id, preview, lab });
                        } else {
                            std.debug.print("{s} {s} summary \"{s}\"\n", .{ mark, id, preview });
                        }
                    },
                    .branch_summary => |b| {
                        const preview = if (b.summary.len > 40) b.summary[0..40] else b.summary;
                        if (lab.len > 0) {
                            std.debug.print("{s} {s} branch_summary from={s} \"{s}\" [{s}]\n", .{ mark, id, b.fromId, preview, lab });
                        } else {
                            std.debug.print("{s} {s} branch_summary from={s} \"{s}\"\n", .{ mark, id, b.fromId, preview });
                        }
                    },
                    .thinking_level_change => |t| {
                        if (lab.len > 0) {
                            std.debug.print("{s} {s} thinking_level_change {s} [{s}]\n", .{ mark, id, t.thinkingLevel, lab });
                        } else {
                            std.debug.print("{s} {s} thinking_level_change {s}\n", .{ mark, id, t.thinkingLevel });
                        }
                    },
                    .model_change => |m| {
                        if (lab.len > 0) {
                            std.debug.print("{s} {s} model_change {s}/{s} [{s}]\n", .{ mark, id, m.provider, m.modelId, lab });
                        } else {
                            std.debug.print("{s} {s} model_change {s}/{s}\n", .{ mark, id, m.provider, m.modelId });
                        }
                    },
                    else => {},
                }

                const key = st.parentIdOf(e) orelse "";
                _ = key;

                if (children_map.get(id)) |kids| {
                    for (kids.items) |kid| {
                        printNode(alloc, by_id_map, children_map, labels_map, path_map, kid, depth + 1, maxd, show_turns_flag);
                    }
                }
            }
        };

        // roots are nodes whose parentId is null/""
        if (children.get("")) |roots| {
            for (roots.items) |rid| {
                Printer.printNode(allocator, &by_id, &children, &labels, &on_path, rid, 0, max_depth, show_turns);
            }
        }

        return;
    }

    if (std.mem.eql(u8, cmd, "branch")) {
        var session_path: ?[]const u8 = null;
        var to_id: ?[]const u8 = null;
        var to_root = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--to")) {
                to_id = args.next() orelse return error.MissingTo;
            } else if (std.mem.eql(u8, a, "--root")) {
                to_root = true;
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
                return;
            } else {
                return error.UnknownArg;
            }
        }
        const sp = session_path orelse {
            usage();
            return;
        };
        var sm = session.SessionManager.init(allocator, sp, ".");
        try sm.ensure();
        if (to_root and to_id != null) return error.InvalidBranchTarget;
        const target_id: ?[]const u8 = if (to_root) null else (to_id orelse return error.MissingTo);
        try sm.branchTo(target_id);
        std.debug.print("ok: true\nbranch: {s} -> {s}\n", .{ sp, target_id orelse "(root)" });
        return;
    }

    if (std.mem.eql(u8, cmd, "branch-with-summary")) {
        var session_path: ?[]const u8 = null;
        var to_id: ?[]const u8 = null;
        var to_root = false;
        var summary_text: ?[]const u8 = null;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--to")) {
                to_id = args.next() orelse return error.MissingTo;
            } else if (std.mem.eql(u8, a, "--root")) {
                to_root = true;
            } else if (std.mem.eql(u8, a, "--summary")) {
                summary_text = args.next() orelse return error.MissingLabel;
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
                return;
            } else {
                return error.UnknownArg;
            }
        }
        const sp = session_path orelse {
            usage();
            return;
        };

        var sm = session.SessionManager.init(allocator, sp, ".");
        try sm.ensure();
        if (to_root and to_id != null) return error.InvalidBranchTarget;
        const target_id: ?[]const u8 = if (to_root) null else (to_id orelse return error.MissingTo);
        const old_leaf = try sm.leafId();
        const summary = summary_text orelse try buildAutoBranchSummary(allocator, &sm, old_leaf, target_id);
        const abandoned = try collectAbandonedEntries(allocator, &sm, old_leaf, target_id);
        const file_ops = try collectBranchSummaryFileOps(allocator, abandoned);
        const details_json = try branchSummaryDetailsJson(allocator, file_ops.readFiles, file_ops.modifiedFiles);
        try sm.branchTo(target_id);
        const from_id = old_leaf orelse "root";
        const sid = try sm.appendBranchSummaryWithDetails(from_id, summary, details_json, false);
        std.debug.print("ok: true\nbranch: {s} -> {s}\nbranchSummaryId: {s}\n", .{ sp, target_id orelse "(root)", sid });
        return;
    }

    if (std.mem.eql(u8, cmd, "set-model")) {
        var session_path: ?[]const u8 = null;
        var provider: ?[]const u8 = null;
        var model_id: ?[]const u8 = null;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--provider")) {
                provider = args.next() orelse return error.MissingLabel;
            } else if (std.mem.eql(u8, a, "--model")) {
                model_id = args.next() orelse return error.MissingId;
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
                return;
            } else {
                return error.UnknownArg;
            }
        }
        const sp = session_path orelse {
            usage();
            return;
        };
        const p = provider orelse {
            usage();
            return;
        };
        const mid = model_id orelse {
            usage();
            return;
        };

        var sm = session.SessionManager.init(allocator, sp, ".");
        try sm.ensure();
        const id = try sm.appendModelChange(p, mid);
        std.debug.print("ok: true\nmodelChangeId: {s}\nprovider: {s}\nmodel: {s}\n", .{ id, p, mid });
        return;
    }

    if (std.mem.eql(u8, cmd, "set-thinking")) {
        var session_path: ?[]const u8 = null;
        var level: ?[]const u8 = null;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--level")) {
                level = args.next() orelse return error.MissingLabel;
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
                return;
            } else {
                return error.UnknownArg;
            }
        }
        const sp = session_path orelse {
            usage();
            return;
        };
        const lv = level orelse {
            usage();
            return;
        };

        var sm = session.SessionManager.init(allocator, sp, ".");
        try sm.ensure();
        const id = try sm.appendThinkingLevelChange(lv);
        std.debug.print("ok: true\nthinkingLevelChangeId: {s}\nlevel: {s}\n", .{ id, lv });
        return;
    }

    if (std.mem.eql(u8, cmd, "session-name")) {
        var session_path: ?[]const u8 = null;
        var set_name: ?[]const u8 = null;
        var clear = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--set")) {
                set_name = args.next() orelse return error.MissingLabel;
            } else if (std.mem.eql(u8, a, "--clear")) {
                clear = true;
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
                return;
            } else {
                return error.UnknownArg;
            }
        }
        const sp = session_path orelse {
            usage();
            return;
        };
        if (set_name != null and clear) return error.InvalidSessionNameAction;

        var sm = session.SessionManager.init(allocator, sp, ".");
        try sm.ensure();
        if (set_name != null or clear) {
            const applied_name: ?[]const u8 = if (clear) null else blk: {
                const trimmed = std.mem.trim(u8, set_name.?, " \t\r\n");
                if (trimmed.len == 0) return error.InvalidSessionName;
                break :blk trimmed;
            };
            const id = try sm.appendSessionInfo(applied_name);
            if (clear) {
                std.debug.print("ok: true\nsessionInfoId: {s}\nname: (null)\n", .{id});
            } else {
                std.debug.print("ok: true\nsessionInfoId: {s}\nname: {s}\n", .{ id, applied_name.? });
            }
        } else {
            const cur = try sm.latestSessionName();
            std.debug.print("ok: true\nname: {s}\n", .{cur orelse "(null)"});
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "session-migrate")) {
        var session_path: ?[]const u8 = null;
        var out_path: ?[]const u8 = null;
        var dry_run = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--out")) {
                out_path = args.next() orelse return error.MissingOut;
            } else if (std.mem.eql(u8, a, "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
                return;
            } else {
                return error.UnknownArg;
            }
        }

        const sp = session_path orelse {
            usage();
            return;
        };

        const stt = try migrateSessionFile(allocator, sp, out_path, dry_run);
        std.debug.print(
            "ok: true\nsession: {s}\nout: {s}\ndryRun: {any}\nchangedLines: {d}\ntotalLines: {d}\nparseErrors: {d}\nchanged: timestamp={d} session={d} message={d} leaf={d} label={d}\n",
            .{
                sp,
                out_path orelse sp,
                dry_run,
                stt.changedLines,
                stt.totalLines,
                stt.parseErrors,
                stt.timestampChanged,
                stt.sessionChanged,
                stt.messageChanged,
                stt.leafChanged,
                stt.labelChanged,
            },
        );
        return;
    }

    if (std.mem.eql(u8, cmd, "replay")) {
        var session_path: ?[]const u8 = null;
        var show_turns = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--show-turns")) {
                show_turns = true;
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
                return;
            } else {
                return error.UnknownArg;
            }
        }
        const sp = session_path orelse {
            usage();
            return;
        };

        var sm = session.SessionManager.init(allocator, sp, ".");
        try sm.ensure();
        const entries = if (show_turns) try sm.buildContextEntriesVerbose() else try sm.buildContextEntries();
        for (entries) |e| {
            switch (e) {
                .turn_start => |t| {
                    if (show_turns) {
                        std.debug.print("[turn_start] {d} userMessageId={s} group={s} phase={s}\n", .{ t.turn, t.userMessageId orelse "-", t.turnGroupId orelse "-", t.phase orelse "-" });
                    }
                },
                .turn_end => |t| {
                    if (show_turns) {
                        std.debug.print("[turn_end] {d} userMessageId={s} group={s} phase={s}\n", .{ t.turn, t.userMessageId orelse "-", t.turnGroupId orelse "-", t.phase orelse "-" });
                    }
                },
                .message => |m| std.debug.print("[{s}] {s}\n", .{ m.role, m.content }),
                .custom_message => |c| std.debug.print("[custom_message:{s}] {s}\n", .{ c.customType, c.content }),
                .custom => |c| std.debug.print("[custom] {s}\n", .{c.customType}),
                .session_info => |s| std.debug.print("[session_info] name={s}\n", .{s.name orelse "(null)"}),
                .tool_call => |tc| std.debug.print("[tool_call] {s} arg={s}\n", .{ tc.tool, tc.arg }),
                .tool_result => |tr| std.debug.print("[tool_result] {s} ok={any} {s}\n", .{ tr.tool, tr.ok, tr.content }),
                .branch_summary => |b| std.debug.print("[branch_summary] from={s}\n{s}\n", .{ b.fromId, b.summary }),
                .thinking_level_change => |t| std.debug.print("[thinking_level_change] {s}\n", .{t.thinkingLevel}),
                .model_change => |m| std.debug.print("[model_change] {s}/{s}\n", .{ m.provider, m.modelId }),
                .summary => |s| {
                    if (std.mem.eql(u8, s.format, "json")) {
                        // Pretty render JSON summary (brief)
                        var parsed = std.json.parseFromSlice(std.json.Value, allocator, s.summary, .{}) catch {
                            std.debug.print("[summary] (invalid json) {s}\n", .{s.summary});
                            break;
                        };
                        defer parsed.deinit();
                        const obj = switch (parsed.value) {
                            .object => |o| o,
                            else => {
                                std.debug.print("[summary] {s}\n", .{s.summary});
                                break;
                            },
                        };
                        const raw = if (obj.get("raw")) |v| switch (v) {
                            .string => |t| t,
                            else => "",
                        } else "";
                        const next_steps = if (obj.get("next_steps")) |v| switch (v) {
                            .array => |a| a.items,
                            else => &.{},
                        } else &.{};

                        std.debug.print("[summary] raw:\n{s}\n", .{raw});
                        if (next_steps.len > 0) {
                            std.debug.print("[summary] next_steps:\n", .{});
                            for (next_steps) |it| {
                                const s2 = switch (it) {
                                    .string => |t| t,
                                    else => "",
                                };
                                if (s2.len > 0) std.debug.print("- {s}\n", .{s2});
                            }
                        }
                    } else {
                        std.debug.print("[summary] {s}\n", .{s.summary});
                    }
                },
                .label => |l| std.debug.print("[label] {s} -> {s}\n", .{ l.targetId, l.label orelse "(null)" }),
                .session, .leaf => {},
            }
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "chat")) {
        var session_path: ?[]const u8 = null;
        var allow_shell = false;
        var auto_compact = false;
        var max_chars: usize = 8_000;
        var max_tokens_est: usize = 2_000;
        var keep_last: usize = 8;
        var keep_last_groups: ?usize = null;

        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--allow-shell")) {
                allow_shell = true;
            } else if (std.mem.eql(u8, a, "--auto-compact")) {
                auto_compact = true;
            } else if (std.mem.eql(u8, a, "--max-chars")) {
                const s = args.next() orelse return error.MissingMaxChars;
                max_chars = try std.fmt.parseInt(usize, s, 10);
            } else if (std.mem.eql(u8, a, "--max-tokens-est")) {
                const s = args.next() orelse return error.MissingMaxTokensEst;
                max_tokens_est = try std.fmt.parseInt(usize, s, 10);
            } else if (std.mem.eql(u8, a, "--keep-last")) {
                const s = args.next() orelse return error.MissingKeepLast;
                keep_last = try std.fmt.parseInt(usize, s, 10);
            } else if (std.mem.eql(u8, a, "--keep-last-groups")) {
                const s = args.next() orelse return error.MissingKeepLast;
                keep_last_groups = try std.fmt.parseInt(usize, s, 10);
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
                return;
            } else {
                return error.UnknownArg;
            }
        }
        const sp = session_path orelse {
            usage();
            return;
        };

        var sm = session.SessionManager.init(allocator, sp, ".");
        try sm.ensure();
        var reg = tools.ToolRegistry.init(allocator);
        reg.allow_shell = allow_shell;

        var bus = events.EventBus.init(allocator);
        // Print all events (MVP: debug-style)
        const PrinterCtx = struct {};
        const printer = struct {
            fn onEvent(_: *anyopaque, ev: events.Event) void {
                switch (ev) {
                    .turn_start => |p| std.debug.print("[turn_start] {d}\n", .{p.turn}),
                    .turn_end => |p| std.debug.print("[turn_end] {d}\n", .{p.turn}),
                    .message_append => |m| std.debug.print("[message_append] {s}: {s}\n", .{ m.role, m.content }),
                    .tool_execution_start => |t| std.debug.print("[tool_start] {s} arg={s}\n", .{ t.tool, t.arg }),
                    .tool_execution_end => |t| std.debug.print("[tool_end] {s} ok={any}\n", .{ t.tool, t.ok }),
                }
            }
        };
        var ctx = PrinterCtx{};
        try bus.subscribe(@ptrCast(&ctx), printer.onEvent);

        var loop = agent_loop.AgentLoop.init(allocator, &sm, &reg, &bus);

        std.debug.print("chat session: {s}\n", .{sp});
        std.debug.print("type messages. ctrl-d to exit.\n", .{});

        const stdin_file = std.fs.File.stdin();
        var reader = std.fs.File.deprecatedReader(stdin_file);
        var buf: [4096]u8 = undefined;
        while (true) {
            std.debug.print("> ", .{});
            const line_opt = try reader.readUntilDelimiterOrEof(&buf, '\n');
            if (line_opt == null) break;
            const line = std.mem.trim(u8, line_opt.?, " \t\r\n");
            if (line.len == 0) continue;

            _ = try sm.appendMessageWithTokensEst("user", line, (line.len + 3) / 4);

            // Run model/tools until it returns a final_text (step() -> true)
            while (true) {
                const done = try loop.step();
                if (done) break;
            }

            if (auto_compact) {
                // TS-like: size estimate on business-only context (ignore structural entries)
                const chain = try sm.buildContextEntries();

                // TS parity: only size the "boundary" since the most recent summary.
                // This prevents old history (already summarized) from continuously re-triggering.
                var boundary_from: usize = 0;
                {
                    var k: usize = chain.len;
                    while (k > 0) : (k -= 1) {
                        const e = chain[k - 1];
                        switch (e) {
                            .summary => {
                                boundary_from = k; // start *after* the summary
                                break;
                            },
                            else => {},
                        }
                    }
                }

                var total: usize = 0;
                var idx: usize = boundary_from;
                while (idx < chain.len) : (idx += 1) {
                    const e = chain[idx];
                    switch (e) {
                        .message => |m| total += m.content.len,
                        .summary => |s| total += s.summary.len,
                        else => {},
                    }
                }
                const token_est = estimateBoundaryTokens(chain, boundary_from);
                const total_tokens_est = token_est.tokens;

                if (total > max_chars or total_tokens_est > max_tokens_est) {
                    const effective_keep_last: usize = if (keep_last_groups != null) 0 else keep_last;
                    const res = try doCompact(
                        allocator,
                        &sm,
                        effective_keep_last,
                        keep_last_groups,
                        false,
                        "AUTO_COMPACT",
                        "AUTO_COMPACT (naive):\n",
                        if (total > max_chars) "auto_chars" else "auto_tokens",
                        total,
                        total_tokens_est,
                        max_chars,
                        max_tokens_est,
                        false,
                    );
                    const mode = if (keep_last_groups != null) "groups" else "entries";
                    std.debug.print(
                        "[auto_compact] triggered chars={d}/{d} tokens_est={d}/{d} usage={d} trailing={d} (mode={s} keep_last={d} keep_last_groups={any}) summaryId={s}\n",
                        .{ total, max_chars, total_tokens_est, max_tokens_est, token_est.usageTokens, token_est.trailingTokens, mode, keep_last, keep_last_groups, res.summaryId.? },
                    );
                }
            }

            // Print last assistant message
            const msgs = try sm.loadMessages();
            var i: usize = msgs.len;
            while (i > 0) : (i -= 1) {
                const m = msgs[i - 1];
                if (std.mem.eql(u8, m.role, "assistant")) {
                    std.debug.print("{s}\n", .{m.content});
                    break;
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "verify")) {
        var run_id: ?[]const u8 = null;
        var out_dir: []const u8 = "runs";

        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--run")) {
                run_id = args.next() orelse return error.MissingRunId;
            } else if (std.mem.eql(u8, a, "--out")) {
                out_dir = args.next() orelse return error.MissingOut;
            } else if (std.mem.eql(u8, a, "--help")) {
                usage();
                return;
            } else {
                return error.UnknownArg;
            }
        }

        const rid = run_id orelse {
            usage();
            return;
        };

        try verifyRun(allocator, out_dir, rid);
        std.debug.print("ok: true\nverify: {s}/{s}\n", .{ out_dir, rid });
        return;
    }

    if (!std.mem.eql(u8, cmd, "run")) {
        usage();
        return;
    }

    var plan_path: ?[]const u8 = null;
    var out_dir: []const u8 = "runs";

    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--plan")) {
            plan_path = args.next() orelse return error.MissingPlan;
        } else if (std.mem.eql(u8, a, "--out")) {
            out_dir = args.next() orelse return error.MissingOut;
        } else if (std.mem.eql(u8, a, "--help")) {
            usage();
            return;
        } else {
            return error.UnknownArg;
        }
    }

    const pp = plan_path orelse {
        usage();
        return;
    };

    var parsed = try parseJsonFile(allocator, pp);
    defer parsed.deinit();

    const v = parsed.value;
    const obj = switch (v) {
        .object => |o| o,
        else => return error.InvalidPlan,
    };

    const schema_v = obj.get("schema") orelse return error.InvalidPlan;
    const workflow_v = obj.get("workflow") orelse return error.InvalidPlan;
    const steps_v = obj.get("steps") orelse return error.InvalidPlan;

    const schema = switch (schema_v) {
        .string => |s| s,
        else => return error.InvalidPlan,
    };
    if (!std.mem.eql(u8, schema, "pi.plan.v1")) return error.UnsupportedSchema;

    const workflow = switch (workflow_v) {
        .string => |s| s,
        else => return error.InvalidPlan,
    };

    const steps_arr = switch (steps_v) {
        .array => |a| a,
        else => return error.InvalidPlan,
    };

    // Build Plan struct with owned slices
    var steps_list = try allocator.alloc(root.Plan.Step, steps_arr.items.len);
    errdefer allocator.free(steps_list);

    for (steps_arr.items, 0..) |sv, i| {
        const so = switch (sv) {
            .object => |o| o,
            else => return error.InvalidPlan,
        };
        const id = switch (so.get("id") orelse return error.InvalidPlan) {
            .string => |s| s,
            else => return error.InvalidPlan,
        };
        const tool = switch (so.get("tool") orelse return error.InvalidPlan) {
            .string => |s| s,
            else => return error.InvalidPlan,
        };
        const params = so.get("params") orelse std.json.Value{ .object = so };

        var deps: [][]const u8 = &.{};
        if (so.get("dependsOn")) |deps_v| {
            const deps_arr = switch (deps_v) {
                .array => |a| a,
                else => return error.InvalidPlan,
            };
            var tmp = try allocator.alloc([]const u8, deps_arr.items.len);
            for (deps_arr.items, 0..) |dv, j| {
                tmp[j] = switch (dv) {
                    .string => |s| s,
                    else => return error.InvalidPlan,
                };
            }
            deps = tmp;
        }

        steps_list[i] = .{ .id = id, .tool = tool, .params = params, .dependsOn = deps };
    }

    const plan = root.Plan{ .schema = schema, .workflow = workflow, .steps = steps_list };

    var runner = root.Runner.init(allocator, out_dir);
    const run_id = try runner.run(&plan, v);

    std.debug.print("ok: true\nrunId: {s}\nout: {s}/{s}\n", .{ run_id, out_dir, run_id });
}

test "session-migrate backfills core TS compatibility fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const old_data =
        \\{"type":"session","version":1,"id":"s_old","timestamp":"1770000000000","cwd":"."}
        \\{"type":"message","id":"m1","parentId":null,"timestamp":"1770000000001","role":"user","content":"hello"}
        \\{"type":"leaf","timestamp":"1770000000002","targetId":"m1"}
        \\{"type":"message","id":"m2","parentId":"m1","timestamp":"1770000000003","message":{"role":"assistant","content":"ok","provider":"openai","model":"gpt-4.1","usage":{"totalTokens":42}}}
        \\{"type":"label","id":"l1","timestamp":"1770000000004","targetId":"m1","label":"ROOT"}
        \\
    ;

    {
        var f = try tmp.dir.createFile("old.jsonl", .{ .truncate = true });
        defer f.close();
        try f.writeAll(old_data);
    }

    const session_abs = try tmp.dir.realpathAlloc(allocator, "old.jsonl");

    const dry_stats = try migrateSessionFile(allocator, session_abs, null, true);
    try std.testing.expectEqual(@as(usize, 5), dry_stats.totalLines);
    try std.testing.expectEqual(@as(usize, 0), dry_stats.parseErrors);
    try std.testing.expectEqual(@as(usize, 5), dry_stats.changedLines);
    try std.testing.expectEqual(@as(usize, 5), dry_stats.timestampChanged);
    try std.testing.expectEqual(@as(usize, 1), dry_stats.sessionChanged);
    try std.testing.expectEqual(@as(usize, 2), dry_stats.messageChanged);
    try std.testing.expectEqual(@as(usize, 1), dry_stats.leafChanged);
    try std.testing.expectEqual(@as(usize, 1), dry_stats.labelChanged);

    _ = try migrateSessionFile(allocator, session_abs, null, false);

    const migrated = try readFileAlloc(allocator, session_abs);

    var lines = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, migrated, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        try lines.append(allocator, ln);
    }
    try std.testing.expectEqual(@as(usize, 5), lines.items.len);

    {
        var p = try std.json.parseFromSlice(std.json.Value, allocator, lines.items[0], .{});
        defer p.deinit();
        const o = switch (p.value) {
            .object => |obj| obj,
            else => return error.TestUnexpectedResult,
        };
        const ver = if (o.get("version")) |vv| switch (vv) {
            .integer => |x| x,
            else => return error.TestUnexpectedResult,
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(i64, 3), ver);
        const ts = if (o.get("timestamp")) |tv| valueAsString(tv) orelse return error.TestUnexpectedResult else return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOfScalar(u8, ts, 'T') != null);
        try std.testing.expect(std.mem.endsWith(u8, ts, "Z"));
    }

    {
        var p = try std.json.parseFromSlice(std.json.Value, allocator, lines.items[1], .{});
        defer p.deinit();
        const o = switch (p.value) {
            .object => |obj| obj,
            else => return error.TestUnexpectedResult,
        };
        const msgv = o.get("message") orelse return error.TestUnexpectedResult;
        switch (msgv) {
            .object => |mobj| {
                const role = if (mobj.get("role")) |rv| valueAsString(rv) orelse return error.TestUnexpectedResult else return error.TestUnexpectedResult;
                const content = if (mobj.get("content")) |cv| valueAsString(cv) orelse return error.TestUnexpectedResult else return error.TestUnexpectedResult;
                try std.testing.expectEqualStrings("user", role);
                try std.testing.expectEqualStrings("hello", content);
            },
            else => return error.TestUnexpectedResult,
        }
    }

    {
        var p = try std.json.parseFromSlice(std.json.Value, allocator, lines.items[2], .{});
        defer p.deinit();
        const o = switch (p.value) {
            .object => |obj| obj,
            else => return error.TestUnexpectedResult,
        };
        const leaf_id = if (o.get("id")) |v| valueAsString(v) orelse return error.TestUnexpectedResult else return error.TestUnexpectedResult;
        const leaf_pid = if (o.get("parentId")) |v| valueAsString(v) orelse return error.TestUnexpectedResult else return error.TestUnexpectedResult;
        try std.testing.expect(leaf_id.len > 0);
        try std.testing.expectEqualStrings("m1", leaf_pid);
    }

    {
        var p = try std.json.parseFromSlice(std.json.Value, allocator, lines.items[3], .{});
        defer p.deinit();
        const o = switch (p.value) {
            .object => |obj| obj,
            else => return error.TestUnexpectedResult,
        };
        const role = if (o.get("role")) |v| valueAsString(v) orelse return error.TestUnexpectedResult else return error.TestUnexpectedResult;
        const content = if (o.get("content")) |v| valueAsString(v) orelse return error.TestUnexpectedResult else return error.TestUnexpectedResult;
        const provider = if (o.get("provider")) |v| valueAsString(v) orelse return error.TestUnexpectedResult else return error.TestUnexpectedResult;
        const model = if (o.get("model")) |v| valueAsString(v) orelse return error.TestUnexpectedResult else return error.TestUnexpectedResult;
        const utt = if (o.get("usageTotalTokens")) |v| valueAsUsize(v) orelse return error.TestUnexpectedResult else return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("assistant", role);
        try std.testing.expectEqualStrings("ok", content);
        try std.testing.expectEqualStrings("openai", provider);
        try std.testing.expectEqualStrings("gpt-4.1", model);
        try std.testing.expectEqual(@as(usize, 42), utt);

        const msgv = o.get("message") orelse return error.TestUnexpectedResult;
        switch (msgv) {
            .object => |mobj| {
                const nested_provider = if (mobj.get("provider")) |v| valueAsString(v) orelse return error.TestUnexpectedResult else return error.TestUnexpectedResult;
                const nested_model = if (mobj.get("model")) |v| valueAsString(v) orelse return error.TestUnexpectedResult else return error.TestUnexpectedResult;
                try std.testing.expectEqualStrings("openai", nested_provider);
                try std.testing.expectEqualStrings("gpt-4.1", nested_model);
            },
            else => return error.TestUnexpectedResult,
        }
    }

    {
        var p = try std.json.parseFromSlice(std.json.Value, allocator, lines.items[4], .{});
        defer p.deinit();
        const o = switch (p.value) {
            .object => |obj| obj,
            else => return error.TestUnexpectedResult,
        };
        const label_pid = if (o.get("parentId")) |v| valueAsString(v) orelse return error.TestUnexpectedResult else return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("m2", label_pid);
    }
}

test "session-migrate supports --out style non-destructive migration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const old_data =
        \\{"type":"session","version":1,"id":"s_old","timestamp":"1770000000000","cwd":"."}
        \\{"type":"message","id":"m1","parentId":null,"timestamp":"1770000000001","role":"user","content":"hello"}
        \\
    ;

    {
        var f = try tmp.dir.createFile("src.jsonl", .{ .truncate = true });
        defer f.close();
        try f.writeAll(old_data);
    }
    {
        var f = try tmp.dir.createFile("out.jsonl", .{ .truncate = true });
        defer f.close();
    }

    const src_abs = try tmp.dir.realpathAlloc(allocator, "src.jsonl");
    const out_abs = try tmp.dir.realpathAlloc(allocator, "out.jsonl");

    _ = try migrateSessionFile(allocator, src_abs, out_abs, false);

    const src_after = try readFileAlloc(allocator, src_abs);
    const out_after = try readFileAlloc(allocator, out_abs);

    try std.testing.expect(std.mem.indexOf(u8, src_after, "\"version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_after, "\"version\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_after, "\"message\":") != null);
}

test "estimateBoundaryTokens uses assistant usage snapshot with trailing estimates" {
    const entries = [_]st.Entry{
        .{ .message = .{
            .id = "m0",
            .timestamp = "t0",
            .role = "user",
            .content = "hi",
        } },
        .{ .message = .{
            .id = "m1",
            .timestamp = "t1",
            .role = "assistant",
            .content = "assistant summary",
            .usageTotalTokens = 120,
        } },
        .{ .tool_call = .{
            .id = "tc1",
            .timestamp = "t2",
            .tool = "shell",
            .arg = "echo hi",
        } },
        .{ .tool_result = .{
            .id = "tr1",
            .timestamp = "t3",
            .tool = "shell",
            .ok = true,
            .content = "ok",
        } },
    };

    const est = estimateBoundaryTokens(&entries, 0);
    try std.testing.expectEqual(@as(usize, 120), est.usageTokens);
    try std.testing.expectEqual(@as(usize, 19), est.trailingTokens); // 10 + 9
    try std.testing.expectEqual(@as(usize, 139), est.tokens);
    try std.testing.expectEqual(@as(?usize, 1), est.lastUsageIndex);

    const est_tail = estimateBoundaryTokens(&entries, 2);
    try std.testing.expectEqual(@as(usize, 0), est_tail.usageTokens);
    try std.testing.expectEqual(@as(usize, 19), est_tail.trailingTokens);
    try std.testing.expectEqual(@as(usize, 19), est_tail.tokens);
}

test "collectBranchSummaryFileOps scans shell commands and detail payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]st.Entry{
        .{ .tool_call = .{
            .id = "tc_read",
            .timestamp = "t0",
            .tool = "shell",
            .arg = "cat src/main.zig",
        } },
        .{ .tool_call = .{
            .id = "tc_write",
            .timestamp = "t1",
            .tool = "shell",
            .arg = "echo hello > src/out.txt",
        } },
        .{ .summary = .{
            .id = "s1",
            .timestamp = "t2",
            .summary = "old summary",
            .readFiles = &.{ "old-read.md" },
            .modifiedFiles = &.{ "old-mod.md" },
            .fromHook = false,
        } },
        .{ .summary = .{
            .id = "s2",
            .timestamp = "t3",
            .summary = "ignored summary",
            .fromHook = true,
            .readFiles = &.{ "ignored.md" },
        } },
        .{ .summary = .{
            .id = "s3",
            .timestamp = "t4",
            .summary = "old summary with details",
            .detailsJson = "{\"readFiles\":[\"old-detail-read.md\"],\"modifiedFiles\":[\"old-detail-mod.md\"]}",
        } },
        .{ .branch_summary = .{
            .id = "bs1",
            .timestamp = "t5",
            .fromId = "from1",
            .summary = "branch summary",
            .detailsJson = "{\"readFiles\":[\"bs-read.txt\"],\"modifiedFiles\":[\"bs-mod.txt\"]}",
            .fromHook = null,
        } },
    };

    const ops = try collectBranchSummaryFileOps(allocator, &entries);

    var seen_read = false;
    var seen_old_read = false;
    var seen_detail_read = false;
    var seen_bs_read = false;
    for (ops.readFiles) |path| {
        if (std.mem.eql(u8, path, "src/main.zig")) seen_read = true;
        if (std.mem.eql(u8, path, "old-read.md")) seen_old_read = true;
        if (std.mem.eql(u8, path, "old-detail-read.md")) seen_detail_read = true;
        if (std.mem.eql(u8, path, "bs-read.txt")) seen_bs_read = true;
    }
    try std.testing.expect(seen_read);
    try std.testing.expect(seen_old_read);
    try std.testing.expect(seen_detail_read);
    try std.testing.expect(seen_bs_read);

    var seen_mod = false;
    var seen_old_mod = false;
    var seen_bs_mod = false;
    for (ops.modifiedFiles) |path| {
        if (std.mem.eql(u8, path, "src/out.txt")) seen_mod = true;
        if (std.mem.eql(u8, path, "old-mod.md")) seen_old_mod = true;
        if (std.mem.eql(u8, path, "bs-mod.txt")) seen_bs_mod = true;
    }
    try std.testing.expect(seen_mod);
    try std.testing.expect(seen_old_mod);
    try std.testing.expect(seen_bs_mod);

    const details = try branchSummaryDetailsJson(
        allocator,
        ops.readFiles,
        ops.modifiedFiles,
    ) orelse "";

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, details, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    const reads = switch (obj.get("readFiles") orelse return error.TestUnexpectedResult) {
        .array => |a| a.items,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(reads.len >= 4);
}
