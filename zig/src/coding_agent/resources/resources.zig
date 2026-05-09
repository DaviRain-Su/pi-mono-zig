const std = @import("std");
const config_errors = @import("../config/config_errors.zig");
const extension_manifest = @import("../extensions/extension_manifest.zig");
const provenance_lockfile = @import("../packages/provenance_lockfile.zig");
const wasm_manifest = @import("../extensions/wasm/wasm_manifest.zig");
const tui = @import("tui");
const theme_mod = tui.theme;

pub const SourceScope = enum {
    temporary,
    project,
    user,
};

pub const SourceOrigin = enum {
    top_level,
    package,
};

pub const SourceProvenanceBinding = struct {
    lock_entry_key: []u8,
    source_identity: []u8,
    package_root: []u8,
    package_root_sha256: []u8,
    artifact_sha256: ?[]u8 = null,

    pub fn clone(self: SourceProvenanceBinding, allocator: std.mem.Allocator) !SourceProvenanceBinding {
        return .{
            .lock_entry_key = try allocator.dupe(u8, self.lock_entry_key),
            .source_identity = try allocator.dupe(u8, self.source_identity),
            .package_root = try allocator.dupe(u8, self.package_root),
            .package_root_sha256 = try allocator.dupe(u8, self.package_root_sha256),
            .artifact_sha256 = if (self.artifact_sha256) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *SourceProvenanceBinding, allocator: std.mem.Allocator) void {
        allocator.free(self.lock_entry_key);
        allocator.free(self.source_identity);
        allocator.free(self.package_root);
        allocator.free(self.package_root_sha256);
        if (self.artifact_sha256) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ResourceKind = enum {
    extension,
    skill,
    prompt,
    theme,

    fn directoryName(self: ResourceKind) []const u8 {
        return switch (self) {
            .extension => "extensions",
            .skill => "skills",
            .prompt => "prompts",
            .theme => "themes",
        };
    }

    fn fileExtension(self: ResourceKind) []const u8 {
        return switch (self) {
            .extension => ".ts",
            .skill => ".md",
            .prompt => ".md",
            .theme => ".json",
        };
    }

    fn singularName(self: ResourceKind) []const u8 {
        return switch (self) {
            .extension => "extension",
            .skill => "skill",
            .prompt => "prompt",
            .theme => "theme",
        };
    }
};

pub const Diagnostic = struct {
    kind: []u8,
    message: []u8,
    path: ?[]u8 = null,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.message);
        if (self.path) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const SourceInfo = struct {
    path: []u8,
    source: []u8,
    scope: SourceScope,
    origin: SourceOrigin,
    base_dir: ?[]u8 = null,
    provenance: ?SourceProvenanceBinding = null,

    pub fn clone(self: SourceInfo, allocator: std.mem.Allocator) !SourceInfo {
        return .{
            .path = try allocator.dupe(u8, self.path),
            .source = try allocator.dupe(u8, self.source),
            .scope = self.scope,
            .origin = self.origin,
            .base_dir = if (self.base_dir) |value| try allocator.dupe(u8, value) else null,
            .provenance = if (self.provenance) |value| try value.clone(allocator) else null,
        };
    }

    pub fn deinit(self: *SourceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
        if (self.base_dir) |value| allocator.free(value);
        if (self.provenance) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

pub const ResolvedResource = struct {
    path: []u8,
    enabled: bool,
    source_info: SourceInfo,
    discovery_index: usize = 0,

    pub fn deinit(self: *ResolvedResource, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.source_info.deinit(allocator);
        self.* = undefined;
    }
};

pub const ResolvedPaths = struct {
    extensions: []ResolvedResource,
    skills: []ResolvedResource,
    prompts: []ResolvedResource,
    themes: []ResolvedResource,
    diagnostics: []Diagnostic,

    pub fn deinit(self: *ResolvedPaths, allocator: std.mem.Allocator) void {
        deinitResolvedSlice(allocator, self.extensions);
        deinitResolvedSlice(allocator, self.skills);
        deinitResolvedSlice(allocator, self.prompts);
        deinitResolvedSlice(allocator, self.themes);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const LockedWasmPackage = struct {
    source_info: SourceInfo,
    manifest: wasm_manifest.Manifest,
    lock_entry: provenance_lockfile.LockEntry,

    pub fn deinit(self: *LockedWasmPackage, allocator: std.mem.Allocator) void {
        self.source_info.deinit(allocator);
        self.manifest.deinit(allocator);
        self.lock_entry.deinit(allocator);
        self.* = undefined;
    }
};

pub const LockedWasmPackageResolution = struct {
    packages: []LockedWasmPackage,
    diagnostics: []Diagnostic,

    pub fn deinit(self: *LockedWasmPackageResolution, allocator: std.mem.Allocator) void {
        for (self.packages) |*package| package.deinit(allocator);
        allocator.free(self.packages);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(allocator);
        allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

pub const PackageSourceConfig = struct {
    source: []u8,
    extensions: ?[]const []const u8 = null,
    skills: ?[]const []const u8 = null,
    prompts: ?[]const []const u8 = null,
    themes: ?[]const []const u8 = null,

    pub fn clone(self: PackageSourceConfig, allocator: std.mem.Allocator) !PackageSourceConfig {
        return .{
            .source = try allocator.dupe(u8, self.source),
            .extensions = try cloneStringList(allocator, self.extensions),
            .skills = try cloneStringList(allocator, self.skills),
            .prompts = try cloneStringList(allocator, self.prompts),
            .themes = try cloneStringList(allocator, self.themes),
        };
    }

    pub fn deinit(self: *PackageSourceConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        freeStringList(allocator, self.extensions);
        freeStringList(allocator, self.skills);
        freeStringList(allocator, self.prompts);
        freeStringList(allocator, self.themes);
        self.* = undefined;
    }
};

pub const SettingsResources = struct {
    packages: ?[]const PackageSourceConfig = null,
    extensions: ?[]const []const u8 = null,
    skills: ?[]const []const u8 = null,
    prompts: ?[]const []const u8 = null,
    themes: ?[]const []const u8 = null,
    theme: ?[]const u8 = null,
};

pub const ExtensionDiscoveredResources = struct {
    extension_path: []const u8,
    source_info: SourceInfo,
    skill_paths: []const []const u8 = &.{},
    prompt_paths: []const []const u8 = &.{},
    theme_paths: []const []const u8 = &.{},
};

pub const LoadedExtension = struct {
    path: []u8,
    source_info: SourceInfo,

    pub fn deinit(self: *LoadedExtension, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.source_info.deinit(allocator);
        self.* = undefined;
    }
};

pub const Skill = struct {
    name: []u8,
    description: []u8,
    file_path: []u8,
    base_dir: []u8,
    source_info: SourceInfo,
    disable_model_invocation: bool = false,

    pub fn deinit(self: *Skill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.file_path);
        allocator.free(self.base_dir);
        self.source_info.deinit(allocator);
        self.* = undefined;
    }
};

pub const PromptTemplate = struct {
    name: []u8,
    description: []u8,
    argument_hint: ?[]u8 = null,
    content: []u8,
    file_path: []u8,
    source_info: SourceInfo,

    pub fn deinit(self: *PromptTemplate, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.argument_hint) |value| allocator.free(value);
        allocator.free(self.content);
        allocator.free(self.file_path);
        self.source_info.deinit(allocator);
        self.* = undefined;
    }
};

pub const ThemeColor = theme_mod.ThemeColor;
pub const ThemeToken = theme_mod.ThemeToken;
pub const StyleSpec = theme_mod.StyleSpec;
pub const ThemeColors = theme_mod.ThemeColors;
pub const Theme = theme_mod.Theme;

pub const ResourceBundle = struct {
    extensions: []LoadedExtension,
    skills: []Skill,
    prompt_templates: []PromptTemplate,
    themes: []Theme,
    selected_theme_index: usize,
    diagnostics: []Diagnostic,
    config_errors: []config_errors.ConfigError = &.{},
    terminal_name: []u8,

    pub fn deinit(self: *ResourceBundle, allocator: std.mem.Allocator) void {
        for (self.extensions) |*item| item.deinit(allocator);
        allocator.free(self.extensions);
        for (self.skills) |*item| item.deinit(allocator);
        allocator.free(self.skills);
        for (self.prompt_templates) |*item| item.deinit(allocator);
        allocator.free(self.prompt_templates);
        for (self.themes) |*item| item.deinit(allocator);
        allocator.free(self.themes);
        for (self.diagnostics) |*item| item.deinit(allocator);
        allocator.free(self.diagnostics);
        config_errors.deinitSlice(allocator, self.config_errors);
        allocator.free(self.terminal_name);
        self.* = undefined;
    }

    pub fn selectedTheme(self: *const ResourceBundle) *const Theme {
        return &self.themes[@min(self.selected_theme_index, self.themes.len - 1)];
    }
};

pub const ResolveResourcesOptions = struct {
    cwd: []const u8,
    agent_dir: []const u8,
    global: SettingsResources = .{},
    project: SettingsResources = .{},
    cli_extensions: []const []const u8 = &.{},
    cli_skills: []const []const u8 = &.{},
    cli_prompts: []const []const u8 = &.{},
    cli_themes: []const []const u8 = &.{},
    runtime_theme: ?[]const u8 = null,
    env_map: ?*const std.process.Environ.Map = null,
    include_default_extensions: bool = true,
    include_default_skills: bool = true,
    include_default_prompts: bool = true,
    include_default_themes: bool = true,
    extension_discoveries: []const ExtensionDiscoveredResources = &.{},
};

pub fn resolveConfiguredResources(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ResolveResourcesOptions,
) !ResolvedPaths {
    var diagnostics = std.ArrayList(Diagnostic).empty;
    errdefer deinitDiagnosticsList(allocator, &diagnostics);

    const project_base_dir = try std.fs.path.join(allocator, &[_][]const u8{ options.cwd, ".pi" });
    defer allocator.free(project_base_dir);

    var extensions = std.ArrayList(ResolvedResource).empty;
    errdefer deinitResolvedList(allocator, &extensions);
    var skills = std.ArrayList(ResolvedResource).empty;
    errdefer deinitResolvedList(allocator, &skills);
    var prompts = std.ArrayList(ResolvedResource).empty;
    errdefer deinitResolvedList(allocator, &prompts);
    var themes = std.ArrayList(ResolvedResource).empty;
    errdefer deinitResolvedList(allocator, &themes);

    try addLocalEntries(allocator, io, &extensions, &diagnostics, options.project.extensions, .extension, .{
        .source = "local",
        .scope = .project,
        .origin = .top_level,
        .base_dir = project_base_dir,
    });
    try addLocalEntries(allocator, io, &skills, &diagnostics, options.project.skills, .skill, .{
        .source = "local",
        .scope = .project,
        .origin = .top_level,
        .base_dir = project_base_dir,
    });
    try addLocalEntries(allocator, io, &prompts, &diagnostics, options.project.prompts, .prompt, .{
        .source = "local",
        .scope = .project,
        .origin = .top_level,
        .base_dir = project_base_dir,
    });
    try addLocalEntries(allocator, io, &themes, &diagnostics, options.project.themes, .theme, .{
        .source = "local",
        .scope = .project,
        .origin = .top_level,
        .base_dir = project_base_dir,
    });

    try addLocalEntries(allocator, io, &extensions, &diagnostics, options.global.extensions, .extension, .{
        .source = "local",
        .scope = .user,
        .origin = .top_level,
        .base_dir = options.agent_dir,
    });
    try addLocalEntries(allocator, io, &skills, &diagnostics, options.global.skills, .skill, .{
        .source = "local",
        .scope = .user,
        .origin = .top_level,
        .base_dir = options.agent_dir,
    });
    try addLocalEntries(allocator, io, &prompts, &diagnostics, options.global.prompts, .prompt, .{
        .source = "local",
        .scope = .user,
        .origin = .top_level,
        .base_dir = options.agent_dir,
    });
    try addLocalEntries(allocator, io, &themes, &diagnostics, options.global.themes, .theme, .{
        .source = "local",
        .scope = .user,
        .origin = .top_level,
        .base_dir = options.agent_dir,
    });

    try addPackageSources(allocator, io, &extensions, &skills, &prompts, &themes, &diagnostics, options.project.packages, .project, options.cwd, options.agent_dir);
    try addPackageSources(allocator, io, &extensions, &skills, &prompts, &themes, &diagnostics, options.global.packages, .user, options.cwd, options.agent_dir);

    if (options.include_default_extensions) try addAutoDiscovered(allocator, io, &extensions, &diagnostics, .extension, .project, project_base_dir);
    if (options.include_default_skills) try addAutoDiscovered(allocator, io, &skills, &diagnostics, .skill, .project, project_base_dir);
    if (options.include_default_skills) try addAutoDiscoveredProjectAgentSkills(allocator, io, &skills, &diagnostics, options.cwd, options.env_map);
    if (options.include_default_prompts) try addAutoDiscovered(allocator, io, &prompts, &diagnostics, .prompt, .project, project_base_dir);
    if (options.include_default_themes) try addAutoDiscovered(allocator, io, &themes, &diagnostics, .theme, .project, project_base_dir);

    if (options.include_default_extensions) try addAutoDiscovered(allocator, io, &extensions, &diagnostics, .extension, .user, options.agent_dir);
    if (options.include_default_skills) try addAutoDiscovered(allocator, io, &skills, &diagnostics, .skill, .user, options.agent_dir);
    if (options.include_default_skills) try addAutoDiscoveredUserAgentSkills(allocator, io, &skills, &diagnostics, options.env_map);
    if (options.include_default_prompts) try addAutoDiscovered(allocator, io, &prompts, &diagnostics, .prompt, .user, options.agent_dir);
    if (options.include_default_themes) try addAutoDiscovered(allocator, io, &themes, &diagnostics, .theme, .user, options.agent_dir);

    try addExtensionDiscoveredResources(allocator, io, &skills, &prompts, &themes, &diagnostics, options.extension_discoveries);

    try addLocalEntries(allocator, io, &extensions, &diagnostics, if (options.cli_extensions.len > 0) options.cli_extensions else null, .extension, .{
        .source = "local",
        .scope = .temporary,
        .origin = .top_level,
        .base_dir = options.cwd,
    });
    try addLocalEntries(allocator, io, &skills, &diagnostics, if (options.cli_skills.len > 0) options.cli_skills else null, .skill, .{
        .source = "local",
        .scope = .temporary,
        .origin = .top_level,
        .base_dir = options.cwd,
    });
    try addLocalEntries(allocator, io, &prompts, &diagnostics, if (options.cli_prompts.len > 0) options.cli_prompts else null, .prompt, .{
        .source = "local",
        .scope = .temporary,
        .origin = .top_level,
        .base_dir = options.cwd,
    });
    try addLocalEntries(allocator, io, &themes, &diagnostics, if (options.cli_themes.len > 0) options.cli_themes else null, .theme, .{
        .source = "local",
        .scope = .temporary,
        .origin = .top_level,
        .base_dir = options.cwd,
    });

    sortResolved(extensions.items);
    sortResolved(skills.items);
    sortResolved(prompts.items);
    sortResolved(themes.items);

    return .{
        .extensions = try extensions.toOwnedSlice(allocator),
        .skills = try skills.toOwnedSlice(allocator),
        .prompts = try prompts.toOwnedSlice(allocator),
        .themes = try themes.toOwnedSlice(allocator),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

pub fn resolveConfiguredLockedWasmPackages(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ResolveResourcesOptions,
) !LockedWasmPackageResolution {
    var diagnostics = std.ArrayList(Diagnostic).empty;
    errdefer deinitDiagnosticsList(allocator, &diagnostics);
    var packages = std.ArrayList(LockedWasmPackage).empty;
    errdefer deinitLockedWasmPackageList(allocator, &packages);

    try addLockedWasmPackageSources(allocator, io, &packages, &diagnostics, options.project.packages, .project, options.cwd, options.agent_dir);
    try addLockedWasmPackageSources(allocator, io, &packages, &diagnostics, options.global.packages, .user, options.cwd, options.agent_dir);

    std.mem.sort(LockedWasmPackage, packages.items, {}, struct {
        fn lessThan(_: void, lhs: LockedWasmPackage, rhs: LockedWasmPackage) bool {
            const left_scope = @intFromEnum(lhs.source_info.scope);
            const right_scope = @intFromEnum(rhs.source_info.scope);
            if (left_scope != right_scope) return left_scope < right_scope;
            return std.mem.lessThan(u8, lhs.manifest.package_root, rhs.manifest.package_root);
        }
    }.lessThan);

    return .{
        .packages = try packages.toOwnedSlice(allocator),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

fn addExtensionDiscoveredResources(
    allocator: std.mem.Allocator,
    io: std.Io,
    skills: *std.ArrayList(ResolvedResource),
    prompts: *std.ArrayList(ResolvedResource),
    themes: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    discoveries: []const ExtensionDiscoveredResources,
) !void {
    for (discoveries) |discovery| {
        const base_dir = discovery.source_info.base_dir orelse std.fs.path.dirname(discovery.extension_path) orelse ".";
        const seed = MetadataSeed{
            .source = "extension",
            .scope = discovery.source_info.scope,
            .origin = discovery.source_info.origin,
            .base_dir = base_dir,
        };
        try collectEntriesFromBase(allocator, io, skills, diagnostics, discovery.skill_paths, .skill, seed);
        try collectEntriesFromBase(allocator, io, prompts, diagnostics, discovery.prompt_paths, .prompt, seed);
        try collectEntriesFromBase(allocator, io, themes, diagnostics, discovery.theme_paths, .theme, seed);
    }
}

pub fn loadResourceBundle(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ResolveResourcesOptions,
) !ResourceBundle {
    var resolved = try resolveConfiguredResources(allocator, io, options);
    defer resolved.deinit(allocator);

    var extensions = std.ArrayList(LoadedExtension).empty;
    defer deinitLoadedExtensionsList(allocator, &extensions);
    for (resolved.extensions) |resource| {
        if (!resource.enabled) continue;
        try extensions.append(allocator, .{
            .path = try allocator.dupe(u8, resource.path),
            .source_info = try resource.source_info.clone(allocator),
        });
    }

    var diagnostics = std.ArrayList(Diagnostic).empty;
    defer deinitDiagnosticsList(allocator, &diagnostics);
    var collected_config_errors = std.ArrayList(config_errors.ConfigError).empty;
    errdefer config_errors.deinitList(allocator, &collected_config_errors);
    for (resolved.diagnostics) |diagnostic| {
        try diagnostics.append(allocator, try cloneDiagnostic(allocator, diagnostic));
    }

    const skills = try loadSkills(allocator, io, resolved.skills, &diagnostics, &collected_config_errors);
    errdefer deinitSkills(allocator, skills);
    const templates = try loadPromptTemplates(allocator, io, resolved.prompts, &diagnostics, &collected_config_errors);
    errdefer deinitPromptTemplates(allocator, templates);
    const themes = try loadThemes(allocator, io, resolved.themes, &diagnostics, &collected_config_errors);
    errdefer deinitThemes(allocator, themes);

    var all_themes = std.ArrayList(Theme).empty;
    errdefer deinitThemesList(allocator, &all_themes);
    for (themes) |theme| {
        try all_themes.append(allocator, theme);
    }
    allocator.free(themes);
    if (findThemeIndex(all_themes.items, "dark") == null) {
        try all_themes.append(allocator, try Theme.initDefault(allocator));
    }
    if (findThemeIndex(all_themes.items, "light") == null) {
        try all_themes.append(allocator, try Theme.initLight(allocator));
    }
    if (findThemeIndex(all_themes.items, "codex") == null) {
        try all_themes.append(allocator, try Theme.initCodex(allocator));
    }

    const selected_index = resolveThemeIndex(
        all_themes.items,
        options.env_map,
        options.runtime_theme,
        options.project.theme,
        options.global.theme,
    );
    const terminal_name = try detectTerminalName(allocator, options.env_map);
    errdefer allocator.free(terminal_name);
    const owned_config_errors = try collected_config_errors.toOwnedSlice(allocator);
    errdefer config_errors.deinitSlice(allocator, owned_config_errors);

    return .{
        .extensions = try extensions.toOwnedSlice(allocator),
        .skills = skills,
        .prompt_templates = templates,
        .themes = try all_themes.toOwnedSlice(allocator),
        .selected_theme_index = selected_index,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
        .config_errors = owned_config_errors,
        .terminal_name = terminal_name,
    };
}

fn envThemeName(env_map: ?*const std.process.Environ.Map) ?[]const u8 {
    const raw = if (env_map) |map| map.get("PI_THEME") else return null;
    const value = raw orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

pub fn resolveThemeIndex(
    themes: []const Theme,
    env_map: ?*const std.process.Environ.Map,
    runtime_theme: ?[]const u8,
    project_theme: ?[]const u8,
    global_theme: ?[]const u8,
) usize {
    const candidates = [_]?[]const u8{
        envThemeName(env_map),
        runtime_theme,
        project_theme,
        global_theme,
        detectDefaultThemeName(env_map),
    };
    for (candidates) |candidate| {
        if (findThemeIndex(themes, candidate)) |index| return index;
    }
    return 0;
}

fn detectDefaultThemeName(env_map: ?*const std.process.Environ.Map) []const u8 {
    const colorfgbg = resourceEnvValue(env_map, "COLORFGBG");
    const value = colorfgbg orelse return "dark";

    var parts = std.mem.splitScalar(u8, value, ';');
    _ = parts.next() orelse return "dark";
    const bg_text = parts.next() orelse return "dark";
    const bg = std.fmt.parseInt(u8, std.mem.trim(u8, bg_text, " \t\r\n"), 10) catch return "dark";
    return if (bg < 8) "dark" else "light";
}

fn resourceEnvValue(env_map: ?*const std.process.Environ.Map, comptime key: [:0]const u8) ?[]const u8 {
    const raw = if (env_map) |map| map.get(key) else cEnvValue(key);
    const value = raw orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

fn cEnvValue(comptime key: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(value);
}

fn detectTerminalName(allocator: std.mem.Allocator, env_map: ?*const std.process.Environ.Map) ![]u8 {
    const map = env_map orelse return try allocator.dupe(u8, "term");

    if (nonEmptyEnv(map, "TMUX") != null) return try allocator.dupe(u8, "tmux");

    if (nonEmptyEnv(map, "TERM_PROGRAM")) |term_program| {
        if (std.ascii.eqlIgnoreCase(term_program, "Apple_Terminal")) return try allocator.dupe(u8, "terminal");
        if (std.ascii.eqlIgnoreCase(term_program, "iTerm.app")) return try allocator.dupe(u8, "iterm");
        if (std.ascii.eqlIgnoreCase(term_program, "Ghostty")) return try allocator.dupe(u8, "ghostty");
        if (std.ascii.eqlIgnoreCase(term_program, "WezTerm")) return try allocator.dupe(u8, "wezterm");
        if (std.ascii.eqlIgnoreCase(term_program, "vscode")) return try allocator.dupe(u8, "vscode");
        if (std.ascii.eqlIgnoreCase(term_program, "Hyper")) return try allocator.dupe(u8, "hyper");
        if (std.ascii.eqlIgnoreCase(term_program, "tabby")) return try allocator.dupe(u8, "tabby");
        if (std.ascii.eqlIgnoreCase(term_program, "kitty")) return try allocator.dupe(u8, "kitty");
        if (std.ascii.eqlIgnoreCase(term_program, "Alacritty")) return try allocator.dupe(u8, "alacritty");

        const lower = try allocator.alloc(u8, term_program.len);
        return std.ascii.lowerString(lower, term_program);
    }

    if (nonEmptyEnv(map, "KITTY_WINDOW_ID") != null) return try allocator.dupe(u8, "kitty");
    if (nonEmptyEnv(map, "ALACRITTY_LOG") != null) return try allocator.dupe(u8, "alacritty");
    if (nonEmptyEnv(map, "WT_SESSION") != null) return try allocator.dupe(u8, "wt");

    if (nonEmptyEnv(map, "ConEmuANSI")) |value| {
        if (std.ascii.eqlIgnoreCase(value, "ON")) return try allocator.dupe(u8, "conemu");
    }
    if (nonEmptyEnv(map, "TERMINAL_EMULATOR")) |value| {
        if (std.mem.startsWith(u8, value, "JetBrains")) return try allocator.dupe(u8, "jetbrains");
    }

    if (nonEmptyEnv(map, "TERM")) |term| {
        if (std.mem.startsWith(u8, term, "alacritty")) return try allocator.dupe(u8, "alacritty");
        if (std.mem.startsWith(u8, term, "xterm-kitty")) return try allocator.dupe(u8, "kitty");
        if (std.mem.startsWith(u8, term, "screen")) return try allocator.dupe(u8, "screen");
        if (std.mem.startsWith(u8, term, "tmux")) return try allocator.dupe(u8, "tmux");
        if (std.mem.startsWith(u8, term, "xterm")) return try allocator.dupe(u8, "xterm");
    }

    return try allocator.dupe(u8, "term");
}

fn nonEmptyEnv(env_map: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env_map.get(key) orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len > 0) trimmed else null;
}

pub fn formatSkillsForPrompt(allocator: std.mem.Allocator, skills: []const Skill) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var visible_count: usize = 0;
    for (skills) |skill| {
        if (!skill.disable_model_invocation) visible_count += 1;
    }
    if (visible_count == 0) return allocator.dupe(u8, "");

    try builder.appendSlice(allocator, "\n\nThe following skills provide specialized instructions for specific tasks.\n");
    try builder.appendSlice(allocator, "Use the read tool to load a skill's file when the task matches its description.\n");
    try builder.appendSlice(allocator, "When a skill file references a relative path, resolve it against the skill directory and use that absolute path in tool commands.\n\n");
    try builder.appendSlice(allocator, "<available_skills>\n");

    for (skills) |skill| {
        if (skill.disable_model_invocation) continue;
        try builder.appendSlice(allocator, "  <skill>\n");
        const escaped_name = try escapeXmlAlloc(allocator, skill.name);
        defer allocator.free(escaped_name);
        const name_line = try std.fmt.allocPrint(allocator, "    <name>{s}</name>\n", .{escaped_name});
        defer allocator.free(name_line);
        try builder.appendSlice(allocator, name_line);
        const escaped_description = try escapeXmlAlloc(allocator, skill.description);
        defer allocator.free(escaped_description);
        const description_line = try std.fmt.allocPrint(allocator, "    <description>{s}</description>\n", .{escaped_description});
        defer allocator.free(description_line);
        try builder.appendSlice(allocator, description_line);
        const escaped_location = try escapeXmlAlloc(allocator, skill.file_path);
        defer allocator.free(escaped_location);
        const location_line = try std.fmt.allocPrint(allocator, "    <location>{s}</location>\n", .{escaped_location});
        defer allocator.free(location_line);
        try builder.appendSlice(allocator, location_line);
        try builder.appendSlice(allocator, "  </skill>\n");
    }
    try builder.appendSlice(allocator, "</available_skills>");
    return try builder.toOwnedSlice(allocator);
}

pub fn parseCommandArgs(allocator: std.mem.Allocator, args_string: []const u8) ![]const []const u8 {
    var args = std.ArrayList([]const u8).empty;
    errdefer args.deinit(allocator);
    var current = std.ArrayList(u8).empty;
    defer current.deinit(allocator);
    var in_quote: ?u8 = null;

    for (args_string) |char| {
        if (in_quote) |quote| {
            if (char == quote) {
                in_quote = null;
            } else {
                try current.append(allocator, char);
            }
            continue;
        }

        switch (char) {
            '"', '\'' => in_quote = char,
            ' ', '\t' => if (current.items.len > 0) {
                try args.append(allocator, try current.toOwnedSlice(allocator));
                current = .empty;
            },
            else => try current.append(allocator, char),
        }
    }

    if (current.items.len > 0) {
        try args.append(allocator, try current.toOwnedSlice(allocator));
    }

    return try args.toOwnedSlice(allocator);
}

pub fn freeParsedArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |item| allocator.free(item);
    allocator.free(args);
}

pub fn substituteArgs(allocator: std.mem.Allocator, content: []const u8, args: []const []const u8) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        if (content[i] != '$') {
            try builder.append(allocator, content[i]);
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, content[i..], "$ARGUMENTS")) {
            try appendJoinedArgs(allocator, &builder, args, 0, null);
            i += "$ARGUMENTS".len;
            continue;
        }
        if (std.mem.startsWith(u8, content[i..], "$@")) {
            try appendJoinedArgs(allocator, &builder, args, 0, null);
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, content[i..], "${@:")) {
            if (parseSlicePlaceholder(content[i..])) |placeholder| {
                try appendJoinedArgs(allocator, &builder, args, placeholder.start_index, placeholder.length);
                i += placeholder.consumed_len;
                continue;
            }
        }

        if (i + 1 < content.len and std.ascii.isDigit(content[i + 1])) {
            var end = i + 1;
            while (end < content.len and std.ascii.isDigit(content[end])) : (end += 1) {}
            const index = try std.fmt.parseInt(usize, content[i + 1 .. end], 10);
            if (index > 0 and index <= args.len) {
                try builder.appendSlice(allocator, args[index - 1]);
            }
            i = end;
            continue;
        }

        try builder.append(allocator, '$');
        i += 1;
    }

    return try builder.toOwnedSlice(allocator);
}

pub fn expandPromptTemplate(allocator: std.mem.Allocator, text: []const u8, templates: []const PromptTemplate) ![]u8 {
    if (text.len == 0 or text[0] != '/') return allocator.dupe(u8, text);
    const space_index = std.mem.indexOfScalar(u8, text, ' ');
    const template_name = if (space_index) |value| text[1..value] else text[1..];
    const args_string = if (space_index) |value| text[value + 1 ..] else "";
    for (templates) |template| {
        if (!std.mem.eql(u8, template.name, template_name)) continue;
        const args = try parseCommandArgs(allocator, args_string);
        defer freeParsedArgs(allocator, args);
        return substituteArgs(allocator, template.content, args);
    }
    return allocator.dupe(u8, text);
}

pub fn expandSkillCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    text: []const u8,
    skills: []const Skill,
) ![]u8 {
    if (!std.mem.startsWith(u8, text, "/skill:")) return allocator.dupe(u8, text);

    const space_index = std.mem.indexOfScalar(u8, text, ' ');
    const skill_name = if (space_index) |value| text["/skill:".len..value] else text["/skill:".len..];
    const args = if (space_index) |value| std.mem.trim(u8, text[value + 1 ..], " \t\r\n") else "";

    for (skills) |skill| {
        if (!std.mem.eql(u8, skill.name, skill_name)) continue;

        const bytes = readOptionalFile(allocator, io, skill.file_path) catch {
            return allocator.dupe(u8, text);
        };
        defer if (bytes) |value| allocator.free(value);
        if (bytes == null) return allocator.dupe(u8, text);

        const parsed = parseFrontmatter(allocator, bytes.?) catch {
            return allocator.dupe(u8, text);
        };
        defer parsed.deinit(allocator);

        const body = std.mem.trim(u8, parsed.body, " \t\r\n");
        if (args.len > 0) {
            return std.fmt.allocPrint(
                allocator,
                "<skill name=\"{s}\" location=\"{s}\">\nReferences are relative to {s}.\n\n{s}\n</skill>\n\n{s}",
                .{ skill.name, skill.file_path, skill.base_dir, body, args },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "<skill name=\"{s}\" location=\"{s}\">\nReferences are relative to {s}.\n\n{s}\n</skill>",
            .{ skill.name, skill.file_path, skill.base_dir, body },
        );
    }

    return allocator.dupe(u8, text);
}

fn defaultThemeStyles() [@typeInfo(ThemeToken).@"enum".fields.len]StyleSpec {
    var styles: [@typeInfo(ThemeToken).@"enum".fields.len]StyleSpec = undefined;
    for (&styles) |*style| style.* = .{};
    return styles;
}

const StyleTemplate = struct {
    fg: ?[]const u8 = null,
    bg: ?[]const u8 = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,

    fn owned(self: StyleTemplate, allocator: std.mem.Allocator) !StyleSpec {
        return .{
            .fg = if (self.fg) |value| try allocator.dupe(u8, value) else null,
            .bg = if (self.bg) |value| try allocator.dupe(u8, value) else null,
            .bold = self.bold,
            .italic = self.italic,
            .underline = self.underline,
        };
    }
};

const PaletteTemplate = struct {
    primary: []const u8,
    secondary: []const u8,
    success: []const u8,
    warning: []const u8,
    @"error": []const u8,
    background: []const u8,
    foreground: []const u8,
    border: []const u8,
    muted: []const u8,
};

fn defaultDarkPalette() PaletteTemplate {
    return .{
        .primary = "#7aa2f7",
        .secondary = "#bb9af7",
        .success = "#9ece6a",
        .warning = "#e0af68",
        .@"error" = "#f7768e",
        .background = "#1a1b26",
        .foreground = "#c0caf5",
        .border = "#414868",
        .muted = "#7f849c",
    };
}

fn defaultLightPalette() PaletteTemplate {
    return .{
        .primary = "#3451b2",
        .secondary = "#6f42c1",
        .success = "#2f8f4e",
        .warning = "#a05a00",
        .@"error" = "#c1392b",
        .background = "#f6f8fa",
        .foreground = "#1f2328",
        .border = "#afb8c1",
        .muted = "#57606a",
    };
}

fn initNamed(allocator: std.mem.Allocator, name: []const u8, palette: PaletteTemplate) !Theme {
    var theme = Theme{
        .name = try allocator.dupe(u8, name),
    };
    errdefer theme.deinit(allocator);

    try theme.setColor(allocator, .primary, palette.primary);
    try theme.setColor(allocator, .secondary, palette.secondary);
    try theme.setColor(allocator, .success, palette.success);
    try theme.setColor(allocator, .warning, palette.warning);
    try theme.setColor(allocator, .@"error", palette.@"error");
    try theme.setColor(allocator, .background, palette.background);
    try theme.setColor(allocator, .foreground, palette.foreground);
    try theme.setColor(allocator, .border, palette.border);
    try theme.setColor(allocator, .muted, palette.muted);
    try theme.applyDerivedStyles(allocator);
    return theme;
}

const ParsedSource = union(enum) {
    npm: struct {
        name: []const u8,
        spec: []const u8,
    },
    git: struct {
        normalized: []const u8,
    },
    local: struct {
        path: []const u8,
    },
};

const FilterSet = struct {
    extensions: ?[]const []const u8 = null,
    skills: ?[]const []const u8 = null,
    prompts: ?[]const []const u8 = null,
    themes: ?[]const []const u8 = null,

    fn forKind(self: FilterSet, kind: ResourceKind) ?[]const []const u8 {
        return switch (kind) {
            .extension => self.extensions,
            .skill => self.skills,
            .prompt => self.prompts,
            .theme => self.themes,
        };
    }
};

const MetadataSeed = struct {
    source: []const u8,
    scope: SourceScope,
    origin: SourceOrigin,
    base_dir: []const u8,
    provenance: ?SourceProvenanceBinding = null,

    fn deinit(self: *MetadataSeed, allocator: std.mem.Allocator) void {
        if (self.provenance) |*value| value.deinit(allocator);
        self.* = undefined;
    }
};

fn addPackageSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    extensions: *std.ArrayList(ResolvedResource),
    skills: *std.ArrayList(ResolvedResource),
    prompts: *std.ArrayList(ResolvedResource),
    themes: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    packages: ?[]const PackageSourceConfig,
    scope: SourceScope,
    cwd: []const u8,
    agent_dir: []const u8,
) !void {
    const package_list = packages orelse return;
    for (package_list) |pkg| {
        const parsed = parseSource(pkg.source);
        const filter = FilterSet{
            .extensions = pkg.extensions,
            .skills = pkg.skills,
            .prompts = pkg.prompts,
            .themes = pkg.themes,
        };
        switch (parsed) {
            .local => |local| {
                const base_dir = switch (scope) {
                    .project => try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi" }),
                    .user => agent_dir,
                    .temporary => cwd,
                };
                defer if (scope == .project) allocator.free(base_dir);
                const resolved = try resolvePath(allocator, base_dir, local.path);
                defer allocator.free(resolved);
                if (!try verifyLockedWasmPackageForResources(allocator, io, diagnostics, resolved, pkg.source, scope, cwd, agent_dir)) continue;
                var seed = MetadataSeed{
                    .source = pkg.source,
                    .scope = scope,
                    .origin = .package,
                    .base_dir = resolved,
                    .provenance = try readPackageProvenanceBinding(allocator, io, scope, cwd, agent_dir, pkg.source, resolved),
                };
                defer seed.deinit(allocator);
                try collectPackageResourceRoot(allocator, io, extensions, skills, prompts, themes, diagnostics, resolved, filter, seed);
            },
            .npm => |npm| {
                const install_path = try npmInstallPath(allocator, scope, cwd, agent_dir, npm.name);
                defer allocator.free(install_path);
                if (!pathExists(io, install_path)) {
                    try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "npm source is not installed", install_path));
                    continue;
                }
                if (!try verifyLockedWasmPackageForResources(allocator, io, diagnostics, install_path, pkg.source, scope, cwd, agent_dir)) continue;
                var seed = MetadataSeed{
                    .source = pkg.source,
                    .scope = scope,
                    .origin = .package,
                    .base_dir = install_path,
                    .provenance = try readPackageProvenanceBinding(allocator, io, scope, cwd, agent_dir, pkg.source, install_path),
                };
                defer seed.deinit(allocator);
                try collectPackageResourceRoot(allocator, io, extensions, skills, prompts, themes, diagnostics, install_path, filter, seed);
            },
            .git => |git| {
                const install_path = try gitInstallPath(allocator, scope, cwd, agent_dir, git.normalized);
                defer allocator.free(install_path);
                if (!pathExists(io, install_path)) {
                    try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "git source is not installed", install_path));
                    continue;
                }
                if (!try verifyLockedWasmPackageForResources(allocator, io, diagnostics, install_path, pkg.source, scope, cwd, agent_dir)) continue;
                var seed = MetadataSeed{
                    .source = pkg.source,
                    .scope = scope,
                    .origin = .package,
                    .base_dir = install_path,
                    .provenance = try readPackageProvenanceBinding(allocator, io, scope, cwd, agent_dir, pkg.source, install_path),
                };
                defer seed.deinit(allocator);
                try collectPackageResourceRoot(allocator, io, extensions, skills, prompts, themes, diagnostics, install_path, filter, seed);
            },
        }
    }
}

fn addLockedWasmPackageSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    packages: *std.ArrayList(LockedWasmPackage),
    diagnostics: *std.ArrayList(Diagnostic),
    configured_packages: ?[]const PackageSourceConfig,
    scope: SourceScope,
    cwd: []const u8,
    agent_dir: []const u8,
) !void {
    const package_list = configured_packages orelse return;
    for (package_list) |pkg| {
        const parsed = parseSource(pkg.source);
        switch (parsed) {
            .local => |local| {
                const base_dir = switch (scope) {
                    .project => try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi" }),
                    .user => agent_dir,
                    .temporary => cwd,
                };
                defer if (scope == .project) allocator.free(base_dir);
                const resolved = try resolvePath(allocator, base_dir, local.path);
                defer allocator.free(resolved);
                try appendLockedWasmPackageIfValid(allocator, io, packages, diagnostics, resolved, pkg.source, scope, cwd, agent_dir);
            },
            .npm => |npm| {
                const install_path = try npmInstallPath(allocator, scope, cwd, agent_dir, npm.name);
                defer allocator.free(install_path);
                if (!pathExists(io, install_path)) {
                    try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "npm source is not installed", install_path));
                    continue;
                }
                try appendLockedWasmPackageIfValid(allocator, io, packages, diagnostics, install_path, pkg.source, scope, cwd, agent_dir);
            },
            .git => |git| {
                const install_path = try gitInstallPath(allocator, scope, cwd, agent_dir, git.normalized);
                defer allocator.free(install_path);
                if (!pathExists(io, install_path)) {
                    try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "git source is not installed", install_path));
                    continue;
                }
                try appendLockedWasmPackageIfValid(allocator, io, packages, diagnostics, install_path, pkg.source, scope, cwd, agent_dir);
            },
        }
    }
}

