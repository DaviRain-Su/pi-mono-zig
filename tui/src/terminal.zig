const std = @import("std");

/// Minimal terminal interface.
pub const Terminal = struct {
    start_fn: *const fn (ctx: *anyopaque, on_input: *const fn (data: []const u8) void, on_resize: *const fn () void) void,
    stop_fn: *const fn (ctx: *anyopaque) void,
    write_fn: *const fn (ctx: *anyopaque, data: []const u8) void,
    get_columns_fn: *const fn (ctx: *anyopaque) u16,
    get_rows_fn: *const fn (ctx: *anyopaque) u16,
    hide_cursor_fn: *const fn (ctx: *anyopaque) void,
    show_cursor_fn: *const fn (ctx: *anyopaque) void,
    clear_line_fn: *const fn (ctx: *anyopaque) void,
    clear_screen_fn: *const fn (ctx: *anyopaque) void,
    move_by_fn: *const fn (ctx: *anyopaque, lines: i32) void,
    ctx: *anyopaque,

    pub fn start(self: Terminal, on_input: *const fn (data: []const u8) void, on_resize: *const fn () void) void {
        self.start_fn(self.ctx, on_input, on_resize);
    }
    pub fn stop(self: Terminal) void {
        self.stop_fn(self.ctx);
    }
    pub fn write(self: Terminal, data: []const u8) void {
        self.write_fn(self.ctx, data);
    }
    pub fn columns(self: Terminal) u16 {
        return self.get_columns_fn(self.ctx);
    }
    pub fn rows(self: Terminal) u16 {
        return self.get_rows_fn(self.ctx);
    }
    pub fn hideCursor(self: Terminal) void {
        self.hide_cursor_fn(self.ctx);
    }
    pub fn showCursor(self: Terminal) void {
        self.show_cursor_fn(self.ctx);
    }
    pub fn clearLine(self: Terminal) void {
        self.clear_line_fn(self.ctx);
    }
    pub fn clearScreen(self: Terminal) void {
        self.clear_screen_fn(self.ctx);
    }
    pub fn moveBy(self: Terminal, lines: i32) void {
        self.move_by_fn(self.ctx, lines);
    }
};

/// Real terminal backed by stdin/stdout.
pub const ProcessTerminal = struct {
    tty: std.posix.fd_t,
    out: std.posix.fd_t,
    original_termios: ?std.posix.termios = null,
    kitty_active: bool = false,
    cols: u16 = 80,
    rows: u16 = 24,

    pub fn init() ProcessTerminal {
        return .{
            .tty = std.Io.File.stdin().handle,
            .out = std.Io.File.stdout().handle,
        };
    }

    pub fn asTerminal(self: *ProcessTerminal) Terminal {
        return .{
            .ctx = self,
            .start_fn = struct {
                fn f(ctx: *anyopaque, on_input: *const fn (data: []const u8) void, on_resize: *const fn () void) void {
                    const pt: *ProcessTerminal = @ptrCast(@alignCast(ctx));
                    pt.start(on_input, on_resize);
                }
            }.f,
            .stop_fn = struct {
                fn f(ctx: *anyopaque) void {
                    const pt: *ProcessTerminal = @ptrCast(@alignCast(ctx));
                    pt.stop();
                }
            }.f,
            .write_fn = struct {
                fn f(ctx: *anyopaque, data: []const u8) void {
                    const pt: *ProcessTerminal = @ptrCast(@alignCast(ctx));
                    pt.write(data);
                }
            }.f,
            .get_columns_fn = struct {
                fn f(ctx: *anyopaque) u16 {
                    const pt: *ProcessTerminal = @ptrCast(@alignCast(ctx));
                    return pt.getColumns();
                }
            }.f,
            .get_rows_fn = struct {
                fn f(ctx: *anyopaque) u16 {
                    const pt: *ProcessTerminal = @ptrCast(@alignCast(ctx));
                    return pt.getRows();
                }
            }.f,
            .hide_cursor_fn = struct {
                fn f(ctx: *anyopaque) void {
                    const pt: *ProcessTerminal = @ptrCast(@alignCast(ctx));
                    pt.hideCursor();
                }
            }.f,
            .show_cursor_fn = struct {
                fn f(ctx: *anyopaque) void {
                    const pt: *ProcessTerminal = @ptrCast(@alignCast(ctx));
                    pt.showCursor();
                }
            }.f,
            .clear_line_fn = struct {
                fn f(ctx: *anyopaque) void {
                    const pt: *ProcessTerminal = @ptrCast(@alignCast(ctx));
                    pt.clearLine();
                }
            }.f,
            .clear_screen_fn = struct {
                fn f(ctx: *anyopaque) void {
                    const pt: *ProcessTerminal = @ptrCast(@alignCast(ctx));
                    pt.clearScreen();
                }
            }.f,
            .move_by_fn = struct {
                fn f(ctx: *anyopaque, lines: i32) void {
                    const pt: *ProcessTerminal = @ptrCast(@alignCast(ctx));
                    pt.moveBy(lines);
                }
            }.f,
        };
    }

    pub fn start(self: *ProcessTerminal, on_input: *const fn (data: []const u8) void, on_resize: *const fn () void) void {
        _ = on_input;
        _ = on_resize;
        if (self.original_termios == null) {
            self.original_termios = std.posix.tcgetattr(self.tty) catch null;
        }
        var raw = self.original_termios orelse return;
        std.posix.cfmakeraw(&raw);
        std.posix.tcsetattr(self.tty, .FLUSH, raw) catch {};
        // Enable bracketed paste
        self.write("\x1b[?2004h");
        self.updateSize();
    }

    pub fn stop(self: *ProcessTerminal) void {
        if (self.original_termios) |termios| {
            std.posix.tcsetattr(self.tty, .FLUSH, termios) catch {};
        }
        self.write("\x1b[?2004l");
        self.write("\x1b[?u"); // disable kitty
    }

    pub fn write(self: *ProcessTerminal, data: []const u8) void {
        _ = std.posix.write(self.out, data) catch {};
    }

    pub fn getColumns(self: *ProcessTerminal) u16 {
        self.updateSize();
        return self.cols;
    }

    pub fn getRows(self: *ProcessTerminal) u16 {
        self.updateSize();
        return self.rows;
    }

    pub fn hideCursor(self: *ProcessTerminal) void {
        self.write("\x1b[?25l");
    }

    pub fn showCursor(self: *ProcessTerminal) void {
        self.write("\x1b[?25h");
    }

    pub fn clearLine(self: *ProcessTerminal) void {
        self.write("\x1b[2K\r");
    }

    pub fn clearScreen(self: *ProcessTerminal) void {
        self.write("\x1b[2J\x1b[H");
    }

    pub fn moveBy(self: *ProcessTerminal, lines: i32) void {
        if (lines == 0) return;
        const seq = std.fmt.allocPrint(std.heap.page_allocator, "\x1b[{d}{c}", .{ @abs(lines), if (lines < 0) 'A' else 'B' }) catch return;
        self.write(seq);
    }

    fn updateSize(self: *ProcessTerminal) void {
        var ws: std.posix.winsize = undefined;
        const err = std.posix.system.ioctl(self.tty, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (err == 0) {
            self.cols = ws.col;
            self.rows = ws.row;
        }
    }
};
