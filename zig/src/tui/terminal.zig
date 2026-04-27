const std = @import("std");
const ESC = "\x1b";
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const keys = @import("keys.zig");

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

pub const NativeOptions = struct {
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    read_size_fn: *const fn (context: ?*anyopaque, tty: *vaxis.Tty) ?Size = readSizeWithVaxis,
    read_size_context: ?*anyopaque = null,
};

const NativeState = struct {
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    tty: ?vaxis.Tty = null,
    tty_buffer: [4096]u8 = undefined,
    resize_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    read_size_fn: *const fn (context: ?*anyopaque, tty: *vaxis.Tty) ?Size = readSizeWithVaxis,
    read_size_context: ?*anyopaque = null,

    fn start(self: *NativeState, terminal: *Terminal) !void {
        var tty = try vaxis.Tty.init(self.io, &self.tty_buffer);
        errdefer tty.deinit();
        self.tty = tty;
        self.resize_pending.store(false, .seq_cst);

        if (!builtin.is_test and builtin.os.tag != .windows) {
            const handler: vaxis.Tty.SignalHandler = .{
                .context = terminal,
                .callback = Terminal.handleNativeWinsize,
            };
            try vaxis.Tty.notifyWinsize(handler);
        }
    }

    fn stop(self: *NativeState) void {
        if (!builtin.is_test and builtin.os.tag != .windows) {
            vaxis.Tty.resetSignalHandler();
        }
        if (self.tty) |*tty| {
            tty.deinit();
            self.tty = null;
        }
        self.resize_pending.store(false, .seq_cst);
    }

    fn writer(self: *NativeState) !*std.Io.Writer {
        if (self.tty) |*tty| return tty.writer();
        return error.TerminalNotStarted;
    }

    fn readSize(self: *NativeState, fallback: Size) Size {
        if (self.tty) |*tty| {
            if (self.read_size_fn(self.read_size_context, tty)) |size| {
                return normalizeSize(size, fallback);
            }
        }

        const columns = parseEnvSize(self.env_map.get("COLUMNS")) orelse fallback.width;
        const lines = parseEnvSize(self.env_map.get("LINES")) orelse fallback.height;
        return .{
            .width = if (columns == 0) 80 else columns,
            .height = if (lines == 0) 24 else lines,
        };
    }
};

