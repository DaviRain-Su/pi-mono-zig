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
    response_headers: ?std.StringHashMap([]const u8) = null,
    done: bool = false,
    owns_body: bool = true,
    request: ?*std.http.Client.Request = null,
    reader: ?*std.Io.Reader = null,
    transfer_buffer: [64]u8 = undefined,
    decompress: std.http.Decompress = undefined,
    decompress_buffer: []u8 = &.{},
    redirect_buffer: []u8 = &.{},
    extra_headers: []std.http.Header = &.{},
    aborted: ?*const std.atomic.Value(bool) = null,
    timeout_ms: u32 = 0,
    created_at_ns: i128 = 0,
    io: ?std.Io = null,
    watchdog_thread: ?std.Thread = null,
    watchdog_started: bool = false,
    watchdog_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    termination_reason: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(TerminationReason.none)),

    const TerminationReason = enum(u8) {
        none,
        aborted,
        timeout,
    };

    pub fn deinit(self: *StreamingResponse) void {
        self.watchdog_done.store(true, .release);
        if (self.watchdog_thread) |thread| thread.join();

        if (self.request) |request| {
            request.deinit();
            self.allocator.destroy(request);
        }
        if (self.owns_body) self.allocator.free(self.body);
        if (self.response_headers) |*headers| deinitOwnedHeaders(self.allocator, headers);
        if (self.decompress_buffer.len > 0) self.allocator.free(self.decompress_buffer);
        if (self.redirect_buffer.len > 0) self.allocator.free(self.redirect_buffer);
        if (self.extra_headers.len > 0) self.allocator.free(self.extra_headers);
        self.buffer.deinit(self.allocator);
    }

    /// Read the next line from the buffered body. Returns a slice into an
    /// internal buffer that is valid until the next call to readLine.
    pub fn readLine(self: *StreamingResponse) !?[]const u8 {
        if (self.done) return null;
        if (self.reader != null) return self.readLiveLine();
        return self.readBufferedLine();
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

    /// Consume up to max_bytes from the rest of the stream into a single buffer.
    /// This is intended for provider error bodies where callers only need enough
    /// bytes for bounded diagnostics and should not read an unbounded response.
    pub fn readAllBounded(self: *StreamingResponse, allocator: std.mem.Allocator, max_bytes: usize) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        if (max_bytes == 0) {
            self.done = true;
            return result.toOwnedSlice(allocator);
        }

        if (self.reader == null) {
            if (self.pos >= self.body.len) {
                self.done = true;
                return result.toOwnedSlice(allocator);
            }
            const remaining = self.body[self.pos..];
            const copy_len = @min(remaining.len, max_bytes);
            try result.appendSlice(allocator, remaining[0..copy_len]);
            self.pos += copy_len;
            if (self.pos >= self.body.len or result.items.len >= max_bytes) self.done = true;
            return result.toOwnedSlice(allocator);
        }

        try self.ensureWatchdogStarted();
        const reader = self.reader.?;
        while (result.items.len < max_bytes) {
            if (self.currentTerminationReason()) |reason| {
                self.done = true;
                return terminationError(reason);
            }

            const byte = reader.takeByte() catch |err| {
                if (self.currentTerminationReason()) |reason| {
                    self.done = true;
                    return terminationError(reason);
                }
                if (err == error.EndOfStream) {
                    self.done = true;
                    break;
                }
                return err;
            };
            try result.append(allocator, byte);
        }

        if (result.items.len >= max_bytes) self.done = true;
        return result.toOwnedSlice(allocator);
    }

    fn readBufferedLine(self: *StreamingResponse) !?[]const u8 {
        if (self.pos >= self.body.len) {
            self.done = true;
            return null;
        }

        self.buffer.clearRetainingCapacity();

        while (self.pos < self.body.len) {
            const byte = self.body[self.pos];
            self.pos += 1;

            if (byte == '\n') {
                trimTrailingCarriageReturn(&self.buffer);
                return self.buffer.items;
            }

            try self.buffer.append(self.allocator, byte);
        }

        self.done = true;
        return self.buffer.items;
    }

    fn readLiveLine(self: *StreamingResponse) !?[]const u8 {
        try self.ensureWatchdogStarted();
        if (self.currentTerminationReason()) |reason| {
            self.done = true;
            return terminationError(reason);
        }

        self.buffer.clearRetainingCapacity();
        const reader = self.reader.?;

        while (true) {
            if (self.currentTerminationReason()) |reason| {
                self.done = true;
                return terminationError(reason);
            }

            const byte = reader.takeByte() catch |err| {
                if (self.currentTerminationReason()) |reason| {
                    self.done = true;
                    return terminationError(reason);
                }

                if (err == error.EndOfStream) {
                    self.done = true;
                    if (self.buffer.items.len == 0) return null;
                    trimTrailingCarriageReturn(&self.buffer);
                    return self.buffer.items;
                }

                return err;
            };

            if (byte == '\n') {
                trimTrailingCarriageReturn(&self.buffer);
                return self.buffer.items;
            }

            try self.buffer.append(self.allocator, byte);
        }
    }

    fn ensureWatchdogStarted(self: *StreamingResponse) !void {
        if (self.watchdog_started) return;
        if (self.io == null) return;
        if (self.aborted == null and self.timeout_ms == 0) return;

        self.watchdog_started = true;
        self.watchdog_thread = try std.Thread.spawn(.{}, watchdogMain, .{self});
    }

    fn watchdogMain(self: *StreamingResponse) void {
        const io = self.io orelse return;

        while (!self.watchdog_done.load(.acquire)) {
            if (self.aborted) |aborted| {
                if (aborted.load(.seq_cst)) {
                    self.triggerTermination(.aborted);
                    return;
                }
            }

            if (self.timeout_ms > 0) {
                const now_ns = std.Io.Clock.now(.awake, io).nanoseconds;
                const timeout_ns: i128 = @as(i128, self.timeout_ms) * std.time.ns_per_ms;
                if (now_ns - self.created_at_ns >= timeout_ns) {
                    self.triggerTermination(.timeout);
                    return;
                }
            }

            const sleep_ms: i64 = if (self.timeout_ms == 0) 10 else 1;
            std.Io.sleep(io, .fromMilliseconds(sleep_ms), .awake) catch return;
        }
    }

    fn triggerTermination(self: *StreamingResponse, reason: TerminationReason) void {
        self.termination_reason.store(@intFromEnum(reason), .release);

        if (self.request) |request| {
            if (request.connection) |connection| {
                connection.closing = true;
                connection.stream_reader.stream.shutdown(self.io.?, .both) catch {};
            }
        }
    }

    fn currentTerminationReason(self: *const StreamingResponse) ?TerminationReason {
        return switch (@as(TerminationReason, @enumFromInt(self.termination_reason.load(.acquire)))) {
            .none => null,
            .aborted => .aborted,
            .timeout => .timeout,
        };
    }

    fn terminationError(reason: TerminationReason) HttpError {
        return switch (reason) {
            .none => unreachable,
            .aborted => HttpError.RequestAborted,
            .timeout => HttpError.Timeout,
        };
    }

    fn trimTrailingCarriageReturn(buffer: *std.ArrayList(u8)) void {
        if (buffer.items.len > 0 and buffer.items[buffer.items.len - 1] == '\r') {
            buffer.shrinkRetainingCapacity(buffer.items.len - 1);
        }
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
        const uri = std.Uri.parse(req.url) catch return HttpError.InvalidUrl;
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
            .location = .{ .uri = uri },
            .method = method,
            .payload = req.body,
            .extra_headers = extra_headers.items,
            .response_writer = &response_writer.writer,
        });

        if (httpStatusError(result.status)) |err| return err;

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

        const method: std.http.Method = switch (req.method) {
            .GET => .GET,
            .POST => .POST,
            .PUT => .PUT,
            .DELETE => .DELETE,
            .PATCH => .PATCH,
        };

        const uri = std.Uri.parse(req.url) catch return HttpError.InvalidUrl;

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
        const extra_headers_owned = try extra_headers.toOwnedSlice(self.allocator);
        var owns_extra_headers = true;
        errdefer if (owns_extra_headers) self.allocator.free(extra_headers_owned);

        const redirect_behavior: std.http.Client.Request.RedirectBehavior = if (req.body == null) @enumFromInt(3) else .unhandled;
        var redirect_buffer: []u8 = &[_]u8{};
        if (redirect_behavior != .unhandled) {
            redirect_buffer = try self.allocator.alloc(u8, 8 * 1024);
        }
        var owns_redirect_buffer = true;
        errdefer if (owns_redirect_buffer and redirect_buffer.len > 0) self.allocator.free(redirect_buffer);

        var request_initialized = false;
        const request_ptr = try self.allocator.create(std.http.Client.Request);
        var owns_request = true;
        errdefer if (owns_request) {
            if (request_initialized) request_ptr.deinit();
            self.allocator.destroy(request_ptr);
        };

        request_ptr.* = try self.client.request(method, uri, .{
            .redirect_behavior = redirect_behavior,
            .extra_headers = extra_headers_owned,
        });
        request_initialized = true;

        if (req.body) |body| {
            request_ptr.transfer_encoding = .{ .content_length = body.len };
            var body_writer = try request_ptr.sendBodyUnflushed(&.{});
            try body_writer.writer.writeAll(body);
            try body_writer.end();
            try request_ptr.connection.?.flush();
        } else {
            try request_ptr.sendBodiless();
        }

        var response = try request_ptr.receiveHead(redirect_buffer);
        var response_headers = try cloneResponseHeaders(self.allocator, response.head);
        errdefer deinitOwnedHeaders(self.allocator, &response_headers);

        var streaming = StreamingResponse{
            .status = @intFromEnum(response.head.status),
            .body = &.{},
            .buffer = .empty,
            .allocator = self.allocator,
            .response_headers = response_headers,
            .owns_body = false,
            .request = request_ptr,
            .redirect_buffer = redirect_buffer,
            .extra_headers = extra_headers_owned,
            .aborted = req.aborted,
            .timeout_ms = req.timeout_ms,
            .created_at_ns = std.Io.Clock.now(.awake, self.client.io).nanoseconds,
            .io = self.client.io,
        };
        errdefer streaming.deinit();
        owns_request = false;
        owns_extra_headers = false;
        owns_redirect_buffer = false;

        streaming.reader = switch (response.head.content_encoding) {
            .identity => response.reader(&streaming.transfer_buffer),
            .zstd => blk: {
                streaming.decompress_buffer = try self.allocator.alloc(u8, std.compress.zstd.default_window_len);
                break :blk response.readerDecompressing(
                    &streaming.transfer_buffer,
                    &streaming.decompress,
                    streaming.decompress_buffer,
                );
            },
            .deflate, .gzip => blk: {
                streaming.decompress_buffer = try self.allocator.alloc(u8, std.compress.flate.max_window_len);
                break :blk response.readerDecompressing(
                    &streaming.transfer_buffer,
                    &streaming.decompress,
                    streaming.decompress_buffer,
                );
            },
            .compress => return error.UnsupportedCompressionMethod,
        };

        return streaming;
    }
};

