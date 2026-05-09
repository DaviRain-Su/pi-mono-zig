const std = @import("std");
const common = @import("../tools/common.zig");
const native_manifest = @import("../extensions/native/native_manifest.zig");
const wasm_manifest = @import("../extensions/wasm/wasm_manifest.zig");

pub const LOCKFILE_NAME = "extensions.lock.json";
pub const LOCK_SCHEMA_VERSION = "pi-extension-lock.v0";

pub const Scope = enum {
    user,
    project,

    pub fn jsonName(self: Scope) []const u8 {
        return switch (self) {
            .user => "user",
            .project => "project",
        };
    }
};

pub const Diagnostic = struct {
    category: []u8,
    scope: Scope,
    lockfile_path: []u8,
    phase: []u8,
    message: []u8,
    recovery_hint: []u8,
    source: ?[]u8 = null,
    path: ?[]u8 = null,
    expected: ?[]u8 = null,
    actual: ?[]u8 = null,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.category);
        allocator.free(self.lockfile_path);
        allocator.free(self.phase);
        allocator.free(self.message);
        allocator.free(self.recovery_hint);
        if (self.source) |value| allocator.free(value);
        if (self.path) |value| allocator.free(value);
        if (self.expected) |value| allocator.free(value);
        if (self.actual) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const LockEntry = struct {
    key: []u8,
    scope: Scope,
    source_type: []u8,
    source_identity: []u8,
    source_specifier: ?[]u8 = null,
    manifest_kind: []u8,
    manifest_schema_version: ?[]u8 = null,
    manifest_id: ?[]u8 = null,
    manifest_name: ?[]u8 = null,
    manifest_version: ?[]u8 = null,
    manifest_tool_id: ?[]u8 = null,
    package_root: []u8,
    manifest_path: []u8,
    artifact_kind: ?[]u8 = null,
    artifact_path: ?[]u8 = null,
    artifact_absolute_path: ?[]u8 = null,
    artifact_os: ?[]u8 = null,
    artifact_arch: ?[]u8 = null,
    artifact_sha256: ?[]u8 = null,
    manifest_sha256: ?[]u8 = null,
    package_root_sha256: []u8,

    pub fn deinit(self: *LockEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.source_type);
        allocator.free(self.source_identity);
        if (self.source_specifier) |value| allocator.free(value);
        allocator.free(self.manifest_kind);
        if (self.manifest_schema_version) |value| allocator.free(value);
        if (self.manifest_id) |value| allocator.free(value);
        if (self.manifest_name) |value| allocator.free(value);
        if (self.manifest_version) |value| allocator.free(value);
        if (self.manifest_tool_id) |value| allocator.free(value);
        allocator.free(self.package_root);
        allocator.free(self.manifest_path);
        if (self.artifact_kind) |value| allocator.free(value);
        if (self.artifact_path) |value| allocator.free(value);
        if (self.artifact_absolute_path) |value| allocator.free(value);
        if (self.artifact_os) |value| allocator.free(value);
        if (self.artifact_arch) |value| allocator.free(value);
        if (self.artifact_sha256) |value| allocator.free(value);
        if (self.manifest_sha256) |value| allocator.free(value);
        allocator.free(self.package_root_sha256);
        self.* = undefined;
    }

    pub fn clone(self: LockEntry, allocator: std.mem.Allocator) !LockEntry {
        return .{
            .key = try allocator.dupe(u8, self.key),
            .scope = self.scope,
            .source_type = try allocator.dupe(u8, self.source_type),
            .source_identity = try allocator.dupe(u8, self.source_identity),
            .source_specifier = if (self.source_specifier) |value| try allocator.dupe(u8, value) else null,
            .manifest_kind = try allocator.dupe(u8, self.manifest_kind),
            .manifest_schema_version = if (self.manifest_schema_version) |value| try allocator.dupe(u8, value) else null,
            .manifest_id = if (self.manifest_id) |value| try allocator.dupe(u8, value) else null,
            .manifest_name = if (self.manifest_name) |value| try allocator.dupe(u8, value) else null,
            .manifest_version = if (self.manifest_version) |value| try allocator.dupe(u8, value) else null,
            .manifest_tool_id = if (self.manifest_tool_id) |value| try allocator.dupe(u8, value) else null,
            .package_root = try allocator.dupe(u8, self.package_root),
            .manifest_path = try allocator.dupe(u8, self.manifest_path),
            .artifact_kind = if (self.artifact_kind) |value| try allocator.dupe(u8, value) else null,
            .artifact_path = if (self.artifact_path) |value| try allocator.dupe(u8, value) else null,
            .artifact_absolute_path = if (self.artifact_absolute_path) |value| try allocator.dupe(u8, value) else null,
            .artifact_os = if (self.artifact_os) |value| try allocator.dupe(u8, value) else null,
            .artifact_arch = if (self.artifact_arch) |value| try allocator.dupe(u8, value) else null,
            .artifact_sha256 = if (self.artifact_sha256) |value| try allocator.dupe(u8, value) else null,
            .manifest_sha256 = if (self.manifest_sha256) |value| try allocator.dupe(u8, value) else null,
            .package_root_sha256 = try allocator.dupe(u8, self.package_root_sha256),
        };
    }
};

