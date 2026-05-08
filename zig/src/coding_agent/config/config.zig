const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const auth = @import("../auth/auth.zig");
const config_errors = @import("config_errors.zig");
const wasm_manifest = @import("../extensions/wasm/wasm_manifest.zig");
const keybindings_mod = @import("../shared/keybindings.zig");
const migrations = @import("migrations.zig");
const resources_mod = @import("../resources/resources.zig");
const session_mod = @import("../sessions/session.zig");

const DEFAULT_CONTEXT_WINDOW = 128000;
const DEFAULT_MAX_TOKENS = 16384;
const DEFAULT_RESERVE_TOKENS = 4096;
const DEFAULT_KEEP_RECENT_TOKENS = 20000;
const DEFAULT_MAX_RETRIES = 2;
const DEFAULT_BASE_DELAY_MS = 1000;

pub const ConfigError = config_errors.ConfigError;
pub const ConfigErrorSource = config_errors.Source;
pub const configErrorSourceName = config_errors.sourceName;

pub const DoubleEscapeAction = enum {
    fork,
    tree,
    none,
};

pub const QueueModeSetting = enum {
    all,
    one_at_a_time,
};

pub const TreeFilterMode = enum {
    default,
    no_tools,
    user_only,
    labeled_only,
    all,
};

const MAX_SAFE_INTEGER: u64 = 9007199254740991;

pub const ExtensionResourceLimits = struct {
    max_children: ?u64 = null,
    depth: ?u64 = null,
    turns: ?u64 = null,
    timeout_ms: ?u64 = null,
    output_bytes: ?u64 = null,
    output_lines: ?u64 = null,
    tool_scopes: ?[]const []const u8 = null,

    pub fn deinit(self: *ExtensionResourceLimits, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.tool_scopes);
        self.* = .{};
    }

    fn clone(self: ExtensionResourceLimits, allocator: std.mem.Allocator) !ExtensionResourceLimits {
        return .{
            .max_children = self.max_children,
            .depth = self.depth,
            .turns = self.turns,
            .timeout_ms = self.timeout_ms,
            .output_bytes = self.output_bytes,
            .output_lines = self.output_lines,
            .tool_scopes = try cloneStringList(allocator, self.tool_scopes),
        };
    }
};

pub const ExtensionPolicy = struct {
    approved_grants: ?[]const []const u8 = null,
    resource_limits: ?ExtensionResourceLimits = null,
    approved: ?bool = null,
    enabled: ?bool = null,
    required: ?bool = null,

    pub fn deinit(self: *ExtensionPolicy, allocator: std.mem.Allocator) void {
        freeStringList(allocator, self.approved_grants);
        if (self.resource_limits) |*limits| limits.deinit(allocator);
        self.* = .{};
    }

    fn clone(self: ExtensionPolicy, allocator: std.mem.Allocator) !ExtensionPolicy {
        var cloned = ExtensionPolicy{};
        errdefer cloned.deinit(allocator);
        cloned.approved_grants = try cloneStringList(allocator, self.approved_grants);
        cloned.resource_limits = if (self.resource_limits) |limits| try limits.clone(allocator) else null;
        cloned.approved = self.approved;
        cloned.enabled = self.enabled;
        cloned.required = self.required;
        return cloned;
    }
};

pub const ExtensionPolicyMap = std.StringHashMap(ExtensionPolicy);

pub const Settings = struct {
    default_provider: ?[]u8 = null,
    default_model: ?[]u8 = null,
    enabled_models: ?[]const []const u8 = null,
    default_thinking_level: ?agent.ThinkingLevel = null,
    transport: ?ai.types.Transport = null,
    steering_mode: ?QueueModeSetting = null,
    follow_up_mode: ?QueueModeSetting = null,
    theme: ?[]u8 = null,
    session_dir: ?[]u8 = null,
    hide_thinking_block: ?bool = null,
    quiet_startup: ?bool = null,
    collapse_changelog: ?bool = null,
    enable_install_telemetry: ?bool = null,
    enable_skill_commands: ?bool = null,
    show_hardware_cursor: ?bool = null,
    terminal_show_images: ?bool = null,
    terminal_image_width_cells: ?usize = null,
    terminal_clear_on_shrink: ?bool = null,
    terminal_show_progress: ?bool = null,
    editor_padding_x: ?usize = null,
    autocomplete_max_visible: ?usize = null,
    /// Mirrors TypeScript `settings.images.autoResize`. When null the
    /// runtime defaults to `true` (TS default) via
    /// `RuntimeConfig.imageAutoResize`.
    image_auto_resize: ?bool = null,
    image_block_images: ?bool = null,
    double_escape_action: ?DoubleEscapeAction = null,
    tree_filter_mode: ?TreeFilterMode = null,
    warning_anthropic_extra_usage: ?bool = null,
    branch_summary_skip_prompt: ?bool = null,
    compaction: ?session_mod.CompactionSettings = null,
    retry: ?session_mod.RetrySettings = null,
    packages: ?[]const resources_mod.PackageSourceConfig = null,
    extensions: ?[]const []const u8 = null,
    skills: ?[]const []const u8 = null,
    prompts: ?[]const []const u8 = null,
    themes: ?[]const []const u8 = null,
    extension_policies: ?ExtensionPolicyMap = null,

    pub fn deinit(self: *Settings, allocator: std.mem.Allocator) void {
        if (self.default_provider) |value| allocator.free(value);
        if (self.default_model) |value| allocator.free(value);
        freeStringList(allocator, self.enabled_models);
        if (self.theme) |value| allocator.free(value);
        if (self.session_dir) |value| allocator.free(value);
        freePackageSources(allocator, self.packages);
        freeStringList(allocator, self.extensions);
        freeStringList(allocator, self.skills);
        freeStringList(allocator, self.prompts);
        freeStringList(allocator, self.themes);
        deinitExtensionPolicyMap(allocator, self.extension_policies);
        self.* = .{};
    }

    fn clone(self: Settings, allocator: std.mem.Allocator) !Settings {
        return .{
            .default_provider = if (self.default_provider) |value| try allocator.dupe(u8, value) else null,
            .default_model = if (self.default_model) |value| try allocator.dupe(u8, value) else null,
            .enabled_models = try cloneStringList(allocator, self.enabled_models),
            .default_thinking_level = self.default_thinking_level,
            .transport = self.transport,
            .steering_mode = self.steering_mode,
            .follow_up_mode = self.follow_up_mode,
            .theme = if (self.theme) |value| try allocator.dupe(u8, value) else null,
            .session_dir = if (self.session_dir) |value| try allocator.dupe(u8, value) else null,
            .hide_thinking_block = self.hide_thinking_block,
            .quiet_startup = self.quiet_startup,
            .collapse_changelog = self.collapse_changelog,
            .enable_install_telemetry = self.enable_install_telemetry,
            .enable_skill_commands = self.enable_skill_commands,
            .show_hardware_cursor = self.show_hardware_cursor,
            .terminal_show_images = self.terminal_show_images,
            .terminal_image_width_cells = self.terminal_image_width_cells,
            .terminal_clear_on_shrink = self.terminal_clear_on_shrink,
            .terminal_show_progress = self.terminal_show_progress,
            .editor_padding_x = self.editor_padding_x,
            .autocomplete_max_visible = self.autocomplete_max_visible,
            .image_auto_resize = self.image_auto_resize,
            .image_block_images = self.image_block_images,
            .double_escape_action = self.double_escape_action,
            .tree_filter_mode = self.tree_filter_mode,
            .warning_anthropic_extra_usage = self.warning_anthropic_extra_usage,
            .branch_summary_skip_prompt = self.branch_summary_skip_prompt,
            .compaction = self.compaction,
            .retry = self.retry,
            .packages = try clonePackageSources(allocator, self.packages),
            .extensions = try cloneStringList(allocator, self.extensions),
            .skills = try cloneStringList(allocator, self.skills),
            .prompts = try cloneStringList(allocator, self.prompts),
            .themes = try cloneStringList(allocator, self.themes),
            .extension_policies = try cloneExtensionPolicyMap(allocator, self.extension_policies),
        };
    }
};

pub const RuntimeConfig = struct {
    allocator: std.mem.Allocator,
    agent_dir: []u8,
    settings: Settings,
    global_settings: Settings,
    project_settings: Settings,
    auth_tokens: std.StringHashMap([]const u8),
    provider_api_keys: std.StringHashMap([]const u8),
    keybindings: keybindings_mod.Keybindings,
    errors: []ConfigError = &.{},

    pub fn deinit(self: *RuntimeConfig) void {
        self.allocator.free(self.agent_dir);
        self.settings.deinit(self.allocator);
        self.global_settings.deinit(self.allocator);
        self.project_settings.deinit(self.allocator);
        deinitStringMap(self.allocator, &self.auth_tokens);
        deinitStringMap(self.allocator, &self.provider_api_keys);
        self.keybindings.deinit();
        config_errors.deinitSlice(self.allocator, self.errors);
        self.* = undefined;
    }

    /// Mirrors TS `settingsManager.getImageAutoResize()`: defaults to `true`
    /// when the merged `images.autoResize` is unset.
    pub fn imageAutoResize(self: *const RuntimeConfig) bool {
        return self.settings.image_auto_resize orelse true;
    }

    pub fn blockImages(self: *const RuntimeConfig) bool {
        return self.settings.image_block_images orelse false;
    }

    pub fn showImages(self: *const RuntimeConfig) bool {
        return self.settings.terminal_show_images orelse true;
    }

    pub fn imageWidthCells(self: *const RuntimeConfig) usize {
        return self.settings.terminal_image_width_cells orelse 60;
    }

    pub fn clearOnShrink(self: *const RuntimeConfig) bool {
        return self.settings.terminal_clear_on_shrink orelse false;
    }

    pub fn showTerminalProgress(self: *const RuntimeConfig) bool {
        return self.settings.terminal_show_progress orelse false;
    }

    pub fn enableSkillCommands(self: *const RuntimeConfig) bool {
        return self.settings.enable_skill_commands orelse true;
    }

    pub fn hideThinkingBlock(self: *const RuntimeConfig) bool {
        return self.settings.hide_thinking_block orelse false;
    }

    pub fn collapseChangelog(self: *const RuntimeConfig) bool {
        return self.settings.collapse_changelog orelse false;
    }

    pub fn quietStartup(self: *const RuntimeConfig) bool {
        return self.settings.quiet_startup orelse false;
    }

    pub fn enableInstallTelemetry(self: *const RuntimeConfig) bool {
        return self.settings.enable_install_telemetry orelse true;
    }

    pub fn showHardwareCursor(self: *const RuntimeConfig) bool {
        return self.settings.show_hardware_cursor orelse false;
    }

    pub fn transport(self: *const RuntimeConfig) ai.types.Transport {
        return self.settings.transport orelse .auto;
    }

    pub fn steeringMode(self: *const RuntimeConfig) QueueModeSetting {
        return self.settings.steering_mode orelse .one_at_a_time;
    }

    pub fn followUpMode(self: *const RuntimeConfig) QueueModeSetting {
        return self.settings.follow_up_mode orelse .one_at_a_time;
    }

    /// Mirrors TS `settingsManager.getDoubleEscapeAction()`: defaults to
    /// opening the session tree on a double Escape when unset.
    pub fn doubleEscapeAction(self: *const RuntimeConfig) DoubleEscapeAction {
        return self.settings.double_escape_action orelse .tree;
    }

    pub fn treeFilterMode(self: *const RuntimeConfig) TreeFilterMode {
        return self.settings.tree_filter_mode orelse .default;
    }

    pub fn warningAnthropicExtraUsage(self: *const RuntimeConfig) bool {
        return self.settings.warning_anthropic_extra_usage orelse true;
    }

    pub fn branchSummarySkipPrompt(self: *const RuntimeConfig) bool {
        return self.settings.branch_summary_skip_prompt orelse false;
    }

    pub fn lookupApiKey(self: *const RuntimeConfig, provider: []const u8) ?[]const u8 {
        if (self.auth_tokens.get(provider)) |value| {
            if (isNonEmptyCredentialValue(value)) return value;
        }
        if (self.provider_api_keys.get(provider)) |value| {
            if (isNonEmptyCredentialValue(value)) return value;
        }
        return null;
    }

    pub fn getExtensionPolicy(self: *const RuntimeConfig, identity_key: []const u8) ?ExtensionPolicy {
        var policies = self.settings.extension_policies orelse return null;
        var iterator = policies.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, identity_key)) return entry.value_ptr.*;
        }
        return null;
    }

    /// Resolves the runtime session directory using the same precedence as
    /// the M10 missing-cwd preflight (`runtime_prep.resolvePreflightSessionDir`)
    /// and TypeScript `main.ts`:
    ///
    ///   1. `$PI_CODING_AGENT_SESSION_DIR` env var (TS `ENV_SESSION_DIR`)
    ///   2. `settings.json` `sessionDir` from merged global/project settings
    ///   3. Default `<cwd>/.pi/sessions`
    ///
    /// `--session-dir` overrides this entirely and is applied by the caller
    /// before `effectiveSessionDir` runs, so it is not re-checked here.
    /// Aligning the env-var precedence with the preflight ensures the
    /// missing-cwd diagnostic always refers to the same session directory
    /// the runtime will later open.
    pub fn effectiveSessionDir(self: *const RuntimeConfig, allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map, cwd: []const u8) ![]u8 {
        if (env_map.get("PI_CODING_AGENT_SESSION_DIR")) |value| {
            if (value.len > 0) {
                return expandPath(allocator, env_map, value, cwd);
            }
        }
        if (self.settings.session_dir) |value| {
            return expandPath(allocator, env_map, value, cwd);
        }
        return std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    }
};

