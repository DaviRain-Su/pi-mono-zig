const std = @import("std");

const fixture_dir = "test/golden/openai-responses";
const max_diff_output_bytes: usize = 12_000;
const max_value_bytes: usize = 512;
const max_diffs: usize = 20;

const ignored_field_allowlist = [_][]const u8{
    "id",
    "title",
    "providerFamily",
    "input",
    "metadata",
    "schemaVersion",
    "expected.onPayload",
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    try runBoundedDiffSelfTest(allocator);
    try runIgnoredAllowlistSelfTest(allocator);

    const manifest = try readJsonFile(allocator, io, fixture_dir ++ "/manifest.json");
    defer manifest.deinit();

    const scenario_ids = getObjectField(manifest.value, "scenarioIds").array.items;
    var failures: usize = 0;
    var ignored_paths = IgnoredPathTracker{};

    for (scenario_ids) |scenario_id_value| {
        const scenario_id = scenario_id_value.string;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ fixture_dir, scenario_id });
        defer allocator.free(path);

        const fixture = try readJsonFile(allocator, io, path);
        defer fixture.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const actual_fixture = try buildActualFixtureComparisonRoot(arena.allocator(), fixture.value);

        var diffs = DiffCollector.init(allocator);
        defer diffs.deinit();

        try compareJson(&diffs, &ignored_paths, scenario_id, "", fixture.value, actual_fixture);
        if (diffs.count == 0) {
            std.debug.print("  matched {s}\n", .{scenario_id});
        } else {
            failures += 1;
            std.debug.print("{s}", .{diffs.buffer.items});
            if (diffs.truncated) {
                std.debug.print("scenario {s}: diff output truncated at {d} bytes\n", .{ scenario_id, max_diff_output_bytes });
            }
        }
    }

    if (failures > 0) {
        std.debug.print("OpenAI Responses parity failed for {d} scenario(s); diff bound={d} bytes\n", .{ failures, max_diff_output_bytes });
        std.process.exit(1);
    }

    const ignored_summary = try ignored_paths.summary(allocator);
    defer allocator.free(ignored_summary);
    const allowlist_summary = try ignoredAllowlistSummary(allocator);
    defer allocator.free(allowlist_summary);

    std.debug.print(
        "OpenAI Responses parity matched {d} scenarios; ignored paths: {s}; ignored allowlist: {s}\n",
        .{ scenario_ids.len, ignored_summary, allowlist_summary },
    );
}

fn ignoredAllowlistSummary(allocator: std.mem.Allocator) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    for (ignored_field_allowlist, 0..) |path, index| {
        if (index > 0) try buffer.appendSlice(allocator, ", ");
        try buffer.appendSlice(allocator, path);
    }
    return try buffer.toOwnedSlice(allocator);
}

fn readJsonFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !std.json.Parsed(std.json.Value) {
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1_000_000));
    defer allocator.free(bytes);
    return try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
}

fn buildActualFixtureComparisonRoot(allocator: std.mem.Allocator, fixture: std.json.Value) !std.json.Value {
    if (getObjectField(fixture, "schemaVersion").integer != 1) return error.UnsupportedFixtureSchemaVersion;
    const request = try buildRequestFromFixtureInput(allocator, getObjectField(fixture, "input"), getObjectField(fixture, "providerFamily").string, getObjectField(fixture, "id").string);

    var expected = try initObject(allocator);
    try putValue(allocator, &expected, "typeScriptRequest", request);

    var root = try initObject(allocator);
    try putValue(allocator, &root, "expected", .{ .object = expected });
    return .{ .object = root };
}

fn buildRequestFromFixtureInput(allocator: std.mem.Allocator, input: std.json.Value, provider_family: []const u8, scenario_id: []const u8) !std.json.Value {
    const model = getObjectField(input, "model");
    const context = getObjectField(input, "context");
    const options = getObjectField(input, "options");

    const payload = if (std.mem.eql(u8, provider_family, "azure-openai"))
        try buildAzurePayload(allocator, model, context, options)
    else if (std.mem.eql(u8, provider_family, "openai-codex"))
        try buildCodexPayload(allocator, model, context, options)
    else
        try buildOpenAIResponsesPayload(allocator, model, context, options, provider_family);

    const final_payload = if (optionalString(options, "onPayload")) |mode| blk: {
        if (std.mem.eql(u8, mode, "replace-with-fixture-payload")) {
            break :blk try cloneJsonValue(allocator, getObjectField(options, "payloadReplacement"));
        }
        break :blk payload;
    } else payload;

    var request = try initObject(allocator);
    try putString(allocator, &request, "method", "POST");

    const url_parts = try buildUrlParts(allocator, model, options, provider_family);
    try putString(allocator, &request, "url", url_parts.url);
    try putString(allocator, &request, "baseUrl", url_parts.base_url);
    try putString(allocator, &request, "path", url_parts.path);
    try putValue(allocator, &request, "query", .{ .object = url_parts.query });
    try putValue(allocator, &request, "headers", .{ .object = try buildHeaders(allocator, model, context, options, provider_family) });
    try putValue(allocator, &request, "jsonPayload", final_payload);
    try putValue(allocator, &request, "requestOptions", .{ .object = try buildRequestOptions(allocator, options) });
    try putValue(allocator, &request, "transportMetadata", .{ .object = try buildTransportMetadata(allocator, scenario_id, provider_family) });
    return .{ .object = request };
}

const UrlParts = struct {
    url: []const u8,
    base_url: []const u8,
    path: []const u8,
    query: std.json.ObjectMap,
};

