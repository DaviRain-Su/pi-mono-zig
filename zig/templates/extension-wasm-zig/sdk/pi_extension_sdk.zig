const std = @import("std");

pub const SCHEMA_VERSION = "pi-extension.v0";
pub const ARTIFACT_KIND = "wasm-component";
pub const RUNTIME_KIND = "wasm";
pub const MAX_EXECUTE_INPUT_BYTES: usize = 64 * 1024;
pub const MAX_EXECUTE_OUTPUT_BYTES: usize = 64 * 1024;

pub const Metadata = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    description: []const u8,
};

pub const Schema = struct {
    input_schema_json: []const u8,
    output_schema_json: []const u8,
};

pub const Phase = enum {
    metadata,
    schema,
    execute,
    diagnostics,

    pub fn jsonName(self: Phase) []const u8 {
        return switch (self) {
            .metadata => "metadata",
            .schema => "schema",
            .execute => "execute",
            .diagnostics => "diagnostics",
        };
    }
};

pub const Diagnostic = struct {
    severity: []const u8 = "error",
    extension_id: []const u8,
    tool_id: []const u8,
    phase: Phase,
    category: []const u8,
    message: []const u8,
    details: []const u8 = "",
};

pub fn staticMetadataJson(
    comptime id: []const u8,
    comptime name: []const u8,
    comptime version: []const u8,
    comptime description: []const u8,
) []const u8 {
    return "{\"id\":\"" ++ id ++ "\",\"name\":\"" ++ name ++ "\",\"version\":\"" ++ version ++ "\",\"description\":\"" ++ description ++ "\"}";
}

pub fn staticSchemaJson(
    comptime input_schema_json: []const u8,
    comptime output_schema_json: []const u8,
) []const u8 {
    return "{\"inputSchema\":" ++ input_schema_json ++ ",\"outputSchema\":" ++ output_schema_json ++ "}";
}

pub fn ptr(bytes: []const u8) i32 {
    return @intCast(@intFromPtr(bytes.ptr));
}

pub fn len(bytes: []const u8) i32 {
    return @intCast(bytes.len);
}

pub fn metadataJsonAlloc(allocator: std.mem.Allocator, metadata: Metadata) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"id\":");
    try std.json.Stringify.value(metadata.id, .{}, &writer.writer);
    try writer.writer.writeAll(",\"name\":");
    try std.json.Stringify.value(metadata.name, .{}, &writer.writer);
    try writer.writer.writeAll(",\"version\":");
    try std.json.Stringify.value(metadata.version, .{}, &writer.writer);
    try writer.writer.writeAll(",\"description\":");
    try std.json.Stringify.value(metadata.description, .{}, &writer.writer);
    try writer.writer.writeAll("}");
    return allocator.dupe(u8, writer.written());
}

pub fn schemaJsonAlloc(allocator: std.mem.Allocator, schema: Schema) ![]u8 {
    try expectJsonObject(allocator, schema.input_schema_json);
    try expectJsonObject(allocator, schema.output_schema_json);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"inputSchema\":");
    try writer.writer.writeAll(schema.input_schema_json);
    try writer.writer.writeAll(",\"outputSchema\":");
    try writer.writer.writeAll(schema.output_schema_json);
    try writer.writer.writeAll("}");
    return allocator.dupe(u8, writer.written());
}

pub fn successJsonAlloc(allocator: std.mem.Allocator, output_json: []const u8) ![]u8 {
    try expectJsonObject(allocator, output_json);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"ok\":true,\"output\":");
    try writer.writer.writeAll(output_json);
    try writer.writer.writeAll("}");
    return allocator.dupe(u8, writer.written());
}

pub fn errorJsonAlloc(allocator: std.mem.Allocator, category: []const u8, message: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"ok\":false,\"error\":{\"category\":");
    try std.json.Stringify.value(category, .{}, &writer.writer);
    try writer.writer.writeAll(",\"message\":");
    try std.json.Stringify.value(message, .{}, &writer.writer);
    try writer.writer.writeAll("}}");
    return allocator.dupe(u8, writer.written());
}

