const std = @import("std");
const types = @import("types.zig");

pub const ProviderConfig = struct {
    provider: []const u8,
    api: types.Api,
    base_url: []const u8,
    default_model_id: ?[]const u8 = null,
};

pub const ModelDefinition = struct {
    provider: []const u8,
    id: []const u8,
    name: []const u8,
    reasoning: bool = false,
    tool_calling: bool = true,
    loaded: bool = false,
    input_types: []const []const u8,
    cost: types.ModelCost = .{},
    context_window: u32,
    max_tokens: u32,
    headers: ?std.StringHashMap([]const u8) = null,
    compat: ?std.json.Value = null,
};

pub const RegisterError = std.mem.Allocator.Error || error{
    UnknownProvider,
};

const ProviderEntry = struct {
    config: ProviderConfig,

    fn deinit(self: *ProviderEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.config.provider);
        allocator.free(self.config.api);
        allocator.free(self.config.base_url);
        if (self.config.default_model_id) |default_model_id| allocator.free(default_model_id);
        self.* = undefined;
    }
};

const ModelEntry = struct {
    model: types.Model,

    fn deinit(self: *ModelEntry, allocator: std.mem.Allocator) void {
        deinitOwnedModel(allocator, &self.model);
        self.* = undefined;
    }
};

pub const ModelSummary = struct {
    id: []const u8,
    name: []const u8,
    provider: []const u8,
    reasoning: bool,
    tool_calling: bool,
    loaded: bool,
    input_types: []const []const u8,
    context_window: u32,
    max_tokens: u32,
};