fn buildUrlParts(allocator: std.mem.Allocator, model: std.json.Value, options: std.json.Value, provider_family: []const u8) !UrlParts {
    if (std.mem.eql(u8, provider_family, "azure-openai")) {
        const base = try azureBaseUrl(allocator, model, options);
        const api_version = optionalString(options, "azureApiVersion") orelse "v1";
        const url = try std.fmt.allocPrint(allocator, "{s}/responses?api-version={s}", .{ base, api_version });
        return .{
            .url = url,
            .base_url = base,
            .path = try pathFromUrl(allocator, url),
            .query = try oneStringFieldObject(allocator, "api-version", api_version),
        };
    }

    if (std.mem.eql(u8, provider_family, "openai-codex")) {
        const base = try trimTrailingSlashAlloc(allocator, getObjectField(model, "baseUrl").string);
        const url = if (std.mem.endsWith(u8, base, "/codex/responses"))
            try allocator.dupe(u8, base)
        else if (std.mem.endsWith(u8, base, "/codex"))
            try std.fmt.allocPrint(allocator, "{s}/responses", .{base})
        else
            try std.fmt.allocPrint(allocator, "{s}/codex/responses", .{base});
        return .{ .url = url, .base_url = base, .path = try pathFromUrl(allocator, url), .query = try initObject(allocator) };
    }

    const base = try trimTrailingSlashAlloc(allocator, getObjectField(model, "baseUrl").string);
    const url = try std.fmt.allocPrint(allocator, "{s}/responses", .{base});
    return .{ .url = url, .base_url = base, .path = try pathFromUrl(allocator, url), .query = try initObject(allocator) };
}

fn azureBaseUrl(allocator: std.mem.Allocator, model: std.json.Value, options: std.json.Value) ![]const u8 {
    if (optionalString(options, "azureBaseUrl")) |base| return try normalizeAzureBaseUrl(allocator, base);
    if (optionalString(options, "azureResourceName")) |resource| return try std.fmt.allocPrint(allocator, "https://{s}.openai.azure.com/openai/v1", .{resource});
    return try normalizeAzureBaseUrl(allocator, getObjectField(model, "baseUrl").string);
}

fn normalizeAzureBaseUrl(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \t\r\n"), "/");
    if (std.mem.endsWith(u8, trimmed, "/openai/v1")) return try allocator.dupe(u8, trimmed);
    if (std.mem.endsWith(u8, trimmed, "/openai")) return try std.fmt.allocPrint(allocator, "{s}/v1", .{trimmed});
    return try std.fmt.allocPrint(allocator, "{s}/openai/v1", .{trimmed});
}

fn pathFromUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return error.InvalidUrl;
    const after_host = url[scheme + 3 ..];
    const slash = std.mem.indexOfScalar(u8, after_host, '/') orelse return try allocator.dupe(u8, "/");
    const path_query = after_host[slash..];
    const query = std.mem.indexOfScalar(u8, path_query, '?') orelse return try allocator.dupe(u8, path_query);
    return try allocator.dupe(u8, path_query[0..query]);
}

fn trimTrailingSlashAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return try allocator.dupe(u8, std.mem.trimEnd(u8, std.mem.trim(u8, value, " \t\r\n"), "/"));
}

fn buildOpenAIResponsesPayload(allocator: std.mem.Allocator, model: std.json.Value, context: std.json.Value, options: std.json.Value, provider_family: []const u8) !std.json.Value {
    var payload = try initObject(allocator);
    try putString(allocator, &payload, "model", getObjectField(model, "id").string);
    try putValue(allocator, &payload, "input", .{ .array = try buildResponsesInput(allocator, model, context, true) });
    try putBool(allocator, &payload, "stream", true);
    try putBool(allocator, &payload, "store", false);

    if (optionalString(options, "cacheRetention")) |retention| {
        if (!std.mem.eql(u8, retention, "none")) {
            if (optionalString(options, "sessionId")) |session_id| try putString(allocator, &payload, "prompt_cache_key", session_id);
        }
        if (std.mem.eql(u8, retention, "long")) try putString(allocator, &payload, "prompt_cache_retention", "24h");
    } else if (optionalString(options, "sessionId")) |session_id| {
        try putString(allocator, &payload, "prompt_cache_key", session_id);
    }

    if (optionalU32(options, "maxTokens")) |max_tokens| {
        try putInteger(allocator, &payload, "max_output_tokens", max_tokens);
    } else if (optionalString(options, "simpleReasoning") != null) {
        try putInteger(allocator, &payload, "max_output_tokens", 4096);
    }
    if (optionalNumber(options, "temperature")) |temperature| try putFloat(allocator, &payload, "temperature", temperature);
    if (optionalString(options, "serviceTier")) |service_tier| try putString(allocator, &payload, "service_tier", service_tier);
    if (optionalField(context, "tools")) |tools| {
        if (tools == .array and tools.array.items.len > 0) try putValue(allocator, &payload, "tools", .{ .array = try buildTools(allocator, tools, false) });
    }

    const reasoning = optionalBool(model, "reasoning") orelse false;
    if (reasoning) {
        const effort = if (optionalString(options, "reasoningEffort")) |value|
            value
        else if (optionalString(options, "simpleReasoning")) |value|
            try clampSimpleReasoning(allocator, getObjectField(model, "id").string, value)
        else
            null;
        if (effort) |value| {
            try addReasoning(allocator, &payload, value, optionalString(options, "reasoningSummary") orelse "auto");
        } else if (optionalString(options, "reasoningSummary")) |summary| {
            try addReasoning(allocator, &payload, "medium", summary);
        } else if (!std.mem.eql(u8, provider_family, "github-copilot")) {
            var reasoning_object = try initObject(allocator);
            try putString(allocator, &reasoning_object, "effort", "none");
            try putValue(allocator, &payload, "reasoning", .{ .object = reasoning_object });
        }
    }

    return .{ .object = payload };
}

fn clampSimpleReasoning(allocator: std.mem.Allocator, model_id: []const u8, effort: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, effort, "xhigh")) return effort;
    if (supportsXhigh(model_id)) return effort;
    return try allocator.dupe(u8, "high");
}

