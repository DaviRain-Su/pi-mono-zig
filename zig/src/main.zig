const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const cli = @import("cli/args.zig");
const config_mod = @import("coding_agent/config.zig");
const context_files_mod = @import("coding_agent/context_files.zig");
const resources_mod = @import("coding_agent/resources.zig");
const session_advanced = @import("coding_agent/session_advanced.zig");
const coding_agent = @import("coding_agent/root.zig");

const VERSION = "0.1.0";

const AppMode = enum {
    interactive,
    print,
    json,
    rpc,
};

const CliStdin = struct {
    is_tty: bool = true,
    content: ?[]const u8 = null,
    owns_content: bool = false,

    fn deinit(self: *CliStdin, allocator: std.mem.Allocator) void {
        if (self.owns_content and self.content != null) allocator.free(self.content.?);
        self.* = .{};
    }
};

const PreparedInitialInput = struct {
    prompt: ?[]u8 = null,
    images: []ai.ImageContent = &.{},

    fn deinit(self: *PreparedInitialInput, allocator: std.mem.Allocator) void {
        if (self.prompt) |prompt| allocator.free(prompt);
        if (self.images.len > 0) {
            for (self.images) |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            }
            allocator.free(self.images);
        }
        self.* = .{};
    }
};

const PreparedCliRuntime = struct {
    runtime_config: config_mod.RuntimeConfig,
    resource_bundle: resources_mod.ResourceBundle,
    context_files: []context_files_mod.ContextFile,
    system_prompt: []u8,
    session_dir: []u8,
    expanded_prompt: ?[]u8,
    provider_name: []const u8,
    model_name: ?[]const u8,
    thinking_level: agent.ThinkingLevel,

    fn deinit(self: *PreparedCliRuntime, allocator: std.mem.Allocator) void {
        if (self.expanded_prompt) |prompt| allocator.free(prompt);
        allocator.free(self.session_dir);
        allocator.free(self.system_prompt);
        context_files_mod.deinitContextFiles(allocator, self.context_files);
        self.resource_bundle.deinit(allocator);
        self.runtime_config.deinit();
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

    const exit_code = try runCliWithInput(init.gpa, init.io, init.environ_map, argv.items, null, null, stdout, stderr);
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
    var stdin_input = CliStdin{};
    return runCliWithInput(allocator, io, env_map, argv, cwd_override, &stdin_input, stdout, stderr);
}

fn runCliWithInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argv: []const []const u8,
    cwd_override: ?[]const u8,
    provided_stdin: ?*CliStdin,
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

    if (options.@"export") |session_file| {
        return runSessionExport(allocator, io, env_map, cwd_override, session_file, options.prompt, stdout, stderr) catch |err| {
            try stderr.print("Error: {s}\n", .{exportErrorMessage(err)});
            return 1;
        };
    }

    var detected_stdin = if (provided_stdin) |stdin_override|
        CliStdin{
            .is_tty = stdin_override.is_tty,
            .content = stdin_override.content,
            .owns_content = false,
        }
    else
        try detectCliStdin(allocator, io, options.mode);
    defer if (provided_stdin == null) detected_stdin.deinit(allocator);

    if (options.list_models) {
        return try printModelList(allocator, io, env_map, options.list_models_search, stdout);
    }

    if (options.fork != null and
        (options.session != null or options.@"continue" or options.@"resume" or options.no_session))
    {
        try stderr.writeAll("Error: --fork cannot be combined with --session, --continue, --resume, or --no-session\n");
        return 1;
    }

    if (options.mode == .rpc and options.prompt != null) {
        try stderr.writeAll("Error: Prompt arguments are not supported in RPC mode\n");
        return 1;
    }

    if (options.mode == .rpc and options.file_args != null) {
        try stderr.writeAll("Error: @file arguments are not supported in RPC mode\n");
        return 1;
    }

    const app_mode = resolveAppMode(options.mode, options.print, detected_stdin.is_tty);
    const selected_tools = effectiveToolSelection(&options);
    const cwd = if (cwd_override) |override| blk: {
        break :blk try allocator.dupe(u8, override);
    } else blk: {
        const real_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        defer allocator.free(real_cwd);
        break :blk try allocator.dupe(u8, real_cwd);
    };
    defer allocator.free(cwd);

    var prepared = try prepareCliRuntime(allocator, io, env_map, cwd, &options, selected_tools);
    defer prepared.deinit(allocator);
    try writeResourceDiagnostics(stderr, prepared.resource_bundle.diagnostics);

    var initial_input = prepareInitialInput(
        allocator,
        io,
        env_map,
        cwd,
        options.file_args,
        prepared.expanded_prompt,
        detected_stdin.content,
        stderr,
    ) catch |err| switch (err) {
        error.CliInputFailed => return 1,
        else => return err,
    };
    defer initial_input.deinit(allocator);

    if (app_mode == .print or app_mode == .json) {
        if (initial_input.prompt == null) {
            try stderr.writeAll("Error: No prompt provided\n\n");
            try printUsage(allocator, stdout);
            return 1;
        }
    }

    var provider_runtime = coding_agent.resolveProviderConfig(
        allocator,
        env_map,
        prepared.provider_name,
        prepared.model_name,
        options.api_key,
        prepared.runtime_config.lookupApiKey(prepared.provider_name),
    ) catch |err| {
        try stderr.print("Error: {s}\n", .{coding_agent.resolveProviderErrorMessage(err, prepared.provider_name)});
        return 1;
    };
    defer provider_runtime.deinit(allocator);

    if (app_mode != .interactive) {
        coding_agent.interactive_mode.setToolRuntime(.{
            .cwd = cwd,
            .io = io,
        });
        defer coding_agent.interactive_mode.clearToolRuntime();

        var built_tools = try coding_agent.interactive_mode.buildAgentTools(allocator, selected_tools);
        defer built_tools.deinit();

        var session = try coding_agent.interactive_mode.openInitialSession(
            allocator,
            io,
            prepared.session_dir,
            .{
                .cwd = cwd,
                .system_prompt = prepared.system_prompt,
                .session_dir = prepared.session_dir,
                .provider = prepared.provider_name,
                .model = prepared.model_name,
                .api_key = options.api_key,
                .thinking = prepared.thinking_level,
                .session = options.session,
                .@"continue" = options.@"continue",
                .@"resume" = options.@"resume",
                .fork = options.fork,
                .no_session = options.no_session,
                .model_patterns = options.models,
                .selected_tools = selected_tools,
                .initial_prompt = null,
                .initial_images = &.{},
                .prompt_templates = prepared.resource_bundle.prompt_templates,
                .keybindings = &prepared.runtime_config.keybindings,
                .theme = prepared.resource_bundle.selectedTheme(),
                .runtime_config = &prepared.runtime_config,
            },
            provider_runtime.model,
            provider_runtime.api_key,
            built_tools.items,
        );
        defer session.deinit();

        if (app_mode == .rpc) {
            return try coding_agent.runRpcMode(
                allocator,
                io,
                &session,
                .{},
                stdout,
                stderr,
            );
        }

        if (initial_input.images.len > 0) {
            return try coding_agent.runPrintMode(
                allocator,
                io,
                &session,
                .{
                    .text = initial_input.prompt.?,
                    .images = initial_input.images,
                },
                .{
                    .mode = if (app_mode == .json) .json else .text,
                },
                stdout,
                stderr,
            );
        }

        return try coding_agent.runPrintMode(
            allocator,
            io,
            &session,
            initial_input.prompt.?,
            .{
                .mode = if (app_mode == .json) .json else .text,
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
            .system_prompt = prepared.system_prompt,
            .session_dir = prepared.session_dir,
            .provider = prepared.provider_name,
            .model = prepared.model_name,
            .api_key = options.api_key,
            .thinking = prepared.thinking_level,
            .session = options.session,
            .@"continue" = options.@"continue",
            .@"resume" = options.@"resume",
            .fork = options.fork,
            .no_session = options.no_session,
            .model_patterns = options.models,
            .selected_tools = selected_tools,
            .initial_prompt = initial_input.prompt,
            .initial_images = initial_input.images,
            .prompt_templates = prepared.resource_bundle.prompt_templates,
            .keybindings = &prepared.runtime_config.keybindings,
            .theme = prepared.resource_bundle.selectedTheme(),
            .runtime_config = &prepared.runtime_config,
            .offline = options.offline,
            .verbose = options.verbose,
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

fn resolveAppMode(mode: cli.Mode, print_requested: bool, stdin_is_tty: bool) AppMode {
    return switch (mode) {
        .rpc => .rpc,
        .json => .json,
        .text => if (print_requested or !stdin_is_tty) .print else .interactive,
    };
}

fn stdinIsTty(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch true;
}

fn detectCliStdin(allocator: std.mem.Allocator, io: std.Io, mode: cli.Mode) !CliStdin {
    if (mode == .rpc or stdinIsTty(io)) return .{};

    const content = try readPipedStdin(allocator, io);
    return .{
        .is_tty = false,
        .content = content,
        .owns_content = content != null,
    };
}

fn readPipedStdin(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var collected = std.ArrayList(u8).empty;
    defer collected.deinit(allocator);

    while (true) {
        const byte = stdin_reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try collected.append(allocator, byte);
    }

    const trimmed = std.mem.trim(u8, collected.items, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn prepareInitialInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    file_args: ?[]const []const u8,
    prompt: ?[]const u8,
    stdin_content: ?[]const u8,
    stderr: *std.Io.Writer,
) !PreparedInitialInput {
    var file_text = std.ArrayList(u8).empty;
    defer file_text.deinit(allocator);
    var images = std.ArrayList(ai.ImageContent).empty;
    errdefer {
        for (images.items) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        images.deinit(allocator);
    }

    if (file_args) |paths| {
        for (paths) |path| {
            const absolute_path = try config_mod.expandPath(allocator, env_map, path, cwd);
            defer allocator.free(absolute_path);

            const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, absolute_path, allocator, .unlimited) catch |err| {
                switch (err) {
                    error.FileNotFound => try stderr.print("Error: File not found: {s}\n", .{absolute_path}),
                    else => try stderr.print("Error: Could not read file {s}: {s}\n", .{ absolute_path, @errorName(err) }),
                }
                return error.CliInputFailed;
            };
            defer allocator.free(bytes);

            if (bytes.len == 0) continue;

            if (detectImageMime(bytes)) |mime_type| {
                const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
                _ = std.base64.standard.Encoder.encode(encoded, bytes);

                try images.append(allocator, .{
                    .data = encoded,
                    .mime_type = try allocator.dupe(u8, mime_type),
                });

                const note = try std.fmt.allocPrint(allocator, "<file name=\"{s}\"></file>\n", .{absolute_path});
                defer allocator.free(note);
                try file_text.appendSlice(allocator, note);
            } else {
                const header = try std.fmt.allocPrint(allocator, "<file name=\"{s}\">\n", .{absolute_path});
                defer allocator.free(header);
                try file_text.appendSlice(allocator, header);
                try file_text.appendSlice(allocator, bytes);
                try file_text.appendSlice(allocator, "\n</file>\n");
            }
        }
    }

    var prompt_builder = std.ArrayList(u8).empty;
    defer prompt_builder.deinit(allocator);
    if (stdin_content) |content| try prompt_builder.appendSlice(allocator, content);
    if (file_text.items.len > 0) try prompt_builder.appendSlice(allocator, file_text.items);
    if (prompt) |text| try prompt_builder.appendSlice(allocator, text);

    return .{
        .prompt = if (prompt_builder.items.len > 0)
            try prompt_builder.toOwnedSlice(allocator)
        else
            null,
        .images = try images.toOwnedSlice(allocator),
    };
}

fn detectImageMime(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) {
        return "image/gif";
    }
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        return "image/webp";
    }
    return null;
}

fn effectiveToolSelection(options: *const cli.Args) ?[]const []const u8 {
    if (options.no_tools) {
        return options.tools orelse &[_][]const u8{};
    }
    if (options.no_builtin_tools and options.tools == null) {
        return &[_][]const u8{};
    }
    return options.tools;
}

fn startupNetworkOperationsEnabled(options: *const cli.Args, env_map: *const std.process.Environ.Map) bool {
    return !options.offline and !isTruthyEnvFlag(env_map.get("PI_OFFLINE"));
}

fn isTruthyEnvFlag(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.ascii.eqlIgnoreCase(text, "1") or
        std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "on");
}

fn runSessionExport(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd_override: ?[]const u8,
    session_file: []const u8,
    output_path: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const cwd = if (cwd_override) |override| blk: {
        break :blk try allocator.dupe(u8, override);
    } else blk: {
        const real_cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
        defer allocator.free(real_cwd);
        break :blk try allocator.dupe(u8, real_cwd);
    };
    defer allocator.free(cwd);

    const resolved_session_file = try config_mod.expandPath(allocator, env_map, session_file, cwd);
    defer allocator.free(resolved_session_file);
    const resolved_output_path = if (output_path) |path|
        try config_mod.expandPath(allocator, env_map, path, cwd)
    else
        null;
    defer if (resolved_output_path) |path| allocator.free(path);

    const exported_path = session_advanced.exportFromFile(
        allocator,
        io,
        cwd,
        resolved_session_file,
        resolved_output_path,
    ) catch |err| {
        _ = stderr;
        return err;
    };
    defer allocator.free(exported_path);

    try stdout.print("Exported to: {s}\n", .{exported_path});
    return 0;
}

fn exportErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "File not found",
        error.UnsupportedExportPath => "Unsupported export path. Use a .html, .jsonl, .json, or .md output path",
        error.SessionExportRequiresPersistentFile => "Cannot export JSONL from an in-memory session",
        else => @errorName(err),
    };
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