pub const RuntimeConfigLoadOptions = struct {
    discover_models: bool = true,
};

pub fn loadRuntimeConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
) !RuntimeConfig {
    return loadRuntimeConfigWithOptions(allocator, io, env_map, cwd, .{
        .discover_models = !isTruthyEnvFlag(env_map.get("PI_OFFLINE")),
    });
}

pub fn loadRuntimeConfigWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    options: RuntimeConfigLoadOptions,
) !RuntimeConfig {
    const agent_dir = try resolveAgentDir(allocator, env_map);
    errdefer allocator.free(agent_dir);
    try migrations.run(allocator, io, agent_dir);

    const global_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(global_settings_path);
    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);
    const models_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "models.json" });
    defer allocator.free(models_path);
    const keybindings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "keybindings.json" });
    defer allocator.free(keybindings_path);

    ai.model_registry.clearDefault();

    var errors = std.ArrayList(ConfigError).empty;
    errdefer config_errors.deinitList(allocator, &errors);

    var global_settings = try loadSettingsFile(allocator, io, global_settings_path, &errors, .settings);
    errdefer global_settings.deinit(allocator);
    var project_settings = try loadSettingsFile(allocator, io, project_settings_path, &errors, .settings);
    errdefer project_settings.deinit(allocator);
    var settings = try mergeSettings(allocator, global_settings, project_settings);
    errdefer settings.deinit(allocator);

    var auth_tokens = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitStringMap(allocator, &auth_tokens);
    try loadAuthTokens(allocator, io, env_map, auth_path, &auth_tokens);
    try loadLegacySettingsApiKeys(allocator, io, global_settings_path, &auth_tokens, &errors);

    var provider_api_keys = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitStringMap(allocator, &provider_api_keys);
    try loadModelsConfig(allocator, io, models_path, &provider_api_keys, options.discover_models, &errors);

    var keybindings = try keybindings_mod.loadFromFile(allocator, io, keybindings_path);
    errdefer keybindings.deinit();

    const owned_errors = try errors.toOwnedSlice(allocator);
    errdefer config_errors.deinitSlice(allocator, owned_errors);

    return .{
        .allocator = allocator,
        .agent_dir = agent_dir,
        .settings = settings,
        .global_settings = global_settings,
        .project_settings = project_settings,
        .auth_tokens = auth_tokens,
        .provider_api_keys = provider_api_keys,
        .keybindings = keybindings,
        .errors = owned_errors,
    };
}

fn isTruthyEnvFlag(value: ?[]const u8) bool {
    const text = value orelse return false;
    return std.ascii.eqlIgnoreCase(text, "1") or
        std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "on");
}

fn loadMergedSettings(allocator: std.mem.Allocator, io: std.Io, global_path: []const u8, project_path: []const u8) !Settings {
    var errors = std.ArrayList(ConfigError).empty;
    defer config_errors.deinitList(allocator, &errors);
    var global = try loadSettingsFile(allocator, io, global_path, &errors, .settings);
    defer global.deinit(allocator);
    var project = try loadSettingsFile(allocator, io, project_path, &errors, .settings);
    defer project.deinit(allocator);
    return mergeSettings(allocator, global, project);
}

/// Loads the merged global+project settings only; used by the M10
/// missing-cwd lifecycle preflight to resolve the effective session
/// directory before `prepareCliRuntime` performs heavier work that could
/// fail and preempt the diagnostic. Caller owns the returned `Settings` and
/// must call `Settings.deinit`.
pub fn loadMergedSettingsForPreflight(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
) !Settings {
    const agent_dir = try resolveAgentDir(allocator, env_map);
    defer allocator.free(agent_dir);
    const global_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(global_settings_path);
    const project_settings_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "settings.json" });
    defer allocator.free(project_settings_path);
    return loadMergedSettings(allocator, io, global_settings_path, project_settings_path);
}

fn loadSettingsFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
) !Settings {
    const result = Settings{};
    const content = try readOptionalFile(allocator, io, path);
    defer if (content) |value| allocator.free(value);
    if (content == null) return result;

    return parseSettingsContent(allocator, path, content.?, errors, source);
}

fn parseSettingsContent(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
) !Settings {
    var result = Settings{};
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
        try config_errors.appendError(allocator, errors, source, path, err);
        return result;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try config_errors.appendMessage(allocator, errors, source, path, "expected JSON object");
        return result;
    }

    if (parsed.value.object.get("defaultProvider")) |value| {
        if (value == .string) result.default_provider = try allocator.dupe(u8, value.string);
    }
    if (parsed.value.object.get("defaultModel")) |value| {
        if (value == .string) result.default_model = try allocator.dupe(u8, value.string);
    }
    result.enabled_models = try parseStringList(allocator, parsed.value.object.get("enabledModels"));
    if (parsed.value.object.get("defaultThinkingLevel")) |value| {
        if (value == .string) result.default_thinking_level = parseThinkingLevel(value.string);
    }
    if (parsed.value.object.get("transport")) |value| {
        if (value == .string) result.transport = parseTransport(value.string);
    }
    if (parsed.value.object.get("steeringMode")) |value| {
        if (value == .string) result.steering_mode = parseQueueModeSetting(value.string);
    }
    if (parsed.value.object.get("followUpMode")) |value| {
        if (value == .string) result.follow_up_mode = parseQueueModeSetting(value.string);
    }
    if (parsed.value.object.get("theme")) |value| {
        if (value == .string) result.theme = try allocator.dupe(u8, value.string);
    }
    if (parsed.value.object.get("sessionDir")) |value| {
        if (value == .string) result.session_dir = try allocator.dupe(u8, value.string);
    }
    if (parsed.value.object.get("hideThinkingBlock")) |value| {
        if (value == .bool) result.hide_thinking_block = value.bool;
    }
    if (parsed.value.object.get("quietStartup")) |value| {
        if (value == .bool) result.quiet_startup = value.bool;
    }
    if (parsed.value.object.get("collapseChangelog")) |value| {
        if (value == .bool) result.collapse_changelog = value.bool;
    }
    if (parsed.value.object.get("enableInstallTelemetry")) |value| {
        if (value == .bool) result.enable_install_telemetry = value.bool;
    }
    if (parsed.value.object.get("enableSkillCommands")) |value| {
        if (value == .bool) result.enable_skill_commands = value.bool;
    }
    if (parsed.value.object.get("showHardwareCursor")) |value| {
        if (value == .bool) result.show_hardware_cursor = value.bool;
    }
    if (parsed.value.object.get("terminal")) |terminal_value| {
        if (terminal_value == .object) {
            if (terminal_value.object.get("showImages")) |inner| {
                if (inner == .bool) result.terminal_show_images = inner.bool;
            }
            if (terminal_value.object.get("imageWidthCells")) |inner| {
                result.terminal_image_width_cells = parsePositiveUsize(inner);
            }
            if (terminal_value.object.get("clearOnShrink")) |inner| {
                if (inner == .bool) result.terminal_clear_on_shrink = inner.bool;
            }
            if (terminal_value.object.get("showTerminalProgress")) |inner| {
                if (inner == .bool) result.terminal_show_progress = inner.bool;
            }
        }
    }
    if (parsed.value.object.get("editorPaddingX")) |value| {
        result.editor_padding_x = parseNonNegativeUsize(value);
    }
    if (parsed.value.object.get("autocompleteMaxVisible")) |value| {
        result.autocomplete_max_visible = parsePositiveUsize(value);
    }
    if (parsed.value.object.get("images")) |images_value| {
        if (images_value == .object) {
            if (images_value.object.get("autoResize")) |inner| {
                if (inner == .bool) result.image_auto_resize = inner.bool;
            }
            if (images_value.object.get("blockImages")) |inner| {
                if (inner == .bool) result.image_block_images = inner.bool;
            }
        }
    }
    if (parsed.value.object.get("doubleEscapeAction")) |value| {
        if (value == .string) result.double_escape_action = parseDoubleEscapeAction(value.string);
    }
    if (parsed.value.object.get("treeFilterMode")) |value| {
        if (value == .string) result.tree_filter_mode = parseTreeFilterMode(value.string);
    }
    if (parsed.value.object.get("warnings")) |warnings_value| {
        if (warnings_value == .object) {
            if (warnings_value.object.get("anthropicExtraUsage")) |inner| {
                if (inner == .bool) result.warning_anthropic_extra_usage = inner.bool;
            }
        }
    }
    if (parsed.value.object.get("branchSummary")) |value| {
        if (value == .object) {
            if (value.object.get("skipPrompt")) |inner| {
                if (inner == .bool) result.branch_summary_skip_prompt = inner.bool;
            }
        }
    }
    if (parsed.value.object.get("compaction")) |value| {
        result.compaction = parseCompactionSettings(value);
    }
    if (parsed.value.object.get("retry")) |value| {
        result.retry = parseRetrySettings(value);
    }
    result.packages = try parsePackageSources(allocator, parsed.value.object.get("packages"));
    result.extensions = try parseStringList(allocator, parsed.value.object.get("extensions"));
    result.skills = try parseStringList(allocator, parsed.value.object.get("skills"));
    result.prompts = try parseStringList(allocator, parsed.value.object.get("prompts"));
    result.themes = try parseStringList(allocator, parsed.value.object.get("themes"));
    result.extension_policies = try parseExtensionPolicyMap(
        allocator,
        parsed.value.object.get("extensionPolicies"),
        errors,
        source,
        path,
    );
    return result;
}

