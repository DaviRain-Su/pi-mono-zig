const std = @import("std");

pub const Mode = enum {
    text,
    json,
    rpc,
};

pub const ToolName = enum {
    read,
    bash,
    edit,
    write,
    grep,
    find,
    ls,
};

pub const Diagnostics = struct {
    items: std.ArrayList(Item),
    gpa: std.mem.Allocator,

    pub const Severity = enum { warning, error_msg };

    pub const Item = struct {
        severity: Severity,
        message: []const u8,
    };

    pub fn init(gpa: std.mem.Allocator) Diagnostics {
        return .{ .items = std.ArrayList(Item).empty, .gpa = gpa };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.items.deinit(self.gpa);
    }

    pub fn push(self: *Diagnostics, sev: Severity, msg: []const u8) void {
        self.items.append(self.gpa, .{ .severity = sev, .message = msg }) catch @panic("OOM");
    }
};

pub const Args = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    cont: bool = false,
    resume_session: bool = false,
    help: bool = false,
    version: bool = false,
    mode: ?Mode = null,
    no_session: bool = false,
    session: ?[]const u8 = null,
    fork: ?[]const u8 = null,
    session_dir: ?[]const u8 = null,
    models: std.ArrayList([]const u8),
    tools: std.ArrayList(ToolName),
    no_tools: bool = false,
    extensions: std.ArrayList([]const u8),
    no_extensions: bool = false,
    print_mode: bool = false,
    export_file: ?[]const u8 = null,
    no_skills: bool = false,
    skills: std.ArrayList([]const u8),
    prompt_templates: std.ArrayList([]const u8),
    no_prompt_templates: bool = false,
    themes: std.ArrayList([]const u8),
    no_themes: bool = false,
    list_models: union(enum) { none, all, search: []const u8 } = .none,
    offline: bool = false,
    verbose: bool = false,
    messages: std.ArrayList([]const u8),
    file_args: std.ArrayList([]const u8),
    diagnostics: Diagnostics,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Args {
        return .{
            .models = std.ArrayList([]const u8).empty,
            .tools = std.ArrayList(ToolName).empty,
            .extensions = std.ArrayList([]const u8).empty,
            .skills = std.ArrayList([]const u8).empty,
            .prompt_templates = std.ArrayList([]const u8).empty,
            .themes = std.ArrayList([]const u8).empty,
            .messages = std.ArrayList([]const u8).empty,
            .file_args = std.ArrayList([]const u8).empty,
            .diagnostics = Diagnostics.init(gpa),
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *Args) void {
        self.models.deinit(self.gpa);
        self.tools.deinit(self.gpa);
        self.extensions.deinit(self.gpa);
        self.skills.deinit(self.gpa);
        self.prompt_templates.deinit(self.gpa);
        self.themes.deinit(self.gpa);
        self.messages.deinit(self.gpa);
        self.file_args.deinit(self.gpa);
        self.diagnostics.deinit();
    }
};

