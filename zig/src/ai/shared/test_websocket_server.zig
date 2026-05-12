//! Test-only WebSocket server harness, parallel to `TestStatusServer`.
//!
//! Listens on a loopback TCP port (random, OS-chosen), accepts ONE client
//! connection, performs the RFC 6455 upgrade handshake (or rejects it with a
//! caller-specified HTTP status), then writes a caller-provided sequence of
//! pre-encoded WebSocket frames (text/binary/ping/close/raw bytes). Lets
//! tests optionally capture the first client text frame for assertion.
//!
//! Used by the Mission J integration tests for `websocket_client.zig`.

const std = @import("std");
const websocket_client = @import("../websocket_client.zig");

pub const ExpectedHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const CloseInfo = struct {
    code: u16,
    reason: []const u8 = "",
};

/// One server-driven frame to write to the client after the handshake.
/// Server frames are unmasked (RFC 6455 §5.3).
pub const FrameDirective = union(enum) {
    text: []const u8,
    binary: []const u8,
    ping: []const u8,
    /// Send a close frame with the given code and reason.
    close: CloseInfo,
    /// Send arbitrary, pre-encoded bytes (for malformed-frame tests).
    raw_bytes: []const u8,
};

pub const Config = struct {
    /// If set, the server validates the request-line path and returns 404 if
    /// it doesn't match.
    expected_path: ?[]const u8 = null,
    /// Headers that MUST be present (case-insensitive name match, exact
    /// value match). If any check fails, the server responds with 400 and
    /// closes.
    expected_headers: []const ExpectedHeader = &.{},
    /// If true, the server reads exactly one text/binary frame from the
    /// client after the handshake and stores its payload (text or binary
    /// bytes) for `capturedFrame()`.
    capture_first_client_frame: bool = false,
    /// Pre-encoded frames the server sends after the handshake, in order.
    frames_to_send: []const FrameDirective = &.{},
    /// If non-null, the server sends a final close frame with this info
    /// after `frames_to_send`. If null, the server just closes the TCP
    /// connection.
    close_after_frames: ?CloseInfo = null,
    /// If set, the server skips the 101 upgrade entirely and instead sends
    /// a minimal HTTP error response with this status code. Useful for
    /// testing the client's HandshakeFailed error path.
    reject_with_status: ?u16 = null,
};