fn mergeSettings(allocator: std.mem.Allocator, base: Settings, overrides: Settings) !Settings {
    var merged = try base.clone(allocator);
    errdefer merged.deinit(allocator);

    if (overrides.default_provider) |value| {
        if (merged.default_provider) |existing| allocator.free(existing);
        merged.default_provider = try allocator.dupe(u8, value);
    }
    if (overrides.default_model) |value| {
        if (merged.default_model) |existing| allocator.free(existing);
        merged.default_model = try allocator.dupe(u8, value);
    }
    if (overrides.enabled_models != null) {
        freeStringList(allocator, merged.enabled_models);
        merged.enabled_models = try cloneStringList(allocator, overrides.enabled_models);
    }
    if (overrides.default_thinking_level) |value| {
        merged.default_thinking_level = value;
    }
    if (overrides.transport) |value| merged.transport = value;
    if (overrides.steering_mode) |value| merged.steering_mode = value;
    if (overrides.follow_up_mode) |value| merged.follow_up_mode = value;
    if (overrides.theme) |value| {
        if (merged.theme) |existing| allocator.free(existing);
        merged.theme = try allocator.dupe(u8, value);
    }
    if (overrides.session_dir) |value| {
        if (merged.session_dir) |existing| allocator.free(existing);
        merged.session_dir = try allocator.dupe(u8, value);
    }
    if (overrides.hide_thinking_block) |value| merged.hide_thinking_block = value;
    if (overrides.quiet_startup) |value| merged.quiet_startup = value;
    if (overrides.collapse_changelog) |value| merged.collapse_changelog = value;
    if (overrides.enable_install_telemetry) |value| merged.enable_install_telemetry = value;
    if (overrides.enable_skill_commands) |value| merged.enable_skill_commands = value;
    if (overrides.show_hardware_cursor) |value| merged.show_hardware_cursor = value;
    if (overrides.terminal_show_images) |value| merged.terminal_show_images = value;
    if (overrides.terminal_image_width_cells) |value| merged.terminal_image_width_cells = value;
    if (overrides.terminal_clear_on_shrink) |value| merged.terminal_clear_on_shrink = value;
    if (overrides.terminal_show_progress) |value| merged.terminal_show_progress = value;
    if (overrides.editor_padding_x) |value| merged.editor_padding_x = value;
    if (overrides.autocomplete_max_visible) |value| merged.autocomplete_max_visible = value;
    if (overrides.image_auto_resize) |value| merged.image_auto_resize = value;
    if (overrides.image_block_images) |value| merged.image_block_images = value;
    if (overrides.double_escape_action) |value| merged.double_escape_action = value;
    if (overrides.tree_filter_mode) |value| merged.tree_filter_mode = value;
    if (overrides.warning_anthropic_extra_usage) |value| merged.warning_anthropic_extra_usage = value;
    if (overrides.branch_summary_skip_prompt) |value| merged.branch_summary_skip_prompt = value;
    merged.compaction = mergeCompaction(base.compaction, overrides.compaction);
    merged.retry = mergeRetry(base.retry, overrides.retry);
    if (overrides.packages != null) {
        freePackageSources(allocator, merged.packages);
        merged.packages = try clonePackageSources(allocator, overrides.packages);
    }
    if (overrides.extensions != null) {
        freeStringList(allocator, merged.extensions);
        merged.extensions = try cloneStringList(allocator, overrides.extensions);
    }
    if (overrides.skills != null) {
        freeStringList(allocator, merged.skills);
        merged.skills = try cloneStringList(allocator, overrides.skills);
    }
    if (overrides.prompts != null) {
        freeStringList(allocator, merged.prompts);
        merged.prompts = try cloneStringList(allocator, overrides.prompts);
    }
    if (overrides.themes != null) {
        freeStringList(allocator, merged.themes);
        merged.themes = try cloneStringList(allocator, overrides.themes);
    }
    if (overrides.extension_policies != null) {
        const replacement = try mergeExtensionPolicyMaps(allocator, merged.extension_policies, overrides.extension_policies);
        deinitExtensionPolicyMap(allocator, merged.extension_policies);
        merged.extension_policies = replacement;
    }
    return merged;
}

fn mergeCompaction(base: ?session_mod.CompactionSettings, overrides: ?session_mod.CompactionSettings) ?session_mod.CompactionSettings {
    if (base == null and overrides == null) return null;
    var merged = base orelse session_mod.CompactionSettings{};
    if (overrides) |value| {
        merged.enabled = value.enabled;
        merged.reserve_tokens = value.reserve_tokens;
        merged.keep_recent_tokens = value.keep_recent_tokens;
    }
    return merged;
}

fn mergeRetry(base: ?session_mod.RetrySettings, overrides: ?session_mod.RetrySettings) ?session_mod.RetrySettings {
    if (base == null and overrides == null) return null;
    var merged = base orelse session_mod.RetrySettings{};
    if (overrides) |value| {
        merged.enabled = value.enabled;
        merged.max_retries = value.max_retries;
        merged.base_delay_ms = value.base_delay_ms;
    }
    return merged;
}

pub fn validateExtensionPoliciesForSettingsWrite(
    allocator: std.mem.Allocator,
    settings_object: std.json.ObjectMap,
    settings_path: []const u8,
) !void {
    var errors = std.ArrayList(ConfigError).empty;
    defer config_errors.deinitList(allocator, &errors);
    var parsed = try parseExtensionPolicyMap(
        allocator,
        settings_object.get("extensionPolicies"),
        &errors,
        .settings,
        settings_path,
    );
    if (parsed) |*policies| deinitExtensionPolicyMapRequired(allocator, policies);
    if (errors.items.len > 0) return error.InvalidExtensionPolicies;
}

fn parseExtensionPolicyMap(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    path: []const u8,
) !?ExtensionPolicyMap {
    const map_value = value orelse return null;
    if (map_value != .object) {
        try appendPolicyMessage(allocator, errors, source, path, "$.extensionPolicies: expected object");
        return null;
    }

    var policies = ExtensionPolicyMap.init(allocator);
    errdefer deinitExtensionPolicyMapRequired(allocator, &policies);

    var iterator = map_value.object.iterator();
    while (iterator.next()) |entry| {
        const identity = entry.key_ptr.*;
        const policy_path = try extensionPolicyEntryPath(allocator, identity);
        defer allocator.free(policy_path);
        if (identity.len == 0) {
            const message = try std.fmt.allocPrint(allocator, "{s}: extension identity must not be empty", .{policy_path});
            defer allocator.free(message);
            try appendPolicyMessage(allocator, errors, source, path, message);
            continue;
        }
        var policy = (try parseExtensionPolicyShape(allocator, entry.value_ptr.*, errors, source, path, policy_path)) orelse continue;
        errdefer policy.deinit(allocator);
        const owned_identity = try allocator.dupe(u8, identity);
        errdefer allocator.free(owned_identity);
        if (try policies.fetchPut(owned_identity, policy)) |previous| {
            allocator.free(owned_identity);
            var previous_policy = previous.value;
            previous_policy.deinit(allocator);
        }
    }

    return policies;
}

fn parseExtensionPolicyShape(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    settings_path: []const u8,
    policy_path: []const u8,
) !?ExtensionPolicy {
    if (value != .object) {
        try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}: expected object", .{policy_path});
        return null;
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (!isPolicyField(entry.key_ptr.*)) {
            try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.{s}: unsupported policy field", .{ policy_path, entry.key_ptr.* });
            return null;
        }
    }

    var policy = ExtensionPolicy{};
    errdefer policy.deinit(allocator);
    if (value.object.get("approvedGrants")) |approved_grants| {
        policy.approved_grants = (try parseApprovedGrants(allocator, approved_grants, errors, source, settings_path, policy_path)) orelse return null;
    }
    if (value.object.get("resourceLimits")) |resource_limits| {
        policy.resource_limits = (try parseResourceLimits(allocator, resource_limits, errors, source, settings_path, policy_path)) orelse {
            policy.deinit(allocator);
            return null;
        };
    }
    if (!try parseAndAssignPolicyBool(allocator, value.object.get("approved"), errors, source, settings_path, policy_path, "approved", &policy.approved)) return null;
    if (!try parseAndAssignPolicyBool(allocator, value.object.get("enabled"), errors, source, settings_path, policy_path, "enabled", &policy.enabled)) return null;
    if (!try parseAndAssignPolicyBool(allocator, value.object.get("required"), errors, source, settings_path, policy_path, "required", &policy.required)) return null;
    return policy;
}

fn parseAndAssignPolicyBool(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    settings_path: []const u8,
    policy_path: []const u8,
    field_name: []const u8,
    target: *?bool,
) !bool {
    const field = value orelse return true;
    if (field != .bool) {
        try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.{s}: expected boolean", .{ policy_path, field_name });
        return false;
    }
    target.* = field.bool;
    return true;
}

fn parseApprovedGrants(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    settings_path: []const u8,
    policy_path: []const u8,
) !?[]const []const u8 {
    if (value != .array) {
        try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.approvedGrants: expected array", .{policy_path});
        return null;
    }
    var grants = std.ArrayList([]const u8).empty;
    errdefer deinitOwnedStringArrayList(allocator, &grants);
    for (value.array.items, 0..) |grant_value, index| {
        if (grant_value != .string) {
            try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.approvedGrants[{d}]: expected string", .{ policy_path, index });
            deinitOwnedStringArrayList(allocator, &grants);
            return null;
        }
        if (!isCanonicalExtensionGrant(grant_value.string)) {
            try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.approvedGrants[{d}]: unknown grant \"{s}\"", .{ policy_path, index, grant_value.string });
            deinitOwnedStringArrayList(allocator, &grants);
            return null;
        }
        try appendOwnedString(allocator, &grants, grant_value.string);
    }
    return try grants.toOwnedSlice(allocator);
}

fn deinitOwnedStringArrayList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

fn parseResourceLimits(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    settings_path: []const u8,
    policy_path: []const u8,
) !?ExtensionResourceLimits {
    const limits_path = try std.fmt.allocPrint(allocator, "{s}.resourceLimits", .{policy_path});
    defer allocator.free(limits_path);
    if (value != .object) {
        try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}: expected object", .{limits_path});
        return null;
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (!isResourceLimitField(entry.key_ptr.*)) {
            try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.{s}: unsupported resource limit", .{ limits_path, entry.key_ptr.* });
            return null;
        }
    }

    var limits = ExtensionResourceLimits{};
    errdefer limits.deinit(allocator);
    if (!try parseAndAssignResourceLimitInteger(allocator, value.object.get("maxChildren"), errors, source, settings_path, limits_path, "maxChildren", &limits.max_children)) return null;
    if (!try parseAndAssignResourceLimitInteger(allocator, value.object.get("depth"), errors, source, settings_path, limits_path, "depth", &limits.depth)) return null;
    if (!try parseAndAssignResourceLimitInteger(allocator, value.object.get("turns"), errors, source, settings_path, limits_path, "turns", &limits.turns)) return null;
    if (!try parseAndAssignResourceLimitInteger(allocator, value.object.get("timeoutMs"), errors, source, settings_path, limits_path, "timeoutMs", &limits.timeout_ms)) return null;
    if (!try parseAndAssignResourceLimitInteger(allocator, value.object.get("outputBytes"), errors, source, settings_path, limits_path, "outputBytes", &limits.output_bytes)) return null;
    if (!try parseAndAssignResourceLimitInteger(allocator, value.object.get("outputLines"), errors, source, settings_path, limits_path, "outputLines", &limits.output_lines)) return null;
    switch (try parseOptionalToolScopes(allocator, value.object.get("toolScopes"), errors, source, settings_path, limits_path)) {
        .absent => {},
        .invalid => return null,
        .value => |scopes| limits.tool_scopes = scopes,
    }
    return limits;
}

const OptionalResourceLimitInteger = union(enum) {
    absent,
    invalid,
    value: u64,
};

