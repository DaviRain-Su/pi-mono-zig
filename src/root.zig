const std = @import("std");

fn compatIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn compatCwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

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

var runBaseInstant: ?std.time.Instant = null;

fn nowMsNow() !i64 {
    const now = try std.time.Instant.now();
    const base = if (runBaseInstant) |b| b else blk: {
        runBaseInstant = now;
        break :blk now;
    };
    const ms = now.since(base) / std.time.ns_per_ms;
    return @as(i64, @intCast(ms));
}

pub const Runner = struct {
    allocator: std.mem.Allocator,
    out_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, out_dir: []const u8) Runner {
        return .{ .allocator = allocator, .out_dir = out_dir };
    }

    fn nowMs() !i64 {
        return try nowMsNow();
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
        const io = compatIo();
        const cwd = compatCwd();
        var out = try std.Io.Writer.Allocating.initCapacity(std.heap.page_allocator, 0);
        defer out.deinit();
        try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
        try out.writer.writeByte('\n');

        var f = try cwd.createFile(io, path, .{ .truncate = true });
        defer f.close(io);
        const out_slice = out.writer.buffer[0..out.writer.end];
        try f.writePositionalAll(io, out_slice, 0);
    }

    fn ensureDir(path: []const u8) !void {
        const io = compatIo();
        const cwd = compatCwd();
        cwd.createDirPath(io, path) catch |e| switch (e) {
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
        try std.Io.sleep(compatIo(), std.Io.Duration.fromMilliseconds(ms_i), .awake);
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
        const run_id = try std.fmt.allocPrint(self.allocator, "run_{d}_{s}", .{ try nowMsNow(), plan.workflow });

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

            const started = try nowMsNow();
            const output = self.runTool(step) catch |e| {
                const sid = try safeId(self.allocator, step.id);
                const step_file = try std.fs.path.join(self.allocator, &.{ steps_path, try std.fmt.allocPrint(self.allocator, "{s}.json", .{sid}) });
                const finished = try nowMsNow();
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
            const finished = try nowMsNow();

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
            .createdAtMs = try nowMsNow(),
        };
        try writeJsonFile(run_file, run_artifact);

        return run_id;
    }
};