fn appendLockedWasmPackageIfValid(
    allocator: std.mem.Allocator,
    io: std.Io,
    packages: *std.ArrayList(LockedWasmPackage),
    diagnostics: *std.ArrayList(Diagnostic),
    package_root: []const u8,
    source: []const u8,
    scope: SourceScope,
    cwd: []const u8,
    agent_dir: []const u8,
) !void {
    if (try verifyLockedWasmPackageDetailed(allocator, io, diagnostics, package_root, source, scope, cwd, agent_dir)) |package| {
        for (packages.items) |existing| {
            if (existing.lock_entry.scope == package.lock_entry.scope and
                std.mem.eql(u8, existing.lock_entry.key, package.lock_entry.key))
            {
                var duplicate = package;
                duplicate.deinit(allocator);
                return;
            }
        }
        try packages.append(allocator, package);
    }
}

fn verifyLockedWasmPackageForResources(
    allocator: std.mem.Allocator,
    io: std.Io,
    diagnostics: *std.ArrayList(Diagnostic),
    package_root: []const u8,
    source: []const u8,
    scope: SourceScope,
    cwd: []const u8,
    agent_dir: []const u8,
) !bool {
    if (scope == .temporary) return true;
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    if (!pathExists(io, manifest_path)) return true;
    if (!try manifestRequiresLegacyWasmLock(allocator, io, manifest_path)) return true;

    const provenance_scope: provenance_lockfile.Scope = if (scope == .project) .project else .user;
    const lock_path = try provenance_lockfile.lockfilePath(allocator, provenance_scope, cwd, agent_dir);
    defer allocator.free(lock_path);

    var current_result = try wasm_manifest.validateManifestFileWithOptions(allocator, io, package_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer current_result.deinit(allocator);
    if (current_result != .valid) {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "package_validation_failed", "wasm package validation failed", manifest_path));
        return false;
    }

    var loaded = try provenance_lockfile.readLockfile(allocator, io, provenance_scope, lock_path, "resolve");
    defer loaded.deinit(allocator);
    if (loaded.diagnostic) |diagnostic| {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, diagnostic.category, diagnostic.message, lock_path));
        return false;
    }
    if (!pathExists(io, lock_path)) {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "missing_lockfile", "missing extension provenance lockfile", lock_path));
        return false;
    }

    var current_entry = try provenance_lockfile.createWasmLockEntry(allocator, provenance_scope, current_result.valid.package_root, &current_result.valid);
    defer current_entry.deinit(allocator);
    for (loaded.entries) |entry| {
        if (!std.mem.eql(u8, entry.key, current_entry.key)) continue;
        if (provenance_lockfile.entriesEqual(entry, current_entry)) return true;
        try appendWasmProvenanceMismatchDiagnostic(allocator, diagnostics, entry, current_entry, source, scope, package_root);
        return false;
    }

    try diagnostics.append(allocator, try makeDiagnostic(allocator, "missing_lock_entry", "missing extension provenance lock entry", lock_path));
    return false;
}

