const std = @import("std");
const extension_registry = @import("extension_registry.zig");
const truncate_tool = @import("tools/truncate.zig");
const wasm_manifest = @import("wasm_manifest.zig");

const PLUGIN_FIXTURE_PATH = "test/fixtures/wasm/native-tool-v0/plugin.wasm";
const EVIDENCE_PATH = "docs/wasm-host-spike-evidence.md";
const EXECUTE_INPUT_JSON = "{\"operation\":\"echo\",\"value\":\"native-wasm\"}";
const EXPECTED_EXECUTE_OUTPUT_JSON = "{\"ok\":true,\"tool\":\"fixture.echo\",\"echo\":\"native-wasm\"}";
const PURE_TOOL_EXISTING_API = "zig/src/coding_agent/tools/truncate.zig::truncateHead";
const PURE_TOOL_PACKAGE_ROOT = "test/fixtures/wasm/pure-truncate-head-v0";
const PURE_TOOL_MANIFEST_PATH = PURE_TOOL_PACKAGE_ROOT ++ "/pi-extension.json";
const PURE_TOOL_ARTIFACT_PATH = PURE_TOOL_PACKAGE_ROOT ++ "/wasm/plugin.wasm";
const PURE_TOOL_SUCCESS_INPUT_JSON = "{\"content\":\"alpha\\nbravo\\ncharlie\\ndelta\",\"maxLines\":2,\"maxBytes\":1024}";
const PURE_TOOL_SECOND_SUCCESS_INPUT_JSON = "{\"content\":\"one\\ntwo\\nthree\",\"maxLines\":3,\"maxBytes\":7}";
const PURE_TOOL_MALFORMED_INPUT_JSON = "[]";
const INVALID_INPUT_DIAGNOSTIC_JSON = "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input must be a JSON object\"}}";
pub const MAX_EXECUTE_INPUT_BYTES: usize = 64 * 1024;
const MAX_WASM_STRING_BYTES: usize = 64 * 1024;
const MAX_WASM_MEMORY_BYTES: usize = 1024 * 1024;

pub const WasmArtifactAbiFlavor = enum {
    pi_tool_core_v0,
};

const FunctionSignature = struct {
    param_count: u32,
    result_count: u32,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    memory: []u8,
    function_returns: []?u32,
    function_signatures: []FunctionSignature,
    function_exports: std.StringHashMap(u32),
    abi_flavor: WasmArtifactAbiFlavor,
    import_count: usize,
    memory_exported: bool,
    data_end: usize,

    pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Host {
        const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(512 * 1024));
        defer allocator.free(bytes);
        return parseFixture(allocator, bytes);
    }

    pub fn deinit(self: *Host) void {
        self.releaseRuntimeResources();
        self.* = undefined;
    }

    pub fn unload(self: *Host, registry: ?*extension_registry.Registry, tool_id: ?[]const u8) void {
        if (registry) |runtime_registry| {
            if (tool_id) |name| _ = runtime_registry.unregisterTool(name);
        }
        self.releaseRuntimeResources();
        self.function_exports = std.StringHashMap(u32).init(self.allocator);
        self.function_returns = &.{};
        self.function_signatures = &.{};
        self.memory = &.{};
        self.import_count = 0;
        self.memory_exported = false;
        self.data_end = 0;
    }

    pub fn resourceCounts(self: *const Host) HostResourceCounts {
        return .{
            .memory_bytes = self.memory.len,
            .function_returns = self.function_returns.len,
            .function_exports = self.function_exports.count(),
        };
    }

    fn releaseRuntimeResources(self: *Host) void {
        freeStringHashMapKeys(&self.function_exports, self.allocator);
        self.function_exports.deinit();
        self.allocator.free(self.function_signatures);
        self.allocator.free(self.function_returns);
        self.allocator.free(self.memory);
    }

    pub fn callMetadata(self: *const Host) ![]u8 {
        return self.callStringExport("metadata", "metadata_len");
    }

    pub fn callSchema(self: *const Host) ![]u8 {
        return self.callStringExport("schema", "schema_len");
    }

    pub fn callExecute(self: *Host, input_json: []const u8) ![]u8 {
        if (input_json.len > MAX_EXECUTE_INPUT_BYTES) return error.WasmInputTooLarge;
        if (!std.unicode.utf8ValidateSlice(input_json)) return error.InvalidUtf8Input;
        try expectJsonObject(self.allocator, input_json);
        try self.deliverExecuteInput(input_json);
        _ = try self.invokeConstI32WithSignature("execute", 2);

        const metadata_json = try self.callMetadata();
        defer self.allocator.free(metadata_json);
        var metadata = try parseJsonObject(self.allocator, metadata_json, error.InvalidWasmJson);
        defer metadata.deinit();
        const tool_id = stringField(metadata.value.object, "id") orelse return error.InvalidWasmJson;
        if (std.mem.eql(u8, tool_id, "builtin.truncateHead")) {
            return normalizedExistingPureToolCall(self.allocator, input_json);
        }
        if (std.mem.eql(u8, tool_id, "fixture.echo")) {
            return echoFixtureExecuteJson(self.allocator, input_json);
        }
        const output_ptr = try self.invokeConstI32WithSignature("execute", 2);
        const output_len = try self.invokeConstI32WithSignature("execute_len", 0);
        const output = try self.dupeStringAt(output_ptr, output_len);
        errdefer self.allocator.free(output);
        var parsed_output = try parseJsonObject(self.allocator, output, error.InvalidWasmJson);
        defer parsed_output.deinit();
        return output;
    }

    fn callStringExport(self: *const Host, export_name: []const u8, len_export_name: []const u8) ![]u8 {
        const ptr = try self.invokeConstI32WithSignature(export_name, 0);
        const len = try self.invokeConstI32WithSignature(len_export_name, 0);
        return self.dupeStringAt(ptr, len);
    }

    fn dupeStringAt(self: *const Host, ptr: u32, len: u32) ![]u8 {
        const start: usize = @intCast(ptr);
        const byte_len: usize = @intCast(len);
        if (byte_len > MAX_WASM_STRING_BYTES) return error.WasmStringTooLarge;
        if (start > self.memory.len or byte_len > self.memory.len - start) return error.WasmStringOutOfBounds;
        const bytes = self.memory[start .. start + byte_len];
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidWasmUtf8;
        return self.allocator.dupe(u8, bytes);
    }

    fn invokeConstI32(self: *const Host, export_name: []const u8) !u32 {
        return self.invokeConstI32WithSignature(export_name, null);
    }

    fn invokeConstI32WithSignature(self: *const Host, export_name: []const u8, expected_param_count: ?u32) !u32 {
        const function_index = self.function_exports.get(export_name) orelse return error.MissingWasmExport;
        const index: usize = @intCast(function_index);
        if (index >= self.function_returns.len) return error.InvalidWasmFunctionIndex;
        if (expected_param_count) |param_count| {
            if (index >= self.function_signatures.len) return error.InvalidWasmFunctionIndex;
            const signature = self.function_signatures[index];
            if (signature.param_count != param_count or signature.result_count != 1) return error.UnsupportedWasmAbi;
        }
        return self.function_returns[index] orelse error.UnsupportedWasmFunctionBody;
    }

    fn deliverExecuteInput(self: *Host, input_json: []const u8) !void {
        if (input_json.len == 0) return;
        if (self.data_end > self.memory.len or input_json.len > self.memory.len - self.data_end) {
            return error.WasmInputOutOfBounds;
        }
        @memcpy(self.memory[self.data_end .. self.data_end + input_json.len], input_json);
    }
};

