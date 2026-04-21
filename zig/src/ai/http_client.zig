const std = @import("std");

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
};

pub const HttpResponse = struct {
    status: u16,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HttpResponse) void {
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        self.allocator.free(self.body);
    }
};

pub const HttpRequest = struct {
    method: HttpMethod = .POST,
    url: []const u8,
    headers: ?std.StringHashMap([]const u8) = null,
    body: ?[]const u8 = null,
};

/// Simple HTTP client using std.http
pub const HttpClient = struct {
    client: std.http.Client,
    allocator: std.mem.Allocator,
    threaded: *std.Io.Threaded,

    pub fn init(allocator: std.mem.Allocator) !HttpClient {
        const threaded = try allocator.create(std.Io.Threaded);
        threaded.* = std.Io.Threaded.init(allocator, .{});
        return .{
            .client = std.http.Client{ .allocator = allocator, .io = threaded.io() },
            .allocator = allocator,
            .threaded = threaded,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
        self.threaded.deinit();
        self.allocator.destroy(self.threaded);
    }

    pub fn request(self: *HttpClient, req: HttpRequest) !HttpResponse {
        const method_str = switch (req.method) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
        };

        const uri = try std.Uri.parse(req.url);

        var header_buffer: [8192]u8 = undefined;
        var http_request = try self.client.open(
            std.http.Method.parse(method_str),
            uri,
            .{ .server_header_buffer = &header_buffer },
        );
        defer http_request.deinit();

        // Add custom headers
        if (req.headers) |headers| {
            var it = headers.iterator();
            while (it.next()) |entry| {
                http_request.headers.append(entry.key_ptr.*, entry.value_ptr.*) catch {};
            }
        }

        // Set content length if body present
        if (req.body) |body| {
            http_request.headers.content_length = body.len;
        }

        try http_request.send();

        if (req.body) |body| {
            try http_request.writeAll(body);
            try http_request.finish();
        }

        try http_request.wait();

        const status = @intFromEnum(http_request.response.status);
        const body = try http_request.reader().readAllAlloc(self.allocator, 10 * 1024 * 1024);

        const response_headers = std.StringHashMap([]const u8).init(self.allocator);
        // TODO: Parse response headers from request.response

        return HttpResponse{
            .status = status,
            .headers = response_headers,
            .body = body,
            .allocator = self.allocator,
        };
    }
};

test "HttpClient init/deinit" {
    var client = try HttpClient.init(std.testing.allocator);
    client.deinit();
}
