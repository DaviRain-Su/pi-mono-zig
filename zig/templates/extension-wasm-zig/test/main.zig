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