fn parseAndAssignResourceLimitInteger(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    settings_path: []const u8,
    limits_path: []const u8,
    field_name: []const u8,
    target: *?u64,
) !bool {
    switch (try parseOptionalResourceLimitInteger(allocator, value, errors, source, settings_path, limits_path, field_name)) {
        .absent => return true,
        .invalid => return false,
        .value => |field| {
            target.* = field;
            return true;
        },
    }
}

fn parseOptionalResourceLimitInteger(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    settings_path: []const u8,
    limits_path: []const u8,
    field_name: []const u8,
) !OptionalResourceLimitInteger {
    const field = value orelse return .absent;
    if (field != .integer or field.integer < 0 or @as(u64, @intCast(field.integer)) > MAX_SAFE_INTEGER) {
        try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.{s}: expected non-negative integer", .{ limits_path, field_name });
        return .invalid;
    }
    return .{ .value = @intCast(field.integer) };
}

const OptionalToolScopes = union(enum) {
    absent,
    invalid,
    value: []const []const u8,
};

fn parseOptionalToolScopes(
    allocator: std.mem.Allocator,
    value: ?std.json.Value,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    settings_path: []const u8,
    limits_path: []const u8,
) !OptionalToolScopes {
    const scopes_value = value orelse return .absent;
    if (scopes_value != .array) {
        try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.toolScopes: expected array", .{limits_path});
        return .invalid;
    }
    var scopes = std.ArrayList([]const u8).empty;
    errdefer deinitOwnedStringArrayList(allocator, &scopes);
    for (scopes_value.array.items, 0..) |scope_value, index| {
        if (scope_value != .string) {
            try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.toolScopes[{d}]: expected string", .{ limits_path, index });
            deinitOwnedStringArrayList(allocator, &scopes);
            return .invalid;
        }
        if (scope_value.string.len == 0) {
            try appendPolicyMessageFmt(allocator, errors, source, settings_path, "{s}.toolScopes[{d}]: must not be empty", .{ limits_path, index });
            deinitOwnedStringArrayList(allocator, &scopes);
            return .invalid;
        }
        try appendOwnedString(allocator, &scopes, scope_value.string);
    }
    return .{ .value = try scopes.toOwnedSlice(allocator) };
}

fn mergeExtensionPolicyMaps(
    allocator: std.mem.Allocator,
    base: ?ExtensionPolicyMap,
    overrides: ?ExtensionPolicyMap,
) !?ExtensionPolicyMap {
    if (base == null and overrides == null) return null;

    var merged = (try cloneExtensionPolicyMap(allocator, base)) orelse ExtensionPolicyMap.init(allocator);
    errdefer deinitExtensionPolicyMapRequired(allocator, &merged);
    if (overrides == null) return merged;

    var override_map = overrides.?;
    var iterator = override_map.iterator();
    while (iterator.next()) |entry| {
        var policy = try mergeExtensionPolicy(allocator, merged.get(entry.key_ptr.*), entry.value_ptr.*);
        errdefer policy.deinit(allocator);
        const owned_key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(owned_key);
        if (try merged.fetchPut(owned_key, policy)) |previous| {
            allocator.free(owned_key);
            var previous_policy = previous.value;
            previous_policy.deinit(allocator);
        }
    }
    return merged;
}

fn mergeExtensionPolicy(
    allocator: std.mem.Allocator,
    base: ?ExtensionPolicy,
    override: ExtensionPolicy,
) !ExtensionPolicy {
    var merged = if (base) |policy| try policy.clone(allocator) else ExtensionPolicy{};
    errdefer merged.deinit(allocator);
    if (override.approved_grants != null) {
        const replacement = try cloneStringList(allocator, override.approved_grants);
        freeStringList(allocator, merged.approved_grants);
        merged.approved_grants = replacement;
    }
    if (override.resource_limits) |override_limits| {
        if (merged.resource_limits == null) merged.resource_limits = .{};
        if (override_limits.max_children) |field| merged.resource_limits.?.max_children = field;
        if (override_limits.depth) |field| merged.resource_limits.?.depth = field;
        if (override_limits.turns) |field| merged.resource_limits.?.turns = field;
        if (override_limits.timeout_ms) |field| merged.resource_limits.?.timeout_ms = field;
        if (override_limits.output_bytes) |field| merged.resource_limits.?.output_bytes = field;
        if (override_limits.output_lines) |field| merged.resource_limits.?.output_lines = field;
        if (override_limits.tool_scopes != null) {
            const replacement = try cloneStringList(allocator, override_limits.tool_scopes);
            freeStringList(allocator, merged.resource_limits.?.tool_scopes);
            merged.resource_limits.?.tool_scopes = replacement;
        }
    }
    if (override.approved != null) merged.approved = override.approved;
    if (override.enabled != null) merged.enabled = override.enabled;
    if (override.required != null) merged.required = override.required;
    return merged;
}

fn cloneExtensionPolicyMap(allocator: std.mem.Allocator, value: ?ExtensionPolicyMap) !?ExtensionPolicyMap {
    var source = value orelse return null;
    var cloned = ExtensionPolicyMap.init(allocator);
    errdefer deinitExtensionPolicyMapRequired(allocator, &cloned);
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        var policy = try entry.value_ptr.*.clone(allocator);
        errdefer policy.deinit(allocator);
        try cloned.put(key, policy);
    }
    return cloned;
}

fn deinitExtensionPolicyMap(allocator: std.mem.Allocator, value: ?ExtensionPolicyMap) void {
    var map = value orelse return;
    deinitExtensionPolicyMapRequired(allocator, &map);
}

fn deinitExtensionPolicyMapRequired(allocator: std.mem.Allocator, map: *ExtensionPolicyMap) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit();
}

fn extensionPolicyEntryPath(allocator: std.mem.Allocator, identity: []const u8) ![]u8 {
    const quoted = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = identity }, .{});
    defer allocator.free(quoted);
    return std.fmt.allocPrint(allocator, "$.extensionPolicies[{s}]", .{quoted});
}

fn appendPolicyMessageFmt(
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    path: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    try appendPolicyMessage(allocator, errors, source, path, message);
}

fn appendPolicyMessage(
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(ConfigError),
    source: ConfigErrorSource,
    path: []const u8,
    message: []const u8,
) !void {
    try config_errors.appendMessage(allocator, errors, source, path, message);
}

fn isPolicyField(value: []const u8) bool {
    return std.mem.eql(u8, value, "approvedGrants") or
        std.mem.eql(u8, value, "resourceLimits") or
        std.mem.eql(u8, value, "approved") or
        std.mem.eql(u8, value, "enabled") or
        std.mem.eql(u8, value, "required");
}

fn isResourceLimitField(value: []const u8) bool {
    return std.mem.eql(u8, value, "maxChildren") or
        std.mem.eql(u8, value, "depth") or
        std.mem.eql(u8, value, "turns") or
        std.mem.eql(u8, value, "timeoutMs") or
        std.mem.eql(u8, value, "outputBytes") or
        std.mem.eql(u8, value, "outputLines") or
        std.mem.eql(u8, value, "toolScopes");
}

fn isCanonicalExtensionGrant(value: []const u8) bool {
    for (wasm_manifest.CANONICAL_CAPABILITIES) |capability| {
        if (std.mem.eql(u8, capability.jsonName(), value)) return true;
    }
    return false;
}

fn loadAuthTokens(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    path: []const u8,
    auth_tokens: *std.StringHashMap([]const u8),
) !void {
    const stored = try auth.readStoredCredentialsObject(allocator, io, path);
    defer deinitJsonValue(allocator, stored);
    if (stored != .object) return;

    var iterator = stored.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const object = entry.value_ptr.object;
        if (auth.buildApiKeyFromStoredEntryRefreshing(allocator, io, env_map, path, entry.key_ptr.*, object) catch null) |api_key| {
            defer allocator.free(api_key);
            try putOwnedString(auth_tokens, allocator, entry.key_ptr.*, api_key);
        }
    }
}

fn loadLegacySettingsApiKeys(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    auth_tokens: *std.StringHashMap([]const u8),
    errors: *std.ArrayList(ConfigError),
) !void {
    const content = try readOptionalFile(allocator, io, path);
    defer if (content) |value| allocator.free(value);
    if (content == null) return;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content.?, .{}) catch |err| {
        try config_errors.appendError(allocator, errors, .legacy_settings, path, err);
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;

    const api_keys = parsed.value.object.get("apiKeys") orelse return;
    if (api_keys != .object) return;

    var iterator = api_keys.object.iterator();
    while (iterator.next()) |entry| {
        if (auth_tokens.contains(entry.key_ptr.*)) continue;
        if (entry.value_ptr.* != .string) continue;
        try putOwnedString(auth_tokens, allocator, entry.key_ptr.*, entry.value_ptr.string);
    }
}

