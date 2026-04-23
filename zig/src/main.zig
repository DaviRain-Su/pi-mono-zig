const std = @import("std");
const ai = @import("ai/root.zig");
const openai = @import("ai/providers/openai.zig");
const http_client = @import("ai/http_client.zig");
const json_parse = @import("ai/json_parse.zig");

const VERSION = "0.1.0";

const CliOptions = struct {
    model: ?[]const u8 = null,
    provider: []const u8 = "openai",
    api_key: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    system_prompt: ?[]const u8 = null,
    help: bool = false,
    version: bool = false,
};

fn printUsage() void {
    std.debug.print("pi - AI assistant (Zig rewrite) v{s}\n\n", .{VERSION});
    std.debug.print("Usage: pi [options] <prompt>\n\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  -m, --model <model>       Model ID (default depends on provider)\n", .{});
    std.debug.print("  -p, --provider <provider> Provider: openai, kimi (default: openai)\n", .{});
    std.debug.print("  -k, --api-key <key>       API key (or set OPENAI_API_KEY / KIMI_API_KEY env var)\n", .{});
    std.debug.print("  -u, --base-url <url>      Base URL for API\n", .{});
    std.debug.print("  -t, --temperature <temp>  Temperature (0.0-2.0)\n", .{});
    std.debug.print("  --max-tokens <n>          Maximum tokens to generate\n", .{});
    std.debug.print("  -s, --system <prompt>     System prompt\n", .{});
    std.debug.print("  -h, --help                Show this help\n", .{});
    std.debug.print("  -v, --version             Show version\n\n", .{});
    std.debug.print("Example:\n", .{});
    std.debug.print("  pi \"What is the meaning of life?\"\n", .{});
    std.debug.print("  pi -p kimi \"Explain quantum computing\"\n", .{});
    std.debug.print("  pi -s \"You are a poet\" \"Write a haiku about Zig\"\n", .{});
}

pub fn main(init: std.process.Init) !void {
    // Parse args directly from init.minimal.args without heap allocation
    var options = CliOptions{};
    var prompt: ?[:0]const u8 = null;

    var it = init.minimal.args.iterate();
    _ = it.next(); // skip program name

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            options.version = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--model")) {
            const next_arg = it.next() orelse {
                std.debug.print("Error: Missing argument for option\n", .{});
                printUsage();
                std.process.exit(1);
            };
            options.model = next_arg;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--provider")) {
            const next_arg = it.next() orelse {
                std.debug.print("Error: Missing argument for option\n", .{});
                printUsage();
                std.process.exit(1);
            };
            options.provider = next_arg;
        } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--api-key")) {
            const next_arg = it.next() orelse {
                std.debug.print("Error: Missing argument for option\n", .{});
                printUsage();
                std.process.exit(1);
            };
            options.api_key = next_arg;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--base-url")) {
            const next_arg = it.next() orelse {
                std.debug.print("Error: Missing argument for option\n", .{});
                printUsage();
                std.process.exit(1);
            };
            options.base_url = next_arg;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--temperature")) {
            const next_arg = it.next() orelse {
                std.debug.print("Error: Missing argument for option\n", .{});
                printUsage();
                std.process.exit(1);
            };
            options.temperature = std.fmt.parseFloat(f32, next_arg) catch {
                std.debug.print("Error: Invalid temperature value\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--max-tokens")) {
            const next_arg = it.next() orelse {
                std.debug.print("Error: Missing argument for option\n", .{});
                printUsage();
                std.process.exit(1);
            };
            options.max_tokens = std.fmt.parseInt(u32, next_arg, 10) catch {
                std.debug.print("Error: Invalid max-tokens value\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--system")) {
            const next_arg = it.next() orelse {
                std.debug.print("Error: Missing argument for option\n", .{});
                printUsage();
                std.process.exit(1);
            };
            options.system_prompt = next_arg;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printUsage();
            std.process.exit(1);
        } else {
            prompt = arg;
        }
    }

    if (options.help) {
        printUsage();
        return;
    }

    if (options.version) {
        std.debug.print("pi version {s}\n", .{VERSION});
        return;
    }

    if (prompt == null) {
        std.debug.print("Error: No prompt provided\n", .{});
        printUsage();
        std.process.exit(1);
    }

    // Determine provider defaults and API key env var
    const is_kimi = std.mem.eql(u8, options.provider, "kimi");
    const default_model = if (is_kimi) "moonshot-v1-8k" else "gpt-4";
    const default_base_url = if (is_kimi) "https://api.moonshot.cn/v1" else "https://api.openai.com/v1";
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
    const base_url = options.base_url orelse default_base_url;

    // Build model config
    const model = ai.Model{
        .id = model_id,
        .name = model_id,
        .api = if (is_kimi) "kimi-completions" else "openai-completions",
        .provider = options.provider,
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 8192,
        .max_tokens = 4096,
    };

    // Build context
    const content_block = ai.ContentBlock{ .text = .{ .text = prompt.? } };
    const now: i64 = @intCast(@divFloor(std.Io.Clock.now(.real, init.io).nanoseconds, std.time.ns_per_s));
    const user_msg = ai.Message{ .user = .{
        .content = &[_]ai.ContentBlock{content_block},
        .timestamp = now,
    } };
    const context = ai.Context{
        .system_prompt = options.system_prompt,
        .messages = &[_]ai.Message{user_msg},
    };

    // Build stream options
    const stream_options = ai.StreamOptions{
        .temperature = options.temperature,
        .max_tokens = options.max_tokens,
        .api_key = api_key,
    };

    std.debug.print("pi v{s}\n\n", .{VERSION});

    // Perform actual streaming request
    try streamChatCompletion(init.gpa, init.io, model, context, stream_options);
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