fn verifyLockedWasmPackageDetailed(
    allocator: std.mem.Allocator,
    io: std.Io,
    diagnostics: *std.ArrayList(Diagnostic),
    package_root: []const u8,
    source: []const u8,
    scope: SourceScope,
    cwd: []const u8,
    agent_dir: []const u8,
) !?LockedWasmPackage {
    if (scope == .temporary) return null;
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    if (!pathExists(io, manifest_path)) return null;
    if (!try manifestRequiresLegacyWasmLock(allocator, io, manifest_path)) return null;

    const provenance_scope: provenance_lockfile.Scope = if (scope == .project) .project else .user;
    const lock_path = try provenance_lockfile.lockfilePath(allocator, provenance_scope, cwd, agent_dir);
    defer allocator.free(lock_path);

    var current_result = try wasm_manifest.validateManifestFileWithOptions(allocator, io, package_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer current_result.deinit(allocator);
    if (current_result != .valid) {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "package_validation_failed", "wasm package validation failed", manifest_path));
        return null;
    }

    var loaded = try provenance_lockfile.readLockfile(allocator, io, provenance_scope, lock_path, "resolve");
    defer loaded.deinit(allocator);
    if (loaded.diagnostic) |diagnostic| {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, diagnostic.category, diagnostic.message, lock_path));
        return null;
    }
    if (!pathExists(io, lock_path)) {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "missing_lockfile", "missing extension provenance lockfile", lock_path));
        return null;
    }

    var current_entry = try provenance_lockfile.createWasmLockEntry(allocator, provenance_scope, current_result.valid.package_root, &current_result.valid);
    defer current_entry.deinit(allocator);
    var matched_entry: ?provenance_lockfile.LockEntry = null;
    for (loaded.entries) |entry| {
        if (!std.mem.eql(u8, entry.key, current_entry.key)) continue;
        if (provenance_lockfile.entriesEqual(entry, current_entry)) {
            matched_entry = entry;
            break;
        }
        try appendWasmProvenanceMismatchDiagnostic(allocator, diagnostics, entry, current_entry, source, scope, package_root);
        return null;
    }

    if (matched_entry == null) {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "missing_lock_entry", "missing extension provenance lock entry", lock_path));
        return null;
    }

    const cloned_manifest = try cloneWasmManifest(allocator, current_result.valid);
    errdefer {
        var manifest = cloned_manifest;
        manifest.deinit(allocator);
    }
    const cloned_entry = try matched_entry.?.clone(allocator);
    errdefer {
        var entry = cloned_entry;
        entry.deinit(allocator);
    }
    return .{
        .source_info = .{
            .path = try allocator.dupe(u8, package_root),
            .source = try allocator.dupe(u8, source),
            .scope = scope,
            .origin = .package,
            .base_dir = try allocator.dupe(u8, package_root),
        },
        .manifest = cloned_manifest,
        .lock_entry = cloned_entry,
    };
}

fn manifestRequiresLegacyWasmLock(
    allocator: std.mem.Allocator,
    io: std.Io,
    manifest_path: []const u8,
) !bool {
    const manifest_text = std.Io.Dir.readFileAlloc(.cwd(), io, manifest_path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(manifest_text);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_text, .{}) catch return true;
    defer parsed.deinit();
    if (parsed.value != .object) return true;
    const schema_value = parsed.value.object.get("schemaVersion") orelse return true;
    if (schema_value != .string) return true;
    if (std.mem.eql(u8, schema_value.string, extension_manifest.SCHEMA_VERSION)) return false;
    return std.mem.eql(u8, schema_value.string, wasm_manifest.SCHEMA_VERSION);
}

fn appendWasmProvenanceMismatchDiagnostic(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    locked_entry: provenance_lockfile.LockEntry,
    current_entry: provenance_lockfile.LockEntry,
    source: []const u8,
    scope: SourceScope,
    package_root: []const u8,
) !void {
    const scope_name = sourceScopeDiagnosticName(scope);
    if (!optionalStringEqual(locked_entry.artifact_sha256, current_entry.artifact_sha256)) {
        const expected = locked_entry.artifact_sha256 orelse "";
        const actual = current_entry.artifact_sha256 orelse "";
        const artifact_path = current_entry.artifact_absolute_path orelse locked_entry.artifact_absolute_path orelse "";
        const message = try std.fmt.allocPrint(
            allocator,
            "phase=resolve; source={s}; scope={s}; packageRoot={s}; artifactPath={s}; expected={s}; actual={s}; recovery=run update for the package; extension artifact digest drift",
            .{ source, scope_name, package_root, artifact_path, expected, actual },
        );
        defer allocator.free(message);
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "artifact_digest_mismatch", message, artifact_path));
        return;
    }
    if (!std.mem.eql(u8, locked_entry.package_root_sha256, current_entry.package_root_sha256)) {
        const message = try std.fmt.allocPrint(
            allocator,
            "phase=resolve; source={s}; scope={s}; packageRoot={s}; expected={s}; actual={s}; recovery=run update for the package; extension package-root digest drift",
            .{ source, scope_name, package_root, locked_entry.package_root_sha256, current_entry.package_root_sha256 },
        );
        defer allocator.free(message);
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "package_root_digest_mismatch", message, package_root));
        return;
    }

    const identity_mismatch = firstLockIdentityMismatch(locked_entry, current_entry);
    const message = try std.fmt.allocPrint(
        allocator,
        "phase=resolve; source={s}; scope={s}; packageRoot={s}; field={s}; expected={s}; actual={s}; manifestPath={s}; artifactPath={s}; tool={s}; recovery=run update for the package; extension provenance lock entry differs from current package identity",
        .{
            source,
            scope_name,
            package_root,
            identity_mismatch.field,
            identity_mismatch.expected,
            identity_mismatch.actual,
            current_entry.manifest_path,
            current_entry.artifact_absolute_path orelse current_entry.artifact_path orelse "",
            current_entry.manifest_tool_id orelse "",
        },
    );
    defer allocator.free(message);
    try diagnostics.append(allocator, try makeDiagnostic(allocator, "manifest_identity_mismatch", message, package_root));
}

const LockIdentityMismatch = struct {
    field: []const u8,
    expected: []const u8,
    actual: []const u8,
};

