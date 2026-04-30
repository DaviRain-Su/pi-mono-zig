const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");
const provider_error = @import("../shared/provider_error.zig");
const transform_messages = @import("../shared/transform_messages.zig");
const simple_options = @import("../shared/simple_options.zig");
const openai = @import("openai.zig");

const SERVICE_NAME = "bedrock";
const SHA256_HEX_LEN = std.crypto.hash.sha2.Sha256.digest_length * 2;

const BedrockError = error{
    MissingAwsAccessKeyId,
    MissingAwsSecretAccessKey,
    InvalidBedrockChunk,
    InvalidBedrockEventStream,
    DuplicateBedrockMessageStart,
    MissingBedrockMessageStart,
    UnsupportedEventStreamHeaderType,
    UnexpectedBedrockMessageRole,
    UnknownStopReason,
};

const AwsCredentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    session_token: ?[]const u8 = null,

    fn deinit(self: AwsCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.access_key_id);
        allocator.free(self.secret_access_key);
        if (self.session_token) |value| allocator.free(value);
    }
};

const BedrockAuth = union(enum) {
    sigv4: AwsCredentials,
    bearer: []const u8,

    fn deinit(self: BedrockAuth, allocator: std.mem.Allocator) void {
        switch (self) {
            .sigv4 => |credentials| credentials.deinit(allocator),
            .bearer => |token| allocator.free(token),
        }
    }
};

pub const FixtureEnv = struct {
    aws_access_key_id: ?[]const u8 = null,
    aws_secret_access_key: ?[]const u8 = null,
    aws_session_token: ?[]const u8 = null,
    aws_profile: ?[]const u8 = null,
    aws_bearer_token_bedrock: ?[]const u8 = null,
    aws_region: ?[]const u8 = null,
    aws_default_region: ?[]const u8 = null,
    aws_bedrock_skip_auth: ?[]const u8 = null,
};

const RequestTimestamp = struct {
    amz_date: []const u8,
    date_stamp: []const u8,

    fn deinit(self: RequestTimestamp, allocator: std.mem.Allocator) void {
        allocator.free(self.amz_date);
        allocator.free(self.date_stamp);
    }
};

const CanonicalHeader = struct {
    name: []const u8,
    value: []const u8,

    fn deinit(self: CanonicalHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

const CurrentBlock = union(enum) {
    text: std.ArrayList(u8),
    thinking: struct {
        text: std.ArrayList(u8),
        signature: ?[]const u8,
    },
    tool_call: struct {
        id: []const u8,
        name: []const u8,
        partial_json: std.ArrayList(u8),
    },
};

const BlockEntry = struct {
    bedrock_index: usize,
    event_index: usize,
    block: CurrentBlock,
};

const StreamParseState = struct {
    saw_message_start: bool = false,
    closed_indexes: [64]usize = [_]usize{0} ** 64,
    closed_count: usize = 0,
};

fn isClosedContentBlock(state: *const StreamParseState, bedrock_index: usize) bool {
    for (state.closed_indexes[0..state.closed_count]) |closed_index| {
        if (closed_index == bedrock_index) return true;
    }
    return false;
}

fn markClosedContentBlock(state: *StreamParseState, bedrock_index: usize) !void {
    if (isClosedContentBlock(state, bedrock_index)) return BedrockError.InvalidBedrockChunk;
    if (state.closed_count >= state.closed_indexes.len) return BedrockError.InvalidBedrockChunk;
    state.closed_indexes[state.closed_count] = bedrock_index;
    state.closed_count += 1;
}

pub const BedrockProvider = struct {
    pub const api = "bedrock-converse-stream";

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
        errdefer stream_instance.deinit();

        const auth = resolveBedrockAuth(allocator, options) catch |err| {
            try emitAuthError(allocator, &stream_instance, model, authErrorMessage(err));
            return stream_instance;
        };
        defer auth.deinit(allocator);

        const timestamp = try currentTimestamp(allocator);
        defer timestamp.deinit(allocator);

        var payload = try buildRequestPayload(allocator, model, context, options);
        defer freeJsonValue(allocator, payload);

        if (options) |stream_options| {
            if (stream_options.on_payload) |callback| {
                if (try callback(allocator, payload, model)) |replacement| {
                    freeJsonValue(allocator, payload);
                    payload = replacement;
                }
            }
        }

        const json_body = try std.json.Stringify.valueAlloc(allocator, payload, .{});
        defer allocator.free(json_body);

        const request_path = try buildRequestPath(allocator, model.id);
        defer allocator.free(request_path);

        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ trimTrailingSlash(model.base_url), request_path });
        defer allocator.free(url);

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer headers.deinit();
        try putOwnedHeader(allocator, &headers, "Content-Type", "application/json");
        try mergeHeaders(allocator, &headers, model.headers);
        if (options) |stream_options| {
            try mergeHeaders(allocator, &headers, stream_options.headers);
        }
        switch (auth) {
            .sigv4 => |credentials| try signRequestHeaders(allocator, &headers, model, request_path, json_body, credentials, timestamp, options),
            .bearer => |token| {
                const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
                defer allocator.free(authorization);
                try putOwnedHeader(allocator, &headers, "Authorization", authorization);
            },
        }

        var client = try http_client.HttpClient.init(allocator, io);
        defer client.deinit();

        var response = try client.requestStreaming(.{
            .method = .POST,
            .url = url,
            .headers = headers,
            .body = json_body,
            .aborted = if (options) |stream_options| stream_options.signal else null,
        });
        defer response.deinit();

        if (options) |stream_options| {
            if (stream_options.on_response) |callback| {
                if (response.response_headers) |response_headers| {
                    try callback(response.status, response_headers, model);
                } else {
                    var response_headers = std.StringHashMap([]const u8).init(allocator);
                    defer response_headers.deinit();
                    try callback(response.status, response_headers, model);
                }
            }
        }

        if (response.status != 200) {
            const response_body = try response.readAllBounded(allocator, provider_error.MAX_PROVIDER_ERROR_BODY_READ_BYTES);
            defer allocator.free(response_body);
            try provider_error.pushHttpStatusError(allocator, &stream_instance, model, response.status, response_body);
            return stream_instance;
        }

        try parseStreamBody(allocator, &stream_instance, &response, model, options);
        return stream_instance;
    }

    pub fn streamSimple(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        const base = buildStreamSimpleBedrockOptions(model, options);
        return stream(allocator, io, model, context, base);
    }
};

fn buildStreamSimpleBedrockOptions(model: types.Model, options: ?types.StreamOptions) types.StreamOptions {
    const stream_options = options orelse types.StreamOptions{};
    var base = types.StreamOptions{
        .temperature = stream_options.temperature,
        .max_tokens = stream_options.max_tokens orelse defaultSimpleMaxTokens(model),
        .api_key = stream_options.api_key,
        .transport = stream_options.transport,
        .cache_retention = stream_options.cache_retention,
        .session_id = stream_options.session_id,
        .headers = stream_options.headers,
        .timeout_ms = stream_options.timeout_ms,
        .max_retries = stream_options.max_retries,
        .on_payload = stream_options.on_payload,
        .on_response = stream_options.on_response,
        .signal = stream_options.signal,
        .max_retry_delay_ms = stream_options.max_retry_delay_ms,
        .metadata = stream_options.metadata,
        .bedrock_region = stream_options.bedrock_region,
        .bedrock_profile = stream_options.bedrock_profile,
        .bedrock_bearer_token = stream_options.bedrock_bearer_token,
        .bedrock_tool_choice = stream_options.bedrock_tool_choice,
        .bedrock_interleaved_thinking = stream_options.bedrock_interleaved_thinking,
        .bedrock_thinking_display = stream_options.bedrock_thinking_display,
        .bedrock_request_metadata = stream_options.bedrock_request_metadata,
    };

    const reasoning = stream_options.bedrock_reasoning orelse return base;
    if (isAnthropicClaudeModel(model)) {
        if (supportsAdaptiveThinking(model.id, model.name)) {
            base.bedrock_reasoning = reasoning;
            base.bedrock_thinking_budgets = stream_options.bedrock_thinking_budgets;
            return base;
        }

        const adjusted = simple_options.adjustMaxTokensForThinking(
            base.max_tokens orelse 0,
            model.max_tokens,
            reasoning,
            stream_options.bedrock_thinking_budgets,
        );
        base.max_tokens = adjusted.max_tokens;
        var budgets = stream_options.bedrock_thinking_budgets orelse types.ThinkingBudgets{};
        switch (simple_options.clampReasoning(reasoning).?) {
            .minimal => budgets.minimal = adjusted.thinking_budget,
            .low => budgets.low = adjusted.thinking_budget,
            .medium => budgets.medium = adjusted.thinking_budget,
            .high, .xhigh => budgets.high = adjusted.thinking_budget,
        }
        base.bedrock_reasoning = reasoning;
        base.bedrock_thinking_budgets = budgets;
        return base;
    }

    base.bedrock_reasoning = reasoning;
    base.bedrock_thinking_budgets = stream_options.bedrock_thinking_budgets;
    return base;
}

fn defaultSimpleMaxTokens(model: types.Model) ?u32 {
    if (model.max_tokens == 0) return null;
    return @min(model.max_tokens, @as(u32, 32000));
}

pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    return try buildRequestPayloadWithFixtureEnv(allocator, model, context, options, null);
}

fn buildRequestPayloadWithFixtureEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    fixture_env: ?FixtureEnv,
) !std.json.Value {
    var payload = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer payload.deinit(allocator);

    const cache_retention = resolveOptionsCacheRetention(options, processCacheRetentionEnv());

    try payload.put(allocator, try allocator.dupe(u8, "messages"), try buildMessagesValue(allocator, model, context.messages, cache_retention));

    if (context.system_prompt) |system_prompt| {
        try payload.put(allocator, try allocator.dupe(u8, "system"), try buildSystemValue(allocator, system_prompt, model, cache_retention));
    }

    try payload.put(allocator, try allocator.dupe(u8, "inferenceConfig"), try buildInferenceConfigValue(allocator, model, options));

    if (context.tools) |tools| {
        if (tools.len > 0) {
            if (try buildToolConfigValue(allocator, tools, options)) |tool_config| {
                try payload.put(allocator, try allocator.dupe(u8, "toolConfig"), tool_config);
            }
        }
    }

    if (options) |stream_options| {
        if (try buildRequestMetadataValue(allocator, stream_options.bedrock_request_metadata)) |request_metadata| {
            try payload.put(allocator, try allocator.dupe(u8, "requestMetadata"), request_metadata);
        }
        if (try buildAdditionalModelRequestFieldsValue(allocator, model, stream_options, fixture_env)) |additional_fields| {
            try payload.put(allocator, try allocator.dupe(u8, "additionalModelRequestFields"), additional_fields);
        }
    }

    return .{ .object = payload };
}

pub fn buildRequestSnapshotValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    mode: []const u8,
) !std.json.Value {
    return try buildRequestSnapshotValueWithFixtureEnv(allocator, model, context, options, mode, null);
}

pub fn buildRequestSnapshotValueWithFixtureEnv(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
    mode: []const u8,
    fixture_env: ?FixtureEnv,
) !std.json.Value {
    var request = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer request.deinit(allocator);
    try request.put(allocator, try allocator.dupe(u8, "mode"), .{ .string = try allocator.dupe(u8, mode) });

    var snapshot_options = options;
    var simple_snapshot_options: types.StreamOptions = undefined;
    if (std.mem.eql(u8, mode, "streamSimpleBedrock") or std.mem.eql(u8, mode, "streamSimple")) {
        simple_snapshot_options = buildStreamSimpleBedrockOptions(model, options);
        snapshot_options = simple_snapshot_options;
    }

    var payload = try buildRequestPayloadWithFixtureEnv(allocator, model, context, snapshot_options, fixture_env);
    errdefer freeJsonValue(allocator, payload);
    try payload.object.put(allocator, try allocator.dupe(u8, "modelId"), .{ .string = try allocator.dupe(u8, model.id) });
    if (snapshot_options) |stream_options| {
        if (stream_options.on_payload) |callback| {
            if (try callback(allocator, payload, model)) |replacement| {
                freeJsonValue(allocator, payload);
                payload = replacement;
            }
        }
    }
    try request.put(allocator, try allocator.dupe(u8, "payload"), payload);
    return .{ .object = request };
}

pub fn buildRequestSurfaceSnapshotValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
    payload: std.json.Value,
    fixture_env: FixtureEnv,
) !std.json.Value {
    _ = payload;
    const request_path = try buildRequestPath(allocator, model.id);
    defer allocator.free(request_path);
    const region = resolveFixtureRegion(model.base_url, options, fixture_env);
    const endpoint = try resolveFixtureEndpoint(allocator, model.base_url, region, fixture_env, options);
    defer if (endpoint.value) |value| allocator.free(value);

    var root = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer root.deinit(allocator);
    try root.put(allocator, try allocator.dupe(u8, "method"), .{ .string = try allocator.dupe(u8, "POST") });
    try root.put(allocator, try allocator.dupe(u8, "path"), .{ .string = try allocator.dupe(u8, request_path) });
    if (endpoint.value) |base_url| {
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, request_path });
        try root.put(allocator, try allocator.dupe(u8, "url"), .{ .string = url });
    } else {
        try root.put(allocator, try allocator.dupe(u8, "url"), .{ .string = try allocator.dupe(u8, "sdk-profile-resolution") });
    }

    var endpoint_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try endpoint_object.put(allocator, try allocator.dupe(u8, "mode"), .{ .string = try allocator.dupe(u8, endpoint.mode) });
    if (endpoint.value) |value| try endpoint_object.put(allocator, try allocator.dupe(u8, "value"), .{ .string = try allocator.dupe(u8, value) });
    try root.put(allocator, try allocator.dupe(u8, "endpoint"), .{ .object = endpoint_object });

    var region_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try region_object.put(allocator, try allocator.dupe(u8, "source"), .{ .string = try allocator.dupe(u8, region.source) });
    if (region.value) |value| try region_object.put(allocator, try allocator.dupe(u8, "value"), .{ .string = try allocator.dupe(u8, value) });
    try root.put(allocator, try allocator.dupe(u8, "region"), .{ .object = region_object });

    var client_config = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    if (options) |stream_options| {
        if (stream_options.bedrock_profile) |profile| try client_config.put(allocator, try allocator.dupe(u8, "profile"), .{ .string = try allocator.dupe(u8, profile) });
    }
    if (fixture_env.aws_profile) |profile| try client_config.put(allocator, try allocator.dupe(u8, "envProfile"), .{ .string = try allocator.dupe(u8, profile) });
    if (std.mem.eql(u8, endpoint.mode, "explicit")) {
        if (endpoint.value) |value| try client_config.put(allocator, try allocator.dupe(u8, "endpoint"), .{ .string = try allocator.dupe(u8, value) });
    }
    if (region.value) |value| try client_config.put(allocator, try allocator.dupe(u8, "region"), .{ .string = try allocator.dupe(u8, value) });
    try root.put(allocator, try allocator.dupe(u8, "clientConfig"), .{ .object = client_config });

    const auth = try buildFixtureAuthSnapshot(allocator, options, fixture_env, region);
    try root.put(allocator, try allocator.dupe(u8, "auth"), auth);
    try root.put(allocator, try allocator.dupe(u8, "redaction"), .{ .string = try allocator.dupe(u8, "secrets-redacted") });
    return .{ .object = root };
}

