const std = @import("std");

pub const Plan = struct {
    schema: []const u8,
    workflow: []const u8,
    steps: []Step,

    pub const Step = struct {
        id: []const u8,
        tool: []const u8,
        params: std.json.Value,
        dependsOn: [][]const u8,
    };
};

pub const Runner = struct {
    allocator: std.mem.Allocator,
    out_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, out_dir: []const u8) Runner {
        return .{ .allocator = allocator, .out_dir = out_dir };
    }

    fn nowMs() i64 {
        return std.time.milliTimestamp();
    }

    fn safeId(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
        var out = try allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| {
            const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
            out[i] = if (ok) c else '_';
        }
        return out;
    }

    fn writeJsonFile(path: []const u8, value: anytype) !void {
        var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer f.close();
        var buf: [16 * 1024]u8 = undefined;
        var fw = std.fs.File.Writer.init(f, &buf);
        try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &fw.interface);
        try fw.interface.writeByte('\n');
        _ = try fw.interface.flush();
    }

    fn ensureDir(path: []const u8) !void {
        std.fs.cwd().makePath(path) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }

    fn topoNext(done: *std.StringHashMap(bool), remaining: *std.StringHashMap(Plan.Step)) !?Plan.Step {
        var best: ?Plan.Step = null;
        var it = remaining.iterator();
        while (it.next()) |kv| {
            const step = kv.value_ptr.*;
            var all_ok = true;
            for (step.dependsOn) |d| {
                if (!done.contains(d)) {
                    all_ok = false;
                    break;
                }
            }
            if (!all_ok) continue;

            if (best) |b| {
                if (std.mem.lessThan(u8, step.id, b.id)) best = step;
            } else {
                best = step;
            }
        }
        return best;
    }

    fn toolEcho(allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        const obj = switch (params) {
            .object => |o| o,
            else => return error.InvalidParams,
        };
        const text_v = obj.get("text") orelse return error.InvalidParams;
        _ = switch (text_v) {
            .string => |s| s,
            else => return error.InvalidParams,
        };
        _ = allocator;
        return std.json.Value{ .object = obj };
    }

    fn toolSleepMs(params: std.json.Value) !std.json.Value {
        const obj = switch (params) {
            .object => |o| o,
            else => return error.InvalidParams,
        };
        const ms_v = obj.get("ms") orelse return error.InvalidParams;
        const ms_i: i64 = switch (ms_v) {
            .integer => |x| x,
            .float => |x| @as(i64, @intFromFloat(x)),
            else => return error.InvalidParams,
        };
        if (ms_i < 0 or ms_i > 60_000) return error.InvalidParams;
        std.Thread.sleep(@as(u64, @intCast(ms_i)) * std.time.ns_per_ms);
        return std.json.Value{ .object = obj };
    }

    fn runTool(self: *Runner, step: Plan.Step) !std.json.Value {
        if (std.mem.eql(u8, step.tool, "echo")) {
            return toolEcho(self.allocator, step.params);
        } else if (std.mem.eql(u8, step.tool, "sleep_ms")) {
            return toolSleepMs(step.params);
        }
        return error.UnknownTool;
    }

    pub fn run(self: *Runner, plan: *const Plan, plan_json: std.json.Value) ![]const u8 {
        const run_id = try std.fmt.allocPrint(self.allocator, "run_{d}_{s}", .{ nowMs(), plan.workflow });

        const run_path = try std.fs.path.join(self.allocator, &.{ self.out_dir, run_id });
        const steps_path = try std.fs.path.join(self.allocator, &.{ run_path, "steps" });
        try ensureDir(steps_path);

        // persist plan
        const plan_out = try std.fs.path.join(self.allocator, &.{ run_path, "plan.json" });
        try writeJsonFile(plan_out, plan_json);

        var done = std.StringHashMap(bool).init(self.allocator);
        defer done.deinit();

        var remaining = std.StringHashMap(Plan.Step).init(self.allocator);
        defer remaining.deinit();
        for (plan.steps) |s| {
            try remaining.put(s.id, s);
        }

        while (remaining.count() > 0) {
            const next = try topoNext(&done, &remaining);
            if (next == null) return error.NoRunnableSteps;
            const step = next.?;

            const started = nowMs();
            const output = self.runTool(step) catch |e| {
                const sid = try safeId(self.allocator, step.id);
                const step_file = try std.fs.path.join(self.allocator, &.{ steps_path, try std.fmt.allocPrint(self.allocator, "{s}.json", .{sid}) });
                const finished = nowMs();
                const artifact = .{
                    .schema = "pi.step.v1",
                    .runId = run_id,
                    .stepId = step.id,
                    .tool = step.tool,
                    .dependsOn = step.dependsOn,
                    .startedAtMs = started,
                    .finishedAtMs = finished,
                    .ok = false,
                    .err = @errorName(e),
                };
                try writeJsonFile(step_file, artifact);
                return e;
            };
            const finished = nowMs();

            const sid = try safeId(self.allocator, step.id);
            const step_file = try std.fs.path.join(self.allocator, &.{ steps_path, try std.fmt.allocPrint(self.allocator, "{s}.json", .{sid}) });
            const artifact = .{
                .schema = "pi.step.v1",
                .runId = run_id,
                .stepId = step.id,
                .tool = step.tool,
                .dependsOn = step.dependsOn,
                .startedAtMs = started,
                .finishedAtMs = finished,
                .ok = true,
                .output = output,
            };
            try writeJsonFile(step_file, artifact);

            try done.put(step.id, true);
            _ = remaining.remove(step.id);
        }

        const run_file = try std.fs.path.join(self.allocator, &.{ run_path, "run.json" });
        const run_artifact = .{
            .schema = "pi.run.v1",
            .runId = run_id,
            .workflow = plan.workflow,
            .createdAtMs = nowMs(),
        };
        try writeJsonFile(run_file, run_artifact);

        return run_id;
    }
};