fn firstLockIdentityMismatch(
    locked_entry: provenance_lockfile.LockEntry,
    current_entry: provenance_lockfile.LockEntry,
) LockIdentityMismatch {
    if (locked_entry.scope != current_entry.scope) return .{ .field = "scope", .expected = locked_entry.scope.jsonName(), .actual = current_entry.scope.jsonName() };
    if (!std.mem.eql(u8, locked_entry.source_type, current_entry.source_type)) return .{ .field = "source.type", .expected = locked_entry.source_type, .actual = current_entry.source_type };
    if (!std.mem.eql(u8, locked_entry.source_identity, current_entry.source_identity)) return .{ .field = "source.identity", .expected = locked_entry.source_identity, .actual = current_entry.source_identity };
    if (!optionalStringEqual(locked_entry.source_specifier, current_entry.source_specifier)) return .{ .field = "source.specifier", .expected = locked_entry.source_specifier orelse "", .actual = current_entry.source_specifier orelse "" };
    if (!std.mem.eql(u8, locked_entry.manifest_kind, current_entry.manifest_kind)) return .{ .field = "manifest.kind", .expected = locked_entry.manifest_kind, .actual = current_entry.manifest_kind };
    if (!optionalStringEqual(locked_entry.manifest_schema_version, current_entry.manifest_schema_version)) return .{ .field = "manifest.schemaVersion", .expected = locked_entry.manifest_schema_version orelse "", .actual = current_entry.manifest_schema_version orelse "" };
    if (!optionalStringEqual(locked_entry.manifest_id, current_entry.manifest_id)) return .{ .field = "manifest.id", .expected = locked_entry.manifest_id orelse "", .actual = current_entry.manifest_id orelse "" };
    if (!optionalStringEqual(locked_entry.manifest_name, current_entry.manifest_name)) return .{ .field = "manifest.name", .expected = locked_entry.manifest_name orelse "", .actual = current_entry.manifest_name orelse "" };
    if (!optionalStringEqual(locked_entry.manifest_version, current_entry.manifest_version)) return .{ .field = "manifest.version", .expected = locked_entry.manifest_version orelse "", .actual = current_entry.manifest_version orelse "" };
    if (!optionalStringEqual(locked_entry.manifest_tool_id, current_entry.manifest_tool_id)) return .{ .field = "manifest.toolId", .expected = locked_entry.manifest_tool_id orelse "", .actual = current_entry.manifest_tool_id orelse "" };
    if (!std.mem.eql(u8, locked_entry.package_root, current_entry.package_root)) return .{ .field = "packageRoot", .expected = locked_entry.package_root, .actual = current_entry.package_root };
    if (!std.mem.eql(u8, locked_entry.manifest_path, current_entry.manifest_path)) return .{ .field = "manifestPath", .expected = locked_entry.manifest_path, .actual = current_entry.manifest_path };
    if (!optionalStringEqual(locked_entry.artifact_kind, current_entry.artifact_kind)) return .{ .field = "artifact.kind", .expected = locked_entry.artifact_kind orelse "", .actual = current_entry.artifact_kind orelse "" };
    if (!optionalStringEqual(locked_entry.artifact_path, current_entry.artifact_path)) return .{ .field = "artifact.path", .expected = locked_entry.artifact_path orelse "", .actual = current_entry.artifact_path orelse "" };
    if (!optionalStringEqual(locked_entry.artifact_absolute_path, current_entry.artifact_absolute_path)) return .{ .field = "artifact.absolutePath", .expected = locked_entry.artifact_absolute_path orelse "", .actual = current_entry.artifact_absolute_path orelse "" };
    return .{ .field = "unknown", .expected = "", .actual = "" };
}

fn optionalStringEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

fn sourceScopeDiagnosticName(scope: SourceScope) []const u8 {
    return switch (scope) {
        .temporary => "temporary",
        .project => "project",
        .user => "user",
    };
}

fn collectPackageResourceRoot(
    allocator: std.mem.Allocator,
    io: std.Io,
    extensions: *std.ArrayList(ResolvedResource),
    skills: *std.ArrayList(ResolvedResource),
    prompts: *std.ArrayList(ResolvedResource),
    themes: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    package_root: []const u8,
    filter: FilterSet,
    seed: MetadataSeed,
) !void {
    var manifest = try readPiManifest(allocator, io, package_root);
    defer manifest.deinit(allocator);

    try collectKindFromPackage(allocator, io, extensions, diagnostics, package_root, .extension, filter.forKind(.extension), manifest.extension_entries, seed);
    try collectKindFromPackage(allocator, io, skills, diagnostics, package_root, .skill, filter.forKind(.skill), manifest.skill_entries, seed);
    try collectKindFromPackage(allocator, io, prompts, diagnostics, package_root, .prompt, filter.forKind(.prompt), manifest.prompt_entries, seed);
    try collectKindFromPackage(allocator, io, themes, diagnostics, package_root, .theme, filter.forKind(.theme), manifest.theme_entries, seed);
}

const EXTENSION_PROVENANCE_LOCKFILE_NAME = "extensions.lock.json";

fn readPackageProvenanceBinding(
    allocator: std.mem.Allocator,
    io: std.Io,
    scope: SourceScope,
    cwd: []const u8,
    agent_dir: []const u8,
    source: []const u8,
    package_root: []const u8,
) !?SourceProvenanceBinding {
    if (scope == .temporary) return null;
    const lock_path = try extensionProvenanceLockfilePath(allocator, scope, cwd, agent_dir);
    defer allocator.free(lock_path);
    const lock_text = std.Io.Dir.readFileAlloc(.cwd(), io, lock_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(lock_text);

    const key = try provenanceEntryKeyForSource(allocator, source, package_root);
    defer allocator.free(key);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, lock_text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const entries = parsed.value.object.get("entries") orelse return null;
    if (entries != .array) return null;
    for (entries.array.items) |entry| {
        if (entry != .object) continue;
        const entry_key = jsonStringField(entry.object, "key") orelse continue;
        if (!std.mem.eql(u8, entry_key, key)) continue;
        const source_object = entry.object.get("source") orelse continue;
        if (source_object != .object) continue;
        const source_identity = jsonStringField(source_object.object, "identity") orelse continue;
        const entry_package_root = jsonStringField(entry.object, "packageRoot") orelse package_root;
        const digests = entry.object.get("digests") orelse continue;
        if (digests != .object) continue;
        const package_root_sha256 = jsonStringField(digests.object, "packageRootSha256") orelse continue;
        const artifact_sha256 = if (entry.object.get("artifact")) |artifact| blk: {
            if (artifact != .object) break :blk null;
            break :blk jsonStringField(artifact.object, "sha256");
        } else null;
        return .{
            .lock_entry_key = try allocator.dupe(u8, entry_key),
            .source_identity = try allocator.dupe(u8, source_identity),
            .package_root = try allocator.dupe(u8, entry_package_root),
            .package_root_sha256 = try allocator.dupe(u8, package_root_sha256),
            .artifact_sha256 = if (artifact_sha256) |value| try allocator.dupe(u8, value) else null,
        };
    }
    return null;
}

fn extensionProvenanceLockfilePath(
    allocator: std.mem.Allocator,
    scope: SourceScope,
    cwd: []const u8,
    agent_dir: []const u8,
) ![]u8 {
    return switch (scope) {
        .project => std.fs.path.join(allocator, &.{ cwd, ".pi", EXTENSION_PROVENANCE_LOCKFILE_NAME }),
        .user => std.fs.path.join(allocator, &.{ agent_dir, EXTENSION_PROVENANCE_LOCKFILE_NAME }),
        .temporary => std.fs.path.join(allocator, &.{ cwd, ".pi", "tmp", EXTENSION_PROVENANCE_LOCKFILE_NAME }),
    };
}

fn provenanceEntryKeyForSource(allocator: std.mem.Allocator, source: []const u8, package_root: []const u8) ![]u8 {
    return switch (parseSource(source)) {
        .npm => |npm| std.fmt.allocPrint(allocator, "npm:{s}", .{npm.name}),
        .git => |git| std.fmt.allocPrint(allocator, "git:{s}", .{git.normalized}),
        .local => {
            const identity = realpathAlloc(allocator, package_root) catch try allocator.dupe(u8, package_root);
            defer allocator.free(identity);
            return std.fmt.allocPrint(allocator, "local:{s}", .{identity});
        },
    };
}

fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (@import("builtin").os.tag == .windows) {
        return std.fs.path.resolve(allocator, &.{path}) catch allocator.dupe(u8, path);
    }
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = std.c.realpath(z_path.ptr, &buffer) orelse return error.FileNotFound;
    return allocator.dupe(u8, std.mem.span(resolved));
}

fn jsonStringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn collectKindFromPackage(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    package_root: []const u8,
    kind: ResourceKind,
    filter_entries: ?[]const []const u8,
    manifest_entries: ?[][]u8,
    seed: MetadataSeed,
) !void {
    if (filter_entries) |entries| {
        if (entries.len == 0) return;
        try collectEntriesFromBase(allocator, io, target, diagnostics, entries, kind, seed);
        return;
    }

    if (manifest_entries) |entries| {
        try collectEntriesFromBase(allocator, io, target, diagnostics, sliceConst(entries), kind, seed);
        return;
    }

    const convention_dir = try std.fs.path.join(allocator, &[_][]const u8{ package_root, kind.directoryName() });
    defer allocator.free(convention_dir);
    if (!pathExists(io, convention_dir)) return;
    try collectEntriesFromBase(allocator, io, target, diagnostics, &.{kind.directoryName()}, kind, seed);
}

fn addAutoDiscovered(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    kind: ResourceKind,
    scope: SourceScope,
    base_dir: []const u8,
) !void {
    const resource_dir = try std.fs.path.join(allocator, &[_][]const u8{ base_dir, kind.directoryName() });
    defer allocator.free(resource_dir);
    if (!pathExists(io, resource_dir)) return;
    try collectPaths(
        allocator,
        io,
        target,
        diagnostics,
        resource_dir,
        kind,
        true,
        .{
            .source = "auto",
            .scope = scope,
            .origin = .top_level,
            .base_dir = base_dir,
        },
    );
}

fn addAutoDiscoveredProjectAgentSkills(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    cwd: []const u8,
    env_map: ?*const std.process.Environ.Map,
) !void {
    const user_agents_skills_dir = try userAgentsSkillsDir(allocator, env_map);
    defer if (user_agents_skills_dir) |path| allocator.free(path);

    var skill_dirs = std.ArrayList([]u8).empty;
    defer {
        for (skill_dirs.items) |path| allocator.free(path);
        skill_dirs.deinit(allocator);
    }
    try collectAncestorAgentSkillDirs(allocator, io, cwd, &skill_dirs);

    for (skill_dirs.items) |agents_skills_dir| {
        if (user_agents_skills_dir) |user_dir| {
            if (std.mem.eql(u8, agents_skills_dir, user_dir)) continue;
        }
        const agents_base_dir = std.fs.path.dirname(agents_skills_dir) orelse continue;
        try addAutoDiscoveredAgentSkillDir(allocator, io, target, diagnostics, agents_skills_dir, .project, agents_base_dir);
    }
}

fn addAutoDiscoveredUserAgentSkills(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    env_map: ?*const std.process.Environ.Map,
) !void {
    const agents_skills_dir = try userAgentsSkillsDir(allocator, env_map) orelse return;
    defer allocator.free(agents_skills_dir);
    const agents_base_dir = std.fs.path.dirname(agents_skills_dir) orelse return;
    try addAutoDiscoveredAgentSkillDir(allocator, io, target, diagnostics, agents_skills_dir, .user, agents_base_dir);
}

fn addAutoDiscoveredAgentSkillDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    agents_skills_dir: []const u8,
    scope: SourceScope,
    agents_base_dir: []const u8,
) !void {
    if (!pathExists(io, agents_skills_dir)) return;
    try collectAgentSkillFiles(allocator, io, target, diagnostics, agents_skills_dir, true, .{
        .source = "auto",
        .scope = scope,
        .origin = .top_level,
        .base_dir = agents_base_dir,
    });
}

fn addLocalEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    entries: ?[]const []const u8,
    kind: ResourceKind,
    seed: MetadataSeed,
) !void {
    const path_entries = entries orelse return;
    try collectEntriesFromBase(allocator, io, target, diagnostics, path_entries, kind, seed);
}

fn collectEntriesFromBase(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    entries: []const []const u8,
    kind: ResourceKind,
    seed: MetadataSeed,
) !void {
    if (isExplicitCliResource(kind, seed)) {
        try collectExplicitExtensionEntries(allocator, io, target, diagnostics, entries, seed);
        return;
    }

    for (entries) |entry| {
        const resolved = try resolvePath(allocator, seed.base_dir, entry);
        defer allocator.free(resolved);
        if (!pathExists(io, resolved)) {
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "resource path does not exist", resolved));
            continue;
        }
        try collectPaths(allocator, io, target, diagnostics, resolved, kind, true, seed);
    }
}

fn collectExplicitExtensionEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    entries: []const []const u8,
    seed: MetadataSeed,
) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var iterator = seen.iterator();
        while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
        seen.deinit();
    }

    for (entries) |entry| {
        const resolved = try resolvePath(allocator, seed.base_dir, entry);
        defer allocator.free(resolved);

        if (seen.contains(resolved)) {
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "duplicate explicit --extension path skipped", resolved));
            continue;
        }
        const seen_key = try allocator.dupe(u8, resolved);
        errdefer allocator.free(seen_key);
        try seen.put(seen_key, {});

        if (!pathExists(io, resolved)) {
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "explicit --extension path does not exist", resolved));
            continue;
        }

        const stat = std.Io.Dir.statFile(.cwd(), io, resolved, .{}) catch {
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "failed to stat explicit --extension path", resolved));
            continue;
        };
        if (stat.kind != .directory and (stat.kind != .file or !hasSupportedExtensionFile(resolved))) {
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "explicit --extension path is not a supported extension file or directory", resolved));
            continue;
        }

        try collectPaths(allocator, io, target, diagnostics, resolved, .extension, true, seed);
    }
}

fn collectPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    path: []const u8,
    kind: ResourceKind,
    enabled: bool,
    seed: MetadataSeed,
) !void {
    const stat = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "failed to stat resource path", path));
        return;
    };
    if (stat.kind == .file) {
        const package_extension_file = kind == .extension and seed.origin == .package;
        if (kind != .extension or hasSupportedExtensionFile(path) or package_extension_file) {
            if (kind == .skill or kind == .prompt or kind == .theme or hasSupportedExtensionFile(path) or package_extension_file) {
                try appendResolvedResource(allocator, target, path, enabled, seed);
            }
        }
        return;
    }
    if (stat.kind != .directory) return;

    if (kind == .skill) {
        try collectSkillFiles(allocator, io, target, diagnostics, path, enabled, seed);
        return;
    }

    var files = std.ArrayList([]u8).empty;
    defer {
        for (files.items) |item| allocator.free(item);
        files.deinit(allocator);
    }
    try collectRecursiveFiles(allocator, io, path, kind, &files);
    for (files.items) |file_path| {
        try appendResolvedResource(allocator, target, file_path, enabled, seed);
    }
}

fn collectSkillFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    dir_path: []const u8,
    enabled: bool,
    seed: MetadataSeed,
) !void {
    const skill_marker = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, "SKILL.md" });
    defer allocator.free(skill_marker);
    if (pathExists(io, skill_marker)) {
        try appendResolvedResource(allocator, target, skill_marker, enabled, seed);
        return;
    }

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "failed to open skills directory", dir_path));
        return;
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .directory) {
            const subdir = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            defer allocator.free(subdir);
            try collectSkillFiles(allocator, io, target, diagnostics, subdir, enabled, seed);
            continue;
        }
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(file_path);
        try appendResolvedResource(allocator, target, file_path, enabled, seed);
    }
}

fn collectAgentSkillFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    target: *std.ArrayList(ResolvedResource),
    diagnostics: *std.ArrayList(Diagnostic),
    dir_path: []const u8,
    enabled: bool,
    seed: MetadataSeed,
) !void {
    const skill_marker = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, "SKILL.md" });
    defer allocator.free(skill_marker);
    if (pathExists(io, skill_marker)) {
        try appendResolvedResource(allocator, target, skill_marker, enabled, seed);
        return;
    }

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "failed to open skills directory", dir_path));
        return;
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;

        const subdir = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(subdir);
        try collectAgentSkillFiles(allocator, io, target, diagnostics, subdir, enabled, seed);
    }
}

fn collectRecursiveFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    kind: ResourceKind,
    files: *std.ArrayList([]u8),
) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const child_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(child_path);
        switch (entry.kind) {
            .directory => try collectRecursiveFiles(allocator, io, child_path, kind, files),
            .file => {
                if (kind == .extension) {
                    if (!hasSupportedExtensionFile(entry.name)) continue;
                } else if (!std.mem.endsWith(u8, entry.name, kind.fileExtension())) {
                    continue;
                }
                try files.append(allocator, try allocator.dupe(u8, child_path));
            },
            else => {},
        }
    }
}

