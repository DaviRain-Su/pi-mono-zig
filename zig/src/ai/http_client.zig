const std = @import("std");

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
};

pub const HttpError = error{
    ConnectionRefused,
    ConnectionReset,
    Timeout,
    RequestAborted,
    InvalidUrl,
    UnknownHost,
    TlsFailure,
    TooManyRedirects,
    NetworkUnreachable,
    ServerError,
    ClientError,
    UnexpectedRedirect,
};

pub const HttpResponse = struct {
    status: u16,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const HttpResponse) void {
        self.allocator.free(self.body);
    }
};

/// A streaming response that yields lines from a buffered body.
/// Owns the response body and provides line-by-line iteration.
pub const StreamingResponse = struct {
    status: u16,
    body: []const u8,
    pos: usize = 0,
    buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    done: bool = false,

    pub fn deinit(self: *StreamingResponse) void {
        self.allocator.free(self.body);
        self.buffer.deinit(self.allocator);
    }

    /// Read the next line from the buffered body. Returns a slice into an
    /// internal buffer that is valid until the next call to readLine.
    pub fn readLine(self: *StreamingResponse) !?[]const u8 {
        if (self.done) return null;
        if (self.pos >= self.body.len) {
            self.done = true;
            return null;
        }

        self.buffer.clearRetainingCapacity();

        while (self.pos < self.body.len) {
            const byte = self.body[self.pos];
            self.pos += 1;

            if (byte == '\n') {
                // Strip \r if present
                if (self.buffer.items.len > 0 and self.buffer.items[self.buffer.items.len - 1] == '\r') {
                    self.buffer.shrinkRetainingCapacity(self.buffer.items.len - 1);
                }
                return self.buffer.items;
            }

            try self.buffer.append(self.allocator, byte);
        }

        // Reached end without newline
        self.done = true;
        return self.buffer.items;
    }

    /// Consume the rest of the stream into a single buffer.
    pub fn readAll(self: *StreamingResponse, allocator: std.mem.Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        while (try self.readLine()) |line| {
            try result.appendSlice(allocator, line);
            try result.append(allocator, '\n');
        }

        return result.toOwnedSlice(allocator);
    }
};

pub const HttpRequest = struct {
    method: HttpMethod = .POST,
    url: []const u8,
    headers: ?std.StringHashMap([]const u8) = null,
    body: ?[]const u8 = null,
    /// Request timeout in milliseconds. 0 means no timeout.
    timeout_ms: u32 = 0,
    /// Optional abort signal. If true, the request should be aborted.
    aborted: ?*const std.atomic.Value(bool) = null,
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

    /// Send a request and return a streaming response for line-by-line reading.
    /// The caller must call streaming.deinit() when done.
    pub fn requestStreaming(self: *HttpClient, req: HttpRequest) anyerror!StreamingResponse {
        // Check abort signal before starting
        if (req.aborted) |aborted| {
            if (aborted.load(.monotonic)) return HttpError.RequestAborted;
        }

        // Fall back to buffered fetch for now, but return a StreamingResponse
        // that iterates lines from the buffered body.
        const response = try self.request(req);
        errdefer response.deinit();

        var buffer: std.ArrayList(u8) = .empty;
        _ = &buffer; // silence unused-mutability warning

        // Transfer ownership of the body to StreamingResponse
        const body = response.body;

        return StreamingResponse{
            .status = response.status,
            .body = body,
            .buffer = buffer,
            .allocator = self.allocator,
        };
    }
};

test "HttpClient init/deinit" {
    var client = try HttpClient.init(std.testing.allocator, std.testing.io);
    client.deinit();
}

test "StreamingResponse readLine" {
    const allocator = std.testing.allocator;

    // Simulate a streaming response with SSE data
    const body = try allocator.dupe(u8, "data: hello\ndata: world\n\n");

    var stream = StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer stream.deinit();

    // Read lines
    const line1 = try stream.readLine();
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("data: hello", line1.?);

    const line2 = try stream.readLine();
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("data: world", line2.?);

    const line3 = try stream.readLine();
    try std.testing.expect(line3 != null);
    try std.testing.expectEqualStrings("", line3.?);

    const line4 = try stream.readLine();
    try std.testing.expect(line4 == null);
}

test "StreamingResponse readLine with \\r\\n" {
    const allocator = std.testing.allocator;

    const body = try allocator.dupe(u8, "data: hello\r\ndata: world\r\n");

    var stream = StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer stream.deinit();

    const line1 = try stream.readLine();
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("data: hello", line1.?);

    const line2 = try stream.readLine();
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("data: world", line2.?);
}

test "HttpError codes exist" {
    // Just verify the error set compiles
    const err: HttpError = error.Timeout;
    try std.testing.expect(err == error.Timeout);
}

test "HttpRequest timeout and abort fields" {
    // Verify HttpRequest can be constructed with timeout and abort signal
    var abort_signal = std.atomic.Value(bool).init(false);

    const req = HttpRequest{
        .method = .POST,
        .url = "https://example.com",
        .timeout_ms = 5000,
        .aborted = &abort_signal,
    };

    try std.testing.expectEqual(@as(u32, 5000), req.timeout_ms);
    try std.testing.expect(req.aborted != null);
    try std.testing.expect(!req.aborted.?.load(.monotonic));
}

test "StreamingResponse readAll" {
    const allocator = std.testing.allocator;

    const body = try allocator.dupe(u8, "line1\nline2\nline3");

    var stream = StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer stream.deinit();

    const all = try stream.readAll(allocator);
    defer allocator.free(all);

    try std.testing.expectEqualStrings("line1\nline2\nline3\n", all);
}

test "StreamingResponse empty body" {
    const allocator = std.testing.allocator;

    const body = try allocator.dupe(u8, "");

    var stream = StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer stream.deinit();

    const line1 = try stream.readLine();
    try std.testing.expect(line1 == null);
}

test "StreamingResponse single line no newline" {
    const allocator = std.testing.allocator;

    const body = try allocator.dupe(u8, "just one line");

    var stream = StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer stream.deinit();

    const line1 = try stream.readLine();
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("just one line", line1.?);

    const line2 = try stream.readLine();
    try std.testing.expect(line2 == null);
}

test "requestStreaming abort signal" {
    const allocator = std.testing.allocator;

    var abort_signal = std.atomic.Value(bool).init(true);

    var client = try HttpClient.init(allocator, std.testing.io);
    defer client.deinit();

    const req = HttpRequest{
        .method = .GET,
        .url = "https://example.com",
        .aborted = &abort_signal,
    };

    const result = client.requestStreaming(req);
    try std.testing.expectError(HttpError.RequestAborted, result);
}
