const std = @import("std");
const root = @import("root.zig");

fn usage() void {
    std.debug.print(
        \\pi-mono-zig (MVP)\n\n\
        \\Usage:\n\
        \\  pi-mono-zig run --plan <plan.json> [--out runs]\n\
        \\  pi-mono-zig verify --run <runId> [--out runs]\n\n\
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