fn supportsXhigh(model_id: []const u8) bool {
    return std.mem.indexOf(u8, model_id, "gpt-5.2") != null or
        std.mem.indexOf(u8, model_id, "gpt-5.3") != null or
        std.mem.indexOf(u8, model_id, "gpt-5.4") != null or
        std.mem.indexOf(u8, model_id, "gpt-5.5") != null or
        std.mem.indexOf(u8, model_id, "deepseek-v4-pro") != null or
        std.mem.indexOf(u8, model_id, "deepseek-v4-flash") != null or
        std.mem.indexOf(u8, model_id, "opus-4-6") != null or
        std.mem.indexOf(u8, model_id, "opus-4.6") != null or
        std.mem.indexOf(u8, model_id, "opus-4-7") != null or
        std.mem.indexOf(u8, model_id, "opus-4.7") != null;
}

fn buildAzurePayload(allocator: std.mem.Allocator, model: std.json.Value, context: std.json.Value, options: std.json.Value) !std.json.Value {
    var payload = try initObject(allocator);
    try putString(allocator, &payload, "model", optionalString(options, "azureDeploymentName") orelse getObjectField(model, "id").string);
    try putValue(allocator, &payload, "input", .{ .array = try buildResponsesInput(allocator, model, context, true) });
    try putBool(allocator, &payload, "stream", true);
    if (optionalString(options, "sessionId")) |session_id| try putString(allocator, &payload, "prompt_cache_key", session_id);
    if (optionalU32(options, "maxTokens")) |max_tokens| try putInteger(allocator, &payload, "max_output_tokens", max_tokens);
    if (optionalNumber(options, "temperature")) |temperature| try putFloat(allocator, &payload, "temperature", temperature);
    return .{ .object = payload };
}

fn buildCodexPayload(allocator: std.mem.Allocator, model: std.json.Value, context: std.json.Value, options: std.json.Value) !std.json.Value {
    var payload = try initObject(allocator);
    try putString(allocator, &payload, "model", getObjectField(model, "id").string);
    try putValue(allocator, &payload, "input", .{ .array = try buildResponsesInput(allocator, model, context, false) });
    if (optionalString(context, "systemPrompt")) |system_prompt| try putString(allocator, &payload, "instructions", system_prompt);
    try putBool(allocator, &payload, "store", false);
    try putBool(allocator, &payload, "stream", true);
    try putString(allocator, &payload, "tool_choice", "auto");
    try putBool(allocator, &payload, "parallel_tool_calls", true);
    try putValue(allocator, &payload, "include", .{ .array = try stringArray(allocator, &[_][]const u8{"reasoning.encrypted_content"}) });
    if (optionalString(options, "sessionId")) |session_id| try putString(allocator, &payload, "prompt_cache_key", session_id);
    if (optionalString(options, "serviceTier")) |service_tier| try putString(allocator, &payload, "service_tier", service_tier);
    var text = try initObject(allocator);
    try putString(allocator, &text, "verbosity", optionalString(options, "textVerbosity") orelse "low");
    try putValue(allocator, &payload, "text", .{ .object = text });
    return .{ .object = payload };
}

fn buildResponsesInput(allocator: std.mem.Allocator, model: std.json.Value, context: std.json.Value, include_system_prompt: bool) !std.json.Array {
    var input = std.json.Array.init(allocator);
    var normalized_tool_call_ids = std.StringHashMap([]const u8).init(allocator);
    if (include_system_prompt) {
        if (optionalString(context, "systemPrompt")) |system_prompt| {
            var item = try initObject(allocator);
            try putString(allocator, &item, "content", system_prompt);
            try putString(allocator, &item, "role", if ((optionalBool(model, "reasoning") orelse false)) "developer" else "system");
            try input.append(.{ .object = item });
        }
    }
    for (getObjectField(context, "messages").array.items, 0..) |message, msg_index| {
        const role = getObjectField(message, "role").string;
        if (std.mem.eql(u8, role, "user")) {
            const content = try buildUserContent(allocator, getObjectField(message, "content"));
            if (getObjectField(message, "content") == .array and content.items.len == 0) continue;
            var item = try initObject(allocator);
            try putString(allocator, &item, "role", "user");
            try putValue(allocator, &item, "content", .{ .array = content });
            try input.append(.{ .object = item });
        } else if (std.mem.eql(u8, role, "assistant")) {
            try appendAssistantInputItems(allocator, &input, model, message, msg_index, &normalized_tool_call_ids);
        } else if (std.mem.eql(u8, role, "toolResult")) {
            try input.append(try buildToolResultInputItem(allocator, model, message, &normalized_tool_call_ids));
        }
    }
    return input;
}

fn buildUserContent(allocator: std.mem.Allocator, content: std.json.Value) !std.json.Array {
    var parts = std.json.Array.init(allocator);
    if (content == .string) {
        var part = try initObject(allocator);
        try putString(allocator, &part, "text", content.string);
        try putString(allocator, &part, "type", "input_text");
        try parts.append(.{ .object = part });
        return parts;
    }
    for (content.array.items) |source_part| {
        const part_type = getObjectField(source_part, "type").string;
        var part = try initObject(allocator);
        if (std.mem.eql(u8, part_type, "text")) {
            try putString(allocator, &part, "text", getObjectField(source_part, "text").string);
            try putString(allocator, &part, "type", "input_text");
        } else if (std.mem.eql(u8, part_type, "image")) {
            try putString(allocator, &part, "detail", "auto");
            const image_url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ getObjectField(source_part, "mimeType").string, getObjectField(source_part, "data").string });
            try putString(allocator, &part, "image_url", image_url);
            try putString(allocator, &part, "type", "input_image");
        } else continue;
        try parts.append(.{ .object = part });
    }
    return parts;
}