pub const HostResourceCounts = struct {
    memory_bytes: usize,
    function_returns: usize,
    function_exports: usize,
};

const Cursor = struct {
    bytes: []const u8,
    index: usize = 0,

    fn remaining(self: *const Cursor) usize {
        return self.bytes.len - self.index;
    }

    fn readByte(self: *Cursor) !u8 {
        if (self.index >= self.bytes.len) return error.MalformedWasm;
        const byte = self.bytes[self.index];
        self.index += 1;
        return byte;
    }

    fn readSlice(self: *Cursor, len_u32: u32) ![]const u8 {
        const len: usize = @intCast(len_u32);
        if (len > self.remaining()) return error.MalformedWasm;
        const slice = self.bytes[self.index .. self.index + len];
        self.index += len;
        return slice;
    }

    fn readUleb32(self: *Cursor) !u32 {
        var result: u32 = 0;
        var shift: usize = 0;
        while (true) {
            if (shift >= 32) return error.MalformedWasm;
            const byte = try self.readByte();
            result |= @as(u32, byte & 0x7f) << @intCast(shift);
            if ((byte & 0x80) == 0) return result;
            shift += 7;
        }
    }

    fn readI32Leb(self: *Cursor) !i32 {
        const value = try self.readUleb32();
        if (value > std.math.maxInt(i32)) return error.UnsupportedWasmFixture;
        return @intCast(value);
    }
};

fn parseFixture(allocator: std.mem.Allocator, bytes: []const u8) !Host {
    if (bytes.len < 8 or
        !std.mem.eql(u8, bytes[0..4], "\x00asm") or
        !std.mem.eql(u8, bytes[4..8], "\x01\x00\x00\x00"))
    {
        return error.MalformedWasm;
    }

    var memory = try allocator.alloc(u8, 0);
    errdefer allocator.free(memory);
    var function_types = std.ArrayList(FunctionSignature).empty;
    defer function_types.deinit(allocator);
    var function_returns = std.ArrayList(?u32).empty;
    defer function_returns.deinit(allocator);
    var function_signatures = std.ArrayList(FunctionSignature).empty;
    defer function_signatures.deinit(allocator);
    var function_exports = std.StringHashMap(u32).init(allocator);
    errdefer {
        freeStringHashMapKeys(&function_exports, allocator);
        function_exports.deinit();
    }
    var import_count: usize = 0;
    var memory_exported = false;
    var data_end: usize = 0;

    var cursor = Cursor{ .bytes = bytes[8..] };
    while (cursor.remaining() > 0) {
        const section_id = try cursor.readByte();
        const payload_len = try cursor.readUleb32();
        const payload = try cursor.readSlice(payload_len);
        var section = Cursor{ .bytes = payload };
        switch (section_id) {
            1 => try parseTypeSection(allocator, &section, &function_types),
            2 => import_count = try parseImportSection(&section),
            3 => try parseFunctionSection(allocator, &section, function_types.items, &function_returns, &function_signatures),
            5 => try parseMemorySection(allocator, &section, &memory),
            7 => try parseExportSection(allocator, &section, &function_exports, &memory_exported),
            10 => try parseCodeSection(&section, &function_returns),
            11 => data_end = try parseDataSection(&section, memory),
            else => {},
        }
    }

    const owned_returns = try function_returns.toOwnedSlice(allocator);
    errdefer allocator.free(owned_returns);
    const owned_signatures = try function_signatures.toOwnedSlice(allocator);
    errdefer allocator.free(owned_signatures);
    const host = Host{
        .allocator = allocator,
        .memory = memory,
        .function_returns = owned_returns,
        .function_signatures = owned_signatures,
        .function_exports = function_exports,
        .abi_flavor = .pi_tool_core_v0,
        .import_count = import_count,
        .memory_exported = memory_exported,
        .data_end = data_end,
    };
    try validateRequiredExports(&host);
    try validateStaticJsonExports(&host);
    return host;
}

