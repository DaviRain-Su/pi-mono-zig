const std = @import("std");
const ai = @import("ai/root.zig");
const cli = @import("cli/args.zig");
const coding_agent = @import("coding_agent/root.zig");
const openai = @import("ai/providers/openai.zig");
const http_client = @import("ai/http_client.zig");

const VERSION = "0.1.0";

pub fn main(init: std.process.Init) !void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(init.gpa);
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |arg| {
        try argv.append(init.gpa, arg);
    }

    var options = cli.parseArgs(init.gpa, argv.items) catch |err| {
        std.debug.print("Error: {s}\n\n", .{parseErrorMessage(err)});
        printUsage(init.gpa) catch {};
        std.process.exit(1);
    };
    defer options.deinit(init.gpa);

    if (options.help) {
        try printUsage(init.gpa);
        return;
    }

    if (options.version) {
        try printVersion(init.gpa);
        return;
    }

    if (options.prompt == null) {
        std.debug.print("Error: No prompt provided\n\n", .{});
        printUsage(init.gpa) catch {};
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

    // Determine provider defaults and API key env var
    const is_kimi = std.mem.eql(u8, provider, "kimi");
    const default_model = if (is_kimi) "moonshot-v1-8k" else "gpt-4";
    const api_key_env = if (is_kimi) "KIMI_API_KEY" else "OPENAI_API_KEY";

    // Get API key from env var if not provided
    var api_key: ?[]const u8 = options.api_key;
    if (api_key == null) {
        api_key = init.environ_map.get(api_key_env);
    }

    if (api_key == null) {
        std.debug.print("Error: API key required. Use -k or set {s} env var.\n", .{api_key_env});
        std.process.exit(1);
    }

    // Use default model if not specified
    const model_id = options.model orelse default_model;
    const base_url = if (is_kimi) "https://api.moonshot.cn/v1" else "https://api.openai.com/v1";

    // Build model config
    const model = ai.Model{
        .id = model_id,
        .name = model_id,
        .api = if (is_kimi) "kimi-completions" else "openai-completions",
        .provider = provider,
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    // Build context
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

    // Build stream options
    const stream_options = ai.StreamOptions{
        .api_key = api_key,
    };

    std.debug.print("pi v{s}\n\n", .{VERSION});

    // Perform actual streaming request
    try streamChatCompletion(init.gpa, init.io, model, context, stream_options);
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

fn printUsage(allocator: std.mem.Allocator) !void {
    const text = try cli.helpText(allocator, VERSION);
    defer allocator.free(text);
    std.debug.print("{s}", .{text});
}

fn printVersion(allocator: std.mem.Allocator) !void {
    const text = try cli.versionText(allocator, VERSION);
    defer allocator.free(text);
    std.debug.print("{s}", .{text});
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

/// Stream chat completion and print response to stdout
fn streamChatCompletion(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai.Model,
    context: ai.Context,
    options: ai.StreamOptions,
) !void {
    // Build request payload using OpenAI provider helper
    const payload = try openai.buildRequestPayload(allocator, model, context, options);

    // Serialize payload to JSON
    var json_out: std.Io.Writer.Allocating = .init(allocator);
    const json_writer = &json_out.writer;
    defer json_out.deinit();
    try std.json.Stringify.value(payload, .{}, json_writer);

    // Build HTTP request
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();

    try headers.put("Content-Type", "application/json");
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{options.api_key orelse ""});
    defer allocator.free(auth_header);
    try headers.put("Authorization", auth_header);
    try headers.put("Accept", "text/event-stream");

    const req = http_client.HttpRequest{
        .method = .POST,
        .url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{model.base_url}),
        .headers = headers,
        .body = json_out.written(),
    };
    defer allocator.free(req.url);

    // Send request
    var client = try http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    const response = try client.request(req);
    defer response.deinit();

    if (response.status != 200) {
        std.debug.print("Error: HTTP {d}\n", .{response.status});
        std.debug.print("{s}\n", .{response.body});
        return error.HttpError;
    }

    // Parse SSE stream and print text chunks
    try parseAndPrintSseStream(allocator, response.body);
}

/// Parse SSE stream and print text content to stdout
fn parseAndPrintSseStream(allocator: std.mem.Allocator, body: []const u8) !void {
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first_chunk = true;

    while (lines.next()) |line| {
        const data = openai.parseSseLine(line) orelse continue;

        if (std.mem.eql(u8, data, "[DONE]")) {
            break;
        }

        const chunk = try openai.parseChunk(allocator, data);
        defer if (chunk) |*c| c.deinit();

        if (chunk == null) continue;

        const value = chunk.?.value;

        // Extract choices from chunk
        const choices = value.object.get("choices") orelse continue;
        if (choices != .array or choices.array.items.len == 0) continue;

        const choice = choices.array.items[0];
        if (choice != .object) continue;

        const delta = choice.object.get("delta") orelse continue;
        if (delta != .object) continue;

        // Handle text content
        if (delta.object.get("content")) |content| {
            if (content == .string and content.string.len > 0) {
                if (first_chunk) {
                    std.debug.print("\n", .{});
                    first_chunk = false;
                }
                std.debug.print("{s}", .{content.string});
            }
        }
    }

    if (!first_chunk) {
        std.debug.print("\n", .{});
    }
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
