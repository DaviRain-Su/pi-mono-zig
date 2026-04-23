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
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const HttpResponse) void {
        self.allocator.free(self.body);
    }
};

pub const HttpRequest = struct {
    method: HttpMethod = .POST,
    url: []const u8,
    headers: ?std.StringHashMap([]const u8) = null,
    body: ?[]const u8 = null,
};

/// Simple HTTP client using std.http.Client.fetch
pub const HttpClient = struct {
    client: std.http.Client,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !HttpClient {
        return .{
            .client = std.http.Client{ .allocator = allocator, .io = io },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    pub fn request(self: *HttpClient, req: HttpRequest) !HttpResponse {
        const method: std.http.Method = switch (req.method) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
            .PATCH => .PATCH,
        };

        // Collect headers into http.Header array
        var extra_headers: std.ArrayList(std.http.Header) = .empty;
        defer extra_headers.deinit(self.allocator);

        if (req.headers) |headers| {
            var it = headers.iterator();
            while (it.next()) |entry| {
                try extra_headers.append(self.allocator, .{
                    .name = entry.key_ptr.*,
                    .value = entry.value_ptr.*,
                });
            }
        }

        // Allocating response writer
        var response_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_writer.deinit();

        const result = try self.client.fetch(.{
            .location = .{ .url = req.url },
            .method = method,
            .payload = req.body,
            .extra_headers = extra_headers.items,
            .response_writer = &response_writer.writer,
        });

        const body_copy = try self.allocator.dupe(u8, response_writer.written());

        return HttpResponse{
            .status = @intFromEnum(result.status),
            .body = body_copy,
            .allocator = self.allocator,
        };
    }
};

test "HttpClient init/deinit" {
    var client = try HttpClient.init(std.testing.allocator, std.testing.io);
    client.deinit();
}
