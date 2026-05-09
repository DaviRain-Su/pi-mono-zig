const std = @import("std");
const native_sdk = @import("pi_native_extension_sdk.zig");

pub const CONTRACT_NAME = native_sdk.ABI_NAME;
pub const HOST_MIN_ABI_VERSION = native_sdk.ABI_MIN_VERSION;
pub const HOST_MAX_ABI_VERSION = native_sdk.ABI_MAX_VERSION;
pub const TRUSTED_CODE_SECURITY_LIMITATION = native_sdk.TRUSTED_CODE_SECURITY_LIMITATION;

pub const SymbolSignature = enum {
    abi_version_fn,
    ptr_fn,
    len_fn,
    validate_fn,
    init_fn,
    execute_fn,
    free_fn,
    shutdown_fn,

    pub fn jsonName(self: SymbolSignature) []const u8 {
        return switch (self) {
            .abi_version_fn => "fn() callconv(.c) u32",
            .ptr_fn => "fn() callconv(.c) [*]const u8",
            .len_fn => "fn() callconv(.c) usize",
            .validate_fn => "fn() callconv(.c) i32",
            .init_fn => "fn(*const HostApiV0) callconv(.c) i32",
            .execute_fn => "fn([*]const u8, usize) callconv(.c) [*]const u8",
            .free_fn => "fn([*]const u8, usize) callconv(.c) void",
            .shutdown_fn => "fn() callconv(.c) i32",
        };
    }
};

pub const RequiredSymbol = struct {
    name: []const u8,
    signature: SymbolSignature,
    ownership_rule: []const u8,
};

pub const REQUIRED_SYMBOLS = [_]RequiredSymbol{
    .{
        .name = "pi_native_extension_abi_version",
        .signature = .abi_version_fn,
        .ownership_rule = "host calls before init; returns the package's preferred ABI version",
    },
    .{
        .name = "pi_native_extension_abi_name_ptr",
        .signature = .ptr_fn,
        .ownership_rule = "borrowed static bytes paired with pi_native_extension_abi_name_len",
    },
    .{
        .name = "pi_native_extension_abi_name_len",
        .signature = .len_fn,
        .ownership_rule = "length for borrowed ABI name bytes",
    },
    .{
        .name = "pi_native_extension_metadata_ptr",
        .signature = .ptr_fn,
        .ownership_rule = "borrowed metadata JSON bytes valid for the library lifetime",
    },
    .{
        .name = "pi_native_extension_metadata_len",
        .signature = .len_fn,
        .ownership_rule = "length for borrowed metadata JSON bytes",
    },
    .{
        .name = "pi_native_extension_validate",
        .signature = .validate_fn,
        .ownership_rule = "host calls after ABI symbol resolution and before init",
    },
    .{
        .name = "pi_native_extension_init",
        .signature = .init_fn,
        .ownership_rule = "host calls exactly once only after ABI negotiation succeeds",
    },
    .{
        .name = "pi_native_extension_execute",
        .signature = .execute_fn,
        .ownership_rule = "returned pointer is package-owned until host copies and calls pi_native_extension_free",
    },
    .{
        .name = "pi_native_extension_execute_len",
        .signature = .len_fn,
        .ownership_rule = "length for the package-owned execute result bytes",
    },
    .{
        .name = "pi_native_extension_free",
        .signature = .free_fn,
        .ownership_rule = "host calls once for each non-null execute result pointer, including rejected oversized results",
    },
    .{
        .name = "pi_native_extension_shutdown",
        .signature = .shutdown_fn,
        .ownership_rule = "host calls at unload; callbacks are invalid after shutdown begins",
    },
};

pub const ResolvedSymbol = struct {
    name: []const u8,
    signature: SymbolSignature,
};

pub const Diagnostic = struct {
    phase: []const u8,
    code: []const u8,
    symbol: ?[]const u8 = null,
    expected: ?[]const u8 = null,
    actual: ?[]const u8 = null,
    message: []const u8,
};

pub const ContractResult = union(enum) {
    valid: NegotiatedAbi,
    invalid: Diagnostic,
};

