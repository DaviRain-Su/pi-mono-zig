const std = @import("std");
const sdk = @import("pi-extension-sdk");

test "template execute helper echoes valid input" {
    const allocator = std.testing.allocator;
    const output = try sdk.executeMessageEchoAlloc(allocator, "{\"message\":\"hello\"}", "template.echo");
    defer allocator.free(output);
    try std.testing.expectEqualStrings("{\"ok\":true,\"output\":{\"message\":\"hello\"}}", output);
}

test "template execute helper rejects malformed input" {
    const allocator = std.testing.allocator;
    const output = try sdk.executeMessageEchoAlloc(allocator, "[]", "template.echo");
    defer allocator.free(output);
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input must be a JSON object with a string message field\"}}",
        output,
    );
}

test "template fixed-buffer helper rejects non-object and oversized input" {
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
}

test "template fixed-buffer helper returns bounded overflow envelope" {
    var small_output_buffer: [32]u8 = undefined;
    const output = sdk.executeMessageEcho(&small_output_buffer, "{\"message\":\"hello\"}");
    try std.testing.expectEqualStrings("{\"ok\":false,\"error\":{\"category\":", output);
}
