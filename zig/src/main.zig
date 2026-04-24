const std = @import("std");
const agent = @import("agent");
const cli = @import("cli/args.zig");
const config_mod = @import("coding_agent/config.zig");
const context_files_mod = @import("coding_agent/context_files.zig");
const resources_mod = @import("coding_agent/resources.zig");
const coding_agent = @import("coding_agent/root.zig");

const VERSION = "0.1.0";

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

    const exit_code = try runCli(init.gpa, init.io, init.environ_map, argv.items, null, stdout, stderr);
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

    if (options.mode == .rpc and options.prompt != null) {
        try stderr.writeAll("Error: Prompt arguments are not supported in RPC mode\n");
        return 1;
    }

    if (options.print and options.prompt == null) {
        try stderr.writeAll("Error: No prompt provided\n\n");
        try printUsage(allocator, stdout);
        return 1;
    }

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

    if (options.print or options.mode == .rpc) {
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
                .selected_tools = selected_tools,
                .initial_prompt = null,
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

        if (options.mode == .rpc) {
            return try coding_agent.runRpcMode(
                allocator,
                io,
                &session,
                .{},
                stdout,
                stderr,
            );
        }

        return try coding_agent.runPrintMode(
            allocator,
            io,
            &session,
            prepared.expanded_prompt.?,
            .{
                .mode = switch (options.mode) {
                    .json => .json,
                    else => .text,
                },
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
            .selected_tools = selected_tools,
            .initial_prompt = prepared.expanded_prompt,
            .prompt_templates = prepared.resource_bundle.prompt_templates,
            .keybindings = &prepared.runtime_config.keybindings,
            .theme = prepared.resource_bundle.selectedTheme(),
            .runtime_config = &prepared.runtime_config,
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
    });
    errdefer resource_bundle.deinit(allocator);

    const context_files = try context_files_mod.loadContextFiles(allocator, io, cwd);
    errdefer context_files_mod.deinitContextFiles(allocator, context_files);

    const current_date = try currentDateString(allocator, io);
    defer allocator.free(current_date);

    const provider_name = options.provider orelse runtime_config.settings.default_provider orelse "openai";
    const model_name = options.model orelse runtime_config.settings.default_model;
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

    const session_dir = try runtime_config.effectiveSessionDir(allocator, env_map, cwd);
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