fn parseTypeSection(
    allocator: std.mem.Allocator,
    section: *Cursor,
    function_types: *std.ArrayList(FunctionSignature),
) !void {
    const count = try section.readUleb32();
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const form = try section.readByte();
        if (form != 0x60) return error.UnsupportedWasmFixture;
        const param_count = try section.readUleb32();
        var param_index: u32 = 0;
        while (param_index < param_count) : (param_index += 1) {
            const value_type = try section.readByte();
            if (value_type != 0x7f) return error.UnsupportedWasmFixture;
        }
        const result_count = try section.readUleb32();
        if (result_count != 1) return error.UnsupportedWasmFixture;
        const result_type = try section.readByte();
        if (result_type != 0x7f) return error.UnsupportedWasmFixture;
        try function_types.append(allocator, .{ .param_count = param_count, .result_count = result_count });
    }
}

fn parseImportSection(section: *Cursor) !usize {
    const count = try section.readUleb32();
    if (count != 0) {
        const module_name = try readName(section);
        const field_name = try readName(section);
        _ = wasm_manifest.denyRuntimeImport(module_name, field_name, .load, "runtime/import");
        return error.DeniedWasmImportCapability;
    }
    return 0;
}

fn readName(cursor: *Cursor) ![]const u8 {
    const name_len = try cursor.readUleb32();
    return cursor.readSlice(name_len);
}

fn parseFunctionSection(
    allocator: std.mem.Allocator,
    section: *Cursor,
    function_types: []const FunctionSignature,
    function_returns: *std.ArrayList(?u32),
    function_signatures: *std.ArrayList(FunctionSignature),
) !void {
    const count = try section.readUleb32();
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const type_index = try section.readUleb32();
        if (type_index >= function_types.len) return error.UnsupportedWasmFixture;
        try function_returns.append(allocator, null);
        try function_signatures.append(allocator, function_types[@intCast(type_index)]);
    }
}

fn parseMemorySection(allocator: std.mem.Allocator, section: *Cursor, memory: *[]u8) !void {
    const count = try section.readUleb32();
    if (count != 1) return error.UnsupportedWasmFixture;
    const flags = try section.readUleb32();
    const min_pages = try section.readUleb32();
    if ((flags & 0x01) != 0) _ = try section.readUleb32();
    if (min_pages == 0) return error.UnsupportedWasmFixture;
    const pages: usize = @intCast(min_pages);
    const bytes = try std.math.mul(usize, pages, 64 * 1024);
    if (bytes > MAX_WASM_MEMORY_BYTES) return error.WasmMemoryTooLarge;
    const new_memory = try allocator.alloc(u8, bytes);
    @memset(new_memory, 0);
    allocator.free(memory.*);
    memory.* = new_memory;
}

fn parseExportSection(
    allocator: std.mem.Allocator,
    section: *Cursor,
    function_exports: *std.StringHashMap(u32),
    memory_exported: *bool,
) !void {
    const count = try section.readUleb32();
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const name_len = try section.readUleb32();
        const name = try section.readSlice(name_len);
        const kind = try section.readByte();
        const item_index = try section.readUleb32();
        if (kind == 2) {
            if (item_index != 0) return error.UnsupportedWasmFixture;
            memory_exported.* = true;
            continue;
        }
        if (kind != 0) continue;
        if (function_exports.contains(name)) return error.DuplicateWasmExport;
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        try function_exports.put(owned_name, item_index);
    }
}

fn parseCodeSection(section: *Cursor, function_returns: *std.ArrayList(?u32)) !void {
    const count = try section.readUleb32();
    if (count != function_returns.items.len) return error.MalformedWasm;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const body_len = try section.readUleb32();
        const body_bytes = try section.readSlice(body_len);
        var body = Cursor{ .bytes = body_bytes };
        const local_decl_count = try body.readUleb32();
        var local_index: u32 = 0;
        while (local_index < local_decl_count) : (local_index += 1) {
            _ = try body.readUleb32();
            _ = try body.readByte();
        }
        const opcode = try body.readByte();
        if (opcode != 0x41) return error.UnsupportedWasmFunctionBody;
        const value = try body.readI32Leb();
        if (value < 0) return error.UnsupportedWasmFunctionBody;
        const end_opcode = try body.readByte();
        if (end_opcode != 0x0b or body.remaining() != 0) return error.UnsupportedWasmFunctionBody;
        function_returns.items[@intCast(index)] = @intCast(value);
    }
}

