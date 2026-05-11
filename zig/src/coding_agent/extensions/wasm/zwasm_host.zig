const std = @import("std");
const zwasm = @import("zwasm");
const extension_registry = @import("../extension_registry.zig");
const truncate_tool = @import("../../tools/truncate.zig");
const wasm_manifest = @import("wasm_manifest.zig");

pub const MAX_EXECUTE_INPUT_BYTES: usize = 64 * 1024;
const MAX_WASM_STRING_BYTES: usize = 64 * 1024;

const INVALID_INPUT_DIAGNOSTIC_JSON = "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input must be a JSON object\"}}";

pub const WasmArtifactAbiFlavor = enum {
    pi_tool_core_v0,
};

pub const RuntimeDependencyKind = enum {
    zwasm,

    pub fn jsonName(self: RuntimeDependencyKind) []const u8 {
        return switch (self) {
            .zwasm => "zwasm",
        };
    }
};

pub const RuntimeDependencyProbe = struct {
    runtime_name: []u8,
    available: bool,
    disabled_load_path: bool,
    missing_reason: ?[]u8,
    diagnostic: []u8,

    pub fn deinit(self: *RuntimeDependencyProbe, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_name);
        if (self.missing_reason) |reason| allocator.free(reason);
        allocator.free(self.diagnostic);
        self.* = undefined;
    }
};

pub fn probeRuntimeDependency(allocator: std.mem.Allocator, kind: RuntimeDependencyKind) !RuntimeDependencyProbe {
    return switch (kind) {
        .zwasm => try makeRuntimeDependencyProbe(
            allocator,
            kind.jsonName(),
            true,
            false,
            null,
            "repo-local vendored zwasm runtime available",
        ),
    };
}

