const std = @import("std");
const root = @import("root.zig");
const session = @import("session_manager.zig");
const tools = @import("tools.zig");
const agent_loop = @import("agent_loop.zig");
const events = @import("events.zig");

fn usage() void {
    std.debug.print(
        \\pi-mono-zig (MVP)\n\n\
        \\Usage:\n\
        \\  pi-mono-zig run --plan <plan.json> [--out runs]\n\
        \\  pi-mono-zig verify --run <runId> [--out runs]\n\
        \\  pi-mono-zig chat --session <path.jsonl> [--allow-shell]\n\
        \\  pi-mono-zig replay --session <path.jsonl>\n\
        \\  pi-mono-zig branch --session <path.jsonl> --to <entryId>\n\n\
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
                .session, .leaf => {},
            }
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "chat")) {
        var session_path: ?[]const u8 = null;
        var allow_shell = false;
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--session")) {
                session_path = args.next() orelse return error.MissingSession;
            } else if (std.mem.eql(u8, a, "--allow-shell")) {
                allow_shell = true;
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