pub const LoadResult = struct {
    entries: []LockEntry,
    diagnostic: ?Diagnostic = null,

    pub fn deinit(self: *LoadResult, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
        if (self.diagnostic) |*diagnostic| diagnostic.deinit(allocator);
        self.* = undefined;
    }
};

pub fn lockfilePath(
    allocator: std.mem.Allocator,
    scope: Scope,
    cwd: []const u8,
    agent_dir: []const u8,
) ![]u8 {
    return switch (scope) {
        .user => std.fs.path.join(allocator, &[_][]const u8{ agent_dir, LOCKFILE_NAME }),
        .project => std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", LOCKFILE_NAME }),
    };
}

pub fn createWasmLockEntry(
    allocator: std.mem.Allocator,
    scope: Scope,
    source_identity: []const u8,
    manifest: *const wasm_manifest.Manifest,
) !LockEntry {
    const key = try std.fmt.allocPrint(allocator, "local:{s}", .{source_identity});
    errdefer allocator.free(key);
    return .{
        .key = key,
        .scope = scope,
        .source_type = try allocator.dupe(u8, "local"),
        .source_identity = try allocator.dupe(u8, source_identity),
        .manifest_kind = try allocator.dupe(u8, "wasm-extension"),
        .manifest_schema_version = try allocator.dupe(u8, manifest.schema_version),
        .manifest_id = try allocator.dupe(u8, manifest.id),
        .manifest_name = try allocator.dupe(u8, manifest.name),
        .manifest_version = try allocator.dupe(u8, manifest.version),
        .manifest_tool_id = try allocator.dupe(u8, manifest.tool_id),
        .package_root = try allocator.dupe(u8, manifest.package_root),
        .manifest_path = try allocator.dupe(u8, manifest.manifest_path),
        .artifact_kind = try allocator.dupe(u8, "wasm-component"),
        .artifact_path = try allocator.dupe(u8, manifest.artifact_path),
        .artifact_absolute_path = try allocator.dupe(u8, manifest.artifact_absolute_path),
        .artifact_sha256 = try allocator.dupe(u8, manifest.artifact_sha256),
        .package_root_sha256 = try allocator.dupe(u8, manifest.package_root_sha256),
    };
}

