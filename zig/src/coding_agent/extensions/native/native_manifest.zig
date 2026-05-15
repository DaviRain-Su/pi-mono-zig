const std = @import("std");

pub const MANIFEST_FILE_NAME = "pi-extension.json";
pub const SCHEMA_VERSION = "pi-extension.v1";
pub const ARTIFACT_KIND = "native-dynamic";

pub const Diagnostic = struct {
    path: []const u8 = "$",
    message: []const u8 = "native extensions are not supported by the Zig runtime",
};

pub const ResourceLimits = struct {
    max_children: ?u64 = null,
    depth: ?u64 = null,
    turns: ?u64 = null,
    timeout_ms: ?u64 = null,
    output_bytes: ?u64 = null,
    output_lines: ?u64 = null,
    tool_scopes: []const []u8 = &.{},
};

pub const Manifest = struct {
    package_root: []const u8 = "",
    manifest_path: []const u8 = "",
    schema_version: []const u8 = SCHEMA_VERSION,
    id: []const u8 = "",
    name: []const u8 = "",
    version: []const u8 = "",
    description: []const u8 = "",
    descriptor: []const u8 = "",
    tool_name: []const u8 = "",
    selected_artifact_path: []const u8 = "",
    selected_artifact_absolute_path: []const u8 = "",
    selected_artifact_os: []const u8 = "",
    selected_artifact_arch: []const u8 = "",
    selected_artifact_sha256: []const u8 = "",
    manifest_sha256: []const u8 = "",
    package_root_sha256: []const u8 = "",
    requested_capabilities: []const @import("../wasm/wasm_manifest.zig").Capability = &.{},
    resource_limits: ResourceLimits = .{},

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = .{};
    }
};

pub const ValidationResult = union(enum) {
    valid: Manifest,
    invalid: []const Diagnostic,

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = .{ .invalid = &.{} };
    }
};

pub fn isNativeDynamicManifestText(allocator: std.mem.Allocator, manifest_text: []const u8) bool {
    _ = allocator;
    return std.mem.indexOf(u8, manifest_text, "native") != null;
}

pub fn validateManifestFile(allocator: std.mem.Allocator, io: std.Io, package_root: []const u8) !ValidationResult {
    _ = allocator;
    _ = io;
    _ = package_root;
    return .{ .invalid = &.{.{}} };
}

pub fn validateManifestText(allocator: std.mem.Allocator, package_root: []const u8, manifest_text: []const u8) !ValidationResult {
    _ = allocator;
    _ = package_root;
    _ = manifest_text;
    return .{ .invalid = &.{.{}} };
}
