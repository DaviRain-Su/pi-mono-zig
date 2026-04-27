const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const component_mod = @import("../component.zig");
const draw_mod = @import("../draw.zig");
const keys = @import("../keys.zig");
const test_helpers = @import("../test_helpers.zig");

pub const LoaderStyle = enum {
    spinner,
    dots,
    pulse,
    line,
    arc,
    bounce,
    grow,
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

    pub fn drawComponent(self: *const Loader) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
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

    pub fn draw(
        self: *const Loader,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();
        const display = try self.displayText(ctx.arena);
        const rendered_height = drawWrappedSegment(window, display, self.padding_x, self.padding_y, self.padding_y, .{});
        return .{ .width = window.width, .height = @intCast(rendered_height) };
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

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Loader = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
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
            .arc => DEFAULT_ARC_FRAMES[0..],
            .bounce => DEFAULT_BOUNCE_FRAMES[0..],
            .grow => DEFAULT_GROW_FRAMES[0..],
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

    pub fn drawComponent(self: *const CancellableLoader) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
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

    pub fn draw(
        self: *const CancellableLoader,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();
        const display = try self.loader.displayText(ctx.arena);
        const loader_height = drawWrappedSegment(
            window,
            display,
            self.loader.padding_x,
            self.loader.padding_y,
            self.loader.padding_y,
            .{},
        );
        if (!self.show_cancel_hint or loader_height >= window.height) {
            return .{ .width = window.width, .height = @intCast(loader_height) };
        }

        const hint_window = window.child(.{
            .y_off = @intCast(loader_height),
            .height = window.height - @as(u16, @intCast(loader_height)),
        });
        const hint_height = drawWrappedSegment(hint_window, self.cancel_hint, self.loader.padding_x, 0, 0, .{ .dim = true });
        return .{ .width = window.width, .height = @intCast(@min(@as(usize, window.height), loader_height + hint_height)) };
    }

    pub fn renderInto(
        self: *const CancellableLoader,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        try self.loader.renderInto(allocator, width, lines);
        if (!self.show_cancel_hint) return;
        try renderWrappedText(allocator, self.cancel_hint, width, self.loader.padding_x, 0, lines);
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

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const CancellableLoader = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

pub const DEFAULT_INTERVAL_MS: u64 = 80;
pub const DEFAULT_SPINNER_FRAMES = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const DEFAULT_DOT_FRAMES = [_][]const u8{ ".", "..", "..." };
const DEFAULT_PULSE_FRAMES = [_][]const u8{ "●○○", "○●○", "○○●" };
const DEFAULT_LINE_FRAMES = [_][]const u8{ "-", "\\", "|", "/" };
const DEFAULT_ARC_FRAMES = [_][]const u8{ "◜", "◠", "◝", "◞", "◡", "◟" };
const DEFAULT_BOUNCE_FRAMES = [_][]const u8{ "⠁", "⠂", "⠄", "⠂" };
const DEFAULT_GROW_FRAMES = [_][]const u8{ "▁", "▃", "▄", "▆", "█", "▆", "▄", "▃" };

fn resolvedIntervalMs(interval_ms: u32) u64 {
    return if (interval_ms == 0) DEFAULT_INTERVAL_MS else interval_ms;
}

fn drawWrappedSegment(
    window: vaxis.Window,
    text: []const u8,
    padding_x: usize,
    padding_top: usize,
    padding_bottom: usize,
    style: vaxis.Cell.Style,
) usize {
    const pad_x: u16 = @intCast(@min(padding_x, window.width));
    const pad_top: u16 = @intCast(@min(padding_top, window.height));
    const pad_bottom: u16 = @intCast(@min(padding_bottom, window.height - pad_top));
    if (window.width <= pad_x * 2 or window.height <= pad_top + pad_bottom) {
        return @min(window.height, pad_top + pad_bottom);
    }

    const inner = window.child(.{
        .x_off = @intCast(pad_x),
        .y_off = @intCast(pad_top),
        .width = window.width - pad_x * 2,
        .height = window.height - pad_top - pad_bottom,
    });
    const result = inner.printSegment(.{ .text = text, .style = style }, .{ .wrap = .grapheme });
    return @min(window.height, pad_top + renderedLineCount(result, text.len > 0, inner.height) + pad_bottom);
}

fn renderedLineCount(result: vaxis.Window.PrintResult, had_text: bool, max_height: u16) usize {
    if (!had_text or max_height == 0) return 0;
    if (result.overflow) return max_height;
    return @min(max_height, result.row + if (result.col > 0) @as(u16, 1) else 0);
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
    try ansi.wrapTextAlloc(allocator, text, content_width, &wrapped);

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

test "loader renders animated spinner frames" {
    var loader = Loader{ .message = "Loading..." };

    {
        var screen = try test_helpers.renderToScreen(loader.drawComponent(), 18, 1);
        defer screen.deinit(std.testing.allocator);
        try test_helpers.expectCell(&screen, 0, 0, "⠋", .{});
        try test_helpers.expectCell(&screen, 2, 0, "L", .{});
    }

    loader.advanceFrame();
    {
        var screen = try test_helpers.renderToScreen(loader.drawComponent(), 18, 1);
        defer screen.deinit(std.testing.allocator);
        try test_helpers.expectCell(&screen, 0, 0, "⠙", .{});
    }
}

test "loader supports alternate styles and elapsed time frame selection" {
    var loader = Loader{
        .message = "Syncing",
        .indicator = .{
            .style = .dots,
            .interval_ms = 120,
        },
    };
    loader.setElapsedMs(240);

    {
        var screen = try test_helpers.renderToScreen(loader.drawComponent(), 16, 1);
        defer screen.deinit(std.testing.allocator);

        const rendered = try test_helpers.screenToString(&screen);
        defer std.testing.allocator.free(rendered);
        try std.testing.expect(std.mem.startsWith(u8, rendered, "... Syncing"));
    }

    loader.setFrames(&[_][]const u8{ "[   ]", "[=  ]", "[== ]", "[===]" });
    loader.setFrameIndex(2);

    {
        var screen = try test_helpers.renderToScreen(loader.drawComponent(), 18, 1);
        defer screen.deinit(std.testing.allocator);

        const custom = try test_helpers.screenToString(&screen);
        defer std.testing.allocator.free(custom);
        try std.testing.expect(std.mem.startsWith(u8, custom, "[== ] Syncing"));
    }
}

test "loader includes additional spinner style presets" {
    var loader = Loader{
        .message = "Polishing",
        .indicator = .{ .style = .arc },
        .frame_index = 2,
    };

    {
        var screen = try test_helpers.renderToScreen(loader.drawComponent(), 16, 1);
        defer screen.deinit(std.testing.allocator);
        try test_helpers.expectCell(&screen, 0, 0, "◝", .{});
    }

    loader.setStyle(.grow);
    loader.setFrameIndex(4);

    {
        var screen = try test_helpers.renderToScreen(loader.drawComponent(), 16, 1);
        defer screen.deinit(std.testing.allocator);
        try test_helpers.expectCell(&screen, 0, 0, "█", .{});
    }
}

test "cancellable loader renders dim cancel hint and aborts on escape" {
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

    var screen = try test_helpers.renderToScreen(loader.drawComponent(), 24, 2);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, "|", .{});
    try test_helpers.expectCell(&screen, 0, 1, "E", .{ .dim = true });
    try std.testing.expectEqual(CancellableHandleResult.ignored, loader.handleKey(.enter));
    try std.testing.expect(!loader.aborted());

    try std.testing.expectEqual(CancellableHandleResult.aborted, loader.handleKey(.escape));
    try std.testing.expect(loader.signal().load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 1), callback_count.load(.seq_cst));
}