fn loadModelsConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    provider_api_keys: *std.StringHashMap([]const u8),
    discover_models: bool,
    errors: *std.ArrayList(ConfigError),
) !void {
    const registry = ai.model_registry.getDefault();
    const content = try readOptionalFile(allocator, io, path);
    defer if (content) |value| allocator.free(value);
    if (content == null) return;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content.?, .{}) catch |err| {
        try config_errors.appendError(allocator, errors, .models, path, err);
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try config_errors.appendMessage(allocator, errors, .models, path, "expected JSON object");
        return;
    }

    const providers_value = parsed.value.object.get("providers") orelse return;
    if (providers_value != .object) return;

    var provider_iterator = providers_value.object.iterator();
    while (provider_iterator.next()) |provider_entry| {
        if (provider_entry.value_ptr.* != .object) continue;
        const provider_name = provider_entry.key_ptr.*;
        const provider_object = provider_entry.value_ptr.object;
        const existing_provider = registry.getProviderConfig(provider_name);

        const provider_api_key: ?[]const u8 = if (provider_object.get("apiKey")) |api_key_value|
            if (api_key_value == .string) api_key_value.string else null
        else
            null;
        if (provider_api_key) |api_key| {
            try putOwnedString(provider_api_keys, allocator, provider_name, api_key);
        }

        const provider_base_url = if (provider_object.get("baseUrl")) |base_url_value|
            if (base_url_value == .string) base_url_value.string else if (existing_provider) |descriptor| descriptor.base_url else null
        else if (existing_provider) |descriptor|
            descriptor.base_url
        else
            null;

        const provider_api = if (provider_object.get("api")) |api_value|
            if (api_value == .string) api_value.string else if (existing_provider) |descriptor| descriptor.api else null
        else if (existing_provider) |descriptor|
            descriptor.api
        else if (provider_base_url) |base_url|
            if (isLocalBaseUrl(base_url)) @as([]const u8, "openai-completions") else null
        else
            null;

        const models_value = provider_object.get("models");
        var first_model_id: ?[]const u8 = null;
        if (models_value) |value| {
            if (value == .array) {
                for (value.array.items) |model_value| {
                    if (model_value != .object) continue;
                    if (first_model_id == null) {
                        if (model_value.object.get("id")) |id_value| {
                            if (id_value == .string) first_model_id = id_value.string;
                        }
                    }
                }
            }
        }

        if (provider_api != null and provider_base_url != null) {
            ai.model_registry.registerProvider(.{
                .provider = provider_name,
                .api = provider_api.?,
                .base_url = provider_base_url.?,
                .default_model_id = first_model_id orelse if (existing_provider) |descriptor| descriptor.default_model_id else null,
            }) catch |err| try config_errors.appendError(allocator, errors, .register_provider, path, err);
        }

        const resolved_provider = ai.model_registry.getProviderConfig(provider_name);
        const discovery_config = parseModelDiscoveryConfig(provider_object.get("discoverModels") orelse provider_object.get("modelDiscovery"));
        if (shouldDiscoverProviderModels(discover_models, provider_base_url, models_value, discovery_config)) {
            if (resolved_provider) |provider| {
                _ = ai.model_discovery.discoverAndRegister(allocator, io, registry, provider, .{
                    .kind = discovery_config.kind,
                    .models_url = discovery_config.models_url,
                    .loaded_models_url = discovery_config.loaded_models_url,
                    .api_key = provider_api_key,
                }) catch |err| try config_errors.appendError(allocator, errors, .discovery, path, err);

                if (provider.default_model_id == null) {
                    if (registry.firstModelIdForProvider(provider_name)) |default_model_id| {
                        ai.model_registry.setProviderDefaultModel(provider_name, default_model_id) catch |err| try config_errors.appendError(allocator, errors, .set_default_model, path, err);
                    }
                }
            }
        }

        if (models_value) |value| {
            if (value == .array) {
                for (value.array.items) |model_value| {
                    if (model_value != .object) continue;
                    const model_object = model_value.object;
                    const id_value = model_object.get("id") orelse continue;
                    if (id_value != .string) continue;
                    const model_id = id_value.string;
                    const existing_model = registry.find(provider_name, model_id);
                    const api_name = if (model_object.get("api")) |api_value|
                        if (api_value == .string) api_value.string else if (existing_model) |model| model.api else if (resolved_provider) |descriptor| descriptor.api else continue
                    else if (existing_model) |model|
                        model.api
                    else if (resolved_provider) |descriptor| descriptor.api else continue;
                    const base_url = if (model_object.get("baseUrl")) |base_url_value|
                        if (base_url_value == .string) base_url_value.string else if (existing_model) |model| model.base_url else if (resolved_provider) |descriptor| descriptor.base_url else continue
                    else if (existing_model) |model|
                        model.base_url
                    else if (resolved_provider) |descriptor| descriptor.base_url else continue;

                    var headers = try parseHeaders(allocator, model_object.get("headers"));
                    const compat = try cloneJsonValueOptional(allocator, model_object.get("compat"));

                    const input_types = try parseInputTypes(allocator, model_object.get("input"), existing_model);
                    defer allocator.free(input_types);

                    const register_result = ai.model_registry.registerModel(.{
                        .id = model_id,
                        .name = if (model_object.get("name")) |name_value|
                            if (name_value == .string) name_value.string else model_id
                        else if (existing_model) |model|
                            model.name
                        else
                            model_id,
                        .api = api_name,
                        .provider = provider_name,
                        .base_url = base_url,
                        .reasoning = if (model_object.get("reasoning")) |reasoning_value|
                            if (reasoning_value == .bool) reasoning_value.bool else existing_model != null and existing_model.?.reasoning
                        else if (existing_model) |model|
                            model.reasoning
                        else
                            false,
                        .thinking_level_map = parseThinkingLevelMap(model_object.get("thinkingLevelMap"), existing_model),
                        .tool_calling = parseBoolField(model_object.get("toolCalling") orelse model_object.get("tool_calling"), if (existing_model) |model| model.tool_calling else true),
                        .loaded = parseBoolField(model_object.get("loaded"), if (existing_model) |model| model.loaded else false),
                        .input_types = input_types,
                        .cost = parseCost(model_object.get("cost"), existing_model),
                        .context_window = parseU32Field(model_object.get("contextWindow"), if (existing_model) |model| model.context_window else DEFAULT_CONTEXT_WINDOW),
                        .max_tokens = blk: {
                            const default_max: u32 = if (existing_model) |model| model.max_tokens else DEFAULT_MAX_TOKENS;
                            break :blk parseU32Field(model_object.get("maxTokens"), default_max);
                        },
                        .headers = headers,
                        .compat = compat,
                    });

                    if (headers) |*map| deinitStringMap(allocator, map);
                    if (compat) |value_compat| deinitJsonValue(allocator, value_compat);

                    register_result catch |err| try config_errors.appendError(allocator, errors, .register_model, path, err);
                }
            }
        }
    }
}

const ParsedModelDiscoveryConfig = struct {
    explicit: bool = false,
    enabled: bool = true,
    kind: ai.model_discovery.DiscoveryKind = .auto,
    models_url: ?[]const u8 = null,
    loaded_models_url: ?[]const u8 = null,
};

fn parseModelDiscoveryConfig(value: ?std.json.Value) ParsedModelDiscoveryConfig {
    const discovery_value = value orelse return .{};
    switch (discovery_value) {
        .bool => |enabled| return .{ .explicit = true, .enabled = enabled },
        .string => |kind| return .{ .explicit = true, .kind = parseDiscoveryKind(kind) },
        .object => |object| {
            return .{
                .explicit = true,
                .enabled = parseBoolField(object.get("enabled"), true),
                .kind = parseDiscoveryKind(getStringField(object, "kind") orelse getStringField(object, "type") orelse "auto"),
                .models_url = getStringField(object, "modelsUrl") orelse getStringField(object, "models_url") orelse getStringField(object, "url"),
                .loaded_models_url = getStringField(object, "loadedModelsUrl") orelse getStringField(object, "loaded_models_url") orelse getStringField(object, "loadedUrl") orelse getStringField(object, "loaded_url"),
            };
        },
        else => return .{ .explicit = true, .enabled = false },
    }
}

fn shouldDiscoverProviderModels(
    startup_network_enabled: bool,
    provider_base_url: ?[]const u8,
    models_value: ?std.json.Value,
    config: ParsedModelDiscoveryConfig,
) bool {
    if (!startup_network_enabled) return false;
    const base_url = provider_base_url orelse return false;
    if (config.explicit) return config.enabled;
    if (modelsValueHasEntries(models_value)) return false;
    return isLocalBaseUrl(base_url);
}

fn modelsValueHasEntries(value: ?std.json.Value) bool {
    const models_value = value orelse return false;
    return models_value == .array and models_value.array.items.len > 0;
}

fn parseDiscoveryKind(value: []const u8) ai.model_discovery.DiscoveryKind {
    if (std.ascii.eqlIgnoreCase(value, "openai")) return .openai;
    if (std.ascii.eqlIgnoreCase(value, "openai-compatible")) return .openai;
    if (std.ascii.eqlIgnoreCase(value, "ollama")) return .ollama;
    if (std.ascii.eqlIgnoreCase(value, "pi")) return .pi;
    return .auto;
}

fn isLocalBaseUrl(value: []const u8) bool {
    return containsIgnoreCase(value, "localhost") or
        containsIgnoreCase(value, "127.0.0.1") or
        containsIgnoreCase(value, "0.0.0.0") or
        containsIgnoreCase(value, "[::1]");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn getStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn parseBoolField(value: ?std.json.Value, default_value: bool) bool {
    const field = value orelse return default_value;
    return switch (field) {
        .bool => |boolean| boolean,
        .integer => |integer| integer != 0,
        .string => |text| parseBoolText(text) orelse default_value,
        else => default_value,
    };
}

fn parseBoolText(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "on") or
        std.mem.eql(u8, text, "1"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(text, "false") or
        std.ascii.eqlIgnoreCase(text, "no") or
        std.ascii.eqlIgnoreCase(text, "off") or
        std.mem.eql(u8, text, "0"))
    {
        return false;
    }
    return null;
}

fn parseInputTypes(allocator: std.mem.Allocator, value: ?std.json.Value, existing_model: ?ai.Model) ![]const []const u8 {
    if (value) |input_value| {
        if (input_value == .array) {
            var items = std.ArrayList([]const u8).empty;
            defer items.deinit(allocator);
            for (input_value.array.items) |item| {
                if (item != .string) continue;
                try items.append(allocator, item.string);
            }
            if (items.items.len > 0) return items.toOwnedSlice(allocator);
        }
    }

    if (existing_model) |model| {
        return allocator.dupe([]const u8, model.input_types);
    }

    return allocator.dupe([]const u8, &.{"text"});
}

fn parseThinkingLevelMap(value: ?std.json.Value, existing_model: ?ai.Model) ?ai.types.ModelThinkingLevelMap {
    const map_value = value orelse return if (existing_model) |model| model.thinking_level_map else null;
    if (map_value != .object) return if (existing_model) |model| model.thinking_level_map else null;

    var map = if (existing_model) |model| model.thinking_level_map orelse ai.types.ModelThinkingLevelMap{} else ai.types.ModelThinkingLevelMap{};
    if (parseThinkingLevelMapping(map_value.object.get("off"))) |mapping| map.off = mapping;
    if (parseThinkingLevelMapping(map_value.object.get("minimal"))) |mapping| map.minimal = mapping;
    if (parseThinkingLevelMapping(map_value.object.get("low"))) |mapping| map.low = mapping;
    if (parseThinkingLevelMapping(map_value.object.get("medium"))) |mapping| map.medium = mapping;
    if (parseThinkingLevelMapping(map_value.object.get("high"))) |mapping| map.high = mapping;
    if (parseThinkingLevelMapping(map_value.object.get("xhigh"))) |mapping| map.xhigh = mapping;
    return map;
}

fn parseThinkingLevelMapping(value: ?std.json.Value) ?ai.types.ThinkingLevelMapping {
    const mapping = value orelse return null;
    return switch (mapping) {
        .null => .unsupported,
        .string => |text| .{ .mapped = text },
        else => null,
    };
}

fn parseHeaders(allocator: std.mem.Allocator, value: ?std.json.Value) !?std.StringHashMap([]const u8) {
    const headers_value = value orelse return null;
    if (headers_value != .object) return null;

    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitStringMap(allocator, &headers);

    var iterator = headers_value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        try putOwnedString(&headers, allocator, entry.key_ptr.*, entry.value_ptr.string);
    }
    return headers;
}

fn parseCost(value: ?std.json.Value, existing_model: ?ai.Model) ai.ModelCost {
    var cost = if (existing_model) |model| model.cost else ai.ModelCost{};
    const cost_value = value orelse return cost;
    if (cost_value != .object) return cost;

    if (cost_value.object.get("input")) |field| cost.input = parseF64Field(field, cost.input);
    if (cost_value.object.get("output")) |field| cost.output = parseF64Field(field, cost.output);
    if (cost_value.object.get("cacheRead")) |field| cost.cache_read = parseF64Field(field, cost.cache_read);
    if (cost_value.object.get("cacheWrite")) |field| cost.cache_write = parseF64Field(field, cost.cache_write);
    return cost;
}

fn parseCompactionSettings(value: std.json.Value) ?session_mod.CompactionSettings {
    if (value != .object) return null;
    return .{
        .enabled = if (value.object.get("enabled")) |field| if (field == .bool) field.bool else false else false,
        .reserve_tokens = blk: {
            const default_reserve: u32 = DEFAULT_RESERVE_TOKENS;
            break :blk parseU32Field(value.object.get("reserveTokens"), default_reserve);
        },
        .keep_recent_tokens = blk: {
            const default_keep: u32 = DEFAULT_KEEP_RECENT_TOKENS;
            break :blk parseU32Field(value.object.get("keepRecentTokens"), default_keep);
        },
    };
}

fn parseRetrySettings(value: std.json.Value) ?session_mod.RetrySettings {
    if (value != .object) return null;
    return .{
        .enabled = if (value.object.get("enabled")) |field| if (field == .bool) field.bool else false else false,
        .max_retries = parseU32Field(value.object.get("maxRetries"), DEFAULT_MAX_RETRIES),
        .base_delay_ms = parseU64Field(value.object.get("baseDelayMs"), DEFAULT_BASE_DELAY_MS),
    };
}

fn parseThinkingLevel(value: []const u8) ?agent.ThinkingLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "minimal")) return .minimal;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    return null;
}

fn parseTransport(value: []const u8) ?ai.types.Transport {
    if (std.mem.eql(u8, value, "sse")) return .sse;
    if (std.mem.eql(u8, value, "websocket")) return .websocket;
    if (std.mem.eql(u8, value, "websocket-cached")) return .websocket_cached;
    if (std.mem.eql(u8, value, "auto")) return .auto;
    return null;
}