fn appendAssistantInputItems(
    allocator: std.mem.Allocator,
    input: *std.json.Array,
    model: std.json.Value,
    assistant: std.json.Value,
    msg_index: usize,
    normalized_tool_call_ids: *std.StringHashMap([]const u8),
) !void {
    for (getObjectField(assistant, "content").array.items) |block| {
        const block_type = getObjectField(block, "type").string;
        if (std.mem.eql(u8, block_type, "thinking")) {
            if (optionalString(block, "thinkingSignature")) |signature| {
                var parsed = std.json.parseFromSlice(std.json.Value, allocator, signature, .{}) catch continue;
                defer parsed.deinit();
                try input.append(try cloneJsonValue(allocator, parsed.value));
            }
        } else if (std.mem.eql(u8, block_type, "text")) {
            var message_object = try initObject(allocator);
            try putString(allocator, &message_object, "type", "message");
            try putString(allocator, &message_object, "role", "assistant");
            try putString(allocator, &message_object, "status", "completed");
            const parsed_signature = try parseTextSignature(allocator, optionalString(block, "textSignature"), msg_index);
            try putString(allocator, &message_object, "id", parsed_signature.id);
            if (parsed_signature.phase) |phase| try putString(allocator, &message_object, "phase", phase);

            var content = std.json.Array.init(allocator);
            var text_object = try initObject(allocator);
            try putString(allocator, &text_object, "type", "output_text");
            try putString(allocator, &text_object, "text", getObjectField(block, "text").string);
            try putValue(allocator, &text_object, "annotations", .{ .array = std.json.Array.init(allocator) });
            try content.append(.{ .object = text_object });
            try putValue(allocator, &message_object, "content", .{ .array = content });
            try input.append(.{ .object = message_object });
        } else if (std.mem.eql(u8, block_type, "toolCall")) {
            const original_id = getObjectField(block, "id").string;
            const normalized_id = try normalizeToolCallId(allocator, original_id, model, assistant);
            if (!std.mem.eql(u8, original_id, normalized_id)) try normalized_tool_call_ids.put(original_id, normalized_id);
            const split = splitToolCallId(normalized_id);
            var tool_call_object = try initObject(allocator);
            try putString(allocator, &tool_call_object, "type", "function_call");
            try putString(allocator, &tool_call_object, "call_id", split.call_id);
            if (split.item_id) |item_id| try putString(allocator, &tool_call_object, "id", item_id);
            try putString(allocator, &tool_call_object, "name", getObjectField(block, "name").string);
            const arguments_json = try std.json.Stringify.valueAlloc(allocator, getObjectField(block, "arguments"), .{});
            try putString(allocator, &tool_call_object, "arguments", arguments_json);
            try input.append(.{ .object = tool_call_object });
        }
    }
}

const ParsedTextSignature = struct {
    id: []const u8,
    phase: ?[]const u8,
};

fn parseTextSignature(allocator: std.mem.Allocator, signature: ?[]const u8, msg_index: usize) !ParsedTextSignature {
    const value = signature orelse return .{ .id = try std.fmt.allocPrint(allocator, "msg_{d}", .{msg_index}), .phase = null };
    if (std.mem.startsWith(u8, value, "{")) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, value, .{}) catch {
            return .{ .id = try allocator.dupe(u8, value), .phase = null };
        };
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("v")) |version| {
                if (version == .integer and version.integer == 1) {
                    if (optionalString(parsed.value, "id")) |id| {
                        const phase = optionalString(parsed.value, "phase");
                        if (phase != null and (std.mem.eql(u8, phase.?, "commentary") or std.mem.eql(u8, phase.?, "final_answer"))) {
                            return .{ .id = try allocator.dupe(u8, id), .phase = try allocator.dupe(u8, phase.?) };
                        }
                        return .{ .id = try allocator.dupe(u8, id), .phase = null };
                    }
                }
            }
        }
    }
    return .{ .id = try allocator.dupe(u8, value), .phase = null };
}

fn buildToolResultInputItem(
    allocator: std.mem.Allocator,
    model: std.json.Value,
    tool_result: std.json.Value,
    normalized_tool_call_ids: *std.StringHashMap([]const u8),
) !std.json.Value {
    const original_id = getObjectField(tool_result, "toolCallId").string;
    const normalized_id = normalized_tool_call_ids.get(original_id) orelse original_id;
    const split = splitToolCallId(normalized_id);
    var object = try initObject(allocator);
    try putString(allocator, &object, "type", "function_call_output");
    try putString(allocator, &object, "call_id", split.call_id);

    const supports_images = modelSupportsImages(model);
    var text_parts = std.ArrayList(u8).empty;
    var image_count: usize = 0;
    for (getObjectField(tool_result, "content").array.items) |block| {
        const block_type = getObjectField(block, "type").string;
        if (std.mem.eql(u8, block_type, "text")) {
            if (text_parts.items.len > 0) try text_parts.appendSlice(allocator, "\n");
            try text_parts.appendSlice(allocator, getObjectField(block, "text").string);
        } else if (std.mem.eql(u8, block_type, "image")) {
            image_count += 1;
        }
    }

    if (supports_images and image_count > 0) {
        var output = std.json.Array.init(allocator);
        if (text_parts.items.len > 0) {
            var text_object = try initObject(allocator);
            try putString(allocator, &text_object, "type", "input_text");
            try putString(allocator, &text_object, "text", text_parts.items);
            try output.append(.{ .object = text_object });
        }
        for (getObjectField(tool_result, "content").array.items) |block| {
            if (!std.mem.eql(u8, getObjectField(block, "type").string, "image")) continue;
            var image_object = try initObject(allocator);
            try putString(allocator, &image_object, "type", "input_image");
            try putString(allocator, &image_object, "detail", "auto");
            const image_url = try std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ getObjectField(block, "mimeType").string, getObjectField(block, "data").string });
            try putString(allocator, &image_object, "image_url", image_url);
            try output.append(.{ .object = image_object });
        }
        try putValue(allocator, &object, "output", .{ .array = output });
    } else {
        const output = if (text_parts.items.len > 0) text_parts.items else "(see attached image)";
        try putString(allocator, &object, "output", output);
    }

    return .{ .object = object };
}

