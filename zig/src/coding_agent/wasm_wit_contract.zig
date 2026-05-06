const std = @import("std");
const wasm_manifest = @import("wasm_manifest.zig");

const WIT_PATH = "wit/pi-tool-v0.wit";
const WIT_DOC_PATH = "docs/wasm-tool-wit-v0.md";

fn readRepoFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(128 * 1024));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn expectManifestCapabilityList(documentation: []const u8) !void {
    inline for (@typeInfo(wasm_manifest.Capability).@"enum".fields) |field| {
        const capability: wasm_manifest.Capability = @enumFromInt(field.value);
        try expectContains(documentation, capability.jsonName());
    }
}

test "wasm wit v0 source declares stable tool world exports" {
    const allocator = std.testing.allocator;
    const wit = try readRepoFile(allocator, WIT_PATH);
    defer allocator.free(wit);

    try expectContains(wit, "package pi:extension@0.1.0;");
    try expectContains(wit, "interface tool");
    try expectContains(wit, "metadata: func() -> string;");
    try expectContains(wit, "schema: func() -> string;");
    try expectContains(wit, "execute: func(input-json: string) -> string;");
    try expectContains(wit, "world tool-v0");
    try expectContains(wit, "export tool;");
    try expectNotContains(wit, "import ");
}

test "wasm wit author documentation cross-checks manifest contract" {
    const allocator = std.testing.allocator;
    const wit = try readRepoFile(allocator, WIT_PATH);
    defer allocator.free(wit);
    const documentation = try readRepoFile(allocator, WIT_DOC_PATH);
    defer allocator.free(documentation);

    try expectContains(documentation, WIT_PATH);
    try expectContains(documentation, "package pi:extension@0.1.0");
    try expectContains(documentation, "world tool-v0");

    const exported_functions = [_][]const u8{ "metadata", "schema", "execute" };
    inline for (exported_functions) |function_name| {
        try expectContains(wit, function_name);
        try expectContains(documentation, function_name);
    }

    try expectContains(documentation, "JSON string");
    try expectContains(documentation, wasm_manifest.MANIFEST_FILE_NAME);
    try expectContains(documentation, wasm_manifest.SCHEMA_VERSION);
    try expectContains(documentation, wasm_manifest.ArtifactKind.wasm_component.jsonName());
    try expectContains(documentation, "artifact.kind");
    try expectContains(documentation, "artifact.path");
    try expectContains(documentation, "tool.id");
    try expectContains(documentation, "tool.inputSchema");
    try expectContains(documentation, "tool.outputSchema");
    try expectContains(documentation, "capabilities");
    try expectManifestCapabilityList(documentation);

    try expectContains(documentation, "No v0 host functions");
    try expectContains(documentation, "file");
    try expectContains(documentation, "shell");
    try expectContains(documentation, "network");
    try expectContains(documentation, "environment");
    try expectContains(documentation, "model/session");
    try expectContains(documentation, "UI");
    try expectContains(documentation, "commands");
    try expectContains(documentation, "widgets");
    try expectContains(documentation, "editor hooks");
    try expectContains(documentation, "provider registration");
    try expectContains(documentation, "deferred");
    try expectContains(documentation, "rejected or ignored deterministically");
}
