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
    extensions: ?[]const []const u8 = null,
    no_extensions: bool = false,
    skills: ?[]const []const u8 = null,
    no_skills: bool = false,
    prompt_templates: ?[]const []const u8 = null,
    no_prompt_templates: bool = false,
    themes: ?[]const []const u8 = null,
    no_themes: bool = false,
    @"continue": bool = false,
    @"resume": bool = false,
    session: ?[]const u8 = null,
    fork: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    models: ?[]const []const u8 = null,
    list_models: bool = false,
    list_models_search: ?[]const u8 = null,
    no_session: bool = false,
    print: bool = false,
    mode: Mode = .text,
    tools: ?[]const []const u8 = null,
    no_tools: bool = false,
    help: bool = false,
    version: bool = false,
    prompt: ?[]const u8 = null,
    prompt_owned: bool = false,
    file_args: ?[]const []const u8 = null,

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        if (self.extensions) |extensions| allocator.free(extensions);
        if (self.skills) |skills| allocator.free(skills);
        if (self.prompt_templates) |prompt_templates| allocator.free(prompt_templates);
        if (self.themes) |themes| allocator.free(themes);
        if (self.tools) |tools| allocator.free(tools);
        if (self.models) |models| allocator.free(models);
        if (self.file_args) |file_args| allocator.free(file_args);
        if (self.prompt_owned and self.prompt != null) allocator.free(self.prompt.?);
        self.* = undefined;
    }
};

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) ParseArgsError!Args {
    var result = Args{};
    errdefer result.deinit(allocator);
    var prompt_builder = std.ArrayList(u8).empty;
    var prompt_transferred = false;
    defer if (!prompt_transferred) prompt_builder.deinit(allocator);
    var file_args_builder = std.ArrayList([]const u8).empty;
    var file_args_transferred = false;
    defer if (!file_args_transferred) file_args_builder.deinit(allocator);
    var extensions_builder = std.ArrayList([]const u8).empty;
    var extensions_transferred = false;
    defer if (!extensions_transferred) extensions_builder.deinit(allocator);
    var skills_builder = std.ArrayList([]const u8).empty;
    var skills_transferred = false;
    defer if (!skills_transferred) skills_builder.deinit(allocator);
    var prompt_templates_builder = std.ArrayList([]const u8).empty;
    var prompt_templates_transferred = false;
    defer if (!prompt_templates_transferred) prompt_templates_builder.deinit(allocator);
    var themes_builder = std.ArrayList([]const u8).empty;
    var themes_transferred = false;
    defer if (!themes_transferred) themes_builder.deinit(allocator);

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
        } else if (std.mem.eql(u8, arg, "--extension") or std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            try extensions_builder.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--no-extensions") or std.mem.eql(u8, arg, "-ne")) {
            result.no_extensions = true;
        } else if (std.mem.eql(u8, arg, "--skill")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            try skills_builder.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--no-skills") or std.mem.eql(u8, arg, "-ns")) {
            result.no_skills = true;
        } else if (std.mem.eql(u8, arg, "--prompt-template")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            try prompt_templates_builder.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--no-prompt-templates") or std.mem.eql(u8, arg, "-np")) {
            result.no_prompt_templates = true;
        } else if (std.mem.eql(u8, arg, "--theme")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            try themes_builder.append(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--no-themes")) {
            result.no_themes = true;
        } else if (std.mem.eql(u8, arg, "--thinking")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.thinking = parseThinkingLevel(argv[i]) orelse return error.InvalidThinkingLevel;
        } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c")) {
            result.@"continue" = true;
        } else if (std.mem.eql(u8, arg, "--resume") or std.mem.eql(u8, arg, "-r")) {
            result.@"resume" = true;
        } else if (std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.session = argv[i];
        } else if (std.mem.eql(u8, arg, "--fork")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.fork = argv[i];
        } else if (std.mem.eql(u8, arg, "--session-dir")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.session_dir = argv[i];
        } else if (std.mem.eql(u8, arg, "--models")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            if (result.models) |models| {
                allocator.free(models);
                result.models = null;
            }
            result.models = try parseCommaSeparatedList(allocator, argv[i]);
        } else if (std.mem.eql(u8, arg, "--list-models")) {
            result.list_models = true;
            if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
                i += 1;
                result.list_models_search = argv[i];
            }
        } else if (std.mem.eql(u8, arg, "--no-session")) {
            result.no_session = true;
        } else if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
            result.print = true;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            result.mode = parseMode(argv[i]) orelse return error.InvalidMode;
        } else if (std.mem.eql(u8, arg, "--tools")) {
            i += 1;
            if (i >= argv.len) return error.MissingOptionValue;
            if (result.tools) |tools| {
                allocator.free(tools);
                result.tools = null;
            }
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
        } else if (std.mem.startsWith(u8, arg, "@")) {
            try file_args_builder.append(allocator, arg[1..]);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            if (prompt_builder.items.len > 0) {
                try prompt_builder.append(allocator, ' ');
            }
            try prompt_builder.appendSlice(allocator, arg);
        }
    }

    if (prompt_builder.items.len > 0) {
        result.prompt = try prompt_builder.toOwnedSlice(allocator);
        result.prompt_owned = true;
        prompt_transferred = true;
    }

    if (file_args_builder.items.len > 0) {
        result.file_args = try file_args_builder.toOwnedSlice(allocator);
        file_args_transferred = true;
    }
    if (extensions_builder.items.len > 0) {
        result.extensions = try extensions_builder.toOwnedSlice(allocator);
        extensions_transferred = true;
    }
    if (skills_builder.items.len > 0) {
        result.skills = try skills_builder.toOwnedSlice(allocator);
        skills_transferred = true;
    }
    if (prompt_templates_builder.items.len > 0) {
        result.prompt_templates = try prompt_templates_builder.toOwnedSlice(allocator);
        prompt_templates_transferred = true;
    }
    if (themes_builder.items.len > 0) {
        result.themes = try themes_builder.toOwnedSlice(allocator);
        themes_transferred = true;
    }

    return result;
}

