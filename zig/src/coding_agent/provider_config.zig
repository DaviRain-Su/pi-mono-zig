const std = @import("std");
const ai = @import("ai");
const common = @import("tools/common.zig");

const faux = ai.providers.faux;

pub const ResolveProviderError = error{
    MissingApiKey,
    UnknownProvider,
    InvalidFauxStopReason,
    InvalidFauxTokensPerSecond,
    InvalidFauxToolArguments,
};

const OwnedFauxMessage = struct {
    blocks: []faux.FauxContentBlock,

    fn deinit(self: *OwnedFauxMessage, allocator: std.mem.Allocator) void {
        for (self.blocks) |*block| {
            switch (block.*) {
                .tool_call => |*tool_call| {
                    allocator.free(tool_call.id);
                    allocator.free(tool_call.name);
                    common.deinitJsonValue(allocator, tool_call.arguments);
                },
                else => {},
            }
        }
        allocator.free(self.blocks);
        self.* = undefined;
    }
};

pub const ResolvedProviderConfig = struct {
    model: ai.Model,
    api_key: ?[]const u8,
    faux_registration: ?faux.FauxProviderRegistration = null,
    owned_faux_messages: ?[]OwnedFauxMessage = null,

    pub fn deinit(self: *ResolvedProviderConfig, allocator: std.mem.Allocator) void {
        if (self.faux_registration) |registration| registration.unregister();
        if (self.owned_faux_messages) |messages| {
            for (messages) |*message| message.deinit(allocator);
            allocator.free(messages);
        }
        self.* = undefined;
    }
};

pub const AvailableModel = struct {
    provider: []const u8,
    model_id: []const u8,
    display_name: []const u8,
    available: bool,
};

const ProviderDescriptor = struct {
    provider: []const u8,
    default_model: []const u8,
    api: []const u8,
    base_url: []const u8,
    env_key: ?[]const u8,
};

const PROVIDERS = [_]ProviderDescriptor{
    .{
        .provider = "openai",
        .default_model = "gpt-4",
        .api = "openai-completions",
        .base_url = "https://api.openai.com/v1",
        .env_key = "OPENAI_API_KEY",
    },
    .{
        .provider = "kimi",
        .default_model = "moonshot-v1-8k",
        .api = "kimi-completions",
        .base_url = "https://api.moonshot.cn/v1",
        .env_key = "KIMI_API_KEY",
    },
    .{
        .provider = "faux",
        .default_model = "faux-1",
        .api = "faux",
        .base_url = "http://localhost:0",
        .env_key = null,
    },
};

pub fn resolveProviderConfig(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    provider: []const u8,
    model_override: ?[]const u8,
    api_key_override: ?[]const u8,
) (ResolveProviderError || std.mem.Allocator.Error || std.fmt.ParseIntError)!ResolvedProviderConfig {
    if (std.mem.eql(u8, provider, "faux")) {
        return try resolveFauxProvider(allocator, env_map, model_override);
    }

    const descriptor = findProvider(provider) orelse return error.UnknownProvider;
    const api_key = api_key_override orelse (if (descriptor.env_key) |env_key| env_map.get(env_key) else null) orelse
        return error.MissingApiKey;
    const model_id = model_override orelse descriptor.default_model;

    return .{
        .model = .{
            .id = model_id,
            .name = model_id,
            .api = descriptor.api,
            .provider = descriptor.provider,
            .base_url = descriptor.base_url,
            .input_types = &[_][]const u8{"text"},
            .context_window = 8192,
            .max_tokens = 4096,
        },
        .api_key = api_key,
    };
}

pub fn listAvailableModels(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    current_model: ?ai.Model,
) ![]AvailableModel {
    var models = std.ArrayList(AvailableModel).empty;
    errdefer models.deinit(allocator);

    for (PROVIDERS) |descriptor| {
        const available = descriptor.env_key == null or env_map.get(descriptor.env_key.?) != null;
        if (!available) {
            if (current_model) |model| {
                if (!std.mem.eql(u8, model.provider, descriptor.provider)) continue;
            } else {
                continue;
            }
        }

        try models.append(allocator, .{
            .provider = descriptor.provider,
            .model_id = descriptor.default_model,
            .display_name = descriptor.default_model,
            .available = available,
        });
    }

    if (current_model) |model| {
        var seen = false;
        for (models.items) |entry| {
            if (std.mem.eql(u8, entry.provider, model.provider) and std.mem.eql(u8, entry.model_id, model.id)) {
                seen = true;
                break;
            }
        }
        if (!seen) {
            try models.append(allocator, .{
                .provider = model.provider,
                .model_id = model.id,
                .display_name = model.id,
                .available = true,
            });
        }
    }

    return try models.toOwnedSlice(allocator);
}

pub fn resolveProviderErrorMessage(err: anyerror, provider: []const u8) []const u8 {
    return switch (err) {
        error.MissingApiKey => if (std.mem.eql(u8, provider, "kimi"))
            "API key required. Use --api-key or set KIMI_API_KEY."
        else
            "API key required. Use --api-key or set OPENAI_API_KEY.",
        error.UnknownProvider => "Unsupported provider. Supported providers: openai, kimi, faux.",
        error.InvalidFauxStopReason => "Invalid PI_FAUX_STOP_REASON. Expected stop, length, tool_use, error, or aborted.",
        error.InvalidFauxTokensPerSecond => "Invalid PI_FAUX_TOKENS_PER_SECOND. Expected an integer.",
        error.InvalidFauxToolArguments => "Invalid PI_FAUX_TOOL_ARGS_JSON. Expected a JSON object or value.",
        else => @errorName(err),
    };
}