fn appendResolvedResource(
    allocator: std.mem.Allocator,
    target: *std.ArrayList(ResolvedResource),
    path: []const u8,
    enabled: bool,
    seed: MetadataSeed,
) !void {
    for (target.items) |existing| {
        if (std.mem.eql(u8, existing.path, path)) return;
    }

    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try target.append(allocator, .{
        .path = owned_path,
        .enabled = enabled,
        .source_info = .{
            .path = try allocator.dupe(u8, path),
            .source = try allocator.dupe(u8, seed.source),
            .scope = seed.scope,
            .origin = seed.origin,
            .base_dir = try allocator.dupe(u8, seed.base_dir),
            .provenance = if (seed.provenance) |value| try value.clone(allocator) else null,
        },
        .discovery_index = target.items.len,
    });
}

fn precedence(resource: ResolvedResource) usize {
    if (resource.source_info.scope == .temporary) return 0;
    if (resource.source_info.origin == .package) return 5;
    if (resource.source_info.scope == .project) {
        if (std.mem.eql(u8, resource.source_info.source, "local")) return 1;
        return 2;
    }
    if (std.mem.eql(u8, resource.source_info.source, "local")) return 3;
    return 4;
}

fn sortResolved(items: []ResolvedResource) void {
    std.mem.sort(ResolvedResource, items, {}, struct {
        fn lessThan(_: void, lhs: ResolvedResource, rhs: ResolvedResource) bool {
            const left_rank = precedence(lhs);
            const right_rank = precedence(rhs);
            if (left_rank != right_rank) return left_rank < right_rank;
            if (isExplicitCliResolvedResource(lhs) and isExplicitCliResolvedResource(rhs)) {
                return lhs.discovery_index < rhs.discovery_index;
            }
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lessThan);
}

fn isExplicitCliResource(kind: ResourceKind, seed: MetadataSeed) bool {
    return kind == .extension and
        seed.scope == .temporary and
        seed.origin == .top_level and
        std.mem.eql(u8, seed.source, "local");
}

fn isExplicitCliResolvedResource(resource: ResolvedResource) bool {
    return resource.source_info.scope == .temporary and
        resource.source_info.origin == .top_level and
        std.mem.eql(u8, resource.source_info.source, "local");
}

const Manifest = struct {
    extension_entries: ?[][]u8 = null,
    skill_entries: ?[][]u8 = null,
    prompt_entries: ?[][]u8 = null,
    theme_entries: ?[][]u8 = null,

    fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        if (self.extension_entries) |entries| freeOwnedStringArray(allocator, entries);
        if (self.skill_entries) |entries| freeOwnedStringArray(allocator, entries);
        if (self.prompt_entries) |entries| freeOwnedStringArray(allocator, entries);
        if (self.theme_entries) |entries| freeOwnedStringArray(allocator, entries);
        self.* = .{};
    }
};

fn readPiManifest(allocator: std.mem.Allocator, io: std.Io, package_root: []const u8) !Manifest {
    const package_json_path = try std.fs.path.join(allocator, &[_][]const u8{ package_root, "package.json" });
    defer allocator.free(package_json_path);

    const bytes = readOptionalFile(allocator, io, package_json_path) catch return .{};
    defer if (bytes) |value| allocator.free(value);
    if (bytes == null) return .{};

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes.?, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const pi_value = parsed.value.object.get("pi") orelse return .{};
    if (pi_value != .object) return .{};

    return .{
        .extension_entries = try parseStringArrayOwned(allocator, pi_value.object.get("extensions")),
        .skill_entries = try parseStringArrayOwned(allocator, pi_value.object.get("skills")),
        .prompt_entries = try parseStringArrayOwned(allocator, pi_value.object.get("prompts")),
        .theme_entries = try parseStringArrayOwned(allocator, pi_value.object.get("themes")),
    };
}

fn loadSkills(
    allocator: std.mem.Allocator,
    io: std.Io,
    resources: []const ResolvedResource,
    diagnostics: *std.ArrayList(Diagnostic),
    errors: *std.ArrayList(config_errors.ConfigError),
) ![]Skill {
    var skills = std.ArrayList(Skill).empty;
    errdefer deinitSkillsList(allocator, &skills);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (resources) |resource| {
        if (!resource.enabled) continue;
        const skill = try loadSkillFromFile(allocator, io, resource, diagnostics, errors) orelse continue;
        const gop = try seen.getOrPut(skill.name);
        if (gop.found_existing) {
            var duplicate = skill;
            duplicate.deinit(allocator);
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "collision", "skill name collision", resource.path));
            continue;
        }
        try skills.append(allocator, skill);
    }

    return try skills.toOwnedSlice(allocator);
}

fn loadPromptTemplates(
    allocator: std.mem.Allocator,
    io: std.Io,
    resources: []const ResolvedResource,
    diagnostics: *std.ArrayList(Diagnostic),
    errors: *std.ArrayList(config_errors.ConfigError),
) ![]PromptTemplate {
    var templates = std.ArrayList(PromptTemplate).empty;
    errdefer deinitPromptTemplatesList(allocator, &templates);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (resources) |resource| {
        if (!resource.enabled) continue;
        const template = try loadPromptTemplateFromFile(allocator, io, resource, errors) orelse continue;
        const gop = try seen.getOrPut(template.name);
        if (gop.found_existing) {
            var duplicate = template;
            duplicate.deinit(allocator);
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "collision", "prompt template name collision", resource.path));
            continue;
        }
        try templates.append(allocator, template);
    }

    return try templates.toOwnedSlice(allocator);
}

fn loadThemes(
    allocator: std.mem.Allocator,
    io: std.Io,
    resources: []const ResolvedResource,
    diagnostics: *std.ArrayList(Diagnostic),
    errors: *std.ArrayList(config_errors.ConfigError),
) ![]Theme {
    var themes = std.ArrayList(Theme).empty;
    errdefer deinitThemesList(allocator, &themes);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (resources) |resource| {
        if (!resource.enabled) continue;
        const theme = try loadThemeFromFile(allocator, io, resource, errors) orelse continue;
        const gop = try seen.getOrPut(theme.name);
        if (gop.found_existing) {
            var duplicate = theme;
            duplicate.deinit(allocator);
            try diagnostics.append(allocator, try makeDiagnostic(allocator, "collision", "theme name collision", resource.path));
            continue;
        }
        try themes.append(allocator, theme);
    }

    return try themes.toOwnedSlice(allocator);
}

fn loadSkillFromFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    resource: ResolvedResource,
    diagnostics: *std.ArrayList(Diagnostic),
    errors: *std.ArrayList(config_errors.ConfigError),
) !?Skill {
    const bytes = readOptionalFile(allocator, io, resource.path) catch |err| {
        try config_errors.appendError(allocator, errors, .skill, resource.path, err);
        return null;
    };
    defer if (bytes) |value| allocator.free(value);
    if (bytes == null) return null;

    const parsed = try parseFrontmatter(allocator, bytes.?);
    defer parsed.deinit(allocator);
    const description = parsed.description orelse {
        try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "skill description is required", resource.path));
        return null;
    };

    const base_dir = std.fs.path.dirname(resource.path) orelse ".";
    const parent_name = std.fs.path.basename(base_dir);
    const skill_name = parsed.name orelse parent_name;

    return .{
        .name = try allocator.dupe(u8, skill_name),
        .description = try allocator.dupe(u8, description),
        .file_path = try allocator.dupe(u8, resource.path),
        .base_dir = try allocator.dupe(u8, base_dir),
        .source_info = try resource.source_info.clone(allocator),
        .disable_model_invocation = parsed.disable_model_invocation,
    };
}

fn loadPromptTemplateFromFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    resource: ResolvedResource,
    errors: *std.ArrayList(config_errors.ConfigError),
) !?PromptTemplate {
    const bytes = readOptionalFile(allocator, io, resource.path) catch |err| {
        try config_errors.appendError(allocator, errors, .prompt, resource.path, err);
        return null;
    };
    defer if (bytes) |value| allocator.free(value);
    if (bytes == null) return null;

    const parsed = try parseFrontmatter(allocator, bytes.?);
    defer parsed.deinit(allocator);

    const name = trimExtension(std.fs.path.basename(resource.path), ".md");
    const description = if (parsed.description) |value|
        value
    else
        firstNonEmptyLine(parsed.body) orelse name;

    return .{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .argument_hint = if (parsed.argument_hint) |value| try allocator.dupe(u8, value) else null,
        .content = try allocator.dupe(u8, parsed.body),
        .file_path = try allocator.dupe(u8, resource.path),
        .source_info = try resource.source_info.clone(allocator),
    };
}

fn loadThemeFromFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    resource: ResolvedResource,
    errors: *std.ArrayList(config_errors.ConfigError),
) !?Theme {
    const bytes = readOptionalFile(allocator, io, resource.path) catch |err| {
        try config_errors.appendError(allocator, errors, .theme, resource.path, err);
        return null;
    };
    defer if (bytes) |value| allocator.free(value);
    if (bytes == null) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes.?, .{}) catch |err| {
        try config_errors.appendError(allocator, errors, .theme, resource.path, err);
        return null;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const base_theme_name = if (parsed.value.object.get("base")) |value|
        if (value == .string) value.string else "dark"
    else
        "dark";

    var theme = if (std.mem.eql(u8, base_theme_name, "light"))
        try Theme.initLight(allocator)
    else if (std.mem.eql(u8, base_theme_name, "codex"))
        try Theme.initCodex(allocator)
    else
        try Theme.initDefault(allocator);
    errdefer theme.deinit(allocator);
    allocator.free(theme.name);
    theme.name = try allocator.dupe(u8, trimExtension(std.fs.path.basename(resource.path), ".json"));

    if (parsed.value.object.get("name")) |value| {
        if (value == .string) {
            allocator.free(theme.name);
            theme.name = try allocator.dupe(u8, value.string);
        }
    }

    if (parsed.value.object.get("colors")) |value| {
        if (value == .object) {
            var iterator = value.object.iterator();
            while (iterator.next()) |entry| {
                const color = parseThemeColor(entry.key_ptr.*) orelse continue;
                if (entry.value_ptr.* != .string) continue;
                try theme.setColor(allocator, color, entry.value_ptr.string);
            }
            try theme.applyDerivedStyles(allocator);
        }
    }

    if (parsed.value.object.get("tokens")) |value| {
        if (value == .object) {
            var iterator = value.object.iterator();
            while (iterator.next()) |entry| {
                const token = parseThemeToken(entry.key_ptr.*) orelse continue;
                if (entry.value_ptr.* != .object) continue;
                const object = entry.value_ptr.object;
                var style = &theme.styles[@intFromEnum(token)];
                if (object.get("fg")) |field| {
                    if (field == .string) {
                        if (style.fg) |existing| allocator.free(existing);
                        style.fg = try allocator.dupe(u8, field.string);
                    }
                }
                if (object.get("bg")) |field| {
                    if (field == .string) {
                        if (style.bg) |existing| allocator.free(existing);
                        style.bg = try allocator.dupe(u8, field.string);
                    }
                }
                if (object.get("bold")) |field| {
                    if (field == .bool) style.bold = field.bool;
                }
                if (object.get("dim")) |field| {
                    if (field == .bool) style.dim = field.bool;
                }
                if (object.get("italic")) |field| {
                    if (field == .bool) style.italic = field.bool;
                }
                if (object.get("underline")) |field| {
                    if (field == .bool) style.underline = field.bool;
                }
            }
        }
    }

    return theme;
}

const FrontmatterParseResult = struct {
    name: ?[]u8 = null,
    description: ?[]u8 = null,
    argument_hint: ?[]u8 = null,
    disable_model_invocation: bool = false,
    body: []u8,

    fn deinit(self: *const FrontmatterParseResult, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.description) |value| allocator.free(value);
        if (self.argument_hint) |value| allocator.free(value);
        allocator.free(self.body);
    }
};

fn parseFrontmatter(allocator: std.mem.Allocator, content: []const u8) !FrontmatterParseResult {
    if (!std.mem.startsWith(u8, content, "---")) {
        return .{ .body = try allocator.dupe(u8, content) };
    }

    const line_break = std.mem.indexOfScalar(u8, content, '\n') orelse return .{ .body = try allocator.dupe(u8, content) };
    const marker = "\n---";
    const end_index = std.mem.indexOfPos(u8, content, line_break + 1, marker) orelse return .{ .body = try allocator.dupe(u8, content) };
    const header = content[line_break + 1 .. end_index];
    var result = FrontmatterParseResult{
        .body = try allocator.dupe(u8, std.mem.trim(u8, content[end_index + marker.len ..], "\r\n")),
    };
    errdefer result.deinit(allocator);

    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        const colon_index = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon_index], " \t");
        const value = std.mem.trim(u8, line[colon_index + 1 ..], " \t\"");
        if (std.mem.eql(u8, key, "name")) {
            result.name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "description")) {
            result.description = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "argument-hint")) {
            result.argument_hint = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "disable-model-invocation")) {
            result.disable_model_invocation = std.mem.eql(u8, value, "true");
        }
    }

    return result;
}

fn parseSource(source: []const u8) ParsedSource {
    if (std.mem.startsWith(u8, source, "npm:")) {
        const spec = std.mem.trim(u8, source["npm:".len..], " ");
        return .{ .npm = .{ .name = parseNpmName(spec), .spec = spec } };
    }
    if (std.mem.startsWith(u8, source, "git:")) {
        return .{ .git = .{ .normalized = std.mem.trim(u8, source["git:".len..], " ") } };
    }
    if (isGitUrlSource(source)) {
        return .{ .git = .{ .normalized = std.mem.trim(u8, source, " ") } };
    }
    if (std.mem.startsWith(u8, source, "local:")) {
        return .{ .local = .{ .path = std.mem.trim(u8, source["local:".len..], " ") } };
    }
    return .{ .local = .{ .path = source } };
}

fn isGitUrlSource(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "https://") or
        std.mem.startsWith(u8, source, "http://") or
        std.mem.startsWith(u8, source, "ssh://") or
        std.mem.startsWith(u8, source, "git://");
}

fn parseNpmName(spec: []const u8) []const u8 {
    if (spec.len == 0) return spec;
    if (spec[0] == '@') {
        const at_index = std.mem.lastIndexOfScalar(u8, spec, '@') orelse return spec;
        if (std.mem.indexOfScalar(u8, spec, '/')) |slash_index| {
            if (at_index > slash_index) return spec[0..at_index];
        }
        return spec;
    }
    const at_index = std.mem.lastIndexOfScalar(u8, spec, '@') orelse return spec;
    return spec[0..at_index];
}

fn npmInstallPath(
    allocator: std.mem.Allocator,
    scope: SourceScope,
    cwd: []const u8,
    agent_dir: []const u8,
    package_name: []const u8,
) ![]u8 {
    const base = switch (scope) {
        .project => try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "packages", "npm", "node_modules" }),
        .user => try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "packages", "npm", "node_modules" }),
        .temporary => try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "packages", "tmp", "npm", "node_modules" }),
    };
    defer allocator.free(base);
    return std.fs.path.join(allocator, &[_][]const u8{ base, package_name });
}

fn gitInstallPath(
    allocator: std.mem.Allocator,
    scope: SourceScope,
    cwd: []const u8,
    agent_dir: []const u8,
    normalized_source: []const u8,
) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(normalized_source, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const hex = try std.fmt.allocPrint(allocator, "{s}", .{digest_hex[0..]});
    defer allocator.free(hex);
    const base = switch (scope) {
        .project => try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "packages", "git" }),
        .user => try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "packages", "git" }),
        .temporary => try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "packages", "tmp", "git" }),
    };
    defer allocator.free(base);
    return std.fs.path.join(allocator, &[_][]const u8{ base, hex });
}

fn resolvePath(allocator: std.mem.Allocator, base_dir: []const u8, input: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(input)) return allocator.dupe(u8, input);
    return std.fs.path.resolve(allocator, &[_][]const u8{ base_dir, input });
}

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch return false;
    return true;
}

fn readOptionalFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn userAgentsSkillsDir(allocator: std.mem.Allocator, env_map: ?*const std.process.Environ.Map) !?[]u8 {
    const home = resourceEnvValue(env_map, "HOME") orelse return null;
    return @as(?[]u8, try std.fs.path.join(allocator, &[_][]const u8{ home, ".agents", "skills" }));
}