pub fn executeMessageEchoAlloc(allocator: std.mem.Allocator, input_json: []const u8, tool_id: []const u8) ![]u8 {
    _ = tool_id;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch {
        return errorJsonAlloc(allocator, "invalid_input", "execute input must be a JSON object with a string message field");
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return errorJsonAlloc(allocator, "invalid_input", "execute input must be a JSON object with a string message field");
    }
    const message_value = parsed.value.object.get("message") orelse {
        return errorJsonAlloc(allocator, "invalid_input", "execute input must be a JSON object with a string message field");
    };
    if (message_value != .string) {
        return errorJsonAlloc(allocator, "invalid_input", "execute input must be a JSON object with a string message field");
    }
    var output_writer: std.Io.Writer.Allocating = .init(allocator);
    defer output_writer.deinit();
    try output_writer.writer.writeAll("{\"message\":");
    try std.json.Stringify.value(message_value.string, .{}, &output_writer.writer);
    try output_writer.writer.writeAll("}");
    return successJsonAlloc(allocator, output_writer.written());
}

pub fn diagnosticJsonAlloc(allocator: std.mem.Allocator, diagnostic: Diagnostic) ![]u8 {
    const redacted_message = try redactSecretsAlloc(allocator, diagnostic.message);
    defer allocator.free(redacted_message);
    const redacted_details = try redactSecretsAlloc(allocator, diagnostic.details);
    defer allocator.free(redacted_details);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"runtime\":\"wasm\",\"severity\":");
    try std.json.Stringify.value(diagnostic.severity, .{}, &writer.writer);
    try writer.writer.writeAll(",\"extensionId\":");
    try std.json.Stringify.value(diagnostic.extension_id, .{}, &writer.writer);
    try writer.writer.writeAll(",\"toolId\":");
    try std.json.Stringify.value(diagnostic.tool_id, .{}, &writer.writer);
    try writer.writer.writeAll(",\"phase\":");
    try std.json.Stringify.value(diagnostic.phase.jsonName(), .{}, &writer.writer);
    try writer.writer.writeAll(",\"category\":");
    try std.json.Stringify.value(diagnostic.category, .{}, &writer.writer);
    try writer.writer.writeAll(",\"message\":");
    try std.json.Stringify.value(redacted_message, .{}, &writer.writer);
    try writer.writer.writeAll(",\"details\":");
    try std.json.Stringify.value(redacted_details, .{}, &writer.writer);
    try writer.writer.writeAll("}");
    return allocator.dupe(u8, writer.written());
}

pub fn unsupportedHostApiDiagnosticAlloc(
    allocator: std.mem.Allocator,
    extension_id: []const u8,
    tool_id: []const u8,
    api_name: []const u8,
) ![]u8 {
    var message_writer: std.Io.Writer.Allocating = .init(allocator);
    defer message_writer.deinit();
    try message_writer.writer.writeAll("unsupported host API denied: ");
    try message_writer.writer.writeAll(api_name);
    return diagnosticJsonAlloc(allocator, .{
        .extension_id = extension_id,
        .tool_id = tool_id,
        .phase = .execute,
        .category = "unsupported_host_api",
        .message = message_writer.written(),
    });
}

pub fn executeMessageEcho(output_buffer: []u8, input_json: []const u8) []const u8 {
    if (input_json.len > MAX_EXECUTE_INPUT_BYTES) {
        return writeError(output_buffer, "invalid_input", "execute input exceeds maximum size");
    }
    const message = findStringField(input_json, "message") orelse {
        return writeError(output_buffer, "invalid_input", "execute input must be a JSON object with a string message field");
    };
    var writer = FixedJsonWriter.init(output_buffer);
    writer.append("{\"ok\":true,\"output\":{\"message\":\"") catch return writeError(output_buffer, "output_overflow", "execute output exceeded buffer");
    writer.appendEscaped(message) catch return writeError(output_buffer, "output_overflow", "execute output exceeded buffer");
    writer.append("\"}}") catch return writeError(output_buffer, "output_overflow", "execute output exceeded buffer");
    return writer.written();
}