pub const ModelRegistry = struct {
    allocator: std.mem.Allocator,
    providers: std.StringHashMap(ProviderEntry),
    models: std.ArrayList(ModelEntry),

    pub fn init(allocator: std.mem.Allocator) ModelRegistry {
        return .{
            .allocator = allocator,
            .providers = std.StringHashMap(ProviderEntry).init(allocator),
            .models = .empty,
        };
    }

    pub fn deinit(self: *ModelRegistry) void {
        for (self.models.items) |*entry| entry.deinit(self.allocator);
        self.models.deinit(self.allocator);

        var provider_iterator = self.providers.iterator();
        while (provider_iterator.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.providers.deinit();
        self.* = undefined;
    }

    pub fn registerBuiltIns(self: *ModelRegistry) RegisterError!void {
        for (BUILT_IN_PROVIDER_CONFIGS) |config| {
            try self.registerProvider(config);
        }
        for (BUILT_IN_MODELS) |definition| {
            try self.registerModelDefinition(definition);
        }
    }

    pub fn registerProvider(self: *ModelRegistry, config: ProviderConfig) RegisterError!void {
        if (self.providers.getPtr(config.provider)) |existing| {
            allocatorFreeReplace(self.allocator, &existing.config.api, config.api) catch return error.OutOfMemory;
            allocatorFreeReplace(self.allocator, &existing.config.base_url, config.base_url) catch return error.OutOfMemory;
            if (existing.config.default_model_id) |default_model_id| self.allocator.free(default_model_id);
            existing.config.default_model_id = if (config.default_model_id) |default_model_id|
                try self.allocator.dupe(u8, default_model_id)
            else
                null;

            try self.syncModelsForProvider(existing.config.provider, existing.config.api, existing.config.base_url);
            return;
        }

        const owned_provider = try self.allocator.dupe(u8, config.provider);
        errdefer self.allocator.free(owned_provider);

        const owned_api = try self.allocator.dupe(u8, config.api);
        errdefer self.allocator.free(owned_api);

        const owned_base_url = try self.allocator.dupe(u8, config.base_url);
        errdefer self.allocator.free(owned_base_url);

        const owned_default_model_id = if (config.default_model_id) |default_model_id|
            try self.allocator.dupe(u8, default_model_id)
        else
            null;
        errdefer if (owned_default_model_id) |default_model_id| self.allocator.free(default_model_id);

        try self.providers.put(owned_provider, .{
            .config = .{
                .provider = owned_provider,
                .api = owned_api,
                .base_url = owned_base_url,
                .default_model_id = owned_default_model_id,
            },
        });
    }

    pub fn registerModelDefinition(self: *ModelRegistry, definition: ModelDefinition) RegisterError!void {
        const provider = self.getProviderConfig(definition.provider) orelse return error.UnknownProvider;

        try self.registerModel(.{
            .id = definition.id,
            .name = definition.name,
            .api = provider.api,
            .provider = provider.provider,
            .base_url = provider.base_url,
            .reasoning = definition.reasoning,
            .tool_calling = definition.tool_calling,
            .loaded = definition.loaded,
            .input_types = definition.input_types,
            .cost = definition.cost,
            .context_window = definition.context_window,
            .max_tokens = definition.max_tokens,
            .headers = definition.headers,
            .compat = definition.compat,
        });
    }

    pub fn registerModel(self: *ModelRegistry, model: types.Model) RegisterError!void {
        if (self.getProviderConfig(model.provider) == null) {
            try self.registerProvider(.{
                .provider = model.provider,
                .api = model.api,
                .base_url = model.base_url,
            });
        }

        var cloned = try cloneModel(self.allocator, model);
        errdefer cloned.deinit(self.allocator);

        if (self.findModelIndex(model.provider, model.id)) |index| {
            self.models.items[index].deinit(self.allocator);
            self.models.items[index] = cloned;
            return;
        }

        try self.models.append(self.allocator, cloned);
    }

    pub fn find(self: *const ModelRegistry, provider: []const u8, model_id: []const u8) ?types.Model {
        for (self.models.items) |entry| {
            if (std.mem.eql(u8, entry.model.provider, provider) and std.mem.eql(u8, entry.model.id, model_id)) {
                return entry.model;
            }
        }
        return null;
    }

    pub fn findById(self: *const ModelRegistry, model_id: []const u8) ?types.Model {
        var found: ?types.Model = null;
        for (self.models.items) |entry| {
            if (!std.mem.eql(u8, entry.model.id, model_id)) continue;
            if (found != null) return null;
            found = entry.model;
        }
        return found;
    }

    pub fn findExactReferenceMatch(self: *const ModelRegistry, reference: []const u8) ?types.Model {
        const trimmed = trimReference(reference);
        if (trimmed.len == 0) return null;

        var canonical_match: ?types.Model = null;
        for (self.models.items) |entry| {
            const model = entry.model;
            if (equalCanonicalReference(trimmed, model.provider, model.id)) {
                if (canonical_match != null) return null;
                canonical_match = model;
            }
        }
        if (canonical_match) |match| return match;

        var id_match: ?types.Model = null;
        for (self.models.items) |entry| {
            const model = entry.model;
            if (std.ascii.eqlIgnoreCase(model.id, trimmed)) {
                if (id_match != null) return null;
                id_match = model;
            }
        }
        return id_match;
    }

    pub fn matchScopedModel(self: *const ModelRegistry, reference: []const u8) ?types.Model {
        const trimmed = trimReference(reference);
        if (trimmed.len == 0) return null;

        if (self.findExactReferenceMatch(trimmed)) |exact| return exact;

        if (std.mem.indexOfScalar(u8, trimmed, '/')) |slash_index| {
            const provider = trimReference(trimmed[0..slash_index]);
            const pattern = trimReference(trimmed[slash_index + 1 ..]);
            if (pattern.len == 0) return null;

            if (self.getProviderConfig(provider) != null) {
                return self.matchBestForProvider(provider, pattern);
            }
        }

        return self.matchBestAcrossProviders(trimmed);
    }

    pub fn getProviderConfig(self: *const ModelRegistry, provider: []const u8) ?ProviderConfig {
        return if (self.providers.get(provider)) |entry| entry.config else null;
    }

    pub fn setProviderDefaultModel(self: *ModelRegistry, provider: []const u8, model_id: []const u8) RegisterError!void {
        const entry = self.providers.getPtr(provider) orelse return error.UnknownProvider;
        const owned_model_id = try self.allocator.dupe(u8, model_id);
        if (entry.config.default_model_id) |existing| self.allocator.free(existing);
        entry.config.default_model_id = owned_model_id;
    }

    pub fn firstModelIdForProvider(self: *const ModelRegistry, provider: []const u8) ?[]const u8 {
        for (self.models.items) |entry| {
            if (std.mem.eql(u8, entry.model.provider, provider)) return entry.model.id;
        }
        return null;
    }

    pub fn setModelLoaded(self: *ModelRegistry, provider: []const u8, model_id: []const u8, loaded: bool) bool {
        if (self.findModelIndex(provider, model_id)) |index| {
            self.models.items[index].model.loaded = loaded;
            return true;
        }
        return false;
    }

    pub fn clearLoadedForProvider(self: *ModelRegistry, provider: []const u8) void {
        for (self.models.items) |*entry| {
            if (std.mem.eql(u8, entry.model.provider, provider)) entry.model.loaded = false;
        }
    }

    pub fn count(self: *const ModelRegistry) usize {
        return self.models.items.len;
    }

    pub fn countProviders(self: *const ModelRegistry) usize {
        return self.providers.count();
    }

    pub fn listSummaries(self: *const ModelRegistry, allocator: std.mem.Allocator) ![]ModelSummary {
        const summaries = try allocator.alloc(ModelSummary, self.models.items.len);
        for (self.models.items, 0..) |entry, index| {
            summaries[index] = .{
                .id = entry.model.id,
                .name = entry.model.name,
                .provider = entry.model.provider,
                .reasoning = entry.model.reasoning,
                .tool_calling = entry.model.tool_calling,
                .loaded = entry.model.loaded,
                .input_types = entry.model.input_types,
                .context_window = entry.model.context_window,
                .max_tokens = entry.model.max_tokens,
            };
        }
        return summaries;
    }

    fn syncModelsForProvider(
        self: *ModelRegistry,
        provider: []const u8,
        api: []const u8,
        base_url: []const u8,
    ) RegisterError!void {
        for (self.models.items) |*entry| {
            if (!std.mem.eql(u8, entry.model.provider, provider)) continue;

            allocatorFreeReplace(self.allocator, &entry.model.api, api) catch return error.OutOfMemory;
            allocatorFreeReplace(self.allocator, &entry.model.base_url, base_url) catch return error.OutOfMemory;
        }
    }

    fn findModelIndex(self: *const ModelRegistry, provider: []const u8, model_id: []const u8) ?usize {
        for (self.models.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.model.provider, provider) and std.mem.eql(u8, entry.model.id, model_id)) {
                return index;
            }
        }
        return null;
    }

    fn matchBestForProvider(self: *const ModelRegistry, provider: []const u8, pattern: []const u8) ?types.Model {
        var best: ?types.Model = null;
        for (self.models.items) |entry| {
            const model = entry.model;
            if (!std.mem.eql(u8, model.provider, provider)) continue;
            if (!matchesPattern(model, pattern)) continue;
            if (best == null or isBetterMatch(model, best.?)) best = model;
        }
        return best;
    }

    fn matchBestAcrossProviders(self: *const ModelRegistry, pattern: []const u8) ?types.Model {
        var best: ?types.Model = null;
        for (self.models.items) |entry| {
            const model = entry.model;
            if (!matchesPattern(model, pattern)) continue;
            if (best == null or isBetterMatch(model, best.?)) best = model;
        }
        return best;
    }
};