fn printModelList(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    search: ?[]const u8,
    stdout: *std.Io.Writer,
) !u8 {
    var runtime_config = try config_mod.loadRuntimeConfig(allocator, io, env_map, ".");
    defer runtime_config.deinit();

    const available = try coding_agent.provider_config.listAvailableModels(allocator, env_map, null, .{
        .auth_tokens = &runtime_config.auth_tokens,
        .provider_api_keys = &runtime_config.provider_api_keys,
    });
    defer allocator.free(available);

    const configured = try coding_agent.provider_config.filterConfiguredModels(allocator, available);
    defer allocator.free(configured);

    const filtered = if (search) |pattern|
        try coding_agent.provider_config.filterAvailableModels(allocator, configured, &.{pattern})
    else
        try allocator.dupe(coding_agent.provider_config.AvailableModel, configured);
    defer allocator.free(filtered);

    if (filtered.len == 0) {
        if (search) |pattern| {
            try stdout.print("No models matching \"{s}\"\n", .{pattern});
        } else {
            try stdout.writeAll("No models available\n");
        }
        return 0;
    }

    const Row = struct {
        provider: []const u8,
        model: []const u8,
        context: []u8,
        max_out: []u8,
        thinking: []const u8,
        images: []const u8,
    };

    const rows = try allocator.alloc(Row, filtered.len);
    defer {
        for (rows) |row| {
            allocator.free(row.context);
            allocator.free(row.max_out);
        }
        allocator.free(rows);
    }

    var provider_width = "provider".len;
    var model_width = "model".len;
    var context_width = "context".len;
    var max_out_width = "max-out".len;
    var thinking_width = "thinking".len;
    var images_width = "images".len;

    for (filtered, 0..) |entry, index| {
        const context = try formatTokenCount(allocator, entry.context_window);
        errdefer allocator.free(context);
        const max_out = try formatTokenCount(allocator, entry.max_tokens);
        errdefer allocator.free(max_out);

        rows[index] = .{
            .provider = entry.provider,
            .model = entry.model_id,
            .context = context,
            .max_out = max_out,
            .thinking = if (entry.reasoning) "yes" else "no",
            .images = if (entry.supports_images) "yes" else "no",
        };

        provider_width = @max(provider_width, rows[index].provider.len);
        model_width = @max(model_width, rows[index].model.len);
        context_width = @max(context_width, rows[index].context.len);
        max_out_width = @max(max_out_width, rows[index].max_out.len);
        thinking_width = @max(thinking_width, rows[index].thinking.len);
        images_width = @max(images_width, rows[index].images.len);
    }

    try writeTableRow(
        stdout,
        "provider",
        provider_width,
        "model",
        model_width,
        "context",
        context_width,
        "max-out",
        max_out_width,
        "thinking",
        thinking_width,
        "images",
        images_width,
    );

    for (rows) |row| {
        try writeTableRow(
            stdout,
            row.provider,
            provider_width,
            row.model,
            model_width,
            row.context,
            context_width,
            row.max_out,
            max_out_width,
            row.thinking,
            thinking_width,
            row.images,
            images_width,
        );
    }

    return 0;
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

fn writeTableRow(
    stdout: *std.Io.Writer,
    provider: []const u8,
    provider_width: usize,
    model: []const u8,
    model_width: usize,
    context: []const u8,
    context_width: usize,
    max_out: []const u8,
    max_out_width: usize,
    thinking: []const u8,
    thinking_width: usize,
    images: []const u8,
    images_width: usize,
) !void {
    try writePadded(stdout, provider, provider_width);
    try stdout.writeAll("  ");
    try writePadded(stdout, model, model_width);
    try stdout.writeAll("  ");
    try writePadded(stdout, context, context_width);
    try stdout.writeAll("  ");
    try writePadded(stdout, max_out, max_out_width);
    try stdout.writeAll("  ");
    try writePadded(stdout, thinking, thinking_width);
    try stdout.writeAll("  ");
    try writePadded(stdout, images, images_width);
    try stdout.writeByte('\n');
}

fn writePadded(stdout: *std.Io.Writer, value: []const u8, width: usize) !void {
    try stdout.writeAll(value);
    if (width <= value.len) return;

    var remaining = width - value.len;
    var spaces: [32]u8 = [_]u8{' '} ** 32;
    while (remaining > 0) {
        const chunk = @min(remaining, spaces.len);
        try stdout.writeAll(spaces[0..chunk]);
        remaining -= chunk;
    }
}

fn formatTokenCount(allocator: std.mem.Allocator, count: u32) ![]u8 {
    if (count >= 1_000_000) {
        if (count % 1_000_000 == 0) {
            return std.fmt.allocPrint(allocator, "{d}M", .{count / 1_000_000});
        }

        const tenths = @divFloor((@as(u64, count) * 10) + 500_000, 1_000_000);
        if (tenths % 10 == 0) {
            return std.fmt.allocPrint(allocator, "{d}M", .{@as(u32, @intCast(tenths / 10))});
        }
        return std.fmt.allocPrint(
            allocator,
            "{d}.{d}M",
            .{
                @as(u32, @intCast(tenths / 10)),
                @as(u32, @intCast(tenths % 10)),
            },
        );
    }

    if (count >= 1_000) {
        if (count % 1_000 == 0) {
            return std.fmt.allocPrint(allocator, "{d}K", .{count / 1_000});
        }

        const tenths = @divFloor((@as(u64, count) * 10) + 500, 1_000);
        if (tenths % 10 == 0) {
            return std.fmt.allocPrint(allocator, "{d}K", .{@as(u32, @intCast(tenths / 10))});
        }
        return std.fmt.allocPrint(
            allocator,
            "{d}.{d}K",
            .{
                @as(u32, @intCast(tenths / 10)),
                @as(u32, @intCast(tenths % 10)),
            },
        );
    }

    return std.fmt.allocPrint(allocator, "{d}", .{count});
}

fn flushWriters(stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    try stdout.flush();
    try stderr.flush();
}

fn prepareCliRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    options: *const cli.Args,
    selected_tools: ?[]const []const u8,
) !PreparedCliRuntime {
    var runtime_config = try config_mod.loadRuntimeConfig(allocator, io, env_map, cwd);
    errdefer runtime_config.deinit();

    var resource_bundle = try resources_mod.loadResourceBundle(allocator, io, .{
        .cwd = cwd,
        .agent_dir = runtime_config.agent_dir,
        .global = settingsResources(runtime_config.global_settings),
        .project = settingsResources(runtime_config.project_settings),
        .cli_extensions = options.extensions orelse &.{},
        .cli_skills = options.skills orelse &.{},
        .cli_prompts = options.prompt_templates orelse &.{},
        .cli_themes = options.themes orelse &.{},
        .include_default_extensions = !options.no_extensions,
        .include_default_skills = !options.no_skills,
        .include_default_prompts = !options.no_prompt_templates,
        .include_default_themes = !options.no_themes,
    });
    errdefer resource_bundle.deinit(allocator);

    const context_files = if (options.no_context_files)
        try allocator.dupe(context_files_mod.ContextFile, &.{})
    else
        try context_files_mod.loadContextFiles(allocator, io, cwd);
    errdefer context_files_mod.deinitContextFiles(allocator, context_files);

    _ = startupNetworkOperationsEnabled(options, env_map);

    const current_date = try currentDateString(allocator, io);
    defer allocator.free(current_date);

    const initial_model = try selectInitialModel(allocator, env_map, &runtime_config, options);
    const provider_name = initial_model.provider_name;
    const model_name = initial_model.model_name;
    const thinking_level = if (options.thinking) |level|
        mapThinkingLevel(level)
    else
        runtime_config.settings.default_thinking_level orelse .off;

    const system_prompt = try coding_agent.buildSystemPrompt(allocator, .{
        .cwd = cwd,
        .current_date = current_date,
        .custom_prompt = options.system_prompt,
        .append_prompt = options.append_system_prompt,
        .selected_tools = selected_tools,
        .context_files = context_files,
        .skills = resource_bundle.skills,
    });
    errdefer allocator.free(system_prompt);

    const session_dir = if (options.session_dir) |value|
        try config_mod.expandPath(allocator, env_map, value, cwd)
    else
        try runtime_config.effectiveSessionDir(allocator, env_map, cwd);
    errdefer allocator.free(session_dir);

    const expanded_prompt = if (options.prompt) |prompt|
        try resources_mod.expandPromptTemplate(allocator, prompt, resource_bundle.prompt_templates)
    else
        null;
    errdefer if (expanded_prompt) |value| allocator.free(value);

    return .{
        .runtime_config = runtime_config,
        .resource_bundle = resource_bundle,
        .context_files = context_files,
        .system_prompt = system_prompt,
        .session_dir = session_dir,
        .expanded_prompt = expanded_prompt,
        .provider_name = provider_name,
        .model_name = model_name,
        .thinking_level = thinking_level,
    };
}

