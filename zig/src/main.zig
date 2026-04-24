const std = @import("std");
const ai = @import("ai");
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

    var options = cli.parseArgs(init.gpa, argv.items) catch |err| {
        stderr.print("Error: {s}\n\n", .{parseErrorMessage(err)}) catch {};
        printUsage(init.gpa, stdout) catch {};
        flushWriters(stdout, stderr) catch {};
        std.process.exit(1);
    };
    defer options.deinit(init.gpa);

    if (options.help) {
        try printUsage(init.gpa, stdout);
        try flushWriters(stdout, stderr);
        return;
    }

    if (options.version) {
        try printVersion(init.gpa, stdout);
        try flushWriters(stdout, stderr);
        return;
    }

    if (options.print and options.prompt == null) {
        try stderr.writeAll("Error: No prompt provided\n\n");
        printUsage(init.gpa, stdout) catch {};
        try flushWriters(stdout, stderr);
        std.process.exit(1);
    }

    if (options.mode == .rpc) {
        try stderr.writeAll("Error: RPC mode is not implemented in the Zig CLI\n");
        try flushWriters(stdout, stderr);
        std.process.exit(1);
    }

    const provider_name = options.provider orelse "openai";
    const selected_tools = effectiveToolSelection(&options);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", init.gpa);
    defer init.gpa.free(cwd);
    const current_date = try currentDateString(init.gpa, init.io);
    defer init.gpa.free(current_date);
    const system_prompt = try coding_agent.buildSystemPrompt(init.gpa, .{
        .cwd = cwd,
        .current_date = current_date,
        .custom_prompt = options.system_prompt,
        .append_prompt = options.append_system_prompt,
        .selected_tools = selected_tools,
    });
    defer init.gpa.free(system_prompt);

    var provider_runtime = coding_agent.resolveProviderConfig(
        init.gpa,
        init.environ_map,
        provider_name,
        options.model,
        options.api_key,
    ) catch |err| {
        try stderr.print("Error: {s}\n", .{coding_agent.resolveProviderErrorMessage(err, provider_name)});
        try flushWriters(stdout, stderr);
        std.process.exit(1);
    };
    defer provider_runtime.deinit(init.gpa);

    if (options.print) {
        const content_block = ai.ContentBlock{ .text = .{ .text = options.prompt.? } };
        const now: i64 = @intCast(@divFloor(std.Io.Clock.now(.real, init.io).nanoseconds, std.time.ns_per_s));
        const user_msg = ai.Message{ .user = .{
            .content = &[_]ai.ContentBlock{content_block},
            .timestamp = now,
        } };
        const context = ai.Context{
            .system_prompt = system_prompt,
            .messages = &[_]ai.Message{user_msg},
        };

        const exit_code = try coding_agent.runPrintMode(
            init.gpa,
            init.io,
            provider_runtime.model,
            context,
            .{
                .api_key = provider_runtime.api_key,
            },
            .{
                .mode = switch (options.mode) {
                    .json => .json,
                    else => .text,
                },
            },
            stdout,
            stderr,
        );
        try flushWriters(stdout, stderr);
        if (exit_code != 0) std.process.exit(exit_code);
        return;
    }

    const exit_code = try coding_agent.runInteractiveMode(
        init.gpa,
        init.io,
        init.environ_map,
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
    try flushWriters(stdout, stderr);
    if (exit_code != 0) std.process.exit(exit_code);
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