pub const Terminal = struct {
    state: union(enum) {
        backend: Backend,
        native: NativeState,
    },
    started: bool = false,
    raw_mode_enabled: bool = false,
    current_size: Size = .{ .width = 80, .height = 24 },

    pub const ALT_SCREEN_ENABLE = vaxis.ctlseqs.smcup;
    pub const ALT_SCREEN_DISABLE = vaxis.ctlseqs.rmcup;
    pub const BRACKETED_PASTE_ENABLE = vaxis.ctlseqs.bp_set;
    pub const BRACKETED_PASTE_DISABLE = vaxis.ctlseqs.bp_reset;
    pub const KITTY_KEYBOARD_QUERY = vaxis.ctlseqs.csi_u_query;
    pub const KITTY_KEYBOARD_ENABLE = ESC ++ "[>7u";
    pub const KITTY_KEYBOARD_DISABLE = vaxis.ctlseqs.csi_u_pop;
    pub const MOUSE_ENABLE = ESC ++ "[?1002h" ++ ESC ++ "[?1006h";
    pub const MOUSE_DISABLE = ESC ++ "[?1006l" ++ ESC ++ "[?1002l";
    pub const SYNC_OUTPUT_ENABLE = vaxis.ctlseqs.sync_set;
    pub const SYNC_OUTPUT_DISABLE = vaxis.ctlseqs.sync_reset;
    pub const HIDE_CURSOR = vaxis.ctlseqs.hide_cursor;
    pub const SHOW_CURSOR = vaxis.ctlseqs.show_cursor;
    pub const AUTO_WRAP_DISABLE = ESC ++ "[?7l";
    pub const AUTO_WRAP_ENABLE = ESC ++ "[?7h";

    pub fn init(backend: Backend) Terminal {
        return .{ .state = .{ .backend = backend } };
    }

    pub fn initNative(options: NativeOptions) Terminal {
        return .{
            .state = .{ .native = .{
                .io = options.io,
                .env_map = options.env_map,
                .read_size_fn = options.read_size_fn,
                .read_size_context = options.read_size_context,
            } },
        };
    }

    pub fn start(self: *Terminal) !void {
        if (self.started) return;

        switch (self.state) {
            .backend => |backend| {
                try backend.enterRawMode();
                errdefer backend.restoreMode() catch {};

                try backend.write(ALT_SCREEN_ENABLE ++ BRACKETED_PASTE_ENABLE ++ HIDE_CURSOR ++ AUTO_WRAP_DISABLE ++ KITTY_KEYBOARD_QUERY ++ KITTY_KEYBOARD_ENABLE ++ MOUSE_ENABLE);
                errdefer backend.write(MOUSE_DISABLE ++ AUTO_WRAP_ENABLE ++ ALT_SCREEN_DISABLE ++ BRACKETED_PASTE_DISABLE ++ KITTY_KEYBOARD_DISABLE ++ SHOW_CURSOR) catch {};

                self.current_size = try backend.getSize();
            },
            .native => |*native| {
                try native.start(self);
                errdefer native.stop();

                const writer = try native.writer();
                try writer.writeAll(ALT_SCREEN_ENABLE ++ BRACKETED_PASTE_ENABLE ++ HIDE_CURSOR ++ AUTO_WRAP_DISABLE ++ KITTY_KEYBOARD_QUERY ++ KITTY_KEYBOARD_ENABLE ++ MOUSE_ENABLE);
                try writer.flush();
                errdefer {
                    const stop_writer = native.writer() catch null;
                    if (stop_writer) |w| {
                        w.writeAll(MOUSE_DISABLE ++ AUTO_WRAP_ENABLE ++ ALT_SCREEN_DISABLE ++ BRACKETED_PASTE_DISABLE ++ KITTY_KEYBOARD_DISABLE ++ SHOW_CURSOR) catch {};
                        w.flush() catch {};
                    }
                }

                self.current_size = native.readSize(self.current_size);
            },
        }

        self.started = true;
        self.raw_mode_enabled = true;
    }

    pub fn stop(self: *Terminal) void {
        if (!self.started) return;

        switch (self.state) {
            .backend => |backend| {
                backend.write(MOUSE_DISABLE ++ AUTO_WRAP_ENABLE ++ ALT_SCREEN_DISABLE ++ BRACKETED_PASTE_DISABLE ++ KITTY_KEYBOARD_DISABLE ++ SHOW_CURSOR) catch {};
                backend.restoreMode() catch {};
            },
            .native => |*native| {
                const writer = native.writer() catch null;
                if (writer) |tty_writer| {
                    tty_writer.writeAll(MOUSE_DISABLE ++ AUTO_WRAP_ENABLE ++ ALT_SCREEN_DISABLE ++ BRACKETED_PASTE_DISABLE ++ KITTY_KEYBOARD_DISABLE ++ SHOW_CURSOR) catch {};
                    tty_writer.flush() catch {};
                }
                native.stop();
            },
        }

        self.started = false;
        self.raw_mode_enabled = false;
    }

    pub fn write(self: *Terminal, bytes: []const u8) !void {
        switch (self.state) {
            .backend => |backend| try backend.write(bytes),
            .native => |*native| {
                const writer = try native.writer();
                try writer.writeAll(bytes);
                try writer.flush();
            },
        }
    }

    pub fn refreshSize(self: *Terminal) !Size {
        switch (self.state) {
            .backend => |backend| {
                self.current_size = try backend.getSize();
            },
            .native => |*native| {
                if (native.resize_pending.swap(false, .seq_cst)) {
                    self.current_size = native.readSize(self.current_size);
                }
            },
        }
        return self.current_size;
    }

    pub fn handleNativeWinsize(context: *anyopaque) void {
        const self: *Terminal = @ptrCast(@alignCast(context));
        switch (self.state) {
            .backend => {},
            .native => |*native| native.resize_pending.store(true, .seq_cst),
        }
    }

    pub fn initInputLoop(
        self: *Terminal,
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
    ) !*InputLoop {
        return switch (self.state) {
            .backend => error.UnsupportedTerminalBackend,
            .native => |*native| {
                if (native.tty) |*tty| {
                    return try InputLoop.init(allocator, io, env_map, tty);
                }
                return error.TerminalNotStarted;
            },
        };
    }
};

pub const LoopEvent = union(enum) {
    key_press: vaxis.Key,
    key_release: vaxis.Key,
    paste_start,
    paste_end,
    paste: []const u8,
    mouse: vaxis.Mouse,
};

pub const InputLoopResult = struct {
    parsed: keys.ParsedInput,
    owned_paste: ?[]const u8 = null,

    pub fn deinit(self: InputLoopResult, allocator: std.mem.Allocator) void {
        if (self.owned_paste) |paste| allocator.free(paste);
    }
};