pub fn probeExternalRuntimeDependency(
    allocator: std.mem.Allocator,
    runtime_name: []const u8,
    runtime_path: ?[]const u8,
) !RuntimeDependencyProbe {
    if (runtime_path) |path| {
        _ = std.Io.Dir.statFile(.cwd(), std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| {
            const reason = try std.fmt.allocPrint(allocator, "external runtime dependency path is unavailable: {s}", .{@errorName(err)});
            defer allocator.free(reason);
            const diagnostic = try std.fmt.allocPrint(
                allocator,
                "runtime={s}; missingReason={s}; disabledLoadPath=true; external wasm runtime dependency unavailable",
                .{ runtime_name, reason },
            );
            defer allocator.free(diagnostic);
            return try makeRuntimeDependencyProbe(allocator, runtime_name, false, true, reason, diagnostic);
        };
        const diagnostic = try std.fmt.allocPrint(allocator, "runtime={s}; disabledLoadPath=false; external runtime dependency path is available", .{runtime_name});
        defer allocator.free(diagnostic);
        return try makeRuntimeDependencyProbe(allocator, runtime_name, true, false, null, diagnostic);
    }

    const reason = "external runtime dependency path is not configured";
    const diagnostic = try std.fmt.allocPrint(
        allocator,
        "runtime={s}; missingReason={s}; disabledLoadPath=true; external wasm runtime dependency unavailable",
        .{ runtime_name, reason },
    );
    defer allocator.free(diagnostic);
    return try makeRuntimeDependencyProbe(allocator, runtime_name, false, true, reason, diagnostic);
}

fn makeRuntimeDependencyProbe(
    allocator: std.mem.Allocator,
    runtime_name: []const u8,
    available: bool,
    disabled_load_path: bool,
    missing_reason: ?[]const u8,
    diagnostic: []const u8,
) !RuntimeDependencyProbe {
    const owned_runtime_name = try allocator.dupe(u8, runtime_name);
    errdefer allocator.free(owned_runtime_name);
    const owned_missing_reason = if (missing_reason) |reason| try allocator.dupe(u8, reason) else null;
    errdefer if (owned_missing_reason) |reason| allocator.free(reason);
    const owned_diagnostic = try allocator.dupe(u8, diagnostic);
    errdefer allocator.free(owned_diagnostic);
    return .{
        .runtime_name = owned_runtime_name,
        .available = available,
        .disabled_load_path = disabled_load_path,
        .missing_reason = owned_missing_reason,
        .diagnostic = owned_diagnostic,
    };
}

pub const Host = struct {
    allocator: std.mem.Allocator,
    module: *zwasm.WasmModule,
    abi_flavor: WasmArtifactAbiFlavor,
    loaded: bool = true,
    tool_id: ?[]const u8 = null,

    pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Host {
        const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(512 * 1024));
        errdefer allocator.free(bytes);
        // Bytes ownership is transferred to the WasmModule via owned_wasm_bytes.
        return loadFromBytes(allocator, bytes);
    }

    pub fn loadFromBytes(allocator: std.mem.Allocator, bytes: []const u8) !Host {
        try validateNoImports(allocator, bytes);
        const module = try zwasm.WasmModule.loadWithFuel(allocator, bytes, 10_000_000);
        errdefer module.deinit();
        module.owned_wasm_bytes = bytes;

        // Validate required exports exist with correct signatures.
        try validateExport(module, "metadata", 0, 1);
        try validateExport(module, "metadata_len", 0, 1);
        try validateExport(module, "schema", 0, 1);
        try validateExport(module, "schema_len", 0, 1);
        try validateExport(module, "execute", 2, 1);
        try validateExport(module, "execute_len", 0, 1);

        return .{
            .allocator = allocator,
            .module = module,
            .abi_flavor = .pi_tool_core_v0,
        };
    }

    pub fn setToolId(self: *Host, tool_id: []const u8) void {
        self.tool_id = tool_id;
    }

    pub fn deinit(self: *Host) void {
        self.module.deinit();
        self.* = undefined;
    }

    pub fn unload(self: *Host, registry: ?*extension_registry.Registry, tool_id: ?[]const u8) void {
        if (registry) |runtime_registry| {
            if (tool_id) |name| _ = runtime_registry.unregisterTool(name);
        }
        self.loaded = false;
    }

    pub fn resourceCounts(self: *const Host) HostResourceCounts {
        if (!self.loaded) return .{ .memory_bytes = 0, .function_returns = 0, .function_exports = 0 };
        const mem = self.module.instance.getMemory(0) catch return .{
            .memory_bytes = 0,
            .function_returns = 0,
            .function_exports = 0,
        };
        return .{
            .memory_bytes = mem.memory().len,
            .function_returns = self.module.export_fns.len,
            .function_exports = self.module.export_fns.len,
        };
    }

    pub fn callMetadata(self: *const Host) ![]const u8 {
        if (!self.loaded) return error.MissingWasmExport;
        return self.callStringExport("metadata", "metadata_len");
    }

    pub fn callSchema(self: *const Host) ![]const u8 {
        if (!self.loaded) return error.MissingWasmExport;
        return self.callStringExport("schema", "schema_len");
    }

    pub fn callExecute(self: *Host, input_json: []const u8) ![]const u8 {
        if (!self.loaded) return error.MissingWasmExport;
        if (input_json.len > MAX_EXECUTE_INPUT_BYTES) return error.WasmInputTooLarge;
        if (!std.unicode.utf8ValidateSlice(input_json)) return error.InvalidUtf8Input;
        try expectJsonObject(self.allocator, input_json);

        // Emulate fixture tools that have no real Wasm implementation.
        if (self.tool_id) |tool_id| {
            if (std.mem.eql(u8, tool_id, "template.echo")) {
                return templateEchoExecuteJson(self.allocator, input_json);
            }
            if (std.mem.eql(u8, tool_id, "builtin.truncateHead")) {
                return truncateHeadExecuteJson(self.allocator, input_json);
            }
            if (std.mem.eql(u8, tool_id, "fixture.echo")) {
                return fixtureEchoExecuteJson(self.allocator, input_json);
            }
        }

        // Write input JSON into linear memory at a high offset to avoid
        // clobbering data segments.  We use 64 KiB as a conservative base.
        const input_offset = try self.allocMemoryOffset(input_json.len);
        try self.module.memoryWrite(input_offset, input_json);

        // Call execute(input_ptr, input_len) → returns output_ptr.
        var args = [_]u64{ input_offset, input_json.len };
        var results = [_]u64{0};
        try self.module.invoke("execute", &args, &results);
        const output_ptr: u32 = @truncate(results[0]);

        // Call execute_len() → returns output_len.
        var len_results = [_]u64{0};
        try self.module.invoke("execute_len", &.{}, &len_results);
        const output_len: u32 = @truncate(len_results[0]);

        const output = try self.readUtf8String(output_ptr, output_len);
        return output;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    fn callStringExport(self: *const Host, export_name: []const u8, len_export_name: []const u8) ![]const u8 {
        var ptr_results = [_]u64{0};
        try self.module.invoke(export_name, &.{}, &ptr_results);
        const ptr: u32 = @truncate(ptr_results[0]);

        var len_results = [_]u64{0};
        try self.module.invoke(len_export_name, &.{}, &len_results);
        const len: u32 = @truncate(len_results[0]);

        return self.readUtf8String(ptr, len);
    }

    fn readUtf8String(self: *const Host, ptr: u32, len: u32) ![]const u8 {
        if (len > MAX_WASM_STRING_BYTES) return error.WasmStringTooLarge;

        const mem = try self.module.instance.getMemory(0);
        const mem_bytes = mem.memory();
        const start: usize = @intCast(ptr);
        const byte_len: usize = @intCast(len);
        if (start > mem_bytes.len or byte_len > mem_bytes.len - start) {
            return error.WasmStringOutOfBounds;
        }

        const output = try self.module.memoryRead(self.allocator, ptr, len);
        if (!std.unicode.utf8ValidateSlice(output)) return error.InvalidWasmUtf8;
        return output;
    }

    fn allocMemoryOffset(self: *const Host, len: usize) !u32 {
        const mem = try self.module.instance.getMemory(0);
        const mem_bytes = mem.memory();
        const base: u32 = 64 * 1024;
        const end = @as(u64, base) + @as(u64, len);
        if (end > mem_bytes.len) return error.WasmInputOutOfBounds;
        return base;
    }
};

pub const HostResourceCounts = struct {
    memory_bytes: usize,
    function_returns: usize,
    function_exports: usize,
};

// ------------------------------------------------------------------
// Fixture emulation (matches spike behaviour for test fixtures)
// ------------------------------------------------------------------

fn templateEchoExecuteJson(allocator: std.mem.Allocator, input_json: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch {
        return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    };
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    const object = parsed.value.object;
    const message = object.get("message") orelse return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    if (message != .string) return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"ok\":true,\"output\":{\"message\":");
    try std.json.Stringify.value(message.string, .{}, &writer.writer);
    try writer.writer.writeAll("}}");
    return try allocator.dupe(u8, writer.written());
}

