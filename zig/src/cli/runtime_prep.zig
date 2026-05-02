const std = @import("std");
const agent = @import("agent");
const cli = @import("args.zig");
const bootstrap = @import("bootstrap.zig");
const config_mod = @import("../coding_agent/config.zig");
const context_files_mod = @import("../coding_agent/context_files.zig");
const resources_mod = @import("../coding_agent/resources.zig");
const coding_agent = @import("../coding_agent/root.zig");

pub const PreparedCliRuntime = struct {
    runtime_config: config_mod.RuntimeConfig,
    resource_bundle: resources_mod.ResourceBundle,
    context_files: []context_files_mod.ContextFile,
    system_prompt: []u8,
    session_dir: []u8,
    expanded_prompt: ?[]u8,
    provider_name: []const u8,
    model_name: ?[]const u8,
    thinking_level: agent.ThinkingLevel,

    pub fn deinit(self: *PreparedCliRuntime, allocator: std.mem.Allocator) void {
        if (self.expanded_prompt) |prompt| allocator.free(prompt);
        allocator.free(self.session_dir);
        allocator.free(self.system_prompt);
        context_files_mod.deinitContextFiles(allocator, self.context_files);
        self.resource_bundle.deinit(allocator);
        self.runtime_config.deinit();
        self.* = undefined;
    }
};

pub fn prepareCliRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    options: *const cli.Args,
    selected_tools: ?[]const []const u8,
) !PreparedCliRuntime {
    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(
        allocator,
        io,
        env_map,
        cwd,
        runtimeConfigLoadOptions(options, env_map),
    );
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
        .env_map = env_map,
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

pub fn runtimeConfigLoadOptions(
    options: *const cli.Args,
    env_map: *const std.process.Environ.Map,
) config_mod.RuntimeConfigLoadOptions {
    return .{
        .discover_models = bootstrap.startupNetworkOperationsEnabled(options, env_map),
    };
}

/// Resolves the effective session directory using the same precedence as
/// `prepareCliRuntime`, but without loading provider auth, model registries,
/// resource bundles, context files, or the system prompt. Used by the M10
/// missing-cwd preflight so the diagnostic always wins over downstream
/// runtime/provider/tool failures.
///
/// Precedence (matches TypeScript `main.ts`):
///   1. `--session-dir` CLI override
///   2. `$PI_CODING_AGENT_SESSION_DIR` env var (TS `ENV_SESSION_DIR`)
///   3. `settings.json` `sessionDir` from merged global/project settings
///   4. Default `<cwd>/.pi/sessions`
///
/// Settings load failures fall through to the default; the preflight is
/// best-effort and never blocks the heavier `prepareCliRuntime` failure
/// path.
pub fn resolvePreflightSessionDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    options: *const cli.Args,
) ![]u8 {
    if (options.session_dir) |value| {
        return try config_mod.expandPath(allocator, env_map, value, cwd);
    }
    if (env_map.get("PI_CODING_AGENT_SESSION_DIR")) |value| {
        if (value.len > 0) {
            return try config_mod.expandPath(allocator, env_map, value, cwd);
        }
    }
    if (config_mod.loadMergedSettingsForPreflight(allocator, io, env_map, cwd)) |maybe_settings| {
        var settings_value = maybe_settings;
        defer settings_value.deinit(allocator);
        if (settings_value.session_dir) |value| {
            return try config_mod.expandPath(allocator, env_map, value, cwd);
        }
    } else |_| {
        // Settings parse failure: fall through to the default. The heavier
        // prepareCliRuntime path will surface the same diagnostic later when
        // the user actually proceeds past the missing-cwd preflight.
    }
    return try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
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

test "runtimeConfigLoadOptions disables model discovery for offline CLI flag" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var args = try cli.parseArgs(allocator, &.{"--offline"});
    defer args.deinit(allocator);

    const options = runtimeConfigLoadOptions(&args, &env_map);
    try std.testing.expect(!options.discover_models);
}

test "runtimeConfigLoadOptions disables model discovery for PI_OFFLINE" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_OFFLINE", "true");

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    const options = runtimeConfigLoadOptions(&args, &env_map);
    try std.testing.expect(!options.discover_models);
}

test "runtimeConfigLoadOptions keeps model discovery enabled by default" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    const options = runtimeConfigLoadOptions(&args, &env_map);
    try std.testing.expect(options.discover_models);
}
