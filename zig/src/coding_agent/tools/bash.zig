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

pub const BashUpdateCallback = *const fn (
    context: ?*anyopaque,
    result: BashExecutionResult,
) anyerror!void;

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
        return self.executeWithUpdates(allocator, args, signal, null, null);
    }

    pub fn executeWithUpdates(
        self: BashTool,
        allocator: std.mem.Allocator,
        args: BashArgs,
        signal: ?*const std.atomic.Value(bool),
        on_update_context: ?*anyopaque,
        on_update: ?BashUpdateCallback,
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

        var wait_state = WaitState{
            .child = &child,
            .io = self.io,
        };
        const wait_thread = try std.Thread.spawn(.{}, waitChildThread, .{&wait_state});

        var reader_state = OutputReaderState.init(allocator, stdout_file, self.io);
        const reader_thread = std.Thread.spawn(.{}, readOutputThread, .{&reader_state}) catch |err| {
            child.kill(self.io);
            wait_thread.join();
            return err;
        };

        // Both threads spawned successfully; now install the defer that joins and cleans up
        var threads_joined = false;
        defer {
            if (!threads_joined) {
                wait_thread.join();
                reader_thread.join();
            }
            reader_state.deinit();
        }

        const started_at = std.Io.Clock.now(.awake, self.io).nanoseconds;
        var timed_out = false;
        var aborted = false;
        var last_reported_generation: u64 = 0;
        var last_progress_report_ns = started_at;

        while (!wait_state.done.load(.seq_cst)) {
            if (on_update != null) {
                const now_ns = std.Io.Clock.now(.awake, self.io).nanoseconds;
                const generation = reader_state.generation.load(.seq_cst);
                const should_emit = generation != last_reported_generation or
                    now_ns - last_progress_report_ns >= 200 * std.time.ns_per_ms;
                if (should_emit) {
                    const snapshot = try reader_state.snapshot(allocator);
                    defer allocator.free(snapshot);
                    try emitStreamingUpdate(
                        allocator,
                        snapshot,
                        now_ns - started_at,
                        on_update_context,
                        on_update,
                    );
                    last_reported_generation = generation;
                    last_progress_report_ns = now_ns;
                }
            }

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
        threads_joined = true;

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
            details.full_output_path = captureOutputInSecureTempFile(allocator, self.io, output) catch null;

            const start_line = if (details.truncation.?.output_lines > details.truncation.?.total_lines)
                @as(usize, 1)
            else
                details.truncation.?.total_lines - details.truncation.?.output_lines + 1;
            const end_line = details.truncation.?.total_lines;
            const full_output_note = if (details.full_output_path) |path|
                try std.fmt.allocPrint(allocator, "Full output: {s}", .{path})
            else
                try allocator.dupe(u8, "Full output was not retained");
            defer allocator.free(full_output_note);
            const note = if (details.truncation.?.last_line_partial)
                try std.fmt.allocPrint(
                    allocator,
                    "\n\n[Showing last 50KB of line {d}. {s}]",
                    .{
                        end_line,
                        full_output_note,
                    },
                )
            else if (details.truncation.?.truncated_by.? == .lines)
                try std.fmt.allocPrint(
                    allocator,
                    "\n\n[Showing lines {d}-{d} of {d}. {s}]",
                    .{
                        start_line,
                        end_line,
                        details.truncation.?.total_lines,
                        full_output_note,
                    },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "\n\n[Showing lines {d}-{d} of {d} (50KB limit). {s}]",
                    .{
                        start_line,
                        end_line,
                        details.truncation.?.total_lines,
                        full_output_note,
                    },
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

pub fn parseArguments(args: std.json.Value) !BashArgs {
    if (args != .object) return error.InvalidToolArguments;

    const command = try parseRequiredString(args.object, "command");
    const timeout_seconds = try getOptionalPositiveInt(args.object, "timeout_seconds");

    return .{
        .command = command,
        .timeout_seconds = timeout_seconds,
    };
}

const OutputReaderState = struct {
    allocator: std.mem.Allocator,
    file: std.Io.File,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    output: std.ArrayList(u8),
    err: ?anyerror = null,
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

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

    fn append(self: *OutputReaderState, bytes: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.output.appendSlice(self.allocator, bytes);
        _ = self.generation.fetchAdd(1, .seq_cst);
    }

    fn snapshot(self: *OutputReaderState, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return allocator.dupe(u8, self.output.items);
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
        state.append(buffer[0..bytes_read]) catch |err| {
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

fn emitStreamingUpdate(
    allocator: std.mem.Allocator,
    output: []const u8,
    elapsed_ns: i128,
    on_update_context: ?*anyopaque,
    on_update: ?BashUpdateCallback,
) !void {
    const callback = on_update orelse return;
    const preview_text = try buildStreamingPreview(allocator, output, elapsed_ns);
    defer allocator.free(preview_text);

    var preview = BashExecutionResult{
        .content = try common.makeTextContent(allocator, preview_text),
        .details = null,
        .is_error = false,
    };
    defer preview.deinit(allocator);

    try callback(on_update_context, preview);
}

fn buildStreamingPreview(
    allocator: std.mem.Allocator,
    output: []const u8,
    elapsed_ns: i128,
) ![]u8 {
    var truncation_result = try truncate.truncateTail(allocator, output, .{});
    errdefer truncation_result.deinit(allocator);

    var preview = if (truncation_result.content.len == 0)
        try allocator.dupe(u8, "Running...")
    else
        try allocator.dupe(u8, truncation_result.content);

    if (truncation_result.truncated) {
        const note = if (truncation_result.truncated_by.? == .lines)
            try std.fmt.allocPrint(
                allocator,
                "\n\n[Streaming last {d} of {d} lines while command runs]",
                .{ truncation_result.output_lines, truncation_result.total_lines },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "\n\n[Streaming last {d} lines ({d} byte window) while command runs]",
                .{ truncation_result.output_lines, truncate.DEFAULT_MAX_BYTES },
            );
        defer allocator.free(note);

        const with_note = try std.mem.concat(allocator, u8, &[_][]const u8{ preview, note });
        defer allocator.free(with_note);
        allocator.free(preview);
        preview = try allocator.dupe(u8, with_note);
    }

    const elapsed_ms: u64 = @intCast(@divTrunc(@max(elapsed_ns, 0), std.time.ns_per_ms));
    const elapsed_note = try std.fmt.allocPrint(
        allocator,
        "\n\n[Running... {d}.{d:0>1}s elapsed]",
        .{ elapsed_ms / std.time.ms_per_s, (elapsed_ms % std.time.ms_per_s) / 100 },
    );
    defer allocator.free(elapsed_note);

    const rendered = try std.mem.concat(allocator, u8, &[_][]const u8{ preview, elapsed_note });
    allocator.free(preview);

    if (!truncation_result.truncated) {
        truncation_result.deinit(allocator);
    }
    return rendered;
}

const SecureTempFile = struct {
    file: ?std.Io.File,
    path: ?[]u8,

    fn create(allocator: std.mem.Allocator, io: std.Io) !SecureTempFile {
        var attempts: usize = 0;
        while (attempts < 16) : (attempts += 1) {
            var random_bytes: [16]u8 = undefined;
            io.random(&random_bytes);
            const encoded = std.fmt.bytesToHex(random_bytes, .lower);
            const path = try std.fmt.allocPrint(allocator, "/tmp/pi-bash-{s}.log", .{encoded[0..]});
            errdefer allocator.free(path);

            var file = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    allocator.free(path);
                    continue;
                },
                else => return err,
            };
            errdefer file.close(io);

            return .{
                .file = file,
                .path = path,
            };
        }

        return error.TemporaryFilePathCollision;
    }

    fn releasePath(self: *SecureTempFile) []u8 {
        const path = self.path.?;
        self.path = null;
        return path;
    }

    fn deinit(self: *SecureTempFile, allocator: std.mem.Allocator, io: std.Io) void {
        if (self.file) |file| file.close(io);
        if (self.path) |path| allocator.free(path);
        self.* = undefined;
    }
};

fn captureOutputInSecureTempFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    output: []const u8,
) ![]u8 {
    var temp_file = SecureTempFile.create(allocator, io) catch |err| return err;
    errdefer temp_file.deinit(allocator, io);
    try temp_file.file.?.writeStreamingAll(io, output);
    temp_file.file.?.close(io);
    temp_file.file = null;
    return temp_file.releasePath();
}

fn parseRequiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return (try parseOptionalString(object, key)) orelse error.InvalidToolArguments;
}

fn parseOptionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return error.InvalidToolArguments;
    return value.string;
}

fn getOptionalPositiveInt(object: std.json.ObjectMap, key: []const u8) !?u64 {
    const value = object.get(key) orelse return null;
    if (value != .integer) return error.InvalidToolArguments;
    if (value.integer <= 0) return error.InvalidToolArguments;
    return @intCast(value.integer);
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

fn jsonObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &.{}, &.{});
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

const StreamingUpdateCollector = struct {
    allocator: std.mem.Allocator,
    updates: std.ArrayList([]u8) = .empty,

    fn deinit(self: *StreamingUpdateCollector) void {
        for (self.updates.items) |update| self.allocator.free(update);
        self.updates.deinit(self.allocator);
    }
};

fn collectStreamingUpdate(context: ?*anyopaque, result: BashExecutionResult) !void {
    const collector: *StreamingUpdateCollector = @ptrCast(@alignCast(context.?));
    const text = switch (result.content[0]) {
        .text => |content| content.text,
        else => return error.UnexpectedContentBlock,
    };
    try collector.updates.append(collector.allocator, try collector.allocator.dupe(u8, text));
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

test "bash tool streams partial output updates for long-running commands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const joined_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(joined_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, joined_path);
    defer std.testing.allocator.free(absolute_path);

    var collector = StreamingUpdateCollector{ .allocator = std.testing.allocator };
    defer collector.deinit();

    var result = try BashTool.init(absolute_path, std.testing.io).executeWithUpdates(
        std.testing.allocator,
        .{
            .command = "printf 'first\\n'; sleep 0.2; printf 'second\\n'; sleep 0.2; printf 'third\\n'",
        },
        null,
        &collector,
        collectStreamingUpdate,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(collector.updates.items.len >= 2);

    var saw_first_only = false;
    var saw_running_note = false;
    for (collector.updates.items) |update| {
        if (std.mem.indexOf(u8, update, "Running...") != null) saw_running_note = true;
        if (std.mem.indexOf(u8, update, "first") != null and std.mem.indexOf(u8, update, "third") == null) {
            saw_first_only = true;
        }
    }

    try std.testing.expect(saw_first_only);
    try std.testing.expect(saw_running_note);
    try std.testing.expect(std.mem.indexOf(u8, result.content[0].text.text, "third") != null);
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

test "bash tool truncates large output and exposes the temp path" {
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
    const full_output_path = result.details.?.full_output_path.?;
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, full_output_path) catch {};

    const full_output = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, full_output_path, std.testing.allocator, .limited(32 * 1024));
    defer std.testing.allocator.free(full_output);

    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "3000"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "1\n2\n3"));
    try std.testing.expect(std.mem.startsWith(u8, full_output_path, "/tmp/pi-bash-"));
    try std.testing.expect(std.mem.containsAtLeast(u8, full_output, 1, "1\n2\n3"));
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        result.content[0].text.text,
        1,
        full_output_path,
    ));
}

