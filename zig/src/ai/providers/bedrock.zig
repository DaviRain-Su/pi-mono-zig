const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const event_stream = @import("../event_stream.zig");

const SERVICE_NAME = "bedrock";
const SHA256_HEX_LEN = std.crypto.hash.sha2.Sha256.digest_length * 2;

const BedrockError = error{
    MissingAwsAccessKeyId,
    MissingAwsSecretAccessKey,
    InvalidBedrockChunk,
    InvalidBedrockEventStream,
    UnsupportedEventStreamHeaderType,
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

        const credentials = resolveAwsCredentials(allocator) catch |err| {
            try emitAuthError(allocator, &stream_instance, model, authErrorMessage(err));
            return stream_instance;
        };
        defer credentials.deinit(allocator);

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
        try signRequestHeaders(allocator, &headers, model, request_path, json_body, credentials, timestamp);

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
                var response_headers = std.StringHashMap([]const u8).init(allocator);
                defer response_headers.deinit();
                callback(response.status, response_headers, model);
            }
        }

        if (response.status != 200) {
            const detail = extractErrorMessage(response.body);
            const error_message = try std.fmt.allocPrint(allocator, "Bedrock API error ({d}): {s}", .{ response.status, detail });
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
            stream_instance.push(.{
                .event_type = .error_event,
                .error_message = error_message,
                .message = message,
            });
            stream_instance.end(message);
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
        return stream(allocator, io, model, context, options);
    }
};

pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    var payload = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer payload.deinit(allocator);

    try payload.put(allocator, try allocator.dupe(u8, "messages"), try buildMessagesValue(allocator, context.messages));

    if (context.system_prompt) |system_prompt| {
        try payload.put(allocator, try allocator.dupe(u8, "system"), try buildSystemValue(allocator, system_prompt));
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
        if (try buildRequestMetadataValue(allocator, stream_options.metadata)) |request_metadata| {
            try payload.put(allocator, try allocator.dupe(u8, "requestMetadata"), request_metadata);
        }
    }

    return .{ .object = payload };
}

fn buildSystemValue(allocator: std.mem.Allocator, system_prompt: []const u8) !std.json.Value {
    var blocks = std.json.Array.init(allocator);
    errdefer blocks.deinit();
    try blocks.append(try buildTextBlockObject(allocator, system_prompt));
    return .{ .array = blocks };
}

fn buildInferenceConfigValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
) !std.json.Value {
    var config = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer config.deinit(allocator);

    const max_tokens = if (options) |stream_options|
        stream_options.max_tokens orelse @max(@as(u32, 1), @min(model.max_tokens, @as(u32, 4096)))
    else
        @max(@as(u32, 1), @min(model.max_tokens, @as(u32, 4096)));
    try config.put(allocator, try allocator.dupe(u8, "maxTokens"), .{ .integer = @intCast(max_tokens) });

    if (options) |stream_options| {
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

fn buildMessagesValue(allocator: std.mem.Allocator, messages: []const types.Message) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();

    var index: usize = 0;
    while (index < messages.len) : (index += 1) {
        switch (messages[index]) {
            .user => |user| try array.append(try buildUserMessageValue(allocator, user)),
            .assistant => |assistant| {
                if (try buildAssistantMessageValue(allocator, assistant)) |message_value| {
                    try array.append(message_value);
                }
            },
            .tool_result => {
                const grouped = try buildToolResultMessageValue(allocator, messages[index..]);
                try array.append(grouped.value);
                index += grouped.consumed - 1;
            },
        }
    }

    return .{ .array = array };
}

fn buildUserMessageValue(allocator: std.mem.Allocator, user: types.UserMessage) !std.json.Value {
    var content = std.json.Array.init(allocator);
    errdefer content.deinit();

    for (user.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
                try content.append(try buildTextBlockObject(allocator, text.text));
            },
            .image => try content.append(try buildTextBlockObject(allocator, "(image omitted: binary Bedrock image upload not implemented)")),
            .thinking => {},
        }
    }

    if (content.items.len == 0) try content.append(try buildTextBlockObject(allocator, ""));
    return try buildRoleMessageObject(allocator, "user", .{ .array = content });
}

fn buildAssistantMessageValue(allocator: std.mem.Allocator, assistant: types.AssistantMessage) !?std.json.Value {
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
                if (thinking.signature) |signature| {
                    var reasoning_text = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    try reasoning_text.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, thinking.thinking) });
                    try reasoning_text.put(allocator, try allocator.dupe(u8, "signature"), .{ .string = try allocator.dupe(u8, signature) });

                    var reasoning_content = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    try reasoning_content.put(allocator, try allocator.dupe(u8, "reasoningText"), .{ .object = reasoning_text });

                    var block_object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                    try block_object.put(allocator, try allocator.dupe(u8, "reasoningContent"), .{ .object = reasoning_content });
                    try content.append(.{ .object = block_object });
                } else {
                    try content.append(try buildTextBlockObject(allocator, thinking.thinking));
                }
            },
            .image => {},
        }
    }

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

    if (content.items.len == 0) return null;
    return try buildRoleMessageObject(allocator, "assistant", .{ .array = content });
}