fn writeError(output_buffer: []u8, category: []const u8, message: []const u8) []const u8 {
    var writer = FixedJsonWriter.init(output_buffer);
    writer.append("{\"ok\":false,\"error\":{\"category\":\"") catch return fallbackStaticError(output_buffer);
    writer.appendEscaped(category) catch return fallbackStaticError(output_buffer);
    writer.append("\",\"message\":\"") catch return fallbackStaticError(output_buffer);
    writer.appendEscaped(message) catch return fallbackStaticError(output_buffer);
    writer.append("\"}}") catch return fallbackStaticError(output_buffer);
    return writer.written();
}

fn fallbackStaticError(output_buffer: []u8) []const u8 {
    const fallback = "{\"ok\":false,\"error\":{\"category\":\"output_overflow\",\"message\":\"execute output exceeded buffer\"}}";
    const len_to_copy = @min(output_buffer.len, fallback.len);
    @memcpy(output_buffer[0..len_to_copy], fallback[0..len_to_copy]);
    return output_buffer[0..len_to_copy];
}

fn findStringField(input_json: []const u8, field: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, input_json, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return null;
    var index: usize = 1;
    while (index < trimmed.len - 1) {
        while (index < trimmed.len and isJsonWhitespace(trimmed[index])) index += 1;
        if (index >= trimmed.len or trimmed[index] == '}') break;
        if (trimmed[index] != '"') return null;
        const key_start = index + 1;
        const key_end = std.mem.indexOfScalarPos(u8, trimmed, key_start, '"') orelse return null;
        const key = trimmed[key_start..key_end];
        index = key_end + 1;
        while (index < trimmed.len and isJsonWhitespace(trimmed[index])) index += 1;
        if (index >= trimmed.len or trimmed[index] != ':') return null;
        index += 1;
        while (index < trimmed.len and isJsonWhitespace(trimmed[index])) index += 1;
        if (index >= trimmed.len) return null;
        if (std.mem.eql(u8, key, field)) {
            if (trimmed[index] != '"') return null;
            return parseSimpleJsonString(trimmed, index);
        }
        index = skipJsonValue(trimmed, index) orelse return null;
        while (index < trimmed.len and isJsonWhitespace(trimmed[index])) index += 1;
        if (index < trimmed.len and trimmed[index] == ',') index += 1;
    }
    return null;
}

fn parseSimpleJsonString(bytes: []const u8, quote_index: usize) ?[]const u8 {
    var index = quote_index + 1;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index] == '\\') return null;
        if (bytes[index] == '"') return bytes[quote_index + 1 .. index];
    }
    return null;
}

fn skipJsonValue(bytes: []const u8, start: usize) ?usize {
    if (start >= bytes.len) return null;
    if (bytes[start] == '"') {
        return (std.mem.indexOfScalarPos(u8, bytes, start + 1, '"') orelse return null) + 1;
    }
    var index = start;
    while (index < bytes.len and bytes[index] != ',' and bytes[index] != '}') index += 1;
    return index;
}

fn isJsonWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn expectJsonObject(allocator: std.mem.Allocator, json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJsonSchema;
}