fn normalizeToolCallId(allocator: std.mem.Allocator, id: []const u8, model: std.json.Value, source: std.json.Value) ![]const u8 {
    if (!std.mem.eql(u8, getObjectField(model, "provider").string, "openai") and
        !std.mem.eql(u8, getObjectField(model, "provider").string, "openai-codex") and
        !std.mem.eql(u8, getObjectField(model, "provider").string, "opencode"))
    {
        return normalizeIdPart(allocator, id);
    }
    const separator = std.mem.indexOfScalar(u8, id, '|') orelse return normalizeIdPart(allocator, id);
    const call_id = try normalizeIdPart(allocator, id[0..separator]);
    const item_id = id[separator + 1 ..];
    const is_foreign = !std.mem.eql(u8, getObjectField(source, "provider").string, getObjectField(model, "provider").string) or
        !std.mem.eql(u8, getObjectField(source, "api").string, getObjectField(model, "api").string);
    var normalized_item_id = if (is_foreign)
        try buildForeignResponsesItemId(allocator, item_id)
    else
        try normalizeIdPart(allocator, item_id);
    if (!std.mem.startsWith(u8, normalized_item_id, "fc_")) {
        const prefixed = try std.fmt.allocPrint(allocator, "fc_{s}", .{normalized_item_id});
        normalized_item_id = try normalizeIdPart(allocator, prefixed);
    }
    return try std.fmt.allocPrint(allocator, "{s}|{s}", .{ call_id, normalized_item_id });
}

fn normalizeIdPart(allocator: std.mem.Allocator, part: []const u8) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    for (part) |char| {
        const normalized = if (std.ascii.isAlphanumeric(char) or char == '_' or char == '-') char else '_';
        try buffer.append(allocator, normalized);
        if (buffer.items.len == 64) break;
    }
    while (buffer.items.len > 0 and buffer.items[buffer.items.len - 1] == '_') _ = buffer.pop();
    return try buffer.toOwnedSlice(allocator);
}

fn buildForeignResponsesItemId(allocator: std.mem.Allocator, item_id: []const u8) ![]const u8 {
    const hash = try shortHash(allocator, item_id);
    const prefixed = try std.fmt.allocPrint(allocator, "fc_{s}", .{hash});
    if (prefixed.len > 64) return try allocator.dupe(u8, prefixed[0..64]);
    return prefixed;
}

fn splitToolCallId(id: []const u8) struct { call_id: []const u8, item_id: ?[]const u8 } {
    if (std.mem.indexOfScalar(u8, id, '|')) |separator_index| {
        const item_id = id[separator_index + 1 ..];
        return .{
            .call_id = id[0..separator_index],
            .item_id = if (item_id.len > 0) item_id else null,
        };
    }
    return .{ .call_id = id, .item_id = null };
}

fn modelSupportsImages(model: std.json.Value) bool {
    const input = optionalField(model, "input") orelse return false;
    if (input != .array) return false;
    for (input.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, "image")) return true;
    }
    return false;
}

fn shortHash(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var h1: u32 = 0xdeadbeef;
    var h2: u32 = 0x41c6ce57;
    for (input) |char| {
        const ch: u32 = char;
        h1 = (h1 ^ ch) *% 2654435761;
        h2 = (h2 ^ ch) *% 1597334677;
    }
    h1 = ((h1 ^ (h1 >> 16)) *% 2246822507) ^ ((h2 ^ (h2 >> 13)) *% 3266489909);
    h2 = ((h2 ^ (h2 >> 16)) *% 2246822507) ^ ((h1 ^ (h1 >> 13)) *% 3266489909);
    const high = try u32ToBase36(allocator, h2);
    const low = try u32ToBase36(allocator, h1);
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ high, low });
}

fn u32ToBase36(allocator: std.mem.Allocator, value: u32) ![]const u8 {
    if (value == 0) return try allocator.dupe(u8, "0");
    var digits: [16]u8 = undefined;
    var current = value;
    var index: usize = digits.len;
    while (current > 0) {
        index -= 1;
        const digit: u8 = @intCast(current % 36);
        digits[index] = if (digit < 10) '0' + digit else 'a' + (digit - 10);
        current /= 36;
    }
    return try allocator.dupe(u8, digits[index..]);
}

fn buildTools(allocator: std.mem.Allocator, tools: std.json.Value, strict_null: bool) !std.json.Array {
    var array = std.json.Array.init(allocator);
    for (tools.array.items) |tool| {
        var object = try initObject(allocator);
        try putString(allocator, &object, "description", getObjectField(tool, "description").string);
        try putString(allocator, &object, "name", getObjectField(tool, "name").string);
        try putValue(allocator, &object, "parameters", try cloneJsonValue(allocator, getObjectField(tool, "parameters")));
        if (strict_null) try putValue(allocator, &object, "strict", .null) else try putBool(allocator, &object, "strict", false);
        try putString(allocator, &object, "type", "function");
        try array.append(.{ .object = object });
    }
    return array;
}

fn addReasoning(allocator: std.mem.Allocator, payload: *std.json.ObjectMap, effort: []const u8, summary: []const u8) !void {
    var reasoning = try initObject(allocator);
    try putString(allocator, &reasoning, "effort", effort);
    try putString(allocator, &reasoning, "summary", summary);
    try putValue(allocator, payload, "reasoning", .{ .object = reasoning });
    try putValue(allocator, payload, "include", .{ .array = try stringArray(allocator, &[_][]const u8{"reasoning.encrypted_content"}) });
}