pub fn buildStreamSnapshotValueFromLocalEvents(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    events: []const std.json.Value,
) !std.json.Value {
    return buildStreamSnapshotValueFromLocalEventsWithTerminalFailure(allocator, io, model, events, null);
}

pub const FixtureTerminalFailureTiming = enum {
    before_events,
    after_events,
};

pub const FixtureTerminalFailure = struct {
    timing: FixtureTerminalFailureTiming,
    stop_reason: types.StopReason,
    message: []const u8,
};

pub fn buildStreamSnapshotValueFromLocalEventsWithTerminalFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    events: []const std.json.Value,
    terminal_failure: ?FixtureTerminalFailure,
) !std.json.Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    var stream_instance = event_stream.createAssistantMessageEventStream(parse_allocator, io);
    defer stream_instance.deinit();

    var output = initOutput(model);
    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(parse_allocator);
    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(parse_allocator);
    var active_blocks = std.ArrayList(BlockEntry).empty;
    defer {
        for (active_blocks.items) |*entry| deinitCurrentBlock(parse_allocator, &entry.block);
        active_blocks.deinit(parse_allocator);
    }
    var state = StreamParseState{};

    if (terminal_failure) |failure| {
        if (failure.timing == .before_events) {
            try emitStreamFailureMessage(parse_allocator, &stream_instance, &output, &content_blocks, &tool_calls, &active_blocks, failure.stop_reason, failure.message);
            return try snapshotStreamEvents(allocator, parse_allocator, &stream_instance);
        }
    }

    for (events) |event_value| {
        var failed = false;
        handleEventValue(parse_allocator, &stream_instance, event_value, &output, &content_blocks, &tool_calls, &active_blocks, &state, model) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(parse_allocator, &stream_instance, &output, &content_blocks, &tool_calls, &active_blocks, model, err);
                failed = true;
            },
        };
        if (failed) break;
        if (stream_instance.result() != null) break;
    }
    if (stream_instance.result() == null) {
        if (terminal_failure) |failure| {
            if (failure.timing == .after_events) {
                try emitStreamFailureMessage(parse_allocator, &stream_instance, &output, &content_blocks, &tool_calls, &active_blocks, failure.stop_reason, failure.message);
            } else {
                try finalizeOutput(parse_allocator, &stream_instance, &output, &content_blocks, &tool_calls, &active_blocks, &state, model);
            }
        } else {
            try finalizeOutput(parse_allocator, &stream_instance, &output, &content_blocks, &tool_calls, &active_blocks, &state, model);
        }
    }

    return try snapshotStreamEvents(allocator, parse_allocator, &stream_instance);
}

pub fn buildStreamSnapshotValueFromBinaryBody(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: types.Model,
    body: []const u8,
) !std.json.Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    var stream_instance = event_stream.createAssistantMessageEventStream(parse_allocator, io);
    defer stream_instance.deinit();
    try parseEventStreamFrames(parse_allocator, &stream_instance, body, model, null);
    return try snapshotStreamEvents(allocator, parse_allocator, &stream_instance);
}

fn buildSystemValue(
    allocator: std.mem.Allocator,
    system_prompt: []const u8,
    model: types.Model,
    cache_retention: types.CacheRetention,
) !std.json.Value {
    var blocks = std.json.Array.init(allocator);
    errdefer blocks.deinit();
    try blocks.append(try buildTextBlockObject(allocator, system_prompt));
    if (cache_retention != .none and supportsPromptCaching(model)) {
        try blocks.append(try buildCachePointBlockObject(allocator, cache_retention));
    }
    return .{ .array = blocks };
}

fn buildInferenceConfigValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
) !std.json.Value {
    _ = model;
    var config = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer config.deinit(allocator);

    if (options) |stream_options| {
        if (stream_options.max_tokens) |max_tokens| {
            try config.put(allocator, try allocator.dupe(u8, "maxTokens"), .{ .integer = @intCast(max_tokens) });
        }
        if (stream_options.temperature) |temperature| {
            try config.put(allocator, try allocator.dupe(u8, "temperature"), .{ .float = temperature });
        }
    }

    return .{ .object = config };
}

fn buildRequestMetadataValue(allocator: std.mem.Allocator, metadata: ?std.json.Value) !?std.json.Value {
    if (metadata) |value| {
        if (value != .object) return null;
        var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        errdefer object.deinit(allocator);

        var iterator = value.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            try object.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), .{ .string = try allocator.dupe(u8, entry.value_ptr.*.string) });
        }
        return .{ .object = object };
    }
    return null;
}

fn processCacheRetentionEnv() ?[]const u8 {
    const value = std.c.getenv("PI_CACHE_RETENTION") orelse return null;
    return std.mem.span(value);
}

fn resolveCacheRetention(cache_retention: types.CacheRetention, pi_cache_retention_env: ?[]const u8) types.CacheRetention {
    return switch (cache_retention) {
        .unset => if (pi_cache_retention_env) |value|
            if (std.mem.eql(u8, value, "long")) .long else .short
        else
            .short,
        else => cache_retention,
    };
}

fn resolveOptionsCacheRetention(options: ?types.StreamOptions, pi_cache_retention_env: ?[]const u8) types.CacheRetention {
    return resolveCacheRetention(if (options) |stream_options| stream_options.cache_retention else .unset, pi_cache_retention_env);
}

fn buildCachePointBlockObject(allocator: std.mem.Allocator, cache_retention: types.CacheRetention) !std.json.Value {
    var cache_point = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try cache_point.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "default") });
    if (cache_retention == .long) {
        try cache_point.put(allocator, try allocator.dupe(u8, "ttl"), .{ .string = try allocator.dupe(u8, "1h") });
    }

    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "cachePoint"), .{ .object = cache_point });
    return .{ .object = object };
}

fn buildImageBlockObject(allocator: std.mem.Allocator, image: types.ImageContent) !std.json.Value {
    const format = try bedrockImageFormat(image.mime_type);

    var source = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try source.put(allocator, try allocator.dupe(u8, "bytes"), .{ .string = try allocator.dupe(u8, image.data) });

    var image_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try image_object.put(allocator, try allocator.dupe(u8, "source"), .{ .object = source });
    try image_object.put(allocator, try allocator.dupe(u8, "format"), .{ .string = try allocator.dupe(u8, format) });

    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "image"), .{ .object = image_object });
    return .{ .object = object };
}

fn bedrockImageFormat(mime_type: []const u8) ![]const u8 {
    if (std.mem.eql(u8, mime_type, "image/jpeg") or std.mem.eql(u8, mime_type, "image/jpg")) return "jpeg";
    if (std.mem.eql(u8, mime_type, "image/png")) return "png";
    if (std.mem.eql(u8, mime_type, "image/gif")) return "gif";
    if (std.mem.eql(u8, mime_type, "image/webp")) return "webp";
    return error.UnknownBedrockImageType;
}

fn normalizeBedrockToolCallIdForTransform(
    allocator: std.mem.Allocator,
    id: []const u8,
    model: types.Model,
    source: types.AssistantMessage,
) ![]const u8 {
    _ = model;
    _ = source;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    for (id) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '_' or char == '-') {
            try output.append(allocator, char);
        } else {
            try output.append(allocator, '_');
        }
        if (output.items.len == 64) break;
    }
    return try output.toOwnedSlice(allocator);
}

fn modelMatchCandidateContains(model: types.Model, needle: []const u8) bool {
    return textMatchCandidateContains(model.id, needle) or textMatchCandidateContains(model.name, needle);
}

fn textMatchCandidateContains(value: []const u8, needle: []const u8) bool {
    var buffer: [512]u8 = undefined;
    const lower = std.ascii.lowerString(buffer[0..@min(value.len, buffer.len)], value[0..@min(value.len, buffer.len)]);
    if (std.mem.indexOf(u8, lower, needle) != null) return true;
    var normalized: [512]u8 = undefined;
    for (lower, 0..) |char, index| {
        normalized[index] = switch (char) {
            ' ', '_', '.', ':' => '-',
            else => char,
        };
    }
    return std.mem.indexOf(u8, normalized[0..lower.len], needle) != null;
}

fn isAnthropicClaudeModel(model: types.Model) bool {
    return modelMatchCandidateContains(model, "anthropic.claude") or
        modelMatchCandidateContains(model, "anthropic/claude") or
        modelMatchCandidateContains(model, "claude");
}

fn supportsAdaptiveThinking(model_id: []const u8, model_name: []const u8) bool {
    const model = types.Model{
        .id = model_id,
        .name = model_name,
        .api = "",
        .provider = "",
        .base_url = "",
        .input_types = &[_][]const u8{},
        .context_window = 0,
        .max_tokens = 0,
    };
    return modelMatchCandidateContains(model, "opus-4-6") or
        modelMatchCandidateContains(model, "opus-4-7") or
        modelMatchCandidateContains(model, "sonnet-4-6");
}

fn supportsPromptCaching(model: types.Model) bool {
    if (!modelMatchCandidateContains(model, "claude")) {
        const forced = std.c.getenv("AWS_BEDROCK_FORCE_CACHE") orelse return false;
        return std.mem.eql(u8, std.mem.span(forced), "1");
    }
    return modelMatchCandidateContains(model, "-4-") or
        modelMatchCandidateContains(model, "claude-3-7-sonnet") or
        modelMatchCandidateContains(model, "claude-3-5-haiku");
}

fn isGovCloudBedrockTarget(model: types.Model, options: types.StreamOptions, fixture_env: ?FixtureEnv) bool {
    if (configuredBedrockRegion(options, fixture_env)) |region| {
        if (asciiStartsWithIgnoreCase(region, "us-gov-")) return true;
    }
    return asciiStartsWithIgnoreCase(model.id, "us-gov.") or asciiStartsWithIgnoreCase(model.id, "arn:aws-us-gov:");
}

fn configuredBedrockRegion(options: types.StreamOptions, fixture_env: ?FixtureEnv) ?[]const u8 {
    if (options.bedrock_region) |region| return region;
    if (fixture_env) |env| {
        if (nonEmpty(env.aws_region)) |region| return region;
        if (nonEmpty(env.aws_default_region)) |region| return region;
        return null;
    }
    if (std.c.getenv("AWS_REGION")) |region| {
        const value = std.mem.span(region);
        if (value.len > 0) return value;
    }
    if (std.c.getenv("AWS_DEFAULT_REGION")) |region| {
        const value = std.mem.span(region);
        if (value.len > 0) return value;
    }
    return null;
}

fn asciiStartsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn mapThinkingLevelToEffort(level: types.ThinkingLevel, model: types.Model) []const u8 {
    return switch (level) {
        .minimal, .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => if (modelMatchCandidateContains(model, "opus-4-6"))
            "max"
        else if (modelMatchCandidateContains(model, "opus-4-7"))
            "xhigh"
        else
            "high",
    };
}

fn buildAdditionalModelRequestFieldsValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: types.StreamOptions,
    fixture_env: ?FixtureEnv,
) !?std.json.Value {
    const reasoning = options.bedrock_reasoning orelse return null;
    if (!model.reasoning or !isAnthropicClaudeModel(model)) return null;

    const display = if (isGovCloudBedrockTarget(model, options, fixture_env)) null else options.bedrock_thinking_display orelse .summarized;
    var result = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer result.deinit(allocator);

    if (supportsAdaptiveThinking(model.id, model.name)) {
        var thinking = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try thinking.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "adaptive") });
        if (display) |display_value| {
            try thinking.put(allocator, try allocator.dupe(u8, "display"), .{ .string = try allocator.dupe(u8, thinkingDisplayString(display_value)) });
        }
        try result.put(allocator, try allocator.dupe(u8, "thinking"), .{ .object = thinking });

        var output_config = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try output_config.put(allocator, try allocator.dupe(u8, "effort"), .{ .string = try allocator.dupe(u8, mapThinkingLevelToEffort(reasoning, model)) });
        try result.put(allocator, try allocator.dupe(u8, "output_config"), .{ .object = output_config });
    } else {
        const budgets = options.bedrock_thinking_budgets orelse types.ThinkingBudgets{};
        const budget = switch (reasoning) {
            .minimal => budgets.minimal,
            .low => budgets.low,
            .medium => budgets.medium,
            .high, .xhigh => budgets.high,
        };
        var thinking = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try thinking.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "enabled") });
        try thinking.put(allocator, try allocator.dupe(u8, "budget_tokens"), .{ .integer = budget });
        if (display) |display_value| {
            try thinking.put(allocator, try allocator.dupe(u8, "display"), .{ .string = try allocator.dupe(u8, thinkingDisplayString(display_value)) });
        }
        try result.put(allocator, try allocator.dupe(u8, "thinking"), .{ .object = thinking });
        if (options.bedrock_interleaved_thinking orelse true) {
            var beta = std.json.Array.init(allocator);
            try beta.append(.{ .string = try allocator.dupe(u8, "interleaved-thinking-2025-05-14") });
            try result.put(allocator, try allocator.dupe(u8, "anthropic_beta"), .{ .array = beta });
        }
    }

    return .{ .object = result };
}

