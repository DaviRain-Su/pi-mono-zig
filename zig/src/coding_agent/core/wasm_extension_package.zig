const std = @import("std");
const extension_policy = @import("extension_policy.zig");

pub const WASM_EXTENSION_MANIFEST_NAME = "pi-extension.json";
pub const WASM_EXTENSION_SCHEMA_VERSION = "pi-extension.v0";
pub const WASM_DENIED_CAPABILITY_CATEGORY = "denied_capability";
pub const WASM_CANONICAL_SECURITY_GRANTS = extension_policy.CANONICAL_EXTENSION_GRANTS;
pub const WASM_CANONICAL_CAPABILITIES = WASM_CANONICAL_SECURITY_GRANTS;
pub const WasmExtensionResourceLimits = extension_policy.ExtensionResourceLimits;

pub const WasmExtensionPackagePolicyRequest = struct {
    package_root: []const u8,
    manifest_path: []const u8,
    policy_lookup_key: []const u8,
    schema_version: []const u8,
    id: []const u8,
    name: []const u8,
    version: []const u8,
    description: []const u8,
    artifact_path: []const u8,
    tool_id: []const u8,
    tool_description: []const u8,
    capabilities: []const extension_policy.CanonicalExtensionGrant,
    resource_limits: WasmExtensionResourceLimits,

    pub fn deinit(self: *WasmExtensionPackagePolicyRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest_path);
        allocator.free(self.policy_lookup_key);
        allocator.free(self.capabilities);
        allocator.free(self.resource_limits.tool_scopes);
        self.* = undefined;
    }
};

pub const WasmExtensionPackageManifest = struct {
    kind: []const u8 = "wasm-extension",
    package_root: []const u8,
    manifest_path: []const u8,
    policy_lookup_key: []const u8,
    schema_version: []const u8,
    id: []const u8,
    name: []const u8,
    version: []const u8,
    description: []const u8,
    artifact_kind: []const u8 = "wasm-component",
    artifact_path: []const u8,
    artifact_absolute_path: []const u8,
    artifact_sha256: []const u8,
    tool_id: []const u8,
    tool_description: []const u8,
    capabilities: []const extension_policy.CanonicalExtensionGrant,
    resource_limits: WasmExtensionResourceLimits,

    pub fn deinit(self: *WasmExtensionPackageManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.package_root);
        allocator.free(self.manifest_path);
        allocator.free(self.policy_lookup_key);
        allocator.free(self.artifact_absolute_path);
        allocator.free(self.artifact_sha256);
        allocator.free(self.capabilities);
        allocator.free(self.resource_limits.tool_scopes);
        self.* = undefined;
    }
};

pub const WasmExtensionPackageError = error{
    ManifestNotFound,
    MalformedJson,
    ExpectedObject,
    ExpectedArray,
    ExpectedString,
    MissingRequiredField,
    UnsupportedSchemaVersion,
    UnsupportedArtifactKind,
    UnsupportedSurface,
    UnsupportedTrustProductSurface,
    UnknownCapability,
    CapabilityNotApproved,
    UnsupportedResourceLimit,
    ExpectedNonNegativeInteger,
    EmptyToolScope,
    EmptyArtifactPath,
    AbsoluteArtifactPath,
    BackslashArtifactPath,
    NonWasmArtifactPath,
    UnnormalizedArtifactPath,
    ArtifactEscapesPackageRoot,
    PackageRootNotFound,
    ArtifactFileNotFound,
    ArtifactNotFile,
    InvalidWasmBinary,
};