pub const NegotiatedAbi = struct {
    abi_name: []const u8,
    host_min_version: u32,
    host_max_version: u32,
    package_min_version: u32,
    package_max_version: u32,
    negotiated_version: u32,
    metadata_id: []const u8,
    metadata_tool_name: []const u8,
    trusted_code_notice: []const u8 = TRUSTED_CODE_SECURITY_LIMITATION,
};

pub const ManifestExpectation = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    runtime_descriptor: []const u8,
    tool_name: []const u8,
    capability_exports: []const []const u8 = &.{},
    abi_name: []const u8 = CONTRACT_NAME,
    abi_min_version: u32 = HOST_MIN_ABI_VERSION,
    abi_max_version: u32 = HOST_MAX_ABI_VERSION,
};

pub const AbiVersionFn = *const fn () callconv(.c) u32;
pub const PtrFn = *const fn () callconv(.c) [*]const u8;
pub const LenFn = *const fn () callconv(.c) usize;
pub const ValidateFn = *const fn () callconv(.c) i32;
pub const InitFn = *const fn (*const native_sdk.HostApiV0) callconv(.c) i32;
pub const ExecuteFn = *const fn ([*]const u8, usize) callconv(.c) [*]const u8;
pub const FreeFn = *const fn ([*]const u8, usize) callconv(.c) void;
pub const ShutdownFn = *const fn () callconv(.c) i32;

pub const FunctionTable = struct {
    abi_version: ?AbiVersionFn = null,
    abi_name_ptr: ?PtrFn = null,
    abi_name_len: ?LenFn = null,
    metadata_ptr: ?PtrFn = null,
    metadata_len: ?LenFn = null,
    validate: ?ValidateFn = null,
    init: ?InitFn = null,
    execute: ?ExecuteFn = null,
    execute_len: ?LenFn = null,
    free: ?FreeFn = null,
    shutdown: ?ShutdownFn = null,
};

pub fn validateResolvedSymbols(symbols: []const ResolvedSymbol) ContractResult {
    for (REQUIRED_SYMBOLS) |required| {
        var found: ?ResolvedSymbol = null;
        for (symbols) |symbol| {
            if (std.mem.eql(u8, symbol.name, required.name)) {
                found = symbol;
                break;
            }
        }
        const resolved = found orelse return .{ .invalid = .{
            .phase = "symbol_resolution",
            .code = "native_abi_missing_symbol",
            .symbol = required.name,
            .expected = required.signature.jsonName(),
            .message = "required native ABI symbol was not exported",
        } };
        if (resolved.signature != required.signature) return .{ .invalid = .{
            .phase = "symbol_resolution",
            .code = "native_abi_invalid_symbol_signature",
            .symbol = required.name,
            .expected = required.signature.jsonName(),
            .actual = resolved.signature.jsonName(),
            .message = "native ABI symbol signature does not match pi_native_extension_abi_v0",
        } };
    }
    return .{ .valid = .{
        .abi_name = CONTRACT_NAME,
        .host_min_version = HOST_MIN_ABI_VERSION,
        .host_max_version = HOST_MAX_ABI_VERSION,
        .package_min_version = HOST_MIN_ABI_VERSION,
        .package_max_version = HOST_MAX_ABI_VERSION,
        .negotiated_version = HOST_MAX_ABI_VERSION,
        .metadata_id = "",
        .metadata_tool_name = "",
    } };
}

