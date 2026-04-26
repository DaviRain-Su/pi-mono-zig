const std = @import("std");
const cli = @import("args.zig");

pub const AppMode = enum {
    interactive,
    print,
    json,
    rpc,
};

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) cli.ParseArgsError!cli.Args {
    return cli.parseArgs(allocator, argv);
}

pub fn parseErrorMessage(err: cli.ParseArgsError) []const u8 {
    return switch (err) {
        error.MissingOptionValue => "Missing value for option",
        error.InvalidMode => "Invalid mode. Expected one of: text, json, rpc",
        error.InvalidThinkingLevel => "Invalid thinking level. Expected one of: off, minimal, low, medium, high, xhigh",
        error.UnknownOption => "Unknown option",
        error.OutOfMemory => "Out of memory while parsing CLI arguments",
    };
}

pub fn resolveAppMode(mode: cli.Mode, print_requested: bool, stdin_is_tty: bool) AppMode {
    return switch (mode) {
        .rpc => .rpc,
        .json => .json,
        .text => if (print_requested or !stdin_is_tty) .print else .interactive,
    };
}

pub fn effectiveToolSelection(options: *const cli.Args) ?[]const []const u8 {
    if (options.no_tools) {
        return options.tools orelse &[_][]const u8{};
    }
    if (options.no_builtin_tools and options.tools == null) {
        return &[_][]const u8{};
    }
    return options.tools;
}

pub fn startupNetworkOperationsEnabled(options: *const cli.Args, env_map: *const std.process.Environ.Map) bool {
    return !options.offline and !isTruthyEnvFlag(env_map.get("PI_OFFLINE"));
}

fn isTruthyEnvFlag(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.ascii.eqlIgnoreCase(text, "1") or
        std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "on");
}
