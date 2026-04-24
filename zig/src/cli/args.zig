const std = @import("std");

pub const Mode = enum {
    text,
    json,
    rpc,
};

pub const ThinkingLevel = enum {
    off,
    minimal,
    low,
    medium,
    high,
    xhigh,
};

pub const ParseError = error{
    MissingOptionValue,
    InvalidMode,
    InvalidThinkingLevel,
    UnknownOption,
};

pub const ParseArgsError = ParseError || std.mem.Allocator.Error;

pub const Args = struct {
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    thinking: ?ThinkingLevel = null,
    @"continue": bool = false,
    session: ?[]const u8 = null,
    print: bool = false,
    mode: Mode = .text,
    tools: ?[]const []const u8 = null,
    no_tools: bool = false,
    help: bool = false,
    version: bool = false,
    prompt: ?[]const u8 = null,

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        if (self.tools) |tools| allocator.free(tools);
        self.* = undefined;
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) ParseArgsError!Args {
    var result = Args{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            result.version = true;
        } else if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.model = argv[i];
        } else if (std.mem.eql(u8, arg, "--provider")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.provider = argv[i];
        } else if (std.mem.eql(u8, arg, "--api-key") or std.mem.eql(u8, arg, "-k")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.api_key = argv[i];
        } else if (std.mem.eql(u8, arg, "--thinking")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.thinking = parseThinkingLevel(argv[i]) orelse return error.InvalidThinkingLevel;
        } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c")) {
            result.@"continue" = true;
        } else if (std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.session = argv[i];
        } else if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
            result.print = true;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.mode = parseMode(argv[i]) orelse return error.InvalidMode;
        } else if (std.mem.eql(u8, arg, "--tools")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.tools = try parseToolList(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--no-tools")) {
            result.no_tools = true;
        } else if (std.mem.eql(u8, arg, "--system-prompt") or std.mem.eql(u8, arg, "--system") or std.mem.eql(u8, arg, "-s")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.system_prompt = argv[i];
        } else if (std.mem.eql(u8, arg, "--append-system-prompt")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.append_system_prompt = argv[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            result.prompt = arg;
        }
    }

    return result;
}

pub fn helpText(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\pi - AI assistant (Zig rewrite) v{s}
        \\
        \\Usage:
        \\  pi [options] [prompt]
        \\
        \\Options:
        \\  --model <model>                Model ID (default depends on provider)
        \\  --provider <provider>          Provider name (default: openai)
        \\  --api-key <key>                API key (defaults to provider env vars)
        \\  --thinking <level>             Thinking level: off, minimal, low, medium, high, xhigh
        \\  --continue, -c                 Continue a previous session
        \\  --session <id|path>            Use a specific session identifier or path
        \\  --print, -p                    Non-interactive mode
        \\  --mode <text|json|rpc>         Output mode (default: text)
        \\  --tools <names>                Comma-separated tool allowlist
        \\  --no-tools                     Disable built-in tools by default
        \\  --system-prompt <text>         Replace the default system prompt
        \\  --append-system-prompt <text>  Append text to the system prompt
        \\  --help, -h                     Show this help
        \\  --version, -v                  Show version
        \\
        \\Examples:
        \\  pi --help
        \\  pi --version
        \\  pi --model gpt-4.1 --provider openai "Summarize this repository"
        \\  pi --print --mode json "Explain the latest session"
        \\  pi --tools read,grep,ls "Inspect the codebase"
        \\
    ,
        .{version},
    );
}

pub fn versionText(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "pi version {s}\n", .{version});
}

fn parseMode(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    if (std.mem.eql(u8, value, "rpc")) return .rpc;
    return null;
}

fn parseThinkingLevel(value: []const u8) ?ThinkingLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return null;
}

fn parseToolList(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var tools = std.ArrayList([]const u8).empty;
    errdefer tools.deinit(allocator);

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t\r\n");
        if (trimmed.len == 0) continue;
        try tools.append(allocator, trimmed);
    }

    return try tools.toOwnedSlice(allocator);
}

test "parse args supports expected CLI flags" {
    const allocator = std.testing.allocator;
    var args = try parseArgs(allocator, &.{
        "--model",
        "gpt-4.1",
        "--provider",
        "openai",
        "--api-key",
        "secret",
        "--thinking",
        "high",
        "--continue",
        "--session",
        "session-123",
        "--print",
        "--mode",
        "json",
        "--tools",
        "read, grep,ls",
        "--no-tools",
        "Summarize the repository",
    });
    defer args.deinit(allocator);

    try std.testing.expectEqualStrings("gpt-4.1", args.model.?);
    try std.testing.expectEqualStrings("openai", args.provider.?);
    try std.testing.expectEqualStrings("secret", args.api_key.?);
    try std.testing.expectEqual(ThinkingLevel.high, args.thinking.?);
    try std.testing.expect(args.@"continue");
    try std.testing.expectEqualStrings("session-123", args.session.?);
    try std.testing.expect(args.print);
    try std.testing.expectEqual(Mode.json, args.mode);
    try std.testing.expect(args.no_tools);
    try std.testing.expectEqualStrings("Summarize the repository", args.prompt.?);
    try std.testing.expectEqual(@as(usize, 3), args.tools.?.len);
    try std.testing.expectEqualStrings("read", args.tools.?[0]);
    try std.testing.expectEqualStrings("grep", args.tools.?[1]);
    try std.testing.expectEqualStrings("ls", args.tools.?[2]);
}

test "parse args supports help and version" {
    const allocator = std.testing.allocator;

    var help_args = try parseArgs(allocator, &.{"--help"});
    defer help_args.deinit(allocator);
    try std.testing.expect(help_args.help);

    var version_args = try parseArgs(allocator, &.{"--version"});
    defer version_args.deinit(allocator);
    try std.testing.expect(version_args.version);
}

test "parse args rejects invalid thinking level" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidThinkingLevel, parseArgs(allocator, &.{ "--thinking", "turbo" }));
}

test "help text mentions expected flags" {
    const allocator = std.testing.allocator;
    const help = try helpText(allocator, "0.1.0");
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
    try std.testing.expect(std.mem.indexOf(u8, help, "--help, -h") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Examples:") != null);
}

test "version text prints version" {
    const allocator = std.testing.allocator;
    const version = try versionText(allocator, "0.1.0");
    defer allocator.free(version);

    try std.testing.expectEqualStrings("pi version 0.1.0\n", version);
}