fn thinkingDisplayString(display: types.AnthropicThinkingDisplay) []const u8 {
    return switch (display) {
        .summarized => "summarized",
        .omitted => "omitted",
    };
}

fn buildMessagesValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    messages: []const types.Message,
    cache_retention: types.CacheRetention,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();

    const transformed_messages = try transform_messages.transformMessages(allocator, messages, model, normalizeBedrockToolCallIdForTransform);
    defer transform_messages.freeMessages(allocator, transformed_messages);

    var index: usize = 0;
    while (index < transformed_messages.len) : (index += 1) {
        switch (transformed_messages[index]) {
            .user => |user| try array.append(try buildUserMessageValue(allocator, model, user)),
            .assistant => |assistant| {
                if (types.shouldReplayAssistantInProviderContext(assistant)) {
                    if (try buildAssistantMessageValue(allocator, model, assistant)) |message_value| {
                        try array.append(message_value);
                    }
                }
            },
            .tool_result => {
                const grouped = try buildToolResultMessageValue(allocator, model, transformed_messages[index..]);
                try array.append(grouped.value);
                index += grouped.consumed - 1;
            },
        }
    }

    if (cache_retention != .none and supportsPromptCaching(model) and array.items.len > 0) {
        const last_message = &array.items[array.items.len - 1];
        if (last_message.* == .object) {
            const role = last_message.object.get("role");
            const content = last_message.object.getPtr("content");
            if (role != null and role.? == .string and std.mem.eql(u8, role.?.string, "user") and content != null and content.?.* == .array) {
                try content.?.array.append(try buildCachePointBlockObject(allocator, cache_retention));
            }
        }
    }

    return .{ .array = array };
}

fn buildUserMessageValue(allocator: std.mem.Allocator, model: types.Model, user: types.UserMessage) !std.json.Value {
    _ = model;
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();

    for (user.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
                try content.append(try buildTextBlockObject(allocator, text.text));
            },
            .image => |image| try content.append(try buildImageBlockObject(allocator, image)),
            .thinking, .tool_call => {},
        }
    }

    if (content.items.len == 0) try content.append(try buildTextBlockObject(allocator, ""));
    return try buildRoleMessageObject(allocator, "user", .{ .array = content });
}

fn buildAssistantMessageValue(allocator: std.mem.Allocator, model: types.Model, assistant: types.AssistantMessage) !?std.json.Value {
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();

    for (assistant.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
                try content.append(try buildTextBlockObject(allocator, text.text));
            },
            .thinking => |thinking| {
                if (std.mem.trim(u8, thinking.thinking, " \t\r\n").len == 0) continue;
                if (isAnthropicClaudeModel(model)) {
                    if (types.thinkingSignature(thinking)) |signature| {
                        var reasoning_text = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                        const sanitized = try openai.sanitizeSurrogates(allocator, thinking.thinking);
                        defer allocator.free(sanitized);
                        try reasoning_text.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, sanitized) });
                        try reasoning_text.put(allocator, try allocator.dupe(u8, "signature"), .{ .string = try allocator.dupe(u8, signature) });

                        var reasoning_content = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                        try reasoning_content.put(allocator, try allocator.dupe(u8, "reasoningText"), .{ .object = reasoning_text });

                        var block_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                        try block_object.put(allocator, try allocator.dupe(u8, "reasoningContent"), .{ .object = reasoning_content });
                        try content.append(.{ .object = block_object });
                    } else {
                        try content.append(try buildTextBlockObject(allocator, thinking.thinking));
                    }
                } else {
                    var reasoning_text = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    const sanitized = try openai.sanitizeSurrogates(allocator, thinking.thinking);
                    defer allocator.free(sanitized);
                    try reasoning_text.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, sanitized) });

                    var reasoning_content = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    try reasoning_content.put(allocator, try allocator.dupe(u8, "reasoningText"), .{ .object = reasoning_text });

                    var block_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    try block_object.put(allocator, try allocator.dupe(u8, "reasoningContent"), .{ .object = reasoning_content });
                    try content.append(.{ .object = block_object });
                }
            },
            .image => |image| try content.append(try buildImageBlockObject(allocator, image)),
            .tool_call => |tool_call| {
                var tool_use = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try tool_use.put(allocator, try allocator.dupe(u8, "toolUseId"), .{ .string = try allocator.dupe(u8, tool_call.id) });
                try tool_use.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool_call.name) });
                try tool_use.put(allocator, try allocator.dupe(u8, "input"), try cloneJsonValue(allocator, tool_call.arguments));

                var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try object.put(allocator, try allocator.dupe(u8, "toolUse"), .{ .object = tool_use });
                try content.append(.{ .object = object });
            },
        }
    }

    if (!types.hasInlineToolCalls(assistant)) {
        if (assistant.tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                var tool_use = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try tool_use.put(allocator, try allocator.dupe(u8, "toolUseId"), .{ .string = try allocator.dupe(u8, tool_call.id) });
                try tool_use.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool_call.name) });
                try tool_use.put(allocator, try allocator.dupe(u8, "input"), try cloneJsonValue(allocator, tool_call.arguments));

                var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try object.put(allocator, try allocator.dupe(u8, "toolUse"), .{ .object = tool_use });
                try content.append(.{ .object = object });
            }
        }
    }

    if (content.items.len == 0) return null;
    return try buildRoleMessageObject(allocator, "assistant", .{ .array = content });
}

fn buildToolResultMessageValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    messages: []const types.Message,
) !struct { value: std.json.Value, consumed: usize } {
    _ = model;
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();

    var consumed: usize = 0;
    while (consumed < messages.len) : (consumed += 1) {
        switch (messages[consumed]) {
            .tool_result => |tool_result| {
                var tool_result_blocks = std.json.Array.init(allocator);
                errdefer tool_result_blocks.deinit();
                for (tool_result.content) |block| {
                    switch (block) {
                        .text => |text| try tool_result_blocks.append(try buildTextBlockObject(allocator, text.text)),
                        .image => |image| try tool_result_blocks.append(try buildImageBlockObject(allocator, image)),
                        .thinking => |thinking| try tool_result_blocks.append(try buildTextBlockObject(allocator, thinking.thinking)),
                        .tool_call => {},
                    }
                }
                if (tool_result_blocks.items.len == 0) {
                    try tool_result_blocks.append(try buildTextBlockObject(allocator, ""));
                }

                var tool_result_obj = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try tool_result_obj.put(allocator, try allocator.dupe(u8, "toolUseId"), .{ .string = try allocator.dupe(u8, tool_result.tool_call_id) });
                try tool_result_obj.put(allocator, try allocator.dupe(u8, "content"), .{ .array = tool_result_blocks });
                try tool_result_obj.put(
                    allocator,
                    try allocator.dupe(u8, "status"),
                    .{ .string = try allocator.dupe(u8, if (tool_result.is_error) "error" else "success") },
                );

                var wrapper = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try wrapper.put(allocator, try allocator.dupe(u8, "toolResult"), .{ .object = tool_result_obj });
                try content.append(.{ .object = wrapper });
            },
            else => break,
        }
    }

    return .{
        .value = try buildRoleMessageObject(allocator, "user", .{ .array = content }),
        .consumed = consumed,
    };
}

fn buildToolConfigValue(
    allocator: std.mem.Allocator,
    tools: []const types.Tool,
    options: ?types.StreamOptions,
) !?std.json.Value {
    if (options) |stream_options| {
        if (stream_options.bedrock_tool_choice) |tool_choice| {
            if (tool_choice == .none) return null;
        }
    }

    var tool_entries = std.json.Array.init(allocator);
    errdefer tool_entries.deinit();
    for (tools) |tool| {
        var tool_spec = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try tool_spec.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool.name) });
        try tool_spec.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, tool.description) });

        var input_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try input_schema.put(allocator, try allocator.dupe(u8, "json"), try cloneJsonValue(allocator, tool.parameters));
        try tool_spec.put(allocator, try allocator.dupe(u8, "inputSchema"), .{ .object = input_schema });

        var tool_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try tool_object.put(allocator, try allocator.dupe(u8, "toolSpec"), .{ .object = tool_spec });
        try tool_entries.append(.{ .object = tool_object });
    }

    var config = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try config.put(allocator, try allocator.dupe(u8, "tools"), .{ .array = tool_entries });

    if (options) |stream_options| {
        if (stream_options.bedrock_tool_choice) |tool_choice| {
            if (try buildToolChoiceValue(allocator, tool_choice)) |choice_value| {
                try config.put(allocator, try allocator.dupe(u8, "toolChoice"), choice_value);
            }
        }
    }

    return .{ .object = config };
}

fn buildToolChoiceValue(allocator: std.mem.Allocator, tool_choice: types.BedrockToolChoice) !?std.json.Value {
    switch (tool_choice) {
        .none => return null,
        .auto => return .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{try allocator.dupe(u8, "auto")}, &[_]std.json.Value{.{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) }}) },
        .any => return .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{try allocator.dupe(u8, "any")}, &[_]std.json.Value{.{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) }}) },
        .tool => |name| {
            var tool = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            try tool.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, name) });
            var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            try object.put(allocator, try allocator.dupe(u8, "tool"), .{ .object = tool });
            return .{ .object = object };
        },
    }
}

fn buildTextBlockObject(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    const sanitized = try openai.sanitizeSurrogates(allocator, text);
    defer allocator.free(sanitized);
    try object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, sanitized) });
    return .{ .object = object };
}

fn buildRoleMessageObject(allocator: std.mem.Allocator, role: []const u8, content: std.json.Value) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, role) });
    try object.put(allocator, try allocator.dupe(u8, "content"), content);
    return .{ .object = object };
}

fn resolveAwsCredentials(allocator: std.mem.Allocator) !AwsCredentials {
    const access_key_id = try loadEnvRequired(allocator, "AWS_ACCESS_KEY_ID", BedrockError.MissingAwsAccessKeyId);
    errdefer allocator.free(access_key_id);
    const secret_access_key = try loadEnvRequired(allocator, "AWS_SECRET_ACCESS_KEY", BedrockError.MissingAwsSecretAccessKey);
    errdefer allocator.free(secret_access_key);
    const session_token = try loadEnvOptional(allocator, "AWS_SESSION_TOKEN");

    return .{
        .access_key_id = access_key_id,
        .secret_access_key = secret_access_key,
        .session_token = session_token,
    };
}

fn resolveBedrockAuth(allocator: std.mem.Allocator, options: ?types.StreamOptions) !BedrockAuth {
    const skip_auth = if (try loadEnvOptional(allocator, "AWS_BEDROCK_SKIP_AUTH")) |value| blk: {
        defer allocator.free(value);
        break :blk std.mem.eql(u8, value, "1");
    } else false;

    if (skip_auth) {
        return .{ .sigv4 = .{
            .access_key_id = try allocator.dupe(u8, "dummy-access-key"),
            .secret_access_key = try allocator.dupe(u8, "dummy-secret-key"),
        } };
    }

    if (options) |stream_options| {
        if (stream_options.bedrock_bearer_token) |token| {
            return .{ .bearer = try allocator.dupe(u8, token) };
        }
    }
    if (try loadEnvOptional(allocator, "AWS_BEARER_TOKEN_BEDROCK")) |token| {
        return .{ .bearer = token };
    }

    return .{ .sigv4 = try resolveAwsCredentials(allocator) };
}

fn loadEnvRequired(allocator: std.mem.Allocator, name: []const u8, comptime err: anytype) ![]u8 {
    return try loadEnvOptional(allocator, name) orelse err;
}

fn loadEnvOptional(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    const value = std.c.getenv(name_z) orelse return null;
    const value_slice = std.mem.span(value);
    if (value_slice.len == 0) return null;
    return try allocator.dupe(u8, value_slice);
}

fn currentTimestamp(allocator: std.mem.Allocator) !RequestTimestamp {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(tv.sec) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return .{
        .amz_date = try std.fmt.allocPrint(
            allocator,
            "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z",
            .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1, day_seconds.getHoursIntoDay(), day_seconds.getMinutesIntoHour(), day_seconds.getSecondsIntoMinute() },
        ),
        .date_stamp = try std.fmt.allocPrint(
            allocator,
            "{d:0>4}{d:0>2}{d:0>2}",
            .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 },
        ),
    };
}

fn buildRequestPath(allocator: std.mem.Allocator, model_id: []const u8) ![]const u8 {
    const encoded_model_id = try percentEncodePathSegment(allocator, model_id);
    defer allocator.free(encoded_model_id);
    return try std.fmt.allocPrint(allocator, "/model/{s}/converse-stream", .{encoded_model_id});
}

fn percentEncodePathSegment(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    for (value) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == '~') {
            try list.append(allocator, char);
        } else {
            try list.append(allocator, '%');
            try list.append(allocator, std.fmt.digitToChar(@intCast(char >> 4), .upper));
            try list.append(allocator, std.fmt.digitToChar(@intCast(char & 0x0f), .upper));
        }
    }

    return try list.toOwnedSlice(allocator);
}