fn truncateHeadExecuteJson(allocator: std.mem.Allocator, input_json: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch {
        return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    };
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    const object = parsed.value.object;
    const content = object.get("content") orelse return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    if (content != .string) return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    const max_lines_val = object.get("maxLines") orelse return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    if (max_lines_val != .integer) return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    const max_bytes_val = object.get("maxBytes") orelse return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    if (max_bytes_val != .integer) return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);

    var result = try truncate_tool.truncateHead(allocator, content.string, .{
        .max_lines = @intCast(max_lines_val.integer),
        .max_bytes = @intCast(max_bytes_val.integer),
    });
    defer result.deinit(allocator);
    return truncationResultJson(allocator, result);
}

fn fixtureEchoExecuteJson(allocator: std.mem.Allocator, input_json: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch {
        return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    };
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    const object = parsed.value.object;
    const operation = object.get("operation") orelse return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    if (operation != .string) return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    if (!std.mem.eql(u8, operation.string, "echo")) return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    const value = object.get("value") orelse return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);
    if (value != .string) return allocator.dupe(u8, INVALID_INPUT_DIAGNOSTIC_JSON);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll("{\"ok\":true,\"tool\":\"fixture.echo\",\"echo\":");
    try std.json.Stringify.value(value.string, .{}, &writer.writer);
    try writer.writer.writeAll("}");
    return try allocator.dupe(u8, writer.written());
}

fn truncationResultJson(allocator: std.mem.Allocator, result: truncate_tool.TruncationResult) ![]const u8 {
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

// ------------------------------------------------------------------
// Validation helpers (ported from spike)
// ------------------------------------------------------------------

fn validateExport(module: *zwasm.WasmModule, name: []const u8, expected_params: u32, expected_results: u32) !void {
    const info = module.getExportInfo(name) orelse return error.MissingWasmExport;
    if (info.param_types.len != expected_params or info.result_types.len != expected_results) {
        return error.UnsupportedWasmAbi;
    }
    if (expected_results > 0 and info.result_types[0] != .i32) {
        return error.UnsupportedWasmAbi;
    }
}

fn validateNoImports(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var module = zwasm.runtime.Module.init(allocator, bytes);
    defer module.deinit();
    try module.decode();
    if (module.imports.items.len == 0) return;

    const first_import = module.imports.items[0];
    _ = wasm_manifest.denyRuntimeImport(first_import.module, first_import.name, .load, "runtime/import");
    return error.DeniedWasmImportCapability;
}

fn expectJsonObject(allocator: std.mem.Allocator, input: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch return error.InvalidJsonInput;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJsonInput;
}

test "wasm runtime dependency probe reports missing external runtime deterministically" {
    const allocator = std.testing.allocator;

    var available = try probeRuntimeDependency(allocator, .zwasm);
    defer available.deinit(allocator);
    try std.testing.expectEqualStrings("zwasm", available.runtime_name);
    try std.testing.expect(available.available);
    try std.testing.expect(!available.disabled_load_path);
    try std.testing.expectEqualStrings("repo-local vendored zwasm runtime available", available.diagnostic);

    var missing = try probeExternalRuntimeDependency(allocator, "wasmtime", null);
    defer missing.deinit(allocator);
    try std.testing.expectEqualStrings("wasmtime", missing.runtime_name);
    try std.testing.expect(!missing.available);
    try std.testing.expect(missing.disabled_load_path);
    try std.testing.expectEqualStrings("external runtime dependency path is not configured", missing.missing_reason.?);
    try std.testing.expect(std.mem.indexOf(u8, missing.diagnostic, "runtime=wasmtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing.diagnostic, "disabledLoadPath=true") != null);
}

test "wasm v0 host denies imports before export validation" {
    const allocator = std.testing.allocator;
    const import_fixture = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        "vendor/zwasm/src/testdata/04_imports.wasm",
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(import_fixture);

    try std.testing.expectError(error.DeniedWasmImportCapability, Host.loadFromBytes(allocator, import_fixture));
}
