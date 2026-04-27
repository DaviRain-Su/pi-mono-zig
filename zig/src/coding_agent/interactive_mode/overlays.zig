const std = @import("std");
const ai = @import("ai");
const auth = @import("../auth.zig");
const config_mod = @import("../config.zig");
const keybindings_mod = @import("../keybindings.zig");
const provider_config = @import("../provider_config.zig");
const resources_mod = @import("../resources.zig");
const session_mod = @import("../session.zig");
const session_manager_mod = @import("../session_manager.zig");
const tui = @import("tui");
const shared = @import("shared.zig");
const formatting = @import("formatting.zig");
const settingsResources = shared.settingsResources;
const configuredCredentials = shared.configuredCredentials;
const blocksToText = formatting.blocksToText;
const formatAssistantMessage = formatting.formatAssistantMessage;

pub const SelectorOverlay = union(enum) {
    info: InfoOverlay,
    settings_editor: SettingsEditorOverlay,
    session: SessionOverlay,
    model: ModelOverlay,
    theme: ThemeOverlay,
    tree: TreeOverlay,
    auth: AuthOverlay,

    pub fn deinit(self: *SelectorOverlay, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .info => |*overlay| overlay.deinit(allocator),
            .settings_editor => |*overlay| overlay.deinit(allocator),
            .session => |*overlay| overlay.deinit(allocator),
            .model => |*overlay| overlay.deinit(allocator),
            .theme => |*overlay| overlay.deinit(allocator),
            .tree => |*overlay| overlay.deinit(allocator),
            .auth => |*overlay| overlay.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn title(self: *const SelectorOverlay) []const u8 {
        return switch (self.*) {
            .info => self.info.title,
            .settings_editor => self.settings_editor.title,
            .session => "Session selector",
            .model => self.model.title,
            .theme => "Theme selector",
            .tree => "Session tree",
            .auth => if (self.auth.mode == .login) "Login" else "Logout",
        };
    }

    pub fn hint(self: *const SelectorOverlay) []const u8 {
        return switch (self.*) {
            .info => self.info.hint,
            .settings_editor => self.settings_editor.hint,
            else => "Up/Down move • Enter select • Esc cancel",
        };
    }
};

pub const InfoOverlay = struct {
    title: []u8,
    hint: []u8,
    items: []tui.SelectItem,
    list: tui.SelectList,

    pub fn deinit(self: *InfoOverlay, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.hint);
        for (self.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const SettingsEditorOverlay = struct {
    title: []u8,
    hint: []u8,
    path: []u8,
    editor: tui.Editor,

    pub fn deinit(self: *SettingsEditorOverlay, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.hint);
        allocator.free(self.path);
        self.editor.deinit();
        self.* = undefined;
    }
};

pub const SessionChoice = struct {
    path: []u8,
};

pub const SessionOverlay = struct {
    choices: []SessionChoice,
    items: []tui.SelectItem,
    list: tui.SelectList,

    pub fn deinit(self: *SessionOverlay, allocator: std.mem.Allocator) void {
        for (self.choices) |choice| allocator.free(choice.path);
        allocator.free(self.choices);
        for (self.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const ModelChoice = struct {
    provider: []u8,
    model_id: []u8,
};

pub const ModelOverlay = struct {
    title: []const u8 = "Model selector",
    choices: []ModelChoice,
    items: []tui.SelectItem,
    list: tui.SelectList,

    pub fn deinit(self: *ModelOverlay, allocator: std.mem.Allocator) void {
        for (self.choices) |choice| {
            allocator.free(choice.provider);
            allocator.free(choice.model_id);
        }
        allocator.free(self.choices);
        for (self.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const ThemeChoice = struct {
    name: []u8,
};

pub const ThemeOverlay = struct {
    choices: []ThemeChoice,
    items: []tui.SelectItem,
    list: tui.SelectList,

    pub fn deinit(self: *ThemeOverlay, allocator: std.mem.Allocator) void {
        for (self.choices) |choice| allocator.free(choice.name);
        allocator.free(self.choices);
        for (self.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const TreeChoice = struct {
    entry_id: []u8,
};

pub const TreeOverlay = struct {
    choices: []TreeChoice,
    items: []tui.SelectItem,
    list: tui.SelectList,

    pub fn deinit(self: *TreeOverlay, allocator: std.mem.Allocator) void {
        for (self.choices) |choice| allocator.free(choice.entry_id);
        allocator.free(self.choices);
        for (self.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const AuthOverlayMode = enum {
    login,
    logout,
};

pub const AuthChoice = struct {
    provider_id: []u8,
    provider_name: []u8,
    auth_type: auth.ProviderAuthType,
};

pub const AuthOverlay = struct {
    mode: AuthOverlayMode,
    choices: []AuthChoice,
    items: []tui.SelectItem,
    list: tui.SelectList,

    pub fn deinit(self: *AuthOverlay, allocator: std.mem.Allocator) void {
        for (self.choices) |choice| {
            allocator.free(choice.provider_id);
            allocator.free(choice.provider_name);
        }
        allocator.free(self.choices);
        for (self.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const AuthFlow = union(enum) {
    browser_redirect: PendingBrowserRedirect,
    google_project: PendingGoogleProject,
    copilot_device: auth.CopilotDeviceLogin,
    api_key: PendingApiKeyEntry,

    pub fn deinit(self: *AuthFlow, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .browser_redirect => |*value| value.deinit(allocator),
            .google_project => |*value| value.deinit(allocator),
            .copilot_device => |*value| value.deinit(allocator),
            .api_key => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const PendingBrowserRedirect = struct {
    session: auth.BrowserLoginSession,

    pub fn deinit(self: *PendingBrowserRedirect, allocator: std.mem.Allocator) void {
        self.session.deinit(allocator);
        self.* = undefined;
    }
};

pub const PendingGoogleProject = struct {
    provider_id: []const u8 = "google-gemini-cli",
    provider_name: []const u8 = "Google Cloud Code Assist (Gemini CLI)",
    exchange: auth.GoogleExchangeResult,

    pub fn deinit(self: *PendingGoogleProject, allocator: std.mem.Allocator) void {
        self.exchange.deinit(allocator);
        self.* = undefined;
    }
};

pub const PendingApiKeyEntry = struct {
    provider_id: []const u8,
    provider_name: []const u8,

    pub fn deinit(self: *PendingApiKeyEntry, _: std.mem.Allocator) void {
        self.* = undefined;
    }
};

pub fn loadAuthOverlay(
    allocator: std.mem.Allocator,
    mode: AuthOverlayMode,
    providers: ?[]const auth.ProviderInfo,
) !SelectorOverlay {
    const source = providers orelse auth.SUPPORTED_PROVIDERS[0..];
    const choices = try allocator.alloc(AuthChoice, source.len);
    errdefer {
        for (choices) |choice| {
            allocator.free(choice.provider_id);
            allocator.free(choice.provider_name);
        }
        allocator.free(choices);
    }

    const items = try allocator.alloc(tui.SelectItem, source.len);
    errdefer {
        for (items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(items);
    }

    if (source.len == 0) {
        return .{
            .auth = .{
                .mode = mode,
                .choices = choices,
                .items = items,
                .list = .{
                    .items = items,
                    .max_visible = 8,
                },
            },
        };
    }

    for (source, 0..) |provider, index| {
        choices[index] = .{
            .provider_id = try allocator.dupe(u8, provider.id),
            .provider_name = try allocator.dupe(u8, provider.name),
            .auth_type = provider.auth_type,
        };
        items[index] = .{
            .value = try allocator.dupe(u8, provider.id),
            .label = try allocator.dupe(u8, provider.name),
            .description = try allocator.dupe(
                u8,
                switch (mode) {
                    .login => if (provider.auth_type == .oauth) "OAuth login" else "API key login",
                    .logout => if (provider.auth_type == .oauth) "Stored OAuth credentials" else "Stored API key",
                },
            ),
        };
    }

    return .{
        .auth = .{
            .mode = mode,
            .choices = choices,
            .items = items,
            .list = .{
                .items = items,
                .max_visible = 8,
            },
        },
    };
}

pub fn loadSettingsEditorOverlay(
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_config: *const config_mod.RuntimeConfig,
    theme: ?*const resources_mod.Theme,
) !SelectorOverlay {
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ runtime_config.agent_dir, "settings.json" });
    errdefer allocator.free(settings_path);

    const initial_content = std.Io.Dir.readFileAlloc(.cwd(), io, settings_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, "{\n}\n"),
        else => return err,
    };
    defer allocator.free(initial_content);

    var editor = tui.Editor.init(allocator);
    errdefer editor.deinit();
    editor.padding_x = 1;
    editor.autocomplete_max_visible = 8;
    editor.setTheme(theme);
    _ = try editor.handlePaste(initial_content);

    return .{
        .settings_editor = .{
            .title = try allocator.dupe(u8, "Settings"),
            .hint = try allocator.dupe(u8, "Edit settings.json • Ctrl+S save • Esc cancel"),
            .path = settings_path,
            .editor = editor,
        },
    };
}

pub fn loadHotkeysOverlay(
    allocator: std.mem.Allocator,
    keybindings: ?*const keybindings_mod.Keybindings,
) !SelectorOverlay {
    var items = std.ArrayList(tui.SelectItem).empty;
    errdefer {
        freeOwnedSelectItems(allocator, items.items);
        items.deinit(allocator);
    }

    const bindings = keybindings orelse {
        try appendInfoOverlayItem(allocator, &items, "Hotkeys", try allocator.dupe(u8, "Keybindings unavailable"));
        return try loadInfoOverlay(
            allocator,
            "Keyboard shortcuts",
            "Up/Down scroll • Enter close • Esc close",
            try items.toOwnedSlice(allocator),
            10,
        );
    };

    try appendHotkeyOverlayItem(allocator, &items, bindings, .interrupt, "Cancel autocomplete or abort streaming");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .clear, "Clear the chat display");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .exit, "Exit interactive mode");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .open_sessions, "Open the session selector");
    try appendHotkeyOverlayItem(allocator, &items, bindings, .open_models, "Open the model selector");
    try appendInfoOverlayItem(allocator, &items, "Enter", try allocator.dupe(u8, "Submit the current prompt"));
    try appendInfoOverlayItem(allocator, &items, "Tab", try allocator.dupe(u8, "Accept the selected autocomplete entry"));
    try appendInfoOverlayItem(allocator, &items, "/", try allocator.dupe(u8, "Start a slash command"));
    try appendInfoOverlayItem(allocator, &items, "!", try allocator.dupe(u8, "Run a bash command"));
    try appendInfoOverlayItem(allocator, &items, "!!", try allocator.dupe(u8, "Run a bash command without adding output to context"));

    return try loadInfoOverlay(
        allocator,
        "Keyboard shortcuts",
        "Up/Down scroll • Enter close • Esc close",
        try items.toOwnedSlice(allocator),
        12,
    );
}

pub fn loadInfoOverlay(
    allocator: std.mem.Allocator,
    title: []const u8,
    hint: []const u8,
    items: []tui.SelectItem,
    max_visible: usize,
) !SelectorOverlay {
    return .{
        .info = .{
            .title = try allocator.dupe(u8, title),
            .hint = try allocator.dupe(u8, hint),
            .items = items,
            .list = .{
                .items = items,
                .max_visible = max_visible,
            },
        },
    };
}

pub fn appendInfoOverlayItem(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(tui.SelectItem),
    label: []const u8,
    description: []u8,
) !void {
    errdefer allocator.free(description);
    const value = try allocator.dupe(u8, label);
    errdefer allocator.free(value);
    const owned_label = try allocator.dupe(u8, label);
    errdefer allocator.free(owned_label);
    try items.append(allocator, .{
        .value = value,
        .label = owned_label,
        .description = description,
    });
}

pub fn appendHotkeyOverlayItem(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(tui.SelectItem),
    keybindings: *const keybindings_mod.Keybindings,
    action: keybindings_mod.Action,
    description: []const u8,
) !void {
    const label = try keybindings.primaryLabel(allocator, action);
    errdefer allocator.free(label);
    const value = try allocator.dupe(u8, label);
    errdefer allocator.free(value);
    const owned_description = try allocator.dupe(u8, description);
    errdefer allocator.free(owned_description);
    try items.append(allocator, .{
        .value = value,
        .label = label,
        .description = owned_description,
    });
}

pub fn freeOwnedSelectItems(allocator: std.mem.Allocator, items: []tui.SelectItem) void {
    for (items) |item| {
        allocator.free(item.value);
        allocator.free(item.label);
        if (item.description) |description| allocator.free(description);
    }
    allocator.free(items);
}

pub fn loadSessionOverlay(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
) !SelectorOverlay {
    const entries = try listSessions(allocator, io, session_dir);
    errdefer {
        for (entries.paths) |path| allocator.free(path);
        allocator.free(entries.paths);
        for (entries.items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(entries.items);
    }

    return .{
        .session = .{
            .choices = entries.paths,
            .items = entries.items,
            .list = .{
                .items = entries.items,
                .max_visible = 12,
            },
        },
    };
}

pub fn loadModelOverlay(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ai.Model,
    current_provider: ?*const provider_config.ResolvedProviderConfig,
    model_patterns: ?[]const []const u8,
    runtime_config: ?*const config_mod.RuntimeConfig,
) !SelectorOverlay {
    const available = try loadSelectableModels(allocator, env_map, current_model, current_provider, model_patterns, runtime_config);
    defer allocator.free(available);

    const choices = try allocator.alloc(ModelChoice, available.len);
    errdefer {
        for (choices) |choice| {
            allocator.free(choice.provider);
            allocator.free(choice.model_id);
        }
        allocator.free(choices);
    }

    const items = try allocator.alloc(tui.SelectItem, available.len);
    errdefer {
        for (items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(items);
    }

    var selected_index: usize = 0;
    for (available, 0..) |entry, index| {
        const provider_changed = index == 0 or !std.mem.eql(u8, available[index - 1].provider, entry.provider);
        const label = try formatModelOverlayLabel(allocator, entry, provider_changed);
        errdefer allocator.free(label);
        const description = try formatModelOverlayDescription(allocator, entry);
        errdefer allocator.free(description);
        choices[index] = .{
            .provider = try allocator.dupe(u8, entry.provider),
            .model_id = try allocator.dupe(u8, entry.model_id),
        };
        items[index] = .{
            .value = try allocator.dupe(u8, entry.model_id),
            .label = label,
            .description = description,
        };
        if (std.mem.eql(u8, entry.provider, current_model.provider) and std.mem.eql(u8, entry.model_id, current_model.id)) {
            selected_index = index;
        }
    }

    return .{
        .model = .{
            .title = "Model selector",
            .choices = choices,
            .items = items,
            .list = .{
                .items = items,
                .selected_index = selected_index,
                .max_visible = 12,
            },
        },
    };
}

pub fn loadThemeOverlay(
    allocator: std.mem.Allocator,
    themes: []const resources_mod.Theme,
    active_theme: ?*const resources_mod.Theme,
) !SelectorOverlay {
    const choices = try allocator.alloc(ThemeChoice, themes.len);
    errdefer {
        for (choices) |choice| allocator.free(choice.name);
        allocator.free(choices);
    }

    const items = try allocator.alloc(tui.SelectItem, themes.len);
    errdefer {
        for (items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(items);
    }

    const active_name = if (active_theme) |theme| theme.name else "";
    var selected_index: usize = 0;
    for (themes, 0..) |theme, index| {
        const is_active = std.mem.eql(u8, theme.name, active_name);
        choices[index] = .{
            .name = try allocator.dupe(u8, theme.name),
        };
        items[index] = .{
            .value = try allocator.dupe(u8, theme.name),
            .label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ if (is_active) "✓" else " ", theme.name }),
            .description = try allocator.dupe(u8, if (is_active) "active theme" else "available theme"),
        };
        if (is_active) selected_index = index;
    }

    return .{
        .theme = .{
            .choices = choices,
            .items = items,
            .list = .{
                .items = items,
                .selected_index = selected_index,
                .max_visible = 12,
            },
        },
    };
}

pub fn loadScopedModelOverlay(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ai.Model,
    current_provider: ?*const provider_config.ResolvedProviderConfig,
    model_patterns: ?[]const []const u8,
    runtime_config: ?*const config_mod.RuntimeConfig,
) !SelectorOverlay {
    const patterns = model_patterns orelse return error.NoScopedModelPatterns;
    if (patterns.len == 0) return error.NoScopedModelPatterns;

    const available = try loadSelectableModels(allocator, env_map, current_model, current_provider, patterns, runtime_config);
    defer allocator.free(available);

    if (available.len == 0) return error.NoScopedModelsAvailable;

    const choices = try allocator.alloc(ModelChoice, available.len);
    errdefer {
        for (choices) |choice| {
            allocator.free(choice.provider);
            allocator.free(choice.model_id);
        }
        allocator.free(choices);
    }

    const items = try allocator.alloc(tui.SelectItem, available.len);
    errdefer {
        for (items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(items);
    }

    var selected_index: usize = 0;
    for (available, 0..) |entry, index| {
        const provider_changed = index == 0 or !std.mem.eql(u8, available[index - 1].provider, entry.provider);
        const label = try formatModelOverlayLabel(allocator, entry, provider_changed);
        errdefer allocator.free(label);
        const description = try formatModelOverlayDescription(allocator, entry);
        errdefer allocator.free(description);
        choices[index] = .{
            .provider = try allocator.dupe(u8, entry.provider),
            .model_id = try allocator.dupe(u8, entry.model_id),
        };
        items[index] = .{
            .value = try allocator.dupe(u8, entry.model_id),
            .label = label,
            .description = description,
        };
        if (std.mem.eql(u8, entry.provider, current_model.provider) and std.mem.eql(u8, entry.model_id, current_model.id)) {
            selected_index = index;
        }
    }

    return .{
        .model = .{
            .title = "Scoped model selector",
            .choices = choices,
            .items = items,
            .list = .{
                .items = items,
                .selected_index = selected_index,
                .max_visible = 12,
            },
        },
    };
}

pub fn loadSelectableModels(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ai.Model,
    current_provider: ?*const provider_config.ResolvedProviderConfig,
    model_patterns: ?[]const []const u8,
    runtime_config: ?*const config_mod.RuntimeConfig,
) ![]provider_config.AvailableModel {
    const available = try provider_config.listAvailableModels(allocator, env_map, current_model, configuredCredentials(runtime_config));
    errdefer allocator.free(available);

    if (current_provider) |resolved_provider| {
        for (available) |*entry| {
            if (!std.mem.eql(u8, entry.provider, resolved_provider.model.provider)) continue;
            entry.auth_status = resolved_provider.auth_status;
            entry.available = resolved_provider.auth_status != .missing;
        }
    }

    const configured = try provider_config.filterConfiguredModels(allocator, available);
    allocator.free(available);
    errdefer allocator.free(configured);

    const patterns = model_patterns orelse return configured;
    const filtered = try provider_config.filterAvailableModels(allocator, configured, patterns);
    allocator.free(configured);
    return filtered;
}

fn formatModelOverlayLabel(
    allocator: std.mem.Allocator,
    entry: provider_config.AvailableModel,
    provider_changed: bool,
) ![]u8 {
    if (provider_changed) {
        return std.fmt.allocPrint(
            allocator,
            "{s} / {s}",
            .{ provider_config.providerDisplayName(entry.provider), entry.display_name },
        );
    }
    return std.fmt.allocPrint(allocator, "  {s}", .{entry.display_name});
}

fn formatModelOverlayDescription(
    allocator: std.mem.Allocator,
    entry: provider_config.AvailableModel,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s} • {s}",
        .{ entry.model_id, provider_config.providerAuthStatusLabel(entry.auth_status) },
    );
}

pub fn modelSupportsInput(input_types: []const []const u8, expected: []const u8) bool {
    for (input_types) |input_type| {
        if (std.ascii.eqlIgnoreCase(input_type, expected)) return true;
    }
    return false;
}

pub fn loadTreeOverlay(
    allocator: std.mem.Allocator,
    session: *const session_mod.AgentSession,
) !SelectorOverlay {
    const tree = try session.session_manager.getTree(allocator);
    defer {
        for (tree) |*node| node.deinit(allocator);
        allocator.free(tree);
    }

    var choice_list = std.ArrayList(TreeChoice).empty;
    errdefer {
        for (choice_list.items) |choice| allocator.free(choice.entry_id);
        choice_list.deinit(allocator);
    }

    var item_list = std.ArrayList(tui.SelectItem).empty;
    errdefer {
        for (item_list.items) |item| {
            allocator.free(item.value);
            allocator.free(item.label);
            if (item.description) |description| allocator.free(description);
        }
        item_list.deinit(allocator);
    }

    var selected_index: usize = 0;
    const current_leaf_id = session.session_manager.getLeafId();
    try appendTreeNodes(allocator, tree, 0, current_leaf_id, &choice_list, &item_list, &selected_index);

    if (item_list.items.len == 0) {
        try choice_list.append(allocator, .{ .entry_id = try allocator.dupe(u8, "") });
        try item_list.append(allocator, .{
            .value = try allocator.dupe(u8, "none"),
            .label = try allocator.dupe(u8, "No tree entries"),
            .description = null,
        });
    }

    const choices = try choice_list.toOwnedSlice(allocator);
    errdefer {
        for (choices) |choice| allocator.free(choice.entry_id);
        allocator.free(choices);
    }
    const items = try item_list.toOwnedSlice(allocator);
    errdefer freeOwnedSelectItems(allocator, items);

    return .{
        .tree = .{
            .choices = choices,
            .items = items,
            .list = .{
                .items = items,
                .selected_index = selected_index,
                .max_visible = 12,
            },
        },
    };
}

pub fn appendTreeNodes(
    allocator: std.mem.Allocator,
    nodes: []const session_manager_mod.SessionTreeNode,
    depth: usize,
    current_leaf_id: ?[]const u8,
    choices: *std.ArrayList(TreeChoice),
    items: *std.ArrayList(tui.SelectItem),
    selected_index: *usize,
) !void {
    for (nodes) |node| {
        const prefix = try indentationPrefix(allocator, depth);
        defer allocator.free(prefix);
        const summary = try summarizeSessionEntry(allocator, node.entry.*);
        defer allocator.free(summary);
        const label = if (node.label) |entry_label|
            try std.fmt.allocPrint(allocator, "{s}[{s}] {s}", .{ prefix, entry_label, summary })
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, summary });
        defer allocator.free(label);

        try choices.append(allocator, .{ .entry_id = try allocator.dupe(u8, node.entry.id()) });
        try items.append(allocator, .{
            .value = try allocator.dupe(u8, node.entry.id()),
            .label = try allocator.dupe(u8, label),
            .description = try allocator.dupe(u8, node.entry.timestamp()),
        });
        if (current_leaf_id) |leaf_id| {
            if (std.mem.eql(u8, leaf_id, node.entry.id())) {
                selected_index.* = items.items.len - 1;
            }
        }

        try appendTreeNodes(allocator, node.children, depth + 1, current_leaf_id, choices, items, selected_index);
    }
}

pub fn indentationPrefix(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    const prefix = try allocator.alloc(u8, depth * 2);
    @memset(prefix, ' ');
    return prefix;
}

pub fn summarizeSessionEntry(allocator: std.mem.Allocator, entry: session_manager_mod.SessionEntry) ![]u8 {
    return switch (entry) {
        .message => |message_entry| switch (message_entry.message) {
            .user => |user_message| blk: {
                const text = try blocksToText(allocator, user_message.content);
                defer allocator.free(text);
                break :blk std.fmt.allocPrint(allocator, "user: {s}", .{trimSummaryText(text)});
            },
            .assistant => |assistant_message| blk: {
                const text = try formatAssistantMessage(allocator, assistant_message);
                defer allocator.free(text);
                break :blk allocator.dupe(u8, trimSummaryText(text));
            },
            .tool_result => |tool_result| blk: {
                const text = try blocksToText(allocator, tool_result.content);
                defer allocator.free(text);
                break :blk std.fmt.allocPrint(allocator, "tool {s}: {s}", .{ tool_result.tool_name, trimSummaryText(text) });
            },
        },
        .thinking_level_change => |thinking_entry| std.fmt.allocPrint(allocator, "thinking: {s}", .{@tagName(thinking_entry.thinking_level)}),
        .model_change => |model_entry| std.fmt.allocPrint(allocator, "model: {s}/{s}", .{ model_entry.provider, model_entry.model_id }),
        .compaction => |compaction_entry| std.fmt.allocPrint(allocator, "compaction: {s}", .{trimSummaryText(try session_manager_mod.getCompactionSummary(compaction_entry))}),
        .branch_summary => |branch_summary_entry| std.fmt.allocPrint(allocator, "branch summary: {s}", .{trimSummaryText(branch_summary_entry.summary)}),
        .custom => |custom_entry| std.fmt.allocPrint(allocator, "custom: {s}", .{custom_entry.custom_type}),
        .custom_message => |custom_message_entry| blk: {
            const text = switch (custom_message_entry.content) {
                .text => |value| try allocator.dupe(u8, value),
                .blocks => |blocks| try blocksToText(allocator, blocks),
            };
            defer allocator.free(text);
            break :blk std.fmt.allocPrint(
                allocator,
                "[{s}]: {s}",
                .{ custom_message_entry.custom_type, trimSummaryText(text) },
            );
        },
        .label => |label_entry| if (label_entry.label) |label|
            std.fmt.allocPrint(allocator, "label: {s}", .{label})
        else
            allocator.dupe(u8, "label cleared"),
        .session_info => |session_info_entry| if (session_info_entry.name) |name|
            std.fmt.allocPrint(allocator, "session name: {s}", .{name})
        else
            allocator.dupe(u8, "session name cleared"),
    };
}

pub fn trimSummaryText(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return if (trimmed.len > 72) trimmed[0..72] else trimmed;
}

pub const SessionOverlayEntries = struct {
    paths: []SessionChoice,
    items: []tui.SelectItem,
};

pub fn listSessions(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
) !SessionOverlayEntries {
    var dir = std.Io.Dir.openDirAbsolute(io, session_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            const paths = try allocator.alloc(SessionChoice, 1);
            const items = try allocator.alloc(tui.SelectItem, 1);
            paths[0] = .{ .path = try allocator.dupe(u8, "") };
            items[0] = .{
                .value = try allocator.dupe(u8, "none"),
                .label = try allocator.dupe(u8, "No sessions found"),
                .description = null,
            };
            return .{ .paths = paths, .items = items };
        },
        else => return err,
    };
    defer dir.close(io);

    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.order(u8, lhs, rhs) == .gt;
        }
    }.lessThan);

    const count = if (names.items.len == 0) @as(usize, 1) else names.items.len;
    const paths = try allocator.alloc(SessionChoice, count);
    errdefer {
        for (paths) |path| allocator.free(path.path);
        allocator.free(paths);
    }
    const items = try allocator.alloc(tui.SelectItem, count);
    errdefer {
        for (items) |item| {
            allocator.free(@constCast(item.value));
            allocator.free(@constCast(item.label));
            if (item.description) |description| allocator.free(@constCast(description));
        }
        allocator.free(items);
    }

    if (names.items.len == 0) {
        paths[0] = .{ .path = try allocator.dupe(u8, "") };
        items[0] = .{
            .value = try allocator.dupe(u8, "none"),
            .label = try allocator.dupe(u8, "No sessions found"),
            .description = null,
        };
        return .{ .paths = paths, .items = items };
    }

    for (names.items, 0..) |name, index| {
        const path = try std.fs.path.join(allocator, &[_][]const u8{ session_dir, name });
        const display_name = try loadSessionDisplayName(allocator, io, path, name);
        errdefer allocator.free(display_name);
        paths[index] = .{ .path = path };
        items[index] = .{
            .value = try allocator.dupe(u8, name),
            .label = display_name,
            .description = try allocator.dupe(u8, path),
        };
    }

    return .{ .paths = paths, .items = items };
}

pub fn loadSessionDisplayName(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_path: []const u8,
    fallback_name: []const u8,
) ![]u8 {
    var manager = session_manager_mod.SessionManager.open(allocator, io, session_path, null) catch {
        return allocator.dupe(u8, fallback_name);
    };
    defer manager.deinit();

    if (manager.getSessionName()) |name| return allocator.dupe(u8, name);
    return allocator.dupe(u8, fallback_name);
}

test "loadModelOverlay groups configured providers and omits missing-auth providers" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("OPENAI_API_KEY", "openai-key");
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-key");

    const current_model = ai.model_registry.find("openai", "gpt-5.4").?;
    var overlay = try loadModelOverlay(allocator, &env_map, current_model, null, null, null);
    defer overlay.deinit(allocator);

    try std.testing.expectEqual(@as(std.meta.Tag(SelectorOverlay), .model), std.meta.activeTag(overlay));

    var saw_anthropic = false;
    var saw_grouped_openai = false;
    var saw_grouped_anthropic = false;
    var saw_google = false;
    for (overlay.model.items) |item| {
        if (std.mem.startsWith(u8, item.label, "Anthropic / ")) {
            saw_grouped_anthropic = true;
        }
        if (std.mem.startsWith(u8, item.label, "Google Gemini / ")) {
            saw_google = true;
        }
        if (std.mem.startsWith(u8, item.label, "OpenAI / ")) {
            saw_grouped_openai = true;
        }
        if (std.mem.eql(u8, item.value, "claude-sonnet-4-5")) {
            saw_anthropic = true;
        }
    }

    try std.testing.expect(saw_anthropic);
    try std.testing.expect(saw_grouped_openai);
    try std.testing.expect(saw_grouped_anthropic);
    try std.testing.expect(!saw_google);
}

test "loadModelOverlay marks current provider models available for runtime api key overrides" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var current_provider = try provider_config.resolveProviderConfig(
        allocator,
        &env_map,
        "openai",
        "gpt-5.4",
        "runtime-openai-key",
        null,
    );
    defer current_provider.deinit(allocator);

    var overlay = try loadModelOverlay(allocator, &env_map, current_provider.model, &current_provider, null, null);
    defer overlay.deinit(allocator);

    var saw_runtime_status = false;
    var saw_second_openai_model = false;
    for (overlay.model.items) |item| {
        if (std.mem.eql(u8, item.value, "gpt-5.5")) saw_second_openai_model = true;
        if (std.mem.indexOf(u8, item.description.?, "--api-key") != null) saw_runtime_status = true;
    }

    try std.testing.expect(saw_second_openai_model);
    try std.testing.expect(saw_runtime_status);
}