fn findProvider(provider: []const u8) ?ProviderDescriptor {
    for (PROVIDERS) |descriptor| {
        if (std.mem.eql(u8, descriptor.provider, provider)) return descriptor;
    }
    return null;
}

fn resolveFauxProvider(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    model_override: ?[]const u8,
) (ResolveProviderError || std.mem.Allocator.Error || std.fmt.ParseIntError)!ResolvedProviderConfig {
    const tokens_per_second = if (env_map.get("PI_FAUX_TOKENS_PER_SECOND")) |value|
        std.fmt.parseInt(u32, value, 10) catch return error.InvalidFauxTokensPerSecond
    else
        null;

    const registration = try faux.registerFauxProvider(allocator, .{
        .tokens_per_second = tokens_per_second,
    });
    errdefer registration.unregister();

    const owned_messages = try buildOwnedFauxMessages(allocator, env_map);
    errdefer {
        for (owned_messages) |*message| message.deinit(allocator);
        allocator.free(owned_messages);
    }

    if (owned_messages.len == 1) {
        try registration.setResponses(&[_]faux.FauxResponseStep{
            .{ .message = faux.fauxAssistantMessage(owned_messages[0].blocks, .{
                .stop_reason = parseFauxStopReason(env_map.get("PI_FAUX_STOP_REASON") orelse "stop") orelse
                    return error.InvalidFauxStopReason,
                .error_message = env_map.get("PI_FAUX_ERROR_MESSAGE") orelse defaultFauxErrorMessage(
                    parseFauxStopReason(env_map.get("PI_FAUX_STOP_REASON") orelse "stop") orelse .stop,
                ),
            }) },
        });
    } else {
        const final_stop_reason = parseFauxStopReason(env_map.get("PI_FAUX_STOP_REASON") orelse "stop") orelse
            return error.InvalidFauxStopReason;
        try registration.setResponses(&[_]faux.FauxResponseStep{
            .{ .message = faux.fauxAssistantMessage(owned_messages[0].blocks, .{
                .stop_reason = .tool_use,
            }) },
            .{ .message = faux.fauxAssistantMessage(owned_messages[1].blocks, .{
                .stop_reason = final_stop_reason,
                .error_message = env_map.get("PI_FAUX_ERROR_MESSAGE") orelse defaultFauxErrorMessage(final_stop_reason),
            }) },
        });
    }

    var model = registration.getModel();
    if (model_override) |override| {
        model.id = override;
        model.name = override;
    }

    return .{
        .model = model,
        .api_key = null,
        .faux_registration = registration,
        .owned_faux_messages = owned_messages,
    };
}

fn buildOwnedFauxMessages(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
) (ResolveProviderError || std.mem.Allocator.Error)![]OwnedFauxMessage {
    if (env_map.get("PI_FAUX_TOOL_NAME")) |tool_name| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, env_map.get("PI_FAUX_TOOL_ARGS_JSON") orelse "{}", .{}) catch
            return error.InvalidFauxToolArguments;
        defer parsed.deinit();

        const first_blocks = try allocator.alloc(faux.FauxContentBlock, 1);
        const tool_args = try common.cloneJsonValue(allocator, parsed.value);
        errdefer common.deinitJsonValue(allocator, tool_args);
        first_blocks[0] = faux.fauxToolCall(allocator, tool_name, tool_args, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidFauxToolArguments,
        };

        const second_blocks = try allocator.alloc(faux.FauxContentBlock, 1);
        second_blocks[0] = faux.fauxText(env_map.get("PI_FAUX_TOOL_FINAL_RESPONSE") orelse "Tool execution complete");

        const messages = try allocator.alloc(OwnedFauxMessage, 2);
        messages[0] = .{ .blocks = first_blocks };
        messages[1] = .{ .blocks = second_blocks };
        return messages;
    }

    const blocks = try allocator.alloc(faux.FauxContentBlock, 1);
    blocks[0] = faux.fauxText(env_map.get("PI_FAUX_RESPONSE") orelse "faux response");

    const messages = try allocator.alloc(OwnedFauxMessage, 1);
    messages[0] = .{ .blocks = blocks };
    return messages;
}

fn parseFauxStopReason(value: []const u8) ?ai.StopReason {
    if (std.mem.eql(u8, value, "stop")) return .stop;
    if (std.mem.eql(u8, value, "length")) return .length;
    if (std.mem.eql(u8, value, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, value, "error")) return .error_reason;
    if (std.mem.eql(u8, value, "error_reason")) return .error_reason;
    if (std.mem.eql(u8, value, "aborted")) return .aborted;
    return null;
}

fn defaultFauxErrorMessage(stop_reason: ai.StopReason) ?[]const u8 {
    return switch (stop_reason) {
        .error_reason => "Faux response failed",
        .aborted => "Request was aborted",
        else => null,
    };
}
