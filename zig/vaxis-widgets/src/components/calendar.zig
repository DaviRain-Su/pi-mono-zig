const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const Calendar = struct {
    year: u16,
    month: u8, // 1-12
    day: ?u8 = null,
    style: vaxis.Cell.Style = .{},
    header_style: vaxis.Cell.Style = .{ .bold = true },
    weekend_style: vaxis.Cell.Style = .{ .dim = true },
    selected_style: vaxis.Cell.Style = .{ .reverse = true },
    today_style: vaxis.Cell.Style = .{ .bold = true, .ul_style = .single },
    today: ?u8 = null,
    show_header: bool = true,
    show_weekdays: bool = true,

    pub fn drawComponent(self: *const Calendar) draw_mod.Component {
        return draw_mod.component(self, drawOpaque);
    }

    pub fn draw(
        self: *const Calendar,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        if (window.width == 0 or window.height == 0) {
            return .{ .width = window.width, .height = 0 };
        }

        const day_names = &[_][]const u8{ "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" };
        const month_names = &[_][]const u8{
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December",
        };

        var y: u16 = 0;

        // Header: Month Year
        if (self.show_header) {
            if (y >= window.height) return .{ .width = window.width, .height = y };
            const header = try std.fmt.allocPrint(ctx.arena, "{s} {d}", .{
                month_names[@min(self.month - 1, 11)],
                self.year,
            });
            const header_width = ansi.visibleWidth(header);
            const start_col: u16 = if (header_width < window.width)
                @intCast((window.width - header_width) / 2)
            else
                0;
            var col = start_col;
            for (header) |byte| {
                if (col >= window.width) break;
                const grapheme = try std.fmt.allocPrint(ctx.arena, "{c}", .{byte});
                window.writeCell(col, y, .{
                    .char = .{ .grapheme = grapheme, .width = 1 },
                    .style = self.header_style,
                });
                col += 1;
            }
            y += 1;
        }

        // Weekday headers
        if (self.show_weekdays) {
            if (y >= window.height) return .{ .width = window.width, .height = y };
            for (day_names, 0..) |name, i| {
                const col: u16 = @intCast(i * 3);
                if (col + 1 >= window.width) break;
                var style = self.header_style;
                if (i == 0 or i == 6) style = mergeStyle(style, self.weekend_style);
                window.writeCell(col, y, .{
                    .char = .{ .grapheme = name[0..1], .width = 1 },
                    .style = style,
                });
                window.writeCell(col + 1, y, .{
                    .char = .{ .grapheme = name[1..2], .width = 1 },
                    .style = style,
                });
            }
            y += 1;
        }

        // Days grid
        const days_in_month = daysInMonth(self.year, self.month);
        const first_weekday = weekdayOfFirstDay(self.year, self.month);

        var day: u8 = 1;
        var row: u16 = 0;
        while (day <= days_in_month and y < window.height) : (row += 1) {
            for (0..7) |col_idx| {
                if (day > days_in_month) break;
                if (row == 0 and col_idx < first_weekday) continue;

                const col: u16 = @intCast(col_idx * 3);
                if (col >= window.width) break;

                const is_weekend = col_idx == 0 or col_idx == 6;
                const is_selected = self.day != null and self.day.? == day;
                const is_today = self.today != null and self.today.? == day;

                var cell_style = self.style;
                if (is_weekend) cell_style = mergeStyle(cell_style, self.weekend_style);
                if (is_selected) cell_style = mergeStyle(cell_style, self.selected_style);
                if (is_today) cell_style = mergeStyle(cell_style, self.today_style);

                const day_text = try std.fmt.allocPrint(ctx.arena, "{d:0>2}", .{day});

                window.writeCell(col, y, .{
                    .char = .{ .grapheme = day_text[0..1], .width = 1 },
                    .style = cell_style,
                });
                if (col + 1 < window.width) {
                    window.writeCell(col + 1, y, .{
                        .char = .{ .grapheme = day_text[1..2], .width = 1 },
                        .style = cell_style,
                    });
                }

                day += 1;
            }
            y += 1;
        }

        return .{ .width = window.width, .height = y };
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Calendar = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 31,
    };
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

// Returns weekday of the first day of the month (0=Sunday, 1=Monday, ...)
// Uses 2024-01-01 (Monday = 1) as anchor
fn weekdayOfFirstDay(year: u16, month: u8) u8 {
    var total_days: i32 = 0;

    // Days between anchor year and target year
    if (year >= 2024) {
        var y: u16 = 2024;
        while (y < year) : (y += 1) {
            total_days += if (isLeapYear(y)) 366 else 365;
        }
    } else {
        var y: u16 = 2024;
        while (y > year) : (y -= 1) {
            total_days -= if (isLeapYear(y - 1)) 366 else 365;
        }
    }

    // Days for months before target month in target year
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        total_days += daysInMonth(year, m);
    }

    const anchor_weekday: i32 = 1; // Monday
    const result = @mod(anchor_weekday + total_days, 7);
    return @intCast(result);
}

fn mergeStyle(base: vaxis.Cell.Style, overlay: vaxis.Cell.Style) vaxis.Cell.Style {
    return .{
        .fg = if (overlay.fg != .default) overlay.fg else base.fg,
        .bg = if (overlay.bg != .default) overlay.bg else base.bg,
        .bold = overlay.bold or base.bold,
        .dim = overlay.dim or base.dim,
        .italic = overlay.italic or base.italic,
        .ul_style = if (overlay.ul_style != .off) overlay.ul_style else base.ul_style,
        .reverse = overlay.reverse or base.reverse,
        .blink = overlay.blink or base.blink,
        .invisible = overlay.invisible or base.invisible,
        .strikethrough = overlay.strikethrough or base.strikethrough,
    };
}

test "calendar renders month header and days" {
    const cal = Calendar{
        .year = 2024,
        .month = 1, // January 2024
        .today = 15,
        .day = 1,
    };

    var screen = try test_helpers.renderToScreen(cal.drawComponent(), 21, 8);
    defer screen.deinit(std.testing.allocator);

    // Check header (centered: "January 2024" width=12, start=(21-12)/2=4)
    try test_helpers.expectCell(&screen, 4, 0, "J", .{ .bold = true });

    // Check weekday header (Sunday = weekend = dim)
    try test_helpers.expectCell(&screen, 0, 1, "S", .{ .bold = true, .dim = true });
}

test "calendar shows selected day with reverse style" {
    const cal = Calendar{
        .year = 2024,
        .month = 1,
        .day = 1,
    };

    var screen = try test_helpers.renderToScreen(cal.drawComponent(), 21, 8);
    defer screen.deinit(std.testing.allocator);

    // January 1, 2024 is a Monday (col 3)
    const cell = screen.readCell(3, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(cell.style.reverse);
    try std.testing.expectEqualStrings("0", cell.char.grapheme);
}
