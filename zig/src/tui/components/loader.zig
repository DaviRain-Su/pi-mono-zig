const std = @import("std");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const keys = @import("../keys.zig");

pub const LoaderStyle = enum {
    spinner,
    dots,
    pulse,
    line,
    custom,
};

pub const LoaderIndicatorOptions = struct {
    style: LoaderStyle = .spinner,
    custom_frames: ?[]const []const u8 = null,
    interval_ms: u32 = @intCast(DEFAULT_INTERVAL_MS),
};

pub const Loader = struct {
    message: []const u8 = "Loading...",
    indicator: LoaderIndicatorOptions = .{},
    frame_index: usize = 0,
    padding_x: usize = 0,
    padding_y: usize = 0,

    pub fn component(self: *const Loader) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn setMessage(self: *Loader, message: []const u8) void {
        self.message = message;
    }

    pub fn setStyle(self: *Loader, style: LoaderStyle) void {
        self.indicator.style = style;
        if (style != .custom) self.indicator.custom_frames = null;
        self.frame_index = 0;
    }

    pub fn setFrames(self: *Loader, new_frames: []const []const u8) void {
        self.indicator.style = .custom;
        self.indicator.custom_frames = new_frames;
        self.frame_index = 0;
    }

    pub fn setFrameIndex(self: *Loader, index: usize) void {
        self.frame_index = index;
    }

    pub fn setElapsedMs(self: *Loader, elapsed_ms: u64) void {
        self.frame_index = self.frameIndexForElapsed(elapsed_ms);
    }

    pub fn frameIndexForElapsed(self: *const Loader, elapsed_ms: u64) usize {
        const indicator_frames = self.indicatorFrames();
        if (indicator_frames.len == 0) return 0;
        const interval_ms = resolvedIntervalMs(self.indicator.interval_ms);
        const elapsed_frames = @as(usize, @intCast(elapsed_ms / interval_ms));
        return elapsed_frames % indicator_frames.len;
    }

    pub fn advanceFrame(self: *Loader) void {
        const indicator_frames = self.indicatorFrames();
        if (indicator_frames.len == 0) return;
        self.frame_index = (self.frame_index + 1) % indicator_frames.len;
    }

    pub fn currentFrame(self: *const Loader) []const u8 {
        const indicator_frames = self.indicatorFrames();
        if (indicator_frames.len == 0) return "";
        return indicator_frames[self.frame_index % indicator_frames.len];
    }

    pub fn renderInto(
        self: *const Loader,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const display = try self.displayText(allocator);
        defer allocator.free(display);
        try renderWrappedText(allocator, display, width, self.padding_x, self.padding_y, lines);
    }

    fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const Loader = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }

    fn displayText(self: *const Loader, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const frame = self.currentFrame();
        if (frame.len == 0) return allocator.dupe(u8, self.message);
        if (self.message.len == 0) return allocator.dupe(u8, frame);
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ frame, self.message });
    }

    fn indicatorFrames(self: *const Loader) []const []const u8 {
        if (self.indicator.style == .custom) {
            return self.indicator.custom_frames orelse &[_][]const u8{};
        }

        return switch (self.indicator.style) {
            .spinner => DEFAULT_SPINNER_FRAMES[0..],
            .dots => DEFAULT_DOT_FRAMES[0..],
            .pulse => DEFAULT_PULSE_FRAMES[0..],
            .line => DEFAULT_LINE_FRAMES[0..],
            .custom => unreachable,
        };
    }
};

pub const AbortCallback = struct {
    context: ?*anyopaque = null,
    callback: *const fn (context: ?*anyopaque) void,

    fn invoke(self: AbortCallback) void {
        self.callback(self.context);
    }
};

pub const CancellableHandleResult = enum {
    ignored,
    aborted,
};

pub const CancellableLoader = struct {
    loader: Loader = .{},
    cancel_hint: []const u8 = "Esc to cancel",
    show_cancel_hint: bool = true,
    on_abort: ?AbortCallback = null,
    abort_signal: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn component(self: *const CancellableLoader) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn signal(self: *CancellableLoader) *std.atomic.Value(bool) {
        return &self.abort_signal;
    }

    pub fn aborted(self: *const CancellableLoader) bool {
        return self.abort_signal.load(.seq_cst);
    }

    pub fn reset(self: *CancellableLoader) void {
        self.abort_signal.store(false, .seq_cst);
    }

    pub fn handleKey(self: *CancellableLoader, key: keys.Key) CancellableHandleResult {
        switch (key) {
            .escape => {
                if (!self.aborted()) {
                    self.abort_signal.store(true, .seq_cst);
                    if (self.on_abort) |callback| callback.invoke();
                }
                return .aborted;
            },
            else => return .ignored,
        }
    }

    pub fn renderInto(
        self: *const CancellableLoader,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        try self.loader.renderInto(allocator, width, lines);
        if (!self.show_cancel_hint) return;

        const hint = try std.fmt.allocPrint(allocator, "\x1b[2m{s}\x1b[0m", .{self.cancel_hint});
        defer allocator.free(hint);
        try renderWrappedText(allocator, hint, width, self.loader.padding_x, 0, lines);
    }

    fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const CancellableLoader = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }
};

