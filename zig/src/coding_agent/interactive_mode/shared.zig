const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const config_mod = @import("../config.zig");
const keybindings_mod = @import("../keybindings.zig");
const provider_config = @import("../provider_config.zig");
const resources_mod = @import("../resources.zig");
const session_mod = @import("../session.zig");

pub const RunInteractiveModeOptions = struct {
    cwd: []const u8,
    system_prompt: []const u8,
    session_dir: []const u8,
    provider: []const u8,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    thinking: agent.ThinkingLevel = .off,
    session: ?[]const u8 = null,
    @"continue": bool = false,
    @"resume": bool = false,
    fork: ?[]const u8 = null,
    no_session: bool = false,
    model_patterns: ?[]const []const u8 = null,
    selected_tools: ?[]const []const u8 = null,
    initial_prompt: ?[]const u8 = null,
    initial_images: []const ai.ImageContent = &.{},
    prompt_templates: []const resources_mod.PromptTemplate = &.{},
    keybindings: ?*const keybindings_mod.Keybindings = null,
    theme: ?*const resources_mod.Theme = null,
    runtime_config: ?*const config_mod.RuntimeConfig = null,
    offline: bool = false,
    verbose: bool = false,
};

pub const LiveResources = struct {
    runtime_config: ?*const config_mod.RuntimeConfig,
    keybindings: ?*const keybindings_mod.Keybindings,
    prompt_templates: []const resources_mod.PromptTemplate,
    theme: ?*const resources_mod.Theme,
    owned_runtime_config: ?config_mod.RuntimeConfig = null,
    owned_resource_bundle: ?resources_mod.ResourceBundle = null,

    pub fn init(options: RunInteractiveModeOptions) LiveResources {
        return .{
            .runtime_config = options.runtime_config,
            .keybindings = options.keybindings,
            .prompt_templates = options.prompt_templates,
            .theme = options.theme,
        };
    }

    pub fn deinit(self: *LiveResources, allocator: std.mem.Allocator) void {
        if (self.owned_resource_bundle) |*bundle| {
            bundle.deinit(allocator);
            self.owned_resource_bundle = null;
        }
        if (self.owned_runtime_config) |*runtime_config| {
            runtime_config.deinit();
            self.owned_runtime_config = null;
        }
    }

    pub fn reload(
        self: *LiveResources,
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        cwd: []const u8,
    ) ![]const resources_mod.Diagnostic {
        var next_runtime = try config_mod.loadRuntimeConfig(allocator, io, env_map, cwd);
        errdefer next_runtime.deinit();

        var next_bundle = try resources_mod.loadResourceBundle(allocator, io, .{
            .cwd = cwd,
            .agent_dir = next_runtime.agent_dir,
            .global = settingsResources(next_runtime.global_settings),
            .project = settingsResources(next_runtime.project_settings),
        });
        errdefer next_bundle.deinit(allocator);

        self.deinit(allocator);
        self.owned_runtime_config = next_runtime;
        self.owned_resource_bundle = next_bundle;
        self.runtime_config = &self.owned_runtime_config.?;
        self.keybindings = &self.owned_runtime_config.?.keybindings;
        self.prompt_templates = self.owned_resource_bundle.?.prompt_templates;
        self.theme = self.owned_resource_bundle.?.selectedTheme();
        return self.owned_resource_bundle.?.diagnostics;
    }
};

pub fn currentSessionLabel(session: *const session_mod.AgentSession) []const u8 {
    if (session.session_manager.getSessionName()) |name| return name;
    return if (session.session_manager.getSessionFile()) |path|
        std.fs.path.basename(path)
    else
        session.session_manager.getSessionId();
}

pub fn configuredCredentials(runtime_config: ?*const config_mod.RuntimeConfig) provider_config.ConfiguredCredentials {
    if (runtime_config) |value| {
        return .{
            .auth_tokens = &value.auth_tokens,
            .provider_api_keys = &value.provider_api_keys,
        };
    }
    return .{};
}

pub fn configuredApiKeyForProvider(runtime_config: ?*const config_mod.RuntimeConfig, provider_name: []const u8) ?[]const u8 {
    if (runtime_config) |runtime_config_value| {
        return runtime_config_value.lookupApiKey(provider_name);
    }
    return null;
}

pub fn configuredCompactionSettings(runtime_config: ?*const config_mod.RuntimeConfig) session_mod.CompactionSettings {
    if (runtime_config) |runtime_config_value| {
        return runtime_config_value.settings.compaction orelse .{};
    }
    return .{};
}

pub fn configuredRetrySettings(runtime_config: ?*const config_mod.RuntimeConfig) session_mod.RetrySettings {
    if (runtime_config) |runtime_config_value| {
        return runtime_config_value.settings.retry orelse .{};
    }
    return .{};
}

pub fn settingsResources(settings: config_mod.Settings) resources_mod.SettingsResources {
    return .{
        .packages = settings.packages,
        .extensions = settings.extensions,
        .skills = settings.skills,
        .prompts = settings.prompts,
        .themes = settings.themes,
        .theme = settings.theme,
    };
}

pub fn normalizePathArgument(argument: []const u8) []const u8 {
    if (argument.len >= 2) {
        const first = argument[0];
        const last = argument[argument.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return argument[1 .. argument.len - 1];
        }
    }
    return argument;
}

pub fn overrideApiKeyForProvider(options: RunInteractiveModeOptions, provider_name: []const u8) ?[]const u8 {
    if (options.api_key) |api_key| {
        if (std.mem.eql(u8, provider_name, options.provider)) return api_key;
    }
    return null;
}
