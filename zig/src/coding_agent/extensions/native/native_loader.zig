const std = @import("std");
const builtin = @import("builtin");
const native_abi_contract = @import("native_abi_contract.zig");
const native_manifest = @import("native_manifest.zig");
const native_sdk = @import("pi_native_extension_sdk.zig");

pub const Diagnostic = struct {
    phase: []const u8,
    code: []const u8,
    message: []const u8,
    artifact_path: []const u8,
    cause: ?[]const u8 = null,
    symbol: ?[]const u8 = null,
    expected: ?[]const u8 = null,
    actual: ?[]const u8 = null,
};

pub const LoadedLibrary = struct {
    library: std.DynLib,
    artifact_path: []u8,
    functions: native_abi_contract.FunctionTable,
    unloaded: bool = false,

    pub fn shutdownAndClose(self: *LoadedLibrary) ?i32 {
        if (self.unloaded) return null;
        const shutdown_status = if (self.functions.shutdown) |shutdown| shutdown() else null;
        self.library.close();
        self.unloaded = true;
        return shutdown_status;
    }

    pub fn deinit(self: *LoadedLibrary, allocator: std.mem.Allocator) void {
        _ = self.shutdownAndClose();
        allocator.free(self.artifact_path);
        self.* = undefined;
    }
};

pub const LoadResult = union(enum) {
    loaded: LoadedLibrary,
    invalid: Diagnostic,
};

pub fn loadVerifiedPackage(
    allocator: std.mem.Allocator,
    manifest: *const native_manifest.Manifest,
    host_api: *const native_sdk.HostApiV0,
) !LoadResult {
    if (unsupportedPlatformReason()) |reason| {
        return invalid(
            "load",
            "native_loader_unsupported_platform",
            "dynamic native library loading is not supported on this platform",
            manifest.selected_artifact_absolute_path,
            reason,
        );
    }
    if (!std.fs.path.isAbsolute(manifest.package_root) or !std.fs.path.isAbsolute(manifest.selected_artifact_absolute_path)) {
        return invalid(
            "load",
            "native_loader_noncanonical_path",
            "native loader requires canonical absolute package-root and artifact paths",
            manifest.selected_artifact_absolute_path,
            null,
        );
    }

    const root_real = realpathAlloc(allocator, manifest.package_root) catch |err| {
        return invalid(
            "load",
            "native_loader_package_root_unavailable",
            "native package root could not be canonicalized before library load",
            manifest.selected_artifact_absolute_path,
            @errorName(err),
        );
    };
    defer allocator.free(root_real);
    if (!std.mem.eql(u8, root_real, manifest.package_root)) {
        return invalid(
            "load",
            "native_loader_package_root_drift",
            "native package root canonical path changed after provenance verification",
            manifest.selected_artifact_absolute_path,
            null,
        );
    }
    const artifact_real = realpathAlloc(allocator, manifest.selected_artifact_absolute_path) catch |err| {
        return invalid(
            "load",
            "native_library_open_failed",
            "selected native dynamic library artifact was not found before load",
            manifest.selected_artifact_absolute_path,
            @errorName(err),
        );
    };
    defer allocator.free(artifact_real);
    if (!pathWithin(root_real, artifact_real)) {
        return invalid(
            "load",
            "native_loader_artifact_escape",
            "selected native dynamic library resolves outside the canonical package root",
            manifest.selected_artifact_absolute_path,
            null,
        );
    }
    if (!std.mem.eql(u8, artifact_real, manifest.selected_artifact_absolute_path)) {
        return invalid(
            "load",
            "native_loader_artifact_drift",
            "selected native dynamic library canonical path changed after provenance verification",
            manifest.selected_artifact_absolute_path,
            null,
        );
    }

    var library = openPlatformLibrary(manifest.selected_artifact_absolute_path) catch |err| {
        return invalid(
            "load",
            "native_library_open_failed",
            "platform linker failed to open selected native dynamic library",
            manifest.selected_artifact_absolute_path,
            @errorName(err),
        );
    };
    errdefer library.close();

    const table = switch (resolveFunctionTable(&library, manifest.selected_artifact_absolute_path)) {
        .table => |resolved| resolved,
        .diagnostic => |diagnostic| return .{ .invalid = diagnostic },
    };
    const expectation = manifestExpectation(manifest);
    const contract = try native_abi_contract.validateAndInitialize(allocator, table, expectation, host_api);
    switch (contract) {
        .valid => {},
        .invalid => |diagnostic| {
            if (std.mem.eql(u8, diagnostic.phase, "init")) {
                if (table.shutdown) |shutdown| _ = shutdown();
            }
            return .{ .invalid = contractDiagnostic(diagnostic, manifest.selected_artifact_absolute_path) };
        },
    }

    return .{ .loaded = .{
        .library = library,
        .artifact_path = try allocator.dupe(u8, manifest.selected_artifact_absolute_path),
        .functions = table,
    } };
}