var default_registry: ?ModelRegistry = null;

pub fn init() void {
    if (default_registry != null) return;

    var registry = ModelRegistry.init(std.heap.page_allocator);
    registry.registerBuiltIns() catch @panic("failed to register built-in models");
    default_registry = registry;
}

pub fn getDefault() *ModelRegistry {
    init();
    return &default_registry.?;
}

pub fn clearDefault() void {
    if (default_registry) |*registry| {
        registry.deinit();
        default_registry = null;
    }
}

/// Deprecated test-only alias. Production code should call clearDefault().
pub const resetForTesting = clearDefault;

pub fn find(provider: []const u8, model_id: []const u8) ?types.Model {
    return getDefault().find(provider, model_id);
}

pub fn findById(model_id: []const u8) ?types.Model {
    return getDefault().findById(model_id);
}

pub fn findExactReferenceMatch(reference: []const u8) ?types.Model {
    return getDefault().findExactReferenceMatch(reference);
}

pub fn matchScopedModel(reference: []const u8) ?types.Model {
    return getDefault().matchScopedModel(reference);
}

pub fn listSummaries(allocator: std.mem.Allocator) ![]ModelSummary {
    return getDefault().listSummaries(allocator);
}

pub fn getProviderConfig(provider: []const u8) ?ProviderConfig {
    return getDefault().getProviderConfig(provider);
}

pub fn setProviderDefaultModel(provider: []const u8, model_id: []const u8) RegisterError!void {
    return getDefault().setProviderDefaultModel(provider, model_id);
}

pub fn firstModelIdForProvider(provider: []const u8) ?[]const u8 {
    return getDefault().firstModelIdForProvider(provider);
}

pub fn setModelLoaded(provider: []const u8, model_id: []const u8, loaded: bool) bool {
    return getDefault().setModelLoaded(provider, model_id, loaded);
}

pub fn clearLoadedForProvider(provider: []const u8) void {
    getDefault().clearLoadedForProvider(provider);
}

pub fn builtInProviderConfigs() []const ProviderConfig {
    return BUILT_IN_PROVIDER_CONFIGS[0..];
}

pub fn registerProvider(config: ProviderConfig) RegisterError!void {
    return getDefault().registerProvider(config);
}

pub fn registerModelDefinition(definition: ModelDefinition) RegisterError!void {
    return getDefault().registerModelDefinition(definition);
}

pub fn registerModel(model: types.Model) RegisterError!void {
    return getDefault().registerModel(model);
}

fn cloneModel(allocator: std.mem.Allocator, model: types.Model) RegisterError!ModelEntry {
    const owned_id = try allocator.dupe(u8, model.id);
    errdefer allocator.free(owned_id);

    const owned_name = try allocator.dupe(u8, model.name);
    errdefer allocator.free(owned_name);

    const owned_api = try allocator.dupe(u8, model.api);
    errdefer allocator.free(owned_api);

    const owned_provider = try allocator.dupe(u8, model.provider);
    errdefer allocator.free(owned_provider);

    const owned_base_url = try allocator.dupe(u8, model.base_url);
    errdefer allocator.free(owned_base_url);

    const owned_input_types = try cloneInputTypes(allocator, model.input_types);
    errdefer {
        for (owned_input_types) |input_type| allocator.free(input_type);
        allocator.free(owned_input_types);
    }

    var owned_headers = try cloneHeaders(allocator, model.headers);
    errdefer if (owned_headers) |*headers| deinitHeaders(allocator, headers);

    const owned_compat = if (model.compat) |compat| try cloneJsonValue(allocator, compat) else null;
    errdefer if (owned_compat) |compat| deinitJsonValue(allocator, compat);

    return .{
        .model = .{
            .id = owned_id,
            .name = owned_name,
            .api = owned_api,
            .provider = owned_provider,
            .base_url = owned_base_url,
            .reasoning = model.reasoning,
            .tool_calling = model.tool_calling,
            .loaded = model.loaded,
            .input_types = owned_input_types,
            .cost = model.cost,
            .context_window = model.context_window,
            .max_tokens = model.max_tokens,
            .headers = owned_headers,
            .compat = owned_compat,
        },
    };
}