pub fn validateAndInitialize(
    allocator: std.mem.Allocator,
    table: FunctionTable,
    manifest: ManifestExpectation,
    host_api: *const native_sdk.HostApiV0,
) !ContractResult {
    const symbol_result = validateFunctionTablePresence(table);
    if (symbol_result == .invalid) return symbol_result;

    const abi_name = readRequiredBytes(table.abi_name_ptr.?, table.abi_name_len.?, native_sdk.MAX_ABI_NAME_BYTES) catch |err| {
        return contractError("abi_negotiation", "native_abi_invalid_name_buffer", @errorName(err), "ABI name pointer/length pair is invalid");
    };
    if (!std.mem.eql(u8, abi_name, CONTRACT_NAME)) return .{ .invalid = .{
        .phase = "abi_negotiation",
        .code = "native_abi_name_mismatch",
        .expected = CONTRACT_NAME,
        .actual = abi_name,
        .message = "native package ABI name is not supported",
    } };

    const package_version = table.abi_version.?();
    if (package_version < HOST_MIN_ABI_VERSION or package_version > HOST_MAX_ABI_VERSION) return .{ .invalid = .{
        .phase = "abi_negotiation",
        .code = "native_abi_version_mismatch",
        .expected = "host supports pi_native_extension_abi_v0 version range 0..0",
        .actual = @errorName(error.UnsupportedNativeAbiVersion),
        .message = "native package ABI version is outside the host-supported range",
    } };

    const metadata = readRequiredBytes(table.metadata_ptr.?, table.metadata_len.?, native_sdk.MAX_METADATA_BYTES) catch |err| {
        return contractError("metadata", "native_abi_invalid_metadata_buffer", @errorName(err), "metadata pointer/length pair is invalid");
    };
    const metadata_result = try validateMetadataAgainstManifest(allocator, metadata, manifest);
    if (metadata_result == .invalid) return metadata_result;

    if (table.validate.?() != 0) return .{ .invalid = .{
        .phase = "metadata",
        .code = "native_abi_validate_failed",
        .message = "native package self-validation failed before init",
    } };

    if (table.init.?(host_api) != 0) return .{ .invalid = .{
        .phase = "init",
        .code = "native_abi_init_failed",
        .message = "native package init returned failure",
    } };

    return metadata_result;
}