fn resolveBedrockRegion(allocator: std.mem.Allocator, base_url: []const u8, options: ?types.StreamOptions) ![]u8 {
    if (options) |stream_options| {
        if (stream_options.bedrock_region) |region| return try allocator.dupe(u8, region);
    }
    if (try loadEnvOptional(allocator, "AWS_REGION")) |region| return region;
    if (try loadEnvOptional(allocator, "AWS_DEFAULT_REGION")) |region| return region;

    const host = try extractHostFromUrl(allocator, base_url);
    defer allocator.free(host);

    const lowered = try std.ascii.allocLowerString(allocator, host);
    defer allocator.free(lowered);

    const patterns = [_][]const u8{
        "bedrock-runtime.",
        "bedrock-runtime-fips.",
    };
    for (patterns) |pattern| {
        if (std.mem.startsWith(u8, lowered, pattern)) {
            const rest = lowered[pattern.len..];
            if (std.mem.indexOf(u8, rest, ".amazonaws.com")) |end| {
                return try allocator.dupe(u8, rest[0..end]);
            }
            if (std.mem.indexOf(u8, rest, ".amazonaws.com.cn")) |end| {
                return try allocator.dupe(u8, rest[0..end]);
            }
        }
    }

    return try allocator.dupe(u8, "us-east-1");
}

fn extractHostFromUrl(allocator: std.mem.Allocator, url_text: []const u8) ![]u8 {
    const uri = try std.Uri.parse(url_text);
    const host = uri.host orelse return error.InvalidUrl;
    return try allocator.dupe(u8, try host.toRawMaybeAlloc(allocator));
}

fn signRequestHeaders(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    model: types.Model,
    request_path: []const u8,
    body: []const u8,
    credentials: AwsCredentials,
    timestamp: RequestTimestamp,
    options: ?types.StreamOptions,
) !void {
    const host = try extractHostFromUrl(allocator, model.base_url);
    defer allocator.free(host);
    const region = try resolveBedrockRegion(allocator, model.base_url, options);
    defer allocator.free(region);

    try putOwnedHeader(allocator, headers, "host", host);

    var body_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &body_hash, .{});
    const body_hash_hex = try bytesToHexAlloc(allocator, &body_hash);
    defer allocator.free(body_hash_hex);

    try putOwnedHeader(allocator, headers, "x-amz-content-sha256", body_hash_hex);
    try putOwnedHeader(allocator, headers, "x-amz-date", timestamp.amz_date);
    if (credentials.session_token) |session_token| {
        try putOwnedHeader(allocator, headers, "x-amz-security-token", session_token);
    }

    var canonical_headers = std.ArrayList(CanonicalHeader).empty;
    defer {
        for (canonical_headers.items) |entry| entry.deinit(allocator);
        canonical_headers.deinit(allocator);
    }

    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "Authorization")) continue;
        try canonical_headers.append(allocator, .{
            .name = try std.ascii.allocLowerString(allocator, entry.key_ptr.*),
            .value = try normalizeHeaderValue(allocator, entry.value_ptr.*),
        });
    }
    std.mem.sort(CanonicalHeader, canonical_headers.items, {}, struct {
        fn lessThan(_: void, a: CanonicalHeader, b: CanonicalHeader) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    var canonical_header_text = std.ArrayList(u8).empty;
    defer canonical_header_text.deinit(allocator);
    var signed_headers = std.ArrayList(u8).empty;
    defer signed_headers.deinit(allocator);

    for (canonical_headers.items, 0..) |entry, index| {
        try canonical_header_text.appendSlice(allocator, entry.name);
        try canonical_header_text.append(allocator, ':');
        try canonical_header_text.appendSlice(allocator, entry.value);
        try canonical_header_text.append(allocator, '\n');

        if (index > 0) try signed_headers.append(allocator, ';');
        try signed_headers.appendSlice(allocator, entry.name);
    }

    const canonical_request = try std.fmt.allocPrint(
        allocator,
        "POST\n{s}\n\n{s}\n{s}\n{s}",
        .{ request_path, canonical_header_text.items, signed_headers.items, body_hash_hex },
    );
    defer allocator.free(canonical_request);

    var canonical_request_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_request, &canonical_request_hash, .{});
    const canonical_request_hash_hex = try bytesToHexAlloc(allocator, &canonical_request_hash);
    defer allocator.free(canonical_request_hash_hex);

    const credential_scope = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/aws4_request", .{ timestamp.date_stamp, region, SERVICE_NAME });
    defer allocator.free(credential_scope);

    const string_to_sign = try std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}",
        .{ timestamp.amz_date, credential_scope, canonical_request_hash_hex },
    );
    defer allocator.free(string_to_sign);

    const signing_key = try deriveSigningKey(allocator, credentials.secret_access_key, timestamp.date_stamp, region, SERVICE_NAME);
    defer allocator.free(signing_key);

    var signature: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&signature, string_to_sign, signing_key);
    const signature_hex = try bytesToHexAlloc(allocator, &signature);
    defer allocator.free(signature_hex);

    const authorization = try std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{ credentials.access_key_id, credential_scope, signed_headers.items, signature_hex },
    );
    defer allocator.free(authorization);
    try putOwnedHeader(allocator, headers, "Authorization", authorization);
}

fn deriveSigningKey(
    allocator: std.mem.Allocator,
    secret_access_key: []const u8,
    date_stamp: []const u8,
    region: []const u8,
    service: []const u8,
) ![]u8 {
    const seed = try std.fmt.allocPrint(allocator, "AWS4{s}", .{secret_access_key});
    defer allocator.free(seed);

    var k_date: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&k_date, date_stamp, seed);

    var k_region: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&k_region, region, &k_date);

    var k_service: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&k_service, service, &k_region);

    var signing_key: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&signing_key, "aws4_request", &k_service);
    return try allocator.dupe(u8, &signing_key);
}

fn bytesToHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        output[index * 2] = std.fmt.digitToChar(@intCast(byte >> 4), .lower);
        output[index * 2 + 1] = std.fmt.digitToChar(@intCast(byte & 0x0f), .lower);
    }
    return output;
}

fn normalizeHeaderValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    var previous_was_space = false;
    for (trimmed) |char| {
        const is_space = char == ' ' or char == '\t' or char == '\r' or char == '\n';
        if (is_space) {
            if (!previous_was_space) {
                try list.append(allocator, ' ');
                previous_was_space = true;
            }
        } else {
            try list.append(allocator, char);
            previous_was_space = false;
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn putOwnedHeader(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    if (headers.fetchRemove(name)) |entry| {
        allocator.free(entry.key);
        allocator.free(entry.value);
    }
    try headers.put(try allocator.dupe(u8, name), try allocator.dupe(u8, value));
}

fn mergeHeaders(
    allocator: std.mem.Allocator,
    target: *std.StringHashMap([]const u8),
    source: ?std.StringHashMap([]const u8),
) !void {
    if (source) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            try putOwnedHeader(allocator, target, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

fn parseStreamBody(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    streaming: *http_client.StreamingResponse,
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    if (looksLikeBinaryEventStream(streaming.body)) {
        try parseEventStreamFrames(allocator, stream_ptr, streaming.body, model, options);
        return;
    }
    try parseTextStreamLines(allocator, stream_ptr, streaming, model, options);
}

fn looksLikeBinaryEventStream(body: []const u8) bool {
    if (body.len == 0) return false;
    if (std.mem.indexOfScalar(u8, body, 0) != null) return true;

    for (body) |char| {
        switch (char) {
            ' ', '\t', '\r', '\n' => continue,
            '{', '[', 'd', 'e' => return false,
            else => return !std.ascii.isPrint(char),
        }
    }
    return false;
}

fn parseEventStreamFrames(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    body: []const u8,
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    var output = initOutput(model);
    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);
    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);
    var active_blocks = std.ArrayList(BlockEntry).empty;
    defer {
        for (active_blocks.items) |*entry| deinitCurrentBlock(allocator, &entry.block);
        active_blocks.deinit(allocator);
    }
    var state = StreamParseState{};

    var cursor: usize = 0;
    while (cursor < body.len) {
        if (isAbortRequested(options)) {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, error.RequestAborted);
            return;
        }

        if (body.len - cursor < 16) {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, BedrockError.InvalidBedrockEventStream);
            return;
        }
        const total_length = readBigEndianU32(body[cursor..][0..4]);
        const headers_length = readBigEndianU32(body[cursor..][4..8]);
        if (total_length < 16 or cursor + total_length > body.len) {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, BedrockError.InvalidBedrockEventStream);
            return;
        }
        const headers_start = cursor + 12;
        const headers_end = headers_start + headers_length;
        if (headers_end + 4 > cursor + total_length) {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, BedrockError.InvalidBedrockEventStream);
            return;
        }
        const payload_end = cursor + total_length - 4;

        const parsed_headers = parseEventStreamHeaders(body[headers_start..headers_end]) catch |err| {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, err);
            return;
        };
        const payload = body[headers_end..payload_end];
        cursor += total_length;

        if (payload.len == 0) continue;
        parseWrappedEventPayload(allocator, stream_ptr, payload, parsed_headers.event_type, parsed_headers.exception_type, &output, &content_blocks, &tool_calls, &active_blocks, &state, model) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, err);
                return;
            },
        };
        if (output.stop_reason == .error_reason and output.error_message != null and stream_ptr.result() != null) return;
    }

    try finalizeOutput(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, &state, model);
}

const EventStreamHeaders = struct {
    event_type: ?[]const u8 = null,
    exception_type: ?[]const u8 = null,
};

fn parseEventStreamHeaders(headers_bytes: []const u8) !EventStreamHeaders {
    var result = EventStreamHeaders{};
    var cursor: usize = 0;
    while (cursor < headers_bytes.len) {
        if (cursor + 2 > headers_bytes.len) return BedrockError.InvalidBedrockEventStream;
        const name_len = headers_bytes[cursor];
        cursor += 1;
        if (cursor + name_len + 1 > headers_bytes.len) return BedrockError.InvalidBedrockEventStream;
        const name = headers_bytes[cursor .. cursor + name_len];
        cursor += name_len;
        const header_type = headers_bytes[cursor];
        cursor += 1;

        const value = switch (header_type) {
            7 => blk: {
                if (cursor + 2 > headers_bytes.len) return BedrockError.InvalidBedrockEventStream;
                const value_len = readBigEndianU16(headers_bytes[cursor..][0..2]);
                cursor += 2;
                if (cursor + value_len > headers_bytes.len) return BedrockError.InvalidBedrockEventStream;
                const string_value = headers_bytes[cursor .. cursor + value_len];
                cursor += value_len;
                break :blk string_value;
            },
            else => return BedrockError.UnsupportedEventStreamHeaderType,
        };

        if (std.mem.eql(u8, name, ":event-type")) result.event_type = value;
        if (std.mem.eql(u8, name, ":exception-type")) result.exception_type = value;
    }
    return result;
}

fn readBigEndianU32(bytes: []const u8) usize {
    return @as(usize, bytes[0]) << 24 |
        @as(usize, bytes[1]) << 16 |
        @as(usize, bytes[2]) << 8 |
        @as(usize, bytes[3]);
}

fn readBigEndianU16(bytes: []const u8) usize {
    return @as(usize, bytes[0]) << 8 |
        @as(usize, bytes[1]);
}

fn parseWrappedEventPayload(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    payload: []const u8,
    event_type: ?[]const u8,
    exception_type: ?[]const u8,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    state: *StreamParseState,
    model: types.Model,
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    if (parsed.value != .object or !containsKnownEventField(parsed.value)) {
        const wrapped = try wrapEventValue(allocator, parsed.value, event_type, exception_type);
        defer freeJsonValue(allocator, wrapped);
        try handleEventValue(allocator, stream_ptr, wrapped, output, content_blocks, tool_calls, active_blocks, state, model);
        return;
    }
    try handleEventValue(allocator, stream_ptr, parsed.value, output, content_blocks, tool_calls, active_blocks, state, model);
}

fn containsKnownEventField(value: std.json.Value) bool {
    if (value != .object) return false;
    const keys = [_][]const u8{
        "messageStart",
        "contentBlockStart",
        "contentBlockDelta",
        "contentBlockStop",
        "messageStop",
        "metadata",
        "internalServerException",
        "modelStreamErrorException",
        "validationException",
        "throttlingException",
        "serviceUnavailableException",
    };
    inline for (keys) |key| {
        if (value.object.get(key) != null) return true;
    }
    return false;
}

fn wrapEventValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    event_type: ?[]const u8,
    exception_type: ?[]const u8,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);

    if (event_type) |name| {
        try object.put(allocator, try allocator.dupe(u8, name), try cloneJsonValue(allocator, value));
        return .{ .object = object };
    }
    if (exception_type) |name| {
        const field_name = try normalizeEventStreamExceptionName(allocator, name);
        defer allocator.free(field_name);
        try object.put(allocator, try allocator.dupe(u8, field_name), try cloneJsonValue(allocator, value));
        return .{ .object = object };
    }
    return BedrockError.InvalidBedrockChunk;
}

fn normalizeEventStreamExceptionName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const mappings = [_]struct { raw: []const u8, field: []const u8 }{
        .{ .raw = "InternalServerException", .field = "internalServerException" },
        .{ .raw = "ModelStreamErrorException", .field = "modelStreamErrorException" },
        .{ .raw = "ValidationException", .field = "validationException" },
        .{ .raw = "ThrottlingException", .field = "throttlingException" },
        .{ .raw = "ServiceUnavailableException", .field = "serviceUnavailableException" },
    };
    for (mappings) |mapping| {
        if (std.mem.eql(u8, name, mapping.raw) or std.mem.eql(u8, name, mapping.field)) {
            return allocator.dupe(u8, mapping.field);
        }
    }
    return allocator.dupe(u8, name);
}

fn initOutput(model: types.Model) types.AssistantMessage {
    return .{
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    };
}

