const std = @import("std");
const capability = @import("../capability.zig");

pub const MANIFEST_FILE_NAME = "pi-extension.json";
pub const SCHEMA_VERSION = "pi-extension.v1";
pub const Capability = capability.Capability;
pub const CANONICAL_CAPABILITIES = capability.CANONICAL_CAPABILITIES;
pub const CapabilityEnforcementBranch = capability.CapabilityEnforcementBranch;
pub const CapabilityDenialDiagnostic = capability.CapabilityDenialDiagnostic;
pub const ResourceLimits = capability.ResourceLimits;
pub const LifecyclePhase = capability.LifecyclePhase;
pub const parseCapability = capability.parseCapability;
pub const denyFirstUnapprovedCapability = capability.denyFirstUnapprovedCapability;

pub const Diagnostic = struct {
    path: []const u8 = "$",
    message: []const u8 = "wasm extensions are not supported by the Zig runtime",
    principal: ?struct {
        policy_lookup_key: []const u8,
        extension_id: []const u8,
        tool_id: []const u8,
        runtime_kind: []const u8,
    } = null,
    capability: ?Capability = null,
    source: ?struct {
        manifest_path: []const u8,
        package_root: []const u8,
        artifact_path: []const u8,
    } = null,
};

pub const ArtifactKind = enum {
    wasm_component,

    pub fn jsonName(self: ArtifactKind) []const u8 {
        return switch (self) {
            .wasm_component => "wasm-component",
        };
    }
};

pub const Manifest = struct {
    package_root: []const u8 = "",
    manifest_path: []const u8 = "",
    schema_version: []const u8 = SCHEMA_VERSION,
    id: []const u8 = "",
    name: []const u8 = "",
    version: []const u8 = "",
    description: []const u8 = "",
    artifact_kind: ArtifactKind = .wasm_component,
    artifact_path: []const u8 = "",
    artifact_absolute_path: []const u8 = "",
    artifact_sha256: []const u8 = "",
    package_root_sha256: []const u8 = "",
    tool_id: []const u8 = "",
    tool_description: []const u8 = "",
    input_schema_json: []const u8 = "{}",
    output_schema_json: []const u8 = "{}",
    requested_capabilities: []const Capability = &.{},
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

pub const ValidateOptions = struct {
    approved_capabilities: []const Capability = CANONICAL_CAPABILITIES[0..],
};

pub fn validateManifestFile(allocator: std.mem.Allocator, io: std.Io, package_root: []const u8) !ValidationResult {
    return validateManifestFileWithOptions(allocator, io, package_root, .{});
}

pub fn validateManifestFileWithOptions(allocator: std.mem.Allocator, io: std.Io, package_root: []const u8, options: ValidateOptions) !ValidationResult {
    _ = allocator;
    _ = io;
    _ = package_root;
    _ = options;
    return .{ .invalid = &.{.{}} };
}

pub fn validateManifestText(allocator: std.mem.Allocator, package_root: []const u8, manifest_text: []const u8) !ValidationResult {
    _ = allocator;
    _ = package_root;
    _ = manifest_text;
    return .{ .invalid = &.{.{}} };
}

pub fn computePackageRootSha256(allocator: std.mem.Allocator, package_root: []const u8) ![]u8 {
    _ = package_root;
    return allocator.dupe(u8, "unsupported");
}