const InitialModelSelection = struct {
    provider_name: []const u8,
    model_name: ?[]const u8,
};

fn selectInitialModel(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    runtime_config: *const config_mod.RuntimeConfig,
    options: *const cli.Args,
) !InitialModelSelection {
    if (options.provider != null or runtime_config.settings.default_provider != null) {
        return .{
            .provider_name = options.provider orelse runtime_config.settings.default_provider.?,
            .model_name = options.model orelse runtime_config.settings.default_model,
        };
    }

    if (options.model != null or runtime_config.settings.default_model != null) {
        return .{
            .provider_name = "openai",
            .model_name = options.model orelse runtime_config.settings.default_model,
        };
    }

    const model = try coding_agent.provider_config.findInitialDefaultModel(allocator, env_map, .{
        .auth_tokens = &runtime_config.auth_tokens,
        .provider_api_keys = &runtime_config.provider_api_keys,
    });
    if (model) |value| {
        return .{
            .provider_name = value.provider,
            .model_name = value.id,
        };
    }

    return .{
        .provider_name = "openai",
        .model_name = null,
    };
}

fn settingsResources(settings: config_mod.Settings) resources_mod.SettingsResources {
    return .{
        .packages = settings.packages,
        .extensions = settings.extensions,
        .skills = settings.skills,
        .prompts = settings.prompts,
        .themes = settings.themes,
        .theme = settings.theme,
    };
}