fn buildHeaders(allocator: std.mem.Allocator, model: std.json.Value, context: std.json.Value, options: std.json.Value, provider_family: []const u8) !std.json.ObjectMap {
    var headers = try initObject(allocator);

    if (std.mem.eql(u8, provider_family, "openai-codex")) {
        try mergeHeaderObject(allocator, &headers, optionalField(model, "headers"));
        try mergeHeaderObject(allocator, &headers, optionalField(options, "headers"));
        try putHeader(allocator, &headers, "Authorization", "<redacted-present>");
        try putHeader(allocator, &headers, "chatgpt-account-id", "fixture-account");
        try putHeader(allocator, &headers, "originator", "pi");
        try putHeader(allocator, &headers, "OpenAI-Beta", "responses=experimental");
        try putHeader(allocator, &headers, "accept", "text/event-stream");
        try putHeader(allocator, &headers, "content-type", "application/json");
        if (optionalString(options, "sessionId")) |session_id| {
            try putHeader(allocator, &headers, "session_id", session_id);
            try putHeader(allocator, &headers, "x-client-request-id", session_id);
        }
        return headers;
    }

    try putHeader(allocator, &headers, "accept", "application/json");
    try putHeader(allocator, &headers, "content-type", "application/json");
    if (std.mem.eql(u8, provider_family, "azure-openai")) {
        try putHeader(allocator, &headers, "api-key", "<redacted-present>");
    } else {
        try putHeader(allocator, &headers, "authorization", "<redacted-present>");
    }
    try mergeHeaderObject(allocator, &headers, optionalField(model, "headers"));
    if (std.mem.eql(u8, provider_family, "github-copilot")) {
        try putHeader(allocator, &headers, "X-Initiator", inferCopilotInitiator(context));
        try putHeader(allocator, &headers, "Openai-Intent", "conversation-edits");
        if (hasCopilotVisionInput(context)) try putHeader(allocator, &headers, "Copilot-Vision-Request", "true");
    }
    if (!std.mem.eql(u8, provider_family, "azure-openai")) {
        const cache_enabled = !std.mem.eql(u8, optionalString(options, "cacheRetention") orelse "short", "none");
        if (cache_enabled) {
            if (optionalString(options, "sessionId")) |session_id| {
                try putHeader(allocator, &headers, "session_id", session_id);
                try putHeader(allocator, &headers, "x-client-request-id", session_id);
            }
        }
    }
    try mergeHeaderObject(allocator, &headers, optionalField(options, "headers"));
    return headers;
}

fn inferCopilotInitiator(context: std.json.Value) []const u8 {
    const messages = getObjectField(context, "messages").array.items;
    if (messages.len == 0) return "user";
    const last = messages[messages.len - 1];
    const role = getObjectField(last, "role").string;
    return if (std.mem.eql(u8, role, "user")) "user" else "agent";
}

fn hasCopilotVisionInput(context: std.json.Value) bool {
    for (getObjectField(context, "messages").array.items) |message| {
        const role = getObjectField(message, "role").string;
        if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "toolResult")) continue;
        const content = getObjectField(message, "content");
        if (content != .array) continue;
        for (content.array.items) |part| {
            if (std.mem.eql(u8, getObjectField(part, "type").string, "image")) return true;
        }
    }
    return false;
}

fn buildRequestOptions(allocator: std.mem.Allocator, options: std.json.Value) !std.json.ObjectMap {
    var object = try initObject(allocator);
    if (optionalU32(options, "maxRetries")) |value| try putInteger(allocator, &object, "maxRetries", value);
    try putString(allocator, &object, "signal", "not-provided");
    if (optionalU32(options, "timeoutMs")) |value| try putInteger(allocator, &object, "timeoutMs", value);
    return object;
}

fn buildTransportMetadata(allocator: std.mem.Allocator, scenario_id: []const u8, provider_family: []const u8) !std.json.ObjectMap {
    var object = try initObject(allocator);
    var response_headers = try initObject(allocator);
    try putString(allocator, &response_headers, "content-type", "text/event-stream");
    try putString(allocator, &response_headers, "x-fixture-response", scenario_id);
    try putValue(allocator, &object, "mockedResponseHeaders", .{ .object = response_headers });
    try putInteger(allocator, &object, "mockedStatus", 200);
    try putString(allocator, &object, "mode", "sse");
    try putString(allocator, &object, "providerFamily", provider_family);
    try putString(allocator, &object, "requestBoundary", "before local mocked SSE response body is consumed");
    return object;
}

fn putHeader(allocator: std.mem.Allocator, headers: *std.json.ObjectMap, name: []const u8, value: []const u8) !void {
    const lower = try asciiLowerAlloc(allocator, name);
    try headers.put(allocator, lower, .{ .string = try allocator.dupe(u8, value) });
}

fn mergeHeaderObject(allocator: std.mem.Allocator, headers: *std.json.ObjectMap, maybe_source: ?std.json.Value) !void {
    const source = maybe_source orelse return;
    if (source != .object) return;
    var iterator = source.object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (value != .string) continue;
        if (isSemanticHeader(name, value.string)) try putHeader(allocator, headers, name, value.string);
    }
}

fn isSemanticHeader(name_raw: []const u8, value: []const u8) bool {
    var lower_buffer: [128]u8 = undefined;
    if (name_raw.len > lower_buffer.len) return false;
    const name = lower_buffer[0..name_raw.len];
    for (name_raw, 0..) |char, index| name[index] = std.ascii.toLower(char);
    if (std.mem.eql(u8, name, "user-agent")) return std.mem.startsWith(u8, value, "GitHubCopilotChat/");
    return std.mem.eql(u8, name, "accept") or
        std.mem.eql(u8, name, "chatgpt-account-id") or
        std.mem.eql(u8, name, "content-type") or
        std.mem.eql(u8, name, "copilot-integration-id") or
        std.mem.eql(u8, name, "copilot-vision-request") or
        std.mem.eql(u8, name, "editor-plugin-version") or
        std.mem.eql(u8, name, "editor-version") or
        std.mem.eql(u8, name, "openai-beta") or
        std.mem.eql(u8, name, "openai-intent") or
        std.mem.eql(u8, name, "originator") or
        std.mem.eql(u8, name, "session_id") or
        std.mem.eql(u8, name, "x-client-request-id") or
        std.mem.eql(u8, name, "x-initiator") or
        std.mem.startsWith(u8, name, "x-fixture-");
}