fn parseQueueModeSetting(value: []const u8) ?QueueModeSetting {
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "one-at-a-time")) return .one_at_a_time;
    return null;
}

fn parseDoubleEscapeAction(value: []const u8) ?DoubleEscapeAction {
    if (std.mem.eql(u8, value, "fork")) return .fork;
    if (std.mem.eql(u8, value, "tree")) return .tree;
    if (std.mem.eql(u8, value, "none")) return .none;
    return null;
}

fn parseTreeFilterMode(value: []const u8) ?TreeFilterMode {
    if (std.mem.eql(u8, value, "default")) return .default;
    if (std.mem.eql(u8, value, "no-tools")) return .no_tools;
    if (std.mem.eql(u8, value, "user-only")) return .user_only;
    if (std.mem.eql(u8, value, "labeled-only")) return .labeled_only;
    if (std.mem.eql(u8, value, "all")) return .all;
    return null;
}

fn parseNonNegativeUsize(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn parsePositiveUsize(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |number| if (number > 0) @intCast(number) else null,
        else => null,
    };
}

fn parseU32Field(value: ?std.json.Value, default_value: u32) u32 {
    if (value) |field| {
        if (field == .integer and field.integer >= 0) return @intCast(field.integer);
    }
    return default_value;
}

fn parseU64Field(value: ?std.json.Value, default_value: u64) u64 {
    if (value) |field| {
        if (field == .integer and field.integer >= 0) return @intCast(field.integer);
    }
    return default_value;
}

fn parseF64Field(value: std.json.Value, default_value: f64) f64 {
    return switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        else => default_value,
    };
}

fn parseStringList(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const []const u8 {
    const list_value = value orelse return null;
    if (list_value != .array) return null;

    var items = std.ArrayList([]const u8).empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }

    for (list_value.array.items) |item| {
        if (item != .string) continue;
        try appendOwnedString(allocator, &items, item.string);
    }

    return try items.toOwnedSlice(allocator);
}

fn appendOwnedString(allocator: std.mem.Allocator, items: *std.ArrayList([]const u8), value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try items.append(allocator, owned);
}

fn parsePackageSources(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const resources_mod.PackageSourceConfig {
    const packages_value = value orelse return null;
    if (packages_value != .array) return null;

    var items = std.ArrayList(resources_mod.PackageSourceConfig).empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    for (packages_value.array.items) |item| {
        switch (item) {
            .string => |source| try items.append(allocator, .{
                .source = try allocator.dupe(u8, source),
            }),
            .object => |object| {
                const source_value = object.get("source") orelse continue;
                if (source_value != .string) continue;
                try items.append(allocator, .{
                    .source = try allocator.dupe(u8, source_value.string),
                    .extensions = try parseStringList(allocator, object.get("extensions")),
                    .skills = try parseStringList(allocator, object.get("skills")),
                    .prompts = try parseStringList(allocator, object.get("prompts")),
                    .themes = try parseStringList(allocator, object.get("themes")),
                });
            },
            else => {},
        }
    }

    return try items.toOwnedSlice(allocator);
}

fn clonePackageSources(
    allocator: std.mem.Allocator,
    value: ?[]const resources_mod.PackageSourceConfig,
) !?[]const resources_mod.PackageSourceConfig {
    const packages = value orelse return null;
    var items = std.ArrayList(resources_mod.PackageSourceConfig).empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }
    for (packages) |package_source| {
        try items.append(allocator, try package_source.clone(allocator));
    }
    return try items.toOwnedSlice(allocator);
}

fn freePackageSources(allocator: std.mem.Allocator, value: ?[]const resources_mod.PackageSourceConfig) void {
    const packages = value orelse return;
    for (packages) |item_const| {
        var item = item_const;
        item.deinit(allocator);
    }
    allocator.free(packages);
}

fn cloneStringList(allocator: std.mem.Allocator, value: ?[]const []const u8) !?[]const []const u8 {
    const items = value orelse return null;
    var cloned = std.ArrayList([]const u8).empty;
    errdefer {
        for (cloned.items) |item| allocator.free(item);
        cloned.deinit(allocator);
    }
    for (items) |item| {
        const cloned_item = try allocator.dupe(u8, item);
        cloned.append(allocator, cloned_item) catch |err| {
            allocator.free(cloned_item);
            return err;
        };
    }
    return try cloned.toOwnedSlice(allocator);
}

fn freeStringList(allocator: std.mem.Allocator, value: ?[]const []const u8) void {
    const items = value orelse return;
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn cloneJsonValueOptional(allocator: std.mem.Allocator, value: ?std.json.Value) !?std.json.Value {
    if (value) |raw| return try cloneJsonValue(allocator, raw);
    return null;
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => return .{ .bool = value.bool },
        .integer => return .{ .integer = value.integer },
        .float => return .{ .float = value.float },
        .number_string => return .{ .number_string = try allocator.dupe(u8, value.number_string) },
        .string => return .{ .string = try allocator.dupe(u8, value.string) },
        .array => {
            var array = std.json.Array.init(allocator);
            errdefer {
                for (array.items) |item| deinitJsonValue(allocator, item);
                array.deinit();
            }
            for (value.array.items) |item| {
                try array.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = array };
        },
        .object => {
            var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            errdefer {
                var iterator = object.iterator();
                while (iterator.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    deinitJsonValue(allocator, entry.value_ptr.*);
                }
                object.deinit(allocator);
            }
            var iterator = value.object.iterator();
            while (iterator.next()) |entry| {
                try object.put(
                    allocator,
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try cloneJsonValue(allocator, entry.value_ptr.*),
                );
            }
            return .{ .object = object };
        },
    }
}

fn deinitJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .null, .bool, .integer, .float => {},
        .number_string => allocator.free(value.number_string),
        .string => allocator.free(value.string),
        .array => {
            for (value.array.items) |item| deinitJsonValue(allocator, item);
            var array = value.array;
            array.deinit();
        },
        .object => {
            var object = value.object;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr.*);
            }
            object.deinit(allocator);
        },
    }
}

pub fn resolveAgentDir(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    if (env_map.get("PI_CODING_AGENT_DIR")) |value| {
        return expandLeadingHome(allocator, env_map, value);
    }

    const base_dir = if (env_map.get("PI_CONFIG_DIR")) |value|
        try expandLeadingHome(allocator, env_map, value)
    else if (env_map.get("HOME")) |home|
        try std.fs.path.join(allocator, &[_][]const u8{ home, ".pi" })
    else
        try allocator.dupe(u8, ".pi");
    defer allocator.free(base_dir);

    return std.fs.path.join(allocator, &[_][]const u8{ base_dir, "agent" });
}

pub fn expandPath(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map, value: []const u8, cwd: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(value)) return allocator.dupe(u8, value);
    if (std.mem.startsWith(u8, value, "~/") or std.mem.eql(u8, value, "~")) {
        return expandLeadingHome(allocator, env_map, value);
    }
    return std.fs.path.join(allocator, &[_][]const u8{ cwd, value });
}

fn expandLeadingHome(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map, value: []const u8) ![]u8 {
    const home = env_map.get("HOME") orelse return allocator.dupe(u8, value);
    if (std.mem.eql(u8, value, "~")) return allocator.dupe(u8, home);
    if (std.mem.startsWith(u8, value, "~/")) return std.fs.path.join(allocator, &[_][]const u8{ home, value[2..] });
    return allocator.dupe(u8, value);
}

fn readOptionalFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn isNonEmptyCredentialValue(value: []const u8) bool {
    return std.mem.trim(u8, value, &std.ascii.whitespace).len > 0;
}

fn putOwnedString(map: *std.StringHashMap([]const u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    if (try map.fetchPut(owned_key, owned_value)) |previous| {
        allocator.free(previous.key);
        allocator.free(previous.value);
    }
}

fn deinitStringMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

fn makeAbsoluteTestPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

fn makeTmpPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const relative_path = try std.fs.path.join(allocator, &[_][]const u8{ ".zig-cache", "tmp", &tmp.sub_path, name });
    defer allocator.free(relative_path);
    return makeAbsoluteTestPath(allocator, relative_path);
}

test "runtime config merges global and project settings with nested overrides" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "openai",
        \\  "defaultModel": "gpt-5.4",
        \\  "defaultThinkingLevel": "low",
        \\  "sessionDir": "~/sessions",
        \\  "doubleEscapeAction": "fork",
        \\  "editorPaddingX": 1,
        \\  "compaction": {
        \\    "enabled": true,
        \\    "reserveTokens": 5000,
        \\    "keepRecentTokens": 20000
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.pi/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "doubleEscapeAction": "none",
        \\  "editorPaddingX": 3,
        \\  "autocompleteMaxVisible": 9,
        \\  "compaction": {
        \\    "enabled": false,
        \\    "reserveTokens": 1200,
        \\    "keepRecentTokens": 6400
        \\  },
        \\  "retry": {
        \\    "enabled": true,
        \\    "maxRetries": 4,
        \\    "baseDelayMs": 2500
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqualStrings("faux", runtime.settings.default_provider.?);
    try std.testing.expectEqualStrings("gpt-5.4", runtime.settings.default_model.?);
    try std.testing.expectEqual(agent.ThinkingLevel.low, runtime.settings.default_thinking_level.?);
    try std.testing.expectEqual(DoubleEscapeAction.none, runtime.doubleEscapeAction());
    try std.testing.expectEqual(@as(usize, 3), runtime.settings.editor_padding_x.?);
    try std.testing.expectEqual(@as(usize, 9), runtime.settings.autocomplete_max_visible.?);
    try std.testing.expectEqual(@as(usize, 0), runtime.errors.len);
    try std.testing.expect(runtime.settings.compaction != null);
    try std.testing.expectEqual(false, runtime.settings.compaction.?.enabled);
    try std.testing.expectEqual(@as(u32, 1200), runtime.settings.compaction.?.reserve_tokens);
    try std.testing.expectEqual(@as(u32, 6400), runtime.settings.compaction.?.keep_recent_tokens);
    try std.testing.expect(runtime.settings.retry != null);
    try std.testing.expectEqual(true, runtime.settings.retry.?.enabled);
    try std.testing.expectEqual(@as(u32, 4), runtime.settings.retry.?.max_retries);
    try std.testing.expectEqual(@as(u64, 2500), runtime.settings.retry.?.base_delay_ms);

    const session_dir = try runtime.effectiveSessionDir(allocator, &env_map, project_dir);
    defer allocator.free(session_dir);
    const expected_session_dir = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, "sessions" });
    defer allocator.free(expected_session_dir);
    try std.testing.expectEqualStrings(expected_session_dir, session_dir);
}