pub fn createNativeLockEntry(
    allocator: std.mem.Allocator,
    scope: Scope,
    source_identity: []const u8,
    manifest: *const native_manifest.Manifest,
) !LockEntry {
    const key = try std.fmt.allocPrint(allocator, "local:{s}", .{source_identity});
    errdefer allocator.free(key);
    return .{
        .key = key,
        .scope = scope,
        .source_type = try allocator.dupe(u8, "local"),
        .source_identity = try allocator.dupe(u8, source_identity),
        .manifest_kind = try allocator.dupe(u8, "native-extension"),
        .manifest_schema_version = try allocator.dupe(u8, manifest.schema_version),
        .manifest_id = try allocator.dupe(u8, manifest.id),
        .manifest_name = try allocator.dupe(u8, manifest.name),
        .manifest_version = try allocator.dupe(u8, manifest.version),
        .manifest_tool_id = try allocator.dupe(u8, manifest.tool_name),
        .package_root = try allocator.dupe(u8, manifest.package_root),
        .manifest_path = try allocator.dupe(u8, manifest.manifest_path),
        .artifact_kind = try allocator.dupe(u8, native_manifest.ARTIFACT_KIND),
        .artifact_path = try allocator.dupe(u8, manifest.selected_artifact_path),
        .artifact_absolute_path = try allocator.dupe(u8, manifest.selected_artifact_absolute_path),
        .artifact_os = try allocator.dupe(u8, manifest.selected_artifact_os),
        .artifact_arch = try allocator.dupe(u8, manifest.selected_artifact_arch),
        .artifact_sha256 = try allocator.dupe(u8, manifest.selected_artifact_sha256),
        .manifest_sha256 = try allocator.dupe(u8, manifest.manifest_sha256),
        .package_root_sha256 = try allocator.dupe(u8, manifest.package_root_sha256),
    };
}

pub fn entriesEqual(left: LockEntry, right: LockEntry) bool {
    return std.mem.eql(u8, left.key, right.key) and
        left.scope == right.scope and
        optEql(left.source_specifier, right.source_specifier) and
        std.mem.eql(u8, left.source_type, right.source_type) and
        std.mem.eql(u8, left.source_identity, right.source_identity) and
        std.mem.eql(u8, left.manifest_kind, right.manifest_kind) and
        optEql(left.manifest_schema_version, right.manifest_schema_version) and
        optEql(left.manifest_id, right.manifest_id) and
        optEql(left.manifest_name, right.manifest_name) and
        optEql(left.manifest_version, right.manifest_version) and
        optEql(left.manifest_tool_id, right.manifest_tool_id) and
        std.mem.eql(u8, left.package_root, right.package_root) and
        std.mem.eql(u8, left.manifest_path, right.manifest_path) and
        optEql(left.artifact_kind, right.artifact_kind) and
        optEql(left.artifact_path, right.artifact_path) and
        optEql(left.artifact_absolute_path, right.artifact_absolute_path) and
        optEql(left.artifact_os, right.artifact_os) and
        optEql(left.artifact_arch, right.artifact_arch) and
        optEql(left.artifact_sha256, right.artifact_sha256) and
        optEql(left.manifest_sha256, right.manifest_sha256) and
        std.mem.eql(u8, left.package_root_sha256, right.package_root_sha256);
}

fn optEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return std.mem.eql(u8, left.?, right.?);
}