fn collectAncestorAgentSkillDirs(
    allocator: std.mem.Allocator,
    io: std.Io,
    start_dir: []const u8,
    out: *std.ArrayList([]u8),
) !void {
    var current = if (std.fs.path.isAbsolute(start_dir))
        try allocator.dupe(u8, start_dir)
    else
        try std.fs.path.resolve(allocator, &[_][]const u8{start_dir});
    defer allocator.free(current);

    const git_root = try findGitRepoRoot(allocator, io, current);
    defer if (git_root) |path| allocator.free(path);

    while (true) {
        try out.append(allocator, try std.fs.path.join(allocator, &[_][]const u8{ current, ".agents", "skills" }));
        if (git_root) |root| {
            if (std.mem.eql(u8, current, root)) break;
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

fn findGitRepoRoot(allocator: std.mem.Allocator, io: std.Io, start_dir: []const u8) !?[]u8 {
    var current = try allocator.dupe(u8, start_dir);
    defer allocator.free(current);

    while (true) {
        const git_path = try std.fs.path.join(allocator, &[_][]const u8{ current, ".git" });
        defer allocator.free(git_path);
        if (pathExists(io, git_path)) {
            return try allocator.dupe(u8, current);
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    return null;
}

fn makeDiagnostic(allocator: std.mem.Allocator, kind: []const u8, message: []const u8, path: []const u8) !Diagnostic {
    const redacted_message = try redactDiagnosticValue(allocator, message);
    errdefer allocator.free(redacted_message);
    const redacted_path = try redactDiagnosticValue(allocator, path);
    errdefer allocator.free(redacted_path);
    return .{
        .kind = try allocator.dupe(u8, kind),
        .message = redacted_message,
        .path = redacted_path,
    };
}

pub fn redactDiagnosticValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < value.len) {
        if (startsWithIgnoreCase(value[index..], "Bearer ")) {
            try out.writer.writeAll("Bearer [REDACTED]");
            index = skipUntilDelimiter(value, index + "Bearer ".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "api_key=")) {
            try out.writer.writeAll("api_key=[REDACTED]");
            index = skipUntilDelimiter(value, index + "api_key=".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "access_token=")) {
            try out.writer.writeAll("access_token=[REDACTED]");
            index = skipUntilDelimiter(value, index + "access_token=".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "token=")) {
            try out.writer.writeAll("token=[REDACTED]");
            index = skipUntilDelimiter(value, index + "token=".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "x-api-key:")) {
            try out.writer.writeAll("x-api-key: [REDACTED]");
            index = skipUntilDelimiter(value, index + "x-api-key:".len);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "sk-")) {
            try out.writer.writeAll("[REDACTED]");
            index = skipUntilDelimiter(value, index);
            continue;
        }
        if (startsWithIgnoreCase(value[index..], "secret")) {
            try out.writer.writeAll("[REDACTED]");
            index += "secret".len;
            continue;
        }
        try out.writer.writeByte(value[index]);
        index += 1;
    }
    return out.toOwnedSlice();
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn skipUntilDelimiter(value: []const u8, start: usize) usize {
    var index = start;
    while (index < value.len) : (index += 1) {
        switch (value[index]) {
            ' ', '\t', '\r', '\n', '&', '"', '\'', ',', ')' => return index,
            else => {},
        }
    }
    return index;
}

fn cloneDiagnostic(allocator: std.mem.Allocator, diagnostic: Diagnostic) !Diagnostic {
    return .{
        .kind = try allocator.dupe(u8, diagnostic.kind),
        .message = try allocator.dupe(u8, diagnostic.message),
        .path = if (diagnostic.path) |value| try allocator.dupe(u8, value) else null,
    };
}

fn hasSupportedExtensionFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".js");
}

fn trimExtension(name: []const u8, extension: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, extension)) return name[0 .. name.len - extension.len];
    return name;
}

fn firstNonEmptyLine(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

fn parseThemeToken(name: []const u8) ?ThemeToken {
    if (std.mem.eql(u8, name, "welcome")) return .welcome;
    if (std.mem.eql(u8, name, "user")) return .user;
    if (std.mem.eql(u8, name, "assistant")) return .assistant;
    if (std.mem.eql(u8, name, "toolCall")) return .tool_call;
    if (std.mem.eql(u8, name, "toolResult")) return .tool_result;
    if (std.mem.eql(u8, name, "error")) return .@"error";
    if (std.mem.eql(u8, name, "status")) return .status;
    if (std.mem.eql(u8, name, "footer")) return .footer;
    if (std.mem.eql(u8, name, "prompt")) return .prompt;
    if (std.mem.eql(u8, name, "boxBorder")) return .box_border;
    if (std.mem.eql(u8, name, "text")) return .text;
    if (std.mem.eql(u8, name, "editor")) return .editor;
    if (std.mem.eql(u8, name, "editorCursor")) return .editor_cursor;
    if (std.mem.eql(u8, name, "selectSelected")) return .select_selected;
    if (std.mem.eql(u8, name, "selectDescription")) return .select_description;
    if (std.mem.eql(u8, name, "selectScroll")) return .select_scroll;
    if (std.mem.eql(u8, name, "selectEmpty")) return .select_empty;
    if (std.mem.eql(u8, name, "markdownText")) return .markdown_text;
    if (std.mem.eql(u8, name, "markdownHeading")) return .markdown_heading;
    if (std.mem.eql(u8, name, "markdownLink")) return .markdown_link;
    if (std.mem.eql(u8, name, "markdownCode")) return .markdown_code;
    if (std.mem.eql(u8, name, "markdownCodeBorder")) return .markdown_code_border;
    if (std.mem.eql(u8, name, "markdownQuote")) return .markdown_quote;
    if (std.mem.eql(u8, name, "markdownQuoteBorder")) return .markdown_quote_border;
    if (std.mem.eql(u8, name, "markdownListBullet")) return .markdown_list_bullet;
    if (std.mem.eql(u8, name, "markdownRule")) return .markdown_rule;
    if (std.mem.eql(u8, name, "overlayTitle")) return .overlay_title;
    if (std.mem.eql(u8, name, "overlayHint")) return .overlay_hint;
    if (std.mem.eql(u8, name, "promptGlyph")) return .prompt_glyph;
    if (std.mem.eql(u8, name, "promptBorder")) return .prompt_border;
    if (std.mem.eql(u8, name, "taskHeader")) return .task_header;
    if (std.mem.eql(u8, name, "taskHeaderAccent")) return .task_header_accent;
    if (std.mem.eql(u8, name, "taskHeaderSeparator")) return .task_header_separator;
    if (std.mem.eql(u8, name, "role_user") or std.mem.eql(u8, name, "roleUser")) return .role_user;
    if (std.mem.eql(u8, name, "role_assistant") or std.mem.eql(u8, name, "roleAssistant")) return .role_assistant;
    if (std.mem.eql(u8, name, "role_thinking") or std.mem.eql(u8, name, "roleThinking")) return .role_thinking;
    if (std.mem.eql(u8, name, "role_tool_call") or std.mem.eql(u8, name, "roleToolCall")) return .role_tool_call;
    if (std.mem.eql(u8, name, "role_tool_result") or std.mem.eql(u8, name, "roleToolResult")) return .role_tool_result;
    if (std.mem.eql(u8, name, "role_thinking_glyph") or std.mem.eql(u8, name, "roleThinkingGlyph")) return .role_thinking_glyph;
    if (std.mem.eql(u8, name, "terminalBadge")) return .terminal_badge;
    return null;
}

fn parseThemeColor(name: []const u8) ?ThemeColor {
    const aliases = [_]struct { []const u8, ThemeColor }{
        .{ "primary", .primary },
        .{ "secondary", .secondary },
        .{ "success", .success },
        .{ "warning", .warning },
        .{ "error", .@"error" },
        .{ "background", .background },
        .{ "foreground", .foreground },
        .{ "border", .border },
        .{ "muted", .muted },
        .{ "dim", .dim },
        .{ "thinkingText", .thinking_text },
        .{ "thinking_text", .thinking_text },
        .{ "selectedBg", .selected_bg },
        .{ "selected_bg", .selected_bg },
        .{ "userMessageBg", .user_message_bg },
        .{ "user_message_bg", .user_message_bg },
        .{ "customMessageBg", .custom_message_bg },
        .{ "custom_message_bg", .custom_message_bg },
        .{ "toolPendingBg", .tool_pending_bg },
        .{ "tool_pending_bg", .tool_pending_bg },
        .{ "toolSuccessBg", .tool_success_bg },
        .{ "tool_success_bg", .tool_success_bg },
        .{ "toolErrorBg", .tool_error_bg },
        .{ "tool_error_bg", .tool_error_bg },
        .{ "borderAccent", .border_accent },
        .{ "border_accent", .border_accent },
        .{ "borderMuted", .border_muted },
        .{ "border_muted", .border_muted },
        .{ "mdHeading", .markdown_heading },
        .{ "markdownHeading", .markdown_heading },
        .{ "markdown_heading", .markdown_heading },
        .{ "mdLink", .markdown_link },
        .{ "markdownLink", .markdown_link },
        .{ "markdown_link", .markdown_link },
        .{ "mdCode", .markdown_code },
        .{ "markdownCode", .markdown_code },
        .{ "markdown_code", .markdown_code },
        .{ "mdCodeBlockBorder", .markdown_code_border },
        .{ "markdownCodeBorder", .markdown_code_border },
        .{ "markdown_code_border", .markdown_code_border },
        .{ "mdQuote", .markdown_quote },
        .{ "markdownQuote", .markdown_quote },
        .{ "markdown_quote", .markdown_quote },
        .{ "mdQuoteBorder", .markdown_quote_border },
        .{ "markdownQuoteBorder", .markdown_quote_border },
        .{ "markdown_quote_border", .markdown_quote_border },
        .{ "mdHr", .markdown_rule },
        .{ "markdownRule", .markdown_rule },
        .{ "markdown_rule", .markdown_rule },
        .{ "mdListBullet", .markdown_list_bullet },
        .{ "markdownListBullet", .markdown_list_bullet },
        .{ "markdown_list_bullet", .markdown_list_bullet },
        .{ "toolOutput", .tool_output },
        .{ "tool_output", .tool_output },
    };
    for (aliases) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

test "roles m0 parseThemeToken accepts role token names" {
    try std.testing.expectEqual(ThemeToken.role_user, parseThemeToken("role_user").?);
    try std.testing.expectEqual(ThemeToken.role_assistant, parseThemeToken("role_assistant").?);
    try std.testing.expectEqual(ThemeToken.role_thinking, parseThemeToken("role_thinking").?);
    try std.testing.expectEqual(ThemeToken.role_tool_call, parseThemeToken("role_tool_call").?);
    try std.testing.expectEqual(ThemeToken.role_tool_result, parseThemeToken("role_tool_result").?);
    try std.testing.expectEqual(ThemeToken.role_thinking_glyph, parseThemeToken("role_thinking_glyph").?);
    try std.testing.expectEqual(ThemeToken.role_tool_result, parseThemeToken("roleToolResult").?);
}

pub fn findThemeIndex(themes: []const Theme, name: ?[]const u8) ?usize {
    const theme_name = name orelse return null;
    for (themes, 0..) |theme, index| {
        if (std.mem.eql(u8, theme.name, theme_name)) return index;
    }
    return null;
}

const SlicePlaceholder = struct {
    start_index: usize,
    length: ?usize,
    consumed_len: usize,
};

fn parseSlicePlaceholder(text: []const u8) ?SlicePlaceholder {
    var index: usize = "${@:".len;
    var end = index;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    if (end == index or end >= text.len) return null;
    const start_value = std.fmt.parseInt(usize, text[index..end], 10) catch return null;
    var length: ?usize = null;
    index = end;
    if (index < text.len and text[index] == ':') {
        index += 1;
        end = index;
        while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
        if (end == index) return null;
        length = std.fmt.parseInt(usize, text[index..end], 10) catch return null;
        index = end;
    }
    if (index >= text.len or text[index] != '}') return null;
    return .{
        .start_index = if (start_value == 0) 0 else start_value - 1,
        .length = length,
        .consumed_len = index + 1,
    };
}

fn appendJoinedArgs(
    allocator: std.mem.Allocator,
    builder: *std.ArrayList(u8),
    args: []const []const u8,
    start_index: usize,
    length: ?usize,
) !void {
    const end_index = if (length) |value| @min(args.len, start_index + value) else args.len;
    for (args[start_index..end_index], 0..) |arg, index| {
        if (index > 0) try builder.append(allocator, ' ');
        try builder.appendSlice(allocator, arg);
    }
}

fn appendColorAnsi(allocator: std.mem.Allocator, builder: *std.ArrayList(u8), value: []const u8, foreground: bool) !void {
    if (parseNamedColor(value)) |named| {
        const prefix = if (foreground) "\x1b[3" else "\x1b[4";
        const color_text = try std.fmt.allocPrint(allocator, "{s}{d}m", .{ prefix, named });
        defer allocator.free(color_text);
        try builder.appendSlice(allocator, color_text);
        return;
    }
    if (value.len == 7 and value[0] == '#') {
        const r = std.fmt.parseInt(u8, value[1..3], 16) catch return;
        const g = std.fmt.parseInt(u8, value[3..5], 16) catch return;
        const b = std.fmt.parseInt(u8, value[5..7], 16) catch return;
        const ansi_text = if (foreground)
            try std.fmt.allocPrint(allocator, "\x1b[38;2;{d};{d};{d}m", .{ r, g, b })
        else
            try std.fmt.allocPrint(allocator, "\x1b[48;2;{d};{d};{d}m", .{ r, g, b });
        defer allocator.free(ansi_text);
        try builder.appendSlice(allocator, ansi_text);
    }
}

fn parseNamedColor(value: []const u8) ?u8 {
    if (std.mem.eql(u8, value, "black")) return 0;
    if (std.mem.eql(u8, value, "red")) return 1;
    if (std.mem.eql(u8, value, "green")) return 2;
    if (std.mem.eql(u8, value, "yellow")) return 3;
    if (std.mem.eql(u8, value, "blue")) return 4;
    if (std.mem.eql(u8, value, "magenta")) return 5;
    if (std.mem.eql(u8, value, "cyan")) return 6;
    if (std.mem.eql(u8, value, "white")) return 7;
    return null;
}

fn escapeXmlAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var builder = std.ArrayList(u8).empty;
    errdefer builder.deinit(allocator);
    for (text) |char| {
        switch (char) {
            '&' => try builder.appendSlice(allocator, "&amp;"),
            '<' => try builder.appendSlice(allocator, "&lt;"),
            '>' => try builder.appendSlice(allocator, "&gt;"),
            '"' => try builder.appendSlice(allocator, "&quot;"),
            '\'' => try builder.appendSlice(allocator, "&apos;"),
            else => try builder.append(allocator, char),
        }
    }
    return try builder.toOwnedSlice(allocator);
}

fn parseStringArrayOwned(allocator: std.mem.Allocator, value: ?std.json.Value) !?[][]u8 {
    const actual = value orelse return null;
    if (actual != .array) return null;

    var items = std.ArrayList([]u8).empty;
    errdefer freeOwnedStringArrayList(allocator, &items);
    for (actual.array.items) |item| {
        if (item != .string) continue;
        try items.append(allocator, try allocator.dupe(u8, item.string));
    }
    return try items.toOwnedSlice(allocator);
}

fn cloneStringList(allocator: std.mem.Allocator, input: ?[]const []const u8) !?[]const []const u8 {
    const items = input orelse return null;
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }
    for (items) |item| try list.append(allocator, try allocator.dupe(u8, item));
    return try list.toOwnedSlice(allocator);
}

