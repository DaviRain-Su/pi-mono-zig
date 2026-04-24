const std = @import("std");
const agent = @import("agent");
const cli = @import("cli/args.zig");
const coding_agent = @import("coding_agent/root.zig");

const VERSION = "0.1.0";

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(init.gpa);
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |arg| {
        try argv.append(init.gpa, arg);
    }

    const exit_code = try runCli(init.gpa, init.io, init.environ_map, argv.items, null, stdout, stderr);
    try flushWriters(stdout, stderr);
    if (exit_code != 0) std.process.exit(exit_code);
}

pub fn runCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argv: []const []const u8,
    cwd_override: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var options = cli.parseArgs(allocator, argv) catch |err| {
        try stderr.print("Error: {s}\n\n", .{parseErrorMessage(err)});
        try printUsage(allocator, stdout);
        return 1;
    };
    defer options.deinit(allocator);

    if (options.help) {
        try printUsage(allocator, stdout);
        return 0;
    }

    if (options.version) {
        try printVersion(allocator, stdout);
        return 0;
    }

    if (options.mode == .rpc and options.prompt != null) {
        try stderr.writeAll("Error: Prompt arguments are not supported in RPC mode\n");
        return 1;
    }

    if (options.print and options.prompt == null) {
        try stderr.writeAll("Error: No prompt provided\n\n");
        try printUsage(allocator, stdout);
        return 1;
    }

    const provider_name = options.provider orelse "openai";
    const selected_tools = effectiveToolSelection(&options);
    const cwd = if (cwd_override) |override| blk: {
        break :blk try allocator.dupe(u8, override);
    } else blk: {
        const real_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        defer allocator.free(real_cwd);
        break :blk try allocator.dupe(u8, real_cwd);
    };
    defer allocator.free(cwd);

    const current_date = try currentDateString(allocator, io);
    defer allocator.free(current_date);
    const system_prompt = try coding_agent.buildSystemPrompt(allocator, .{
        .cwd = cwd,
        .current_date = current_date,
        .custom_prompt = options.system_prompt,
        .append_prompt = options.append_system_prompt,
        .selected_tools = selected_tools,
    });
    defer allocator.free(system_prompt);

    var provider_runtime = coding_agent.resolveProviderConfig(
        allocator,
        env_map,
        provider_name,
        options.model,
        options.api_key,
    ) catch |err| {
        try stderr.print("Error: {s}\n", .{coding_agent.resolveProviderErrorMessage(err, provider_name)});
        return 1;
    };
    defer provider_runtime.deinit(allocator);

    if (options.print or options.mode == .rpc) {
        coding_agent.interactive_mode.setToolRuntime(.{
            .cwd = cwd,
            .io = io,
        });
        defer coding_agent.interactive_mode.clearToolRuntime();

        var built_tools = try coding_agent.interactive_mode.buildAgentTools(allocator, selected_tools);
        defer built_tools.deinit();

        const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
        defer allocator.free(session_dir);

        var session = try coding_agent.interactive_mode.openInitialSession(
            allocator,
            io,
            session_dir,
            .{
                .cwd = cwd,
                .system_prompt = system_prompt,
                .provider = provider_name,
                .model = options.model,
                .api_key = options.api_key,
                .thinking = mapThinkingLevel(options.thinking),
                .session = options.session,
                .@"continue" = options.@"continue",
                .selected_tools = selected_tools,
                .initial_prompt = null,
            },
            provider_runtime.model,
            provider_runtime.api_key,
            built_tools.items,
        );
        defer session.deinit();

        if (options.mode == .rpc) {
            return try coding_agent.runRpcMode(
                allocator,
                io,
                &session,
                .{},
                stdout,
                stderr,
            );
        }

        return try coding_agent.runPrintMode(
            allocator,
            io,
            &session,
            options.prompt.?,
            .{
                .mode = switch (options.mode) {
                    .json => .json,
                    else => .text,
                },
            },
            stdout,
            stderr,
        );
    }

    return try coding_agent.runInteractiveMode(
        allocator,
        io,
        env_map,
        .{
            .cwd = cwd,
            .system_prompt = system_prompt,
            .provider = provider_name,
            .model = options.model,
            .api_key = options.api_key,
            .thinking = mapThinkingLevel(options.thinking),
            .session = options.session,
            .@"continue" = options.@"continue",
            .selected_tools = selected_tools,
            .initial_prompt = options.prompt,
        },
        stderr,
    );
}