test "bash tool validates required arguments" {
    const object = try jsonObject(std.testing.allocator);
    defer {
        const value = std.json.Value{ .object = object };
        common.deinitJsonValue(std.testing.allocator, value);
    }

    try std.testing.expectError(error.InvalidToolArguments, parseArguments(.{ .object = object }));
}

test "bash tool validates positive timeout_seconds" {
    var object = try jsonObject(std.testing.allocator);
    defer {
        const value = std.json.Value{ .object = object };
        common.deinitJsonValue(std.testing.allocator, value);
    }

    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "command"), .{
        .string = try std.testing.allocator.dupe(u8, "echo hello"),
    });
    try object.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "timeout_seconds"), .{ .integer = 0 });

    try std.testing.expectError(error.InvalidToolArguments, parseArguments(.{ .object = object }));
}

test "secure temp file remains available after creation" {
    var first = try SecureTempFile.create(std.testing.allocator, std.testing.io);
    defer {
        if (first.path) |path| std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};
        first.deinit(std.testing.allocator, std.testing.io);
    }

    var second = try SecureTempFile.create(std.testing.allocator, std.testing.io);
    defer {
        if (second.path) |path| std.Io.Dir.deleteFileAbsolute(std.testing.io, path) catch {};
        second.deinit(std.testing.allocator, std.testing.io);
    }

    try std.testing.expect(std.mem.startsWith(u8, first.path.?, "/tmp/pi-bash-"));
    try std.testing.expect(!std.mem.eql(u8, first.path.?, second.path.?));

    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, first.path.?, .{});
    file.close(std.testing.io);
}