fn buildToolResultMessageValue(
    allocator: std.mem.Allocator,
    messages: []const types.Message,
) !struct { value: std.json.Value, consumed: usize } {
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
                        .image => try tool_result_blocks.append(try buildTextBlockObject(allocator, "(image omitted)")),
                        .thinking => |thinking| try tool_result_blocks.append(try buildTextBlockObject(allocator, thinking.thinking)),
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
        if (stream_options.google_tool_choice) |tool_choice| {
            if (std.ascii.eqlIgnoreCase(tool_choice, "none")) return null;
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
        if (stream_options.google_tool_choice) |tool_choice| {
            if (try buildToolChoiceValue(allocator, tool_choice)) |choice_value| {
                try config.put(allocator, try allocator.dupe(u8, "toolChoice"), choice_value);
            }
        }
    }

    return .{ .object = config };
}

fn buildToolChoiceValue(allocator: std.mem.Allocator, tool_choice: []const u8) !?std.json.Value {
    if (std.ascii.eqlIgnoreCase(tool_choice, "auto")) {
        return .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{try allocator.dupe(u8, "auto")}, &[_]std.json.Value{.{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) }}) };
    }
    if (std.ascii.eqlIgnoreCase(tool_choice, "any")) {
        return .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{try allocator.dupe(u8, "any")}, &[_]std.json.Value{.{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) }}) };
    }
    return null;
}

fn buildTextBlockObject(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text) });
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

fn loadEnvRequired(allocator: std.mem.Allocator, name: []const u8, comptime err: anytype) ![]u8 {
    return try loadEnvOptional(allocator, name) orelse err;
}

fn loadEnvOptional(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    const value = std.c.getenv(name_z) orelse return null;
    return try allocator.dupe(u8, std.mem.span(value));
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

fn resolveBedrockRegion(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
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
) !void {
    const host = try extractHostFromUrl(allocator, model.base_url);
    defer allocator.free(host);
    const region = try resolveBedrockRegion(allocator, model.base_url);
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

    stream_ptr.push(.{ .event_type = .start });

    var cursor: usize = 0;
    while (cursor < body.len) {
        if (isAbortRequested(options)) {
            output.stop_reason = .aborted;
            output.error_message = "Request was aborted";
            stream_ptr.push(.{ .event_type = .error_event, .error_message = output.error_message, .message = output });
            stream_ptr.end(output);
            return;
        }

        if (body.len - cursor < 16) return BedrockError.InvalidBedrockEventStream;
        const total_length = readBigEndianU32(body[cursor..][0..4]);
        const headers_length = readBigEndianU32(body[cursor..][4..8]);
        if (total_length < 16 or cursor + total_length > body.len) return BedrockError.InvalidBedrockEventStream;
        const headers_start = cursor + 12;
        const headers_end = headers_start + headers_length;
        if (headers_end + 4 > cursor + total_length) return BedrockError.InvalidBedrockEventStream;
        const payload_end = cursor + total_length - 4;

        const parsed_headers = try parseEventStreamHeaders(body[headers_start..headers_end]);
        const payload = body[headers_end..payload_end];
        cursor += total_length;

        if (payload.len == 0) continue;
        try parseWrappedEventPayload(allocator, stream_ptr, payload, parsed_headers.event_type, parsed_headers.exception_type, &output, &content_blocks, &tool_calls, &active_blocks, model);
        if (output.stop_reason == .error_reason and output.error_message != null and stream_ptr.result() != null) return;
    }

    try finalizeOutput(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model);
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
    model: types.Model,
) !void {
    var parsed = try json_parse.parseStreamingJson(allocator, payload);
    defer parsed.deinit();

    if (parsed.value != .object or !containsKnownEventField(parsed.value)) {
        const wrapped = try wrapEventValue(allocator, parsed.value, event_type, exception_type);
        defer freeJsonValue(allocator, wrapped);
        try handleEventValue(allocator, stream_ptr, wrapped, output, content_blocks, tool_calls, active_blocks, model);
        return;
    }
    try handleEventValue(allocator, stream_ptr, parsed.value, output, content_blocks, tool_calls, active_blocks, model);
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
        try object.put(allocator, try allocator.dupe(u8, name), try cloneJsonValue(allocator, value));
        return .{ .object = object };
    }
    return BedrockError.InvalidBedrockChunk;
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

    stream_ptr.push(.{ .event_type = .start });

    while (try streaming.readLine()) |line| {
        if (isAbortRequested(options)) {
            output.stop_reason = .aborted;
            output.error_message = "Request was aborted";
            stream_ptr.push(.{ .event_type = .error_event, .error_message = output.error_message, .message = output });
            stream_ptr.end(output);
            return;
        }

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "event:")) continue;
        const payload = if (std.mem.startsWith(u8, trimmed, "data: ")) trimmed[6..] else trimmed;
        if (payload.len == 0) continue;

        var parsed = try json_parse.parseStreamingJson(allocator, payload);
        defer parsed.deinit();
        try handleEventValue(allocator, stream_ptr, parsed.value, &output, &content_blocks, &tool_calls, &active_blocks, model);
        if (stream_ptr.result() != null) return;
    }

    try finalizeOutput(allocator, stream_ptr, &output, &content_blocks, &tool_calls, &active_blocks, model);
}