pub const TestWebSocketServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    config: Config,
    thread: ?std.Thread = null,
    captured: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
    ) !TestWebSocketServer {
        return .{
            .allocator = allocator,
            .io = io,
            .server = try std.Io.net.IpAddress.listen(
                &.{ .ip4 = .loopback(0) },
                io,
                .{ .reuse_address = true },
            ),
            .config = config,
        };
    }

    pub fn start(self: *TestWebSocketServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *TestWebSocketServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
        if (self.captured) |bytes| {
            self.allocator.free(bytes);
            self.captured = null;
        }
    }

    pub fn url(self: *const TestWebSocketServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "ws://127.0.0.1:{d}{s}",
            .{
                self.server.socket.address.getPort(),
                if (self.config.expected_path) |p| p else "/",
            },
        );
    }

    /// Returns the payload of the first text/binary frame received from the
    /// client, if `Config.capture_first_client_frame` was set. The returned
    /// slice is owned by the server and freed in `deinit`. Callers must
    /// ensure the server thread has completed (via `awaitDone` or by
    /// draining the WS conversation to close) before calling this.
    pub fn capturedFrame(self: *const TestWebSocketServer) ?[]const u8 {
        return self.captured;
    }

    /// Joins the server thread so all writes/reads on the server side have
    /// completed. Safe to call once. After this returns, captured state is
    /// stable.
    pub fn awaitDone(self: *TestWebSocketServer) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    // ---------------------------------------------------------------------
    // Internals.
    // ---------------------------------------------------------------------

    fn run(self: *TestWebSocketServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => std.debug.panic("test websocket server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);

        self.handleConnection(stream) catch |err| switch (err) {
            // Treat any I/O / protocol failure during the conversation as
            // benign — tests assert on the client side, and the server side
            // just needs to clean up. We deliberately don't panic on these.
            else => {},
        };
    }

    fn handleConnection(self: *TestWebSocketServer, stream: std.Io.net.Stream) !void {
        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);
        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);

        const request = try readRequestHead(self.allocator, &reader.interface);
        defer self.allocator.free(request.bytes);

        if (self.config.reject_with_status) |status| {
            try writeRejectionResponse(&writer.interface, status);
            return;
        }

        if (self.config.expected_path) |expected| {
            if (!std.mem.eql(u8, request.path, expected)) {
                try writeRejectionResponse(&writer.interface, 404);
                return;
            }
        }

        for (self.config.expected_headers) |expected| {
            const value = findHeader(request.bytes, expected.name) orelse {
                try writeRejectionResponse(&writer.interface, 400);
                return;
            };
            if (!std.mem.eql(u8, value, expected.value)) {
                try writeRejectionResponse(&writer.interface, 400);
                return;
            }
        }

        const client_key = findHeader(request.bytes, "Sec-WebSocket-Key") orelse {
            try writeRejectionResponse(&writer.interface, 400);
            return;
        };

        const accept = try websocket_client.computeAccept(self.allocator, client_key);
        defer self.allocator.free(accept);

        try writer.interface.print(
            "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n\r\n",
            .{accept},
        );
        try writer.interface.flush();

        if (self.config.capture_first_client_frame) {
            const payload = readClientDataFrame(self.allocator, &reader.interface) catch null;
            if (payload) |bytes| {
                self.captured = bytes;
            }
        }

        for (self.config.frames_to_send) |directive| {
            try writeDirective(&writer.interface, directive);
        }

        if (self.config.close_after_frames) |info| {
            try writeServerCloseFrame(&writer.interface, info.code, info.reason);
        }
    }

    const RequestHead = struct {
        bytes: []u8,
        path: []const u8, // borrowed from bytes
    };

    fn readRequestHead(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) !RequestHead {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        var tail: [4]u8 = .{ 0, 0, 0, 0 };
        var count: usize = 0;
        while (true) {
            const byte = try reader.takeByte();
            try buf.append(allocator, byte);
            tail[count % tail.len] = byte;
            count += 1;
            // Cap to prevent unbounded growth on a misbehaving client.
            if (buf.items.len > 16 * 1024) return error.RequestHeaderTooLarge;
            if (count >= 4) {
                const start_idx = count % tail.len;
                const ordered = [_]u8{
                    tail[start_idx],
                    tail[(start_idx + 1) % tail.len],
                    tail[(start_idx + 2) % tail.len],
                    tail[(start_idx + 3) % tail.len],
                };
                if (std.mem.eql(u8, &ordered, "\r\n\r\n")) break;
            }
        }

        const bytes = try buf.toOwnedSlice(allocator);
        errdefer allocator.free(bytes);

        // Request line: "GET <path> HTTP/1.1\r\n..."
        const line_end = std.mem.indexOfScalar(u8, bytes, '\r') orelse return error.MalformedRequest;
        const line = bytes[0..line_end];
        if (!std.mem.startsWith(u8, line, "GET ")) return error.MalformedRequest;
        const rest = line[4..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.MalformedRequest;
        const path = rest[0..space];

        return .{ .bytes = bytes, .path = path };
    }

    fn findHeader(request: []const u8, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        _ = lines.next(); // skip request line
        while (lines.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const lname = std.mem.trim(u8, line[0..colon], " \t");
            if (!std.ascii.eqlIgnoreCase(lname, name)) continue;
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }

    fn writeRejectionResponse(writer: *std.Io.Writer, status: u16) !void {
        const reason: []const u8 = switch (status) {
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            429 => "Too Many Requests",
            500 => "Internal Server Error",
            else => "Error",
        };
        try writer.print(
            "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            .{ status, reason },
        );
        try writer.flush();
    }

    /// Reads one masked client data frame (text or binary) and returns its
    /// unmasked payload, allocated out of `allocator`. Control frames are
    /// skipped; fragmentation is NOT supported here (tests send single
    /// unfragmented frames).
    fn readClientDataFrame(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
    ) ![]u8 {
        while (true) {
            const header0 = try reader.takeByte();
            const header1 = try reader.takeByte();
            const fin = (header0 & 0x80) != 0;
            const opcode: u4 = @truncate(header0 & 0x0F);
            const masked = (header1 & 0x80) != 0;
            const len_field: u7 = @truncate(header1 & 0x7F);
            const payload_len: u64 = switch (len_field) {
                126 => try reader.takeInt(u16, .big),
                127 => try reader.takeInt(u64, .big),
                else => @as(u64, len_field),
            };

            var mask: [4]u8 = .{ 0, 0, 0, 0 };
            if (masked) try reader.readSliceAll(mask[0..]);

            const payload = try allocator.alloc(u8, @intCast(payload_len));
            errdefer allocator.free(payload);
            if (payload.len > 0) try reader.readSliceAll(payload);
            if (masked) {
                for (payload, 0..) |*b, i| b.* ^= mask[i & 3];
            }

            // text=0x1, binary=0x2: yield. Anything else: free and continue.
            if (fin and (opcode == 0x1 or opcode == 0x2)) return payload;
            allocator.free(payload);
            if (opcode == 0x8) return error.UnexpectedClose;
        }
    }

    fn writeDirective(
        writer: *std.Io.Writer,
        directive: FrameDirective,
    ) !void {
        switch (directive) {
            .text => |bytes| try writeServerFrame(writer, 0x1, bytes),
            .binary => |bytes| try writeServerFrame(writer, 0x2, bytes),
            .ping => |bytes| try writeServerFrame(writer, 0x9, bytes),
            .close => |info| try writeServerCloseFrame(writer, info.code, info.reason),
            .raw_bytes => |bytes| {
                try writer.writeAll(bytes);
                try writer.flush();
            },
        }
    }

    /// Writes a single UNMASKED server frame. Server frames must not be
    /// masked (RFC 6455 §5.3).
    fn writeServerFrame(
        writer: *std.Io.Writer,
        opcode: u4,
        payload: []const u8,
    ) !void {
        var header_buf: [10]u8 = undefined;
        var header_len: usize = 0;

        header_buf[0] = 0x80 | @as(u8, opcode); // FIN=1, no RSV
        if (payload.len < 126) {
            header_buf[1] = @intCast(payload.len); // mask bit clear
            header_len = 2;
        } else if (payload.len <= std.math.maxInt(u16)) {
            header_buf[1] = 126;
            std.mem.writeInt(u16, header_buf[2..4], @intCast(payload.len), .big);
            header_len = 4;
        } else {
            header_buf[1] = 127;
            std.mem.writeInt(u64, header_buf[2..10], @intCast(payload.len), .big);
            header_len = 10;
        }

        try writer.writeAll(header_buf[0..header_len]);
        if (payload.len > 0) try writer.writeAll(payload);
        try writer.flush();
    }

    fn writeServerCloseFrame(
        writer: *std.Io.Writer,
        code: u16,
        reason: []const u8,
    ) !void {
        if (reason.len > 123) return error.CloseReasonTooLong;
        var buf: [125]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], code, .big);
        if (reason.len > 0) @memcpy(buf[2..][0..reason.len], reason);
        try writeServerFrame(writer, 0x8, buf[0 .. 2 + reason.len]);
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "TestWebSocketServer accepts upgrade and sends canned text frames" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const frames = [_]FrameDirective{
        .{ .text = "hello" },
        .{ .text = "world" },
    };
    var server = try TestWebSocketServer.init(allocator, io, .{
        .frames_to_send = &frames,
        .close_after_frames = .{ .code = 1000, .reason = "bye" },
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);

    var client = try websocket_client.Client.connect(.{
        .allocator = allocator,
        .io = io,
        .url = ws_url,
    });
    defer client.deinit();

    // First text frame.
    {
        const f = (try client.next()).?;
        defer f.deinit(allocator);
        try std.testing.expectEqualStrings("hello", f.text);
    }
    // Second text frame.
    {
        const f = (try client.next()).?;
        defer f.deinit(allocator);
        try std.testing.expectEqualStrings("world", f.text);
    }
    // Server close.
    {
        const f = (try client.next()).?;
        defer f.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 1000), f.close.code);
        try std.testing.expectEqualStrings("bye", f.close.reason);
    }
    // After close, the decoder should yield null.
    try std.testing.expect((try client.next()) == null);
}