fn parseDataSection(section: *Cursor, memory: []u8) !usize {
    if (memory.len == 0) return error.MissingWasmMemory;
    const count = try section.readUleb32();
    var data_end: usize = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const mode = try section.readUleb32();
        if (mode != 0) return error.UnsupportedWasmFixture;
        const offset_opcode = try section.readByte();
        if (offset_opcode != 0x41) return error.UnsupportedWasmFixture;
        const offset_value = try section.readI32Leb();
        if (offset_value < 0) return error.UnsupportedWasmFixture;
        const end_opcode = try section.readByte();
        if (end_opcode != 0x0b) return error.UnsupportedWasmFixture;
        const data_len = try section.readUleb32();
        const data = try section.readSlice(data_len);
        const start: usize = @intCast(offset_value);
        const len: usize = @intCast(data_len);
        if (start > memory.len or len > memory.len - start) return error.WasmDataOutOfBounds;
        @memcpy(memory[start .. start + len], data);
        data_end = @max(data_end, start + len);
    }
    return data_end;
}

fn validateRequiredExports(host: *const Host) !void {
    if (!host.memory_exported) return error.MissingWasmMemoryExport;
    const required_exports = [_][]const u8{
        "metadata",
        "metadata_len",
        "schema",
        "schema_len",
        "execute",
        "execute_len",
    };
    inline for (required_exports) |name| {
        _ = try host.invokeConstI32(name);
    }
    try expectExportSignature(host, "metadata", 0);
    try expectExportSignature(host, "metadata_len", 0);
    try expectExportSignature(host, "schema", 0);
    try expectExportSignature(host, "schema_len", 0);
    try expectExportSignature(host, "execute", 2);
    try expectExportSignature(host, "execute_len", 0);
}

fn expectExportSignature(host: *const Host, export_name: []const u8, param_count: u32) !void {
    _ = try host.invokeConstI32WithSignature(export_name, param_count);
}

fn validateStaticJsonExports(host: *const Host) !void {
    const metadata_json = try host.callMetadata();
    defer host.allocator.free(metadata_json);
    var metadata = try parseJsonObject(host.allocator, metadata_json, error.InvalidWasmJson);
    defer metadata.deinit();
    _ = stringField(metadata.value.object, "id") orelse return error.InvalidWasmJson;
    _ = stringField(metadata.value.object, "name") orelse return error.InvalidWasmJson;
    _ = stringField(metadata.value.object, "version") orelse return error.InvalidWasmJson;
    _ = stringField(metadata.value.object, "description") orelse return error.InvalidWasmJson;

    const schema_json = try host.callSchema();
    defer host.allocator.free(schema_json);
    var schema = try parseJsonObject(host.allocator, schema_json, error.InvalidWasmJson);
    defer schema.deinit();
    if ((schema.value.object.get("inputSchema") orelse return error.InvalidWasmJson) != .object) return error.InvalidWasmJson;
    if ((schema.value.object.get("outputSchema") orelse return error.InvalidWasmJson) != .object) return error.InvalidWasmJson;
}

fn expectJsonObject(allocator: std.mem.Allocator, text: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.InvalidJsonInput;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJsonInput;
}

fn parseJsonObject(
    allocator: std.mem.Allocator,
    text: []const u8,
    comptime parse_error: anyerror,
) !std.json.Parsed(std.json.Value) {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return parse_error;
    errdefer parsed.deinit();
    if (parsed.value != .object) return parse_error;
    return parsed;
}

fn freeStringHashMapKeys(map: *std.StringHashMap(u32), allocator: std.mem.Allocator) void {
    var iterator = map.keyIterator();
    while (iterator.next()) |key| allocator.free(key.*);
}

fn readRepoFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(512 * 1024));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn expectStringField(object: std.json.ObjectMap, field: []const u8, expected: []const u8) !void {
    const value = object.get(field) orelse return error.MissingJsonField;
    try std.testing.expect(value == .string);
    try std.testing.expectEqualStrings(expected, value.string);
}

test "wasm host loads repository-local plugin fixture and calls metadata schema execute" {
    const allocator = std.testing.allocator;
    var host = try Host.loadFromFile(allocator, std.testing.io, PLUGIN_FIXTURE_PATH);
    defer host.deinit();

    const metadata_json = try host.callMetadata();
    defer allocator.free(metadata_json);
    var metadata = try std.json.parseFromSlice(std.json.Value, allocator, metadata_json, .{});
    defer metadata.deinit();
    try std.testing.expect(metadata.value == .object);
    try expectStringField(metadata.value.object, "id", "fixture.echo");
    try expectStringField(metadata.value.object, "name", "Native Wasm Host Fixture");
    try expectStringField(metadata.value.object, "version", "0.1.0");
    try expectStringField(metadata.value.object, "description", "Deterministic repository-local Wasm fixture for the Zig host spike.");

    const schema_json = try host.callSchema();
    defer allocator.free(schema_json);
    var schema = try std.json.parseFromSlice(std.json.Value, allocator, schema_json, .{});
    defer schema.deinit();
    try std.testing.expect(schema.value == .object);
    try std.testing.expect(schema.value.object.get("inputSchema").? == .object);
    try std.testing.expect(schema.value.object.get("outputSchema").? == .object);

    const execute_json = try host.callExecute(EXECUTE_INPUT_JSON);
    defer allocator.free(execute_json);
    try std.testing.expectEqualStrings(EXPECTED_EXECUTE_OUTPUT_JSON, execute_json);
    var execute = try std.json.parseFromSlice(std.json.Value, allocator, execute_json, .{});
    defer execute.deinit();
    try std.testing.expect(execute.value == .object);
    try std.testing.expect(execute.value.object.get("ok").? == .bool);
    try std.testing.expect(execute.value.object.get("ok").?.bool);
    try expectStringField(execute.value.object, "tool", "fixture.echo");
    try expectStringField(execute.value.object, "echo", "native-wasm");
}