pub fn helpText(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        \\pi - AI assistant (Zig rewrite) v{s}
        \\
        \\Usage:
        \\  pi [options] [@files...] [prompt]
        \\
        \\Options:
        \\  --model <model>                Model ID (default depends on provider)
        \\  --provider <provider>          Provider name (default: openai)
        \\  --api-key <key>                API key (defaults to provider env vars)
        \\  --thinking <level>             Thinking level: off, minimal, low, medium, high, xhigh
        \\  --extension, -e <path>         Load an extension file or directory (repeatable)
        \\  --no-extensions, -ne           Disable default extension discovery
        \\  --skill <path>                 Load a skill file or directory (repeatable)
        \\  --no-skills, -ns               Disable default skill discovery
        \\  --prompt-template <path>       Load a prompt template file or directory (repeatable)
        \\  --no-prompt-templates, -np     Disable default prompt template discovery
        \\  --theme <path>                 Load a theme file or directory (repeatable)
        \\  --no-themes                    Disable default theme discovery
        \\  --continue, -c                 Continue a previous session
        \\  --resume, -r                   Resume the latest session
        \\  --session <id|path>            Use a specific session identifier or path
        \\  --fork <id|path>               Fork a specific session into a new session
        \\  --session-dir <dir>            Directory for session storage and lookup
        \\  --no-session                   Run without session persistence
        \\  --models <patterns>            Comma-separated model patterns for model selection
        \\  --list-models [search]         List available models and exit
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
        \\  pi --session-dir ./tmp/sessions --print "Summarize this repository"
        \\  pi @prompt.md @screenshot.png "What changed in this image?"
        \\  pi --models anthropic/*,*gpt-5*
        \\  pi --list-models sonnet
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

fn parseCommaSeparatedList(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var items = std.ArrayList([]const u8).empty;
    errdefer items.deinit(allocator);

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t\r\n");
        if (trimmed.len == 0) continue;
        try items.append(allocator, trimmed);
    }

    return try items.toOwnedSlice(allocator);
}

fn parseToolList(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    return parseCommaSeparatedList(allocator, value);
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
        "--extension",
        "extensions/review.ts",
        "--no-extensions",
        "--skill",
        "skills/reviewer",
        "--no-skills",
        "--prompt-template",
        "prompts/fix.md",
        "--no-prompt-templates",
        "--theme",
        "themes/night.json",
        "--no-themes",
        "--thinking",
        "high",
        "--continue",
        "--resume",
        "--session",
        "session-123",
        "--fork",
        "session-456",
        "--session-dir",
        "./sessions",
        "--models",
        "anthropic/*,*gpt-5*",
        "--list-models",
        "sonnet",
        "--no-session",
        "--print",
        "--mode",
        "json",
        "--tools",
        "read, grep,ls",
        "--no-tools",
        "@prompt.md",
        "@image.png",
        "Summarize the repository",
    });
    defer args.deinit(allocator);

    try std.testing.expectEqualStrings("gpt-4.1", args.model.?);
    try std.testing.expectEqualStrings("openai", args.provider.?);
    try std.testing.expectEqualStrings("secret", args.api_key.?);
    try std.testing.expectEqual(@as(usize, 1), args.extensions.?.len);
    try std.testing.expectEqualStrings("extensions/review.ts", args.extensions.?[0]);
    try std.testing.expect(args.no_extensions);
    try std.testing.expectEqual(@as(usize, 1), args.skills.?.len);
    try std.testing.expectEqualStrings("skills/reviewer", args.skills.?[0]);
    try std.testing.expect(args.no_skills);
    try std.testing.expectEqual(@as(usize, 1), args.prompt_templates.?.len);
    try std.testing.expectEqualStrings("prompts/fix.md", args.prompt_templates.?[0]);
    try std.testing.expect(args.no_prompt_templates);
    try std.testing.expectEqual(@as(usize, 1), args.themes.?.len);
    try std.testing.expectEqualStrings("themes/night.json", args.themes.?[0]);
    try std.testing.expect(args.no_themes);
    try std.testing.expectEqual(ThinkingLevel.high, args.thinking.?);
    try std.testing.expect(args.@"continue");
    try std.testing.expect(args.@"resume");
    try std.testing.expectEqualStrings("session-123", args.session.?);
    try std.testing.expectEqualStrings("session-456", args.fork.?);
    try std.testing.expectEqualStrings("./sessions", args.session_dir.?);
    try std.testing.expectEqual(@as(usize, 2), args.models.?.len);
    try std.testing.expectEqualStrings("anthropic/*", args.models.?[0]);
    try std.testing.expectEqualStrings("*gpt-5*", args.models.?[1]);
    try std.testing.expect(args.list_models);
    try std.testing.expectEqualStrings("sonnet", args.list_models_search.?);
    try std.testing.expect(args.no_session);
    try std.testing.expect(args.print);
    try std.testing.expectEqual(Mode.json, args.mode);
    try std.testing.expect(args.no_tools);
    try std.testing.expectEqualStrings("Summarize the repository", args.prompt.?);
    try std.testing.expectEqual(@as(usize, 2), args.file_args.?.len);
    try std.testing.expectEqualStrings("prompt.md", args.file_args.?[0]);
    try std.testing.expectEqualStrings("image.png", args.file_args.?[1]);
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

test "parse args frees previous tool list when --tools is repeated" {
    const allocator = std.testing.allocator;

    var args = try parseArgs(allocator, &.{
        "--tools",
        "read,grep",
        "--tools",
        "ls",
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), args.tools.?.len);
    try std.testing.expectEqualStrings("ls", args.tools.?[0]);
}

test "parse args frees previous model list when --models is repeated" {
    const allocator = std.testing.allocator;

    var args = try parseArgs(allocator, &.{
        "--models",
        "anthropic/*,openai/*",
        "--models",
        "faux/*",
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), args.models.?.len);
    try std.testing.expectEqualStrings("faux/*", args.models.?[0]);
}

test "parse args supports list-models without a search term" {
    const allocator = std.testing.allocator;

    var args = try parseArgs(allocator, &.{"--list-models"});
    defer args.deinit(allocator);

    try std.testing.expect(args.list_models);
    try std.testing.expect(args.list_models_search == null);
}

test "parse args concatenates multiple positional prompts" {
    const allocator = std.testing.allocator;

    var args = try parseArgs(allocator, &.{
        "Summarize",
        "the",
        "repository",
    });
    defer args.deinit(allocator);

    try std.testing.expect(args.prompt_owned);
    try std.testing.expectEqualStrings("Summarize the repository", args.prompt.?);
}

test "parse args keeps @file arguments separate from the prompt" {
    const allocator = std.testing.allocator;

    var args = try parseArgs(allocator, &.{
        "@notes.md",
        "Explain",
        "@diagram.png",
        "this",
    });
    defer args.deinit(allocator);

    try std.testing.expectEqualStrings("Explain this", args.prompt.?);
    try std.testing.expectEqual(@as(usize, 2), args.file_args.?.len);
    try std.testing.expectEqualStrings("notes.md", args.file_args.?[0]);
    try std.testing.expectEqualStrings("diagram.png", args.file_args.?[1]);
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
    try std.testing.expect(std.mem.indexOf(u8, help, "--extension, -e <path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-extensions, -ne") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--skill <path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-skills, -ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--prompt-template <path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-prompt-templates, -np") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--theme <path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-themes") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--continue, -c") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--resume, -r") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--session <id|path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--fork <id|path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--session-dir <dir>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-session") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--models <patterns>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--list-models [search]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--print, -p") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--mode <text|json|rpc>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--tools <names>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--help, -h") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "[@files...] [prompt]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Examples:") != null);
}

test "version text prints version" {
    const allocator = std.testing.allocator;
    const version = try versionText(allocator, "0.1.0");
    defer allocator.free(version);

    try std.testing.expectEqualStrings("pi version 0.1.0\n", version);
}