test "TestWebSocketServer captures first client text frame" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestWebSocketServer.init(allocator, io, .{
        .capture_first_client_frame = true,
        .close_after_frames = .{ .code = 1000, .reason = "" },
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);

    var client = try websocket_client.Client.connect(.{
        .allocator = allocator,
        .io = io,
        .url = ws_url,
    });
    defer client.deinit();

    try client.sendText("ping from client");

    // Drain frames until we observe the server-driven close so the server
    // thread completes before we read `capturedFrame`.
    while (try client.next()) |frame| {
        defer frame.deinit(allocator);
        if (frame == .close) break;
    }
    server.awaitDone();
    const captured = server.capturedFrame() orelse return error.TestExpectedCapturedFrame;
    try std.testing.expectEqualStrings("ping from client", captured);
}

test "TestWebSocketServer rejects upgrade with custom status" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var server = try TestWebSocketServer.init(allocator, io, .{
        .reject_with_status = 403,
    });
    defer server.deinit();
    try server.start();

    const ws_url = try server.url(allocator);
    defer allocator.free(ws_url);

    const result = websocket_client.Client.connect(.{
        .allocator = allocator,
        .io = io,
        .url = ws_url,
    });
    try std.testing.expectError(websocket_client.Error.HandshakeFailed, result);
}