pub fn readLockfile(
    allocator: std.mem.Allocator,
    io: std.Io,
    scope: Scope,
    path: []const u8,
    phase: []const u8,
) !LoadResult {
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .entries = try allocator.alloc(LockEntry, 0) },
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Malformed extension provenance lockfile: {s}", .{@errorName(err)});
        defer allocator.free(message);
        return .{
            .entries = try allocator.alloc(LockEntry, 0),
            .diagnostic = try makeDiagnostic(allocator, "malformed_lockfile", scope, path, phase, "$", null, null, message),
        };
    };
    defer parsed.deinit();

    const unsupported_path = try scanUnsupportedTrustSurface(allocator, parsed.value, "$");
    defer if (unsupported_path) |value| allocator.free(value);
    if (unsupported_path) |bad_path| {
        const message = try std.fmt.allocPrint(allocator, "Malformed extension provenance lockfile: {s}: unsupported v0 trust surface", .{bad_path});
        defer allocator.free(message);
        return .{
            .entries = try allocator.alloc(LockEntry, 0),
            .diagnostic = try makeDiagnostic(allocator, "malformed_lockfile", scope, path, phase, bad_path, null, null, message),
        };
    }

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return malformed(allocator, scope, path, phase, "$", "expected object", null, null),
    };
    const schema_value = root.get("schemaVersion") orelse return malformed(allocator, scope, path, phase, "$.schemaVersion", "missing required field", null, null);
    if (schema_value != .string) return malformed(allocator, scope, path, phase, "$.schemaVersion", "expected string", null, null);
    if (!std.mem.eql(u8, schema_value.string, LOCK_SCHEMA_VERSION)) {
        const message = try std.fmt.allocPrint(allocator, "$.schemaVersion: unsupported schema version \"{s}\"; expected " ++ LOCK_SCHEMA_VERSION, .{schema_value.string});
        defer allocator.free(message);
        return malformed(allocator, scope, path, phase, "$.schemaVersion", message, LOCK_SCHEMA_VERSION, schema_value.string);
    }
    const entries_value = root.get("entries") orelse return malformed(allocator, scope, path, phase, "$.entries", "missing required field", null, null);
    if (entries_value != .array) return malformed(allocator, scope, path, phase, "$.entries", "expected array", null, null);

    var entries = std.ArrayList(LockEntry).empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    for (entries_value.array.items, 0..) |item, index| {
        const entry = parseEntry(allocator, item, index) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "Malformed extension provenance lockfile: {s}", .{@errorName(err)});
            defer allocator.free(message);
            return .{
                .entries = try allocator.alloc(LockEntry, 0),
                .diagnostic = try makeDiagnostic(allocator, "malformed_lockfile", scope, path, phase, "$.entries", null, null, message),
            };
        };
        try entries.append(allocator, entry);
    }
    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

fn malformed(
    allocator: std.mem.Allocator,
    scope: Scope,
    path: []const u8,
    phase: []const u8,
    json_path: []const u8,
    reason: []const u8,
    expected: ?[]const u8,
    actual: ?[]const u8,
) !LoadResult {
    const message = try std.fmt.allocPrint(allocator, "Malformed extension provenance lockfile: {s}: {s}", .{ json_path, reason });
    defer allocator.free(message);
    return .{
        .entries = try allocator.alloc(LockEntry, 0),
        .diagnostic = try makeDiagnostic(allocator, "malformed_lockfile", scope, path, phase, json_path, expected, actual, message),
    };
}