const SymbolResolve = union(enum) {
    table: native_abi_contract.FunctionTable,
    diagnostic: Diagnostic,
};

fn resolveFunctionTable(library: *std.DynLib, artifact_path: []const u8) SymbolResolve {
    return .{ .table = .{
        .abi_version = library.lookup(native_abi_contract.AbiVersionFn, "pi_native_extension_abi_version") orelse return missingSymbol("pi_native_extension_abi_version", "fn() callconv(.c) u32", artifact_path),
        .abi_name_ptr = library.lookup(native_abi_contract.PtrFn, "pi_native_extension_abi_name_ptr") orelse return missingSymbol("pi_native_extension_abi_name_ptr", "fn() callconv(.c) [*]const u8", artifact_path),
        .abi_name_len = library.lookup(native_abi_contract.LenFn, "pi_native_extension_abi_name_len") orelse return missingSymbol("pi_native_extension_abi_name_len", "fn() callconv(.c) usize", artifact_path),
        .metadata_ptr = library.lookup(native_abi_contract.PtrFn, "pi_native_extension_metadata_ptr") orelse return missingSymbol("pi_native_extension_metadata_ptr", "fn() callconv(.c) [*]const u8", artifact_path),
        .metadata_len = library.lookup(native_abi_contract.LenFn, "pi_native_extension_metadata_len") orelse return missingSymbol("pi_native_extension_metadata_len", "fn() callconv(.c) usize", artifact_path),
        .validate = library.lookup(native_abi_contract.ValidateFn, "pi_native_extension_validate") orelse return missingSymbol("pi_native_extension_validate", "fn() callconv(.c) i32", artifact_path),
        .init = library.lookup(native_abi_contract.InitFn, "pi_native_extension_init") orelse return missingSymbol("pi_native_extension_init", "fn(*const HostApiV0) callconv(.c) i32", artifact_path),
        .execute = library.lookup(native_abi_contract.ExecuteFn, "pi_native_extension_execute") orelse return missingSymbol("pi_native_extension_execute", "fn([*]const u8, usize) callconv(.c) [*]const u8", artifact_path),
        .execute_len = library.lookup(native_abi_contract.LenFn, "pi_native_extension_execute_len") orelse return missingSymbol("pi_native_extension_execute_len", "fn() callconv(.c) usize", artifact_path),
        .free = library.lookup(native_abi_contract.FreeFn, "pi_native_extension_free") orelse return missingSymbol("pi_native_extension_free", "fn([*]const u8, usize) callconv(.c) void", artifact_path),
        .shutdown = library.lookup(native_abi_contract.ShutdownFn, "pi_native_extension_shutdown") orelse return missingSymbol("pi_native_extension_shutdown", "fn() callconv(.c) i32", artifact_path),
    } };
}

fn missingSymbol(symbol: []const u8, expected: []const u8, artifact_path: []const u8) SymbolResolve {
    return .{ .diagnostic = .{
        .phase = "symbol_resolution",
        .code = "native_abi_missing_symbol",
        .message = "required native ABI symbol was not resolved",
        .artifact_path = artifact_path,
        .symbol = symbol,
        .expected = expected,
    } };
}

fn manifestExpectation(manifest: *const native_manifest.Manifest) native_abi_contract.ManifestExpectation {
    return .{
        .id = manifest.id,
        .name = manifest.name,
        .version = manifest.version,
        .runtime_descriptor = manifest.descriptor,
        .tool_name = manifest.tool_name,
    };
}

fn invalid(
    phase: []const u8,
    code: []const u8,
    message: []const u8,
    artifact_path: []const u8,
    cause: ?[]const u8,
) LoadResult {
    return .{ .invalid = .{
        .phase = phase,
        .code = code,
        .message = message,
        .artifact_path = artifact_path,
        .cause = cause,
    } };
}

fn contractDiagnostic(diagnostic: native_abi_contract.Diagnostic, artifact_path: []const u8) Diagnostic {
    return .{
        .phase = diagnostic.phase,
        .code = diagnostic.code,
        .message = diagnostic.message,
        .artifact_path = artifact_path,
        .symbol = diagnostic.symbol,
        .expected = diagnostic.expected,
        .actual = diagnostic.actual,
    };
}