pub const InputLoop = struct {
    allocator: std.mem.Allocator,
    vaxis_state: *vaxis.Vaxis,
    loop: vaxis.Loop(LoopEvent),
    paste_buffer: std.ArrayList(u8) = .empty,
    paste_active: bool = false,
    started: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        env_map: *const std.process.Environ.Map,
        tty: *vaxis.Tty,
    ) !*InputLoop {
        const result = try allocator.create(InputLoop);
        errdefer allocator.destroy(result);

        const vaxis_state = try allocator.create(vaxis.Vaxis);
        errdefer allocator.destroy(vaxis_state);

        vaxis_state.* = try vaxis.init(io, allocator, @constCast(env_map), .{});
        errdefer vaxis_state.deinit(allocator, tty.writer());

        result.* = .{
            .allocator = allocator,
            .vaxis_state = vaxis_state,
            .loop = vaxis.Loop(LoopEvent).init(io, tty, vaxis_state),
        };
        errdefer result.paste_buffer.deinit(allocator);

        try result.loop.start();
        result.started = true;
        return result;
    }

    pub fn deinit(self: *InputLoop) void {
        const allocator = self.allocator;
        self.paste_buffer.deinit(self.allocator);
        if (self.started) {
            self.loop.should_quit = true;
            if (self.loop.thread) |*thread| {
                _ = thread.cancel(self.loop.io);
                self.loop.thread = null;
                self.loop.should_quit = false;
            }
        }
        self.vaxis_state.deinit(self.allocator, self.loop.tty.writer());
        allocator.destroy(self.vaxis_state);
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn tryInputEvent(self: *InputLoop) !?InputLoopResult {
        while (try self.loop.tryEvent()) |event| {
            if (try processLoopEvent(self.allocator, &self.paste_buffer, &self.paste_active, event)) |result| {
                return result;
            }
        }
        return null;
    }
};

fn processLoopEvent(
    allocator: std.mem.Allocator,
    paste_buffer: *std.ArrayList(u8),
    paste_active: *bool,
    event: LoopEvent,
) !?InputLoopResult {
    switch (event) {
        .key_press => |key| {
            if (paste_active.*) {
                try appendPasteKeyText(allocator, paste_buffer, key);
                return null;
            }
            const parsed = keys.parsedInputFromVaxisKey(key, .press) orelse return null;
            return .{ .parsed = parsed };
        },
        .key_release => |key| {
            if (paste_active.*) return null;
            const parsed = keys.parsedInputFromVaxisKey(key, .release) orelse return null;
            return .{ .parsed = parsed };
        },
        .paste_start => {
            paste_active.* = true;
            paste_buffer.clearRetainingCapacity();
            return null;
        },
        .paste_end => {
            if (!paste_active.*) return null;
            paste_active.* = false;
            const owned = try allocator.dupe(u8, paste_buffer.items);
            paste_buffer.clearRetainingCapacity();
            return .{
                .parsed = keys.parsedPasteInput(owned),
                .owned_paste = owned,
            };
        },
        .paste => |text| {
            return .{
                .parsed = keys.parsedPasteInput(text),
                .owned_paste = text,
            };
        },
        .mouse => |mouse| {
            const parsed = keys.parsedMouseWheelInput(mouse) orelse return null;
            return .{ .parsed = parsed };
        },
    }
}

fn appendPasteKeyText(
    allocator: std.mem.Allocator,
    paste_buffer: *std.ArrayList(u8),
    key: vaxis.Key,
) !void {
    if (key.text) |text| {
        try paste_buffer.appendSlice(allocator, text);
        return;
    }

    switch (key.codepoint) {
        vaxis.Key.enter, vaxis.Key.kp_enter => try paste_buffer.append(allocator, '\r'),
        vaxis.Key.tab => try paste_buffer.append(allocator, '\t'),
        else => {
            if (key.codepoint < 0x20) return;
            var encoded: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(key.codepoint, &encoded) catch return;
            try paste_buffer.appendSlice(allocator, encoded[0..length]);
        },
    }
}

pub fn readSizeWithVaxis(_: ?*anyopaque, tty: *vaxis.Tty) ?Size {
    const winsize = tty.getWinsize() catch return null;
    return .{
        .width = winsize.cols,
        .height = winsize.rows,
    };
}

pub fn normalizeSize(size: Size, fallback: Size) Size {
    return .{
        .width = if (size.width == 0)
            if (fallback.width == 0) 80 else fallback.width
        else
            size.width,
        .height = if (size.height == 0)
            if (fallback.height == 0) 24 else fallback.height
        else
            size.height,
    };
}