fn parseEntry(allocator: std.mem.Allocator, value: std.json.Value, index: usize) !LockEntry {
    if (value != .object) return error.InvalidLockEntry;
    const object = value.object;
    const path = try std.fmt.allocPrint(allocator, "$.entries[{d}]", .{index});
    defer allocator.free(path);
    const key = try requiredStringOwned(allocator, object, path, "key");
    errdefer allocator.free(key);
    const scope_text = try requiredStringOwned(allocator, object, path, "scope");
    defer allocator.free(scope_text);
    const scope = if (std.mem.eql(u8, scope_text, "user"))
        Scope.user
    else if (std.mem.eql(u8, scope_text, "project"))
        Scope.project
    else
        return error.InvalidLockEntry;
    const source = object.get("source") orelse return error.InvalidLockEntry;
    if (source != .object) return error.InvalidLockEntry;
    const source_type = try requiredStringOwned(allocator, source.object, "source", "type");
    errdefer allocator.free(source_type);
    const source_identity = try requiredStringOwned(allocator, source.object, "source", "identity");
    errdefer allocator.free(source_identity);
    const source_specifier = try optionalStringOwned(allocator, source.object, "specifier");
    errdefer if (source_specifier) |owned| allocator.free(owned);
    const manifest = object.get("manifest") orelse return error.InvalidLockEntry;
    if (manifest != .object) return error.InvalidLockEntry;
    const manifest_kind = try requiredStringOwned(allocator, manifest.object, "manifest", "kind");
    errdefer allocator.free(manifest_kind);
    const package_root = try requiredStringOwned(allocator, object, path, "packageRoot");
    errdefer allocator.free(package_root);
    const manifest_path = try requiredStringOwned(allocator, object, path, "manifestPath");
    errdefer allocator.free(manifest_path);
    const digests = object.get("digests") orelse return error.InvalidLockEntry;
    if (digests != .object) return error.InvalidLockEntry;
    const package_root_sha256 = try requiredStringOwned(allocator, digests.object, "digests", "packageRootSha256");
    errdefer allocator.free(package_root_sha256);
    if (!isSha256(package_root_sha256)) return error.InvalidLockEntry;

    var entry = LockEntry{
        .key = key,
        .scope = scope,
        .source_type = source_type,
        .source_identity = source_identity,
        .source_specifier = source_specifier,
        .manifest_kind = manifest_kind,
        .manifest_schema_version = try optionalStringOwned(allocator, manifest.object, "schemaVersion"),
        .manifest_id = try optionalStringOwned(allocator, manifest.object, "id"),
        .manifest_name = try optionalStringOwned(allocator, manifest.object, "name"),
        .manifest_version = try optionalStringOwned(allocator, manifest.object, "version"),
        .manifest_tool_id = try optionalStringOwned(allocator, manifest.object, "toolId"),
        .package_root = package_root,
        .manifest_path = manifest_path,
        .package_root_sha256 = package_root_sha256,
    };
    errdefer entry.deinit(allocator);

    if (object.get("artifact")) |artifact| {
        if (artifact != .object) return error.InvalidLockEntry;
        entry.artifact_kind = try requiredStringOwned(allocator, artifact.object, "artifact", "kind");
        entry.artifact_path = try requiredStringOwned(allocator, artifact.object, "artifact", "path");
        entry.artifact_absolute_path = try requiredStringOwned(allocator, artifact.object, "artifact", "absolutePath");
        entry.artifact_os = try optionalStringOwned(allocator, artifact.object, "os");
        entry.artifact_arch = try optionalStringOwned(allocator, artifact.object, "arch");
        entry.artifact_sha256 = try requiredStringOwned(allocator, artifact.object, "artifact", "sha256");
        if (!isSha256(entry.artifact_sha256.?)) return error.InvalidLockEntry;
    }
    entry.manifest_sha256 = try optionalStringOwned(allocator, digests.object, "manifestSha256");
    if (entry.manifest_sha256) |manifest_sha256| if (!isSha256(manifest_sha256)) return error.InvalidLockEntry;
    return entry;
}

fn requiredStringOwned(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    path: []const u8,
    field: []const u8,
) ![]u8 {
    _ = path;
    const value = object.get(field) orelse return error.InvalidLockEntry;
    if (value != .string) return error.InvalidLockEntry;
    return try allocator.dupe(u8, value.string);
}

fn optionalStringOwned(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field: []const u8,
) !?[]u8 {
    const value = object.get(field) orelse return null;
    if (value != .string) return error.InvalidLockEntry;
    return try allocator.dupe(u8, value.string);
}

pub fn writeEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    scope: Scope,
    path: []const u8,
    entry: LockEntry,
) !void {
    var loaded = try readLockfile(allocator, io, scope, path, "write");
    defer loaded.deinit(allocator);
    if (loaded.diagnostic != null) return error.MalformedLockfile;

    var entries = std.ArrayList(LockEntry).empty;
    defer {
        for (entries.items) |*item| item.deinit(allocator);
        entries.deinit(allocator);
    }
    var replaced = false;
    for (loaded.entries) |existing| {
        if (std.mem.eql(u8, existing.key, entry.key)) {
            try entries.append(allocator, try entry.clone(allocator));
            replaced = true;
        } else {
            try entries.append(allocator, try existing.clone(allocator));
        }
    }
    if (!replaced) try entries.append(allocator, try entry.clone(allocator));
    std.mem.sort(LockEntry, entries.items, {}, entryLessThan);
    const serialized = try serialize(allocator, entries.items);
    defer allocator.free(serialized);
    try writeAtomically(allocator, io, path, serialized);
}

