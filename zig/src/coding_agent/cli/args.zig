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

pub const Diagnostic = struct {
    kind: []const u8,
    message: []const u8,
};

pub const UnknownFlag = struct {
    name: []u8,
    value: ?[]u8 = null,
};

pub const Args = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    thinking: ?ThinkingLevel = null,
    continue_session: bool = false,
    resume_session: bool = false,
    help: bool = false,
    version: bool = false,
    mode: ?Mode = null,
    no_session: bool = false,
    session: ?[]const u8 = null,
    fork: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    no_tools: bool = false,
    no_builtin_tools: bool = false,
    no_extensions: bool = false,
    print: bool = false,
    export_path: ?[]const u8 = null,
    no_skills: bool = false,
    no_prompt_templates: bool = false,
    no_themes: bool = false,
    no_context_files: bool = false,
    list_models: ?[]const u8 = null,
    list_models_all: bool = false,
    offline: bool = false,
    verbose: bool = false,
    messages: []const []const u8 = &.{},
    file_args: []const []const u8 = &.{},
    unknown_flags: []UnknownFlag = &.{},
    diagnostics: []Diagnostic = &.{},

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        for (self.unknown_flags) |flag| {
            allocator.free(flag.name);
            if (flag.value) |value| allocator.free(value);
        }
        allocator.free(self.unknown_flags);
        allocator.free(self.messages);
        allocator.free(self.file_args);
        allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const VALID_THINKING_LEVELS = [_][]const u8{ "off", "minimal", "low", "medium", "high", "xhigh" };

pub fn isValidThinkingLevel(level: []const u8) bool {
    return parseThinkingLevel(level) != null;
}

pub fn parseThinkingLevel(level: []const u8) ?ThinkingLevel {
    if (std.mem.eql(u8, level, "off")) return .off;
    if (std.mem.eql(u8, level, "minimal")) return .minimal;
    if (std.mem.eql(u8, level, "low")) return .low;
    if (std.mem.eql(u8, level, "medium")) return .medium;
    if (std.mem.eql(u8, level, "high")) return .high;
    if (std.mem.eql(u8, level, "xhigh")) return .xhigh;
    return null;
}

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !Args {
    var messages: std.ArrayList([]const u8) = .empty;
    errdefer messages.deinit(allocator);
    var file_args: std.ArrayList([]const u8) = .empty;
    errdefer file_args.deinit(allocator);
    var unknown_flags: std.ArrayList(UnknownFlag) = .empty;
    errdefer {
        for (unknown_flags.items) |flag| {
            allocator.free(flag.name);
            if (flag.value) |value| allocator.free(value);
        }
        unknown_flags.deinit(allocator);
    }
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);

    var result: Args = .{};
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            result.version = true;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            if (takeNext(argv, &index)) |value| result.mode = parseMode(value);
        } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c")) {
            result.continue_session = true;
        } else if (std.mem.eql(u8, arg, "--resume") or std.mem.eql(u8, arg, "-r")) {
            result.resume_session = true;
        } else if (std.mem.eql(u8, arg, "--provider")) {
            if (takeNext(argv, &index)) |value| result.provider = value;
        } else if (std.mem.eql(u8, arg, "--model")) {
            if (takeNext(argv, &index)) |value| result.model = value;
        } else if (std.mem.eql(u8, arg, "--api-key")) {
            if (takeNext(argv, &index)) |value| result.api_key = value;
        } else if (std.mem.eql(u8, arg, "--system-prompt")) {
            if (takeNext(argv, &index)) |value| result.system_prompt = value;
        } else if (std.mem.eql(u8, arg, "--no-session")) {
            result.no_session = true;
        } else if (std.mem.eql(u8, arg, "--session")) {
            if (takeNext(argv, &index)) |value| result.session = value;
        } else if (std.mem.eql(u8, arg, "--fork")) {
            if (takeNext(argv, &index)) |value| result.fork = value;
        } else if (std.mem.eql(u8, arg, "--session-dir")) {
            if (takeNext(argv, &index)) |value| result.session_dir = value;
        } else if (std.mem.eql(u8, arg, "--no-tools") or std.mem.eql(u8, arg, "-nt")) {
            result.no_tools = true;
        } else if (std.mem.eql(u8, arg, "--no-builtin-tools") or std.mem.eql(u8, arg, "-nbt")) {
            result.no_builtin_tools = true;
        } else if (std.mem.eql(u8, arg, "--thinking")) {
            if (takeNext(argv, &index)) |value| {
                if (parseThinkingLevel(value)) |level| {
                    result.thinking = level;
                } else {
                    try diagnostics.append(allocator, .{ .kind = "warning", .message = "Invalid thinking level" });
                }
            }
        } else if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
            result.print = true;
            if (peek(argv, index + 1)) |next| {
                if (!std.mem.startsWith(u8, next, "@") and (!std.mem.startsWith(u8, next, "-") or std.mem.startsWith(u8, next, "---"))) {
                    try messages.append(allocator, next);
                    index += 1;
                }
            }
        } else if (std.mem.eql(u8, arg, "--export")) {
            if (takeNext(argv, &index)) |value| result.export_path = value;
        } else if (std.mem.eql(u8, arg, "--no-extensions") or std.mem.eql(u8, arg, "-ne")) {
            result.no_extensions = true;
        } else if (std.mem.eql(u8, arg, "--no-skills") or std.mem.eql(u8, arg, "-ns")) {
            result.no_skills = true;
        } else if (std.mem.eql(u8, arg, "--no-prompt-templates") or std.mem.eql(u8, arg, "-np")) {
            result.no_prompt_templates = true;
        } else if (std.mem.eql(u8, arg, "--no-themes")) {
            result.no_themes = true;
        } else if (std.mem.eql(u8, arg, "--no-context-files") or std.mem.eql(u8, arg, "-nc")) {
            result.no_context_files = true;
        } else if (std.mem.eql(u8, arg, "--list-models")) {
            if (peek(argv, index + 1)) |next| {
                if (!std.mem.startsWith(u8, next, "-") and !std.mem.startsWith(u8, next, "@")) {
                    result.list_models = next;
                    index += 1;
                } else {
                    result.list_models_all = true;
                }
            } else {
                result.list_models_all = true;
            }
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            result.verbose = true;
        } else if (std.mem.eql(u8, arg, "--offline")) {
            result.offline = true;
        } else if (std.mem.startsWith(u8, arg, "@")) {
            try file_args.append(allocator, arg[1..]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try appendUnknownFlag(allocator, &unknown_flags, argv, &index);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try diagnostics.append(allocator, .{ .kind = "error", .message = "Unknown option" });
        } else {
            try messages.append(allocator, arg);
        }
    }
    result.messages = try messages.toOwnedSlice(allocator);
    result.file_args = try file_args.toOwnedSlice(allocator);
    result.unknown_flags = try unknown_flags.toOwnedSlice(allocator);
    result.diagnostics = try diagnostics.toOwnedSlice(allocator);
    return result;
}