test "runtime config parses merges and looks up extension policies" {
    const allocator = std.testing.allocator;
    const identity_a = "typescript:local:project:/tmp/policy-a.ts";
    const identity_b = "typescript:local:project:/tmp/policy-b.ts";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-b.ts": { "approvedGrants": ["file.read"], "approved": false, "enabled": false },
        \\    "typescript:local:project:/tmp/policy-a.ts": {
        \\      "approvedGrants": ["agent.delegate", "tool.use"],
        \\      "approved": true,
        \\      "enabled": true,
        \\      "required": false,
        \\      "resourceLimits": {
        \\        "turns": 5,
        \\        "timeoutMs": 1000,
        \\        "outputLines": 20,
        \\        "toolScopes": ["fixture.echo", "fixture.read"]
        \\      }
        \\    }
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.pi/settings.json",
        .data =
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-a.ts": {
        \\      "approvedGrants": ["tool.use"],
        \\      "required": true,
        \\      "resourceLimits": {
        \\        "turns": 1,
        \\        "toolScopes": []
        \\      }
        \\    }
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqual(@as(usize, 0), runtime.errors.len);
    try std.testing.expect(runtime.settings.extension_policies != null);
    try std.testing.expectEqual(@as(u32, 2), runtime.settings.extension_policies.?.count());
    const policy_a = runtime.getExtensionPolicy(identity_a).?;
    try std.testing.expectEqual(@as(usize, 1), policy_a.approved_grants.?.len);
    try std.testing.expectEqualStrings("tool.use", policy_a.approved_grants.?[0]);
    try std.testing.expectEqual(@as(u64, 1), policy_a.resource_limits.?.turns.?);
    try std.testing.expectEqual(@as(u64, 1000), policy_a.resource_limits.?.timeout_ms.?);
    try std.testing.expectEqual(@as(u64, 20), policy_a.resource_limits.?.output_lines.?);
    try std.testing.expectEqual(@as(usize, 0), policy_a.resource_limits.?.tool_scopes.?.len);
    try std.testing.expectEqual(true, policy_a.approved.?);
    try std.testing.expectEqual(true, policy_a.enabled.?);
    try std.testing.expectEqual(true, policy_a.required.?);

    const policy_b = runtime.getExtensionPolicy(identity_b).?;
    try std.testing.expectEqual(@as(usize, 1), policy_b.approved_grants.?.len);
    try std.testing.expectEqualStrings("file.read", policy_b.approved_grants.?[0]);
    try std.testing.expectEqual(false, policy_b.approved.?);
    try std.testing.expectEqual(false, policy_b.enabled.?);
}

test "extension policy merge replacement clones are OOM safe" {
    const base_policy = ExtensionPolicy{
        .approved_grants = &.{"file.read"},
        .resource_limits = .{
            .turns = 5,
            .tool_scopes = &.{"base.scope"},
        },
    };
    const override_policy = ExtensionPolicy{
        .approved_grants = &.{"tool.use"},
        .resource_limits = .{
            .turns = 1,
            .tool_scopes = &.{"override.scope"},
        },
    };

    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_allocator_state.allocator();

        if (mergeExtensionPolicy(failing_allocator, base_policy, override_policy)) |merged| {
            var owned = merged;
            defer owned.deinit(failing_allocator);

            try std.testing.expectEqual(@as(usize, 1), owned.approved_grants.?.len);
            try std.testing.expectEqualStrings("tool.use", owned.approved_grants.?[0]);
            try std.testing.expectEqual(@as(u64, 1), owned.resource_limits.?.turns.?);
            try std.testing.expectEqual(@as(usize, 1), owned.resource_limits.?.tool_scopes.?.len);
            try std.testing.expectEqualStrings("override.scope", owned.resource_limits.?.tool_scopes.?[0]);
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }
}

fn putOwnedTestPolicy(
    allocator: std.mem.Allocator,
    map: *ExtensionPolicyMap,
    identity: []const u8,
    grants: []const []const u8,
    tool_scopes: ?[]const []const u8,
) !void {
    var policy = ExtensionPolicy{};
    errdefer policy.deinit(allocator);
    policy.approved_grants = (try cloneStringList(allocator, grants)).?;
    if (tool_scopes) |scopes| {
        policy.resource_limits = .{
            .tool_scopes = (try cloneStringList(allocator, scopes)).?,
        };
    }
    const owned_identity = try allocator.dupe(u8, identity);
    errdefer allocator.free(owned_identity);
    try map.put(owned_identity, policy);
}

fn expectBasePolicyUnchanged(base: ExtensionPolicyMap, identity_a: []const u8, identity_b: []const u8) !void {
    const retained = base.get(identity_a).?;
    try std.testing.expectEqual(@as(usize, 1), retained.approved_grants.?.len);
    try std.testing.expectEqualStrings("file.read", retained.approved_grants.?[0]);
    try std.testing.expectEqual(@as(usize, 1), retained.resource_limits.?.tool_scopes.?.len);
    try std.testing.expectEqualStrings("base.scope", retained.resource_limits.?.tool_scopes.?[0]);
    try std.testing.expect(base.get(identity_b) == null);
}

test "extension policy map merge preserves caller-owned base map on OOM" {
    const allocator = std.testing.allocator;
    const identity_a = "typescript:local:project:/tmp/policy-a.ts";
    const identity_b = "typescript:local:project:/tmp/policy-b.ts";

    var base = ExtensionPolicyMap.init(allocator);
    defer deinitExtensionPolicyMapRequired(allocator, &base);
    try putOwnedTestPolicy(allocator, &base, identity_a, &.{"file.read"}, &.{"base.scope"});

    var overrides = ExtensionPolicyMap.init(allocator);
    defer deinitExtensionPolicyMapRequired(allocator, &overrides);
    try putOwnedTestPolicy(allocator, &overrides, identity_a, &.{"tool.use"}, &.{"override.scope"});
    try putOwnedTestPolicy(allocator, &overrides, identity_b, &.{"agent.delegate"}, null);

    var fail_index: usize = 0;
    while (fail_index < 96) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_allocator_state.allocator();
        if (mergeExtensionPolicyMaps(failing_allocator, base, overrides)) |maybe_merged| {
            var merged = maybe_merged.?;
            defer deinitExtensionPolicyMapRequired(failing_allocator, &merged);

            const policy_a = merged.get(identity_a).?;
            try std.testing.expectEqual(@as(usize, 1), policy_a.approved_grants.?.len);
            try std.testing.expectEqualStrings("tool.use", policy_a.approved_grants.?[0]);
            try std.testing.expectEqual(@as(usize, 1), policy_a.resource_limits.?.tool_scopes.?.len);
            try std.testing.expectEqualStrings("override.scope", policy_a.resource_limits.?.tool_scopes.?[0]);
            const policy_b = merged.get(identity_b).?;
            try std.testing.expectEqual(@as(usize, 1), policy_b.approved_grants.?.len);
            try std.testing.expectEqualStrings("agent.delegate", policy_b.approved_grants.?[0]);
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }

        try expectBasePolicyUnchanged(base, identity_a, identity_b);
    }
}

test "extension policy map clone releases cloned policy when put fails" {
    const allocator = std.testing.allocator;

    var source = ExtensionPolicyMap.init(allocator);
    defer deinitExtensionPolicyMapRequired(allocator, &source);
    try putOwnedTestPolicy(
        allocator,
        &source,
        "typescript:local:project:/tmp/policy-a.ts",
        &.{ "file.read", "tool.use" },
        &.{ "scope.one", "scope.two" },
    );

    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_allocator_state.allocator();

        if (cloneExtensionPolicyMap(failing_allocator, source)) |maybe_cloned| {
            if (maybe_cloned) |cloned| {
                var owned = cloned;
                deinitExtensionPolicyMapRequired(failing_allocator, &owned);
            }
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }
}

test "extension policy parser list append failures release duplicated strings" {
    const allocator = std.testing.allocator;
    var errors = std.ArrayList(ConfigError).empty;
    defer config_errors.deinitList(allocator, &errors);

    var grants_value = try std.json.parseFromSlice(std.json.Value, allocator,
        \\["file.read", "tool.use"]
    , .{});
    defer grants_value.deinit();
    var tool_scopes_value = try std.json.parseFromSlice(std.json.Value, allocator,
        \\["scope.one", "scope.two"]
    , .{});
    defer tool_scopes_value.deinit();
    var string_list_value = try std.json.parseFromSlice(std.json.Value, allocator,
        \\["extensions", "skills"]
    , .{});
    defer string_list_value.deinit();

    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_allocator_state.allocator();
        if (parseApprovedGrants(
            failing_allocator,
            grants_value.value,
            &errors,
            .settings,
            "settings.json",
            "$.extensionPolicies[\"policy\"]",
        )) |maybe_grants| {
            freeStringList(failing_allocator, maybe_grants);
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }

    fail_index = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_allocator_state.allocator();
        if (parseOptionalToolScopes(
            failing_allocator,
            tool_scopes_value.value,
            &errors,
            .settings,
            "settings.json",
            "$.extensionPolicies[\"policy\"].resourceLimits",
        )) |scopes_result| {
            switch (scopes_result) {
                .absent, .invalid => {},
                .value => |scopes| freeStringList(failing_allocator, scopes),
            }
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }

    fail_index = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing_allocator_state = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const failing_allocator = failing_allocator_state.allocator();
        if (parseStringList(failing_allocator, string_list_value.value)) |maybe_items| {
            freeStringList(failing_allocator, maybe_items);
        } else |err| switch (err) {
            error.OutOfMemory => {},
        }
    }

    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
}

test "runtime config reports malformed extension policies while preserving valid scopes" {
    const allocator = std.testing.allocator;
    const identity_a = "typescript:local:project:/tmp/policy-a.ts";
    const identity_b = "typescript:local:project:/tmp/policy-b.ts";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-a.ts": { "approvedGrants": ["agent.delegate"] },
        \\    "typescript:local:project:/tmp/policy-b.ts": { "approvedGrants": ["agent"] }
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.pi/settings.json",
        .data =
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-b.ts": { "resourceLimits": { "turns": 1 } }
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqual(@as(usize, 1), runtime.errors.len);
    try std.testing.expectEqualStrings(
        "$.extensionPolicies[\"typescript:local:project:/tmp/policy-b.ts\"].approvedGrants[0]: unknown grant \"agent\"",
        runtime.errors[0].message,
    );
    try std.testing.expect(runtime.global_settings.extension_policies.?.get(identity_a) != null);
    try std.testing.expect(runtime.global_settings.extension_policies.?.get(identity_b) == null);
    const policy_b = runtime.getExtensionPolicy(identity_b).?;
    try std.testing.expectEqual(@as(u64, 1), policy_b.resource_limits.?.turns.?);
}

test "runtime config rejects malformed resource limit policy entries for effective lookup" {
    const allocator = std.testing.allocator;
    const valid_identity = "typescript:local:project:/tmp/policy-valid.ts";
    const timeout_identity = "typescript:local:project:/tmp/policy-timeout.ts";
    const scopes_identity = "typescript:local:project:/tmp/policy-scopes.ts";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-valid.ts": {
        \\      "approvedGrants": ["file.read"],
        \\      "resourceLimits": { "turns": 1, "toolScopes": ["read"] }
        \\    },
        \\    "typescript:local:project:/tmp/policy-timeout.ts": {
        \\      "approvedGrants": ["file.read"],
        \\      "resourceLimits": { "timeoutMs": 9007199254740992 }
        \\    },
        \\    "typescript:local:project:/tmp/policy-scopes.ts": {
        \\      "approvedGrants": ["file.read"],
        \\      "resourceLimits": { "toolScopes": [""] }
        \\    }
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfigWithOptions(allocator, std.testing.io, &env_map, project_dir, .{ .discover_models = false });
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqual(@as(usize, 2), runtime.errors.len);
    try std.testing.expectEqualStrings(
        "$.extensionPolicies[\"typescript:local:project:/tmp/policy-timeout.ts\"].resourceLimits.timeoutMs: expected non-negative integer",
        runtime.errors[0].message,
    );
    try std.testing.expectEqualStrings(
        "$.extensionPolicies[\"typescript:local:project:/tmp/policy-scopes.ts\"].resourceLimits.toolScopes[0]: must not be empty",
        runtime.errors[1].message,
    );
    try std.testing.expect(runtime.settings.extension_policies != null);
    try std.testing.expectEqual(@as(u32, 1), runtime.settings.extension_policies.?.count());
    try std.testing.expect(runtime.getExtensionPolicy(timeout_identity) == null);
    try std.testing.expect(runtime.getExtensionPolicy(scopes_identity) == null);

    const valid_policy = runtime.getExtensionPolicy(valid_identity).?;
    try std.testing.expectEqual(@as(usize, 1), valid_policy.approved_grants.?.len);
    try std.testing.expectEqualStrings("file.read", valid_policy.approved_grants.?[0]);
    try std.testing.expectEqual(@as(u64, 1), valid_policy.resource_limits.?.turns.?);
    try std.testing.expectEqual(@as(usize, 1), valid_policy.resource_limits.?.tool_scopes.?.len);
    try std.testing.expectEqualStrings("read", valid_policy.resource_limits.?.tool_scopes.?[0]);
}

