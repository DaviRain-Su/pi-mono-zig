const std = @import("std");

pub const SCHEMA_VERSION = "pi-extension.v1";
pub const RUNTIME_KIND = "native";
pub const ABI_NAME = "pi_native_extension_abi_v0";
pub const ABI_VERSION: u32 = 0;
pub const MAX_EXECUTE_INPUT_BYTES: usize = 64 * 1024;
pub const MAX_EXECUTE_OUTPUT_BYTES: usize = 64 * 1024;

pub const Metadata = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    description: []const u8,
    tool_name: []const u8,
    tool_description: []const u8,
    input_schema_json: []const u8,
    output_schema_json: []const u8,
};

pub const ExpectedManifest = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    runtime_descriptor: []const u8,
    tool_name: []const u8,
    timeout_ms: u64,
    output_bytes: u64,
};

pub fn staticMetadataJson(
    comptime id: []const u8,
    comptime name: []const u8,
    comptime version: []const u8,
    comptime description: []const u8,
    comptime tool_name: []const u8,
    comptime tool_description: []const u8,
    comptime input_schema_json: []const u8,
    comptime output_schema_json: []const u8,
) []const u8 {
    return "{\"schemaVersion\":\"" ++ SCHEMA_VERSION ++
        "\",\"runtime\":\"" ++ RUNTIME_KIND ++
        "\",\"abi\":{\"name\":\"" ++ ABI_NAME ++ "\",\"version\":0}" ++
        ",\"id\":\"" ++ id ++
        "\",\"name\":\"" ++ name ++
        "\",\"version\":\"" ++ version ++
        "\",\"description\":\"" ++ description ++
        "\",\"tool\":{\"name\":\"" ++ tool_name ++
        "\",\"description\":\"" ++ tool_description ++
        "\",\"inputSchema\":" ++ input_schema_json ++
        ",\"outputSchema\":" ++ output_schema_json ++ "}}";
}

pub fn ptr(bytes: []const u8) [*]const u8 {
    return bytes.ptr;
}

pub fn len(bytes: []const u8) usize {
    return bytes.len;
}

pub fn metadataJsonAlloc(allocator: std.mem.Allocator, metadata: Metadata) ![]u8 {
    try expectJsonObject(allocator, metadata.input_schema_json);
    try expectJsonObject(allocator, metadata.output_schema_json);
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"schemaVersion\":");
    try std.json.Stringify.value(SCHEMA_VERSION, .{}, &writer.writer);
    try writer.writer.writeAll(",\"runtime\":");
    try std.json.Stringify.value(RUNTIME_KIND, .{}, &writer.writer);
    try writer.writer.writeAll(",\"abi\":{\"name\":");
    try std.json.Stringify.value(ABI_NAME, .{}, &writer.writer);
    try writer.writer.print(",\"version\":{d}", .{ABI_VERSION});
    try writer.writer.writeAll("},\"id\":");
    try std.json.Stringify.value(metadata.id, .{}, &writer.writer);
    try writer.writer.writeAll(",\"name\":");
    try std.json.Stringify.value(metadata.name, .{}, &writer.writer);
    try writer.writer.writeAll(",\"version\":");
    try std.json.Stringify.value(metadata.version, .{}, &writer.writer);
    try writer.writer.writeAll(",\"description\":");
    try std.json.Stringify.value(metadata.description, .{}, &writer.writer);
    try writer.writer.writeAll(",\"tool\":{\"name\":");
    try std.json.Stringify.value(metadata.tool_name, .{}, &writer.writer);
    try writer.writer.writeAll(",\"description\":");
    try std.json.Stringify.value(metadata.tool_description, .{}, &writer.writer);
    try writer.writer.writeAll(",\"inputSchema\":");
    try writer.writer.writeAll(metadata.input_schema_json);
    try writer.writer.writeAll(",\"outputSchema\":");
    try writer.writer.writeAll(metadata.output_schema_json);
    try writer.writer.writeAll("}}");
    return allocator.dupe(u8, writer.written());
}