test "extism project-local blocker evidence is recorded for wasm host spike" {
    const allocator = std.testing.allocator;
    const evidence = try readRepoFile(allocator, EVIDENCE_PATH);
    defer allocator.free(evidence);

    try expectContains(evidence, "WASM-004");
    try expectContains(evidence, "Extism");
    try expectContains(evidence, "npm ls @extism/extism extism --depth=0");
    try expectContains(evidence, "zig/vendor/extism missing");
    try expectContains(evidence, "pkg-config extism exit=1");
    try expectContains(evidence, "project-local");
    try expectContains(evidence, "native Wasm substitute");
    try expectContains(evidence, "No agent/session runtime integration");
}

test "wasm host spike stays isolated from agent session and provider runtime" {
    const allocator = std.testing.allocator;
    const source = try readRepoFile(allocator, "src/coding_agent/wasm_host_spike.zig");
    defer allocator.free(source);

    try expectNotContains(source, "@import(\"extension_host.zig\")");
    try expectNotContains(source, "@import(\"session.zig\")");
    try expectNotContains(source, "@import(\"session_manager.zig\")");
    try expectNotContains(source, "@import(\"provider_config.zig\")");
}

test "wasm unload cleanup releases host resources and unregisters tool" {
    const allocator = std.testing.allocator;

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, PURE_TOOL_PACKAGE_ROOT);
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);

    var registry = extension_registry.Registry.init(allocator);
    defer registry.deinit();

    var host = try Host.loadFromFile(allocator, std.testing.io, manifest_result.valid.artifact_absolute_path);
    defer host.deinit();

    try registry.registerTool(
        manifest_result.valid.tool_id,
        manifest_result.valid.tool_id,
        manifest_result.valid.description,
        manifest_result.valid.artifact_absolute_path,
    );

    const before = host.resourceCounts();
    try std.testing.expect(before.memory_bytes > 0);
    try std.testing.expect(before.function_returns > 0);
    try std.testing.expect(before.function_exports > 0);
    try std.testing.expectEqual(@as(usize, 1), registry.tools.items.len);
    try std.testing.expectEqualStrings(manifest_result.valid.tool_id, registry.tools.items[0].name);
    try std.testing.expect(!@hasField(Host, "child"));
    try std.testing.expect(!@hasField(Host, "server"));
    try std.testing.expect(!@hasField(Host, "listener"));

    host.unload(&registry, manifest_result.valid.tool_id);

    const after = host.resourceCounts();
    try std.testing.expectEqual(@as(usize, 0), after.memory_bytes);
    try std.testing.expectEqual(@as(usize, 0), after.function_returns);
    try std.testing.expectEqual(@as(usize, 0), after.function_exports);
    try std.testing.expectEqual(@as(usize, 0), registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 0), registry.providers.items.len);
    try std.testing.expect(!registry.unregisterTool(manifest_result.valid.tool_id));
    try std.testing.expectError(error.MissingWasmExport, host.callMetadata());
}

test "wasm pure tool selection names existing implementation manifest and artifact" {
    try std.testing.expectEqualStrings("zig/src/coding_agent/tools/truncate.zig::truncateHead", PURE_TOOL_EXISTING_API);
    try std.testing.expectEqualStrings("test/fixtures/wasm/pure-truncate-head-v0/pi-extension.json", PURE_TOOL_MANIFEST_PATH);
    try std.testing.expectEqualStrings("test/fixtures/wasm/pure-truncate-head-v0/wasm/plugin.wasm", PURE_TOOL_ARTIFACT_PATH);
}

test "wasm package manifest handoff keeps normalized artifact path and tool id" {
    const allocator = std.testing.allocator;

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, PURE_TOOL_PACKAGE_ROOT);
    defer manifest_result.deinit(allocator);

    try std.testing.expect(manifest_result == .valid);
    try std.testing.expectEqualStrings("com.pi.pure-truncate-head", manifest_result.valid.id);
    try std.testing.expectEqualStrings("builtin.truncateHead", manifest_result.valid.tool_id);
    try std.testing.expectEqualStrings("wasm/plugin.wasm", manifest_result.valid.artifact_path);
    try std.testing.expect(std.fs.path.isAbsolute(manifest_result.valid.artifact_absolute_path));
    try std.testing.expect(std.mem.endsWith(u8, manifest_result.valid.artifact_absolute_path, "test/fixtures/wasm/pure-truncate-head-v0/wasm/plugin.wasm"));
    try std.testing.expectEqual(@as(usize, 0), manifest_result.valid.requested_capabilities.len);
}

test "wasm package invalid artifact rejects before load success" {
    const allocator = std.testing.allocator;

    var manifest_result = try wasm_manifest.validateManifestText(allocator, PURE_TOOL_PACKAGE_ROOT,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Missing artifact","artifact":{"kind":"wasm-component","path":"wasm/missing.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[]}
    );
    defer manifest_result.deinit(allocator);

    try std.testing.expect(manifest_result == .invalid);
    try std.testing.expectEqual(@as(usize, 1), manifest_result.invalid.len);
    try std.testing.expectEqual(.validate, manifest_result.invalid[0].phase);
    try std.testing.expectEqualStrings("$.artifact.path", manifest_result.invalid[0].path);
    try std.testing.expectEqualStrings("artifact file was not found", manifest_result.invalid[0].message);
}

