const std = @import("std");

const PLUGIN_FIXTURE_PATH = "test/fixtures/wasm/native-tool-v0/plugin.wasm";
const EVIDENCE_PATH = "docs/wasm-host-spike-evidence.md";
const EXECUTE_INPUT_JSON = "{\"operation\":\"echo\",\"value\":\"native-wasm\"}";
const EXPECTED_EXECUTE_OUTPUT_JSON = "{\"ok\":true,\"tool\":\"fixture.echo\",\"echo\":\"native-wasm\"}";

pub const Host = struct {
    allocator: std.mem.Allocator,
    memory: []u8,
    function_returns: []?u32,
    function_exports: std.StringHashMap(u32),

    pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Host {
        const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(512 * 1024));
        defer allocator.free(bytes);
        return parseFixture(allocator, bytes);
    }

    pub fn deinit(self: *Host) void {
        freeStringHashMapKeys(&self.function_exports, self.allocator);
        self.function_exports.deinit();
        self.allocator.free(self.function_returns);
        self.allocator.free(self.memory);
        self.* = undefined;
    }

    pub fn callMetadata(self: *const Host) ![]u8 {
        return self.callStringExport("metadata", "metadata_len");
    }

    pub fn callSchema(self: *const Host) ![]u8 {
        return self.callStringExport("schema", "schema_len");
    }

    pub fn callExecute(self: *const Host, input_json: []const u8) ![]u8 {
        try expectJsonObject(self.allocator, input_json);
        return self.callStringExport("execute", "execute_len");
    }

    fn callStringExport(self: *const Host, export_name: []const u8, len_export_name: []const u8) ![]u8 {
        const ptr = try self.invokeConstI32(export_name);
        const len = try self.invokeConstI32(len_export_name);
        const start: usize = @intCast(ptr);
        const byte_len: usize = @intCast(len);
        if (start > self.memory.len or byte_len > self.memory.len - start) return error.WasmStringOutOfBounds;
        return self.allocator.dupe(u8, self.memory[start .. start + byte_len]);
    }

    fn invokeConstI32(self: *const Host, export_name: []const u8) !u32 {
        const function_index = self.function_exports.get(export_name) orelse return error.MissingWasmExport;
        const index: usize = @intCast(function_index);
        if (index >= self.function_returns.len) return error.InvalidWasmFunctionIndex;
        return self.function_returns[index] orelse error.UnsupportedWasmFunctionBody;
    }
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
    var function_returns = std.ArrayList(?u32).empty;
    defer function_returns.deinit(allocator);
    var function_exports = std.StringHashMap(u32).init(allocator);
    errdefer {
        freeStringHashMapKeys(&function_exports, allocator);
        function_exports.deinit();
    }

    var cursor = Cursor{ .bytes = bytes[8..] };
    while (cursor.remaining() > 0) {
        const section_id = try cursor.readByte();
        const payload_len = try cursor.readUleb32();
        const payload = try cursor.readSlice(payload_len);
        var section = Cursor{ .bytes = payload };
        switch (section_id) {
            1 => try parseTypeSection(&section),
            2 => try parseImportSection(&section),
            3 => try parseFunctionSection(allocator, &section, &function_returns),
            5 => try parseMemorySection(allocator, &section, &memory),
            7 => try parseExportSection(allocator, &section, &function_exports),
            10 => try parseCodeSection(&section, &function_returns),
            11 => try parseDataSection(&section, memory),
            else => {},
        }
    }

    const owned_returns = try function_returns.toOwnedSlice(allocator);
    errdefer allocator.free(owned_returns);
    const host = Host{
        .allocator = allocator,
        .memory = memory,
        .function_returns = owned_returns,
        .function_exports = function_exports,
    };
    try validateRequiredExports(&host);
    return host;
}

fn parseTypeSection(section: *Cursor) !void {
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
    }
}

fn parseImportSection(section: *Cursor) !void {
    const count = try section.readUleb32();
    if (count != 0) return error.UnsupportedWasmFixture;
}

fn parseFunctionSection(
    allocator: std.mem.Allocator,
    section: *Cursor,
    function_returns: *std.ArrayList(?u32),
) !void {
    const count = try section.readUleb32();
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        _ = try section.readUleb32();
        try function_returns.append(allocator, null);
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
    const new_memory = try allocator.alloc(u8, bytes);
    @memset(new_memory, 0);
    allocator.free(memory.*);
    memory.* = new_memory;
}

fn parseExportSection(
    allocator: std.mem.Allocator,
    section: *Cursor,
    function_exports: *std.StringHashMap(u32),
) !void {
    const count = try section.readUleb32();
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const name_len = try section.readUleb32();
        const name = try section.readSlice(name_len);
        const kind = try section.readByte();
        const item_index = try section.readUleb32();
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

fn parseDataSection(section: *Cursor, memory: []u8) !void {
    if (memory.len == 0) return error.MissingWasmMemory;
    const count = try section.readUleb32();
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
    }
}

fn validateRequiredExports(host: *const Host) !void {
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
}

fn expectJsonObject(allocator: std.mem.Allocator, text: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.InvalidJsonInput;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJsonInput;
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
    try expectNotContains(source, "@import(\"extension_registry.zig\")");
    try expectNotContains(source, "@import(\"session.zig\")");
    try expectNotContains(source, "@import(\"session_manager.zig\")");
    try expectNotContains(source, "@import(\"provider_config.zig\")");
}