fn writeResourceDiagnostics(stderr: *std.Io.Writer, diagnostics: []const resources_mod.Diagnostic) !void {
    for (diagnostics) |diagnostic| {
        if (diagnostic.path) |path| {
            try stderr.print("Warning: {s}: {s} ({s})\n", .{ diagnostic.kind, diagnostic.message, path });
        } else {
            try stderr.print("Warning: {s}: {s}\n", .{ diagnostic.kind, diagnostic.message });
        }
    }
}

fn mapThinkingLevel(level: cli.ThinkingLevel) agent.ThinkingLevel {
    return switch (level) {
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

const CliExecutableResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn deinit(self: *CliExecutableResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

fn exitCodeFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

fn hasAnsiEscape(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '\x1b') != null;
}

fn runCliExecutable(
    allocator: std.mem.Allocator,
    tmp: anytype,
    args: []const []const u8,
    env_entries: []const struct { []const u8, []const u8 },
) !CliExecutableResult {
    try tmp.dir.createDirPath(std.testing.io, "home");
    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "project");

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const agent_dir = try makeTmpPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    const binary_path = try makeAbsoluteTestPath(allocator, "zig-out/bin/pi");
    defer allocator.free(binary_path);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, binary_path);
    try argv.appendSlice(allocator, args);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    for (env_entries) |entry| {
        try env_map.put(entry[0], entry[1]);
    }

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .path = project_dir },
        .environ_map = &env_map,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exitCodeFromTerm(result.term),
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
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-builtin-tools, -nbt") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-context-files, -nc") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--export <file>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--offline") != null);
}

