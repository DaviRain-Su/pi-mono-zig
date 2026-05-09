const std = @import("std");
const sdk = @import("pi-native-extension-sdk");

const expected_manifest = sdk.ExpectedManifest{
    .id = "com.pi.native.template.echo",
    .name = "Pi Native Zig Echo Template",
    .version = "0.1.0",
    .runtime_descriptor = "native://dynamic/com.pi.native.template.echo",
    .tool_name = "native.echo",
    .timeout_ms = 30000,
    .output_bytes = 65536,
};

test "template local author validation accepts manifest metadata" {
    const allocator = std.testing.allocator;
    const manifest = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, "pi-extension.json", allocator, .limited(256 * 1024));
    defer allocator.free(manifest);

    const result = try sdk.validateManifestTextAlloc(allocator, manifest, expected_manifest);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"schemaVersion\":\"pi-extension.v1\",\"runtime\":\"native\",\"abi\":\"pi_native_extension_abi_v0\",\"packageId\":\"com.pi.native.template.echo\",\"toolName\":\"native.echo\"}",
        result,
    );
}

test "template local author validation rejects private loader fields" {
    const allocator = std.testing.allocator;
    const invalid_manifest =
        \\{
        \\  "schemaVersion": "pi-extension.v1",
        \\  "id": "com.pi.native.template.echo",
        \\  "name": "Pi Native Zig Echo Template",
        \\  "version": "0.1.0",
        \\  "runtime": {
        \\    "kind": "native",
        \\    "entrypoint": {
        \\      "descriptor": "native://dynamic/com.pi.native.template.echo",
        \\      "dynamic_library_path": "native/libpi_native_template_echo.dylib"
        \\    },
        \\    "abi": {"name": "pi_native_extension_abi_v0", "minVersion": 0, "maxVersion": 0},
        \\    "limits": {"timeoutMs": 30000, "outputBytes": 65536, "toolScopes": ["native.echo"]}
        \\  },
        \\  "tools": [{"name": "native.echo", "inputSchema": {}, "outputSchema": {}}],
        \\  "capabilities": {"exports": [{"id": "native.echo", "kind": "tool", "version": "0.1.0"}], "imports": []}
        \\}
    ;
    const result = try sdk.validateManifestTextAlloc(allocator, invalid_manifest, expected_manifest);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"diagnostics\":[{\"severity\":\"error\",\"runtime\":\"native\",\"path\":\"$.runtime.entrypoint.dynamic_library_path\",\"code\":\"manifest.unsupported_native_entrypoint_field\",\"message\":\"use the public native descriptor boundary, not direct loader/runtime internals\"}]}",
        result,
    );
}

test "template execute helper echoes valid input and rejects malformed input" {
    const allocator = std.testing.allocator;
    const output = try sdk.executeMessageEchoAlloc(allocator, "{\"message\":\"hello\"}");
    defer allocator.free(output);
    try std.testing.expectEqualStrings("{\"ok\":true,\"output\":{\"message\":\"hello\"}}", output);

    const invalid = try sdk.executeMessageEchoAlloc(allocator, "[]");
    defer allocator.free(invalid);
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input must be a JSON object with a string message field\"}}",
        invalid,
    );
}

test "template fixed-buffer helper enforces bounded input and output" {
    var output_buffer: [sdk.MAX_EXECUTE_OUTPUT_BYTES]u8 = undefined;

    const non_object = sdk.executeMessageEcho(&output_buffer, "[]");
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input must be a JSON object with a string message field\"}}",
        non_object,
    );

    const allocator = std.testing.allocator;
    const oversized_input = try allocator.alloc(u8, sdk.MAX_EXECUTE_INPUT_BYTES + 1);
    defer allocator.free(oversized_input);
    @memset(oversized_input, ' ');
    const oversized = sdk.executeMessageEcho(&output_buffer, oversized_input);
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input exceeds maximum size\"}}",
        oversized,
    );

    var small_output_buffer: [32]u8 = undefined;
    const overflow = sdk.executeMessageEcho(&small_output_buffer, "{\"message\":\"hello\"}");
    try std.testing.expectEqualStrings("{\"ok\":false,\"error\":{\"category\":", overflow);
}