fn handleEventValue(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    value: std.json.Value,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
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
            output.stop_reason = .error_reason;
            output.error_message = try buildExceptionMessage(allocator, field, exception_value);
            stream_ptr.push(.{ .event_type = .error_event, .error_message = output.error_message, .message = output.* });
            stream_ptr.end(output.*);
            return;
        }
    }

    if (value.object.get("messageStart")) |_| {
        return;
    }
    if (value.object.get("contentBlockStart")) |start_value| {
        try handleContentBlockStart(allocator, active_blocks, stream_ptr, content_blocks.items.len, start_value);
        return;
    }
    if (value.object.get("contentBlockDelta")) |delta_value| {
        try handleContentBlockDelta(allocator, active_blocks, stream_ptr, content_blocks.items.len, delta_value);
        return;
    }
    if (value.object.get("contentBlockStop")) |stop_value| {
        try handleContentBlockStop(allocator, active_blocks, content_blocks, tool_calls, stream_ptr, stop_value);
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
    const detail = if (value == .object and value.object.get("message") != null and value.object.get("message").? == .string)
        value.object.get("message").?.string
    else
        "Bedrock streaming request failed";
    return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ field, detail });
}

fn handleContentBlockStart(
    allocator: std.mem.Allocator,
    active_blocks: *std.ArrayList(BlockEntry),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    completed_count: usize,
    value: std.json.Value,
) !void {
    if (value != .object) return BedrockError.InvalidBedrockChunk;
    const index_value = value.object.get("contentBlockIndex") orelse return BedrockError.InvalidBedrockChunk;
    if (index_value != .integer) return BedrockError.InvalidBedrockChunk;
    const bedrock_index: usize = @intCast(index_value.integer);

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
    stream_ptr: *event_stream.AssistantMessageEventStream,
    completed_count: usize,
    value: std.json.Value,
) !void {
    if (value != .object) return BedrockError.InvalidBedrockChunk;
    const index_value = value.object.get("contentBlockIndex") orelse return BedrockError.InvalidBedrockChunk;
    if (index_value != .integer) return BedrockError.InvalidBedrockChunk;
    const bedrock_index: usize = @intCast(index_value.integer);
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
            if (entry.block.thinking.signature) |existing| allocator.free(existing);
            entry.block.thinking.signature = try allocator.dupe(u8, signature);
        }
        return;
    }
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

    switch (entry.block) {
        .text => |text| {
            const owned = try allocator.dupe(u8, text.items);
            try content_blocks.append(allocator, .{ .text = .{ .text = owned } });
            stream_ptr.push(.{ .event_type = .text_end, .content_index = @intCast(entry.event_index), .content = owned });
        },
        .thinking => |thinking| {
            const owned = try allocator.dupe(u8, thinking.text.items);
            const signature = if (thinking.signature) |value_bytes| try allocator.dupe(u8, value_bytes) else null;
            try content_blocks.append(allocator, .{ .thinking = .{ .thinking = owned, .signature = signature, .redacted = false } });
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
            try content_blocks.append(allocator, .{ .text = .{ .text = "" } });
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
        break :blk if (total > 0) total else output.usage.input + output.usage.output + output.usage.cache_read + output.usage.cache_write;
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

fn finalizeOutput(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    active_blocks: *std.ArrayList(BlockEntry),
    model: types.Model,
) !void {
    _ = model;
    if (active_blocks.items.len != 0) return BedrockError.InvalidBedrockChunk;
    output.content = try content_blocks.toOwnedSlice(allocator);
    output.tool_calls = if (tool_calls.items.len > 0) try tool_calls.toOwnedSlice(allocator) else null;
    output.usage.total_tokens = if (output.usage.total_tokens > 0) output.usage.total_tokens else output.usage.input + output.usage.output + output.usage.cache_read + output.usage.cache_write;

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

fn extractErrorMessage(body: []const u8) []const u8 {
    return if (body.len == 0) "Bedrock request failed" else body;
}

fn trimTrailingSlash(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
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
