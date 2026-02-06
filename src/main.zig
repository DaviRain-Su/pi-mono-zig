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
        \\  pi-mono-zig branch --session <path.jsonl> --to <entryId>\n\
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
        .message => |m| tokensEstFromChars(m.content.len),
        // tool call/results tend to be denser / more verbose
        .tool_call => |tc| tokensEstFromChars(tc.arg.len) + 8,
        .tool_result => |tr| tokensEstFromChars(tr.content.len) + 8,
        .turn_start => 2,
        .turn_end => 2,
        .summary => |s| tokensEstFromChars(s.content.len),
        else => 0,
    };
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

    // Choose cut start.
    var start: usize = if (n > keep_last) n - keep_last else 0;
    if (keep_last_groups) |kg| {
        // Keep the last N complete turn-groups (best-effort).
        // We find the boundary end-of-group that precedes the kept groups.
        // Example: kg=1 => keep last group => boundary is the END of the previous group (count == kg+1).
        var count: usize = 0;
        var idx: usize = n;
        while (idx > 0) : (idx -= 1) {
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
        // If there aren't enough groups to skip, keep everything.
        if (count <= kg) start = 0;
        if (start > n) start = n;
    }

    // TS-ish compaction cut alignment:
    // 1) Avoid starting the kept tail with a tool_result (which would split tool_call/tool_result pairs).
    // 2) Prefer to start the tail at a user message (turn boundary heuristic).
    while (start > 0 and start < n) {
        const e = nodes.items[start];
        switch (e) {
            .tool_result => start -= 1,
            else => break,
        }
    }

    // Turn-group boundary: move start backwards until it is immediately AFTER a persisted turn_end
    // that represents the end of a complete group (phase="final"|"error").
    // This avoids splitting multi-step turns that share the same turnGroupId.
    while (start > 0) {
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

    var sum_buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer sum_buf.deinit(allocator);

    const want_json = std.mem.eql(u8, prefix, "SUMMARY_JSON");
    const want_md = std.mem.eql(u8, prefix, "SUMMARY_MD");

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
            blocked: []const []const u8,
        };
        const Payload = struct {
            schema: []const u8,
            goal: []const u8,
            constraints: []const []const u8,
            progress: Progress,
            key_decisions: []const []const u8,
            next_steps: []const []const u8,
            critical_context: []const []const u8,
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
                            const parsed = std.json.parseFromSlice(std.json.Value, allocator, s.content, .{}) catch break;
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

                            const schema = if (obj.get("schema")) |v| switch (v) { .string => |t| try dupStr.dup(allocator, t), else => "pi.summary.v1" } else "pi.summary.v1";
                            const goal = if (obj.get("goal")) |v| switch (v) { .string => |t| try dupStr.dup(allocator, t), else => "(unknown)" } else "(unknown)";

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

                            const raw = if (obj.get("raw")) |v| switch (v) { .string => |t| try dupStr.dup(allocator, t), else => "" } else "";

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

        var i: usize = from_i;
        while (i < start) : (i += 1) {
            const e = nodes.items[i];
            switch (e) {
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
                    }
                },
                else => {},
            }
        }

        const base = prev_payload orelse Payload{
            .schema = "pi.summary.v1",
            .goal = "(unknown)",
            .constraints = &.{},
            .progress = .{ .done = &.{}, .in_progress = &.{}, .blocked = &.{} },
            .key_decisions = &.{},
            .next_steps = &.{},
            .critical_context = &.{},
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
        var done_seen = std.StringHashMap(bool).init(allocator);
        defer done_seen.deinit();
        var ctx_seen = std.StringHashMap(bool).init(allocator);
        defer ctx_seen.deinit();
        var cons_seen = std.StringHashMap(bool).init(allocator);
        defer cons_seen.deinit();
        var dec_seen = std.StringHashMap(bool).init(allocator);
        defer dec_seen.deinit();

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

        // Seed seen maps with base items so we don't duplicate.
        for (base.next_steps) |it| try next_seen.put(it, true);
        for (base.progress.done) |it| try done_seen.put(it, true);
        for (base.critical_context) |it| try ctx_seen.put(it, true);
        for (base.constraints) |it| try cons_seen.put(it, true);
        for (base.key_decisions) |it| try dec_seen.put(it, true);

        // Start with base lists (capped).
        try Merge.uniqueAppend(allocator, &next_out, &next_seen, base.next_steps, MAX_NEXT);
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

        // Append new items.
        try Merge.uniqueAppend(allocator, &next_out, &next_seen, new_next.items, MAX_NEXT);
        try Merge.uniqueAppend(allocator, &done_out, &done_seen, new_done.items, MAX_DONE);
        try Merge.uniqueAppend(allocator, &cons_out, &cons_seen, new_constraints.items, 20);
        try Merge.uniqueAppend(allocator, &dec_out, &dec_seen, new_decisions.items, 20);

        // Sync in_progress with next steps: add items not in done.
        for (new_next.items) |it| {
            if (ip_out.items.len >= MAX_NEXT) break;
            if (done_seen.contains(it)) continue;
            if (std.mem.indexOf(u8, it, "(none)") != null) continue;
            // naive de-dup
            var already = false;
            for (ip_out.items) |x| if (std.mem.eql(u8, x, it)) { already = true; break; };
            if (already) continue;
            try ip_out.append(allocator, it);
        }
        try Merge.uniqueAppend(allocator, &ctx_out, &ctx_seen, new_ctx.items, MAX_CTX);

        // Heuristic: mark related user tasks as done based on ack: tool_result echo: <arg>
        // This lets us drop "echo: <arg>" from next_steps/in_progress.
        for (done_out.items) |d| {
            const prefix_echo = "ack: tool_result echo:";
            if (std.mem.startsWith(u8, d, prefix_echo)) {
                const arg = std.mem.trimLeft(u8, d[prefix_echo.len..], " ");
                const task = try std.fmt.allocPrint(allocator, "echo: {s}", .{arg});
                // do not cap; it just enriches done_seen
                _ = done_seen.put(task, true) catch {};
            }
        }

        // Post-process: remove next_steps that are already done.
        {
            var filtered = try std.ArrayList([]const u8).initCapacity(allocator, next_out.items.len);
            for (next_out.items) |it| {
                if (done_seen.contains(it)) continue;
                try filtered.append(allocator, it);
            }
            // NOTE: arena allocator; we intentionally don't deinit old list.
            next_out = filtered;
        }

        // Also drop done items from in_progress.
        {
            var filtered = try std.ArrayList([]const u8).initCapacity(allocator, ip_out.items.len);
            for (ip_out.items) |it| {
                if (done_seen.contains(it)) continue;
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

        const merged = Payload{
            .schema = base.schema,
            .goal = goal_out,
            .constraints = try cons_out.toOwnedSlice(allocator),
            .progress = .{ .done = try done_out.toOwnedSlice(allocator), .in_progress = try ip_out.toOwnedSlice(allocator), .blocked = base.progress.blocked },
            .key_decisions = try dec_out.toOwnedSlice(allocator),
            .next_steps = try next_out.toOwnedSlice(allocator),
            .critical_context = try ctx_out.toOwnedSlice(allocator),
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
                            prev_summary = s.content;
                            prev_idx = k - 1;
                            break;
                        }
                    },
                    else => {},
                }
            }
        }

        if (prev_summary == null) {
            // Naive fill: Goal unknown, Constraints none, Progress/NextSteps empty, Critical Context includes message snippets.
            try sum_buf.appendSlice(allocator,
                "## Goal\n(unknown)\n\n" ++
                "## Constraints & Preferences\n- (none)\n\n" ++
                "## Progress\n### Done\n- (none)\n\n### In Progress\n- (none)\n\n### Blocked\n- (none)\n\n" ++
                "## Key Decisions\n- (none)\n\n" ++
                "## Next Steps\n1. (none)\n\n" ++
                "## Critical Context\n");

            var i: usize = 0;
            while (i < start) : (i += 1) {
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
                    else => {},
                }
            }
            if (start == 0) {
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
            while (ii < start) : (ii += 1) {
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
                    try b2.appendSlice(allocator, base[0..insert_pos + next_hdr]);

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
                    try b2.appendSlice(allocator, base[0..insert_pos + next_hdr]);

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
            while (i < start) : (i += 1) {
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
                    else => {},
                }
            }
        }
    }

    const sum_text = try sum_buf.toOwnedSlice(allocator);

    if (dry_run) {
        return .{ .dryRun = true, .summaryText = sum_text, .summaryId = null };
    }

    const summary_id = try sm.appendSummary(
        sum_text,
        reason,
        if (want_json) "json" else if (want_md) "md" else "text",
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

    var j: usize = start;
    while (j < n) : (j += 1) {
        const e = nodes.items[j];
        switch (e) {
            .turn_start => |t| {
                _ = try sm.appendTurnStart(t.turn, t.userMessageId, t.turnGroupId, t.phase);
            },
            .turn_end => |t| {
                _ = try sm.appendTurnEnd(t.turn, t.userMessageId, t.turnGroupId, t.phase);
            },
            .message => |m| {
                _ = try sm.appendMessage(m.role, m.content);
            },
            .tool_call => |tc| {
                _ = try sm.appendToolCall(tc.tool, tc.arg);
            },
            .tool_result => |tr| {
                _ = try sm.appendToolResult(tr.tool, tr.ok, tr.content);
            },
            .summary => |s| {
                _ = try sm.appendSummary(
                    s.content,
                    s.reason,
                    s.format,
                    s.totalChars,
                    s.totalTokensEst,
                    s.keepLast,
                    s.keepLastGroups,
                    s.thresholdChars,
                    s.thresholdTokensEst,
                );
            },
            else => {},
        }
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
                    .summary => |s| std.debug.print(
                        "summary {s} parent={s}\nreason={s}\nformat={s}\nkeepLast={any} keepLastGroups={any}\nchars={any} tokens_est={any}\nthresh_chars={any} thresh_tokens_est={any}\ncontent=\n{s}\n",
                        .{ s.id, s.parentId orelse "(null)", s.reason orelse "(null)", s.format, s.keepLast, s.keepLastGroups, s.totalChars, s.totalTokensEst, s.thresholdChars, s.thresholdTokensEst, s.content },
                    ),
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
                    .tool_call => |tc| std.debug.print("{d}. {s} tool_call {s} arg={s} {s}\n", .{ idx, eid, tc.tool, tc.arg, if (lab.len > 0) lab else "" }),
                    .tool_result => |tr| std.debug.print("{d}. {s} tool_result {s} ok={any} {s}\n", .{ idx, eid, tr.tool, tr.ok, if (lab.len > 0) lab else "" }),
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

        // Stats snapshot (TS-like): compute totals for current leaf context
        const chain = try sm.buildContextEntries();
        var total_chars: usize = 0;
        var total_tokens_est: usize = 0;
        for (chain) |e| {
            switch (e) {
                .message => |m| total_chars += m.content.len,
                .summary => |s| total_chars += s.content.len,
                else => {},
            }
            total_tokens_est += tokensEstForEntry(e);
        }

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

        // find leaf
        var leaf: ?[]const u8 = null;
        for (entries) |e| {
            switch (e) {
                .leaf => |l| leaf = l.targetId,
                else => {},
            }
        }

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
                        const preview = if (s.content.len > 40) s.content[0..40] else s.content;
                        if (lab.len > 0) {
                            std.debug.print("{s} {s} summary \"{s}\" [{s}]\n", .{ mark, id, preview, lab });
                        } else {
                            std.debug.print("{s} {s} summary \"{s}\"\n", .{ mark, id, preview });
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
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--to")) {
                to_id = args.next() orelse return error.MissingTo;
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
        try sm.branchTo(to_id);
        std.debug.print("ok: true\nbranch: {s} -> {s}\n", .{ sp, to_id orelse "(null)" });
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
                .tool_call => |tc| std.debug.print("[tool_call] {s} arg={s}\n", .{ tc.tool, tc.arg }),
                .tool_result => |tr| std.debug.print("[tool_result] {s} ok={any} {s}\n", .{ tr.tool, tr.ok, tr.content }),
                .summary => |s| {
                    if (std.mem.eql(u8, s.format, "json")) {
                        // Pretty render JSON summary (brief)
                        var parsed = std.json.parseFromSlice(std.json.Value, allocator, s.content, .{}) catch {
                            std.debug.print("[summary] (invalid json) {s}\n", .{s.content});
                            break;
                        };
                        defer parsed.deinit();
                        const obj = switch (parsed.value) {
                            .object => |o| o,
                            else => {
                                std.debug.print("[summary] {s}\n", .{s.content});
                                break;
                            },
                        };
                        const raw = if (obj.get("raw")) |v| switch (v) { .string => |t| t, else => "" } else "";
                        const next_steps = if (obj.get("next_steps")) |v| switch (v) { .array => |a| a.items, else => &.{} } else &.{};

                        std.debug.print("[summary] raw:\n{s}\n", .{raw});
                        if (next_steps.len > 0) {
                            std.debug.print("[summary] next_steps:\n", .{});
                            for (next_steps) |it| {
                                const s2 = switch (it) { .string => |t| t, else => "" };
                                if (s2.len > 0) std.debug.print("- {s}\n", .{s2});
                            }
                        }
                    } else {
                        std.debug.print("[summary] {s}\n", .{s.content});
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

            _ = try sm.appendMessage("user", line);

            // Run model/tools until it returns a final_text (step() -> true)
            while (true) {
                const done = try loop.step();
                if (done) break;
            }

            if (auto_compact) {
                // TS-like: size estimate on business-only context (ignore structural entries)
                const chain = try sm.buildContextEntries();
                var total: usize = 0;
                var total_tokens_est: usize = 0;
                for (chain) |e| {
                    switch (e) {
                        .message => |m| total += m.content.len,
                        .summary => |s| total += s.content.len,
                        else => {},
                    }
                    total_tokens_est += tokensEstForEntry(e);
                }

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
                        "[auto_compact] triggered chars={d}/{d} tokens_est={d}/{d} (mode={s} keep_last={d} keep_last_groups={any}) summaryId={s}\n",
                        .{ total, max_chars, total_tokens_est, max_tokens_est, mode, keep_last, keep_last_groups, res.summaryId.? },
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