fn parseTextStreamLines(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    streaming: *http_client.StreamingResponse,
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    var output = initOutput(model);
    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);
    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);
    var active_blocks = std.ArrayList(BlockEntry).empty;
    defer {
        for (active_blocks.items) |*entry| deinitCurrentBlock(allocator, &entry.block);
        active_blocks.deinit(allocator);
    }
    var state = StreamParseState{};

    while (true) {
        const maybe_line = streaming.readLine() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, err);
                return;
            },
        };
        const line = maybe_line orelse break;
        if (isAbortRequested(options)) {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, error.RequestAborted);
            return;
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "event:")) continue;
        const payload = if (std.mem.startsWith(u8, trimmed, "data: ")) trimmed[6..] else trimmed;
        if (payload.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, err);
                return;
            },
        };
        defer parsed.deinit();
        handleEventValue(allocator, stream_ptr, parsed.value, &output, &content_blocks, &tool_calls, &active_blocks, &state, model) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model, err);
                return;
            },
        };
        if (stream_ptr.result() != null) return;
    }

    try finalizeOutput(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, &state, model);
}

fn handleEventValue(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    state: *StreamParseState,
    model: types.Model,
) !void {
    if (value != .object) return BedrockError.InvalidBedrockChunk;

    const exception_fields = [_][]const u8{
        "internalServerException",
        "modelStreamErrorException",
        "validationException",
        "throttlingException",
        "serviceUnavailableException",
    };
    inline for (exception_fields) |field| {
        if (value.object.get(field)) |exception_value| {
            try collectOutputFromPartials(allocator, output, content_blocks, tool_calls, active_blocks);
            output.stop_reason = .error_reason;
            output.error_message = try buildExceptionMessage(allocator, field, exception_value);
            stream_ptr.push(.{ .event_type = .error_event, .error_message = output.error_message, .message = output.* });
            stream_ptr.end(output.*);
            return;
        }
    }

    if (value.object.get("messageStart")) |start_value| {
        if (state.saw_message_start) return BedrockError.DuplicateBedrockMessageStart;
        state.saw_message_start = true;
        if (start_value != .object) return BedrockError.InvalidBedrockChunk;
        const role_value = start_value.object.get("role") orelse return BedrockError.InvalidBedrockChunk;
        if (role_value != .string) return BedrockError.InvalidBedrockChunk;
        if (!std.mem.eql(u8, role_value.string, "assistant")) {
            try emitStreamFailureMessage(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, .error_reason, "Unexpected assistant message start but got user message start instead");
            return;
        }
        stream_ptr.push(.{ .event_type = .start });
        return;
    }
    if (value.object.get("contentBlockStart")) |start_value| {
        try handleContentBlockStart(allocator, active_blocks, state, stream_ptr, content_blocks.items.len, start_value);
        return;
    }
    if (value.object.get("contentBlockDelta")) |delta_value| {
        try handleContentBlockDelta(allocator, active_blocks, state, stream_ptr, content_blocks.items.len, delta_value);
        return;
    }
    if (value.object.get("contentBlockStop")) |stop_value| {
        try handleContentBlockStop(allocator, active_blocks, state, content_blocks, tool_calls, stream_ptr, stop_value);
        return;
    }
    if (value.object.get("messageStop")) |stop_value| {
        if (stop_value == .object) {
            if (stop_value.object.get("stopReason")) |reason_value| {
                if (reason_value == .string) output.stop_reason = mapStopReason(reason_value.string) catch .error_reason;
            }
        }
        return;
    }
    if (value.object.get("metadata")) |metadata_value| {
        updateUsage(output, metadata_value, model);
        return;
    }
}

fn buildExceptionMessage(allocator: std.mem.Allocator, field: []const u8, value: std.json.Value) ![]const u8 {
    const raw_detail = if (value == .object and value.object.get("message") != null and value.object.get("message").? == .string)
        value.object.get("message").?.string
    else
        "Bedrock streaming request failed";
    const detail = try provider_error.sanitizeProviderErrorDetail(allocator, raw_detail);
    defer allocator.free(detail);
    const prefix = bedrockExceptionPrefix(field);
    return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, detail });
}

fn bedrockExceptionPrefix(field: []const u8) []const u8 {
    if (std.mem.eql(u8, field, "internalServerException")) return "Internal server error";
    if (std.mem.eql(u8, field, "modelStreamErrorException")) return "Model stream error";
    if (std.mem.eql(u8, field, "validationException")) return "Validation error";
    if (std.mem.eql(u8, field, "throttlingException")) return "Throttling error";
    if (std.mem.eql(u8, field, "serviceUnavailableException")) return "Service unavailable";
    return field;
}

fn handleContentBlockStart(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    state: *StreamParseState,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    completed_count: usize,
    value: std.json.Value,
) !void {
    if (value != .object) return BedrockError.InvalidBedrockChunk;
    const index_value = value.object.get("contentBlockIndex") orelse return BedrockError.InvalidBedrockChunk;
    if (index_value != .integer) return BedrockError.InvalidBedrockChunk;
    const bedrock_index: usize = @intCast(index_value.integer);
    if (findActiveBlock(active_blocks, bedrock_index) != null or isClosedContentBlock(state, bedrock_index)) return BedrockError.InvalidBedrockChunk;

    const start_value = value.object.get("start") orelse return;
    if (start_value != .object) return BedrockError.InvalidBedrockChunk;

    if (start_value.object.get("toolUse")) |tool_use_value| {
        if (tool_use_value != .object) return BedrockError.InvalidBedrockChunk;
        const id_value = tool_use_value.object.get("toolUseId") orelse return BedrockError.InvalidBedrockChunk;
        const name_value = tool_use_value.object.get("name") orelse return BedrockError.InvalidBedrockChunk;
        if (id_value != .string or name_value != .string) return BedrockError.InvalidBedrockChunk;

        const event_index = completed_count + active_blocks.items.len;
        try active_blocks.append(allocator, .{
            .bedrock_index = bedrock_index,
            .event_index = event_index,
            .block = .{ .tool_call = .{
                .id = try allocator.dupe(u8, id_value.string),
                .name = try allocator.dupe(u8, name_value.string),
                .partial_json = std.ArrayList(u8).empty,
            } },
        });
        stream_ptr.push(.{ .event_type = .toolcall_start, .content_index = @intCast(event_index) });
    }
}

fn handleContentBlockDelta(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    state: *StreamParseState,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    completed_count: usize,
    value: std.json.Value,
) !void {
    if (value != .object) return BedrockError.InvalidBedrockChunk;
    const index_value = value.object.get("contentBlockIndex") orelse return BedrockError.InvalidBedrockChunk;
    if (index_value != .integer) return BedrockError.InvalidBedrockChunk;
    const bedrock_index: usize = @intCast(index_value.integer);
    if (isClosedContentBlock(state, bedrock_index)) return BedrockError.InvalidBedrockChunk;
    const delta_value = value.object.get("delta") orelse return BedrockError.InvalidBedrockChunk;
    if (delta_value != .object) return BedrockError.InvalidBedrockChunk;

    if (delta_value.object.get("text")) |text_value| {
        if (text_value != .string) return BedrockError.InvalidBedrockChunk;
        var entry = try ensureActiveTextBlock(allocator, active_blocks, stream_ptr, completed_count, bedrock_index, false);
        if (entry.block != .text) return BedrockError.InvalidBedrockChunk;
        try entry.block.text.appendSlice(allocator, text_value.string);
        stream_ptr.push(.{ .event_type = .text_delta, .content_index = @intCast(entry.event_index), .delta = try allocator.dupe(u8, text_value.string), .owns_delta = true });
        return;
    }

    if (delta_value.object.get("toolUse")) |tool_use_value| {
        if (tool_use_value != .object) return BedrockError.InvalidBedrockChunk;
        const entry = findActiveBlock(active_blocks, bedrock_index) orelse return BedrockError.InvalidBedrockChunk;
        if (entry.block != .tool_call) return BedrockError.InvalidBedrockChunk;
        if (tool_use_value.object.get("input")) |input_value| {
            if (input_value != .string) return BedrockError.InvalidBedrockChunk;
            try entry.block.tool_call.partial_json.appendSlice(allocator, input_value.string);
            stream_ptr.push(.{ .event_type = .toolcall_delta, .content_index = @intCast(entry.event_index), .delta = try allocator.dupe(u8, input_value.string), .owns_delta = true });
        }
        return;
    }

    if (delta_value.object.get("reasoningContent")) |reasoning_value| {
        if (reasoning_value != .object) return BedrockError.InvalidBedrockChunk;
        var entry = try ensureActiveTextBlock(allocator, active_blocks, stream_ptr, completed_count, bedrock_index, true);
        if (entry.block != .thinking) return BedrockError.InvalidBedrockChunk;

        if (extractReasoningText(reasoning_value)) |text| {
            if (text.len > 0) {
                try entry.block.thinking.text.appendSlice(allocator, text);
                stream_ptr.push(.{ .event_type = .thinking_delta, .content_index = @intCast(entry.event_index), .delta = try allocator.dupe(u8, text), .owns_delta = true });
            }
        }
        if (extractReasoningSignature(reasoning_value)) |signature| {
            if (entry.block.thinking.signature) |existing| {
                const appended = try std.fmt.allocPrint(allocator, "{s}{s}", .{ existing, signature });
                allocator.free(existing);
                entry.block.thinking.signature = appended;
            } else {
                entry.block.thinking.signature = try allocator.dupe(u8, signature);
            }
        }
        return;
    }
}

fn insertContentBlockAtEventIndex(
    allocator: std.mem.Allocator,
    content_blocks: *std.ArrayList(types.ContentBlock),
    event_index: usize,
    block: types.ContentBlock,
) !void {
    const insert_index = @min(event_index, content_blocks.items.len);
    try content_blocks.insert(allocator, insert_index, block);
}

fn ensureActiveTextBlock(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    completed_count: usize,
    bedrock_index: usize,
    is_thinking: bool,
) !*BlockEntry {
    if (findActiveBlock(active_blocks, bedrock_index)) |entry| return entry;

    const event_index = completed_count + active_blocks.items.len;
    try active_blocks.append(allocator, .{
        .bedrock_index = bedrock_index,
        .event_index = event_index,
        .block = if (is_thinking)
            .{ .thinking = .{ .text = std.ArrayList(u8).empty, .signature = null } }
        else
            .{ .text = std.ArrayList(u8).empty },
    });
    stream_ptr.push(.{ .event_type = if (is_thinking) .thinking_start else .text_start, .content_index = @intCast(event_index) });
    return &active_blocks.items[active_blocks.items.len - 1];
}

fn extractReasoningText(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    if (value.object.get("text")) |text_value| {
        if (text_value == .string) return text_value.string;
    }
    if (value.object.get("reasoningText")) |reasoning_text| {
        if (reasoning_text == .object) {
            if (reasoning_text.object.get("text")) |text_value| {
                if (text_value == .string) return text_value.string;
            }
        }
    }
    return null;
}

fn extractReasoningSignature(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    if (value.object.get("signature")) |signature_value| {
        if (signature_value == .string) return signature_value.string;
    }
    if (value.object.get("reasoningText")) |reasoning_text| {
        if (reasoning_text == .object) {
            if (reasoning_text.object.get("signature")) |signature_value| {
                if (signature_value == .string) return signature_value.string;
            }
        }
    }
    return null;
}

fn handleContentBlockStop(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    state: *StreamParseState,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
) !void {
    if (value != .object) return BedrockError.InvalidBedrockChunk;
    const index_value = value.object.get("contentBlockIndex") orelse return BedrockError.InvalidBedrockChunk;
    if (index_value != .integer) return BedrockError.InvalidBedrockChunk;
    const bedrock_index: usize = @intCast(index_value.integer);

    const remove_index = findActiveBlockIndex(active_blocks, bedrock_index) orelse return BedrockError.InvalidBedrockChunk;
    var entry = active_blocks.orderedRemove(remove_index);
    defer deinitCurrentBlock(allocator, &entry.block);
    try markClosedContentBlock(state, bedrock_index);

    switch (entry.block) {
        .text => |text| {
            const owned = try allocator.dupe(u8, text.items);
            try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .text = .{ .text = owned } });
            stream_ptr.push(.{ .event_type = .text_end, .content_index = @intCast(entry.event_index), .content = owned });
        },
        .thinking => |thinking| {
            const owned = try allocator.dupe(u8, thinking.text.items);
            const signature = if (thinking.signature) |value_bytes| try allocator.dupe(u8, value_bytes) else null;
            try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .thinking = .{ .thinking = owned, .signature = signature, .redacted = false } });
            stream_ptr.push(.{ .event_type = .thinking_end, .content_index = @intCast(entry.event_index), .content = owned });
        },
        .tool_call => |tool| {
            var parsed_arguments = try json_parse.parseStreamingJson(allocator, tool.partial_json.items);
            defer parsed_arguments.deinit();
            const arguments = try cloneJsonValue(allocator, parsed_arguments.value);
            const final_tool_call = types.ToolCall{
                .id = try allocator.dupe(u8, tool.id),
                .name = try allocator.dupe(u8, tool.name),
                .arguments = arguments,
            };
            try tool_calls.append(allocator, final_tool_call);
            try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .tool_call = .{
                .id = try allocator.dupe(u8, final_tool_call.id),
                .name = try allocator.dupe(u8, final_tool_call.name),
                .arguments = try cloneJsonValue(allocator, final_tool_call.arguments),
            } });
            stream_ptr.push(.{ .event_type = .toolcall_end, .content_index = @intCast(entry.event_index), .tool_call = final_tool_call });
        },
    }
}

fn findActiveBlock(active_blocks: *std.ArrayList(BlockEntry), bedrock_index: usize) ?*BlockEntry {
    const index = findActiveBlockIndex(active_blocks, bedrock_index) orelse return null;
    return &active_blocks.items[index];
}

fn findActiveBlockIndex(active_blocks: *const std.ArrayList(BlockEntry), bedrock_index: usize) ?usize {
    for (active_blocks.items, 0..) |entry, index| {
        if (entry.bedrock_index == bedrock_index) return index;
    }
    return null;
}