fn freeStringList(allocator: std.mem.Allocator, input: ?[]const []const u8) void {
    const items = input orelse return;
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn freeOwnedStringArray(allocator: std.mem.Allocator, input: [][]u8) void {
    for (input) |item| allocator.free(item);
    allocator.free(input);
}

fn freeOwnedStringArrayList(allocator: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit(allocator);
}

fn cloneWasmManifest(allocator: std.mem.Allocator, manifest: wasm_manifest.Manifest) !wasm_manifest.Manifest {
    const package_root = try allocator.dupe(u8, manifest.package_root);
    errdefer allocator.free(package_root);
    const manifest_path = try allocator.dupe(u8, manifest.manifest_path);
    errdefer allocator.free(manifest_path);
    const schema_version = try allocator.dupe(u8, manifest.schema_version);
    errdefer allocator.free(schema_version);
    const id = try allocator.dupe(u8, manifest.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, manifest.name);
    errdefer allocator.free(name);
    const version = try allocator.dupe(u8, manifest.version);
    errdefer allocator.free(version);
    const description = try allocator.dupe(u8, manifest.description);
    errdefer allocator.free(description);
    const artifact_path = try allocator.dupe(u8, manifest.artifact_path);
    errdefer allocator.free(artifact_path);
    const artifact_absolute_path = try allocator.dupe(u8, manifest.artifact_absolute_path);
    errdefer allocator.free(artifact_absolute_path);
    const artifact_sha256 = try allocator.dupe(u8, manifest.artifact_sha256);
    errdefer allocator.free(artifact_sha256);
    const package_root_sha256 = try allocator.dupe(u8, manifest.package_root_sha256);
    errdefer allocator.free(package_root_sha256);
    const tool_id = try allocator.dupe(u8, manifest.tool_id);
    errdefer allocator.free(tool_id);
    const tool_description = try allocator.dupe(u8, manifest.tool_description);
    errdefer allocator.free(tool_description);
    const input_schema_json = try allocator.dupe(u8, manifest.input_schema_json);
    errdefer allocator.free(input_schema_json);
    const output_schema_json = try allocator.dupe(u8, manifest.output_schema_json);
    errdefer allocator.free(output_schema_json);
    const requested_capabilities = try allocator.dupe(wasm_manifest.Capability, manifest.requested_capabilities);
    errdefer allocator.free(requested_capabilities);
    var resource_limits = try cloneWasmResourceLimits(allocator, manifest.resource_limits);
    errdefer resource_limits.deinit(allocator);

    return .{
        .package_root = package_root,
        .manifest_path = manifest_path,
        .schema_version = schema_version,
        .id = id,
        .name = name,
        .version = version,
        .description = description,
        .artifact_kind = manifest.artifact_kind,
        .artifact_path = artifact_path,
        .artifact_absolute_path = artifact_absolute_path,
        .artifact_sha256 = artifact_sha256,
        .package_root_sha256 = package_root_sha256,
        .tool_id = tool_id,
        .tool_description = tool_description,
        .input_schema_json = input_schema_json,
        .output_schema_json = output_schema_json,
        .requested_capabilities = requested_capabilities,
        .resource_limits = resource_limits,
    };
}

fn cloneWasmResourceLimits(allocator: std.mem.Allocator, limits: wasm_manifest.ResourceLimits) !wasm_manifest.ResourceLimits {
    const tool_scopes = try allocator.alloc([]u8, limits.tool_scopes.len);
    errdefer allocator.free(tool_scopes);
    for (limits.tool_scopes, 0..) |scope, index| {
        tool_scopes[index] = try allocator.dupe(u8, scope);
        errdefer allocator.free(tool_scopes[index]);
    }
    return .{
        .max_children = limits.max_children,
        .depth = limits.depth,
        .turns = limits.turns,
        .timeout_ms = limits.timeout_ms,
        .output_bytes = limits.output_bytes,
        .output_lines = limits.output_lines,
        .tool_scopes = tool_scopes,
    };
}

fn sliceConst(items: [][]u8) []const []const u8 {
    return @ptrCast(items);
}

fn deinitResolvedSlice(allocator: std.mem.Allocator, items: []ResolvedResource) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn deinitResolvedList(allocator: std.mem.Allocator, items: *std.ArrayList(ResolvedResource)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
}

fn deinitLockedWasmPackageList(allocator: std.mem.Allocator, items: *std.ArrayList(LockedWasmPackage)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
}

fn deinitLoadedExtensionsList(allocator: std.mem.Allocator, items: *std.ArrayList(LoadedExtension)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
}

fn deinitSkills(allocator: std.mem.Allocator, items: []Skill) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn deinitPromptTemplates(allocator: std.mem.Allocator, items: []PromptTemplate) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn deinitThemes(allocator: std.mem.Allocator, items: []Theme) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn deinitSkillsList(allocator: std.mem.Allocator, items: *std.ArrayList(Skill)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
}

fn deinitPromptTemplatesList(allocator: std.mem.Allocator, items: *std.ArrayList(PromptTemplate)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
}

fn deinitThemesList(allocator: std.mem.Allocator, items: *std.ArrayList(Theme)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
}

fn deinitDiagnosticsList(allocator: std.mem.Allocator, items: *std.ArrayList(Diagnostic)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
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

fn findResolvedResource(items: []const ResolvedResource, path: []const u8) ?ResolvedResource {
    for (items) |item| {
        if (std.mem.eql(u8, item.path, path)) return item;
    }
    return null;
}

test "explicit extension paths preserve order and diagnose invalid entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/first");
    try tmp.dir.createDirPath(std.testing.io, "repo/second");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/first/index.js", .data = "export default {};\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/second/index.js", .data = "export default {};\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/not-extension.txt", .data = "nope\n" });

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const first = try makeTmpPath(allocator, tmp, "repo/first");
    defer allocator.free(first);
    const second = try makeTmpPath(allocator, tmp, "repo/second");
    defer allocator.free(second);
    const missing = try makeTmpPath(allocator, tmp, "repo/missing");
    defer allocator.free(missing);
    const invalid_file = try makeTmpPath(allocator, tmp, "repo/not-extension.txt");
    defer allocator.free(invalid_file);

    var resolved = try resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = cwd,
        .cli_extensions = &.{ second, missing, first, second, invalid_file },
        .include_default_extensions = false,
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), resolved.extensions.len);
    try std.testing.expect(std.mem.endsWith(u8, resolved.extensions[0].path, "second/index.js"));
    try std.testing.expect(std.mem.endsWith(u8, resolved.extensions[1].path, "first/index.js"));
    try std.testing.expect(resourceDiagnosticContains(resolved.diagnostics, "explicit --extension path does not exist"));
    try std.testing.expect(resourceDiagnosticContains(resolved.diagnostics, "duplicate explicit --extension path skipped"));
    try std.testing.expect(resourceDiagnosticContains(resolved.diagnostics, "explicit --extension path is not a supported extension file or directory"));
}

fn resourceDiagnosticContains(diagnostics: []const Diagnostic, needle: []const u8) bool {
    for (diagnostics) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, needle) != null) return true;
    }
    return false;
}

test "resolveConfiguredResources loads local, npm, and git resource sources" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/extensions");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/prompts");
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent/packages/npm/node_modules/@demo/pkg/extensions");
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent/packages/npm/node_modules/@demo/pkg/skills/reviewer");
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent/packages/npm/node_modules/@demo/pkg/themes");

    const git_hash_source = "github.com/example/pi-theme";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(git_hash_source, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const git_hash = try std.fmt.allocPrint(allocator, "{s}", .{digest_hex[0..]});
    defer allocator.free(git_hash);
    const git_theme_dir = try std.fmt.allocPrint(allocator, "repo/.pi/packages/git/{s}/themes", .{git_hash});
    defer allocator.free(git_theme_dir);
    try tmp.dir.createDirPath(std.testing.io, git_theme_dir);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/extensions/local-extension.ts",
        .data = "export default {};\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/prompts/summarize.md",
        .data = "Summarize $ARGUMENTS",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/packages/npm/node_modules/@demo/pkg/package.json",
        .data =
        \\{
        \\  "pi": {
        \\    "extensions": ["extensions"],
        \\    "skills": ["skills"],
        \\    "themes": ["themes"]
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/packages/npm/node_modules/@demo/pkg/extensions/pkg-extension.ts",
        .data = "export default {};\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/packages/npm/node_modules/@demo/pkg/skills/reviewer/SKILL.md",
        .data =
        \\---
        \\description: Review code carefully
        \\---
        \\Read the diff before replying.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/packages/npm/node_modules/@demo/pkg/themes/pkg.json",
        .data =
        \\{
        \\  "name": "pkg-theme",
        \\  "tokens": {
        \\    "footer": { "fg": "cyan", "bold": true }
        \\  }
        \\}
        ,
    });
    const git_theme_file = try std.fmt.allocPrint(allocator, "{s}/theme.json", .{git_theme_dir});
    defer allocator.free(git_theme_file);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = git_theme_file,
        .data =
        \\{
        \\  "name": "git-theme"
        \\}
        ,
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    const npm_pkg = PackageSourceConfig{ .source = try allocator.dupe(u8, "npm:@demo/pkg") };
    defer {
        var owned = npm_pkg;
        owned.deinit(allocator);
    }
    const git_pkg = PackageSourceConfig{ .source = try allocator.dupe(u8, "git:github.com/example/pi-theme") };
    defer {
        var owned = git_pkg;
        owned.deinit(allocator);
    }

    var resolved = try resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .global = .{
            .packages = &.{npm_pkg},
        },
        .project = .{
            .extensions = &.{"extensions/local-extension.ts"},
            .prompts = &.{"prompts"},
            .packages = &.{git_pkg},
        },
        .include_default_skills = false,
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), resolved.extensions.len);
    try std.testing.expect(std.mem.indexOf(u8, resolved.extensions[0].path, "local-extension.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved.extensions[1].path, "pkg-extension.ts") != null);
    try std.testing.expectEqual(@as(usize, 1), resolved.skills.len);
    try std.testing.expect(std.mem.indexOf(u8, resolved.skills[0].path, "SKILL.md") != null);
    try std.testing.expectEqual(@as(usize, 1), resolved.prompts.len);
    try std.testing.expect(std.mem.indexOf(u8, resolved.prompts[0].path, "summarize.md") != null);
    try std.testing.expectEqual(@as(usize, 2), resolved.themes.len);
}

test "resolveConfiguredResources loads unified extension package resources without wasm lock" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/unified-pkg/extensions");
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/unified-pkg/package.json",
        .data =
        \\{
        \\  "pi": { "extensions": ["extensions/extension.ts"] }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/unified-pkg/pi-extension.json",
        .data =
        \\{
        \\  "schemaVersion": "pi-extension.v1",
        \\  "id": "com.example.unified",
        \\  "name": "Unified Package",
        \\  "version": "1.0.0",
        \\  "runtime": {
        \\    "kind": "process_jsonl",
        \\    "entrypoint": { "argv": ["node", "extensions/extension.ts"] }
        \\  },
        \\  "tools": []
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/unified-pkg/extensions/extension.ts",
        .data = "export default {};\n",
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const fixture_root = try makeTmpPath(allocator, tmp, "repo/fixtures/unified-pkg");
    defer allocator.free(fixture_root);

    var package_config = PackageSourceConfig{ .source = try allocator.dupe(u8, fixture_root) };
    defer package_config.deinit(allocator);

    var resolved = try resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .global = .{ .packages = &.{package_config} },
        .include_default_extensions = false,
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), resolved.extensions.len);
    try std.testing.expectEqual(@as(usize, 0), resolved.diagnostics.len);
    try std.testing.expect(std.mem.endsWith(u8, resolved.extensions[0].path, "extensions/extension.ts"));
    try std.testing.expect(resolved.extensions[0].source_info.provenance == null);
}

test "resolveConfiguredResources discovers project .agents skills up to git root" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/packages/feature");
    try tmp.dir.createDirPath(std.testing.io, "repo/.agents/skills/repo");
    try tmp.dir.createDirPath(std.testing.io, "repo/packages/.agents/skills/package");
    try tmp.dir.createDirPath(std.testing.io, ".agents/skills/above-repo");
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.agents/skills/repo/SKILL.md",
        .data = "---\nname: repo\ndescription: repo\n---\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/packages/.agents/skills/package/SKILL.md",
        .data = "---\nname: package\ndescription: package\n---\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".agents/skills/above-repo/SKILL.md",
        .data = "---\nname: above\ndescription: above\n---\n",
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo/packages/feature");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const repo_skill = try makeTmpPath(allocator, tmp, "repo/.agents/skills/repo/SKILL.md");
    defer allocator.free(repo_skill);
    const package_skill = try makeTmpPath(allocator, tmp, "repo/packages/.agents/skills/package/SKILL.md");
    defer allocator.free(package_skill);
    const above_repo_skill = try makeTmpPath(allocator, tmp, ".agents/skills/above-repo/SKILL.md");
    defer allocator.free(above_repo_skill);
    const repo_agents_base = try makeTmpPath(allocator, tmp, "repo/.agents");
    defer allocator.free(repo_agents_base);
    const package_agents_base = try makeTmpPath(allocator, tmp, "repo/packages/.agents");
    defer allocator.free(package_agents_base);

    var resolved = try resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .include_default_extensions = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer resolved.deinit(allocator);

    const repo_resource = findResolvedResource(resolved.skills, repo_skill).?;
    const package_resource = findResolvedResource(resolved.skills, package_skill).?;
    try std.testing.expect(findResolvedResource(resolved.skills, above_repo_skill) == null);
    try std.testing.expectEqual(.project, repo_resource.source_info.scope);
    try std.testing.expectEqual(.project, package_resource.source_info.scope);
    try std.testing.expectEqualStrings(repo_agents_base, repo_resource.source_info.base_dir.?);
    try std.testing.expectEqualStrings(package_agents_base, package_resource.source_info.base_dir.?);
}

test "resolveConfiguredResources discovers user .agents skills with .agents base dir" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/scratch/nested");
    try tmp.dir.createDirPath(std.testing.io, "home/.agents/skills/home-skill");
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.agents/skills/home-skill/SKILL.md",
        .data = "---\nname: home-skill\ndescription: home\n---\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.agents/skills/root-file.md",
        .data = "---\nname: root-file\ndescription: root file\n---\n",
    });

    const home = try makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home);
    const cwd = try makeTmpPath(allocator, tmp, "home/scratch/nested");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const skill_path = try makeTmpPath(allocator, tmp, "home/.agents/skills/home-skill/SKILL.md");
    defer allocator.free(skill_path);
    const root_markdown = try makeTmpPath(allocator, tmp, "home/.agents/skills/root-file.md");
    defer allocator.free(root_markdown);
    const agents_base = try makeTmpPath(allocator, tmp, "home/.agents");
    defer allocator.free(agents_base);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home);

    var resolved = try resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .env_map = &env_map,
        .include_default_extensions = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer resolved.deinit(allocator);

    const resource = findResolvedResource(resolved.skills, skill_path).?;
    try std.testing.expect(findResolvedResource(resolved.skills, root_markdown) == null);
    try std.testing.expectEqual(@as(usize, 1), resolved.skills.len);
    try std.testing.expectEqual(.user, resource.source_info.scope);
    try std.testing.expectEqualStrings("auto", resource.source_info.source);
    try std.testing.expectEqualStrings(agents_base, resource.source_info.base_dir.?);
}

test "resolveConfiguredResources denies wasm package resources without valid scope lock" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/wasm-pkg/extensions");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/wasm-pkg/wasm");
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/wasm-pkg/wasm/plugin.wasm",
        .data = "\x00asm",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/wasm-pkg/extensions/main.ts",
        .data = "export default {};\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/wasm-pkg/package.json",
        .data =
        \\{
        \\  "pi": { "extensions": ["extensions/main.ts"] }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/fixtures/wasm-pkg/pi-extension.json",
        .data =
        \\{
        \\  "schemaVersion": "pi-extension.v0",
        \\  "id": "com.example.locked-resource",
        \\  "name": "Locked Resource",
        \\  "version": "0.1.0",
        \\  "description": "Locked resource fixture.",
        \\  "artifact": { "kind": "wasm-component", "path": "wasm/plugin.wasm" },
        \\  "tool": {
        \\    "id": "example.lockedResource",
        \\    "description": "Locked resource tool.",
        \\    "inputSchema": {},
        \\    "outputSchema": {}
        \\  },
        \\  "capabilities": []
        \\}
        ,
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const fixture_root = try makeTmpPath(allocator, tmp, "repo/fixtures/wasm-pkg");
    defer allocator.free(fixture_root);

    var package_config = PackageSourceConfig{ .source = try allocator.dupe(u8, fixture_root) };
    defer package_config.deinit(allocator);

    var missing_lock = try resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .global = .{ .packages = &.{package_config} },
        .include_default_extensions = false,
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer missing_lock.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), missing_lock.extensions.len);
    try std.testing.expectEqual(@as(usize, 1), missing_lock.diagnostics.len);
    try std.testing.expectEqualStrings("missing_lockfile", missing_lock.diagnostics[0].kind);

    const lock_path = try provenance_lockfile.lockfilePath(allocator, .user, cwd, agent_dir);
    defer allocator.free(lock_path);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, agent_dir);
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = lock_path,
        .data = "{ malformed",
    });

    var malformed_lock = try resolveConfiguredResources(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .global = .{ .packages = &.{package_config} },
        .include_default_extensions = false,
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer malformed_lock.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), malformed_lock.extensions.len);
    try std.testing.expectEqual(@as(usize, 1), malformed_lock.diagnostics.len);
    try std.testing.expectEqualStrings("malformed_lockfile", malformed_lock.diagnostics[0].kind);
}

