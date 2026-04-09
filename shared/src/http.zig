const std = @import("std");

// =============================================================================
// Safe SSE helpers
// =============================================================================

/// Extract the `data:` payload from an SSE line.
/// Compatible with both `data: {...}` and `data:{...}` (no space after colon).
/// Returns null for non-data lines or `[DONE]` markers.
pub fn parseSseData(line: []const u8) ?[]const u8 {
    const prefix = "data:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    const data = std.mem.trim(u8, if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest, " \r\n");
    if (std.mem.eql(u8, data, "[DONE]")) return null;
    return data;
}

/// Parse a JSON Value from an SSE data payload, allocating it into `arena_gpa`.
///
/// CRITICAL: This function intentionally leaks the `std.json.Parsed` wrapper into the
/// arena and returns only the `std.json.Value`. This prevents the classic segfault
/// where `defer parsed.deinit()` inside an SSE loop frees memory still referenced by
/// string slices pushed to an EventStream.
///
/// Do NOT call `std.json.parseFromSlice` + `defer parsed.deinit()` in SSE loops.
pub fn parseSseJsonLine(data: []const u8, arena_gpa: std.mem.Allocator) !std.json.Value {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena_gpa, data, .{});
    return parsed.value;
}

/// A thin wrapper around std.http.Client for our common patterns.
pub const HttpClient = struct {
    client: std.http.Client,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) HttpClient {
        const client = std.http.Client{ .allocator = gpa };
        return .{ .client = client, .gpa = gpa };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    /// Perform a simple GET request and return the response body as an owned string.
    pub fn get(self: *HttpClient, url: []const u8, headers: ?[]const std.http.Header) ![]const u8 {
        var server_header_buffer: [4096]u8 = undefined;
        const uri = try std.Uri.parse(url);

        var request = try self.client.open(.GET, uri, .{
            .server_header_buffer = &server_header_buffer,
            .extra_headers = headers orelse &.{},
        });
        defer request.deinit();

        try request.send();
        try request.finish();
        try request.wait();

        if (request.response.status.class() != .success) {
            return error.RequestFailed;
        }

        const body = try request.reader().readAllAlloc(self.gpa, 16 * 1024 * 1024);
        return body;
    }

    /// Perform a simple POST request with a string body and return the response body as an owned string.
    pub fn post(self: *HttpClient, url: []const u8, headers: ?[]const std.http.Header, body: []const u8) ![]const u8 {
        var server_header_buffer: [4096]u8 = undefined;
        const uri = try std.Uri.parse(url);

        var request = try self.client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buffer,
            .extra_headers = headers orelse &.{},
        });
        defer request.deinit();

        request.transfer_encoding = .{ .content_length = body.len };
        try request.send();
        try request.writeAll(body);
        try request.finish();
        try request.wait();

        if (request.response.status.class() != .success) {
            return error.RequestFailed;
        }

        const response_body = try request.reader().readAllAlloc(self.gpa, 16 * 1024 * 1024);
        return response_body;
    }
};
