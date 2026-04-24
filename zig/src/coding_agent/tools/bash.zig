const std = @import("std");
const ai = @import("ai");
const common = @import("common.zig");
const truncate = @import("truncate.zig");

pub const BashArgs = struct {
    command: []const u8,
    timeout_seconds: ?u64 = null,
};

pub const BashDetails = struct {
    exit_code: ?u8 = null,
    timed_out: bool = false,
    full_output_path: ?[]const u8 = null,
    truncation: ?truncate.TruncationResult = null,

    pub fn deinit(self: *BashDetails, allocator: std.mem.Allocator) void {
        if (self.full_output_path) |path| allocator.free(path);
        if (self.truncation) |*truncation_result| truncation_result.deinit(allocator);
        self.* = undefined;
    }
};

pub const BashExecutionResult = struct {
    content: []const ai.ContentBlock,
    details: ?BashDetails = null,
    is_error: bool = false,

    pub fn deinit(self: *BashExecutionResult, allocator: std.mem.Allocator) void {
        common.deinitContentBlocks(allocator, self.content);
        if (self.details) |*details| details.deinit(allocator);
        self.* = undefined;
    }
};

pub const BashTool = struct {
    cwd: []const u8,
    io: std.Io,

    pub const name = "bash";
    pub const description =
        "Execute a shell command in the configured working directory. " ++
        "Combined stdout/stderr output is truncated to the last 2000 lines or 50KB, supports timeouts, and kills the entire process group on timeout.";

    pub fn init(cwd: []const u8, io: std.Io) BashTool {
        return .{
            .cwd = cwd,
            .io = io,
        };
    }

    pub fn schema(allocator: std.mem.Allocator) !std.json.Value {
        var properties = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer {
            const value = std.json.Value{ .object = properties };
            common.deinitJsonValue(allocator, value);
        }

        try properties.put(allocator, try allocator.dupe(u8, "command"), try schemaProperty(
            allocator,
            "string",
            "Shell command to execute",
        ));
        try properties.put(allocator, try allocator.dupe(u8, "timeout_seconds"), try schemaProperty(
            allocator,
            "integer",
            "Timeout in seconds before the process group is terminated",
        ));

        var required = std.json.Array.init(allocator);
        try required.append(.{ .string = try allocator.dupe(u8, "command") });

        var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try root.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });
        try root.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = properties });
        try root.put(allocator, try allocator.dupe(u8, "required"), .{ .array = required });
        return .{ .object = root };
    }

    pub fn execute(
        self: BashTool,
        allocator: std.mem.Allocator,
        args: BashArgs,
        signal: ?*const std.atomic.Value(bool),
    ) !BashExecutionResult {
        var cwd_dir = std.Io.Dir.openDirAbsolute(self.io, self.cwd, .{}) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "Working directory does not exist: {s} ({s})", .{ self.cwd, @errorName(err) });
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        };
        defer cwd_dir.close(self.io);

        const wrapped_command = try std.fmt.allocPrint(allocator, "exec 2>&1\n{s}", .{args.command});
        defer allocator.free(wrapped_command);

        const argv = [_][]const u8{ "/bin/sh", "-c", wrapped_command };
        var child = try std.process.spawn(self.io, .{
            .argv = argv[0..],
            .cwd = .{ .path = self.cwd },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = 0,
        });
        defer {
            if (child.id != null) child.kill(self.io);
        }

        const pid = child.id.?;
        const stdout_file = child.stdout.?;
        child.stdout = null;

        var reader_state = OutputReaderState.init(allocator, stdout_file, self.io);
        defer reader_state.deinit();
        const reader_thread = try std.Thread.spawn(.{}, readOutputThread, .{&reader_state});

        var wait_state = WaitState{
            .child = &child,
            .io = self.io,
        };
        const wait_thread = try std.Thread.spawn(.{}, waitChildThread, .{&wait_state});

        const started_at = std.Io.Clock.now(.awake, self.io).nanoseconds;
        var timed_out = false;
        var aborted = false;

        while (!wait_state.done.load(.seq_cst)) {
            if (args.timeout_seconds) |timeout_seconds| {
                const elapsed_ns: u128 = @intCast(std.Io.Clock.now(.awake, self.io).nanoseconds - started_at);
                if (elapsed_ns >= @as(u128, timeout_seconds) * std.time.ns_per_s) {
                    timed_out = true;
                    killProcessGroup(pid);
                    break;
                }
            }

            if (signal) |abort_signal| {
                if (abort_signal.load(.seq_cst)) {
                    aborted = true;
                    killProcessGroup(pid);
                    break;
                }
            }

            std.Io.sleep(self.io, .fromMilliseconds(50), .awake) catch {};
        }

        wait_thread.join();
        reader_thread.join();

        if (reader_state.err) |err| return err;
        if (wait_state.err) |err| return err;

        const output = try reader_state.output.toOwnedSlice(allocator);
        defer allocator.free(output);

        var truncation_result = try truncate.truncateTail(allocator, output, .{});
        errdefer truncation_result.deinit(allocator);

        var details = BashDetails{
            .timed_out = timed_out,
            .exit_code = exitCodeFromTerm(wait_state.term.?),
        };
        var base_output = if (truncation_result.content.len == 0)
            try allocator.dupe(u8, "(no output)")
        else
            try allocator.dupe(u8, truncation_result.content);

        if (truncation_result.truncated) {
            details.truncation = truncation_result;
            const full_output_path = try makeTempOutputPath(allocator, pid);
            errdefer allocator.free(full_output_path);
            try std.Io.Dir.writeFile(.cwd(), self.io, .{
                .sub_path = full_output_path,
                .data = output,
            });
            details.full_output_path = full_output_path;

            const start_line = if (details.truncation.?.output_lines > details.truncation.?.total_lines)
                @as(usize, 1)
            else
                details.truncation.?.total_lines - details.truncation.?.output_lines + 1;
            const end_line = details.truncation.?.total_lines;
            const note = if (details.truncation.?.truncated_by.? == .lines)
                try std.fmt.allocPrint(
                    allocator,
                    "\n\n[Showing lines {d}-{d} of {d}. Full output: {s}]",
                    .{ start_line, end_line, details.truncation.?.total_lines, full_output_path },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "\n\n[Showing lines {d}-{d} of {d} (50KB limit). Full output: {s}]",
                    .{ start_line, end_line, details.truncation.?.total_lines, full_output_path },
                );
            defer allocator.free(note);

            const with_note = try std.mem.concat(allocator, u8, &[_][]const u8{ base_output, note });
            defer allocator.free(with_note);
            allocator.free(base_output);
            base_output = try allocator.dupe(u8, with_note);
        } else {
            truncation_result.deinit(allocator);
        }

        if (timed_out) {
            const note = try std.fmt.allocPrint(allocator, "\n\nCommand timed out after {d} seconds", .{args.timeout_seconds.?});
            defer allocator.free(note);
            const with_note = try std.mem.concat(allocator, u8, &[_][]const u8{ base_output, note });
            defer allocator.free(with_note);
            allocator.free(base_output);
            base_output = try allocator.dupe(u8, with_note);
        } else if (aborted) {
            const with_note = try std.mem.concat(allocator, u8, &[_][]const u8{ base_output, "\n\nCommand aborted" });
            defer allocator.free(with_note);
            allocator.free(base_output);
            base_output = try allocator.dupe(u8, with_note);
        } else if (details.exit_code != null and details.exit_code.? != 0) {
            const note = try std.fmt.allocPrint(allocator, "\n\nCommand exited with code {d}", .{details.exit_code.?});
            defer allocator.free(note);
            const with_note = try std.mem.concat(allocator, u8, &[_][]const u8{ base_output, note });
            defer allocator.free(with_note);
            allocator.free(base_output);
            base_output = try allocator.dupe(u8, with_note);
        }

        defer allocator.free(base_output);
        return .{
            .content = try common.makeTextContent(allocator, base_output),
            .details = details,
            .is_error = timed_out or aborted or (details.exit_code != null and details.exit_code.? != 0),
        };
    }
};

