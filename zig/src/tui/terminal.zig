const std = @import("std");

pub const Size = struct {
    width: usize,
    height: usize,
};

pub const Backend = struct {
    ptr: *anyopaque,
    enterRawModeFn: *const fn (ptr: *anyopaque) anyerror!void,
    restoreModeFn: *const fn (ptr: *anyopaque) anyerror!void,
    writeFn: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!void,
    getSizeFn: *const fn (ptr: *anyopaque) anyerror!Size,

    fn enterRawMode(self: Backend) anyerror!void {
        try self.enterRawModeFn(self.ptr);
    }

    fn restoreMode(self: Backend) anyerror!void {
        try self.restoreModeFn(self.ptr);
    }

    fn write(self: Backend, bytes: []const u8) anyerror!void {
        try self.writeFn(self.ptr, bytes);
    }

    fn getSize(self: Backend) anyerror!Size {
        return try self.getSizeFn(self.ptr);
    }
};

pub const Terminal = struct {
    backend: Backend,
    started: bool = false,
    raw_mode_enabled: bool = false,
    current_size: Size = .{ .width = 80, .height = 24 },

    pub const ALT_SCREEN_ENABLE = "\x1b[?1049h";
    pub const ALT_SCREEN_DISABLE = "\x1b[?1049l";
    pub const BRACKETED_PASTE_ENABLE = "\x1b[?2004h";
    pub const BRACKETED_PASTE_DISABLE = "\x1b[?2004l";
    pub const HIDE_CURSOR = "\x1b[?25l";
    pub const SHOW_CURSOR = "\x1b[?25h";

    pub fn init(backend: Backend) Terminal {
        return .{ .backend = backend };
    }

    pub fn start(self: *Terminal) !void {
        if (self.started) return;

        try self.backend.enterRawMode();
        errdefer self.backend.restoreMode() catch {};

        try self.backend.write(ALT_SCREEN_ENABLE ++ BRACKETED_PASTE_ENABLE ++ HIDE_CURSOR);
        errdefer self.backend.write(ALT_SCREEN_DISABLE ++ BRACKETED_PASTE_DISABLE ++ SHOW_CURSOR) catch {};

        self.current_size = try self.backend.getSize();
        self.started = true;
        self.raw_mode_enabled = true;
    }

    pub fn stop(self: *Terminal) void {
        if (!self.started) return;

        self.backend.write(ALT_SCREEN_DISABLE ++ BRACKETED_PASTE_DISABLE ++ SHOW_CURSOR) catch {};
        self.backend.restoreMode() catch {};
        self.started = false;
        self.raw_mode_enabled = false;
    }

    pub fn write(self: *Terminal, bytes: []const u8) !void {
        try self.backend.write(bytes);
    }

    pub fn refreshSize(self: *Terminal) !Size {
        self.current_size = try self.backend.getSize();
        return self.current_size;
    }
};

pub fn makeRawMode(term: std.posix.termios) std.posix.termios {
    var raw = term;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.cflag.CREAD = true;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    return raw;
}

const MockBackend = struct {
    entered_raw: bool = false,
    restored: bool = false,
    fail_get_size: bool = false,
    size: Size = .{ .width = 80, .height = 24 },
    writes: std.ArrayList([]u8) = .empty,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.writes.items) |entry| allocator.free(entry);
        self.writes.deinit(allocator);
    }

    fn backend(self: *@This()) Backend {
        return .{
            .ptr = self,
            .enterRawModeFn = enterRawMode,
            .restoreModeFn = restoreMode,
            .writeFn = write,
            .getSizeFn = getSize,
        };
    }

    fn enterRawMode(ptr: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.entered_raw = true;
    }

    fn restoreMode(ptr: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.restored = true;
    }

    fn write(ptr: *anyopaque, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.writes.append(std.testing.allocator, try std.testing.allocator.dupe(u8, bytes));
    }

    fn getSize(ptr: *anyopaque) !Size {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.fail_get_size) return error.GetSizeFailed;
        return self.size;
    }
};

test "terminal enters raw mode on startup and restores on exit" {
    var backend = MockBackend{};
    defer backend.deinit(std.testing.allocator);

    var terminal = Terminal.init(backend.backend());
    try terminal.start();

    try std.testing.expect(backend.entered_raw);
    try std.testing.expect(terminal.raw_mode_enabled);
    try std.testing.expectEqualStrings(
        Terminal.ALT_SCREEN_ENABLE ++ Terminal.BRACKETED_PASTE_ENABLE ++ Terminal.HIDE_CURSOR,
        backend.writes.items[0],
    );

    terminal.stop();

    try std.testing.expect(backend.restored);
    try std.testing.expect(!terminal.raw_mode_enabled);
    try std.testing.expectEqualStrings(
        Terminal.ALT_SCREEN_DISABLE ++ Terminal.BRACKETED_PASTE_DISABLE ++ Terminal.SHOW_CURSOR,
        backend.writes.items[1],
    );
}

test "terminal restores terminal modes when startup fails after entering alternate screen" {
    var backend = MockBackend{ .fail_get_size = true };
    defer backend.deinit(std.testing.allocator);

    var terminal = Terminal.init(backend.backend());
    try std.testing.expectError(error.GetSizeFailed, terminal.start());

    try std.testing.expect(backend.entered_raw);
    try std.testing.expect(backend.restored);
    try std.testing.expect(!terminal.started);
    try std.testing.expect(!terminal.raw_mode_enabled);
    try std.testing.expectEqual(@as(usize, 2), backend.writes.items.len);
    try std.testing.expectEqualStrings(
        Terminal.ALT_SCREEN_ENABLE ++ Terminal.BRACKETED_PASTE_ENABLE ++ Terminal.HIDE_CURSOR,
        backend.writes.items[0],
    );
    try std.testing.expectEqualStrings(
        Terminal.ALT_SCREEN_DISABLE ++ Terminal.BRACKETED_PASTE_DISABLE ++ Terminal.SHOW_CURSOR,
        backend.writes.items[1],
    );
}