pub fn hasWasmExtensionManifest(package_root: []const u8) bool {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}" ++ std.fs.path.sep_str ++ WASM_EXTENSION_MANIFEST_NAME, .{package_root}) catch return false;
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn readWasmExtensionPackagePolicyRequest(
    allocator: std.mem.Allocator,
    package_root: []const u8,
) (WasmExtensionPackageError || error{OutOfMemory})!WasmExtensionPackagePolicyRequest {
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, WASM_EXTENSION_MANIFEST_NAME });
    errdefer allocator.free(manifest_path);
    const manifest_text = std.Io.Dir.readFileAlloc(
        .cwd(),
        std.Io.Threaded.global_single_threaded.io(),
        manifest_path,
        allocator,
        .limited(256 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.ManifestNotFound,
        else => return error.ManifestNotFound,
    };
    defer allocator.free(manifest_text);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_text, .{}) catch return error.MalformedJson;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.ExpectedObject,
    };
    if (scanUnsupportedTrustProductSurface(root)) return error.UnsupportedTrustProductSurface;

    const schema_version = try requiredString(root, "schemaVersion");
    if (!std.mem.eql(u8, schema_version, WASM_EXTENSION_SCHEMA_VERSION)) return error.UnsupportedSchemaVersion;
    const artifact = try requiredObject(root, "artifact");
    const artifact_kind = try requiredString(artifact, "kind");
    if (!std.mem.eql(u8, artifact_kind, "wasm-component")) return error.UnsupportedArtifactKind;
    const artifact_path = try requiredString(artifact, "path");
    if (root.get("tools") != null) return error.UnsupportedSurface;
    const tool = try requiredObject(root, "tool");
    _ = try requiredObject(tool, "inputSchema");
    _ = try requiredObject(tool, "outputSchema");
    if (hasUnsupportedSurface(root)) return error.UnsupportedSurface;

    const capabilities = try readCapabilities(allocator, root);
    errdefer allocator.free(capabilities);
    const resource_limits = try readResourceLimits(allocator, root);
    errdefer allocator.free(resource_limits.tool_scopes);

    const id = try requiredString(root, "id");
    const version = try requiredString(root, "version");
    const policy_lookup_key = try createManifestPolicyLookupKey(allocator, .{
        .schema_version = schema_version,
        .id = id,
        .version = version,
        .package_root = package_root,
        .manifest_path = manifest_path,
        .artifact_path = artifact_path,
    });
    errdefer allocator.free(policy_lookup_key);

    return .{
        .package_root = package_root,
        .manifest_path = manifest_path,
        .policy_lookup_key = policy_lookup_key,
        .schema_version = schema_version,
        .id = id,
        .name = try requiredString(root, "name"),
        .version = version,
        .description = try requiredString(root, "description"),
        .artifact_path = artifact_path,
        .tool_id = try requiredString(tool, "id"),
        .tool_description = try requiredString(tool, "description"),
        .capabilities = capabilities,
        .resource_limits = resource_limits,
    };
}

pub const ManifestPolicyLookupKeyOptions = struct {
    schema_version: []const u8,
    id: []const u8,
    version: []const u8,
    package_root: []const u8,
    manifest_path: []const u8,
    artifact_path: []const u8,
};

pub fn createManifestPolicyLookupKey(allocator: std.mem.Allocator, options: ManifestPolicyLookupKeyOptions) ![]u8 {
    return extension_policy.createWasmExtensionManifestPolicyKey(
        allocator,
        options.schema_version,
        options.id,
        options.version,
        options.manifest_path,
        options.package_root,
        options.artifact_path,
    );
}

pub fn isCanonicalWasmCapability(value: []const u8) bool {
    return extension_policy.isCanonicalExtensionGrant(value);
}

pub fn wasmCapabilityBranch(capability_name: []const u8) []const u8 {
    const grant = extension_policy.parseCanonicalExtensionGrant(capability_name) orelse return capability_name;
    return grant.enforcementBranch().jsonName();
}

pub fn denyRequestedCapabilities(
    requested_capabilities: []const extension_policy.CanonicalExtensionGrant,
    approved_capabilities: []const extension_policy.CanonicalExtensionGrant,
) WasmExtensionPackageError!void {
    for (requested_capabilities) |requested| {
        var approved = false;
        for (approved_capabilities) |candidate| {
            if (candidate == requested) {
                approved = true;
                break;
            }
        }
        if (!approved) return error.CapabilityNotApproved;
    }
}

pub fn validateArtifactPathSyntax(artifact_path: []const u8) WasmExtensionPackageError!void {
    if (artifact_path.len == 0) return error.EmptyArtifactPath;
    if (std.fs.path.isAbsolute(artifact_path)) return error.AbsoluteArtifactPath;
    if (std.mem.indexOfScalar(u8, artifact_path, '\\') != null) return error.BackslashArtifactPath;
    if (!std.mem.endsWith(u8, artifact_path, ".wasm")) return error.NonWasmArtifactPath;
    var iterator = std.mem.splitScalar(u8, artifact_path, '/');
    while (iterator.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) return error.UnnormalizedArtifactPath;
        if (std.mem.eql(u8, component, "..")) return error.ArtifactEscapesPackageRoot;
    }
}