const OutputReaderState = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    output: std.ArrayList(u8),
    err: ?anyerror = null,

    fn init(allocator: std.mem.Allocator, file: std.Io.File, io: std.Io) OutputReaderState {
        return .{
            .allocator = allocator,
            .file = file,
            .io = io,
            .output = .empty,
        };
    }

    fn deinit(self: *OutputReaderState) void {
        self.output.deinit(self.allocator);
        self.file.close(self.io);
    }
};

const WaitState = struct {
    child: *std.process.Child,
    io: std.Io,
    term: ?std.process.Child.Term = null,
    err: ?anyerror = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn readOutputThread(state: *OutputReaderState) void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = std.posix.read(state.file.handle, &buffer) catch |err| {
            state.err = err;
            return;
        };
        if (bytes_read == 0) return;
        state.output.appendSlice(state.allocator, buffer[0..bytes_read]) catch |err| {
            state.err = err;
            return;
        };
    }
}

fn waitChildThread(state: *WaitState) void {
    state.term = state.child.wait(state.io) catch |err| {
        state.err = err;
        state.done.store(true, .seq_cst);
        return;
    };
    state.done.store(true, .seq_cst);
}

fn killProcessGroup(pid: std.posix.pid_t) void {
    std.posix.kill(-pid, .TERM) catch {};
    std.posix.kill(-pid, .KILL) catch {};
}

