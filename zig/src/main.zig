const std = @import("std");
const ai = @import("ai");
const cli = @import("cli/args.zig");
const coding_agent = @import("coding_agent/root.zig");
const faux = ai.providers.faux;

const VERSION = "0.1.0";

const ResolveProviderError = error{
    MissingApiKey,
    UnknownProvider,
    InvalidFauxStopReason,
    InvalidFauxTokensPerSecond,
};

const ResolvedProviderConfig = struct {
    model: ai.Model,
    api_key: ?[]const u8,
    faux_registration: ?faux.FauxProviderRegistration = null,
    faux_blocks: ?[]faux.FauxContentBlock = null,

    fn deinit(self: *ResolvedProviderConfig, allocator: std.mem.Allocator) void {
        if (self.faux_registration) |registration| registration.unregister();
        if (self.faux_blocks) |blocks| allocator.free(blocks);
        self.* = undefined;
    }
};

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

    if (options.prompt == null) {
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

    const provider = options.provider orelse "openai";
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

    var provider_config = resolveProviderConfig(
        init.gpa,
        init.environ_map,
        provider,
        options.model,
        options.api_key,
    ) catch |err| {
        try stderr.print("Error: {s}\n", .{resolveProviderErrorMessage(err, provider)});
        try flushWriters(stdout, stderr);
        std.process.exit(1);
    };
    defer provider_config.deinit(init.gpa);

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
        provider_config.model,
        context,
        .{
            .api_key = provider_config.api_key,
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

fn resolveProviderConfig(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
    model_override: ?[]const u8,
    api_key_override: ?[]const u8,
) (ResolveProviderError || std.mem.Allocator.Error || std.fmt.ParseIntError)!ResolvedProviderConfig {
    if (std.mem.eql(u8, provider, "faux")) {
        return try resolveFauxProvider(allocator, env_map, model_override);
    }

    if (std.mem.eql(u8, provider, "openai")) {
        return resolveOpenAiCompatibleProvider(
            env_map,
            "OPENAI_API_KEY",
            "gpt-4",
            "openai-completions",
            provider,
            "https://api.openai.com/v1",
            model_override,
            api_key_override,
        );
    }

    if (std.mem.eql(u8, provider, "kimi")) {
        return resolveOpenAiCompatibleProvider(
            env_map,
            "KIMI_API_KEY",
            "moonshot-v1-8k",
            "kimi-completions",
            provider,
            "https://api.moonshot.cn/v1",
            model_override,
            api_key_override,
        );
    }

    return error.UnknownProvider;
}

fn resolveOpenAiCompatibleProvider(
    env_map: *const std.process.Environ.Map,
    env_key: []const u8,
    default_model: []const u8,
    api: []const u8,
    provider: []const u8,
    base_url: []const u8,
    model_override: ?[]const u8,
    api_key_override: ?[]const u8,
) ResolveProviderError!ResolvedProviderConfig {
    const api_key = api_key_override orelse env_map.get(env_key) orelse return error.MissingApiKey;
    const model_id = model_override orelse default_model;
    return .{
        .model = .{
            .id = model_id,
            .name = model_id,
            .api = api,
            .provider = provider,
            .base_url = base_url,
            .input_types = &[_][]const u8{"text"},
            .context_window = 8192,
            .max_tokens = 4096,
        },
        .api_key = api_key,
    };
}

fn resolveFauxProvider(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    model_override: ?[]const u8,
) (ResolveProviderError || std.mem.Allocator.Error || std.fmt.ParseIntError)!ResolvedProviderConfig {
    const tokens_per_second = if (env_map.get("PI_FAUX_TOKENS_PER_SECOND")) |value|
        std.fmt.parseInt(u32, value, 10) catch return error.InvalidFauxTokensPerSecond
    else
        null;

    const registration = try faux.registerFauxProvider(allocator, .{
        .tokens_per_second = tokens_per_second,
    });
    errdefer registration.unregister();

    const response_blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    errdefer allocator.free(response_blocks);
    response_blocks[0] = faux.fauxText(env_map.get("PI_FAUX_RESPONSE") orelse "faux response");

    const stop_reason = parseFauxStopReason(env_map.get("PI_FAUX_STOP_REASON") orelse "stop") orelse
        return error.InvalidFauxStopReason;
    const error_message = env_map.get("PI_FAUX_ERROR_MESSAGE") orelse defaultFauxErrorMessage(stop_reason);

    try registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(response_blocks, .{
            .stop_reason = stop_reason,
            .error_message = error_message,
        }) },
    });

    var model = registration.getModel();
    if (model_override) |override| {
        model.id = override;
        model.name = override;
    }

    return .{
        .model = model,
        .api_key = null,
        .faux_registration = registration,
        .faux_blocks = response_blocks,
    };
}

fn parseFauxStopReason(value: []const u8) ?ai.StopReason {
    if (std.mem.eql(u8, value, "stop")) return .stop;
    if (std.mem.eql(u8, value, "length")) return .length;
    if (std.mem.eql(u8, value, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, value, "error")) return .error_reason;
    if (std.mem.eql(u8, value, "error_reason")) return .error_reason;
    if (std.mem.eql(u8, value, "aborted")) return .aborted;
    return null;
}

fn defaultFauxErrorMessage(stop_reason: ai.StopReason) ?[]const u8 {
    return switch (stop_reason) {
        .error_reason => "Faux response failed",
        .aborted => "Request was aborted",
        else => null,
    };
}

fn resolveProviderErrorMessage(err: anyerror, provider: []const u8) []const u8 {
    return switch (err) {
        error.MissingApiKey => if (std.mem.eql(u8, provider, "kimi"))
            "API key required. Use --api-key or set KIMI_API_KEY."
        else
            "API key required. Use --api-key or set OPENAI_API_KEY.",
        error.UnknownProvider => "Unsupported provider. Supported providers: openai, kimi, faux.",
        error.InvalidFauxStopReason => "Invalid PI_FAUX_STOP_REASON. Expected stop, length, tool_use, error, or aborted.",
        error.InvalidFauxTokensPerSecond => "Invalid PI_FAUX_TOKENS_PER_SECOND. Expected an integer.",
        else => @errorName(err),
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