test "effectiveToolSelection disables built-in tools when requested" {
    const allocator = std.testing.allocator;

    var no_builtin_args = try cli.parseArgs(allocator, &.{"--no-builtin-tools"});
    defer no_builtin_args.deinit(allocator);
    const no_builtin_selection = effectiveToolSelection(&no_builtin_args).?;
    try std.testing.expectEqual(@as(usize, 0), no_builtin_selection.len);

    var explicit_args = try cli.parseArgs(allocator, &.{
        "--no-builtin-tools",
        "--tools",
        "read,ls",
    });
    defer explicit_args.deinit(allocator);
    const explicit_selection = effectiveToolSelection(&explicit_args).?;
    try std.testing.expectEqual(@as(usize, 2), explicit_selection.len);
    try std.testing.expectEqualStrings("read", explicit_selection[0]);
    try std.testing.expectEqualStrings("ls", explicit_selection[1]);

    var built_tools = try coding_agent.interactive_mode.buildAgentTools(allocator, no_builtin_selection);
    defer built_tools.deinit();
    try std.testing.expectEqual(@as(usize, 0), built_tools.items.len);
}

test "startup network operations respect CLI offline flag and environment" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var default_args = try cli.parseArgs(allocator, &.{});
    defer default_args.deinit(allocator);
    try std.testing.expect(startupNetworkOperationsEnabled(&default_args, &env_map));

    var offline_args = try cli.parseArgs(allocator, &.{"--offline"});
    defer offline_args.deinit(allocator);
    try std.testing.expect(!startupNetworkOperationsEnabled(&offline_args, &env_map));

    try env_map.put("PI_OFFLINE", "true");
    try std.testing.expect(!startupNetworkOperationsEnabled(&default_args, &env_map));
}

test "runCli lists models and applies optional search" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-key");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--list-models", "sonnet" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "claude-sonnet-4-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "gpt-5.4") == null);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
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

test "runCli auto-switches to print mode for piped stdin" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "hello from stdin");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var stdin_input = CliStdin{
        .is_tty = false,
        .content = "prompt from pipe",
    };

    const exit_code = try runCliWithInput(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux" },
        "/tmp/project",
        &stdin_input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("hello from stdin\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "runCli exports session files to html and jsonl" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeTmpPath(allocator, tmp, "cli-export");
    defer allocator.free(cwd);
    try std.Io.Dir.createDirAbsolute(std.testing.io, cwd, .default_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "export reply");

    var create_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer create_stdout.deinit();
    var create_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer create_stderr.deinit();

    const create_exit = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "export prompt" },
        cwd,
        &create_stdout.writer,
        &create_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), create_exit);

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    const html_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "exported.html" });
    defer allocator.free(html_path);
    const jsonl_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "exported.jsonl" });
    defer allocator.free(jsonl_path);

    var html_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer html_stdout.deinit();
    var html_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer html_stderr.deinit();
    const html_exit = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--export", session_file, html_path },
        cwd,
        &html_stdout.writer,
        &html_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), html_exit);
    try std.testing.expect(std.mem.indexOf(u8, html_stdout.writer.buffered(), "Exported to:") != null);
    try std.testing.expectEqualStrings("", html_stderr.writer.buffered());

    const html_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, html_path, allocator, .limited(1024 * 1024));
    defer allocator.free(html_bytes);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "export prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "export reply") != null);

    var jsonl_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer jsonl_stdout.deinit();
    var jsonl_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer jsonl_stderr.deinit();
    const jsonl_exit = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--export", session_file, jsonl_path },
        cwd,
        &jsonl_stdout.writer,
        &jsonl_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), jsonl_exit);
    try std.testing.expectEqualStrings("", jsonl_stderr.writer.buffered());

    const exported_jsonl = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, jsonl_path, allocator, .limited(1024 * 1024));
    defer allocator.free(exported_jsonl);
    try std.testing.expect(std.mem.indexOf(u8, exported_jsonl, "\"export prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported_jsonl, "\"export reply\"") != null);
}

test "runCli injects @file text into the initial prompt" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try makeTmpPath(allocator, tmp, "cli-file-text");
    defer allocator.free(cwd);
    try std.Io.Dir.createDirAbsolute(std.testing.io, cwd, .default_dir);
    const note_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "note.txt" });
    defer allocator.free(note_path);
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = note_path,
        .data = "alpha beta",
    });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "text file injected");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var stdin_input = CliStdin{};

    const exit_code = try runCliWithInput(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "@note.txt", "Question?" },
        cwd,
        &stdin_input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("text file injected\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();

    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    const user_text = context.messages[0].user.content[0].text.text;
    try std.testing.expect(std.mem.startsWith(u8, user_text, "<file name=\""));
    try std.testing.expect(std.mem.indexOf(u8, user_text, "alpha beta") != null);
    try std.testing.expect(std.mem.endsWith(u8, user_text, "</file>\nQuestion?"));
    try std.testing.expectEqualStrings("text file injected", context.messages[1].assistant.content[0].text.text);
}

test "runCli injects image file arguments into the initial prompt" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try makeTmpPath(allocator, tmp, "cli-file-image");
    defer allocator.free(cwd);
    try std.Io.Dir.createDirAbsolute(std.testing.io, cwd, .default_dir);
    const image_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "screenshot.png" });
    defer allocator.free(image_path);
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = image_path,
        .data = "\x89PNG\r\n\x1a\nfakepng",
    });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "image file injected");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var stdin_input = CliStdin{};

    const exit_code = try runCliWithInput(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "@screenshot.png", "Describe it" },
        cwd,
        &stdin_input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("image file injected\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();

    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqual(@as(usize, 2), context.messages[0].user.content.len);
    const user_text = context.messages[0].user.content[0].text.text;
    try std.testing.expect(std.mem.startsWith(u8, user_text, "<file name=\""));
    try std.testing.expect(std.mem.endsWith(u8, user_text, "\"></file>\nDescribe it"));
    try std.testing.expectEqualStrings("image/png", context.messages[0].user.content[1].image.mime_type);
    try std.testing.expect(context.messages[0].user.content[1].image.data.len > 0);
    try std.testing.expectEqualStrings("image file injected", context.messages[1].assistant.content[0].text.text);
}