fn exitCodeFromTerm(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

fn makeTempOutputPath(allocator: std.mem.Allocator, pid: std.posix.pid_t) ![]u8 {
    return std.fmt.allocPrint(allocator, "/tmp/pi-bash-{d}.log", .{pid});
}

fn schemaProperty(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    description: []const u8,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, type_name) });
    try object.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, description) });
    return .{ .object = object };
}

fn makeAbsoluteTestPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

fn processExists(allocator: std.mem.Allocator, pid: std.posix.pid_t) !bool {
    const pid_text = try std.fmt.allocPrint(allocator, "{d}", .{pid});
    defer allocator.free(pid_text);

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &[_][]const u8{ "ps", "-p", pid_text },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "bash tool executes a command and returns stdout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const joined_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(joined_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, joined_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try BashTool.init(absolute_path, std.testing.io).execute(std.testing.allocator, .{
        .command = "echo hello",
    }, null);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("hello\n", result.content[0].text.text);
    try std.testing.expect(result.details.?.exit_code.? == 0);
}

test "bash tool captures stderr and exit code on failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const joined_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(joined_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, joined_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try BashTool.init(absolute_path, std.testing.io).execute(std.testing.allocator, .{
        .command = "echo failure >&2; exit 7",
    }, null);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expectEqual(@as(u8, 7), result.details.?.exit_code.?);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "failure"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "Command exited with code 7"));
}

test "bash tool times out and kills the whole process group" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const pid_file_relative = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, "child.pid" });
    defer std.testing.allocator.free(pid_file_relative);
    const pid_file = try makeAbsoluteTestPath(std.testing.allocator, pid_file_relative);
    defer std.testing.allocator.free(pid_file);

    const joined_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(joined_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, joined_path);
    defer std.testing.allocator.free(absolute_path);

    const command = try std.fmt.allocPrint(
        std.testing.allocator,
        "sleep 30 & echo $! > \"{s}\"; wait",
        .{pid_file},
    );
    defer std.testing.allocator.free(command);

    var result = try BashTool.init(absolute_path, std.testing.io).execute(std.testing.allocator, .{
        .command = command,
        .timeout_seconds = 1,
    }, null);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(result.details.?.timed_out);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "Command timed out after 1 seconds"));

    const pid_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, pid_file, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(pid_bytes);
    const child_pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_bytes, &std.ascii.whitespace), 10);

    std.Io.sleep(std.testing.io, .fromMilliseconds(200), .awake) catch {};
    try std.testing.expect(!(try processExists(std.testing.allocator, child_pid)));
}

test "bash tool truncates large output and persists the full log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const joined_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(joined_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, joined_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try BashTool.init(absolute_path, std.testing.io).execute(std.testing.allocator, .{
        .command = "seq 3000",
    }, null);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(result.details.?.truncation != null);
    try std.testing.expect(result.details.?.truncation.?.truncated);
    try std.testing.expectEqual(truncate.TruncatedBy.lines, result.details.?.truncation.?.truncated_by.?);
    try std.testing.expect(result.details.?.full_output_path != null);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "3000"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "1\n2\n3"));

    const full_output = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, result.details.?.full_output_path.?, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(full_output);
    try std.testing.expect(std.mem.containsAtLeast(u8, full_output, 1, "1\n2\n3"));
    try std.testing.expect(std.mem.containsAtLeast(u8, full_output, 1, "2998\n2999\n3000"));
}