fn cloneInputTypes(allocator: std.mem.Allocator, input_types: []const []const u8) ![]const []const u8 {
    const owned_input_types = try allocator.alloc([]const u8, input_types.len);
    errdefer allocator.free(owned_input_types);

    for (input_types, 0..) |input_type, index| {
        owned_input_types[index] = try allocator.dupe(u8, input_type);
    }

    return owned_input_types;
}

fn deinitOwnedModel(allocator: std.mem.Allocator, model: *types.Model) void {
    allocator.free(model.id);
    allocator.free(model.name);
    allocator.free(model.api);
    allocator.free(model.provider);
    allocator.free(model.base_url);

    for (model.input_types) |input_type| allocator.free(input_type);
    allocator.free(model.input_types);

    if (model.headers) |*headers| {
        deinitHeaders(allocator, headers);
    }
    if (model.compat) |compat| {
        deinitJsonValue(allocator, compat);
    }
}

fn cloneHeaders(
    allocator: std.mem.Allocator,
    headers: ?std.StringHashMap([]const u8),
) !?std.StringHashMap([]const u8) {
    if (headers) |original| {
        var cloned = std.StringHashMap([]const u8).init(allocator);
        errdefer deinitHeaders(allocator, &cloned);

        var iterator = original.iterator();
        while (iterator.next()) |entry| {
            const owned_key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(owned_key);

            const owned_value = try allocator.dupe(u8, entry.value_ptr.*);
            errdefer allocator.free(owned_value);

            try cloned.put(owned_key, owned_value);
        }

        return cloned;
    }

    return null;
}

fn deinitHeaders(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |v| .{ .bool = v },
        .integer => |v| .{ .integer = v },
        .float => |v| .{ .float = v },
        .number_string => |v| .{ .number_string = try allocator.dupe(u8, v) },
        .string => |v| .{ .string = try allocator.dupe(u8, v) },
        .array => |array| blk: {
            var cloned = std.json.Array.init(allocator);
            errdefer {
                for (cloned.items) |item| deinitJsonValue(allocator, item);
                cloned.deinit();
            }
            for (array.items) |item| {
                try cloned.append(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = cloned };
        },
        .object => |object| blk: {
            var cloned = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            errdefer {
                var it = cloned.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    deinitJsonValue(allocator, entry.value_ptr.*);
                }
                cloned.deinit(allocator);
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try cloned.put(
                    allocator,
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try cloneJsonValue(allocator, entry.value_ptr.*),
                );
            }
            break :blk .{ .object = cloned };
        },
    };
}

fn deinitJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .null, .bool, .integer, .float => {},
        .number_string => |v| allocator.free(v),
        .string => |v| allocator.free(v),
        .array => |array| {
            for (array.items) |item| deinitJsonValue(allocator, item);
            var array_mut = array;
            array_mut.deinit();
        },
        .object => |object| {
            var object_mut = object;
            var iterator = object_mut.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr.*);
            }
            object_mut.deinit(allocator);
        },
    }
}

fn allocatorFreeReplace(allocator: std.mem.Allocator, target: *[]const u8, value: []const u8) !void {
    const replacement = try allocator.dupe(u8, value);
    allocator.free(target.*);
    target.* = replacement;
}

fn trimReference(reference: []const u8) []const u8 {
    return std.mem.trim(u8, reference, &std.ascii.whitespace);
}

fn equalCanonicalReference(reference: []const u8, provider: []const u8, model_id: []const u8) bool {
    const slash_index = std.mem.indexOfScalar(u8, reference, '/') orelse return false;
    return std.ascii.eqlIgnoreCase(trimReference(reference[0..slash_index]), provider) and
        std.ascii.eqlIgnoreCase(trimReference(reference[slash_index + 1 ..]), model_id);
}

