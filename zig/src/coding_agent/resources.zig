const std = @import("std");

pub const SourceScope = enum {
    temporary,
    project,
    user,
};

pub const SourceOrigin = enum {
    top_level,
    package,
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

    pub fn clone(self: SourceInfo, allocator: std.mem.Allocator) !SourceInfo {
        return .{
            .path = try allocator.dupe(u8, self.path),
            .source = try allocator.dupe(u8, self.source),
            .scope = self.scope,
            .origin = self.origin,
            .base_dir = if (self.base_dir) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *SourceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
        if (self.base_dir) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ResolvedResource = struct {
    path: []u8,
    enabled: bool,
    source_info: SourceInfo,

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

pub const ThemeToken = enum(u8) {
    welcome,
    user,
    assistant,
    tool_call,
    tool_result,
    @"error",
    status,
    footer,
    prompt,
};

pub const StyleSpec = struct {
    fg: ?[]u8 = null,
    bg: ?[]u8 = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,

    fn clone(self: StyleSpec, allocator: std.mem.Allocator) !StyleSpec {
        return .{
            .fg = if (self.fg) |value| try allocator.dupe(u8, value) else null,
            .bg = if (self.bg) |value| try allocator.dupe(u8, value) else null,
            .bold = self.bold,
            .italic = self.italic,
            .underline = self.underline,
        };
    }

    fn deinit(self: *StyleSpec, allocator: std.mem.Allocator) void {
        if (self.fg) |value| allocator.free(value);
        if (self.bg) |value| allocator.free(value);
        self.* = .{};
    }
};

pub const Theme = struct {
    name: []u8,
    source_path: ?[]u8 = null,
    source_info: ?SourceInfo = null,
    styles: [@typeInfo(ThemeToken).@"enum".fields.len]StyleSpec = defaultThemeStyles(),

    pub fn initDefault(allocator: std.mem.Allocator) !Theme {
        return .{
            .name = try allocator.dupe(u8, "default"),
        };
    }

    pub fn clone(self: Theme, allocator: std.mem.Allocator) !Theme {
        var styles = defaultThemeStyles();
        for (&styles, self.styles) |*target, source| {
            target.* = try source.clone(allocator);
        }
        return .{
            .name = try allocator.dupe(u8, self.name),
            .source_path = if (self.source_path) |value| try allocator.dupe(u8, value) else null,
            .source_info = if (self.source_info) |value| try value.clone(allocator) else null,
            .styles = styles,
        };
    }

    pub fn deinit(self: *Theme, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.source_path) |value| allocator.free(value);
        if (self.source_info) |*value| value.deinit(allocator);
        for (&self.styles) |*style| style.deinit(allocator);
        self.* = undefined;
    }

    pub fn applyAlloc(self: *const Theme, allocator: std.mem.Allocator, token: ThemeToken, text: []const u8) ![]u8 {
        const style = self.styles[@intFromEnum(token)];
        if (style.fg == null and style.bg == null and !style.bold and !style.italic and !style.underline) {
            return allocator.dupe(u8, text);
        }

        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);
        if (style.bold) try builder.appendSlice(allocator, "\x1b[1m");
        if (style.italic) try builder.appendSlice(allocator, "\x1b[3m");
        if (style.underline) try builder.appendSlice(allocator, "\x1b[4m");
        if (style.fg) |value| try appendColorAnsi(allocator, &builder, value, true);
        if (style.bg) |value| try appendColorAnsi(allocator, &builder, value, false);
        try builder.appendSlice(allocator, text);
        try builder.appendSlice(allocator, "\x1b[0m");
        return try builder.toOwnedSlice(allocator);
    }
};

pub const ResourceBundle = struct {
    extensions: []LoadedExtension,
    skills: []Skill,
    prompt_templates: []PromptTemplate,
    themes: []Theme,
    selected_theme_index: usize,
    diagnostics: []Diagnostic,

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
    include_default_extensions: bool = true,
    include_default_skills: bool = true,
    include_default_prompts: bool = true,
    include_default_themes: bool = true,
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
    if (options.include_default_prompts) try addAutoDiscovered(allocator, io, &prompts, &diagnostics, .prompt, .project, project_base_dir);
    if (options.include_default_themes) try addAutoDiscovered(allocator, io, &themes, &diagnostics, .theme, .project, project_base_dir);

    if (options.include_default_extensions) try addAutoDiscovered(allocator, io, &extensions, &diagnostics, .extension, .user, options.agent_dir);
    if (options.include_default_skills) try addAutoDiscovered(allocator, io, &skills, &diagnostics, .skill, .user, options.agent_dir);
    if (options.include_default_prompts) try addAutoDiscovered(allocator, io, &prompts, &diagnostics, .prompt, .user, options.agent_dir);
    if (options.include_default_themes) try addAutoDiscovered(allocator, io, &themes, &diagnostics, .theme, .user, options.agent_dir);

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
    for (resolved.diagnostics) |diagnostic| {
        try diagnostics.append(allocator, try cloneDiagnostic(allocator, diagnostic));
    }

    const skills = try loadSkills(allocator, io, resolved.skills, &diagnostics);
    errdefer deinitSkills(allocator, skills);
    const templates = try loadPromptTemplates(allocator, io, resolved.prompts, &diagnostics);
    errdefer deinitPromptTemplates(allocator, templates);
    const themes = try loadThemes(allocator, io, resolved.themes, &diagnostics);
    errdefer deinitThemes(allocator, themes);

    var all_themes = std.ArrayList(Theme).empty;
    errdefer deinitThemesList(allocator, &all_themes);
    try all_themes.append(allocator, try Theme.initDefault(allocator));
    for (themes) |theme| {
        try all_themes.append(allocator, theme);
    }
    allocator.free(themes);

    const selected_name = options.project.theme orelse options.global.theme;
    const selected_index = findThemeIndex(all_themes.items, selected_name) orelse 0;

    return .{
        .extensions = try extensions.toOwnedSlice(allocator),
        .skills = skills,
        .prompt_templates = templates,
        .themes = try all_themes.toOwnedSlice(allocator),
        .selected_theme_index = selected_index,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
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

fn defaultThemeStyles() [@typeInfo(ThemeToken).@"enum".fields.len]StyleSpec {
    var styles: [@typeInfo(ThemeToken).@"enum".fields.len]StyleSpec = undefined;
    for (&styles) |*style| style.* = .{};
    return styles;
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
                try collectPackageResourceRoot(allocator, io, extensions, skills, prompts, themes, diagnostics, resolved, filter, .{
                    .source = pkg.source,
                    .scope = scope,
                    .origin = .package,
                    .base_dir = resolved,
                });
            },
            .npm => |npm| {
                const install_path = try npmInstallPath(allocator, scope, cwd, agent_dir, npm.name);
                defer allocator.free(install_path);
                if (!pathExists(io, install_path)) {
                    try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "npm source is not installed", install_path));
                    continue;
                }
                try collectPackageResourceRoot(allocator, io, extensions, skills, prompts, themes, diagnostics, install_path, filter, .{
                    .source = pkg.source,
                    .scope = scope,
                    .origin = .package,
                    .base_dir = install_path,
                });
            },
            .git => |git| {
                const install_path = try gitInstallPath(allocator, scope, cwd, agent_dir, git.normalized);
                defer allocator.free(install_path);
                if (!pathExists(io, install_path)) {
                    try diagnostics.append(allocator, try makeDiagnostic(allocator, "warning", "git source is not installed", install_path));
                    continue;
                }
                try collectPackageResourceRoot(allocator, io, extensions, skills, prompts, themes, diagnostics, install_path, filter, .{
                    .source = pkg.source,
                    .scope = scope,
                    .origin = .package,
                    .base_dir = install_path,
                });
            },
        }
    }
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
        if (kind != .extension or hasSupportedExtensionFile(path)) {
            if (kind == .skill or kind == .prompt or kind == .theme or hasSupportedExtensionFile(path)) {
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
        },
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
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lessThan);
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
) ![]Skill {
    var skills = std.ArrayList(Skill).empty;
    errdefer deinitSkillsList(allocator, &skills);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (resources) |resource| {
        if (!resource.enabled) continue;
        const skill = try loadSkillFromFile(allocator, io, resource, diagnostics) orelse continue;
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
) ![]PromptTemplate {
    var templates = std.ArrayList(PromptTemplate).empty;
    errdefer deinitPromptTemplatesList(allocator, &templates);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (resources) |resource| {
        if (!resource.enabled) continue;
        const template = try loadPromptTemplateFromFile(allocator, io, resource) orelse continue;
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
) ![]Theme {
    var themes = std.ArrayList(Theme).empty;
    errdefer deinitThemesList(allocator, &themes);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (resources) |resource| {
        if (!resource.enabled) continue;
        const theme = try loadThemeFromFile(allocator, io, resource) orelse continue;
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
) !?Skill {
    const bytes = readOptionalFile(allocator, io, resource.path) catch return null;
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

fn loadPromptTemplateFromFile(allocator: std.mem.Allocator, io: std.Io, resource: ResolvedResource) !?PromptTemplate {
    const bytes = readOptionalFile(allocator, io, resource.path) catch return null;
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

fn loadThemeFromFile(allocator: std.mem.Allocator, io: std.Io, resource: ResolvedResource) !?Theme {
    const bytes = readOptionalFile(allocator, io, resource.path) catch return null;
    defer if (bytes) |value| allocator.free(value);
    if (bytes == null) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes.?, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    var theme = Theme{
        .name = try allocator.dupe(u8, trimExtension(std.fs.path.basename(resource.path), ".json")),
        .source_path = try allocator.dupe(u8, resource.path),
        .source_info = try resource.source_info.clone(allocator),
    };
    errdefer theme.deinit(allocator);

    if (parsed.value.object.get("name")) |value| {
        if (value == .string) {
            allocator.free(theme.name);
            theme.name = try allocator.dupe(u8, value.string);
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
                    if (field == .string) style.fg = try allocator.dupe(u8, field.string);
                }
                if (object.get("bg")) |field| {
                    if (field == .string) style.bg = try allocator.dupe(u8, field.string);
                }
                if (object.get("bold")) |field| {
                    if (field == .bool) style.bold = field.bool;
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
    if (std.mem.startsWith(u8, source, "local:")) {
        return .{ .local = .{ .path = std.mem.trim(u8, source["local:".len..], " ") } };
    }
    return .{ .local = .{ .path = source } };
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
    return std.fs.path.join(allocator, &[_][]const u8{ base_dir, input });
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

fn makeDiagnostic(allocator: std.mem.Allocator, kind: []const u8, message: []const u8, path: []const u8) !Diagnostic {
    return .{
        .kind = try allocator.dupe(u8, kind),
        .message = try allocator.dupe(u8, message),
        .path = try allocator.dupe(u8, path),
    };
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
    return null;
}

fn findThemeIndex(themes: []const Theme, name: ?[]const u8) ?usize {
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

test "resolveConfiguredResources loads local, npm, and git resource sources" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/extensions");
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

    var bundle = try loadResourceBundle(allocator, std.testing.io, .{
        .cwd = cwd,
        .agent_dir = agent_dir,
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

    const expanded = try expandPromptTemplate(allocator, "/fix parser bug", bundle.prompt_templates);
    defer allocator.free(expanded);
    try std.testing.expectEqualStrings("Fix parser using parser bug", expanded);

    const prompt_text = try formatSkillsForPrompt(allocator, bundle.skills);
    defer allocator.free(prompt_text);
    try std.testing.expect(std.mem.indexOf(u8, prompt_text, "<available_skills>") != null);

    const styled = try bundle.selectedTheme().applyAlloc(allocator, .assistant, "Pi:");
    defer allocator.free(styled);
    try std.testing.expect(std.mem.indexOf(u8, styled, "\x1b[1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, styled, "Pi:") != null);
}