fn asciiLowerAlloc(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const output = try allocator.alloc(u8, input.len);
    for (input, 0..) |char, index| output[index] = std.ascii.toLower(char);
    return output;
}

fn stringArray(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Array {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = try allocator.dupe(u8, value) });
    return array;
}

fn oneStringFieldObject(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !std.json.ObjectMap {
    var object = try initObject(allocator);
    try putString(allocator, &object, key, value);
    return object;
}

fn initObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
}

fn putString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
}

fn putBool(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: bool) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .bool = value });
}

fn putInteger(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: u32) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .integer = @intCast(value) });
}

fn putFloat(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: f64) !void {
    try object.put(allocator, try allocator.dupe(u8, key), .{ .float = value });
}

fn putValue(allocator: std.mem.Allocator, object: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    try object.put(allocator, try allocator.dupe(u8, key), value);
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
            var cloned = std.json.Array.init(allocator);
            for (array.items) |item| try cloned.append(try cloneJsonValue(allocator, item));
            return .{ .array = cloned };
        },
        .object => |object| {
            var cloned = try initObject(allocator);
            var iterator = object.iterator();
            while (iterator.next()) |entry| try putValue(allocator, &cloned, entry.key_ptr.*, try cloneJsonValue(allocator, entry.value_ptr.*));
            return .{ .object = cloned };
        },
    }
}

fn getObjectField(value: std.json.Value, key: []const u8) std.json.Value {
    return value.object.get(key) orelse @panic("fixture missing required field");
}

fn optionalField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn optionalString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = optionalField(value, key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

fn optionalBool(value: std.json.Value, key: []const u8) ?bool {
    const field = optionalField(value, key) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

fn optionalU32(value: std.json.Value, key: []const u8) ?u32 {
    const field = optionalField(value, key) orelse return null;
    if (field != .integer) return null;
    return @intCast(field.integer);
}

fn optionalNumber(value: std.json.Value, key: []const u8) ?f64 {
    const field = optionalField(value, key) orelse return null;
    return switch (field) {
        .integer => @floatFromInt(field.integer),
        .float => field.float,
        else => null,
    };
}

const DiffCollector = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    count: usize = 0,
    truncated: bool = false,

    fn init(allocator: std.mem.Allocator) DiffCollector {
        return .{ .allocator = allocator, .buffer = std.ArrayList(u8).empty };
    }

    fn deinit(self: *DiffCollector) void {
        self.buffer.deinit(self.allocator);
    }

    fn add(self: *DiffCollector, scenario_id: []const u8, path: []const u8, expected: std.json.Value, actual: std.json.Value) !void {
        self.count += 1;
        if (self.count > max_diffs or self.buffer.items.len >= max_diff_output_bytes) {
            self.truncated = true;
            return;
        }
        const expected_rendered = try renderBoundedJson(self.allocator, expected);
        defer self.allocator.free(expected_rendered);
        const actual_rendered = try renderBoundedJson(self.allocator, actual);
        defer self.allocator.free(actual_rendered);
        const header = try std.fmt.allocPrint(self.allocator, "scenario {s}: path {s}\n  expected: ", .{ scenario_id, path });
        defer self.allocator.free(header);
        try self.appendBounded(header);
        try self.appendBounded(expected_rendered);
        try self.appendBounded("\n  actual: ");
        try self.appendBounded(actual_rendered);
        try self.appendBounded("\n");
    }

    fn appendBounded(self: *DiffCollector, text: []const u8) !void {
        if (self.buffer.items.len >= max_diff_output_bytes) {
            self.truncated = true;
            return;
        }
        const remaining = max_diff_output_bytes - self.buffer.items.len;
        const take = @min(remaining, text.len);
        try self.buffer.appendSlice(self.allocator, text[0..take]);
        if (take < text.len) self.truncated = true;
    }
};

const IgnoredPathTracker = struct {
    paths: [ignored_field_allowlist.len]bool = [_]bool{false} ** ignored_field_allowlist.len,

    fn shouldIgnore(self: *IgnoredPathTracker, path: []const u8) bool {
        for (ignored_field_allowlist, 0..) |ignored_path, index| {
            if (std.mem.eql(u8, path, ignored_path)) {
                self.paths[index] = true;
                return true;
            }
        }
        return false;
    }

    fn wasIgnored(self: *const IgnoredPathTracker, path: []const u8) bool {
        for (ignored_field_allowlist, 0..) |ignored_path, index| {
            if (std.mem.eql(u8, path, ignored_path)) return self.paths[index];
        }
        return false;
    }

    fn summary(self: *const IgnoredPathTracker, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).empty;
        errdefer buffer.deinit(allocator);
        var first = true;
        for (ignored_field_allowlist, 0..) |path, index| {
            if (!self.paths[index]) continue;
            if (!first) try buffer.appendSlice(allocator, ", ");
            try buffer.appendSlice(allocator, path);
            first = false;
        }
        if (first) try buffer.appendSlice(allocator, "(none)");
        return try buffer.toOwnedSlice(allocator);
    }
};