test "cli executable print mode writes assistant text to stdout without interactive escape codes" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--print", "hello" },
        &.{.{ "PI_FAUX_RESPONSE", "hello from cli binary" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("hello from cli binary\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(!hasAnsiEscape(result.stdout));
    try std.testing.expect(!hasAnsiEscape(result.stderr));
}

test "cli executable print mode json writes valid JSON lines to stdout" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--mode", "json", "--print", "hello" },
        &.{.{ "PI_FAUX_RESPONSE", "json from cli binary" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(!hasAnsiEscape(result.stdout));

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var line_count: usize = 0;
    var saw_agent_start = false;
    var saw_agent_end = false;
    var saw_response_text = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        const event_type = parsed.value.object.get("event_type").?.string;
        if (std.mem.eql(u8, event_type, "agent_start")) saw_agent_start = true;
        if (std.mem.eql(u8, event_type, "agent_end")) saw_agent_end = true;
        if (parsed.value.object.get("text")) |text_value| {
            if (text_value == .string and std.mem.eql(u8, text_value.string, "json from cli binary")) {
                saw_response_text = true;
            }
        }
    }

    try std.testing.expect(line_count >= 3);
    try std.testing.expect(saw_agent_start);
    try std.testing.expect(saw_agent_end);
    try std.testing.expect(saw_response_text);
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

test "runCli resume loads the latest session" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeTmpPath(allocator, tmp, "cli-resume");
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
    try second_env.put("PI_FAUX_RESPONSE", "resumed reply");

    var second_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer second_stdout.deinit();
    var second_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer second_stderr.deinit();

    const second_exit = try runCli(
        allocator,
        std.testing.io,
        &second_env,
        &.{ "--provider", "faux", "--print", "--resume", "second prompt" },
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
    try std.testing.expectEqualStrings("resumed reply", context.messages[3].assistant.content[0].text.text);
}

test "runCli no-session keeps runs ephemeral" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeTmpPath(allocator, tmp, "cli-no-session");
    defer allocator.free(cwd);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "ephemeral reply");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "--no-session", "hello" },
        cwd,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("ephemeral reply\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir);
    defer if (session_file) |path| allocator.free(path);
    try std.testing.expect(session_file == null);
}

test "runCli stores sessions in overridden session directory" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeTmpPath(allocator, tmp, "cli-session-dir");
    defer allocator.free(cwd);
    const overridden_session_dir = try makeTmpPath(allocator, tmp, "custom-sessions");
    defer allocator.free(overridden_session_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "stored in custom session dir");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--session-dir", overridden_session_dir, "--print", "hello" },
        cwd,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("stored in custom session dir\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, overridden_session_dir)).?;
    defer allocator.free(session_file);
    try std.testing.expect(std.mem.startsWith(u8, session_file, overridden_session_dir));
}

test "runCli fork creates a new session from an existing session id" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeTmpPath(allocator, tmp, "cli-fork");
    defer allocator.free(cwd);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);

    var first_env = std.process.Environ.Map.init(allocator);
    defer first_env.deinit();
    try first_env.put("PI_FAUX_RESPONSE", "seed reply");

    var first_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer first_stdout.deinit();
    var first_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer first_stderr.deinit();

    const first_exit = try runCli(
        allocator,
        std.testing.io,
        &first_env,
        &.{ "--provider", "faux", "--print", "seed prompt" },
        cwd,
        &first_stdout.writer,
        &first_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), first_exit);

    const original_session_path = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(original_session_path);

    const source_path = try allocator.dupe(u8, original_session_path);
    defer allocator.free(source_path);

    var source_manager = try coding_agent.SessionManager.open(allocator, std.testing.io, source_path, cwd);
    defer source_manager.deinit();
    const source_session_id = try allocator.dupe(u8, source_manager.getSessionId());
    defer allocator.free(source_session_id);

    var second_env = std.process.Environ.Map.init(allocator);
    defer second_env.deinit();
    try second_env.put("PI_FAUX_RESPONSE", "fork reply");

    var second_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer second_stdout.deinit();
    var second_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer second_stderr.deinit();

    const second_exit = try runCli(
        allocator,
        std.testing.io,
        &second_env,
        &.{ "--provider", "faux", "--print", "--fork", source_session_id, "fork prompt" },
        cwd,
        &second_stdout.writer,
        &second_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), second_exit);

    const forked_session_path = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(forked_session_path);
    try std.testing.expect(!std.mem.eql(u8, source_path, forked_session_path));

    var original_manager = try coding_agent.SessionManager.open(allocator, std.testing.io, source_path, cwd);
    defer original_manager.deinit();
    var original_context = try original_manager.buildSessionContext(allocator);
    defer original_context.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), original_context.messages.len);
    try std.testing.expectEqualStrings("seed prompt", original_context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("seed reply", original_context.messages[1].assistant.content[0].text.text);

    var forked_manager = try coding_agent.SessionManager.open(allocator, std.testing.io, forked_session_path, cwd);
    defer forked_manager.deinit();
    var forked_context = try forked_manager.buildSessionContext(allocator);
    defer forked_context.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), forked_context.messages.len);
    try std.testing.expectEqualStrings("seed prompt", forked_context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("seed reply", forked_context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("fork prompt", forked_context.messages[2].user.content[0].text.text);
    try std.testing.expectEqualStrings("fork reply", forked_context.messages[3].assistant.content[0].text.text);
}

test "runCli rejects conflicting fork flags" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--fork", "session-123", "--resume", "--print", "hello" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "--fork cannot be combined") != null);
}