pub fn validateMetadataAgainstManifest(
    allocator: std.mem.Allocator,
    metadata_json: []const u8,
    manifest: ManifestExpectation,
) !ContractResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, metadata_json, .{}) catch {
        return contractError("metadata", "native_abi_metadata_invalid_json", null, "native metadata must be valid JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return contractError("metadata", "native_abi_metadata_invalid_json", null, "native metadata must be a JSON object");
    const root = parsed.value.object;

    if (!stringEquals(root, "schemaVersion", native_sdk.SCHEMA_VERSION)) {
        return metadataMismatch("$.schemaVersion", native_sdk.SCHEMA_VERSION, "metadata schema version does not match native manifest schema");
    }
    if (!stringEquals(root, "runtime", native_sdk.RUNTIME_KIND)) {
        return metadataMismatch("$.runtime", native_sdk.RUNTIME_KIND, "metadata runtime kind does not match native manifest runtime");
    }
    if (!stringEquals(root, "id", manifest.id)) {
        return metadataMismatch("$.id", manifest.id, "metadata package id does not match manifest id");
    }
    if (!stringEquals(root, "name", manifest.name)) {
        return metadataMismatch("$.name", manifest.name, "metadata package name does not match manifest name");
    }
    if (!stringEquals(root, "version", manifest.version)) {
        return metadataMismatch("$.version", manifest.version, "metadata package version does not match manifest version");
    }

    const abi = objectField(root, "abi") orelse return metadataMismatch("$.abi", "object", "metadata is missing ABI range");
    if (!stringEquals(abi, "name", manifest.abi_name)) {
        return metadataMismatch("$.abi.name", manifest.abi_name, "metadata ABI name does not match manifest ABI name");
    }
    const package_min = integerField(abi, "minVersion") orelse return metadataMismatch("$.abi.minVersion", "integer", "metadata ABI range is missing minVersion");
    const package_max = integerField(abi, "maxVersion") orelse return metadataMismatch("$.abi.maxVersion", "integer", "metadata ABI range is missing maxVersion");
    if (package_min < 0 or package_max < package_min) return metadataMismatch("$.abi", "valid version range", "metadata ABI range is invalid");
    const package_min_u32: u32 = @intCast(package_min);
    const package_max_u32: u32 = @intCast(package_max);
    if (package_max_u32 < HOST_MIN_ABI_VERSION or package_min_u32 > HOST_MAX_ABI_VERSION) {
        return .{ .invalid = .{
            .phase = "abi_negotiation",
            .code = "native_abi_version_mismatch",
            .expected = "overlap with host ABI range 0..0",
            .actual = "metadata ABI range has no host overlap",
            .message = "native metadata ABI range is incompatible with the host",
        } };
    }

    const tool = objectField(root, "tool") orelse return metadataMismatch("$.tool", "object", "metadata is missing tool description");
    if (!stringEquals(tool, "name", manifest.tool_name)) {
        return metadataMismatch("$.tool.name", manifest.tool_name, "metadata tool name does not match manifest tool name");
    }
    if (objectField(tool, "inputSchema") == null) return metadataMismatch("$.tool.inputSchema", "object", "metadata input schema must be an object");
    if (objectField(tool, "outputSchema") == null) return metadataMismatch("$.tool.outputSchema", "object", "metadata output schema must be an object");

    const capabilities = objectField(root, "capabilities") orelse return metadataMismatch("$.capabilities", "object", "metadata is missing declared capabilities");
    const exports = arrayField(capabilities, "exports") orelse return metadataMismatch("$.capabilities.exports", "array", "metadata is missing exported capabilities");
    for (manifest.capability_exports) |capability_id| {
        if (!capabilityExportPresent(exports.items, capability_id)) {
            return .{ .invalid = .{
                .phase = "metadata",
                .code = "native_abi_metadata_capability_mismatch",
                .expected = capability_id,
                .message = "metadata exported capabilities do not match the native manifest",
            } };
        }
    }

    return .{ .valid = .{
        .abi_name = manifest.abi_name,
        .host_min_version = HOST_MIN_ABI_VERSION,
        .host_max_version = HOST_MAX_ABI_VERSION,
        .package_min_version = package_min_u32,
        .package_max_version = package_max_u32,
        .negotiated_version = @min(HOST_MAX_ABI_VERSION, package_max_u32),
        .metadata_id = manifest.id,
        .metadata_tool_name = manifest.tool_name,
    } };
}

pub fn copyNativeBufferAndRelease(
    allocator: std.mem.Allocator,
    ptr: ?[*]const u8,
    len: usize,
    max_len: usize,
    free_fn: FreeFn,
) ![]u8 {
    const concrete_ptr = ptr orelse {
        if (len == 0) return allocator.alloc(u8, 0);
        return error.NativeAbiNullBuffer;
    };
    if (len > max_len) {
        free_fn(concrete_ptr, len);
        return error.NativeAbiOutputTooLarge;
    }
    const copy = try allocator.dupe(u8, concrete_ptr[0..len]);
    free_fn(concrete_ptr, len);
    return copy;
}

pub const HostCallbackLease = struct {
    active: bool = true,

    pub fn ensureActive(self: HostCallbackLease) !void {
        if (!self.active) return error.NativeAbiStaleCallback;
    }

    pub fn deactivate(self: *HostCallbackLease) void {
        self.active = false;
    }
};

fn validateFunctionTablePresence(table: FunctionTable) ContractResult {
    if (table.abi_version == null) return missingFunction("pi_native_extension_abi_version", .abi_version_fn);
    if (table.abi_name_ptr == null) return missingFunction("pi_native_extension_abi_name_ptr", .ptr_fn);
    if (table.abi_name_len == null) return missingFunction("pi_native_extension_abi_name_len", .len_fn);
    if (table.metadata_ptr == null) return missingFunction("pi_native_extension_metadata_ptr", .ptr_fn);
    if (table.metadata_len == null) return missingFunction("pi_native_extension_metadata_len", .len_fn);
    if (table.validate == null) return missingFunction("pi_native_extension_validate", .validate_fn);
    if (table.init == null) return missingFunction("pi_native_extension_init", .init_fn);
    if (table.execute == null) return missingFunction("pi_native_extension_execute", .execute_fn);
    if (table.execute_len == null) return missingFunction("pi_native_extension_execute_len", .len_fn);
    if (table.free == null) return missingFunction("pi_native_extension_free", .free_fn);
    if (table.shutdown == null) return missingFunction("pi_native_extension_shutdown", .shutdown_fn);
    return .{ .valid = .{
        .abi_name = CONTRACT_NAME,
        .host_min_version = HOST_MIN_ABI_VERSION,
        .host_max_version = HOST_MAX_ABI_VERSION,
        .package_min_version = HOST_MIN_ABI_VERSION,
        .package_max_version = HOST_MAX_ABI_VERSION,
        .negotiated_version = HOST_MAX_ABI_VERSION,
        .metadata_id = "",
        .metadata_tool_name = "",
    } };
}

fn missingFunction(name: []const u8, signature: SymbolSignature) ContractResult {
    return .{ .invalid = .{
        .phase = "symbol_resolution",
        .code = "native_abi_missing_symbol",
        .symbol = name,
        .expected = signature.jsonName(),
        .message = "required native ABI symbol was not resolved",
    } };
}

fn readRequiredBytes(ptr_fn: PtrFn, len_fn: LenFn, max_len: usize) ![]const u8 {
    const len_value = len_fn();
    if (len_value > max_len) return error.NativeAbiBufferTooLarge;
    return ptr_fn()[0..len_value];
}

fn contractError(phase: []const u8, code: []const u8, actual: ?[]const u8, message: []const u8) ContractResult {
    return .{ .invalid = .{
        .phase = phase,
        .code = code,
        .actual = actual,
        .message = message,
    } };
}

fn metadataMismatch(path: []const u8, expected: []const u8, message: []const u8) ContractResult {
    return .{ .invalid = .{
        .phase = "metadata",
        .code = "native_abi_metadata_mismatch",
        .symbol = path,
        .expected = expected,
        .message = message,
    } };
}

fn stringEquals(object: std.json.ObjectMap, field: []const u8, expected: []const u8) bool {
    const value = object.get(field) orelse return false;
    return value == .string and std.mem.eql(u8, value.string, expected);
}

fn objectField(object: std.json.ObjectMap, field: []const u8) ?std.json.ObjectMap {
    const value = object.get(field) orelse return null;
    if (value != .object) return null;
    return value.object;
}

fn arrayField(object: std.json.ObjectMap, field: []const u8) ?std.json.Array {
    const value = object.get(field) orelse return null;
    if (value != .array) return null;
    return value.array;
}

fn integerField(object: std.json.ObjectMap, field: []const u8) ?i64 {
    const value = object.get(field) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn capabilityExportPresent(items: []const std.json.Value, expected_id: []const u8) bool {
    for (items) |item| {
        if (item != .object) continue;
        if (stringEquals(item.object, "id", expected_id)) return true;
    }
    return false;
}

const fixture_metadata = native_sdk.staticMetadataJson(
    "com.pi.native.template.echo",
    "Pi Native Zig Echo Template",
    "0.1.0",
    "Echoes a message field through the native dynamic runtime boundary.",
    "native.echo",
    "Echoes a message field from the JSON input.",
    "{\"type\":\"object\"}",
    "{\"type\":\"object\"}",
);

var fixture_init_calls: usize = 0;
var fixture_free_calls: usize = 0;

fn fixtureAbiVersion() callconv(.c) u32 {
    return native_sdk.ABI_VERSION;
}

fn fixtureAbiNamePtr() callconv(.c) [*]const u8 {
    return native_sdk.ABI_NAME.ptr;
}

fn fixtureAbiNameLen() callconv(.c) usize {
    return native_sdk.ABI_NAME.len;
}

fn fixtureMetadataPtr() callconv(.c) [*]const u8 {
    return fixture_metadata.ptr;
}

fn fixtureMetadataLen() callconv(.c) usize {
    return fixture_metadata.len;
}

fn fixtureValidate() callconv(.c) i32 {
    return 0;
}

fn fixtureInit(_: *const native_sdk.HostApiV0) callconv(.c) i32 {
    fixture_init_calls += 1;
    return 0;
}

fn fixtureExecute(_: [*]const u8, _: usize) callconv(.c) [*]const u8 {
    return fixture_metadata.ptr;
}

fn fixtureExecuteLen() callconv(.c) usize {
    return fixture_metadata.len;
}

fn fixtureFree(_: [*]const u8, _: usize) callconv(.c) void {
    fixture_free_calls += 1;
}

fn fixtureShutdown() callconv(.c) i32 {
    return 0;
}

fn unsupportedAbiVersion() callconv(.c) u32 {
    return 99;
}

fn fixtureTable() FunctionTable {
    return .{
        .abi_version = fixtureAbiVersion,
        .abi_name_ptr = fixtureAbiNamePtr,
        .abi_name_len = fixtureAbiNameLen,
        .metadata_ptr = fixtureMetadataPtr,
        .metadata_len = fixtureMetadataLen,
        .validate = fixtureValidate,
        .init = fixtureInit,
        .execute = fixtureExecute,
        .execute_len = fixtureExecuteLen,
        .free = fixtureFree,
        .shutdown = fixtureShutdown,
    };
}

fn fixtureManifest() ManifestExpectation {
    return .{
        .id = "com.pi.native.template.echo",
        .name = "Pi Native Zig Echo Template",
        .version = "0.1.0",
        .runtime_descriptor = "native://dynamic/com.pi.native.template.echo",
        .tool_name = "native.echo",
        .capability_exports = &.{"native.echo"},
    };
}

test "native ABI contract defines required symbols and memory ownership rules" {
    try std.testing.expectEqualStrings("pi_native_extension_abi_v0", CONTRACT_NAME);
    try std.testing.expect(REQUIRED_SYMBOLS.len >= 10);
    try std.testing.expect(std.mem.indexOf(u8, TRUSTED_CODE_SECURITY_LIMITATION, "trusted local code") != null);
    try std.testing.expect(std.mem.indexOf(u8, TRUSTED_CODE_SECURITY_LIMITATION, "not sandboxed") != null);
    try std.testing.expect(std.mem.indexOf(u8, TRUSTED_CODE_SECURITY_LIMITATION, "before native library load") != null);
    var saw_free = false;
    var saw_init = false;
    for (REQUIRED_SYMBOLS) |symbol| {
        if (std.mem.eql(u8, symbol.name, "pi_native_extension_free")) {
            saw_free = true;
            try std.testing.expect(std.mem.indexOf(u8, symbol.ownership_rule, "once") != null);
        }
        if (std.mem.eql(u8, symbol.name, "pi_native_extension_init")) saw_init = true;
    }
    try std.testing.expect(saw_free);
    try std.testing.expect(saw_init);
}

test "native ABI symbol validation reports missing and invalid exports deterministically" {
    const valid_symbols = [_]ResolvedSymbol{
        .{ .name = "pi_native_extension_abi_version", .signature = .abi_version_fn },
        .{ .name = "pi_native_extension_abi_name_ptr", .signature = .ptr_fn },
        .{ .name = "pi_native_extension_abi_name_len", .signature = .len_fn },
        .{ .name = "pi_native_extension_metadata_ptr", .signature = .ptr_fn },
        .{ .name = "pi_native_extension_metadata_len", .signature = .len_fn },
        .{ .name = "pi_native_extension_validate", .signature = .validate_fn },
        .{ .name = "pi_native_extension_init", .signature = .init_fn },
        .{ .name = "pi_native_extension_execute", .signature = .execute_fn },
        .{ .name = "pi_native_extension_execute_len", .signature = .len_fn },
        .{ .name = "pi_native_extension_free", .signature = .free_fn },
        .{ .name = "pi_native_extension_shutdown", .signature = .shutdown_fn },
    };
    try std.testing.expect(validateResolvedSymbols(&valid_symbols) == .valid);

    const missing = validateResolvedSymbols(valid_symbols[0 .. valid_symbols.len - 1]);
    try std.testing.expect(missing == .invalid);
    try std.testing.expectEqualStrings("symbol_resolution", missing.invalid.phase);
    try std.testing.expectEqualStrings("native_abi_missing_symbol", missing.invalid.code);
    try std.testing.expectEqualStrings("pi_native_extension_shutdown", missing.invalid.symbol.?);

    var invalid_symbols = valid_symbols;
    invalid_symbols[7] = .{ .name = "pi_native_extension_execute", .signature = .ptr_fn };
    const invalid = validateResolvedSymbols(&invalid_symbols);
    try std.testing.expect(invalid == .invalid);
    try std.testing.expectEqualStrings("native_abi_invalid_symbol_signature", invalid.invalid.code);
    try std.testing.expectEqualStrings("pi_native_extension_execute", invalid.invalid.symbol.?);
    try std.testing.expectEqualStrings("fn([*]const u8, usize) callconv(.c) [*]const u8", invalid.invalid.expected.?);
}

test "native ABI negotiation accepts compatible metadata before init" {
    const allocator = std.testing.allocator;
    fixture_init_calls = 0;
    var host_api = native_sdk.HostApiV0{ .abi_version = native_sdk.ABI_VERSION };
    const result = try validateAndInitialize(allocator, fixtureTable(), fixtureManifest(), &host_api);
    try std.testing.expect(result == .valid);
    try std.testing.expectEqual(@as(u32, 0), result.valid.negotiated_version);
    try std.testing.expectEqualStrings("com.pi.native.template.echo", result.valid.metadata_id);
    try std.testing.expectEqualStrings("native.echo", result.valid.metadata_tool_name);
    try std.testing.expectEqual(@as(usize, 1), fixture_init_calls);
}

test "native ABI mismatch fails before init" {
    const allocator = std.testing.allocator;
    fixture_init_calls = 0;
    var table = fixtureTable();
    table.abi_version = unsupportedAbiVersion;
    var host_api = native_sdk.HostApiV0{ .abi_version = native_sdk.ABI_VERSION };
    const result = try validateAndInitialize(allocator, table, fixtureManifest(), &host_api);
    try std.testing.expect(result == .invalid);
    try std.testing.expectEqualStrings("abi_negotiation", result.invalid.phase);
    try std.testing.expectEqualStrings("native_abi_version_mismatch", result.invalid.code);
    try std.testing.expectEqual(@as(usize, 0), fixture_init_calls);
}

test "native ABI metadata consistency rejects manifest divergence" {
    const allocator = std.testing.allocator;
    var manifest = fixtureManifest();
    manifest.tool_name = "native.other";
    const result = try validateMetadataAgainstManifest(allocator, fixture_metadata, manifest);
    try std.testing.expect(result == .invalid);
    try std.testing.expectEqualStrings("metadata", result.invalid.phase);
    try std.testing.expectEqualStrings("native_abi_metadata_mismatch", result.invalid.code);
    try std.testing.expectEqualStrings("$.tool.name", result.invalid.symbol.?);
    try std.testing.expectEqualStrings("native.other", result.invalid.expected.?);
}

test "native ABI ownership copies results releases buffers and rejects stale callbacks" {
    const allocator = std.testing.allocator;
    fixture_free_calls = 0;
    const output = "owned-result";
    const copy = try copyNativeBufferAndRelease(allocator, output.ptr, output.len, 64, fixtureFree);
    defer allocator.free(copy);
    try std.testing.expectEqualStrings(output, copy);
    try std.testing.expectEqual(@as(usize, 1), fixture_free_calls);

    try std.testing.expectError(
        error.NativeAbiOutputTooLarge,
        copyNativeBufferAndRelease(allocator, output.ptr, output.len, 4, fixtureFree),
    );
    try std.testing.expectEqual(@as(usize, 2), fixture_free_calls);
    try std.testing.expectError(
        error.NativeAbiNullBuffer,
        copyNativeBufferAndRelease(allocator, null, output.len, 64, fixtureFree),
    );

    var lease = HostCallbackLease{};
    try lease.ensureActive();
    lease.deactivate();
    try std.testing.expectError(error.NativeAbiStaleCallback, lease.ensureActive());
}
