const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const provider_config = @import("../provider_config.zig");
const session_manager_mod = @import("../session_manager.zig");
const session_mod = @import("../session.zig");
const shared = @import("shared.zig");
const slash_commands = @import("slash_commands.zig");
const tool_adapters = @import("tool_adapters.zig");

const AppContext = shared.AppContext;
const RunInteractiveModeOptions = shared.RunInteractiveModeOptions;
const configuredApiKeyForProvider = shared.configuredApiKeyForProvider;
const configuredCompactionSettings = shared.configuredCompactionSettings;
const configuredRetrySettings = shared.configuredRetrySettings;
const createSeededSession = slash_commands.createSeededSession;
const resolveSessionPath = slash_commands.resolveSessionPath;

pub const InteractiveBootstrap = struct {
    allocator: std.mem.Allocator,
    current_provider: provider_config.ResolvedProviderConfig,
    built_tools: tool_adapters.BuiltTools,
    session: session_mod.AgentSession,

    pub fn deinit(self: *InteractiveBootstrap) void {
        self.session.deinit();
        self.built_tools.deinit();
        self.current_provider.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn bootstrapInteractiveState(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    options: RunInteractiveModeOptions,
    app_context: *AppContext,
) !InteractiveBootstrap {
    var current_provider = try provider_config.resolveProviderConfig(
        allocator,
        env_map,
        options.provider,
        options.model,
        options.api_key,
        configuredApiKeyForProvider(options.runtime_config, options.provider),
    );
    errdefer current_provider.deinit(allocator);

    var built_tools = try tool_adapters.buildAgentTools(allocator, app_context, options.selected_tools);
    errdefer built_tools.deinit();

    var session = try openInitialSession(
        allocator,
        io,
        options.session_dir,
        options,
        current_provider.model,
        current_provider.api_key,
        built_tools.items,
    );
    errdefer session.deinit();

    return .{
        .allocator = allocator,
        .current_provider = current_provider,
        .built_tools = built_tools,
        .session = session,
    };
}

pub fn openInitialSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    options: RunInteractiveModeOptions,
    model: ai.Model,
    api_key: ?[]const u8,
    tool_items: []const agent.AgentTool,
) !session_mod.AgentSession {
    const thinking_level = options.thinking;
    const compaction_settings = configuredCompactionSettings(options.runtime_config);
    const retry_settings = configuredRetrySettings(options.runtime_config);
    if (options.no_session) {
        return try session_mod.AgentSession.create(allocator, io, .{
            .cwd = options.cwd,
            .system_prompt = options.system_prompt,
            .model = model,
            .api_key = api_key,
            .thinking_level = thinking_level,
            .tools = tool_items,
            .compaction = compaction_settings,
            .retry = retry_settings,
        });
    }

    if (options.fork) |session_ref| {
        const session_path = try resolveSessionPath(allocator, io, session_dir, options.cwd, session_ref);
        defer allocator.free(session_path);

        var source_session = try openSessionAtPath(allocator, io, session_path, options, model, api_key, tool_items);
        defer source_session.deinit();

        return try createSeededSession(
            allocator,
            io,
            options.cwd,
            options.system_prompt,
            model,
            api_key,
            thinking_level,
            tool_items,
            compaction_settings,
            retry_settings,
            session_dir,
            source_session.agent.getMessages(),
        );
    }

    if (options.session) |session_ref| {
        const session_path = try resolveSessionPath(allocator, io, session_dir, options.cwd, session_ref);
        defer allocator.free(session_path);
        return try openSessionAtPath(allocator, io, session_path, options, model, api_key, tool_items);
    }

    if (options.@"continue" or options.@"resume") {
        if (try session_manager_mod.findMostRecentSession(allocator, io, session_dir)) |recent| {
            defer allocator.free(recent);
            return try openSessionAtPath(allocator, io, recent, options, model, api_key, tool_items);
        }
    }

    return try createSeededSession(
        allocator,
        io,
        options.cwd,
        options.system_prompt,
        model,
        api_key,
        thinking_level,
        tool_items,
        compaction_settings,
        retry_settings,
        session_dir,
        &.{},
    );
}

fn openSessionAtPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_path: []const u8,
    options: RunInteractiveModeOptions,
    model: ai.Model,
    api_key: ?[]const u8,
    tool_items: []const agent.AgentTool,
) !session_mod.AgentSession {
    return session_mod.AgentSession.open(allocator, io, .{
        .session_file = session_path,
        .cwd_override = options.cwd,
        .system_prompt = options.system_prompt,
        .model = model,
        .api_key = api_key,
        .thinking_level = options.thinking,
        .tools = tool_items,
        .compaction = configuredCompactionSettings(options.runtime_config),
        .retry = configuredRetrySettings(options.runtime_config),
    });
}

test "bootstrapInteractiveState resolves provider builds tools and opens a session" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/sessions");

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const root_dir = try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "workspace" });
    defer allocator.free(root_dir);
    const session_dir = try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "workspace", "sessions" });
    defer allocator.free(session_dir);

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
    };

    var app_context = AppContext.init(root_dir, std.testing.io);
    var bootstrap = try bootstrapInteractiveState(allocator, std.testing.io, &env_map, options, &app_context);
    defer bootstrap.deinit();

    try std.testing.expect(bootstrap.built_tools.items.len > 0);
    try std.testing.expectEqualStrings("faux", bootstrap.current_provider.model.provider);
    try std.testing.expect(bootstrap.session.session_manager.getSessionFile() != null);
}

test "openInitialSession honors no_session without creating a session file" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/sessions");

    const root_dir = try makeSessionBootstrapTestPath(allocator, tmp, "workspace");
    defer allocator.free(root_dir);
    const session_dir = try makeSessionBootstrapTestPath(allocator, tmp, "workspace/sessions");
    defer allocator.free(session_dir);

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
        .no_session = true,
    };

    var session = try openInitialSession(
        allocator,
        std.testing.io,
        session_dir,
        options,
        current_provider.model,
        current_provider.api_key,
        &.{},
    );
    defer session.deinit();

    try std.testing.expect(session.session_manager.getSessionFile() == null);
}

test "openInitialSession resumes the most recent session when continue is enabled" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "workspace/sessions");

    const root_dir = try makeSessionBootstrapTestPath(allocator, tmp, "workspace");
    defer allocator.free(root_dir);
    const session_dir = try makeSessionBootstrapTestPath(allocator, tmp, "workspace/sessions");
    defer allocator.free(session_dir);

    var current_provider = try provider_config.resolveProviderConfig(allocator, &env_map, "faux", null, null, null);
    defer current_provider.deinit(allocator);

    var source_session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = root_dir,
        .system_prompt = "sys",
        .model = current_provider.model,
        .api_key = current_provider.api_key,
        .session_dir = session_dir,
    });
    defer source_session.deinit();
    const source_session_file = try allocator.dupe(u8, source_session.session_manager.getSessionFile().?);
    defer allocator.free(source_session_file);

    const options = RunInteractiveModeOptions{
        .cwd = root_dir,
        .system_prompt = "sys",
        .session_dir = session_dir,
        .provider = "faux",
        .@"continue" = true,
    };

    var resumed = try openInitialSession(
        allocator,
        std.testing.io,
        session_dir,
        options,
        current_provider.model,
        current_provider.api_key,
        &.{},
    );
    defer resumed.deinit();

    try std.testing.expectEqualStrings(source_session_file, resumed.session_manager.getSessionFile().?);
}

fn makeSessionBootstrapTestPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, ".zig-cache", "tmp", &tmp.sub_path, name });
}