pub fn parseArgs(gpa: std.mem.Allocator, raw_args: []const []const u8) !Args {
    var result = Args.init(gpa);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.help = true;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            result.version = true;
        } else if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i < raw_args.len) {
                const m = raw_args[i];
                if (std.mem.eql(u8, m, "text")) {
                    result.mode = .text;
                } else if (std.mem.eql(u8, m, "json")) {
                    result.mode = .json;
                } else if (std.mem.eql(u8, m, "rpc")) {
                    result.mode = .rpc;
                }
            }
        } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "-c")) {
            result.cont = true;
        } else if (std.mem.eql(u8, arg, "--resume") or std.mem.eql(u8, arg, "-r")) {
            result.resume_session = true;
        } else if (std.mem.eql(u8, arg, "--provider")) {
            i += 1;
            if (i < raw_args.len) result.provider = raw_args[i];
        } else if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i < raw_args.len) result.model = raw_args[i];
        } else if (std.mem.eql(u8, arg, "--api-key")) {
            i += 1;
            if (i < raw_args.len) result.api_key = raw_args[i];
        } else if (std.mem.eql(u8, arg, "--system-prompt")) {
            i += 1;
            if (i < raw_args.len) result.system_prompt = raw_args[i];
        } else if (std.mem.eql(u8, arg, "--append-system-prompt")) {
            i += 1;
            if (i < raw_args.len) result.append_system_prompt = raw_args[i];
        } else if (std.mem.eql(u8, arg, "--no-session")) {
            result.no_session = true;
        } else if (std.mem.eql(u8, arg, "--session")) {
            i += 1;
            if (i < raw_args.len) result.session = raw_args[i];
        } else if (std.mem.eql(u8, arg, "--fork")) {
            i += 1;
            if (i < raw_args.len) result.fork = raw_args[i];
        } else if (std.mem.eql(u8, arg, "--session-dir")) {
            i += 1;
            if (i < raw_args.len) result.session_dir = raw_args[i];
        } else if (std.mem.eql(u8, arg, "--models")) {
            i += 1;
            if (i < raw_args.len) {
                var it = std.mem.splitScalar(u8, raw_args[i], ',');
                while (it.next()) |s| {
                    const trimmed = std.mem.trim(u8, s, " ");
                    result.models.append(gpa, trimmed) catch @panic("OOM");
                }
            }
        } else if (std.mem.eql(u8, arg, "--no-tools")) {
            result.no_tools = true;
        } else if (std.mem.eql(u8, arg, "--tools")) {
            i += 1;
            if (i < raw_args.len) {
                var it = std.mem.splitScalar(u8, raw_args[i], ',');
                while (it.next()) |s| {
                    const trimmed = std.mem.trim(u8, s, " ");
                    const tool = std.meta.stringToEnum(ToolName, trimmed);
                    if (tool) |t| {
                        result.tools.append(gpa, t) catch @panic("OOM");
                    } else {
                        result.diagnostics.push(.warning, try std.fmt.allocPrint(gpa, "Unknown tool \"{s}\"", .{trimmed}));
                    }
                }
            }
        } else if (std.mem.eql(u8, arg, "--thinking")) {
            i += 1;
            if (i < raw_args.len) result.thinking = raw_args[i];
        } else if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
            result.print_mode = true;
        } else if (std.mem.eql(u8, arg, "--export")) {
            i += 1;
            if (i < raw_args.len) result.export_file = raw_args[i];
        } else if (std.mem.eql(u8, arg, "--extension") or std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i < raw_args.len) result.extensions.append(gpa, raw_args[i]) catch @panic("OOM");
        } else if (std.mem.eql(u8, arg, "--no-extensions") or std.mem.eql(u8, arg, "-ne")) {
            result.no_extensions = true;
        } else if (std.mem.eql(u8, arg, "--skill")) {
            i += 1;
            if (i < raw_args.len) result.skills.append(gpa, raw_args[i]) catch @panic("OOM");
        } else if (std.mem.eql(u8, arg, "--prompt-template")) {
            i += 1;
            if (i < raw_args.len) result.prompt_templates.append(gpa, raw_args[i]) catch @panic("OOM");
        } else if (std.mem.eql(u8, arg, "--theme")) {
            i += 1;
            if (i < raw_args.len) result.themes.append(gpa, raw_args[i]) catch @panic("OOM");
        } else if (std.mem.eql(u8, arg, "--no-skills") or std.mem.eql(u8, arg, "-ns")) {
            result.no_skills = true;
        } else if (std.mem.eql(u8, arg, "--no-prompt-templates") or std.mem.eql(u8, arg, "-np")) {
            result.no_prompt_templates = true;
        } else if (std.mem.eql(u8, arg, "--no-themes")) {
            result.no_themes = true;
        } else if (std.mem.eql(u8, arg, "--list-models")) {
            if (i + 1 < raw_args.len and !std.mem.startsWith(u8, raw_args[i + 1], "-") and !std.mem.startsWith(u8, raw_args[i + 1], "@")) {
                i += 1;
                result.list_models = .{ .search = raw_args[i] };
            } else {
                result.list_models = .all;
            }
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            result.verbose = true;
        } else if (std.mem.eql(u8, arg, "--offline")) {
            result.offline = true;
        } else if (std.mem.startsWith(u8, arg, "@")) {
            result.file_args.append(gpa, arg[1..]) catch @panic("OOM");
        } else if (std.mem.startsWith(u8, arg, "--")) {
            result.diagnostics.push(.warning, try std.fmt.allocPrint(gpa, "Unknown flag: {s}", .{arg}));
        } else if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            result.diagnostics.push(.error_msg, try std.fmt.allocPrint(gpa, "Unknown option: {s}", .{arg}));
        } else {
            result.messages.append(gpa, arg) catch @panic("OOM");
        }
    }

    return result;
}

const help_text =
    \\pi - AI coding assistant (zig rewrite)
    \\Usage:
    \\  pi [options] [@files...] [messages...]
    \\n    \\Options:
    \\  --provider <name>              Provider name
    \\  --model <id>                   Model ID
    \\  --api-key <key>                API key
    \\  --system-prompt <text>         System prompt
    \\  --mode <mode>                  text | json | rpc
    \\  --print, -p                    Non-interactive mode
    \\  --continue, -c                 Continue previous session
    \\  --resume, -r                   Resume a session
    \\  --session <path>               Use specific session
    \\  --fork <path>                  Fork a session
    \\  --session-dir <dir>            Session directory
    \\  --no-session                   Ephemeral mode
    \\  --models <list>                Comma-separated model list
    \\  --no-tools                     Disable tools
    \\  --tools <list>                 Enable specific tools
    \\  --thinking <level>             off | minimal | low | medium | high | xhigh
    \\  --extension, -e <path>         Load extension
    \\  --skill <path>                 Load skill
    \\  --theme <path>                 Load theme
    \\  --export <file>                Export session to HTML
    \\  --list-models [search]         List models
    \\  --verbose                      Verbose output
    \\  --offline                      Offline mode
    \\  --help, -h                     Show this help
    \\  --version, -v                  Show version
    \\n
;

pub fn printHelp(writer: anytype) !void {
    try writer.print(help_text, .{});
}

pub fn printHelpAlloc(gpa: std.mem.Allocator) ![]const u8 {
    return try gpa.dupe(u8, help_text);
}