fn httpStatusError(status: std.http.Status) ?HttpError {
    return switch (status.class()) {
        .success => null,
        .redirect => HttpError.UnexpectedRedirect,
        .client_error => HttpError.ClientError,
        .server_error => HttpError.ServerError,
        else => null,
    };
}

fn cloneResponseHeaders(
    allocator: std.mem.Allocator,
    head: std.http.Client.Response.Head,
) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitOwnedHeaders(allocator, &headers);

    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        try headers.put(
            try allocator.dupe(u8, header.name),
            try allocator.dupe(u8, header.value),
        );
    }

    return headers;
}

fn deinitOwnedHeaders(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

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

test "StreamingResponse readAllBounded caps buffered body" {
    const allocator = std.testing.allocator;

    const body = try allocator.dupe(u8, "0123456789abcdef");

    var stream = StreamingResponse{
        .status = 500,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer stream.deinit();

    const bounded = try stream.readAllBounded(allocator, 6);
    defer allocator.free(bounded);

    try std.testing.expectEqualStrings("012345", bounded);
    try std.testing.expect(stream.done);
    try std.testing.expectEqual(@as(usize, 6), stream.pos);
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

const TestStreamingServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    status_code: u16,
    reason_phrase: []const u8,
    first_chunk: []const u8,
    second_chunk: []const u8,
    delay_ms: u64,
    thread: ?std.Thread = null,

    fn init(io: std.Io, first_chunk: []const u8, second_chunk: []const u8, delay_ms: u64) !TestStreamingServer {
        return initWithStatus(io, 200, "OK", first_chunk, second_chunk, delay_ms);
    }

    fn initWithStatus(
        io: std.Io,
        status_code: u16,
        reason_phrase: []const u8,
        first_chunk: []const u8,
        second_chunk: []const u8,
        delay_ms: u64,
    ) !TestStreamingServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .status_code = status_code,
            .reason_phrase = reason_phrase,
            .first_chunk = first_chunk,
            .second_chunk = second_chunk,
            .delay_ms = delay_ms,
        };
    }

    fn start(self: *TestStreamingServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *TestStreamingServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    fn port(self: *const TestStreamingServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn url(self: *const TestStreamingServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/stream", .{self.port()});
    }

    fn run(self: *TestStreamingServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => std.debug.panic("test server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);

        readRequestHead(self, stream) catch |err| std.debug.panic("test server read failed: {}", .{err});
        writeResponse(self, stream) catch |err| std.debug.panic("test server write failed: {}", .{err});
    }

    fn readRequestHead(self: *TestStreamingServer, stream: std.Io.net.Stream) !void {
        _ = self;
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);
        var tail = [_]u8{ 0, 0, 0, 0 };
        var count: usize = 0;

        while (true) {
            const byte = try reader.interface.takeByte();
            tail[count % tail.len] = byte;
            count += 1;

            if (count >= 4) {
                const start_index = count % tail.len;
                const ordered = [_]u8{
                    tail[start_index],
                    tail[(start_index + 1) % tail.len],
                    tail[(start_index + 2) % tail.len],
                    tail[(start_index + 3) % tail.len],
                };
                if (std.mem.eql(u8, &ordered, "\r\n\r\n")) break;
            }
        }
    }

    fn writeResponse(self: *TestStreamingServer, stream: std.Io.net.Stream) !void {
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        const total_len = self.first_chunk.len + self.second_chunk.len;

        try writer.interface.print(
            "HTTP/1.1 {d} {s}\r\nContent-Type: text/event-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ self.status_code, self.reason_phrase, total_len },
        );
        try writer.interface.flush();

        if (self.first_chunk.len > 0) {
            try writer.interface.writeAll(self.first_chunk);
            try writer.interface.flush();
        }

        if (self.delay_ms > 0) {
            std.Io.sleep(self.io, .fromMilliseconds(@intCast(self.delay_ms)), .awake) catch {};
        }

        if (self.second_chunk.len > 0) {
            writer.interface.writeAll(self.second_chunk) catch return;
            writer.interface.flush() catch return;
        }
    }
};

test "request returns connection refused for unreachable endpoint" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var listener = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();
    listener.deinit(io);

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/missing", .{port});
    defer allocator.free(url);

    const response = client.request(.{
        .method = .GET,
        .url = url,
    });

    try std.testing.expectError(HttpError.ConnectionRefused, response);
}

test "request returns client error for 4xx responses" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.initWithStatus(io, 404, "Not Found", "missing", "", 0);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const response = client.request(.{
        .method = .GET,
        .url = url,
    });

    try std.testing.expectError(HttpError.ClientError, response);
}