test "extension policy write validation blocks malformed active entries" {
    const allocator = std.testing.allocator;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "theme": "dark",
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-a.ts": { "approvedGrants": ["network"] }
        \\  }
        \\}
    , .{});
    defer parsed.deinit();
    try std.testing.expectError(
        error.InvalidExtensionPolicies,
        validateExtensionPoliciesForSettingsWrite(allocator, parsed.value.object, "settings.json"),
    );

    var unsafe_limit = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-a.ts": {
        \\      "resourceLimits": { "timeoutMs": 9007199254740992 }
        \\    }
        \\  }
        \\}
    , .{});
    defer unsafe_limit.deinit();
    try std.testing.expectError(
        error.InvalidExtensionPolicies,
        validateExtensionPoliciesForSettingsWrite(allocator, unsafe_limit.value.object, "settings.json"),
    );

    var valid = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{
        \\  "extensionPolicies": {
        \\    "typescript:local:project:/tmp/policy-a.ts": {
        \\      "approvedGrants": ["agent.delegate"],
        \\      "resourceLimits": { "outputLines": 4 }
        \\    }
        \\  }
        \\}
    , .{});
    defer valid.deinit();
    try validateExtensionPoliciesForSettingsWrite(allocator, valid.value.object, "settings.json");
}

test "runtime config loads auth and custom models from agent files" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/auth.json",
        .data =
        \\{
        \\  "openai": { "type": "api_key", "key": "stored-openai-key" },
        \\  "anthropic": { "type": "oauth", "access_token": "oauth-token" }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/models.json",
        .data =
        \\{
        \\  "providers": {
        \\    "faux": {
        \\      "models": [
        \\        {
        \\          "id": "faux-custom",
        \\          "name": "Faux Custom",
        \\          "contextWindow": 16000,
        \\          "maxTokens": 2048
        \\        }
        \\      ]
        \\    },
        \\    "local-openai": {
        \\      "api": "openai-completions",
        \\      "baseUrl": "http://localhost:11434/v1",
        \\      "apiKey": "local-key",
        \\      "models": [
        \\        {
        \\          "id": "llama-3.3-70b",
        \\          "name": "Local Llama 3.3 70B",
        \\          "headers": {
        \\            "x-test": "1"
        \\          }
        \\        }
        \\      ]
        \\    },
        \\    "local-default": {
        \\      "baseUrl": "http://localhost:1234/v1",
        \\      "models": [
        \\        {
        \\          "id": "local-default-model"
        \\        }
        \\      ]
        \\    }
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqualStrings("stored-openai-key", runtime.lookupApiKey("openai").?);
    try std.testing.expectEqualStrings("oauth-token", runtime.lookupApiKey("anthropic").?);
    try std.testing.expectEqualStrings("local-key", runtime.lookupApiKey("local-openai").?);

    const faux_model = ai.model_registry.find("faux", "faux-custom").?;
    try std.testing.expectEqualStrings("Faux Custom", faux_model.name);
    try std.testing.expectEqual(@as(u32, 16000), faux_model.context_window);

    const local_provider = ai.model_registry.getProviderConfig("local-openai").?;
    try std.testing.expectEqualStrings("openai-completions", local_provider.api);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", local_provider.base_url);
    try std.testing.expectEqualStrings("llama-3.3-70b", local_provider.default_model_id.?);

    const local_model = ai.model_registry.find("local-openai", "llama-3.3-70b").?;
    try std.testing.expectEqualStrings("Local Llama 3.3 70B", local_model.name);
    try std.testing.expect(local_model.headers != null);

    const local_default_provider = ai.model_registry.getProviderConfig("local-default").?;
    try std.testing.expectEqualStrings("openai-completions", local_default_provider.api);
    try std.testing.expectEqualStrings("local-default-model", local_default_provider.default_model_id.?);
    const local_default_model = ai.model_registry.find("local-default", "local-default-model").?;
    try std.testing.expectEqualStrings("openai-completions", local_default_model.api);
    try std.testing.expect(runtime.lookupApiKey("local-default") == null);
}

test "runtime config reads legacy settings api keys" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "apiKeys": {
        \\    "kimi": "legacy-kimi-key"
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqualStrings("legacy-kimi-key", runtime.lookupApiKey("kimi").?);
}

test "runtime config honors PI_CODING_AGENT_DIR and loads keybindings" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "custom-agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "custom-agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "custom-agent/keybindings.json",
        .data =
        \\{
        \\  "app.clear": "ctrl+x",
        \\  "app.exit": ["ctrl+q"]
        \\}
        ,
    });

    const agent_dir = try makeTmpPath(allocator, tmp, "custom-agent");
    defer allocator.free(agent_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqualStrings("faux", runtime.settings.default_provider.?);
    try std.testing.expectEqualStrings("faux-1", runtime.settings.default_model.?);
    try std.testing.expectEqual(keybindings_mod.Action.clear, runtime.keybindings.actionForKey(.{ .ctrl = 'x' }).?);
    // ctrl+l is now model_select by default (was app.clear in old Zig defaults)
    try std.testing.expectEqual(keybindings_mod.Action.model_select, runtime.keybindings.actionForKey(.{ .ctrl = 'l' }).?);
    try std.testing.expectEqual(keybindings_mod.Action.exit, runtime.keybindings.actionForKey(.{ .ctrl = 'q' }).?);
}

test "loadRuntimeConfig runs one-time migrations before loading credentials" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "apiKeys": {
        \\    "openai": "migrated-openai-key"
        \\  }
        \\}
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".pi", "agent", "auth.json" });
    defer allocator.free(auth_path);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".pi", "agent", "settings.json" });
    defer allocator.free(settings_path);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expectEqualStrings("migrated-openai-key", runtime.lookupApiKey("openai").?);

    const auth_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, auth_path, allocator, .limited(1024 * 1024));
    defer allocator.free(auth_bytes);
    try std.testing.expect(std.mem.indexOf(u8, auth_bytes, "\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, auth_bytes, "\"migrated-openai-key\"") != null);

    const settings_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, settings_path, allocator, .limited(1024 * 1024));
    defer allocator.free(settings_bytes);
    try std.testing.expect(std.mem.indexOf(u8, settings_bytes, "\"apiKeys\"") == null);
}

test "runtime config collects malformed settings without aborting" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data = "{ malformed",
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    try std.testing.expect(runtime.errors.len >= 1);
    try std.testing.expectEqual(ConfigErrorSource.settings, runtime.errors[0].source);
    try std.testing.expect(std.mem.indexOf(u8, runtime.errors[0].message, "SyntaxError") != null or
        std.mem.indexOf(u8, runtime.errors[0].message, "Unexpected") != null);
}

test "runtime config parse helpers keep OOM hard" {
    var errors = std.ArrayList(ConfigError).empty;
    defer config_errors.deinitList(std.testing.allocator, &errors);

    var failing_allocator_state = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const failing_allocator = failing_allocator_state.allocator();
    try std.testing.expectError(
        error.OutOfMemory,
        parseSettingsContent(failing_allocator, "settings.json", "{}", &errors, .settings),
    );
    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
}

test "runtime config collects legacy settings and models parse failures" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "settings.json",
        .data = "{ malformed",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "models.json",
        .data = "{ malformed",
    });

    const settings_path = try makeTmpPath(allocator, tmp, "settings.json");
    defer allocator.free(settings_path);
    const models_path = try makeTmpPath(allocator, tmp, "models.json");
    defer allocator.free(models_path);

    var errors = std.ArrayList(ConfigError).empty;
    defer config_errors.deinitList(allocator, &errors);

    var auth_tokens = std.StringHashMap([]const u8).init(allocator);
    defer auth_tokens.deinit();
    try loadLegacySettingsApiKeys(allocator, std.testing.io, settings_path, &auth_tokens, &errors);

    var provider_api_keys = std.StringHashMap([]const u8).init(allocator);
    defer deinitStringMap(allocator, &provider_api_keys);
    try loadModelsConfig(allocator, std.testing.io, models_path, &provider_api_keys, false, &errors);

    try std.testing.expectEqual(@as(usize, 2), errors.items.len);
    try std.testing.expectEqual(ConfigErrorSource.legacy_settings, errors.items[0].source);
    try std.testing.expectEqual(ConfigErrorSource.models, errors.items[1].source);
}

test "runtime config collects model discovery failures" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "models.json",
        .data =
        \\{
        \\  "providers": {
        \\    "local-fail": {
        \\      "api": "openai-completions",
        \\      "baseUrl": "http://127.0.0.1:1/v1",
        \\      "discoverModels": true
        \\    }
        \\  }
        \\}
        ,
    });

    const models_path = try makeTmpPath(allocator, tmp, "models.json");
    defer allocator.free(models_path);

    ai.model_registry.clearDefault();
    defer ai.model_registry.resetForTesting();

    var errors = std.ArrayList(ConfigError).empty;
    defer config_errors.deinitList(allocator, &errors);
    var provider_api_keys = std.StringHashMap([]const u8).init(allocator);
    defer deinitStringMap(allocator, &provider_api_keys);

    try loadModelsConfig(allocator, std.testing.io, models_path, &provider_api_keys, true, &errors);

    var saw_discovery = false;
    for (errors.items) |config_error| {
        if (config_error.source == .discovery) saw_discovery = true;
    }
    try std.testing.expect(saw_discovery);
}

test "RuntimeConfig.effectiveSessionDir honors PI_CODING_AGENT_SESSION_DIR before settings sessionDir" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");
    try tmp.dir.createDirPath(std.testing.io, "envvar-sessions");
    // Settings explicitly point at a different directory so we can prove the
    // env var wins.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{ "sessionDir": "/tmp/should-be-ignored-by-env-var" }
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);
    const env_dir = try makeTmpPath(allocator, tmp, "envvar-sessions");
    defer allocator.free(env_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_SESSION_DIR", env_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    const session_dir = try runtime.effectiveSessionDir(allocator, &env_map, project_dir);
    defer allocator.free(session_dir);
    try std.testing.expectEqualStrings(env_dir, session_dir);
}

test "RuntimeConfig.effectiveSessionDir falls back to settings sessionDir when env is empty" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/.pi");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{ "sessionDir": "~/sessions-from-settings" }
        ,
    });

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    // Empty env value must not preempt settings sessionDir; mirrors TS
    // `process.env[ENV_SESSION_DIR]` truthiness check.
    try env_map.put("PI_CODING_AGENT_SESSION_DIR", "");

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    const session_dir = try runtime.effectiveSessionDir(allocator, &env_map, project_dir);
    defer allocator.free(session_dir);
    const expected = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, "sessions-from-settings" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, session_dir);
}

test "RuntimeConfig.effectiveSessionDir falls back to default when env and settings are absent" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");

    const home_dir = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const project_dir = try makeTmpPath(allocator, tmp, "project");
    defer allocator.free(project_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var runtime = try loadRuntimeConfig(allocator, std.testing.io, &env_map, project_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    const session_dir = try runtime.effectiveSessionDir(allocator, &env_map, project_dir);
    defer allocator.free(session_dir);
    const expected = try std.fs.path.join(allocator, &[_][]const u8{ project_dir, ".pi", "sessions" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, session_dir);
}