fn unsupportedPlatformReason() ?[]const u8 {
    return switch (builtin.os.tag) {
        .windows => "windows native dynamic runtime execution is build-only in this milestone",
        .macos, .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => null,
        else => "unsupported host OS for dynamic native runtime execution",
    };
}

pub fn unsupportedPlatformReasonForTesting() ?[]const u8 {
    return unsupportedPlatformReason();
}

fn openPlatformLibrary(path: []const u8) !std.DynLib {
    return switch (builtin.os.tag) {
        .windows => error.UnsupportedNativeRuntimePlatform,
        .macos, .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => std.DynLib.open(path),
        else => error.UnsupportedNativeRuntimePlatform,
    };
}

fn pathWithin(root: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, root, candidate)) return true;
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len <= root.len) return false;
    return candidate[root.len] == std.fs.path.sep;
}

fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) {
        return std.fs.path.resolve(allocator, &.{path}) catch return error.FileNotFound;
    }
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = std.c.realpath(z_path.ptr, &buffer) orelse return error.FileNotFound;
    return allocator.dupe(u8, std.mem.span(resolved));
}

fn nativeLibrarySuffix() []const u8 {
    return switch (builtin.os.tag) {
        .macos => ".dylib",
        .windows => ".dll",
        else => ".so",
    };
}

fn hostOs() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos",
        .windows => "windows",
        else => "linux",
    };
}

fn hostArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => @tagName(builtin.cpu.arch),
    };
}

fn exitCodeFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

test "native loader opens compatible dynamic library after canonical validation" {
    if (unsupportedPlatformReason() != null) return;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "package/native");
    try tmp.dir.createDirPath(std.testing.io, "package/src");
    const source =
        \\const HostApiV0 = extern struct { abi_version: u32, reserved: ?*anyopaque = null };
        \\const abi_name = "pi_native_extension_abi_v0";
        \\const metadata = "{\"schemaVersion\":\"pi-extension.v1\",\"runtime\":\"native\",\"abi\":{\"name\":\"pi_native_extension_abi_v0\",\"minVersion\":0,\"maxVersion\":0},\"id\":\"com.example.native\",\"name\":\"Native Example\",\"version\":\"0.1.0\",\"description\":\"Native example.\",\"tool\":{\"name\":\"native.echo\",\"description\":\"Echo.\",\"inputSchema\":{},\"outputSchema\":{}},\"capabilities\":{\"exports\":[],\"imports\":[]}}";
        \\export fn pi_native_extension_abi_version() u32 { return 0; }
        \\export fn pi_native_extension_abi_name_ptr() [*]const u8 { return abi_name.ptr; }
        \\export fn pi_native_extension_abi_name_len() usize { return abi_name.len; }
        \\export fn pi_native_extension_metadata_ptr() [*]const u8 { return metadata.ptr; }
        \\export fn pi_native_extension_metadata_len() usize { return metadata.len; }
        \\export fn pi_native_extension_validate() i32 { return 0; }
        \\export fn pi_native_extension_init(host_api: *const HostApiV0) i32 { return if (host_api.abi_version == 0) 0 else 1; }
        \\export fn pi_native_extension_execute(_: [*]const u8, _: usize) [*]const u8 { return metadata.ptr; }
        \\export fn pi_native_extension_execute_len() usize { return metadata.len; }
        \\export fn pi_native_extension_free(_: [*]const u8, _: usize) void {}
        \\export fn pi_native_extension_shutdown() i32 { return 0; }
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "package/src/plugin.zig", .data = source });
    const package_root = try tmp.dir.realPathFileAlloc(std.testing.io, "package", allocator);
    defer allocator.free(package_root);
    const source_path = try std.fs.path.join(allocator, &.{ package_root, "src", "plugin.zig" });
    defer allocator.free(source_path);
    const artifact_rel = try std.fmt.allocPrint(allocator, "native/plugin{s}", .{nativeLibrarySuffix()});
    defer allocator.free(artifact_rel);
    const artifact_path = try std.fs.path.join(allocator, &.{ package_root, artifact_rel });
    defer allocator.free(artifact_path);
    const emit_arg = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{artifact_path});
    defer allocator.free(emit_arg);
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "zig", "build-lib", "-dynamic", "-O", "ReleaseSafe", source_path, emit_arg },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (exitCodeFromTerm(result.term) != 0) {
        std.debug.print("native loader fixture build stdout:\n{s}\nnative loader fixture build stderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.NativeLoaderFixtureBuildFailed;
    }
    const manifest_json = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": "pi-extension.v1",
        \\  "id": "com.example.native",
        \\  "name": "Native Example",
        \\  "version": "0.1.0",
        \\  "description": "Native example.",
        \\  "runtime": {{ "kind": "native", "entrypoint": {{ "descriptor": "native://dynamic/com.example.native" }} }},
        \\  "artifacts": [{{ "kind": "native-dynamic", "os": "{s}", "arch": "{s}", "path": "{s}" }}],
        \\  "tools": [{{ "name": "native.echo", "description": "Echo.", "inputSchema": {{}}, "outputSchema": {{}} }}],
        \\  "capabilities": {{ "exports": [], "imports": [] }},
        \\  "permissions": []
        \\}}
    , .{ hostOs(), hostArch(), artifact_rel });
    defer allocator.free(manifest_json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "package/pi-extension.json", .data = manifest_json });
    var manifest_result = try native_manifest.validateManifestFile(allocator, std.testing.io, package_root);
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    var host_api = native_sdk.HostApiV0{ .abi_version = native_sdk.ABI_VERSION };
    var load_result = try loadVerifiedPackage(allocator, &manifest_result.valid, &host_api);
    try std.testing.expect(load_result == .loaded);
    defer load_result.loaded.deinit(allocator);
    try std.testing.expectEqualStrings(artifact_path, load_result.loaded.artifact_path);
    try std.testing.expect(load_result.loaded.functions.execute != null);
}