fn compareJson(diffs: *DiffCollector, ignored_paths: *IgnoredPathTracker, scenario_id: []const u8, path: []const u8, expected: std.json.Value, actual: std.json.Value) !void {
    if (ignored_paths.shouldIgnore(path)) return;
    if (expected == .integer and actual == .float) {
        if (@as(f64, @floatFromInt(expected.integer)) == actual.float) return;
    }
    if (expected == .float and actual == .integer) {
        if (expected.float == @as(f64, @floatFromInt(actual.integer))) return;
    }
    if (std.meta.activeTag(expected) != std.meta.activeTag(actual)) {
        try diffs.add(scenario_id, path, expected, actual);
        return;
    }
    switch (expected) {
        .null => {},
        .bool => |expected_bool| if (expected_bool != actual.bool) try diffs.add(scenario_id, path, expected, actual),
        .integer => |expected_integer| if (expected_integer != actual.integer) try diffs.add(scenario_id, path, expected, actual),
        .float => |expected_float| if (expected_float != actual.float) try diffs.add(scenario_id, path, expected, actual),
        .number_string => |expected_number| if (!std.mem.eql(u8, expected_number, actual.number_string)) try diffs.add(scenario_id, path, expected, actual),
        .string => |expected_string| if (!std.mem.eql(u8, expected_string, actual.string)) try diffs.add(scenario_id, path, expected, actual),
        .array => |expected_array| {
            if (expected_array.items.len != actual.array.items.len) {
                try diffs.add(scenario_id, path, expected, actual);
                return;
            }
            for (expected_array.items, actual.array.items, 0..) |expected_item, actual_item, index| {
                const child_path = try arrayChildPath(diffs.allocator, path, index);
                defer diffs.allocator.free(child_path);
                try compareJson(diffs, ignored_paths, scenario_id, child_path, expected_item, actual_item);
            }
        },
        .object => |expected_object| {
            var expected_iterator = expected_object.iterator();
            while (expected_iterator.next()) |entry| {
                const child_path = try objectChildPath(diffs.allocator, path, entry.key_ptr.*);
                defer diffs.allocator.free(child_path);
                if (ignored_paths.shouldIgnore(child_path)) continue;
                const actual_child = actual.object.get(entry.key_ptr.*) orelse {
                    try diffs.add(scenario_id, child_path, entry.value_ptr.*, .null);
                    continue;
                };
                try compareJson(diffs, ignored_paths, scenario_id, child_path, entry.value_ptr.*, actual_child);
            }
            var actual_iterator = actual.object.iterator();
            while (actual_iterator.next()) |entry| {
                if (expected_object.get(entry.key_ptr.*) == null) {
                    const child_path = try objectChildPath(diffs.allocator, path, entry.key_ptr.*);
                    defer diffs.allocator.free(child_path);
                    if (ignored_paths.shouldIgnore(child_path)) continue;
                    try diffs.add(scenario_id, child_path, .null, entry.value_ptr.*);
                }
            }
        },
    }
}

fn objectChildPath(allocator: std.mem.Allocator, path: []const u8, child: []const u8) ![]const u8 {
    if (path.len == 0) return try allocator.dupe(u8, child);
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, child });
}

fn arrayChildPath(allocator: std.mem.Allocator, path: []const u8, index: usize) ![]const u8 {
    if (path.len == 0) return try std.fmt.allocPrint(allocator, "[{d}]", .{index});
    return try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index });
}

fn renderBoundedJson(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    const rendered = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(rendered);
    if (rendered.len <= max_value_bytes) return try allocator.dupe(u8, rendered);
    const suffix = "...<truncated>";
    var output = try allocator.alloc(u8, max_value_bytes + suffix.len);
    @memcpy(output[0..max_value_bytes], rendered[0..max_value_bytes]);
    @memcpy(output[max_value_bytes..], suffix);
    return output;
}

fn runBoundedDiffSelfTest(allocator: std.mem.Allocator) !void {
    const long_expected = try allocator.alloc(u8, max_diff_output_bytes * 2);
    defer allocator.free(long_expected);
    @memset(long_expected, 'e');
    const long_actual = try allocator.alloc(u8, max_diff_output_bytes * 2);
    defer allocator.free(long_actual);
    @memset(long_actual, 'a');
    var diffs = DiffCollector.init(allocator);
    defer diffs.deinit();
    try diffs.add("bounded-diff-self-test", "request.jsonPayload.long", .{ .string = long_expected }, .{ .string = long_actual });
    if (diffs.buffer.items.len > max_diff_output_bytes) return error.UnboundedDiffOutput;
}

fn runIgnoredAllowlistSelfTest(allocator: std.mem.Allocator) !void {
    const expected_json =
        \\{
        \\  "id": "allowlisted-id",
        \\  "expected": {"typeScriptRequest": {}, "futureExpectedField": true},
        \\  "futureRootField": true
        \\}
    ;
    const actual_json =
        \\{
        \\  "expected": {"typeScriptRequest": {}},
        \\  "actualOnlyField": true
        \\}
    ;
    const expected = try std.json.parseFromSlice(std.json.Value, allocator, expected_json, .{});
    defer expected.deinit();
    const actual = try std.json.parseFromSlice(std.json.Value, allocator, actual_json, .{});
    defer actual.deinit();
    var ignored_paths = IgnoredPathTracker{};
    var diffs = DiffCollector.init(allocator);
    defer diffs.deinit();
    try compareJson(&diffs, &ignored_paths, "ignored-allowlist-self-test", "", expected.value, actual.value);
    if (diffs.count != 3) return error.UnallowlistedFixtureFieldWasNotRejected;
    if (!ignored_paths.wasIgnored("id")) return error.AllowlistedFixtureFieldWasNotIgnored;
    if (std.mem.indexOf(u8, diffs.buffer.items, "expected.futureExpectedField") == null) return error.UnallowlistedFixtureFieldPathNotReported;
    if (std.mem.indexOf(u8, diffs.buffer.items, "futureRootField") == null) return error.UnallowlistedFixtureFieldPathNotReported;
    if (std.mem.indexOf(u8, diffs.buffer.items, "actualOnlyField") == null) return error.UnallowlistedFixtureFieldPathNotReported;
}