pub fn removeEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    scope: Scope,
    path: []const u8,
    key: []const u8,
) !bool {
    var loaded = try readLockfile(allocator, io, scope, path, "write");
    defer loaded.deinit(allocator);
    if (loaded.diagnostic != null) return error.MalformedLockfile;

    var entries = std.ArrayList(LockEntry).empty;
    defer {
        for (entries.items) |*item| item.deinit(allocator);
        entries.deinit(allocator);
    }
    var removed = false;
    for (loaded.entries) |existing| {
        if (std.mem.eql(u8, existing.key, key)) {
            removed = true;
            continue;
        }
        try entries.append(allocator, try existing.clone(allocator));
    }
    if (!removed) return false;
    std.mem.sort(LockEntry, entries.items, {}, entryLessThan);
    const serialized = try serialize(allocator, entries.items);
    defer allocator.free(serialized);
    try writeAtomically(allocator, io, path, serialized);
    return true;
}

fn entryLessThan(_: void, lhs: LockEntry, rhs: LockEntry) bool {
    return std.mem.lessThan(u8, lhs.key, rhs.key);
}

fn serialize(allocator: std.mem.Allocator, entries: []const LockEntry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  \"schemaVersion\": ");
    try appendJsonString(allocator, &out, LOCK_SCHEMA_VERSION);
    try out.appendSlice(allocator, ",\n  \"entries\": [");
    for (entries, 0..) |entry, index| {
        if (index == 0) {
            try out.appendSlice(allocator, "\n");
        } else {
            try out.appendSlice(allocator, ",\n");
        }
        try appendEntryJson(allocator, &out, entry);
    }
    if (entries.len > 0) try out.appendSlice(allocator, "\n  ");
    try out.appendSlice(allocator, "]\n}\n");
    return out.toOwnedSlice(allocator);
}

fn appendEntryJson(allocator: std.mem.Allocator, out: *std.ArrayList(u8), entry: LockEntry) !void {
    try out.appendSlice(allocator, "    {\n      \"key\": ");
    try appendJsonString(allocator, out, entry.key);
    try out.appendSlice(allocator, ",\n      \"scope\": ");
    try appendJsonString(allocator, out, entry.scope.jsonName());
    try out.appendSlice(allocator, ",\n      \"source\": {\n        \"type\": ");
    try appendJsonString(allocator, out, entry.source_type);
    try out.appendSlice(allocator, ",\n        \"identity\": ");
    try appendJsonString(allocator, out, entry.source_identity);
    if (entry.source_specifier) |specifier| {
        try out.appendSlice(allocator, ",\n        \"specifier\": ");
        try appendJsonString(allocator, out, specifier);
    }
    try out.appendSlice(allocator, "\n      },\n      \"manifest\": {\n        \"kind\": ");
    try appendJsonString(allocator, out, entry.manifest_kind);
    try appendOptionalJsonField(allocator, out, "schemaVersion", entry.manifest_schema_version);
    try appendOptionalJsonField(allocator, out, "id", entry.manifest_id);
    try appendOptionalJsonField(allocator, out, "name", entry.manifest_name);
    try appendOptionalJsonField(allocator, out, "version", entry.manifest_version);
    try appendOptionalJsonField(allocator, out, "toolId", entry.manifest_tool_id);
    try out.appendSlice(allocator, "\n      },\n      \"packageRoot\": ");
    try appendJsonString(allocator, out, entry.package_root);
    try out.appendSlice(allocator, ",\n      \"manifestPath\": ");
    try appendJsonString(allocator, out, entry.manifest_path);
    if (entry.artifact_kind) |artifact_kind| {
        try out.appendSlice(allocator, ",\n      \"artifact\": {\n        \"kind\": ");
        try appendJsonString(allocator, out, artifact_kind);
        try out.appendSlice(allocator, ",\n        \"path\": ");
        try appendJsonString(allocator, out, entry.artifact_path.?);
        try out.appendSlice(allocator, ",\n        \"absolutePath\": ");
        try appendJsonString(allocator, out, entry.artifact_absolute_path.?);
        if (entry.artifact_os) |os| {
            try out.appendSlice(allocator, ",\n        \"os\": ");
            try appendJsonString(allocator, out, os);
        }
        if (entry.artifact_arch) |arch| {
            try out.appendSlice(allocator, ",\n        \"arch\": ");
            try appendJsonString(allocator, out, arch);
        }
        try out.appendSlice(allocator, ",\n        \"sha256\": ");
        try appendJsonString(allocator, out, entry.artifact_sha256.?);
        try out.appendSlice(allocator, "\n      }");
    }
    try out.appendSlice(allocator, ",\n      \"digests\": {\n        \"packageRootSha256\": ");
    try appendJsonString(allocator, out, entry.package_root_sha256);
    if (entry.manifest_sha256) |manifest_sha256| {
        try out.appendSlice(allocator, ",\n        \"manifestSha256\": ");
        try appendJsonString(allocator, out, manifest_sha256);
    }
    try out.appendSlice(allocator, "\n      }\n    }");
}