test "native loader reports platform linker failures for selected artifact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "package/native");
    const artifact_name = switch (builtin.os.tag) {
        .macos => "plugin.dylib",
        .windows => "plugin.dll",
        else => "plugin.so",
    };
    const artifact_sub_path = try std.fs.path.join(allocator, &.{ "package/native", artifact_name });
    defer allocator.free(artifact_sub_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = artifact_sub_path, .data = "not-a-dynamic-library" });
    const package_root = try tmp.dir.realPathFileAlloc(std.testing.io, "package", allocator);
    defer allocator.free(package_root);
    const artifact_path = try std.fs.path.join(allocator, &.{ package_root, "native", artifact_name });
    defer allocator.free(artifact_path);

    var manifest = native_manifest.Manifest{
        .package_root = try allocator.dupe(u8, package_root),
        .manifest_path = try std.fs.path.join(allocator, &.{ package_root, "pi-extension.json" }),
        .manifest_sha256 = try allocator.dupe(u8, "0"),
        .schema_version = try allocator.dupe(u8, native_manifest.SCHEMA_VERSION),
        .id = try allocator.dupe(u8, "com.example.native"),
        .name = try allocator.dupe(u8, "Native Example"),
        .version = try allocator.dupe(u8, "0.1.0"),
        .description = try allocator.dupe(u8, "Native example"),
        .descriptor = try allocator.dupe(u8, "native://dynamic/com.example.native"),
        .selected_artifact_path = try std.fs.path.join(allocator, &.{ "native", artifact_name }),
        .selected_artifact_absolute_path = try allocator.dupe(u8, artifact_path),
        .selected_artifact_os = try allocator.dupe(u8, if (builtin.os.tag == .macos) "macos" else @tagName(builtin.os.tag)),
        .selected_artifact_arch = try allocator.dupe(u8, @tagName(builtin.cpu.arch)),
        .selected_artifact_sha256 = try allocator.dupe(u8, "0"),
        .package_root_sha256 = try allocator.dupe(u8, "0"),
        .tool_name = try allocator.dupe(u8, "native.echo"),
        .requested_capabilities = try allocator.alloc(@import("../wasm/wasm_manifest.zig").Capability, 0),
        .resource_limits = try native_manifest.ResourceLimits.initEmpty(allocator),
    };
    defer manifest.deinit(allocator);
    var host_api = native_sdk.HostApiV0{ .abi_version = native_sdk.ABI_VERSION };
    const result = try loadVerifiedPackage(allocator, &manifest, &host_api);
    try std.testing.expect(result == .invalid);
    if (unsupportedPlatformReason() == null) {
        try std.testing.expectEqualStrings("load", result.invalid.phase);
        try std.testing.expectEqualStrings("native_library_open_failed", result.invalid.code);
    }
    try std.testing.expectEqualStrings(artifact_path, result.invalid.artifact_path);
}