fn parseErrorMessage(err: cli.ParseArgsError) []const u8 {
    return switch (err) {
        error.MissingOptionValue => "Missing value for option",
        error.InvalidMode => "Invalid mode. Expected one of: text, json, rpc",
        error.InvalidThinkingLevel => "Invalid thinking level. Expected one of: off, minimal, low, medium, high, xhigh",
        error.UnknownOption => "Unknown option",
        error.OutOfMemory => "Out of memory while parsing CLI arguments",
    };
}

fn effectiveToolSelection(options: *const cli.Args) ?[]const []const u8 {
    if (options.no_tools) {
        return options.tools orelse &[_][]const u8{};
    }
    return options.tools;
}

fn printUsage(allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    const text = try cli.helpText(allocator, VERSION);
    defer allocator.free(text);
    try stdout.writeAll(text);
}

fn printVersion(allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    const text = try cli.versionText(allocator, VERSION);
    defer allocator.free(text);
    try stdout.writeAll(text);
}

fn currentDateString(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const now_seconds: u64 = @intCast(@divFloor(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = now_seconds };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}",
        .{ year_day.year, @intFromEnum(month_day.month), month_day.day_index + 1 },
    );
}

fn flushWriters(stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    try stdout.flush();
    try stderr.flush();
}

fn mapThinkingLevel(level: ?cli.ThinkingLevel) agent.ThinkingLevel {
    return switch (level orelse .off) {
        .off => .off,
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
}

fn makeAbsoluteTestPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

fn makeTmpPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const relative_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        name,
    });
    defer allocator.free(relative_dir);
    return try makeAbsoluteTestPath(allocator, relative_dir);
}

test "main help text includes expected CLI options" {
    const allocator = std.testing.allocator;
    const help = try cli.helpText(allocator, VERSION);
    defer allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "--model <model>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--provider <provider>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--api-key <key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--thinking <level>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--continue, -c") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--session <id|path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--print, -p") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--mode <text|json|rpc>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--tools <names>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-tools") != null);
}

test "runCli prints faux response end to end" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "hello from cli");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "hello" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("hello from cli\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "runCli persists and continues sessions across runs" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeTmpPath(allocator, tmp, "cli-session");
    defer allocator.free(cwd);

    var first_env = std.process.Environ.Map.init(allocator);
    defer first_env.deinit();
    try first_env.put("PI_FAUX_RESPONSE", "first reply");

    var first_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer first_stdout.deinit();
    var first_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer first_stderr.deinit();

    const first_exit = try runCli(
        allocator,
        std.testing.io,
        &first_env,
        &.{ "--provider", "faux", "--print", "first prompt" },
        cwd,
        &first_stdout.writer,
        &first_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), first_exit);

    var second_env = std.process.Environ.Map.init(allocator);
    defer second_env.deinit();
    try second_env.put("PI_FAUX_RESPONSE", "second reply");

    var second_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer second_stdout.deinit();
    var second_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer second_stderr.deinit();

    const second_exit = try runCli(
        allocator,
        std.testing.io,
        &second_env,
        &.{ "--provider", "faux", "--print", "--continue", "second prompt" },
        cwd,
        &second_stdout.writer,
        &second_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), second_exit);

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();

    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), context.messages.len);
    try std.testing.expectEqualStrings("first prompt", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("first reply", context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("second prompt", context.messages[2].user.content[0].text.text);
    try std.testing.expectEqualStrings("second reply", context.messages[3].assistant.content[0].text.text);
}