test "resolveConfiguredLockedWasmPackages discovers only configured scope locked packages" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/locked/wasm");
    try tmp.dir.createDirPath(std.testing.io, "repo/fixtures/unlocked/wasm");
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    const manifest_json =
        \\{
        \\  "schemaVersion": "pi-extension.v0",
        \\  "id": "com.example.locked-runtime",
        \\  "name": "Locked Runtime",
        \\  "version": "0.1.0",
        \\  "description": "Locked runtime fixture.",
        \\  "artifact": { "kind": "wasm-component", "path": "wasm/plugin.wasm" },
        \\  "tool": {
        \\    "id": "example.lockedRuntime",
        \\    "description": "Locked runtime tool.",
        \\    "inputSchema": {},
        \\    "outputSchema": {}
        \\  },
        \\  "capabilities": []
        \\}
    ;
    inline for (&.{ "locked", "unlocked" }) |name| {
        const manifest_path = try std.fmt.allocPrint(allocator, "repo/fixtures/{s}/pi-extension.json", .{name});
        defer allocator.free(manifest_path);
        const artifact_path = try std.fmt.allocPrint(allocator, "repo/fixtures/{s}/wasm/plugin.wasm", .{name});
        defer allocator.free(artifact_path);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = manifest_json });
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = artifact_path, .data = "\x00asm" });
    }

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const locked_root = try makeTmpPath(allocator, tmp, "repo/fixtures/locked");
    defer allocator.free(locked_root);
    const unlocked_root = try makeTmpPath(allocator, tmp, "repo/fixtures/unlocked");
    defer allocator.free(unlocked_root);

    var manifest_result = try wasm_manifest.validateManifestFileWithOptions(allocator, std.testing.io, locked_root, .{
        .approved_capabilities = wasm_manifest.CANONICAL_CAPABILITIES[0..],
    });
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    var lock_entry = try provenance_lockfile.createWasmLockEntry(allocator, .user, manifest_result.valid.package_root, &manifest_result.valid);
    defer lock_entry.deinit(allocator);
    const lock_path = try provenance_lockfile.lockfilePath(allocator, .user, cwd, agent_dir);
    defer allocator.free(lock_path);
    try provenance_lockfile.writeEntry(allocator, std.testing.io, .user, lock_path, lock_entry);

    var locked_config = PackageSourceConfig{ .source = try allocator.dupe(u8, locked_root) };
    defer locked_config.deinit(allocator);
    var unlocked_config = PackageSourceConfig{ .source = try allocator.dupe(u8, unlocked_root) };
    defer unlocked_config.deinit(allocator);

    var resolved = try resolveConfiguredLockedWasmPackages(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .global = .{ .packages = &.{ locked_config, unlocked_config } },
    });
    defer resolved.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), resolved.packages.len);
    try std.testing.expectEqualStrings("com.example.locked-runtime", resolved.packages[0].manifest.id);
    try std.testing.expectEqualStrings("example.lockedRuntime", resolved.packages[0].manifest.tool_id);
    try std.testing.expectEqual(provenance_lockfile.Scope.user, resolved.packages[0].lock_entry.scope);
    try std.testing.expectEqualStrings(locked_root, resolved.packages[0].source_info.base_dir.?);
    try std.testing.expectEqual(@as(usize, 1), resolved.diagnostics.len);
    try std.testing.expectEqualStrings("missing_lock_entry", resolved.diagnostics[0].kind);
}

test "loadResourceBundle loads skills templates and themes with selected theme" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/skills/reviewer");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/prompts");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/themes");

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/skills/reviewer/SKILL.md",
        .data =
        \\---
        \\description: Review changes before finalizing
        \\---
        \\Review the diff carefully.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/prompts/fix.md",
        .data =
        \\---
        \\description: Create a fix prompt
        \\argument-hint: issue
        \\---
        \\Fix $1 using $ARGUMENTS
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/themes/night.json",
        .data =
        \\{
        \\  "name": "night",
        \\  "tokens": {
        \\    "assistant": { "fg": "#00ffcc", "bold": true },
        \\    "footer": { "fg": "cyan" }
        \\  }
        \\}
        ,
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("TERM_PROGRAM", "Ghostty");

    var bundle = try loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .env_map = &env_map,
        .project = .{
            .skills = &.{"skills"},
            .prompts = &.{"prompts"},
            .themes = &.{"themes"},
            .theme = "night",
        },
    });
    defer bundle.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), bundle.skills.len);
    try std.testing.expectEqualStrings("reviewer", bundle.skills[0].name);
    try std.testing.expectEqual(@as(usize, 1), bundle.prompt_templates.len);
    try std.testing.expectEqualStrings("fix", bundle.prompt_templates[0].name);
    try std.testing.expectEqualStrings("night", bundle.selectedTheme().name);
    try std.testing.expectEqualStrings("ghostty", bundle.terminal_name);

    const expanded = try expandPromptTemplate(allocator, "/fix parser bug", bundle.prompt_templates);
    defer allocator.free(expanded);
    try std.testing.expectEqualStrings("Fix parser using parser bug", expanded);

    const prompt_text = try formatSkillsForPrompt(allocator, bundle.skills);
    defer allocator.free(prompt_text);
    try std.testing.expect(std.mem.indexOf(u8, prompt_text, "<available_skills>") != null);

    const styled = try bundle.selectedTheme().applyAlloc(allocator, .assistant, "Pi:");
    defer allocator.free(styled);
    try std.testing.expectEqualStrings("Pi:", styled);
}

test "expandSkillCommand strips frontmatter and appends arguments" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "skills/reviewer");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "skills/reviewer/SKILL.md",
        .data =
        \\---
        \\name: reviewer
        \\description: Review code
        \\---
        \\Use this skill body.
        \\
        ,
    });

    const skill_path = try makeTmpPath(allocator, tmp, "skills/reviewer/SKILL.md");
    defer allocator.free(skill_path);
    const base_dir = try makeTmpPath(allocator, tmp, "skills/reviewer");
    defer allocator.free(base_dir);
    var skill = Skill{
        .name = try allocator.dupe(u8, "reviewer"),
        .description = try allocator.dupe(u8, "Review code"),
        .file_path = try allocator.dupe(u8, skill_path),
        .base_dir = try allocator.dupe(u8, base_dir),
        .source_info = .{
            .path = try allocator.dupe(u8, skill_path),
            .source = try allocator.dupe(u8, "local"),
            .scope = .temporary,
            .origin = .top_level,
            .base_dir = try allocator.dupe(u8, base_dir),
        },
    };
    defer skill.deinit(allocator);

    const expanded = try expandSkillCommand(allocator, std.testing.io, "/skill:reviewer focus src", &.{skill});
    defer allocator.free(expanded);
    const expected = try std.fmt.allocPrint(
        allocator,
        "<skill name=\"reviewer\" location=\"{s}\">\nReferences are relative to {s}.\n\nUse this skill body.\n</skill>\n\nfocus src",
        .{ skill_path, base_dir },
    );
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, expanded);

    const unknown = try expandSkillCommand(allocator, std.testing.io, "/skill:missing", &.{skill});
    defer allocator.free(unknown);
    try std.testing.expectEqualStrings("/skill:missing", unknown);
}

test "loadResourceBundle exposes built-in dark light and codex themes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    var bundle = try loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
    });
    defer bundle.deinit(allocator);

    try std.testing.expect(findThemeIndex(bundle.themes, "dark") != null);
    try std.testing.expect(findThemeIndex(bundle.themes, "light") != null);
    try std.testing.expect(findThemeIndex(bundle.themes, "codex") != null);
}

test "loadResourceBundle merges extension discovered skills prompts and themes with normal lookup" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/ext-skills/review");
    try tmp.dir.createDirPath(std.testing.io, "repo/ext-prompts");
    try tmp.dir.createDirPath(std.testing.io, "repo/ext-themes");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/ext-skills/review/SKILL.md",
        .data =
        \\---
        \\name: ext-review
        \\description: Extension review skill
        \\---
        \\Use extension review instructions.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/ext-prompts/ext-review.md",
        .data = "Run the extension review prompt.",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/ext-themes/ext-theme.json",
        .data =
        \\{
        \\  "name": "ext-theme",
        \\  "base": "dark",
        \\  "colors": { "primary": "#abcdef" }
        \\}
        ,
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const extension_path = try makeTmpPath(allocator, tmp, "repo/extensions/discoverer.js");
    defer allocator.free(extension_path);
    var source_info = SourceInfo{
        .path = try allocator.dupe(u8, extension_path),
        .source = try allocator.dupe(u8, "extension"),
        .scope = .project,
        .origin = .top_level,
        .base_dir = try allocator.dupe(u8, cwd),
    };
    defer source_info.deinit(allocator);

    const discovery = ExtensionDiscoveredResources{
        .extension_path = extension_path,
        .source_info = source_info,
        .skill_paths = &.{"ext-skills"},
        .prompt_paths = &.{"ext-prompts"},
        .theme_paths = &.{"ext-themes"},
    };

    var bundle = try loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .runtime_theme = "ext-theme",
        .extension_discoveries = &.{discovery},
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
    defer bundle.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), bundle.skills.len);
    try std.testing.expectEqualStrings("ext-review", bundle.skills[0].name);
    try std.testing.expectEqualStrings("Extension review skill", bundle.skills[0].description);
    try std.testing.expectEqual(@as(usize, 1), bundle.prompt_templates.len);
    try std.testing.expectEqualStrings("ext-review", bundle.prompt_templates[0].name);
    try std.testing.expectEqualStrings("ext-theme", bundle.selectedTheme().name);
    try std.testing.expectEqualStrings("#abcdef", bundle.selectedTheme().colors.primary.?);
}

test "loadResourceBundle collects malformed theme config errors" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/themes");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/themes/broken.json",
        .data = "{ malformed",
    });

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    var bundle = try loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .project = .{ .themes = &.{"themes"} },
    });
    defer bundle.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), bundle.config_errors.len);
    try std.testing.expectEqual(config_errors.Source.theme, bundle.config_errors[0].source);
}
test "detectTerminalName maps documented terminal fallback chain" {
    const allocator = std.testing.allocator;

    const Case = struct {
        key: []const u8,
        value: []const u8,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .key = "TERM_PROGRAM", .value = "Apple_Terminal", .expected = "terminal" },
        .{ .key = "TERM_PROGRAM", .value = "iTerm.app", .expected = "iterm" },
        .{ .key = "TERM_PROGRAM", .value = "Ghostty", .expected = "ghostty" },
        .{ .key = "TERM_PROGRAM", .value = "WezTerm", .expected = "wezterm" },
        .{ .key = "TERM_PROGRAM", .value = "vscode", .expected = "vscode" },
        .{ .key = "TERM_PROGRAM", .value = "kitty", .expected = "kitty" },
        .{ .key = "TERM_PROGRAM", .value = "Alacritty", .expected = "alacritty" },
    };

    for (cases) |case| {
        var env_map = std.process.Environ.Map.init(allocator);
        defer env_map.deinit();
        try env_map.put(case.key, case.value);
        const detected = try detectTerminalName(allocator, &env_map);
        defer allocator.free(detected);
        try std.testing.expectEqualStrings(case.expected, detected);
    }

    var kitty_env = std.process.Environ.Map.init(allocator);
    defer kitty_env.deinit();
    try kitty_env.put("KITTY_WINDOW_ID", "42");
    const detected = try detectTerminalName(allocator, &kitty_env);
    defer allocator.free(detected);
    try std.testing.expectEqualStrings("kitty", detected);

    var term_env = std.process.Environ.Map.init(allocator);
    defer term_env.deinit();
    try term_env.put("TERM", "xterm-256color");
    const term_detected = try detectTerminalName(allocator, &term_env);
    defer allocator.free(term_detected);
    try std.testing.expectEqualStrings("xterm", term_detected);

    var empty_env = std.process.Environ.Map.init(allocator);
    defer empty_env.deinit();
    const fallback = try detectTerminalName(allocator, &empty_env);
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("term", fallback);
}

test "PI_THEME env var selects built-in codex over settings theme" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_THEME", "codex");

    var bundle = try loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .env_map = &env_map,
        .project = .{ .theme = "light" },
    });
    defer bundle.deinit(allocator);

    try std.testing.expectEqualStrings("codex", bundle.selectedTheme().name);
}

test "theme resolution priority honors env runtime project global default" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(cwd);
    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var bundle = try loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .global = .{ .theme = "light" },
        .project = .{ .theme = "codex" },
        .runtime_theme = "dark",
        .env_map = &env_map,
    });
    defer bundle.deinit(allocator);
    try std.testing.expectEqualStrings("dark", bundle.selectedTheme().name);

    var env_override = std.process.Environ.Map.init(allocator);
    defer env_override.deinit();
    try env_override.put("PI_THEME", "codex");
    const env_index = resolveThemeIndex(bundle.themes, &env_override, "dark", "light", null);
    try std.testing.expectEqualStrings("codex", bundle.themes[env_index].name);

    const runtime_index = resolveThemeIndex(bundle.themes, &env_map, "light", "codex", "dark");
    try std.testing.expectEqualStrings("light", bundle.themes[runtime_index].name);

    const project_index = resolveThemeIndex(bundle.themes, &env_map, null, "codex", "light");
    try std.testing.expectEqualStrings("codex", bundle.themes[project_index].name);

    const global_index = resolveThemeIndex(bundle.themes, &env_map, null, null, "light");
    try std.testing.expectEqualStrings("light", bundle.themes[global_index].name);

    const default_index = resolveThemeIndex(bundle.themes, &env_map, null, null, null);
    try std.testing.expectEqualStrings("dark", bundle.themes[default_index].name);

    try env_map.put("COLORFGBG", "0;15");
    const detected_light_index = resolveThemeIndex(bundle.themes, &env_map, null, null, null);
    try std.testing.expectEqualStrings("light", bundle.themes[detected_light_index].name);

    try env_map.put("PI_THEME", "dark");
    const env_over_detected_index = resolveThemeIndex(bundle.themes, &env_map, null, null, null);
    try std.testing.expectEqualStrings("dark", bundle.themes[env_over_detected_index].name);
}

test "default themes include dark light and codex palettes" {
    const allocator = std.testing.allocator;

    var dark = try Theme.initDefault(allocator);
    defer dark.deinit(allocator);
    var light = try Theme.initLight(allocator);
    defer light.deinit(allocator);
    var codex = try Theme.initCodex(allocator);
    defer codex.deinit(allocator);

    try std.testing.expectEqualStrings("dark", dark.name);
    try std.testing.expectEqualStrings("light", light.name);
    try std.testing.expectEqualStrings("codex", codex.name);
    try std.testing.expectEqualStrings("#d18b50", codex.colors.primary.?);
    try std.testing.expectEqualStrings("#0f1012", codex.colors.background.?);
    try std.testing.expectEqualStrings("#d18b50", codex.styles[@intFromEnum(ThemeToken.prompt_glyph)].fg.?);

    const dark_prompt = try dark.applyAlloc(allocator, .prompt, "> ");
    defer allocator.free(dark_prompt);
    const light_prompt = try light.applyAlloc(allocator, .prompt, "> ");
    defer allocator.free(light_prompt);

    try std.testing.expectEqualStrings("> ", dark_prompt);
    try std.testing.expectEqualStrings("> ", light_prompt);
}

test "theme files can override palette colors and component tokens" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "dawn.json",
        .data =
        \\{
        \\  "name": "dawn",
        \\  "base": "light",
        \\  "colors": {
        \\    "primary": "#112233",
        \\    "background": "#faf4ed",
        \\    "foreground": "#302d41",
        \\    "border": "#9988aa"
        \\  },
        \\  "tokens": {
        \\    "overlayTitle": { "underline": true }
        \\  }
        \\}
        ,
    });

    const path = try makeTmpPath(allocator, tmp, "dawn.json");
    defer allocator.free(path);

    var resource = ResolvedResource{
        .path = try allocator.dupe(u8, path),
        .enabled = true,
        .source_info = .{
            .path = try allocator.dupe(u8, path),
            .source = try allocator.dupe(u8, "local"),
            .scope = .user,
            .origin = .top_level,
            .base_dir = null,
        },
    };
    defer resource.deinit(allocator);

    var errors = std.ArrayList(config_errors.ConfigError).empty;
    defer config_errors.deinitList(allocator, &errors);
    var theme = (try loadThemeFromFile(allocator, std.testing.io, resource, &errors)).?;
    defer theme.deinit(allocator);

    try std.testing.expectEqualStrings("dawn", theme.name);
    const overlay_title = theme.styles[@intFromEnum(ThemeToken.overlay_title)];
    try std.testing.expect(overlay_title.underline);
    try std.testing.expectEqualStrings("#112233", theme.colors.primary.?);
    try std.testing.expectEqualStrings("#9988aa", theme.colors.border.?);
}