fn readCapabilities(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
) (WasmExtensionPackageError || error{OutOfMemory})![]extension_policy.CanonicalExtensionGrant {
    const value = root.get("capabilities") orelse return allocator.alloc(extension_policy.CanonicalExtensionGrant, 0);
    const array = switch (value) {
        .array => |array| array,
        else => return error.ExpectedArray,
    };
    const capabilities = try allocator.alloc(extension_policy.CanonicalExtensionGrant, array.items.len);
    errdefer allocator.free(capabilities);
    for (array.items, 0..) |entry, index| {
        const name = switch (entry) {
            .string => |text| text,
            else => return error.ExpectedString,
        };
        capabilities[index] = extension_policy.parseCanonicalExtensionGrant(name) orelse return error.UnknownCapability;
    }
    return capabilities;
}

fn readResourceLimits(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
) (WasmExtensionPackageError || error{OutOfMemory})!WasmExtensionResourceLimits {
    const value = root.get("resourceLimits") orelse return .{ .tool_scopes = &.{} };
    return extension_policy.validateResourceLimits(allocator, value) catch |err| switch (err) {
        error.ExpectedObject => error.ExpectedObject,
        error.UnsupportedResourceLimit => error.UnsupportedResourceLimit,
        error.ExpectedNonNegativeInteger => error.ExpectedNonNegativeInteger,
        error.ExpectedArray => error.ExpectedArray,
        error.ExpectedString => error.ExpectedString,
        error.EmptyToolScope => error.EmptyToolScope,
        else => error.ExpectedObject,
    };
}

fn requiredString(object: std.json.ObjectMap, field: []const u8) WasmExtensionPackageError![]const u8 {
    const value = object.get(field) orelse return error.MissingRequiredField;
    return switch (value) {
        .string => |text| text,
        else => error.ExpectedString,
    };
}

fn requiredObject(object: std.json.ObjectMap, field: []const u8) WasmExtensionPackageError!std.json.ObjectMap {
    const value = object.get(field) orelse return error.MissingRequiredField;
    return switch (value) {
        .object => |nested| nested,
        else => error.ExpectedObject,
    };
}

fn hasUnsupportedSurface(root: std.json.ObjectMap) bool {
    inline for (.{ "commands", "widgets", "providers", "editorHooks", "extensions", "shortcuts", "themes", "prompts", "skills" }) |field| {
        if (root.get(field) != null) return true;
    }
    return false;
}

fn scanUnsupportedTrustProductSurface(object: std.json.ObjectMap) bool {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (isUnsupportedTrustProductField(entry.key_ptr.*)) return true;
        if (scanUnsupportedTrustProductValue(entry.value_ptr.*)) return true;
    }
    return false;
}

fn scanUnsupportedTrustProductValue(value: std.json.Value) bool {
    return switch (value) {
        .object => |object| scanUnsupportedTrustProductSurface(object),
        .array => |array| {
            for (array.items) |entry| {
                if (scanUnsupportedTrustProductValue(entry)) return true;
            }
            return false;
        },
        else => false,
    };
}

fn isUnsupportedTrustProductField(field: []const u8) bool {
    inline for (.{ "signature", "signing", "publisher", "marketplace", "approvalUi", "approvalPolicy", "remoteUrl", "remoteWasmUrl", "workflow", "workflowPreset", "wiki", "wikiPreset", "qa", "qaPreset", "review", "reviewPreset", "spawn", "spawnPolicy", "automaticSpawn", "orchestrationPolicy", "modelSelectionUi", "ui", "ux", "slashCommand" }) |candidate| {
        if (std.mem.eql(u8, field, candidate)) return true;
    }
    return false;
}

test "wasm manifest policy key normalizes path separators" {
    const allocator = std.testing.allocator;
    const key = try createManifestPolicyLookupKey(allocator, .{
        .schema_version = WASM_EXTENSION_SCHEMA_VERSION,
        .id = "pkg",
        .version = "1.0.0",
        .package_root = "a\\b",
        .manifest_path = "a\\b\\pi-extension.json",
        .artifact_path = "wasm\\tool.wasm",
    });
    defer allocator.free(key);
    try std.testing.expectEqualStrings(
        "wasm:manifest:pi-extension.v0:pkg:1.0.0:a/b:a/b/pi-extension.json:wasm/tool.wasm",
        key,
    );
}

test "wasm artifact path syntax rejects unsafe paths" {
    try validateArtifactPathSyntax("dist/tool.wasm");
    try std.testing.expectError(error.ArtifactEscapesPackageRoot, validateArtifactPathSyntax("../tool.wasm"));
    try std.testing.expectError(error.NonWasmArtifactPath, validateArtifactPathSyntax("dist/tool.txt"));
}