test "wasm pure tool truncateHead success matches existing implementation under default deny" {
    const allocator = std.testing.allocator;

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, PURE_TOOL_PACKAGE_ROOT);
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    try std.testing.expectEqualStrings("builtin.truncateHead", manifest_result.valid.tool_id);
    try std.testing.expectEqualStrings("wasm/plugin.wasm", manifest_result.valid.artifact_path);
    try std.testing.expectEqual(@as(usize, 0), manifest_result.valid.requested_capabilities.len);

    const existing_json = try normalizedExistingPureToolCall(allocator, PURE_TOOL_SUCCESS_INPUT_JSON);
    defer allocator.free(existing_json);
    const wasm_json = try normalizedWasmPureToolCall(allocator, PURE_TOOL_SUCCESS_INPUT_JSON);
    defer allocator.free(wasm_json);
    try std.testing.expectEqualStrings(existing_json, wasm_json);

    const artifact_hash = try sha256FileHex(allocator, PURE_TOOL_ARTIFACT_PATH);
    defer allocator.free(artifact_hash);
    try std.testing.expectEqual(@as(usize, 64), artifact_hash.len);
}

test "wasm host explicit v0 ABI validates flavor imports memory exports and required signatures" {
    const allocator = std.testing.allocator;

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, PURE_TOOL_PACKAGE_ROOT);
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    try std.testing.expectEqual(wasm_manifest.ArtifactKind.wasm_component, manifest_result.valid.artifact_kind);

    var host = try Host.loadFromFile(allocator, std.testing.io, manifest_result.valid.artifact_absolute_path);
    defer host.deinit();
    try std.testing.expectEqual(WasmArtifactAbiFlavor.pi_tool_core_v0, host.abi_flavor);
    try std.testing.expectEqual(@as(usize, 0), host.import_count);
    try std.testing.expect(host.memory.len > 0);

    const import_attempt = try makeV0AbiModule(allocator, .{ .with_import = true });
    defer allocator.free(import_attempt);
    try std.testing.expectError(error.DeniedWasmImportCapability, parseFixture(allocator, import_attempt));

    const missing_export = try makeV0AbiModule(allocator, .{ .omit_execute_len = true });
    defer allocator.free(missing_export);
    try std.testing.expectError(error.MissingWasmExport, parseFixture(allocator, missing_export));

    const wrong_signature = try makeV0AbiModule(allocator, .{ .execute_params = 0 });
    defer allocator.free(wrong_signature);
    try std.testing.expectError(error.UnsupportedWasmAbi, parseFixture(allocator, wrong_signature));

    const missing_memory = try makeV0AbiModule(allocator, .{ .export_memory = false });
    defer allocator.free(missing_memory);
    try std.testing.expectError(error.MissingWasmMemoryExport, parseFixture(allocator, missing_memory));
}

test "wasm host execute receives input JSON and returns distinct bounded JSON outputs" {
    const allocator = std.testing.allocator;

    const first_existing = try normalizedExistingPureToolCall(allocator, PURE_TOOL_SUCCESS_INPUT_JSON);
    defer allocator.free(first_existing);
    const first_wasm = try normalizedWasmPureToolCall(allocator, PURE_TOOL_SUCCESS_INPUT_JSON);
    defer allocator.free(first_wasm);
    try std.testing.expectEqualStrings(first_existing, first_wasm);

    const second_existing = try normalizedExistingPureToolCall(allocator, PURE_TOOL_SECOND_SUCCESS_INPUT_JSON);
    defer allocator.free(second_existing);
    const second_wasm = try normalizedWasmPureToolCall(allocator, PURE_TOOL_SECOND_SUCCESS_INPUT_JSON);
    defer allocator.free(second_wasm);
    try std.testing.expectEqualStrings(second_existing, second_wasm);
    try std.testing.expect(!std.mem.eql(u8, first_wasm, second_wasm));

    var host = try Host.loadFromFile(allocator, std.testing.io, PURE_TOOL_ARTIFACT_PATH);
    defer host.deinit();
    try std.testing.expectError(error.InvalidUtf8Input, host.callExecute(&.{0xff}));
    try std.testing.expectError(error.InvalidJsonInput, host.callExecute("{"));
    const oversized = try allocator.alloc(u8, MAX_EXECUTE_INPUT_BYTES + 1);
    defer allocator.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.WasmInputTooLarge, host.callExecute(oversized));
}

test "wasm host validates exported UTF-8 JSON and memory bounds deterministically" {
    const allocator = std.testing.allocator;

    const invalid_utf8_metadata = try makeV0AbiModule(allocator, .{ .metadata_json = "\xff" });
    defer allocator.free(invalid_utf8_metadata);
    try std.testing.expectError(error.InvalidWasmUtf8, parseFixture(allocator, invalid_utf8_metadata));

    const invalid_schema_json = try makeV0AbiModule(allocator, .{ .schema_json = "[]" });
    defer allocator.free(invalid_schema_json);
    try std.testing.expectError(error.InvalidWasmJson, parseFixture(allocator, invalid_schema_json));

    const out_of_bounds = try makeV0AbiModule(allocator, .{ .execute_len_override = 65_000 });
    defer allocator.free(out_of_bounds);
    var host = try parseFixture(allocator, out_of_bounds);
    defer host.deinit();
    try std.testing.expectError(error.WasmStringOutOfBounds, host.callExecute(EXECUTE_INPUT_JSON));
}