fn updateUsage(output: *types.AssistantMessage, metadata_value: std.json.Value, model: types.Model) void {
    if (metadata_value != .object) return;
    const usage_value = metadata_value.object.get("usage") orelse return;
    if (usage_value != .object) return;

    output.usage.input = getJsonU32(usage_value.object.get("inputTokens"));
    output.usage.output = getJsonU32(usage_value.object.get("outputTokens"));
    output.usage.cache_read = getJsonU32(usage_value.object.get("cacheReadInputTokens"));
    output.usage.cache_write = getJsonU32(usage_value.object.get("cacheWriteInputTokens"));
    output.usage.total_tokens = blk: {
        const total = getJsonU32(usage_value.object.get("totalTokens"));
        break :blk if (total > 0) total else output.usage.input + output.usage.output;
    };
    calculateCost(model, &output.usage);
}

fn getJsonU32(value: ?std.json.Value) u32 {
    if (value) |json_value| {
        if (json_value == .integer and json_value.integer >= 0) return @intCast(json_value.integer);
    }
    return 0;
}

fn calculateCost(model: types.Model, usage: *types.Usage) void {
    usage.cost.input = (@as(f64, @floatFromInt(usage.input)) / 1_000_000.0) * model.cost.input;
    usage.cost.output = (@as(f64, @floatFromInt(usage.output)) / 1_000_000.0) * model.cost.output;
    usage.cost.cache_read = (@as(f64, @floatFromInt(usage.cache_read)) / 1_000_000.0) * model.cost.cache_read;
    usage.cost.cache_write = (@as(f64, @floatFromInt(usage.cache_write)) / 1_000_000.0) * model.cost.cache_write;
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
}

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
) !void {
    _ = model;
    while (active_blocks.items.len > 0) {
        var entry = active_blocks.orderedRemove(0);
        defer deinitCurrentBlock(allocator, &entry.block);
        switch (entry.block) {
            .text => |text| {
                const owned = try allocator.dupe(u8, text.items);
                try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .text = .{ .text = owned } });
                stream_ptr.push(.{ .event_type = .text_end, .content_index = @intCast(entry.event_index), .content = owned });
            },
            .thinking => |thinking| {
                const owned = try allocator.dupe(u8, thinking.text.items);
                const signature = if (thinking.signature) |value_bytes| try allocator.dupe(u8, value_bytes) else null;
                try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .thinking = .{ .thinking = owned, .signature = signature, .redacted = false } });
                stream_ptr.push(.{ .event_type = .thinking_end, .content_index = @intCast(entry.event_index), .content = owned });
            },
            .tool_call => |tool| {
                var parsed_arguments = try json_parse.parseStreamingJson(allocator, tool.partial_json.items);
                defer parsed_arguments.deinit();
                const final_tool_call = types.ToolCall{
                    .id = try allocator.dupe(u8, tool.id),
                    .name = try allocator.dupe(u8, tool.name),
                    .arguments = try cloneJsonValue(allocator, parsed_arguments.value),
                };
                try tool_calls.append(allocator, final_tool_call);
                try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .tool_call = .{
                    .id = try allocator.dupe(u8, final_tool_call.id),
                    .name = try allocator.dupe(u8, final_tool_call.name),
                    .arguments = try cloneJsonValue(allocator, final_tool_call.arguments),
                } });
                stream_ptr.push(.{ .event_type = .toolcall_end, .content_index = @intCast(entry.event_index), .tool_call = final_tool_call });
            },
        }
    }

    output.content = if (output.content.len == 0 and content_blocks.items.len > 0) try content_blocks.toOwnedSlice(allocator) else output.content;
    output.tool_calls = if (output.tool_calls == null and tool_calls.items.len > 0) try tool_calls.toOwnedSlice(allocator) else output.tool_calls;
    output.usage.total_tokens = if (output.usage.total_tokens > 0) output.usage.total_tokens else output.usage.input + output.usage.output;
}

fn collectOutputFromPartials(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
) !void {
    while (active_blocks.items.len > 0) {
        var entry = active_blocks.orderedRemove(0);
        defer deinitCurrentBlock(allocator, &entry.block);
        switch (entry.block) {
            .text => |text| {
                const owned = try allocator.dupe(u8, text.items);
                try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .text = .{ .text = owned } });
            },
            .thinking => |thinking| {
                const owned = try allocator.dupe(u8, thinking.text.items);
                const signature = if (thinking.signature) |value_bytes| try allocator.dupe(u8, value_bytes) else null;
                try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .thinking = .{ .thinking = owned, .signature = signature, .redacted = false } });
            },
            .tool_call => |tool| {
                var parsed_arguments = try json_parse.parseStreamingJson(allocator, tool.partial_json.items);
                defer parsed_arguments.deinit();
                const final_tool_call = types.ToolCall{
                    .id = try allocator.dupe(u8, tool.id),
                    .name = try allocator.dupe(u8, tool.name),
                    .arguments = try cloneJsonValue(allocator, parsed_arguments.value),
                };
                try tool_calls.append(allocator, final_tool_call);
                try insertContentBlockAtEventIndex(allocator, content_blocks, entry.event_index, .{ .tool_call = .{
                    .id = try allocator.dupe(u8, final_tool_call.id),
                    .name = try allocator.dupe(u8, final_tool_call.name),
                    .arguments = try cloneJsonValue(allocator, final_tool_call.arguments),
                } });
            },
        }
    }

    output.content = if (output.content.len == 0 and content_blocks.items.len > 0) try content_blocks.toOwnedSlice(allocator) else output.content;
    output.tool_calls = if (output.tool_calls == null and tool_calls.items.len > 0) try tool_calls.toOwnedSlice(allocator) else output.tool_calls;
    output.usage.total_tokens = if (output.usage.total_tokens > 0) output.usage.total_tokens else output.usage.input + output.usage.output;
}

fn emitStreamFailureMessage(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    stop_reason: types.StopReason,
    message_text: []const u8,
) !void {
    try collectOutputFromPartials(allocator, output, content_blocks, tool_calls, active_blocks);
    output.stop_reason = stop_reason;
    output.error_message = try allocator.dupe(u8, message_text);
    stream_ptr.push(.{ .event_type = .error_event, .error_message = output.error_message, .message = output.* });
    stream_ptr.end(output.*);
}

fn emitRuntimeFailure(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
    err: anyerror,
) !void {
    _ = model;
    try emitStreamFailureMessage(
        allocator,
        stream_ptr,
        output,
        content_blocks,
        tool_calls,
        active_blocks,
        provider_error.runtimeStopReason(err),
        provider_error.runtimeErrorMessage(err),
    );
}

fn finalizeOutput(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    state: *StreamParseState,
    model: types.Model,
) !void {
    _ = model;
    if (!state.saw_message_start) {
        try emitStreamFailureMessage(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, .error_reason, "An unknown error occurred");
        return;
    }
    if (active_blocks.items.len != 0) return BedrockError.InvalidBedrockChunk;
    if (output.stop_reason == .error_reason or output.stop_reason == .aborted) {
        try emitStreamFailureMessage(allocator, stream_ptr, output, content_blocks, tool_calls, active_blocks, output.stop_reason, "An unknown error occurred");
        return;
    }
    output.content = try content_blocks.toOwnedSlice(allocator);
    output.tool_calls = if (tool_calls.items.len > 0) try tool_calls.toOwnedSlice(allocator) else null;
    output.usage.total_tokens = if (output.usage.total_tokens > 0) output.usage.total_tokens else output.usage.input + output.usage.output;

    stream_ptr.push(.{ .event_type = .done, .message = output.* });
    stream_ptr.end(output.*);
}

pub fn mapStopReason(reason: []const u8) !types.StopReason {
    if (std.mem.eql(u8, reason, "end_turn")) return .stop;
    if (std.mem.eql(u8, reason, "stop_sequence")) return .stop;
    if (std.mem.eql(u8, reason, "max_tokens")) return .length;
    if (std.mem.eql(u8, reason, "model_context_window_exceeded")) return .length;
    if (std.mem.eql(u8, reason, "tool_use")) return .tool_use;
    return BedrockError.UnknownStopReason;
}

fn emitAuthError(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
    message_text: []const u8,
) !void {
    const error_message = try allocator.dupe(u8, message_text);
    const message = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = error_message,
        .timestamp = 0,
    };
    stream_ptr.push(.{ .event_type = .error_event, .error_message = error_message, .message = message });
    stream_ptr.end(message);
}

fn authErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingAwsAccessKeyId => "Bedrock requires AWS_ACCESS_KEY_ID.",
        error.MissingAwsSecretAccessKey => "Bedrock requires AWS_SECRET_ACCESS_KEY.",
        else => "Bedrock authentication failed.",
    };
}

fn trimTrailingSlash(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
}

const FixtureRegion = struct {
    source: []const u8,
    value: ?[]const u8 = null,
};

const FixtureEndpoint = struct {
    mode: []const u8,
    value: ?[]const u8 = null,
};

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    if (text.len == 0) return null;
    return text;
}

fn standardEndpointRegion(base_url: []const u8) ?[]const u8 {
    const prefix = "https://";
    const rest = if (std.mem.startsWith(u8, base_url, prefix)) base_url[prefix.len..] else base_url;
    const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host = rest[0..host_end];
    const prefixes = [_][]const u8{ "bedrock-runtime.", "bedrock-runtime-fips." };
    for (prefixes) |pattern| {
        if (std.mem.startsWith(u8, host, pattern)) {
            const after = host[pattern.len..];
            if (std.mem.indexOf(u8, after, ".amazonaws.com.cn")) |end| return after[0..end];
            if (std.mem.indexOf(u8, after, ".amazonaws.com")) |end| return after[0..end];
        }
    }
    return null;
}

fn resolveFixtureRegion(base_url: []const u8, options: ?types.StreamOptions, env: FixtureEnv) FixtureRegion {
    if (options) |stream_options| {
        if (nonEmpty(stream_options.bedrock_region)) |region| return .{ .source = "options.region", .value = region };
    }
    if (nonEmpty(env.aws_region)) |region| return .{ .source = "AWS_REGION", .value = region };
    if (nonEmpty(env.aws_default_region)) |region| return .{ .source = "AWS_DEFAULT_REGION", .value = region };
    if (standardEndpointRegion(base_url)) |region| {
        if (nonEmpty(env.aws_profile) == null) return .{ .source = "endpoint", .value = region };
    }
    if (nonEmpty(env.aws_profile) != null) return .{ .source = "sdk-profile-resolution" };
    return .{ .source = "default", .value = "us-east-1" };
}

fn hasConfiguredFixtureRegion(options: ?types.StreamOptions, env: FixtureEnv) bool {
    if (options) |stream_options| {
        if (nonEmpty(stream_options.bedrock_region) != null) return true;
    }
    return nonEmpty(env.aws_region) != null or nonEmpty(env.aws_default_region) != null;
}

fn resolveFixtureEndpoint(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    region: FixtureRegion,
    env: FixtureEnv,
    options: ?types.StreamOptions,
) !FixtureEndpoint {
    const endpoint_region = standardEndpointRegion(base_url);
    const use_explicit_endpoint = endpoint_region == null or (!hasConfiguredFixtureRegion(options, env) and nonEmpty(env.aws_profile) == null);
    if (use_explicit_endpoint) {
        return .{ .mode = "explicit", .value = try allocator.dupe(u8, trimTrailingSlash(base_url)) };
    }
    const region_value = region.value orelse return .{ .mode = "sdk-profile-resolution" };
    const suffix = if (std.mem.startsWith(u8, region_value, "cn-")) "amazonaws.com.cn" else "amazonaws.com";
    return .{ .mode = "sdk-default", .value = try std.fmt.allocPrint(allocator, "https://bedrock-runtime.{s}.{s}", .{ region_value, suffix }) };
}