pub fn parseEnvSize(value: ?[]const u8) ?usize {
    const text = value orelse return null;
    return std.fmt.parseUnsigned(usize, text, 10) catch null;
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

test "processLoopEvent maps vaxis key presses to parsed input events" {
    var paste_buffer = std.ArrayList(u8).empty;
    defer paste_buffer.deinit(std.testing.allocator);
    var paste_active = false;

    const result = (try processLoopEvent(std.testing.allocator, &paste_buffer, &paste_active, .{
        .key_press = .{
            .codepoint = 'a',
            .text = "a",
        },
    })).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(keys.ParsedInput{
        .event = .{ .key = .{ .printable = keys.PrintableKey.fromSlice("a") } },
        .consumed = 0,
    }, result.parsed);
}

test "processLoopEvent aggregates bracketed paste content from libvaxis events" {
    var paste_buffer = std.ArrayList(u8).empty;
    defer paste_buffer.deinit(std.testing.allocator);
    var paste_active = false;

    try std.testing.expect((try processLoopEvent(std.testing.allocator, &paste_buffer, &paste_active, .paste_start)) == null);
    try std.testing.expect(paste_active);

    try std.testing.expect((try processLoopEvent(std.testing.allocator, &paste_buffer, &paste_active, .{
        .key_press = .{
            .codepoint = 'h',
            .text = "h",
        },
    })) == null);
    try std.testing.expect((try processLoopEvent(std.testing.allocator, &paste_buffer, &paste_active, .{
        .key_press = .{
            .codepoint = vaxis.Key.enter,
        },
    })) == null);
    try std.testing.expect((try processLoopEvent(std.testing.allocator, &paste_buffer, &paste_active, .{
        .key_press = .{
            .codepoint = 'i',
            .text = "i",
        },
    })) == null);

    const result = (try processLoopEvent(std.testing.allocator, &paste_buffer, &paste_active, .paste_end)).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!paste_active);
    try std.testing.expectEqualStrings("h\ri", result.owned_paste.?);
    try std.testing.expectEqualDeep(keys.ParsedInput{
        .event = .{ .paste = result.owned_paste.? },
        .consumed = 0,
    }, result.parsed);
}

test "processLoopEvent forwards owned libvaxis paste events" {
    var paste_buffer = std.ArrayList(u8).empty;
    defer paste_buffer.deinit(std.testing.allocator);
    var paste_active = false;

    const text = try std.testing.allocator.dupe(u8, "clipboard");
    const result = (try processLoopEvent(std.testing.allocator, &paste_buffer, &paste_active, .{
        .paste = text,
    })).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("clipboard", result.owned_paste.?);
    try std.testing.expectEqualDeep(keys.ParsedInput{
        .event = .{ .paste = result.owned_paste.? },
        .consumed = 0,
    }, result.parsed);
}

test "LoopEvent exposes mouse events and processLoopEvent forwards wheel only" {
    comptime try std.testing.expect(@hasField(LoopEvent, "mouse"));

    var paste_buffer = std.ArrayList(u8).empty;
    defer paste_buffer.deinit(std.testing.allocator);
    var paste_active = false;

    try std.testing.expect((try processLoopEvent(std.testing.allocator, &paste_buffer, &paste_active, .{
        .mouse = .{
            .col = 4,
            .row = 5,
            .button = .left,
            .mods = .{},
            .type = .press,
        },
    })) == null);

    try std.testing.expect((try processLoopEvent(std.testing.allocator, &paste_buffer, &paste_active, .{
        .mouse = .{
            .col = 4,
            .row = 5,
            .button = .wheel_up,
            .mods = .{},
            .type = .release,
        },
    })) == null);

    const result = (try processLoopEvent(std.testing.allocator, &paste_buffer, &paste_active, .{
        .mouse = .{
            .col = 7,
            .row = 8,
            .button = .wheel_up,
            .mods = .{},
            .type = .press,
        },
    })).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(keys.ParsedInput{
        .event = .{ .mouse_wheel = .{
            .direction = .up,
            .row = 8,
            .col = 7,
        } },
        .consumed = 0,
    }, result.parsed);
}