fn appendOptionalJsonField(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    value: ?[]const u8,
) !void {
    const actual = value orelse return;
    try out.appendSlice(allocator, ",\n        ");
    try appendJsonString(allocator, out, name);
    try out.appendSlice(allocator, ": ");
    try appendJsonString(allocator, out, actual);
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const quoted = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = value }, .{});
    defer allocator.free(quoted);
    try out.appendSlice(allocator, quoted);
}

fn writeAtomically(allocator: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    try std.Io.Dir.createDirPath(.cwd(), io, parent);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp_path);
    try common.writeFileAbsolute(io, temp_path, bytes, true);
    std.Io.Dir.renameAbsolute(temp_path, path, io) catch |err| {
        std.Io.Dir.deleteFileAbsolute(io, temp_path) catch {};
        return err;
    };
}

fn makeDiagnostic(
    allocator: std.mem.Allocator,
    category: []const u8,
    scope: Scope,
    lockfile_path: []const u8,
    phase: []const u8,
    path: ?[]const u8,
    expected: ?[]const u8,
    actual: ?[]const u8,
    message: []const u8,
) !Diagnostic {
    return .{
        .category = try allocator.dupe(u8, category),
        .scope = scope,
        .lockfile_path = try allocator.dupe(u8, lockfile_path),
        .phase = try allocator.dupe(u8, phase),
        .message = try allocator.dupe(u8, message),
        .recovery_hint = try allocator.dupe(u8, "Run install or update for the package to refresh trusted extension provenance."),
        .path = if (path) |value| try allocator.dupe(u8, value) else null,
        .expected = if (expected) |value| try allocator.dupe(u8, value) else null,
        .actual = if (actual) |value| try allocator.dupe(u8, value) else null,
    };
}

const unsupported_trust_surface_fields = [_][]const u8{
    "signature",
    "publisher",
    "marketplace",
    "approvalUi",
    "remoteWasmUrl",
};

fn scanUnsupportedTrustSurface(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    path: []const u8,
) !?[]u8 {
    switch (value) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const field_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, entry.key_ptr.* });
                defer allocator.free(field_path);
                inline for (unsupported_trust_surface_fields) |field| {
                    if (std.mem.eql(u8, entry.key_ptr.*, field)) return try allocator.dupe(u8, field_path);
                }
                if (try scanUnsupportedTrustSurface(allocator, entry.value_ptr.*, field_path)) |nested| return nested;
            }
        },
        .array => |array| {
            for (array.items, 0..) |entry, index| {
                const item_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index });
                defer allocator.free(item_path);
                if (try scanUnsupportedTrustSurface(allocator, entry, item_path)) |nested| return nested;
            }
        },
        else => {},
    }
    return null;
}

fn isSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