fn buildFixtureAuthSnapshot(
    allocator: std.mem.Allocator,
    options: ?types.StreamOptions,
    env: FixtureEnv,
    region: FixtureRegion,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);

    const option_bearer = if (options) |stream_options| nonEmpty(stream_options.bedrock_bearer_token) else null;
    const env_bearer = nonEmpty(env.aws_bearer_token_bedrock);

    if (std.mem.eql(u8, nonEmpty(env.aws_bedrock_skip_auth) orelse "", "1")) {
        try object.put(allocator, try allocator.dupe(u8, "mode"), .{ .string = try allocator.dupe(u8, "skip-auth") });
        try object.put(allocator, try allocator.dupe(u8, "credentialSource"), .{ .string = try allocator.dupe(u8, "proxy-dummy") });
        try object.put(allocator, try allocator.dupe(u8, "bearerSuppressed"), .{ .bool = option_bearer != null or env_bearer != null });
        try object.put(allocator, try allocator.dupe(u8, "secrets"), .{ .string = try allocator.dupe(u8, "redacted") });
        return .{ .object = object };
    }

    if (option_bearer != null or env_bearer != null) {
        try object.put(allocator, try allocator.dupe(u8, "mode"), .{ .string = try allocator.dupe(u8, "bearer") });
        try object.put(allocator, try allocator.dupe(u8, "source"), .{ .string = try allocator.dupe(u8, if (option_bearer != null) "options.bearerToken" else "env.bearerToken") });
        try object.put(allocator, try allocator.dupe(u8, "token"), .{ .string = try allocator.dupe(u8, "redacted") });
        try object.put(allocator, try allocator.dupe(u8, "sigv4"), .{ .bool = false });
        return .{ .object = object };
    }

    if ((options != null and nonEmpty(options.?.bedrock_profile) != null) or nonEmpty(env.aws_profile) != null) {
        try object.put(allocator, try allocator.dupe(u8, "mode"), .{ .string = try allocator.dupe(u8, "profile") });
        if (options) |stream_options| {
            if (nonEmpty(stream_options.bedrock_profile)) |profile| try object.put(allocator, try allocator.dupe(u8, "optionsProfile"), .{ .string = try allocator.dupe(u8, profile) });
        }
        if (nonEmpty(env.aws_profile)) |profile| try object.put(allocator, try allocator.dupe(u8, "envProfile"), .{ .string = try allocator.dupe(u8, profile) });
        try object.put(allocator, try allocator.dupe(u8, "credentialDiscovery"), .{ .string = try allocator.dupe(u8, "sdk-profile-resolution") });
        return .{ .object = object };
    }

    if (nonEmpty(env.aws_access_key_id) != null and nonEmpty(env.aws_secret_access_key) != null) {
        const signing_region = region.value orelse "us-east-1";
        try object.put(allocator, try allocator.dupe(u8, "mode"), .{ .string = try allocator.dupe(u8, "sigv4") });
        try object.put(allocator, try allocator.dupe(u8, "method"), .{ .string = try allocator.dupe(u8, "POST") });
        try object.put(allocator, try allocator.dupe(u8, "query"), .{ .string = try allocator.dupe(u8, "") });
        try object.put(allocator, try allocator.dupe(u8, "service"), .{ .string = try allocator.dupe(u8, SERVICE_NAME) });
        try object.put(allocator, try allocator.dupe(u8, "region"), .{ .string = try allocator.dupe(u8, signing_region) });
        try object.put(allocator, try allocator.dupe(u8, "amzDate"), .{ .string = try allocator.dupe(u8, "20250115T120000Z") });
        var credential_scope = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try credential_scope.put(allocator, try allocator.dupe(u8, "date"), .{ .string = try allocator.dupe(u8, "20250115") });
        try credential_scope.put(allocator, try allocator.dupe(u8, "region"), .{ .string = try allocator.dupe(u8, signing_region) });
        try credential_scope.put(allocator, try allocator.dupe(u8, "service"), .{ .string = try allocator.dupe(u8, SERVICE_NAME) });
        try credential_scope.put(allocator, try allocator.dupe(u8, "terminal"), .{ .string = try allocator.dupe(u8, "aws4_request") });
        try object.put(allocator, try allocator.dupe(u8, "credentialScope"), .{ .object = credential_scope });
        var signed_headers = std.json.Array.init(allocator);
        inline for (&[_][]const u8{ "content-type", "host", "x-amz-content-sha256", "x-amz-date", "x-amz-security-token" }) |header| {
            try signed_headers.append(.{ .string = try allocator.dupe(u8, header) });
        }
        try object.put(allocator, try allocator.dupe(u8, "signedHeaders"), .{ .array = signed_headers });
        try object.put(allocator, try allocator.dupe(u8, "bodySha256"), .{ .string = try allocator.dupe(u8, "normalized-payload-sha256") });
        if (nonEmpty(env.aws_session_token) != null) try object.put(allocator, try allocator.dupe(u8, "sessionToken"), .{ .string = try allocator.dupe(u8, "redacted") });
        try object.put(allocator, try allocator.dupe(u8, "accessKeyId"), .{ .string = try allocator.dupe(u8, "redacted") });
        try object.put(allocator, try allocator.dupe(u8, "signature"), .{ .string = try allocator.dupe(u8, "normalized") });
        return .{ .object = object };
    }

    try object.put(allocator, try allocator.dupe(u8, "mode"), .{ .string = try allocator.dupe(u8, "missing-credentials") });
    try object.put(allocator, try allocator.dupe(u8, "errorSurface"), .{ .string = try allocator.dupe(u8, "async-stream-error") });
    try object.put(allocator, try allocator.dupe(u8, "message"), .{ .string = try allocator.dupe(u8, "Bedrock requires AWS_ACCESS_KEY_ID.") });
    try object.put(allocator, try allocator.dupe(u8, "network"), .{ .string = try allocator.dupe(u8, "not-attempted") });
    return .{ .object = object };
}

fn isAbortRequested(options: ?types.StreamOptions) bool {
    if (options) |stream_options| {
        if (stream_options.signal) |signal| return signal.load(.seq_cst);
    }
    return false;
}

fn deinitCurrentBlock(allocator: std.mem.Allocator, block: *CurrentBlock) void {
    switch (block.*) {
        .text => |*text| text.deinit(allocator),
        .thinking => |*thinking| {
            thinking.text.deinit(allocator);
            if (thinking.signature) |signature| allocator.free(signature);
        },
        .tool_call => |*tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            tool_call.partial_json.deinit(allocator);
        },
    }
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |boolean| return .{ .bool = boolean },
        .integer => |integer| return .{ .integer = integer },
        .float => |float| return .{ .float = float },
        .number_string => |number_string| return .{ .number_string = try allocator.dupe(u8, number_string) },
        .string => |string| return .{ .string = try allocator.dupe(u8, string) },
        .array => |array| {
            var clone = std.json.Array.init(allocator);
            for (array.items) |item| try clone.append(try cloneJsonValue(allocator, item));
            return .{ .array = clone };
        },
        .object => |object| {
            var clone = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try clone.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            return .{ .object = clone };
        },
    }
}

fn putStringField(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
}

fn putIntegerField(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: anytype) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .integer = @intCast(value) });
}

fn eventTypeName(event_type: types.EventType) []const u8 {
    return switch (event_type) {
        .start => "start",
        .text_start => "text_start",
        .text_delta => "text_delta",
        .text_end => "text_end",
        .thinking_start => "thinking_start",
        .thinking_delta => "thinking_delta",
        .thinking_end => "thinking_end",
        .toolcall_start => "toolcall_start",
        .toolcall_delta => "toolcall_delta",
        .toolcall_end => "toolcall_end",
        .done => "done",
        .error_event => "error",
    };
}

fn stopReasonName(stop_reason: types.StopReason) []const u8 {
    return switch (stop_reason) {
        .stop => "stop",
        .length => "length",
        .tool_use => "toolUse",
        .error_reason => "error",
        .aborted => "aborted",
    };
}

fn snapshotCostValue(allocator: std.mem.Allocator, cost: types.UsageCost) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, "cacheRead"), if (cost.cache_read == 0) .{ .integer = 0 } else .{ .float = cost.cache_read });
    try object.put(allocator, try allocator.dupe(u8, "cacheWrite"), if (cost.cache_write == 0) .{ .integer = 0 } else .{ .float = cost.cache_write });
    try object.put(allocator, try allocator.dupe(u8, "input"), if (cost.input == 0) .{ .integer = 0 } else .{ .float = cost.input });
    try object.put(allocator, try allocator.dupe(u8, "output"), if (cost.output == 0) .{ .integer = 0 } else .{ .float = cost.output });
    try object.put(allocator, try allocator.dupe(u8, "total"), if (cost.total == 0) .{ .integer = 0 } else .{ .float = cost.total });
    return .{ .object = object };
}

fn snapshotUsageValue(allocator: std.mem.Allocator, usage: types.Usage) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try putIntegerField(allocator, &object, "cacheRead", usage.cache_read);
    try putIntegerField(allocator, &object, "cacheWrite", usage.cache_write);
    try object.put(allocator, try allocator.dupe(u8, "cost"), try snapshotCostValue(allocator, usage.cost));
    try putIntegerField(allocator, &object, "input", usage.input);
    try putIntegerField(allocator, &object, "output", usage.output);
    try putIntegerField(allocator, &object, "totalTokens", usage.total_tokens);
    return .{ .object = object };
}

fn snapshotToolCallValue(allocator: std.mem.Allocator, tool_call: types.ToolCall) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try object.put(allocator, try allocator.dupe(u8, "arguments"), try cloneJsonValue(allocator, tool_call.arguments));
    try putStringField(allocator, &object, "id", tool_call.id);
    try putStringField(allocator, &object, "name", tool_call.name);
    return .{ .object = object };
}

fn snapshotContentBlockValue(allocator: std.mem.Allocator, block: types.ContentBlock) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    switch (block) {
        .text => |text| {
            try putStringField(allocator, &object, "text", text.text);
            try putStringField(allocator, &object, "type", "text");
        },
        .thinking => |thinking| {
            try putStringField(allocator, &object, "thinking", thinking.thinking);
            if (types.thinkingSignature(thinking)) |signature| {
                try putStringField(allocator, &object, "thinkingSignature", signature);
            }
            try putStringField(allocator, &object, "type", "thinking");
        },
        .tool_call => |tool_call| {
            try object.put(allocator, try allocator.dupe(u8, "arguments"), try cloneJsonValue(allocator, tool_call.arguments));
            try putStringField(allocator, &object, "id", tool_call.id);
            try putStringField(allocator, &object, "name", tool_call.name);
            try putStringField(allocator, &object, "type", "toolCall");
        },
        .image => return BedrockError.InvalidBedrockChunk,
    }
    return .{ .object = object };
}

fn snapshotMessageValue(allocator: std.mem.Allocator, message: types.AssistantMessage) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    try putStringField(allocator, &object, "api", message.api);
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();
    for (message.content) |block| {
        try content.append(try snapshotContentBlockValue(allocator, block));
    }
    try object.put(allocator, try allocator.dupe(u8, "content"), .{ .array = content });
    if (message.error_message) |error_message| try putStringField(allocator, &object, "errorMessage", error_message);
    try putStringField(allocator, &object, "model", message.model);
    try putStringField(allocator, &object, "provider", message.provider);
    try putStringField(allocator, &object, "role", "assistant");
    try putStringField(allocator, &object, "stopReason", stopReasonName(message.stop_reason));
    try object.put(allocator, try allocator.dupe(u8, "usage"), try snapshotUsageValue(allocator, message.usage));
    return .{ .object = object };
}

fn snapshotEventValue(allocator: std.mem.Allocator, event: types.AssistantMessageEvent) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer object.deinit(allocator);
    if (event.content) |content| try putStringField(allocator, &object, "content", content);
    if (event.content_index) |content_index| try putIntegerField(allocator, &object, "contentIndex", content_index);
    if (event.delta) |delta| try putStringField(allocator, &object, "delta", delta);
    if (event.error_message) |error_message| try putStringField(allocator, &object, "errorMessage", error_message);
    if (event.message) |message| try object.put(allocator, try allocator.dupe(u8, "message"), try snapshotMessageValue(allocator, message));
    if (event.tool_call) |tool_call| try object.put(allocator, try allocator.dupe(u8, "toolCall"), try snapshotToolCallValue(allocator, tool_call));
    try putStringField(allocator, &object, "type", eventTypeName(event.event_type));
    return .{ .object = object };
}

fn snapshotStreamEvents(
    allocator: std.mem.Allocator,
    event_allocator: std.mem.Allocator,
    stream_instance: *event_stream.AssistantMessageEventStream,
) !std.json.Value {
    var events = std.json.Array.init(allocator);
    errdefer events.deinit();
    while (stream_instance.next()) |event| {
        defer event.deinitTransient(event_allocator);
        try events.append(try snapshotEventValue(allocator, event));
    }
    return .{ .array = events };
}

pub fn freeOwnedJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    freeJsonValue(allocator, value);
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var owned = arr;
            owned.deinit();
        },
        .object => |obj| {
            var iterator = obj.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var owned = obj;
            owned.deinit(allocator);
        },
        else => {},
    }
}

test "VAL-MSG-010 Bedrock skips failed assistants" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude Bedrock",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 4096,
    };
    const first_user = [_]types.ContentBlock{.{ .text = .{ .text = "hello" } }};
    const failed_content = [_]types.ContentBlock{
        .{ .thinking = .{ .thinking = "partial thinking", .thinking_signature = "sig" } },
        .{ .tool_call = .{ .id = "failed-tool", .name = "lookup", .arguments = .null } },
    };
    const final_user = [_]types.ContentBlock{.{ .text = .{ .text = "continue" } }};

    const payload = try buildRequestPayload(allocator, model, .{ .messages = &[_]types.Message{
        .{ .user = .{ .content = &first_user, .timestamp = 1 } },
        .{ .assistant = .{
            .content = &failed_content,
            .api = "bedrock-converse-stream",
            .provider = "amazon-bedrock",
            .model = "anthropic.claude-3-7-sonnet-20250219-v1:0",
            .usage = types.Usage.init(),
            .stop_reason = .error_reason,
            .error_message = "failed",
            .timestamp = 2,
        } },
        .{ .assistant = .{
            .content = &failed_content,
            .api = "bedrock-converse-stream",
            .provider = "amazon-bedrock",
            .model = "anthropic.claude-3-7-sonnet-20250219-v1:0",
            .usage = types.Usage.init(),
            .stop_reason = .aborted,
            .error_message = "aborted",
            .timestamp = 3,
        } },
        .{ .user = .{ .content = &final_user, .timestamp = 4 } },
    } }, null);
    defer freeJsonValue(allocator, payload);

    const messages = payload.object.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 2), messages.items.len);
    try std.testing.expectEqualStrings("user", messages.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("user", messages.items[1].object.get("role").?.string);
}

test "buildRequestPayload includes bedrock system messages inference config and tools" {
    const allocator = std.testing.allocator;

    var tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_schema.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });
    try tool_schema.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) });
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer freeJsonValue(allocator, tool_schema_value);

    const context = types.Context{
        .system_prompt = "You are helpful.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello Bedrock" } }},
                .timestamp = 1,
            } },
        },
        .tools = &[_]types.Tool{.{
            .name = "get_weather",
            .description = "Get weather",
            .parameters = tool_schema_value,
        }},
    };

    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude 3.7 Sonnet",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 8192,
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .temperature = 0.25,
        .max_tokens = 512,
        .google_tool_choice = "any",
    });
    defer freeJsonValue(allocator, payload);

    const object = payload.object;
    try std.testing.expect(object.get("system") != null);
    try std.testing.expect(object.get("messages") != null);
    try std.testing.expect(object.get("inferenceConfig") != null);
    try std.testing.expect(object.get("toolConfig") != null);
    try std.testing.expectEqual(@as(i64, 512), object.get("inferenceConfig").?.object.get("maxTokens").?.integer);
    try std.testing.expectEqualStrings("Hello Bedrock", object.get("messages").?.array.items[0].object.get("content").?.array.items[0].object.get("text").?.string);
}

