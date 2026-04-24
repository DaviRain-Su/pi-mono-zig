const std = @import("std");
const component_mod = @import("../component.zig");

pub const Spacer = struct {
    lines: usize = 1,

    pub fn component(self: *const Spacer) component_mod.Component {
        return .{
            .ptr = self,
            .renderIntoFn = renderIntoOpaque,
        };
    }

    pub fn setLines(self: *Spacer, lines: usize) void {
        self.lines = lines;
    }

    pub fn renderInto(
        self: *const Spacer,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const effective_width = @max(width, 1);
        const blank_line = try allocator.alloc(u8, effective_width);
        defer allocator.free(blank_line);
        @memset(blank_line, ' ');

        for (0..self.lines) |_| {
            try component_mod.appendOwnedLine(lines, allocator, blank_line);
        }
    }

    fn renderIntoOpaque(
        ptr: *const anyopaque,
        allocator: std.mem.Allocator,
        width: usize,
        lines: *component_mod.LineList,
    ) std.mem.Allocator.Error!void {
        const self: *const Spacer = @ptrCast(@alignCast(ptr));
        try self.renderInto(allocator, width, lines);
    }
};

test "spacer renders the requested number of blank lines" {
    const allocator = std.testing.allocator;

    const spacer = Spacer{ .lines = 3 };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try spacer.renderInto(allocator, 5, &lines);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("     ", lines.items[0]);
    try std.testing.expectEqualStrings("     ", lines.items[1]);
    try std.testing.expectEqualStrings("     ", lines.items[2]);
}

test "spacer can render zero lines" {
    const allocator = std.testing.allocator;

    const spacer = Spacer{ .lines = 0 };

    var lines = component_mod.LineList.empty;
    defer component_mod.freeLines(allocator, &lines);

    try spacer.renderInto(allocator, 4, &lines);

    try std.testing.expectEqual(@as(usize, 0), lines.items.len);
}