pub fn validateManifestTextAlloc(
    allocator: std.mem.Allocator,
    manifest_text: []const u8,
    expected: ExpectedManifest,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_text, .{}) catch {
        return invalidAlloc(allocator, "$", "manifest.invalid_json", "manifest must be valid JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return invalidAlloc(allocator, "$", "manifest.expected_object", "manifest must be a JSON object");
    const root = parsed.value.object;

    inline for (unsupported_product_fields) |field| {
        if (root.get(field) != null) {
            const path = try std.fmt.allocPrint(allocator, "$.{s}", .{field});
            defer allocator.free(path);
            return invalidAlloc(allocator, path, "manifest.unsupported_product_surface", "native SDK authoring is local/offline and does not support product, marketplace, signing, or remote surfaces");
        }
    }

    try expectStringValue(allocator, root, "schemaVersion", SCHEMA_VERSION);
    try expectStringValue(allocator, root, "id", expected.id);
    try expectStringValue(allocator, root, "name", expected.name);
    try expectStringValue(allocator, root, "version", expected.version);

    const runtime = root.get("runtime") orelse return invalidAlloc(allocator, "$.runtime", "manifest.missing_required_field", "missing required field");
    if (runtime != .object) return invalidAlloc(allocator, "$.runtime", "manifest.expected_object", "expected object");
    try expectStringValue(allocator, runtime.object, "kind", RUNTIME_KIND);
    const entrypoint = runtime.object.get("entrypoint") orelse return invalidAlloc(allocator, "$.runtime.entrypoint", "manifest.missing_required_field", "missing required field");
    if (entrypoint != .object) return invalidAlloc(allocator, "$.runtime.entrypoint", "manifest.expected_object", "expected object");
    inline for (unsupported_entrypoint_fields) |field| {
        if (entrypoint.object.get(field) != null) {
            const path = try std.fmt.allocPrint(allocator, "$.runtime.entrypoint.{s}", .{field});
            defer allocator.free(path);
            return invalidAlloc(allocator, path, "manifest.unsupported_native_entrypoint_field", "use the public native descriptor boundary, not direct loader/runtime internals");
        }
    }
    try expectNestedStringValue(allocator, entrypoint.object, "descriptor", expected.runtime_descriptor, "$.runtime.entrypoint.descriptor");

    const limits = runtime.object.get("limits") orelse return invalidAlloc(allocator, "$.runtime.limits", "manifest.missing_required_field", "missing required field");
    if (limits != .object) return invalidAlloc(allocator, "$.runtime.limits", "manifest.expected_object", "expected object");
    try expectU64Value(allocator, limits.object, "timeoutMs", expected.timeout_ms, "$.runtime.limits.timeoutMs");
    try expectU64Value(allocator, limits.object, "outputBytes", expected.output_bytes, "$.runtime.limits.outputBytes");
    const tool_scopes = limits.object.get("toolScopes") orelse return invalidAlloc(allocator, "$.runtime.limits.toolScopes", "manifest.missing_required_field", "missing required field");
    if (tool_scopes != .array) return invalidAlloc(allocator, "$.runtime.limits.toolScopes", "manifest.expected_array", "expected array");
    if (tool_scopes.array.items.len == 0 or tool_scopes.array.items[0] != .string or !std.mem.eql(u8, tool_scopes.array.items[0].string, expected.tool_name)) {
        return invalidAlloc(allocator, "$.runtime.limits.toolScopes[0]", "manifest.invalid_resource_limit", "first tool scope must match the template tool name");
    }

    const tools = root.get("tools") orelse return invalidAlloc(allocator, "$.tools", "manifest.missing_required_field", "missing required field");
    if (tools != .array) return invalidAlloc(allocator, "$.tools", "manifest.expected_array", "expected array");
    if (tools.array.items.len != 1) return invalidAlloc(allocator, "$.tools", "manifest.invalid_tool_count", "native template must declare exactly one public tool");
    const tool = tools.array.items[0];
    if (tool != .object) return invalidAlloc(allocator, "$.tools[0]", "manifest.expected_object", "expected object");
    try expectNestedStringValue(allocator, tool.object, "name", expected.tool_name, "$.tools[0].name");
    try expectObjectField(tool.object, "inputSchema", "$.tools[0].inputSchema", allocator);
    try expectObjectField(tool.object, "outputSchema", "$.tools[0].outputSchema", allocator);

    const capabilities = root.get("capabilities") orelse return invalidAlloc(allocator, "$.capabilities", "manifest.missing_required_field", "missing required field");
    if (capabilities != .object) return invalidAlloc(allocator, "$.capabilities", "manifest.expected_object", "expected object");
    const exports = capabilities.object.get("exports") orelse return invalidAlloc(allocator, "$.capabilities.exports", "manifest.missing_required_field", "missing required field");
    if (exports != .array or exports.array.items.len != 1 or exports.array.items[0] != .object) {
        return invalidAlloc(allocator, "$.capabilities.exports", "manifest.expected_array", "expected one capability export");
    }
    try expectNestedStringValue(allocator, exports.array.items[0].object, "id", expected.tool_name, "$.capabilities.exports[0].id");

    return validAlloc(allocator, expected);
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

pub fn executeMessageEchoAlloc(allocator: std.mem.Allocator, input_json: []const u8) ![]u8 {
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

fn validAlloc(allocator: std.mem.Allocator, expected: ExpectedManifest) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"ok\":true,\"schemaVersion\":");
    try std.json.Stringify.value(SCHEMA_VERSION, .{}, &writer.writer);
    try writer.writer.writeAll(",\"runtime\":");
    try std.json.Stringify.value(RUNTIME_KIND, .{}, &writer.writer);
    try writer.writer.writeAll(",\"abi\":");
    try std.json.Stringify.value(ABI_NAME, .{}, &writer.writer);
    try writer.writer.writeAll(",\"packageId\":");
    try std.json.Stringify.value(expected.id, .{}, &writer.writer);
    try writer.writer.writeAll(",\"toolName\":");
    try std.json.Stringify.value(expected.tool_name, .{}, &writer.writer);
    try writer.writer.writeAll("}");
    return allocator.dupe(u8, writer.written());
}

fn invalidAlloc(allocator: std.mem.Allocator, path: []const u8, code: []const u8, message: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"ok\":false,\"diagnostics\":[{\"severity\":\"error\",\"runtime\":\"native\",\"path\":");
    try std.json.Stringify.value(path, .{}, &writer.writer);
    try writer.writer.writeAll(",\"code\":");
    try std.json.Stringify.value(code, .{}, &writer.writer);
    try writer.writer.writeAll(",\"message\":");
    try std.json.Stringify.value(message, .{}, &writer.writer);
    try writer.writer.writeAll("}]}");
    return allocator.dupe(u8, writer.written());
}