fn redactSecretsAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var index: usize = 0;
    while (index < text.len) {
        if (sensitiveQueryParamPrefixLen(text[index..])) |prefix_len| {
            try writer.writer.writeAll(text[index .. index + prefix_len]);
            try writer.writer.writeAll("[REDACTED]");
            index = skipSecretValue(text, index + prefix_len, .query);
            continue;
        }
        if (startsWithIgnoreCase(text[index..], "Bearer ")) {
            try writer.writer.writeAll(text[index .. index + "Bearer ".len]);
            try writer.writer.writeAll("[REDACTED]");
            index = skipSecretValue(text, index + "Bearer ".len, .token);
            continue;
        }
        if (sensitiveHeaderPrefixLen(text[index..])) |prefix_len| {
            try writer.writer.writeAll(text[index .. index + prefix_len]);
            try writer.writer.writeAll("[REDACTED]");
            index = skipSecretValue(text, index + prefix_len, .header);
            continue;
        }
        if (std.mem.startsWith(u8, text[index..], "sk-")) {
            try writer.writer.writeAll("[REDACTED]");
            index += 3;
            while (index < text.len and isSecretChar(text[index])) index += 1;
            continue;
        }
        try writer.writer.writeByte(text[index]);
        index += 1;
    }
    return allocator.dupe(u8, writer.written());
}

const SecretValueMode = enum {
    token,
    query,
    header,
};

fn sensitiveQueryParamPrefixLen(text: []const u8) ?usize {
    const keys = [_][]const u8{
        "api_key=",
        "apikey=",
        "access_token=",
        "refresh_token=",
        "token=",
        "key=",
        "session_token=",
    };
    for (keys) |key| {
        if (startsWithIgnoreCase(text, key)) return key.len;
    }
    return null;
}

fn sensitiveHeaderPrefixLen(text: []const u8) ?usize {
    const headers = [_][]const u8{
        "x-api-key",
        "api-key",
        "authorization",
        "x-amz-security-token",
        "cookie",
        "set-cookie",
    };
    for (headers) |header| {
        if (!startsWithIgnoreCase(text, header)) continue;
        var index: usize = header.len;
        while (index < text.len and text[index] == ' ') index += 1;
        if (index >= text.len or text[index] != ':') continue;
        index += 1;
        while (index < text.len and text[index] == ' ') index += 1;
        if (std.ascii.eqlIgnoreCase(header, "authorization") and startsWithIgnoreCase(text[index..], "Bearer ")) {
            return null;
        }
        return index;
    }
    return null;
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn skipSecretValue(text: []const u8, start: usize, mode: SecretValueMode) usize {
    var index = start;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        switch (mode) {
            .query => {
                if (byte == '&' or byte == '#' or isSecretBoundary(byte)) return index;
            },
            .token => {
                if (isSecretBoundary(byte) or byte == '&' or byte == '?' or byte == '#') return index;
            },
            .header => {
                if (byte == '\n' or byte == '\r') return index;
            },
        }
    }
    return index;
}

fn isSecretBoundary(byte: u8) bool {
    return byte == ' ' or
        byte == '\t' or
        byte == '"' or
        byte == '\'' or
        byte == '<' or
        byte == '>' or
        byte == ')' or
        byte == ']' or
        byte == '}' or
        byte == ',';
}

fn isSecretChar(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9') or
        byte == '-' or
        byte == '_';
}

const FixedJsonWriter = struct {
    buffer: []u8,
    index: usize = 0,

    fn init(buffer: []u8) FixedJsonWriter {
        return .{ .buffer = buffer };
    }

    fn append(self: *FixedJsonWriter, bytes: []const u8) !void {
        if (bytes.len > self.buffer.len - self.index) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.index .. self.index + bytes.len], bytes);
        self.index += bytes.len;
    }

    fn appendEscaped(self: *FixedJsonWriter, bytes: []const u8) !void {
        for (bytes) |byte| {
            switch (byte) {
                '"' => try self.append("\\\""),
                '\\' => try self.append("\\\\"),
                '\n' => try self.append("\\n"),
                '\r' => try self.append("\\r"),
                '\t' => try self.append("\\t"),
                else => try self.append(&.{byte}),
            }
        }
    }

    fn written(self: *const FixedJsonWriter) []const u8 {
        return self.buffer[0..self.index];
    }
};