test "cli executable continue resumes the latest session while preserving older sessions" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ project_dir, ".pi", "sessions" });
    defer allocator.free(session_dir);

    var first = try runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--print", "first prompt" },
        &.{.{ "PI_FAUX_RESPONSE", "first reply" }},
    );
    defer first.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), first.exit_code);
    try std.testing.expectEqualStrings("first reply\n", first.stdout);
    try std.testing.expectEqualStrings("", first.stderr);

    const original_session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(original_session_file);

    const original_session_before_continue = try std.testing.allocator.dupe(u8, original_session_file);
    defer std.testing.allocator.free(original_session_before_continue);

    const original_bytes_before_continue = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, original_session_before_continue, allocator, .unlimited);
    defer allocator.free(original_bytes_before_continue);
    var original_line_count_before_continue: usize = 0;
    for (original_bytes_before_continue) |byte| {
        if (byte == '\n') original_line_count_before_continue += 1;
    }

    var second = try runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--print", "--continue", "second prompt" },
        &.{.{ "PI_FAUX_RESPONSE", "second reply" }},
    );
    defer second.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), second.exit_code);
    try std.testing.expectEqualStrings("second reply\n", second.stdout);
    try std.testing.expectEqualStrings("", second.stderr);

    const original_session_after_continue = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(original_session_after_continue);
    try std.testing.expectEqualStrings(original_session_before_continue, original_session_after_continue);

    const original_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, original_session_after_continue, allocator, .unlimited);
    defer allocator.free(original_bytes);
    var original_line_count: usize = 0;
    for (original_bytes) |byte| {
        if (byte == '\n') original_line_count += 1;
    }
    try std.testing.expectEqual(original_line_count_before_continue + 2, original_line_count);

    var original_manager = try coding_agent.SessionManager.open(allocator, std.testing.io, original_session_after_continue, project_dir);
    defer original_manager.deinit();

    var original_context = try original_manager.buildSessionContext(allocator);
    defer original_context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), original_context.messages.len);
    try std.testing.expectEqualStrings("first prompt", original_context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("first reply", original_context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("second prompt", original_context.messages[2].user.content[0].text.text);
    try std.testing.expectEqualStrings("second reply", original_context.messages[3].assistant.content[0].text.text);

    var third = try runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--print", "third prompt" },
        &.{.{ "PI_FAUX_RESPONSE", "third reply" }},
    );
    defer third.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), third.exit_code);
    try std.testing.expectEqualStrings("third reply\n", third.stdout);
    try std.testing.expectEqualStrings("", third.stderr);

    const latest_session_before_continue = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(latest_session_before_continue);
    try std.testing.expect(!std.mem.eql(u8, original_session_before_continue, latest_session_before_continue));

    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, session_dir, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var iterator = dir.iterate();
    var session_file_count: usize = 0;
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        session_file_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), session_file_count);

    const latest_session_path = try std.testing.allocator.dupe(u8, latest_session_before_continue);
    defer std.testing.allocator.free(latest_session_path);

    var fourth = try runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--print", "--continue", "fourth prompt" },
        &.{.{ "PI_FAUX_RESPONSE", "fourth reply" }},
    );
    defer fourth.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), fourth.exit_code);
    try std.testing.expectEqualStrings("fourth reply\n", fourth.stdout);
    try std.testing.expectEqualStrings("", fourth.stderr);

    const latest_session_after_continue = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(latest_session_after_continue);
    try std.testing.expectEqualStrings(latest_session_path, latest_session_after_continue);

    var latest_manager = try coding_agent.SessionManager.open(allocator, std.testing.io, latest_session_after_continue, project_dir);
    defer latest_manager.deinit();

    var latest_context = try latest_manager.buildSessionContext(allocator);
    defer latest_context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), latest_context.messages.len);
    try std.testing.expectEqualStrings("third prompt", latest_context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("third reply", latest_context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("fourth prompt", latest_context.messages[2].user.content[0].text.text);
    try std.testing.expectEqualStrings("fourth reply", latest_context.messages[3].assistant.content[0].text.text);
}

test "runCli preserves context when continuing with a different provider" {
    const allocator = std.testing.allocator;
    const faux = ai.providers.faux;

    ai.api_registry.resetToBuiltIns();
    defer ai.api_registry.resetToBuiltIns();

    const openai_registration = try faux.registerFauxProvider(allocator, .{
        .api = "openai-completions",
        .provider = "openai",
        .models = &[_]faux.FauxModelDefinition{.{
            .id = "gpt-5.4",
            .name = "GPT-5.4",
            .reasoning = true,
        }},
    });
    defer openai_registration.unregister();

    const openai_blocks = [_]faux.FauxContentBlock{
        faux.fauxText("I will remember marigold."),
    };
    try openai_registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .message = faux.fauxAssistantMessage(openai_blocks[0..], .{}) },
    });

    const anthropic_registration = try faux.registerFauxProvider(allocator, .{
        .api = "anthropic-messages",
        .provider = "anthropic",
        .models = &[_]faux.FauxModelDefinition{.{
            .id = "claude-opus-4-7",
            .name = "Claude Opus 4.7",
            .reasoning = true,
        }},
    });
    defer anthropic_registration.unregister();
    try anthropic_registration.setResponses(&[_]faux.FauxResponseStep{
        .{ .factory = struct {
            fn respond(
                factory_allocator: std.mem.Allocator,
                context: ai.Context,
                _: ?ai.types.StreamOptions,
                call_count: *usize,
                model: ai.Model,
            ) !faux.FauxAssistantMessage {
                try std.testing.expectEqual(@as(usize, 1), call_count.*);
                try std.testing.expectEqualStrings("anthropic", model.provider);
                try std.testing.expectEqualStrings("claude-opus-4-7", model.id);
                try std.testing.expectEqual(@as(usize, 3), context.messages.len);
                try std.testing.expectEqualStrings("Remember this token: marigold", context.messages[0].user.content[0].text.text);
                try std.testing.expectEqualStrings("I will remember marigold.", context.messages[1].assistant.content[0].text.text);
                try std.testing.expectEqualStrings("openai", context.messages[1].assistant.provider);
                try std.testing.expectEqualStrings("What token did I ask you to remember?", context.messages[2].user.content[0].text.text);

                const blocks = try factory_allocator.alloc(faux.FauxContentBlock, 1);
                blocks[0] = faux.fauxText("You asked me to remember marigold.");
                return faux.fauxAssistantMessage(blocks, .{});
            }
        }.respond },
    });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeTmpPath(allocator, tmp, "cli-multi-provider");
    defer allocator.free(cwd);

    var first_env = std.process.Environ.Map.init(allocator);
    defer first_env.deinit();
    try first_env.put("OPENAI_API_KEY", "test-openai-key");

    var first_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer first_stdout.deinit();
    var first_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer first_stderr.deinit();

    const first_exit = try runCli(
        allocator,
        std.testing.io,
        &first_env,
        &.{ "--provider", "openai", "--print", "Remember this token: marigold" },
        cwd,
        &first_stdout.writer,
        &first_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), first_exit);
    try std.testing.expectEqualStrings("I will remember marigold.\n", first_stdout.written());
    try std.testing.expectEqualStrings("", first_stderr.written());

    var second_env = std.process.Environ.Map.init(allocator);
    defer second_env.deinit();
    try second_env.put("ANTHROPIC_API_KEY", "test-anthropic-key");

    var second_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer second_stdout.deinit();
    var second_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer second_stderr.deinit();

    const second_exit = try runCli(
        allocator,
        std.testing.io,
        &second_env,
        &.{ "--provider", "anthropic", "--print", "--continue", "What token did I ask you to remember?" },
        cwd,
        &second_stdout.writer,
        &second_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), second_exit);
    try std.testing.expectEqualStrings("You asked me to remember marigold.\n", second_stdout.written());
    try std.testing.expectEqualStrings("", second_stderr.written());

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();

    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), context.messages.len);
    try std.testing.expectEqualStrings("Remember this token: marigold", context.messages[0].user.content[0].text.text);
    try std.testing.expectEqualStrings("I will remember marigold.", context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("openai", context.messages[1].assistant.provider);
    try std.testing.expectEqualStrings("What token did I ask you to remember?", context.messages[2].user.content[0].text.text);
    try std.testing.expectEqualStrings("You asked me to remember marigold.", context.messages[3].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("anthropic", context.messages[3].assistant.provider);
    try std.testing.expectEqualStrings("anthropic", context.model.?.provider);
    try std.testing.expectEqualStrings("claude-opus-4-7", context.model.?.model_id);
}

test "prepareCliRuntime loads defaults resources context and prompt templates" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/skills/reviewer");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/prompts");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/themes");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1",
        \\  "defaultThinkingLevel": "minimal",
        \\  "sessionDir": "~/sessions"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/settings.json",
        .data =
        \\{
        \\  "theme": "night"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/AGENTS.md",
        .data = "Project instructions from AGENTS.md",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/skills/reviewer/SKILL.md",
        .data =
        \\---
        \\description: Review code changes
        \\---
        \\Use the review checklist.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/prompts/fix.md",
        .data = "Fix $ARGUMENTS please.",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/themes/night.json",
        .data =
        \\{
        \\  "name": "night",
        \\  "tokens": {
        \\    "assistant": { "fg": "cyan" }
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{
        "--tools",
        "read,ls",
        "/fix parser bug",
    });
    defer args.deinit(allocator);

    const selected_tools = effectiveToolSelection(&args);
    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, selected_tools);
    defer prepared.deinit(allocator);

    try std.testing.expectEqualStrings("faux", prepared.provider_name);
    try std.testing.expectEqualStrings("faux-1", prepared.model_name.?);
    try std.testing.expectEqual(agent.ThinkingLevel.minimal, prepared.thinking_level);
    try std.testing.expectEqualStrings("night", prepared.resource_bundle.selectedTheme().name);
    try std.testing.expectEqualStrings("Fix parser bug please.", prepared.expanded_prompt.?);
    try std.testing.expect(prepared.context_files.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "Project instructions from AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "<available_skills>") != null);

    const expected_session_dir = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, "sessions" });
    defer allocator.free(expected_session_dir);
    try std.testing.expectEqualStrings(expected_session_dir, prepared.session_dir);
}