fn parseMode(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    if (std.mem.eql(u8, value, "rpc")) return .rpc;
    return null;
}

fn takeNext(argv: []const []const u8, index: *usize) ?[]const u8 {
    if (index.* + 1 >= argv.len) return null;
    index.* += 1;
    return argv[index.*];
}

fn peek(argv: []const []const u8, index: usize) ?[]const u8 {
    return if (index < argv.len) argv[index] else null;
}

fn appendUnknownFlag(allocator: std.mem.Allocator, flags: *std.ArrayList(UnknownFlag), argv: []const []const u8, index: *usize) !void {
    const arg = argv[index.*];
    if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
        try flags.append(allocator, .{ .name = try allocator.dupe(u8, arg[2..eq]), .value = try allocator.dupe(u8, arg[eq + 1 ..]) });
        return;
    }
    const name = arg[2..];
    if (peek(argv, index.* + 1)) |next| {
        if (!std.mem.startsWith(u8, next, "-") and !std.mem.startsWith(u8, next, "@")) {
            index.* += 1;
            try flags.append(allocator, .{ .name = try allocator.dupe(u8, name), .value = try allocator.dupe(u8, next) });
            return;
        }
    }
    try flags.append(allocator, .{ .name = try allocator.dupe(u8, name), .value = null });
}

test "parseArgs separates messages files and extension flags" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "--model", "sonnet", "@prompt.md", "--plan", "deep", "hello" };
    var parsed = try parseArgs(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("sonnet", parsed.model.?);
    try std.testing.expectEqualStrings("prompt.md", parsed.file_args[0]);
    try std.testing.expectEqualStrings("plan", parsed.unknown_flags[0].name);
    try std.testing.expectEqualStrings("hello", parsed.messages[0]);
}
