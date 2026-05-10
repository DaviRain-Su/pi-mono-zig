const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Pagination = struct {
    current_page: usize = 0,
    total_pages: usize = 1,
    max_visible: usize = 7,
    style: vaxis.Cell.Style = .{},
    active_style: vaxis.Cell.Style = .{ .reverse = true },
    disabled_style: vaxis.Cell.Style = .{ .dim = true },
    prev_label: []const u8 = "← Prev",
    next_label: []const u8 = "Next →",
    ellipsis: []const u8 = "…",

    pub fn drawComponent(self: *const Pagination) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Pagination,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        window.clear();

        if (self.total_pages == 0) return .{ .width = 0, .height = 0 };

        const current = @min(self.current_page, self.total_pages - 1);
        const pages = self.visiblePages(current);

        // Build display elements
        var elements = std.ArrayList(Element).empty;
        defer elements.deinit(std.heap.page_allocator);

        // Prev button
        const prev_disabled = current == 0;
        try elements.append(.{ .text = self.prev_label, .disabled = prev_disabled, .page = if (prev_disabled) null else current - 1 });

        // Page numbers
        var prev_page: ?usize = null;
        for (pages) |page| {
            if (prev_page != null and page > prev_page.? + 1) {
                try elements.append(.{ .text = self.ellipsis, .disabled = true, .page = null });
            }
            var buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{page + 1}) catch unreachable;
            try elements.append(.{ .text = try std.heap.page_allocator.dupe(u8, text), .active = page == current, .page = page });
            prev_page = page;
        }

        // Next button
        const next_disabled = current + 1 >= self.total_pages;
        try elements.append(.{ .text = self.next_label, .disabled = next_disabled, .page = if (next_disabled) null else current + 1 });

        // Calculate total width
        var total_width: usize = 0;
        for (elements.items) |el| {
            total_width += ansi.visibleWidth(el.text) + 2; // space padding
        }
        total_width -= 2; // remove last spacing

        var x: u16 = if (window.width > total_width) @intCast((window.width - total_width) / 2) else 0;

        for (elements.items) |el| {
            if (x >= window.width) break;
            const style = if (el.active) self.active_style else if (el.disabled) self.disabled_style else self.style;

            // Center element in its slot
            var col = x;
            var idx: usize = 0;
            while (idx < el.text.len and col < window.width) {
                const cluster = ansi.nextDisplayCluster(el.text, idx);
                if (cluster.end <= idx) break;
                window.writeCell(col, 0, .{
                    .char = .{ .grapheme = el.text[idx..cluster.end], .width = @intCast(cluster.width) },
                    .style = style,
                });
                col += @intCast(cluster.width);
                idx = cluster.end;
            }

            x = col + 2;
        }

        // Free allocated text
        for (elements.items) |el| {
            if (el.allocated) std.heap.page_allocator.free(el.text);
        }

        return .{ .width = window.width, .height = 1 };
    }

    fn visiblePages(self: *const Pagination, current: usize) []const usize {
        if (self.total_pages <= self.max_visible) {
            var result: [64]usize = undefined;
            for (0..self.total_pages) |i| result[i] = i;
            return result[0..self.total_pages];
        }

        var result: [64]usize = undefined;
        var count: usize = 0;

        // Always show first page
        result[count] = 0;
        count += 1;

        // Window around current
        const half = self.max_visible / 2;
        var start = if (current > half) current - half else 1;
        const end = @min(start + self.max_visible - 3, self.total_pages - 2);
        if (end - start < self.max_visible - 3) {
            start = if (end > self.max_visible - 3) end - (self.max_visible - 3) else 1;
        }

        if (start > 1) {
            // ellipsis handled by gap detection
        }

        for (start..end + 1) |page| {
            result[count] = page;
            count += 1;
        }

        // Always show last page
        if (self.total_pages > 1) {
            result[count] = self.total_pages - 1;
            count += 1;
        }

        return result[0..count];
    }

    pub fn prev(self: *Pagination) void {
        if (self.current_page > 0) {
            self.current_page -= 1;
        }
    }

    pub fn next(self: *Pagination) void {
        if (self.current_page + 1 < self.total_pages) {
            self.current_page += 1;
        }
    }

    pub fn goTo(self: *Pagination, page: usize) void {
        self.current_page = @min(page, self.total_pages -| 1);
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Pagination = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

const Element = struct {
    text: []const u8,
    active: bool = false,
    disabled: bool = false,
    page: ?usize = null,
    allocated: bool = false,
};

test "pagination renders prev next and page numbers" {
    const pagination = Pagination{
        .current_page = 3,
        .total_pages = 10,
    };

    var screen = try test_helpers.renderToScreen(pagination.drawComponent(), 50, 1);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "← Prev") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Next →") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "4") != null); // current page (3+1)
}

test "pagination navigation" {
    var p = Pagination{ .current_page = 0, .total_pages = 5 };
    p.next();
    try std.testing.expectEqual(@as(usize, 1), p.current_page);
    p.prev();
    try std.testing.expectEqual(@as(usize, 0), p.current_page);
    p.prev(); // clamped
    try std.testing.expectEqual(@as(usize, 0), p.current_page);
}