const DEFAULT_INTERVAL_MS: u64 = 80;
const DEFAULT_SPINNER_FRAMES = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const DEFAULT_DOT_FRAMES = [_][]const u8{ ".", "..", "..." };
const DEFAULT_PULSE_FRAMES = [_][]const u8{ "●○○", "○●○", "○○●" };
const DEFAULT_LINE_FRAMES = [_][]const u8{ "-", "\\", "|", "/" };

fn resolvedIntervalMs(interval_ms: u32) u64 {
    return if (interval_ms == 0) DEFAULT_INTERVAL_MS else interval_ms;
}

fn renderWrappedText(
    allocator: std.mem.Allocator,
    text: []const u8,
    width: usize,
    padding_x: usize,
    padding_y: usize,
    lines: *component_mod.LineList,
) std.mem.Allocator.Error!void {
    const effective_width = @max(width, 1);
    const content_width = @max(effective_width, padding_x * 2 + 1) - padding_x * 2;

    var wrapped = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &wrapped);
    try ansi.wrapTextWithAnsi(allocator, text, content_width, &wrapped);

    const blank_line = try allocator.alloc(u8, effective_width);
    defer allocator.free(blank_line);
    @memset(blank_line, ' ');

    for (0..padding_y) |_| {
        try component_mod.appendOwnedLine(lines, allocator, blank_line);
    }

    for (wrapped.items) |line| {
        var builder = std.ArrayList(u8).empty;
        errdefer builder.deinit(allocator);

        try builder.appendNTimes(allocator, ' ', padding_x);
        try builder.appendSlice(allocator, line);

        const padded = try ansi.padRightVisibleAlloc(allocator, builder.items, effective_width);
        defer allocator.free(padded);
        try component_mod.appendOwnedLine(lines, allocator, padded);
        builder.deinit(allocator);
    }

    for (0..padding_y) |_| {
        try component_mod.appendOwnedLine(lines, allocator, blank_line);
    }
}

fn renderLines(
    allocator: std.mem.Allocator,
    component: component_mod.Component,
    width: usize,
) !component_mod.LineList {
    var lines = component_mod.LineList.empty;
    errdefer component_mod.freeLines(allocator, &lines);
    try component.renderInto(allocator, width, &lines);
    return lines;
}

test "loader renders animated spinner frames" {
    const allocator = std.testing.allocator;

    var loader = Loader{ .message = "Loading..." };

    var first = try renderLines(allocator, loader.component(), 18);
    defer component_mod.freeLines(allocator, &first);
    try std.testing.expectEqual(@as(usize, 1), first.items.len);
    try std.testing.expect(std.mem.indexOf(u8, first.items[0], "⠋ Loading...") != null);

    loader.advanceFrame();
    var second = try renderLines(allocator, loader.component(), 18);
    defer component_mod.freeLines(allocator, &second);
    try std.testing.expect(std.mem.indexOf(u8, second.items[0], "⠙ Loading...") != null);
    try std.testing.expect(!std.mem.eql(u8, first.items[0], second.items[0]));
}

test "loader supports alternate styles and elapsed time frame selection" {
    const allocator = std.testing.allocator;

    var loader = Loader{
        .message = "Syncing",
        .indicator = .{
            .style = .dots,
            .interval_ms = 120,
        },
    };
    loader.setElapsedMs(240);

    var builtin = try renderLines(allocator, loader.component(), 16);
    defer component_mod.freeLines(allocator, &builtin);
    try std.testing.expect(std.mem.indexOf(u8, builtin.items[0], "... Syncing") != null);

    loader.setFrames(&[_][]const u8{ "[   ]", "[=  ]", "[== ]", "[===]" });
    loader.setFrameIndex(2);

    var custom = try renderLines(allocator, loader.component(), 18);
    defer component_mod.freeLines(allocator, &custom);
    try std.testing.expect(std.mem.indexOf(u8, custom.items[0], "[== ] Syncing") != null);
}

test "cancellable loader renders cancel hint and aborts on escape" {
    const allocator = std.testing.allocator;

    var callback_count = std.atomic.Value(u32).init(0);
    const CallbackContext = struct {
        fn onAbort(context: ?*anyopaque) void {
            const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(context.?));
            _ = counter.fetchAdd(1, .seq_cst);
        }
    };

    var loader = CancellableLoader{
        .loader = .{
            .message = "Working",
            .indicator = .{ .style = .line },
            .frame_index = 2,
        },
        .on_abort = .{
            .context = &callback_count,
            .callback = CallbackContext.onAbort,
        },
    };

    var lines = try renderLines(allocator, loader.component(), 24);
    defer component_mod.freeLines(allocator, &lines);

    try std.testing.expectEqual(@as(usize, 2), lines.items.len);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[0], "| Working") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines.items[1], "Esc to cancel") != null);
    try std.testing.expectEqual(CancellableHandleResult.ignored, loader.handleKey(.enter));
    try std.testing.expect(!loader.aborted());

    try std.testing.expectEqual(CancellableHandleResult.aborted, loader.handleKey(.escape));
    try std.testing.expect(loader.signal().load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 1), callback_count.load(.seq_cst));
}