fn makeTestEntry(allocator: std.mem.Allocator, key_suffix: []const u8, package_root: []const u8) !LockEntry {
    const key = try std.fmt.allocPrint(allocator, "local:{s}", .{key_suffix});
    errdefer allocator.free(key);
    return .{
        .key = key,
        .scope = .user,
        .source_type = try allocator.dupe(u8, "local"),
        .source_identity = try allocator.dupe(u8, key_suffix),
        .manifest_kind = try allocator.dupe(u8, "wasm-extension"),
        .manifest_schema_version = try allocator.dupe(u8, "pi-extension.v0"),
        .manifest_id = try allocator.dupe(u8, "com.example.lock"),
        .manifest_name = try allocator.dupe(u8, "Lock Example"),
        .manifest_version = try allocator.dupe(u8, "0.1.0"),
        .manifest_tool_id = try allocator.dupe(u8, "example.lock"),
        .package_root = try allocator.dupe(u8, package_root),
        .manifest_path = try std.fs.path.join(allocator, &.{ package_root, "pi-extension.json" }),
        .artifact_kind = try allocator.dupe(u8, "wasm-component"),
        .artifact_path = try allocator.dupe(u8, "wasm/example.wasm"),
        .artifact_absolute_path = try std.fs.path.join(allocator, &.{ package_root, "wasm/example.wasm" }),
        .artifact_sha256 = try allocator.dupe(u8, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        .package_root_sha256 = try allocator.dupe(u8, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
    };
}

fn makeAbsoluteTestPath(allocator: std.mem.Allocator, tmp: anytype, relative: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, relative });
}

test "provenance lockfile writes sorted schema v0 entries and reads them back" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    const agent_dir = try makeAbsoluteTestPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const path = try lockfilePath(allocator, .user, "/unused/project", agent_dir);
    defer allocator.free(path);

    var second = try makeTestEntry(allocator, "z-second", agent_dir);
    defer second.deinit(allocator);
    var first = try makeTestEntry(allocator, "a-first", agent_dir);
    defer first.deinit(allocator);
    try writeEntry(allocator, std.testing.io, .user, path, second);
    try writeEntry(allocator, std.testing.io, .user, path, first);

    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"schemaVersion\": \"pi-extension-lock.v0\"") != null);
    const first_index = std.mem.indexOf(u8, bytes, "local:a-first").?;
    const second_index = std.mem.indexOf(u8, bytes, "local:z-second").?;
    try std.testing.expect(first_index < second_index);

    var loaded = try readLockfile(allocator, std.testing.io, .user, path, "resolve");
    defer loaded.deinit(allocator);
    try std.testing.expect(loaded.diagnostic == null);
    try std.testing.expectEqual(@as(usize, 2), loaded.entries.len);
    try std.testing.expectEqualStrings("local:a-first", loaded.entries[0].key);
    try std.testing.expectEqualStrings("local:z-second", loaded.entries[1].key);
}

test "provenance lockfile denies malformed and unsupported schemas" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agent");
    const agent_dir = try makeAbsoluteTestPath(allocator, tmp, "agent");
    defer allocator.free(agent_dir);
    const path = try lockfilePath(allocator, .user, "/unused/project", agent_dir);
    defer allocator.free(path);

    try common.writeFileAbsolute(std.testing.io, path,
        \\{ "schemaVersion": "pi-extension-lock.v999", "entries": [] }
    , true);
    var future = try readLockfile(allocator, std.testing.io, .user, path, "resolve");
    defer future.deinit(allocator);
    try std.testing.expect(future.diagnostic != null);
    try std.testing.expectEqualStrings("malformed_lockfile", future.diagnostic.?.category);
    try std.testing.expectEqualStrings("$.schemaVersion", future.diagnostic.?.path.?);

    try common.writeFileAbsolute(std.testing.io, path, "{ malformed", true);
    var malformed_result = try readLockfile(allocator, std.testing.io, .user, path, "resolve");
    defer malformed_result.deinit(allocator);
    try std.testing.expect(malformed_result.diagnostic != null);
    try std.testing.expectEqualStrings("malformed_lockfile", malformed_result.diagnostic.?.category);
}