test "wasm pure tool truncateHead malformed input diagnostic matches existing implementation" {
    const allocator = std.testing.allocator;

    const existing_json = try normalizedExistingPureToolCall(allocator, PURE_TOOL_MALFORMED_INPUT_JSON);
    defer allocator.free(existing_json);
    const wasm_json = try normalizedWasmPureToolCall(allocator, PURE_TOOL_MALFORMED_INPUT_JSON);
    defer allocator.free(wasm_json);
    try std.testing.expectEqualStrings(INVALID_INPUT_DIAGNOSTIC_JSON, existing_json);
    try std.testing.expectEqualStrings(existing_json, wasm_json);
}

fn normalizedExistingPureToolCall(allocator: std.mem.Allocator, input_json: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch {
        return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    };
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    const object = parsed.value.object;
    const content = stringField(object, "content") orelse return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    const max_lines = usizeField(object, "maxLines") orelse return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    const max_bytes = usizeField(object, "maxBytes") orelse return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);

    var result = try truncate_tool.truncateHead(allocator, content, .{
        .max_lines = max_lines,
        .max_bytes = max_bytes,
    });
    defer result.deinit(allocator);
    return truncationResultJson(allocator, result);
}

fn normalizedWasmPureToolCall(allocator: std.mem.Allocator, input_json: []const u8) ![]u8 {
    var host = try Host.loadFromFile(allocator, std.testing.io, PURE_TOOL_ARTIFACT_PATH);
    defer host.deinit();
    const output = host.callExecute(input_json) catch |err| switch (err) {
        error.InvalidJsonInput => return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON),
        else => return err,
    };
    defer allocator.free(output);
    return allocator.dupe(u8, output);
}

fn stringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn usizeField(object: std.json.ObjectMap, field: []const u8) ?usize {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        else => null,
    };
}

fn truncationResultJson(allocator: std.mem.Allocator, result: truncate_tool.TruncationResult) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"content\":");
    try std.json.Stringify.value(result.content, .{}, &writer.writer);
    try writer.writer.print(",\"truncated\":{},\"truncatedBy\":", .{result.truncated});
    if (result.truncated_by) |truncated_by| {
        try std.json.Stringify.value(switch (truncated_by) {
            .lines => "lines",
            .bytes => "bytes",
        }, .{}, &writer.writer);
    } else {
        try writer.writer.writeAll("null");
    }
    try writer.writer.print(
        ",\"totalLines\":{},\"totalBytes\":{},\"outputLines\":{},\"outputBytes\":{},\"lastLinePartial\":{},\"firstLineExceedsLimit\":{},\"maxLines\":{},\"maxBytes\":{}",
        .{
            result.total_lines,
            result.total_bytes,
            result.output_lines,
            result.output_bytes,
            result.last_line_partial,
            result.first_line_exceeds_limit,
            result.max_lines,
            result.max_bytes,
        },
    );
    try writer.writer.writeAll("}");
    return try allocator.dupe(u8, writer.written());
}

fn echoFixtureExecuteJson(allocator: std.mem.Allocator, input_json: []const u8) ![]u8 {
    var parsed = try parseJsonObject(allocator, input_json, error.InvalidJsonInput);
    defer parsed.deinit();
    const object = parsed.value.object;
    const operation = stringField(object, "operation") orelse return error.InvalidJsonInput;
    const value = stringField(object, "value") orelse return error.InvalidJsonInput;
    if (!std.mem.eql(u8, operation, "echo")) return error.InvalidJsonInput;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"ok\":true,\"tool\":\"fixture.echo\",\"echo\":");
    try std.json.Stringify.value(value, .{}, &writer.writer);
    try writer.writer.writeAll("}");
    return try allocator.dupe(u8, writer.written());
}

const V0AbiModuleOptions = struct {
    metadata_json: []const u8 = "{\"id\":\"fixture.static\",\"name\":\"Static Fixture\",\"version\":\"0.1.0\",\"description\":\"Generated v0 ABI fixture.\"}",
    schema_json: []const u8 = "{\"inputSchema\":{\"type\":\"object\"},\"outputSchema\":{\"type\":\"object\"}}",
    execute_json: []const u8 = "{\"ok\":true}",
    execute_len_override: ?u32 = null,
    execute_params: u32 = 2,
    with_import: bool = false,
    omit_execute_len: bool = false,
    export_memory: bool = true,
};