fn matchesPattern(model: types.Model, pattern: []const u8) bool {
    return containsIgnoreCase(model.id, pattern) or containsIgnoreCase(model.name, pattern);
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

fn isBetterMatch(candidate: types.Model, current: types.Model) bool {
    const candidate_alias = isAlias(candidate.id);
    const current_alias = isAlias(current.id);

    if (candidate_alias != current_alias) return candidate_alias;
    return std.mem.order(u8, candidate.id, current.id) == .gt;
}

fn isAlias(id: []const u8) bool {
    if (std.mem.endsWith(u8, id, "-latest")) return true;
    if (id.len < 9) return true;

    const suffix = id[id.len - 9 ..];
    if (suffix[0] != '-') return true;
    for (suffix[1..]) |char| {
        if (!std.ascii.isDigit(char)) return true;
    }
    return false;
}

pub fn supportsXhigh(model: types.Model) bool {
    if (std.mem.indexOf(u8, model.id, "gpt-5.2") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.3") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.4") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.5") != null)
    {
        return true;
    }

    if (std.mem.indexOf(u8, model.id, "opus-4-6") != null or
        std.mem.indexOf(u8, model.id, "opus-4.6") != null or
        std.mem.indexOf(u8, model.id, "opus-4-7") != null or
        std.mem.indexOf(u8, model.id, "opus-4.7") != null)
    {
        return true;
    }

    return false;
}

const TEXT_INPUTS = [_][]const u8{"text"};
const TEXT_AND_IMAGE_INPUTS = [_][]const u8{ "text", "image" };

const BUILT_IN_PROVIDER_CONFIGS = [_]ProviderConfig{
    .{ .provider = "openai", .api = "openai-completions", .base_url = "https://api.openai.com/v1", .default_model_id = "gpt-5.4" },
    .{ .provider = "kimi", .api = "kimi-completions", .base_url = "https://api.moonshot.cn/v1", .default_model_id = "kimi-k2.6" },
    .{ .provider = "anthropic", .api = "anthropic-messages", .base_url = "https://api.anthropic.com/v1", .default_model_id = "claude-opus-4-7" },
    .{ .provider = "mistral", .api = "mistral-conversations", .base_url = "https://api.mistral.ai/v1", .default_model_id = "devstral-medium-latest" },
    .{ .provider = "openai-responses", .api = "openai-responses", .base_url = "https://api.openai.com/v1", .default_model_id = "gpt-5-mini" },
    .{ .provider = "azure-openai-responses", .api = "azure-openai-responses", .base_url = "https://example.openai.azure.com/openai/v1", .default_model_id = "gpt-5.4" },
    .{ .provider = "openai-codex", .api = "openai-codex-responses", .base_url = "https://chatgpt.com/backend-api", .default_model_id = "gpt-5.5" },
    .{ .provider = "github-copilot", .api = "openai-responses", .base_url = "https://api.individual.githubcopilot.com", .default_model_id = "gpt-5.4" },
    .{ .provider = "google", .api = "google-generative-ai", .base_url = "https://generativelanguage.googleapis.com/v1beta", .default_model_id = "gemini-3.1-pro-preview" },
    .{ .provider = "google-gemini-cli", .api = "google-gemini-cli", .base_url = "https://cloudcode-pa.googleapis.com", .default_model_id = "gemini-3.1-pro-preview" },
    .{ .provider = "google-vertex", .api = "google-vertex", .base_url = "https://us-central1-aiplatform.googleapis.com/v1/projects/test/locations/us-central1/publishers/google", .default_model_id = "gemini-3.1-pro-preview" },
    .{ .provider = "amazon-bedrock", .api = "bedrock-converse-stream", .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com", .default_model_id = "us.anthropic.claude-opus-4-6-v1" },
    .{ .provider = "xai", .api = "openai-completions", .base_url = "https://api.x.ai/v1", .default_model_id = "grok-4.20-0309-reasoning" },
    .{ .provider = "groq", .api = "openai-completions", .base_url = "https://api.groq.com/openai/v1", .default_model_id = "openai/gpt-oss-120b" },
    .{ .provider = "cerebras", .api = "openai-completions", .base_url = "https://api.cerebras.ai/v1", .default_model_id = "zai-glm-4.7" },
    .{ .provider = "openrouter", .api = "openai-completions", .base_url = "https://openrouter.ai/api/v1", .default_model_id = "moonshotai/kimi-k2.6" },
    .{ .provider = "vercel-ai-gateway", .api = "anthropic-messages", .base_url = "https://ai-gateway.vercel.sh", .default_model_id = "zai/glm-5.1" },
    .{ .provider = "zai", .api = "openai-completions", .base_url = "https://api.z.ai/api/paas/v4", .default_model_id = "glm-5.1" },
    .{ .provider = "minimax", .api = "anthropic-messages", .base_url = "https://api.minimax.io/anthropic", .default_model_id = "MiniMax-M2.7" },
    .{ .provider = "minimax-cn", .api = "anthropic-messages", .base_url = "https://api.minimaxi.com/anthropic", .default_model_id = "MiniMax-M2.7" },
    .{ .provider = "huggingface", .api = "openai-completions", .base_url = "https://router.huggingface.co/v1", .default_model_id = "moonshotai/Kimi-K2.6" },
    .{ .provider = "fireworks", .api = "anthropic-messages", .base_url = "https://api.fireworks.ai/inference", .default_model_id = "accounts/fireworks/models/kimi-k2p6" },
    .{ .provider = "opencode", .api = "openai-completions", .base_url = "https://opencode.ai/zen/v1", .default_model_id = "kimi-k2.6" },
    .{ .provider = "opencode-go", .api = "openai-completions", .base_url = "https://opencode.ai/zen/go/v1", .default_model_id = "kimi-k2.6" },
    .{ .provider = "kimi-coding", .api = "anthropic-messages", .base_url = "https://api.kimi.com/coding", .default_model_id = "kimi-for-coding" },
    .{ .provider = "faux", .api = "faux", .base_url = "http://localhost:0", .default_model_id = "faux-1" },
};

const BUILT_IN_MODELS = [_]ModelDefinition{
    .{ .provider = "openai", .id = "gpt-4.1-mini", .name = "GPT-4.1 Mini", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 128000, .max_tokens = 16384 },
    .{ .provider = "openai", .id = "gpt-5.4", .name = "GPT-5.4", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 400000, .max_tokens = 128000 },
    .{ .provider = "openai", .id = "gpt-5.5", .name = "GPT-5.5", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 400000, .max_tokens = 128000 },

    .{ .provider = "kimi", .id = "moonshot-v1-8k", .name = "Moonshot v1 8K", .reasoning = false, .input_types = TEXT_INPUTS[0..], .context_window = 8192, .max_tokens = 8192 },
    .{ .provider = "kimi", .id = "kimi-k2.6", .name = "Kimi K2.6", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 256000, .max_tokens = 32768 },

    .{ .provider = "anthropic", .id = "claude-sonnet-4-5", .name = "Claude Sonnet 4.5", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 1000000, .max_tokens = 64000 },
    .{ .provider = "anthropic", .id = "claude-sonnet-4-5-20250929", .name = "Claude Sonnet 4.5 (2025-09-29)", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 1000000, .max_tokens = 64000 },
    .{ .provider = "anthropic", .id = "claude-opus-4-7", .name = "Claude Opus 4.7", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 1000000, .max_tokens = 128000 },

    .{ .provider = "mistral", .id = "mistral-medium-latest", .name = "Mistral Medium Latest", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 131072, .max_tokens = 32768 },
    .{ .provider = "mistral", .id = "devstral-medium-latest", .name = "Devstral Medium Latest", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 131072, .max_tokens = 32768 },

    .{ .provider = "openai-responses", .id = "gpt-5-mini", .name = "GPT-5 Mini", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 200000, .max_tokens = 16384 },
    .{ .provider = "azure-openai-responses", .id = "gpt-5.4", .name = "Azure GPT-5.4", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 400000, .max_tokens = 128000 },
    .{ .provider = "openai-codex", .id = "gpt-5.5", .name = "Codex GPT-5.5", .reasoning = true, .input_types = TEXT_INPUTS[0..], .context_window = 400000, .max_tokens = 128000 },
    .{ .provider = "openai-codex", .id = "codex-mini-latest", .name = "Codex Mini Latest", .reasoning = true, .input_types = TEXT_INPUTS[0..], .context_window = 200000, .max_tokens = 32768 },
    .{ .provider = "github-copilot", .id = "gpt-5.4", .name = "GPT-5.4", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 400000, .max_tokens = 128000 },

    .{ .provider = "google", .id = "gemini-2.5-pro", .name = "Gemini 2.5 Pro", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 1048576, .max_tokens = 65536 },
    .{ .provider = "google", .id = "gemini-3.1-pro-preview", .name = "Gemini 3.1 Pro Preview", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 1048576, .max_tokens = 65536 },
    .{ .provider = "google-gemini-cli", .id = "gemini-3.1-pro-preview", .name = "Gemini CLI 3.1 Pro Preview", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 1048576, .max_tokens = 65536 },
    .{ .provider = "google-vertex", .id = "gemini-3.1-pro-preview", .name = "Vertex Gemini 3.1 Pro Preview", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 1048576, .max_tokens = 65536 },

    .{ .provider = "amazon-bedrock", .id = "anthropic.claude-3-7-sonnet-20250219-v1:0", .name = "Bedrock Claude 3.7 Sonnet", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 200000, .max_tokens = 8192 },
    .{ .provider = "amazon-bedrock", .id = "us.anthropic.claude-opus-4-6-v1", .name = "Bedrock Claude Opus 4.6 (US)", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 1000000, .max_tokens = 128000 },
    .{ .provider = "amazon-bedrock", .id = "global.anthropic.claude-opus-4-6-v1", .name = "Bedrock Claude Opus 4.6 (Global)", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 1000000, .max_tokens = 128000 },
    .{ .provider = "xai", .id = "grok-4.20-0309-reasoning", .name = "Grok 4.20 (Reasoning)", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 2000000, .max_tokens = 30000 },
    .{ .provider = "groq", .id = "openai/gpt-oss-120b", .name = "GPT OSS 120B", .reasoning = true, .input_types = TEXT_INPUTS[0..], .context_window = 131072, .max_tokens = 65536 },
    .{ .provider = "cerebras", .id = "zai-glm-4.7", .name = "Z.AI GLM-4.7", .reasoning = false, .input_types = TEXT_INPUTS[0..], .context_window = 131072, .max_tokens = 40000 },

    .{ .provider = "openrouter", .id = "moonshotai/kimi-k2.6", .name = "OpenRouter Kimi K2.6", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 262144, .max_tokens = 32768 },
    .{ .provider = "openrouter", .id = "qwen/qwen3-coder:exacto", .name = "Qwen3 Coder Exacto", .reasoning = true, .input_types = TEXT_INPUTS[0..], .context_window = 128000, .max_tokens = 8192 },
    .{ .provider = "openrouter", .id = "openai/gpt-4o:extended", .name = "GPT-4o Extended", .reasoning = false, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 128000, .max_tokens = 4096 },
    .{ .provider = "vercel-ai-gateway", .id = "zai/glm-5.1", .name = "GLM 5.1", .reasoning = true, .input_types = TEXT_INPUTS[0..], .context_window = 202800, .max_tokens = 64000 },

    .{ .provider = "zai", .id = "glm-5", .name = "GLM-5", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 256000, .max_tokens = 32768 },
    .{ .provider = "zai", .id = "glm-5.1", .name = "GLM-5.1", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 256000, .max_tokens = 32768 },
    .{ .provider = "minimax", .id = "MiniMax-M2.7", .name = "MiniMax-M2.7", .reasoning = true, .input_types = TEXT_INPUTS[0..], .context_window = 204800, .max_tokens = 131072 },
    .{ .provider = "minimax-cn", .id = "MiniMax-M2.7", .name = "MiniMax-M2.7", .reasoning = true, .input_types = TEXT_INPUTS[0..], .context_window = 204800, .max_tokens = 131072 },
    .{ .provider = "huggingface", .id = "moonshotai/Kimi-K2.6", .name = "Kimi-K2.6", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 262144, .max_tokens = 262144 },
    .{ .provider = "fireworks", .id = "accounts/fireworks/models/kimi-k2p6", .name = "Kimi K2.6", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 262000, .max_tokens = 262000 },
    .{ .provider = "opencode", .id = "kimi-k2.6", .name = "Kimi K2.6", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 262144, .max_tokens = 65536 },
    .{ .provider = "opencode-go", .id = "kimi-k2.6", .name = "Kimi K2.6 (3x limits)", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 262144, .max_tokens = 65536 },
    .{ .provider = "kimi-coding", .id = "kimi-for-coding", .name = "Kimi For Coding", .reasoning = true, .input_types = TEXT_AND_IMAGE_INPUTS[0..], .context_window = 262144, .max_tokens = 32768 },

    .{ .provider = "faux", .id = "faux-1", .name = "Faux 1", .reasoning = false, .input_types = TEXT_INPUTS[0..], .context_window = 8192, .max_tokens = 4096 },
};

test "built-in models are registered at startup" {
    resetForTesting();
    defer resetForTesting();

    try std.testing.expect(find("openai", "gpt-5.4") != null);
    try std.testing.expect(find("github-copilot", "gpt-5.4") != null);
    try std.testing.expect(find("anthropic", "claude-opus-4-7") != null);
    try std.testing.expect(find("amazon-bedrock", "us.anthropic.claude-opus-4-6-v1") != null);
    try std.testing.expect(find("fireworks", "accounts/fireworks/models/kimi-k2p6") != null);
    try std.testing.expect(find("groq", "openai/gpt-oss-120b") != null);
    try std.testing.expect(find("cerebras", "zai-glm-4.7") != null);
    try std.testing.expect(find("google", "gemini-3.1-pro-preview") != null);
    try std.testing.expect(find("huggingface", "moonshotai/Kimi-K2.6") != null);
    try std.testing.expect(find("opencode-go", "kimi-k2.6") != null);
    try std.testing.expect(find("kimi-coding", "kimi-for-coding") != null);

    const provider = getProviderConfig("openai").?;
    try std.testing.expectEqualStrings("openai-completions", provider.api);
    try std.testing.expectEqualStrings("https://api.openai.com/v1", provider.base_url);
    try std.testing.expectEqualStrings("gpt-5.4", provider.default_model_id.?);

    const copilot_provider = getProviderConfig("github-copilot").?;
    try std.testing.expectEqualStrings("openai-responses", copilot_provider.api);
    try std.testing.expectEqualStrings("gpt-5.4", copilot_provider.default_model_id.?);

    const fireworks_provider = getProviderConfig("fireworks").?;
    try std.testing.expectEqualStrings("anthropic-messages", fireworks_provider.api);
    try std.testing.expectEqualStrings("accounts/fireworks/models/kimi-k2p6", fireworks_provider.default_model_id.?);
}

test "phase4 provider expansion registers configs and default models" {
    resetForTesting();
    defer resetForTesting();

    const cases = [_]struct {
        provider: []const u8,
        api: []const u8,
        base_url: []const u8,
        default_model_id: []const u8,
    }{
        .{ .provider = "xai", .api = "openai-completions", .base_url = "https://api.x.ai/v1", .default_model_id = "grok-4.20-0309-reasoning" },
        .{ .provider = "groq", .api = "openai-completions", .base_url = "https://api.groq.com/openai/v1", .default_model_id = "openai/gpt-oss-120b" },
        .{ .provider = "cerebras", .api = "openai-completions", .base_url = "https://api.cerebras.ai/v1", .default_model_id = "zai-glm-4.7" },
        .{ .provider = "openrouter", .api = "openai-completions", .base_url = "https://openrouter.ai/api/v1", .default_model_id = "moonshotai/kimi-k2.6" },
        .{ .provider = "vercel-ai-gateway", .api = "anthropic-messages", .base_url = "https://ai-gateway.vercel.sh", .default_model_id = "zai/glm-5.1" },
        .{ .provider = "zai", .api = "openai-completions", .base_url = "https://api.z.ai/api/paas/v4", .default_model_id = "glm-5.1" },
        .{ .provider = "minimax", .api = "anthropic-messages", .base_url = "https://api.minimax.io/anthropic", .default_model_id = "MiniMax-M2.7" },
        .{ .provider = "huggingface", .api = "openai-completions", .base_url = "https://router.huggingface.co/v1", .default_model_id = "moonshotai/Kimi-K2.6" },
        .{ .provider = "fireworks", .api = "anthropic-messages", .base_url = "https://api.fireworks.ai/inference", .default_model_id = "accounts/fireworks/models/kimi-k2p6" },
        .{ .provider = "opencode", .api = "openai-completions", .base_url = "https://opencode.ai/zen/v1", .default_model_id = "kimi-k2.6" },
    };

    for (cases) |case| {
        const provider = getProviderConfig(case.provider).?;
        try std.testing.expectEqualStrings(case.api, provider.api);
        try std.testing.expectEqualStrings(case.base_url, provider.base_url);
        try std.testing.expectEqualStrings(case.default_model_id, provider.default_model_id.?);

        const model = find(case.provider, case.default_model_id).?;
        try std.testing.expectEqualStrings(case.provider, model.provider);
        try std.testing.expectEqualStrings(case.api, model.api);
        try std.testing.expectEqualStrings(case.base_url, model.base_url);
    }
}

test "model lookup by id returns unique built-in model" {
    resetForTesting();
    defer resetForTesting();

    const model = findById("gpt-5-mini").?;
    try std.testing.expectEqualStrings("openai-responses", model.provider);
    try std.testing.expectEqualStrings("openai-responses", model.api);

    try std.testing.expect(findById("gpt-5.4") == null);
}

test "scoped pattern matching resolves exact and partial models" {
    resetForTesting();
    defer resetForTesting();

    const anthropic_match = matchScopedModel("anthropic/sonnet").?;
    try std.testing.expectEqualStrings("anthropic", anthropic_match.provider);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", anthropic_match.id);

    const canonical_match = matchScopedModel("openrouter/qwen/qwen3-coder:exacto").?;
    try std.testing.expectEqualStrings("openrouter", canonical_match.provider);
    try std.testing.expectEqualStrings("qwen/qwen3-coder:exacto", canonical_match.id);

    const exact_reference = findExactReferenceMatch("qwen/qwen3-coder:exacto").?;
    try std.testing.expectEqualStrings("openrouter", exact_reference.provider);
    try std.testing.expectEqualStrings("qwen/qwen3-coder:exacto", exact_reference.id);
}

test "provider config updates propagate to models" {
    var registry = ModelRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerBuiltIns();
    try registry.registerProvider(.{
        .provider = "openai",
        .api = "openai-completions",
        .base_url = "https://proxy.example.com/v1",
        .default_model_id = "gpt-5.4",
    });

    const model = registry.find("openai", "gpt-5.4").?;
    try std.testing.expectEqualStrings("https://proxy.example.com/v1", model.base_url);
}

test "list summaries returns all registered models" {
    resetForTesting();
    defer resetForTesting();

    const summaries = try listSummaries(std.testing.allocator);
    defer std.testing.allocator.free(summaries);

    try std.testing.expect(summaries.len >= 20);

    var found_exacto = false;
    for (summaries) |summary| {
        if (std.mem.eql(u8, summary.provider, "openrouter") and std.mem.eql(u8, summary.id, "qwen/qwen3-coder:exacto")) {
            found_exacto = true;
            try std.testing.expect(summary.reasoning);
            try std.testing.expectEqual(@as(u32, 128000), summary.context_window);
        }
    }

    try std.testing.expect(found_exacto);
}

test "custom models can be registered at runtime" {
    var registry = ModelRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.registerBuiltIns();
    try registry.registerProvider(.{
        .provider = "local-openai",
        .api = "openai-completions",
        .base_url = "http://localhost:11434/v1",
        .default_model_id = "llama-3.3-70b",
    });
    try registry.registerModelDefinition(.{
        .provider = "local-openai",
        .id = "llama-3.3-70b",
        .name = "Local Llama 3.3 70B",
        .reasoning = false,
        .input_types = TEXT_INPUTS[0..],
        .context_window = 131072,
        .max_tokens = 8192,
    });

    const provider = registry.getProviderConfig("local-openai").?;
    try std.testing.expectEqualStrings("openai-completions", provider.api);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", provider.base_url);

    const model = registry.find("local-openai", "llama-3.3-70b").?;
    try std.testing.expectEqualStrings("Local Llama 3.3 70B", model.name);
    try std.testing.expectEqualStrings("openai-completions", model.api);
    try std.testing.expectEqualStrings("http://localhost:11434/v1", model.base_url);
}

test "supportsXhigh matches GPT-5.5 and Opus 4.7 families" {
    const text_inputs = &[_][]const u8{"text"};

    const gpt_model = types.Model{
        .id = "gpt-5.5",
        .name = "GPT-5.5",
        .api = "openai-responses",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = text_inputs,
        .context_window = 400000,
        .max_tokens = 128000,
    };
    try std.testing.expect(supportsXhigh(gpt_model));

    const opus_model = types.Model{
        .id = "claude-opus-4.7",
        .name = "Claude Opus 4.7",
        .api = "anthropic-messages",
        .provider = "anthropic",
        .base_url = "https://api.anthropic.com/v1",
        .reasoning = true,
        .input_types = text_inputs,
        .context_window = 1000000,
        .max_tokens = 128000,
    };
    try std.testing.expect(supportsXhigh(opus_model));

    const mini_model = types.Model{
        .id = "gpt-4.1-mini",
        .name = "GPT-4.1 Mini",
        .api = "openai-completions",
        .provider = "openai",
        .base_url = "https://api.openai.com/v1",
        .reasoning = true,
        .input_types = text_inputs,
        .context_window = 128000,
        .max_tokens = 16384,
    };
    try std.testing.expect(!supportsXhigh(mini_model));
}