test "terminal enters raw mode on startup and restores on exit" {
    var backend = MockBackend{};
    defer backend.deinit(std.testing.allocator);

    var terminal = Terminal.init(backend.backend());
    try terminal.start();

    try std.testing.expect(backend.entered_raw);
    try std.testing.expect(terminal.raw_mode_enabled);
    try std.testing.expectEqualStrings(
        Terminal.ALT_SCREEN_ENABLE ++ Terminal.BRACKETED_PASTE_ENABLE ++ Terminal.HIDE_CURSOR ++ Terminal.AUTO_WRAP_DISABLE ++ Terminal.KITTY_KEYBOARD_QUERY ++ Terminal.KITTY_KEYBOARD_ENABLE ++ Terminal.MOUSE_ENABLE,
        backend.writes.items[0],
    );
    try std.testing.expect(std.mem.indexOf(u8, backend.writes.items[0], "\x1b[?1002h") != null);
    try std.testing.expect(std.mem.indexOf(u8, backend.writes.items[0], "\x1b[?1006h") != null);
    try std.testing.expect(std.mem.indexOf(u8, backend.writes.items[0], "\x1b[?1003h") == null);

    terminal.stop();

    try std.testing.expect(backend.restored);
    try std.testing.expect(!terminal.raw_mode_enabled);
    try std.testing.expectEqualStrings(
        Terminal.MOUSE_DISABLE ++ Terminal.AUTO_WRAP_ENABLE ++ Terminal.ALT_SCREEN_DISABLE ++ Terminal.BRACKETED_PASTE_DISABLE ++ Terminal.KITTY_KEYBOARD_DISABLE ++ Terminal.SHOW_CURSOR,
        backend.writes.items[1],
    );
    try std.testing.expect(std.mem.indexOf(u8, backend.writes.items[1], "\x1b[?1006l") != null);
    try std.testing.expect(std.mem.indexOf(u8, backend.writes.items[1], "\x1b[?1002l") != null);
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
        Terminal.ALT_SCREEN_ENABLE ++ Terminal.BRACKETED_PASTE_ENABLE ++ Terminal.HIDE_CURSOR ++ Terminal.AUTO_WRAP_DISABLE ++ Terminal.KITTY_KEYBOARD_QUERY ++ Terminal.KITTY_KEYBOARD_ENABLE ++ Terminal.MOUSE_ENABLE,
        backend.writes.items[0],
    );
    try std.testing.expectEqualStrings(
        Terminal.MOUSE_DISABLE ++ Terminal.AUTO_WRAP_ENABLE ++ Terminal.ALT_SCREEN_DISABLE ++ Terminal.BRACKETED_PASTE_DISABLE ++ Terminal.KITTY_KEYBOARD_DISABLE ++ Terminal.SHOW_CURSOR,
        backend.writes.items[1],
    );
}

test "native terminal prefers winsize reader over environment variables" {
    const allocator = std.testing.allocator;

    const TestSizeReader = struct {
        size: Size,

        fn read(context: ?*anyopaque, tty: *vaxis.Tty) ?Size {
            _ = tty;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.size;
        }
    };

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("COLUMNS", "40");
    try env_map.put("LINES", "12");

    var reader = TestSizeReader{
        .size = .{ .width = 120, .height = 48 },
    };
    var terminal = Terminal.initNative(.{
        .io = std.testing.io,
        .env_map = &env_map,
        .read_size_fn = TestSizeReader.read,
        .read_size_context = &reader,
    });
    try terminal.start();
    defer terminal.stop();

    try std.testing.expectEqual(Size{ .width = 120, .height = 48 }, terminal.current_size);
}

test "native terminal falls back to environment variables when winsize reader fails" {
    const allocator = std.testing.allocator;

    const FailingSizeReader = struct {
        fn read(_: ?*anyopaque, tty: *vaxis.Tty) ?Size {
            _ = tty;
            return null;
        }
    };

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("COLUMNS", "132");
    try env_map.put("LINES", "43");

    var terminal = Terminal.initNative(.{
        .io = std.testing.io,
        .env_map = &env_map,
        .read_size_fn = FailingSizeReader.read,
    });
    try terminal.start();
    defer terminal.stop();

    try std.testing.expectEqual(Size{ .width = 132, .height = 43 }, terminal.current_size);
}

test "native terminal refreshes cached terminal size after libvaxis winsize callback" {
    const allocator = std.testing.allocator;

    const TestSizeReader = struct {
        size: Size,

        fn read(context: ?*anyopaque, tty: *vaxis.Tty) ?Size {
            _ = tty;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.size;
        }
    };

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var reader = TestSizeReader{
        .size = .{ .width = 80, .height = 24 },
    };
    var terminal = Terminal.initNative(.{
        .io = std.testing.io,
        .env_map = &env_map,
        .read_size_fn = TestSizeReader.read,
        .read_size_context = &reader,
    });
    try terminal.start();
    defer terminal.stop();

    reader.size = .{ .width = 101, .height = 33 };
    Terminal.handleNativeWinsize(&terminal);

    try std.testing.expectEqual(Size{ .width = 101, .height = 33 }, try terminal.refreshSize());
}