fn expectStringValue(allocator: std.mem.Allocator, object: std.json.ObjectMap, field: []const u8, expected: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "$.{s}", .{field});
    defer allocator.free(path);
    try expectNestedStringValue(allocator, object, field, expected, path);
}

fn expectNestedStringValue(allocator: std.mem.Allocator, object: std.json.ObjectMap, field: []const u8, expected: []const u8, path: []const u8) !void {
    _ = allocator;
    _ = path;
    const value = object.get(field) orelse return error.InvalidAuthorManifest;
    if (value != .string or !std.mem.eql(u8, value.string, expected)) {
        return error.InvalidAuthorManifest;
    }
}

fn expectU64Value(allocator: std.mem.Allocator, object: std.json.ObjectMap, field: []const u8, expected: u64, path: []const u8) !void {
    _ = allocator;
    const value = object.get(field) orelse return invalidError(path);
    if (value != .integer or value.integer < 0 or @as(u64, @intCast(value.integer)) != expected) return invalidError(path);
}

fn expectObjectField(object: std.json.ObjectMap, field: []const u8, path: []const u8, allocator: std.mem.Allocator) !void {
    _ = allocator;
    const value = object.get(field) orelse return invalidError(path);
    if (value != .object) return invalidError(path);
}

fn invalidError(path: []const u8) error{InvalidAuthorManifest} {
    _ = path;
    return error.InvalidAuthorManifest;
}

fn expectJsonObject(allocator: std.mem.Allocator, json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJsonSchema;
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

const unsupported_entrypoint_fields = [_][]const u8{
    "library_path",
    "dynamic_library_path",
    "remote_url",
};

const unsupported_product_fields = [_][]const u8{
    "workflow",
    "workflowPreset",
    "wiki",
    "qa",
    "review",
    "webSimulator",
    "marketplace",
    "signing",
    "publisher",
    "remoteUrl",
    "remoteWasmUrl",
    "approvalUi",
};

test "native sdk facade serializes metadata and execute envelopes deterministically" {
    const allocator = std.testing.allocator;
    const metadata = try metadataJsonAlloc(allocator, .{
        .id = "com.example.native",
        .name = "Example Native",
        .version = "0.1.0",
        .description = "Native example.",
        .tool_name = "native.echo",
        .tool_description = "Echo.",
        .input_schema_json = "{\"type\":\"object\"}",
        .output_schema_json = "{\"type\":\"object\"}",
    });
    defer allocator.free(metadata);
    try std.testing.expectEqualStrings(
        "{\"schemaVersion\":\"pi-extension.v1\",\"runtime\":\"native\",\"abi\":{\"name\":\"pi_native_extension_abi_v0\",\"version\":0},\"id\":\"com.example.native\",\"name\":\"Example Native\",\"version\":\"0.1.0\",\"description\":\"Native example.\",\"tool\":{\"name\":\"native.echo\",\"description\":\"Echo.\",\"inputSchema\":{\"type\":\"object\"},\"outputSchema\":{\"type\":\"object\"}}}",
        metadata,
    );

    const success = try executeMessageEchoAlloc(allocator, "{\"message\":\"hello\"}");
    defer allocator.free(success);
    try std.testing.expectEqualStrings("{\"ok\":true,\"output\":{\"message\":\"hello\"}}", success);

    const invalid = try executeMessageEchoAlloc(allocator, "[]");
    defer allocator.free(invalid);
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input must be a JSON object with a string message field\"}}",
        invalid,
    );
}