test "request returns server error for 5xx responses" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.initWithStatus(io, 503, "Service Unavailable", "down", "", 0);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const response = client.request(.{
        .method = .GET,
        .url = url,
    });

    try std.testing.expectError(HttpError.ServerError, response);
}

test "requestStreaming times out before the first line arrives" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.init(io, "", "data: delayed\n", 500);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var streaming = try client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .timeout_ms = 100,
    });
    defer streaming.deinit();

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const line = streaming.readLine();
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.Timeout, line);
    try std.testing.expect(elapsed_ms < server.delay_ms);
}

test "requestStreaming returns before full response body is available" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.init(io, "data: first\n", "data: second\n", 250);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    var streaming = try client.requestStreaming(.{
        .method = .GET,
        .url = url,
    });
    defer streaming.deinit();
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expect(elapsed_ms < server.delay_ms);

    const first_line = (try streaming.readLine()).?;
    try std.testing.expectEqualStrings("data: first", first_line);

    const second_line = (try streaming.readLine()).?;
    try std.testing.expectEqualStrings("data: second", second_line);
}

test "requestStreaming aborts while waiting for the next line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.init(io, "data: first\n", "data: second\n", 500);
    defer server.deinit();
    try server.start();

    var abort_signal = std.atomic.Value(bool).init(false);

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var streaming = try client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .aborted = &abort_signal,
    });
    defer streaming.deinit();

    const first_line = (try streaming.readLine()).?;
    try std.testing.expectEqualStrings("data: first", first_line);

    const abort_thread = try std.Thread.spawn(.{}, struct {
        fn run(signal: *std.atomic.Value(bool), test_io: std.Io) void {
            std.Io.sleep(test_io, .fromMilliseconds(50), .awake) catch {};
            signal.store(true, .seq_cst);
        }
    }.run, .{ &abort_signal, io });
    defer abort_thread.join();

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const next_line = streaming.readLine();
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.RequestAborted, next_line);
    try std.testing.expect(elapsed_ms < server.delay_ms);
}

test "requestStreaming enforces timeout while waiting for the next line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestStreamingServer.init(io, "data: first\n", "data: second\n", 500);
    defer server.deinit();
    try server.start();

    var client = try HttpClient.init(allocator, io);
    defer client.deinit();

    const url = try server.url(allocator);
    defer allocator.free(url);

    var streaming = try client.requestStreaming(.{
        .method = .GET,
        .url = url,
        .timeout_ms = 100,
    });
    defer streaming.deinit();

    const first_line = (try streaming.readLine()).?;
    try std.testing.expectEqualStrings("data: first", first_line);

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const next_line = streaming.readLine();
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, io).nanoseconds - start_ns, std.time.ns_per_ms);

    try std.testing.expectError(HttpError.Timeout, next_line);
    try std.testing.expect(elapsed_ms < server.delay_ms);
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
