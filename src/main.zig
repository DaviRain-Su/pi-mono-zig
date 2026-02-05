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
        \\  pi-mono-zig chat --session <path.jsonl> [--allow-shell] [--auto-compact --max-chars N --max-tokens-est N --keep-last N]\n\
        \\  pi-mono-zig replay --session <path.jsonl>\n\
        \\  pi-mono-zig branch --session <path.jsonl> --to <entryId>\n\
        \\  pi-mono-zig label --session <path.jsonl> --to <entryId> --label <name>\n\
        \\  pi-mono-zig list --session <path.jsonl>\n\
        \\  pi-mono-zig show --session <path.jsonl> --id <entryId>\n\
        \\  pi-mono-zig tree --session <path.jsonl> [--max-depth N]\n\
        \\  pi-mono-zig compact --session <path.jsonl> [--keep-last N] [--dry-run] [--label NAME] [--structured (md|json)] [--update]\n\n\
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
        .summary => |s| tokensEstFromChars(s.content.len),
        else => 0,
    };
}

fn doCompact(
    allocator: std.mem.Allocator,
    sm: *session.SessionManager,
    keep_last: usize,
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
    const chain = try sm.buildContextEntries();

    var nodes = try std.ArrayList(st.Entry).initCapacity(allocator, chain.len);
    defer nodes.deinit(allocator);
    for (chain) |e| {
        switch (e) {
            .session, .leaf, .label => {},
            else => try nodes.append(allocator, e),
        }
    }

    const n = nodes.items.len;
    const start = if (n > keep_last) n - keep_last else 0;

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
        // Structured JSON summary (simple fields)
        var progress = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer progress.deinit(allocator);
        var i: usize = 0;
        while (i < start) : (i += 1) {
            const e = nodes.items[i];
            switch (e) {
                .message => |m| {
                    if (std.mem.eql(u8, m.role, "user") or std.mem.eql(u8, m.role, "assistant")) {
                        const preview = if (m.content.len > 80) m.content[0..80] else m.content;
                        try progress.appendSlice(allocator, m.role);
                        try progress.appendSlice(allocator, ": ");
                        try progress.appendSlice(allocator, preview);
                        try progress.appendSlice(allocator, "\n");
                    }
                },
                else => {},
            }
        }
        const progress_s = try progress.toOwnedSlice(allocator);

        const payload = .{
            .schema = "pi.summary.v1",
            .goal = "(unknown)",
            .constraints = [_][]const u8{},
            .progress = .{ .done = [_][]const u8{}, .in_progress = [_][]const u8{}, .blocked = [_][]const u8{} },
            .key_decisions = [_][]const u8{},
            .next_steps = [_][]const u8{},
            .critical_context = [_][]const u8{},
            .raw = progress_s,
        };

        const written = try std.json.Stringify.valueAlloc(allocator, payload, .{ .whitespace = .indent_2 });
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
            // - If Next Steps is "1. (none)", replace with a placeholder actionable step.
            // - If Progress/In Progress is "- (none)", replace with a placeholder.
            // - Append new message snippets into Critical Context (existing behavior).
            const base0 = prev_summary.?;

            // Preprocess: patch a couple of common "(none)" placeholders.
            var base_buf = try std.ArrayList(u8).initCapacity(allocator, base0.len + 128);
            defer base_buf.deinit(allocator);

            const pat_next = "## Next Steps\n1. (none)\n";
            const rep_next = "## Next Steps\n1. Review new messages since last checkpoint\n";
            const pat_prog = "### In Progress\n- (none)\n";
            const rep_prog = "### In Progress\n- [ ] Review new messages since last checkpoint\n";

            const idx_next = std.mem.indexOf(u8, base0, pat_next);
            const idx_prog = std.mem.indexOf(u8, base0, pat_prog);

            // Apply replacements in a deterministic order by earliest match.
            var cursor: usize = 0;
            while (cursor < base0.len) {
                var next_pos: ?usize = null;
                var which: u8 = 0;

                if (idx_next) |p| {
                    if (p >= cursor and (next_pos == null or p < next_pos.?)) {
                        next_pos = p;
                        which = 1;
                    }
                }
                if (idx_prog) |p| {
                    if (p >= cursor and (next_pos == null or p < next_pos.?)) {
                        next_pos = p;
                        which = 2;
                    }
                }

                if (next_pos == null) {
                    try base_buf.appendSlice(allocator, base0[cursor..]);
                    break;
                }

                const p = next_pos.?;
                try base_buf.appendSlice(allocator, base0[cursor..p]);
                if (which == 1) {
                    try base_buf.appendSlice(allocator, rep_next);
                    cursor = p + pat_next.len;
                } else if (which == 2) {
                    try base_buf.appendSlice(allocator, rep_prog);
                    cursor = p + pat_prog.len;
                } else {
                    // should not happen
                    try base_buf.appendSlice(allocator, base0[p..]);
                    break;
                }
            }

            const base = try base_buf.toOwnedSlice(allocator);

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
            const from_i: usize = (prev_idx orelse 0) + 1;
            var i: usize = from_i;
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
                        "summary {s} parent={s}\nreason={s}\nformat={s}\nkeepLast={any}\nchars={any} tokens_est={any}\nthresh_chars={any} thresh_tokens_est={any}\ncontent=\n{s}\n",
                        .{ s.id, s.parentId orelse "(null)", s.reason orelse "(null)", s.format, s.keepLast, s.totalChars, s.totalTokensEst, s.thresholdChars, s.thresholdTokensEst, s.content },
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
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
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

        const entries = try sm.buildContextEntries();
        var idx: usize = 0;
        for (entries) |e| {
            idx += 1;
            if (st.idOf(e)) |eid| {
                const lab = labels.get(eid) orelse "";
                switch (e) {
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

        const res = try doCompact(
            allocator,
            &sm,
            keep_last,
            dry_run,
            label,
            if (structured and std.mem.eql(u8, structured_format, "json")) "SUMMARY_JSON" else if (structured) "SUMMARY_MD" else "SUMMARY (naive):\n",
            if (update_summary) "manual_update" else "manual",
            null,
            null,
            null,
            null,
            update_summary,
        );

        if (res.dryRun) {
            std.debug.print("ok: true\ndryRun: true\nsummaryPreview:\n{s}\n", .{res.summaryText});
            return;
        }

        std.debug.print("ok: true\ncompacted: {s}\nsummaryId: {s}\n", .{ sp, res.summaryId.? });
        return;
    }

    if (std.mem.eql(u8, cmd, "tree")) {
        var session_path: ?[]const u8 = null;
        var max_depth: usize = 64;

        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--max-depth")) {
                const s = args.next() orelse return error.MissingMaxDepth;
                max_depth = try std.fmt.parseInt(usize, s, 10);
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
                        printNode(alloc, by_id_map, children_map, labels_map, path_map, kid, depth + 1, maxd);
                    }
                }
            }
        };

        // roots are nodes whose parentId is null/""
        if (children.get("")) |roots| {
            for (roots.items) |rid| {
                Printer.printNode(allocator, &by_id, &children, &labels, &on_path, rid, 0, max_depth);
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
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
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
        const entries = try sm.buildContextEntries();
        for (entries) |e| {
            switch (e) {
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
                // naive context size estimate on current leaf path
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
                    const res = try doCompact(
                        allocator,
                        &sm,
                        keep_last,
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
                    std.debug.print(
                        "[auto_compact] triggered chars={d}/{d} tokens_est={d}/{d} (keep_last={d}) summaryId={s}\n",
                        .{ total, max_chars, total_tokens_est, max_tokens_est, keep_last, res.summaryId.? },
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