test "prepareCliRuntime wires CLI resource overrides and discovery toggles" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/extensions");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/skills/default-reviewer");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/prompts");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/themes");
    try tmp.dir.createDirPath(std.testing.io, "repo/cli-skills/reviewer");
    try tmp.dir.createDirPath(std.testing.io, "repo/cli-prompts");

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1",
        \\  "sessionDir": "~/sessions"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/settings.json",
        .data =
        \\{
        \\  "theme": "night"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/extensions/default-extension.ts",
        .data = "export default {};",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/skills/default-reviewer/SKILL.md",
        .data =
        \\---
        \\description: Default review skill
        \\---
        \\Use the default review checklist.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/prompts/fix.md",
        .data = "Default fix $ARGUMENTS.",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/themes/night.json",
        .data =
        \\{
        \\  "name": "night",
        \\  "tokens": {
        \\    "assistant": { "fg": "cyan" }
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/cli-extension.ts",
        .data = "export default {};",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/cli-skills/reviewer/SKILL.md",
        .data =
        \\---
        \\description: CLI review skill
        \\---
        \\Use the CLI review checklist.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/cli-prompts/fix.md",
        .data = "CLI fix $ARGUMENTS.",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/cli-night.json",
        .data =
        \\{
        \\  "name": "night",
        \\  "tokens": {
        \\    "assistant": { "fg": "magenta" }
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{
        "--no-extensions",
        "--extension",
        "cli-extension.ts",
        "--no-skills",
        "--skill",
        "cli-skills",
        "--no-prompt-templates",
        "--prompt-template",
        "cli-prompts",
        "--no-themes",
        "--theme",
        "cli-night.json",
        "/fix parser bug",
    });
    defer args.deinit(allocator);

    const selected_tools = effectiveToolSelection(&args);
    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, selected_tools);
    defer prepared.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), prepared.resource_bundle.extensions.len);
    try std.testing.expect(std.mem.indexOf(u8, prepared.resource_bundle.extensions[0].path, "cli-extension.ts") != null);
    try std.testing.expectEqual(@as(usize, 1), prepared.resource_bundle.skills.len);
    try std.testing.expectEqualStrings("reviewer", prepared.resource_bundle.skills[0].name);
    try std.testing.expectEqual(@as(usize, 1), prepared.resource_bundle.prompt_templates.len);
    try std.testing.expectEqualStrings("fix", prepared.resource_bundle.prompt_templates[0].name);
    try std.testing.expectEqualStrings("CLI fix parser bug.", prepared.expanded_prompt.?);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "CLI review skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "Default review skill") == null);
    try std.testing.expectEqualStrings("night", prepared.resource_bundle.selectedTheme().name);

    const styled = try prepared.resource_bundle.selectedTheme().applyAlloc(allocator, .assistant, "Pi:");
    defer allocator.free(styled);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[35m") != null);
}

test "prepareCliRuntime skips context file discovery when requested" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/AGENTS.md",
        .data = "Project instructions from AGENTS.md",
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{
        "--no-context-files",
        "--verbose",
        "hello",
    });
    defer args.deinit(allocator);

    try std.testing.expect(args.verbose);

    const selected_tools = effectiveToolSelection(&args);
    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, selected_tools);
    defer prepared.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), prepared.context_files.len);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "Project instructions from AGENTS.md") == null);
}

test "prepareCliRuntime selects default model from configured api key" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/auth.json",
        .data =
        \\{
        \\  "kimi": { "type": "api_key", "key": "stored-kimi-key" }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, null);
    defer prepared.deinit(allocator);

    try std.testing.expectEqualStrings("kimi", prepared.provider_name);
    try std.testing.expectEqualStrings("kimi-k2.6", prepared.model_name.?);
}

test "prepareCliRuntime selects kimi-coding from KIMI_API_KEY" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("KIMI_API_KEY", "kimi-key");

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, null);
    defer prepared.deinit(allocator);

    try std.testing.expectEqualStrings("kimi-coding", prepared.provider_name);
    try std.testing.expectEqualStrings("kimi-for-coding", prepared.model_name.?);
}