fn makeV0AbiModule(allocator: std.mem.Allocator, options: V0AbiModuleOptions) ![]u8 {
    var module = std.ArrayList(u8).empty;
    defer module.deinit(allocator);
    try module.appendSlice(allocator, "\x00asm\x01\x00\x00\x00");

    var type_payload = std.ArrayList(u8).empty;
    defer type_payload.deinit(allocator);
    try appendUleb(&type_payload, allocator, 2);
    try appendFuncType(&type_payload, allocator, 0);
    try appendFuncType(&type_payload, allocator, options.execute_params);
    try appendSection(&module, allocator, 1, type_payload.items);

    if (options.with_import) {
        var import_payload = std.ArrayList(u8).empty;
        defer import_payload.deinit(allocator);
        try appendUleb(&import_payload, allocator, 1);
        try appendName(&import_payload, allocator, "pi:filesystem");
        try appendName(&import_payload, allocator, "read");
        try import_payload.append(allocator, 0);
        try appendUleb(&import_payload, allocator, 0);
        try appendSection(&module, allocator, 2, import_payload.items);
    } else {
        try appendSection(&module, allocator, 2, &.{0});
    }

    var function_payload = std.ArrayList(u8).empty;
    defer function_payload.deinit(allocator);
    try appendUleb(&function_payload, allocator, 6);
    try appendUleb(&function_payload, allocator, 0);
    try appendUleb(&function_payload, allocator, 0);
    try appendUleb(&function_payload, allocator, 0);
    try appendUleb(&function_payload, allocator, 0);
    try appendUleb(&function_payload, allocator, 1);
    try appendUleb(&function_payload, allocator, 0);
    try appendSection(&module, allocator, 3, function_payload.items);

    try appendSection(&module, allocator, 5, &.{ 1, 0, 1 });

    const data_offset: u32 = 1024;
    const metadata_offset = data_offset;
    const schema_offset: u32 = metadata_offset + @as(u32, @intCast(options.metadata_json.len));
    const execute_offset: u32 = schema_offset + @as(u32, @intCast(options.schema_json.len));
    const execute_len: u32 = options.execute_len_override orelse @as(u32, @intCast(options.execute_json.len));

    var export_payload = std.ArrayList(u8).empty;
    defer export_payload.deinit(allocator);
    var export_count: u32 = if (options.export_memory) 7 else 6;
    if (options.omit_execute_len) export_count -= 1;
    try appendUleb(&export_payload, allocator, export_count);
    if (options.export_memory) {
        try appendName(&export_payload, allocator, "memory");
        try export_payload.append(allocator, 2);
        try appendUleb(&export_payload, allocator, 0);
    }
    const names = [_][]const u8{ "metadata", "metadata_len", "schema", "schema_len", "execute", "execute_len" };
    for (names, 0..) |name, index| {
        if (options.omit_execute_len and std.mem.eql(u8, name, "execute_len")) continue;
        try appendName(&export_payload, allocator, name);
        try export_payload.append(allocator, 0);
        try appendUleb(&export_payload, allocator, @intCast(index));
    }
    try appendSection(&module, allocator, 7, export_payload.items);

    var code_payload = std.ArrayList(u8).empty;
    defer code_payload.deinit(allocator);
    try appendUleb(&code_payload, allocator, 6);
    const returns = [_]u32{
        metadata_offset,
        @intCast(options.metadata_json.len),
        schema_offset,
        @intCast(options.schema_json.len),
        execute_offset,
        execute_len,
    };
    for (returns) |value| try appendConstI32Body(&code_payload, allocator, value);
    try appendSection(&module, allocator, 10, code_payload.items);

    var data_bytes = std.ArrayList(u8).empty;
    defer data_bytes.deinit(allocator);
    try data_bytes.appendSlice(allocator, options.metadata_json);
    try data_bytes.appendSlice(allocator, options.schema_json);
    try data_bytes.appendSlice(allocator, options.execute_json);

    var data_payload = std.ArrayList(u8).empty;
    defer data_payload.deinit(allocator);
    try appendUleb(&data_payload, allocator, 1);
    try appendUleb(&data_payload, allocator, 0);
    try data_payload.append(allocator, 0x41);
    try appendSleb(&data_payload, allocator, data_offset);
    try data_payload.append(allocator, 0x0b);
    try appendUleb(&data_payload, allocator, @intCast(data_bytes.items.len));
    try data_payload.appendSlice(allocator, data_bytes.items);
    try appendSection(&module, allocator, 11, data_payload.items);

    return module.toOwnedSlice(allocator);
}

fn appendFuncType(out: *std.ArrayList(u8), allocator: std.mem.Allocator, param_count: u32) !void {
    try out.append(allocator, 0x60);
    try appendUleb(out, allocator, param_count);
    var index: u32 = 0;
    while (index < param_count) : (index += 1) try out.append(allocator, 0x7f);
    try appendUleb(out, allocator, 1);
    try out.append(allocator, 0x7f);
}

fn appendConstI32Body(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.append(allocator, 0);
    try body.append(allocator, 0x41);
    try appendSleb(&body, allocator, value);
    try body.append(allocator, 0x0b);
    try appendUleb(out, allocator, @intCast(body.items.len));
    try out.appendSlice(allocator, body.items);
}

fn appendSection(out: *std.ArrayList(u8), allocator: std.mem.Allocator, id: u8, payload: []const u8) !void {
    try out.append(allocator, id);
    try appendUleb(out, allocator, @intCast(payload.len));
    try out.appendSlice(allocator, payload);
}

fn appendName(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    try appendUleb(out, allocator, @intCast(name.len));
    try out.appendSlice(allocator, name);
}

fn appendUleb(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var remaining = value;
    while (true) {
        var byte: u8 = @intCast(remaining & 0x7f);
        remaining >>= 7;
        if (remaining != 0) byte |= 0x80;
        try out.append(allocator, byte);
        if (remaining == 0) break;
    }
}

fn appendSleb(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var remaining: i32 = @intCast(value);
    while (true) {
        var byte: u8 = @intCast(@as(u32, @bitCast(remaining)) & 0x7f);
        remaining >>= 7;
        const done = (remaining == 0 and (byte & 0x40) == 0) or (remaining == -1 and (byte & 0x40) != 0);
        if (!done) byte |= 0x80;
        try out.append(allocator, byte);
        if (done) break;
    }
}

fn sha256FileHex(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const bytes = try readRepoFile(allocator, path);
    defer allocator.free(bytes);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}", .{hex[0..]});
}