test "signRequestHeaders creates sigv4 authorization and security token" {
    const allocator = std.testing.allocator;

    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude 3.7 Sonnet",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 8192,
    };

    var headers = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        headers.deinit();
    }
    try putOwnedHeader(allocator, &headers, "Content-Type", "application/json");

    try signRequestHeaders(
        allocator,
        &headers,
        model,
        "/model/anthropic.claude-3-7-sonnet-20250219-v1%3A0/converse-stream",
        "{}",
        .{
            .access_key_id = "AKIDEXAMPLE",
            .secret_access_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            .session_token = "IQoJb3JpZ2luX2VjEOr//////////wEaCXVzLWVhc3QtMSJHMEUCIQDn",
        },
        .{
            .amz_date = "20250115T120000Z",
            .date_stamp = "20250115",
        },
        null,
    );

    try std.testing.expectEqualStrings("bedrock-runtime.us-east-1.amazonaws.com", headers.get("host").?);
    try std.testing.expectEqualStrings("20250115T120000Z", headers.get("x-amz-date").?);
    try std.testing.expectEqualStrings("44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a", headers.get("x-amz-content-sha256").?);
    try std.testing.expectEqualStrings("IQoJb3JpZ2luX2VjEOr//////////wEaCXVzLWVhc3QtMSJHMEUCIQDn", headers.get("x-amz-security-token").?);
    try std.testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20250115/us-east-1/bedrock/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token, Signature=8271ddd75388cc7aeb4cececc432f97a4e5c9cbc5d072d94b5bcc4b30809cb1f",
        headers.get("Authorization").?,
    );
}

fn appendBigEndianU32(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    try bytes.append(allocator, @intCast((value >> 24) & 0xff));
    try bytes.append(allocator, @intCast((value >> 16) & 0xff));
    try bytes.append(allocator, @intCast((value >> 8) & 0xff));
    try bytes.append(allocator, @intCast(value & 0xff));
}

fn appendBigEndianU16(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) !void {
    try bytes.append(allocator, @intCast((value >> 8) & 0xff));
    try bytes.append(allocator, @intCast(value & 0xff));
}

fn appendEventStreamHeader(
    allocator: std.mem.Allocator,
    headers: *std.ArrayList(u8),
    name: []const u8,
    value: []const u8,
) !void {
    try headers.append(allocator, @intCast(name.len));
    try headers.appendSlice(allocator, name);
    try headers.append(allocator, 7);
    try appendBigEndianU16(headers, allocator, value.len);
    try headers.appendSlice(allocator, value);
}

fn appendEventStreamFrame(
    allocator: std.mem.Allocator,
    frames: *std.ArrayList(u8),
    event_type: []const u8,
    payload: []const u8,
) !void {
    var headers = std.ArrayList(u8).empty;
    defer headers.deinit(allocator);
    try appendEventStreamHeader(allocator, &headers, ":event-type", event_type);

    const total_length = 16 + headers.items.len + payload.len;
    try appendBigEndianU32(frames, allocator, total_length);
    try appendBigEndianU32(frames, allocator, headers.items.len);
    try appendBigEndianU32(frames, allocator, 0);
    try frames.appendSlice(allocator, headers.items);
    try frames.appendSlice(allocator, payload);
    try appendBigEndianU32(frames, allocator, 0);
}

test "parseEventStreamFrames handles bedrock binary converse stream" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude 3.7 Sonnet",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 8192,
    };

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try appendEventStreamFrame(allocator, &body, "messageStart", "{\"role\":\"assistant\"}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"reasoningContent\":{\"reasoningText\":{\"text\":\"Need weather.\",\"signature\":\"sig-1\"}}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStop", "{\"contentBlockIndex\":0}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":1,\"delta\":{\"text\":\"Checking now\"}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStop", "{\"contentBlockIndex\":1}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStart", "{\"contentBlockIndex\":2,\"start\":{\"toolUse\":{\"toolUseId\":\"tool-1\",\"name\":\"get_weather\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":2,\"delta\":{\"toolUse\":{\"input\":\"{\\\"city\\\":\\\"Ber\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":2,\"delta\":{\"toolUse\":{\"input\":\"lin\\\",\\\"unit\\\":\\\"C\\\"}\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStop", "{\"contentBlockIndex\":2}");
    try appendEventStreamFrame(allocator, &body, "messageStop", "{\"stopReason\":\"tool_use\"}");
    try appendEventStreamFrame(allocator, &body, "metadata", "{\"usage\":{\"inputTokens\":21,\"outputTokens\":9,\"totalTokens\":30}}");

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    try parseEventStreamFrames(allocator, &stream_instance, body.items, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream_instance.next().?.event_type);
    const thinking_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_delta, thinking_delta.event_type);
    try std.testing.expectEqualStrings("Need weather.", thinking_delta.delta.?);
    try std.testing.expectEqual(types.EventType.thinking_end, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const text_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqualStrings("Checking now", text_delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream_instance.next().?.event_type);
    const tool_delta_one = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta_one.event_type);
    try std.testing.expect(std.mem.indexOf(u8, tool_delta_one.delta.?, "Ber") != null);
    const tool_delta_two = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta_two.event_type);
    try std.testing.expect(std.mem.indexOf(u8, tool_delta_two.delta.?, "unit") != null);
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqualStrings("get_weather", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("Berlin", tool_end.tool_call.?.arguments.object.get("city").?.string);
    try std.testing.expectEqualStrings("C", tool_end.tool_call.?.arguments.object.get("unit").?.string);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(u32, 21), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 9), done.message.?.usage.output);
    try std.testing.expectEqual(@as(u32, 30), done.message.?.usage.total_tokens);
}

test "parse bedrock stream emits text thinking and tool call events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body =
        "data: {\"messageStart\":{\"role\":\"assistant\"}}\n" ++
        "data: {\"contentBlockDelta\":{\"contentBlockIndex\":0,\"delta\":{\"reasoningContent\":{\"text\":\"Need weather.\",\"signature\":\"sig-1\"}}}}\n" ++
        "data: {\"contentBlockStop\":{\"contentBlockIndex\":0}}\n" ++
        "data: {\"contentBlockDelta\":{\"contentBlockIndex\":1,\"delta\":{\"text\":\"Checking now\"}}}\n" ++
        "data: {\"contentBlockStop\":{\"contentBlockIndex\":1}}\n" ++
        "data: {\"contentBlockStart\":{\"contentBlockIndex\":2,\"start\":{\"toolUse\":{\"toolUseId\":\"tool-1\",\"name\":\"get_weather\"}}}}\n" ++
        "data: {\"contentBlockDelta\":{\"contentBlockIndex\":2,\"delta\":{\"toolUse\":{\"input\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}}}}\n" ++
        "data: {\"contentBlockStop\":{\"contentBlockIndex\":2}}\n" ++
        "data: {\"messageStop\":{\"stopReason\":\"tool_use\"}}\n" ++
        "data: {\"metadata\":{\"usage\":{\"inputTokens\":21,\"outputTokens\":9,\"totalTokens\":30}}}\n";

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = try allocator.dupe(u8, body),
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude 3.7 Sonnet",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 8192,
    };

    try parseTextStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream_instance.next().?.event_type);
    const thinking_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.thinking_delta, thinking_delta.event_type);
    try std.testing.expectEqualStrings("Need weather.", thinking_delta.delta.?);
    try std.testing.expectEqual(types.EventType.thinking_end, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const text_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqualStrings("Checking now", text_delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream_instance.next().?.event_type);
    const tool_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta.event_type);
    try std.testing.expect(std.mem.indexOf(u8, tool_delta.delta.?, "Berlin") != null);
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqualStrings("get_weather", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("Berlin", tool_end.tool_call.?.arguments.object.get("city").?.string);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqual(@as(u32, 21), done.message.?.usage.input);
    try std.testing.expectEqual(@as(u32, 9), done.message.?.usage.output);
    try std.testing.expectEqual(@as(u32, 30), done.message.?.usage.total_tokens);
}

test "parseEventStreamFrames joins split tool call input fragments" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const model = types.Model{
        .id = "anthropic.claude-3-7-sonnet-20250219-v1:0",
        .name = "Claude 3.7 Sonnet",
        .api = "bedrock-converse-stream",
        .provider = "amazon-bedrock",
        .base_url = "https://bedrock-runtime.us-east-1.amazonaws.com",
        .input_types = &[_][]const u8{"text"},
        .context_window = 200000,
        .max_tokens = 8192,
    };

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try appendEventStreamFrame(allocator, &body, "messageStart", "{\"role\":\"assistant\"}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStart", "{\"contentBlockIndex\":0,\"start\":{\"toolUse\":{\"toolUseId\":\"tool-1\",\"name\":\"get_weather\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"toolUse\":{\"input\":\"{\\\"city\\\":\\\"Ber\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"toolUse\":{\"input\":\"lin\\\",\\\"unit\\\":\\\"C\\\"}\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStop", "{\"contentBlockIndex\":0}");
    try appendEventStreamFrame(allocator, &body, "messageStop", "{\"stopReason\":\"tool_use\"}");

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    try parseEventStreamFrames(allocator, &stream_instance, body.items, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream_instance.next().?.event_type);
    const tool_delta_one = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta_one.event_type);
    try std.testing.expectEqualStrings("{\"city\":\"Ber", tool_delta_one.delta.?);
    const tool_delta_two = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_delta, tool_delta_two.event_type);
    try std.testing.expectEqualStrings("lin\",\"unit\":\"C\"}", tool_delta_two.delta.?);
    const tool_end = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.toolcall_end, tool_end.event_type);
    try std.testing.expectEqualStrings("tool-1", tool_end.tool_call.?.id);
    try std.testing.expectEqualStrings("get_weather", tool_end.tool_call.?.name);
    try std.testing.expectEqualStrings("Berlin", tool_end.tool_call.?.arguments.object.get("city").?.string);
    try std.testing.expectEqualStrings("C", tool_end.tool_call.?.arguments.object.get("unit").?.string);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
}

fn runtimePreservationTestModel(api: types.Api, provider: types.Provider) types.Model {
    return .{
        .id = "runtime-test-model",
        .name = "Runtime Test Model",
        .api = api,
        .provider = provider,
        .base_url = "https://example.test",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };
}

test "parseTextStreamLines preserves partial Bedrock text before malformed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"messageStart\":{\"role\":\"assistant\"}}\n" ++
            "data: {\"contentBlockDelta\":{\"contentBlockIndex\":0,\"delta\":{\"text\":\"partial\"}}}\n" ++
            "data: {not-json}\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseTextStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("bedrock-converse-stream", "bedrock"), null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial", delta.delta.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}

test "parseEventStreamFrames finalizes partial Bedrock blocks before provider exception" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const model = runtimePreservationTestModel("bedrock-converse-stream", "amazon-bedrock");

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try appendEventStreamFrame(allocator, &body, "messageStart", "{\"role\":\"assistant\"}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"partial text\"}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":1,\"delta\":{\"reasoningContent\":{\"text\":\"partial thought\",\"signature\":\"sig-1\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockStart", "{\"contentBlockIndex\":2,\"start\":{\"toolUse\":{\"toolUseId\":\"tool-1\",\"name\":\"get_weather\"}}}");
    try appendEventStreamFrame(allocator, &body, "contentBlockDelta", "{\"contentBlockIndex\":2,\"delta\":{\"toolUse\":{\"input\":\"{\\\"city\\\":\\\"Berlin\\\"}\"}}}");
    try appendEventStreamFrame(allocator, &body, "modelStreamErrorException", "{\"message\":\"provider failed with sk-bedrock-secret at /Users/alice/file.zig\"}");

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseEventStreamFrames(allocator, &stream, body.items, model, null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_delta, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_delta, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_delta, stream.next().?.event_type);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings("partial text", terminal.message.?.content[0].text.text);
    try std.testing.expectEqualStrings("partial thought", terminal.message.?.content[1].thinking.thinking);
    try std.testing.expect(terminal.message.?.content[2] == .tool_call);
    try std.testing.expectEqualStrings("get_weather", terminal.message.?.content[2].tool_call.name);
    try std.testing.expectEqualStrings("Berlin", terminal.message.?.content[2].tool_call.arguments.object.get("city").?.string);
    try std.testing.expectEqualStrings("Berlin", terminal.message.?.tool_calls.?[0].arguments.object.get("city").?.string);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, "sk-bedrock-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.error_message.?, "/Users/alice") == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
    try std.testing.expect(stream.next() == null);
}

test "Bedrock abort terminal finalizes active binary partial blocks" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const model = runtimePreservationTestModel("bedrock-converse-stream", "amazon-bedrock");
    var output = initOutput(model);
    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);
    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);
    var active_blocks = std.ArrayList(BlockEntry).empty;
    defer {
        for (active_blocks.items) |*entry| deinitCurrentBlock(allocator, &entry.block);
        active_blocks.deinit(allocator);
    }

    var text = std.ArrayList(u8).empty;
    try text.appendSlice(allocator, "partial before abort");
    try active_blocks.append(allocator, .{
        .bedrock_index = 0,
        .event_index = 0,
        .block = .{ .text = text },
    });

    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();
    stream.push(.{ .event_type = .start });

    try emitRuntimeFailure(allocator, &stream, &output, &content_blocks, &tool_calls, &active_blocks, model, error.RequestAborted);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqual(types.StopReason.aborted, terminal.message.?.stop_reason);
    try std.testing.expectEqualStrings("partial before abort", terminal.message.?.content[0].text.text);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
    try std.testing.expect(stream.next() == null);
}
