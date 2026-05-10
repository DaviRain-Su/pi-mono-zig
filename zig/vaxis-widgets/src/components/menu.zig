const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const layout = @import("../layout.zig");
const test_helpers = @import("../test_helpers.zig");
const keys = @import("../keys.zig");

pub const MenuItem = struct {
    label: []const u8 = "",
    shortcut: ?[]const u8 = null,
    enabled: bool = true,
    separator: bool = false,
};

pub const Menu = struct {
    label: []const u8,
    items: []const MenuItem,
};

pub const MenuResult = union(enum) {
    selected: usize,
    dismissed,
    ignored,
};

pub const MenuBar = struct {
    menus: []const Menu,
    selected_index: usize = 0,
    open: bool = false,
    menu_selected_index: usize = 0,
    style: vaxis.Cell.Style = .{},
    highlight_style: vaxis.Cell.Style = .{ .reverse = true },
    disabled_style: vaxis.Cell.Style = .{ .dim = true },
    separator_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },

    pub fn drawComponent(self: *const MenuBar) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const MenuBar,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        window.clear();
        if (window.width == 0 or window.height == 0) return .{ .width = window.width, .height = 0 };

        var x: u16 = 2;
        const selected_index = if (self.menus.len == 0) 0 else @min(self.selected_index, self.menus.len - 1);
        for (self.menus, 0..) |menu, i| {
            if (x >= window.width) break;
            const is_selected = i == selected_index;
            const style = if (is_selected and self.open) self.highlight_style else if (is_selected) self.highlight_style else self.style;

            const label = menu.label;

            // Draw label with underline for first char (mnemonic)
            var col = x;
            var idx: usize = 0;
            while (idx < label.len and col < window.width) {
                const cluster = ansi.nextDisplayCluster(label, idx);
                if (cluster.end <= idx) break;

                var cell_style = style;
                if (idx == 0) {
                    cell_style = style;
                    cell_style.ul_style = .single;
                }

                window.writeCell(col, 0, .{
                    .char = .{ .grapheme = label[idx..cluster.end], .width = @intCast(cluster.width) },
                    .style = cell_style,
                });
                col += @intCast(cluster.width);
                idx = cluster.end;
            }

            x = col + 3;
        }

        // Draw open menu dropdown
        if (self.open and selected_index < self.menus.len and window.height > 1) {
            const menu = self.menus[selected_index];
            const dropdown_width = self.computeDropdownWidth(menu);
            const dropdown_height = @min(menu.items.len + 2, @as(usize, window.height) - 1);

            if (dropdown_height > 2) {
                const dropdown = window.child(.{
                    .x_off = 2,
                    .y_off = 1,
                    .width = @intCast(dropdown_width),
                    .height = @intCast(dropdown_height),
                });
                self.drawDropdown(dropdown, menu);
            }
        }

        return .{ .width = window.width, .height = 1 };
    }

    fn drawDropdown(self: *const MenuBar, window: vaxis.Window, menu: Menu) void {
        // Border
        const style = self.style;
        for (0..window.width) |col| {
            window.writeCell(@intCast(col), 0, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = style,
            });
            window.writeCell(@intCast(col), window.height - 1, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = style,
            });
        }
        for (1..window.height - 1) |row| {
            window.writeCell(0, @intCast(row), .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = style,
            });
            window.writeCell(window.width - 1, @intCast(row), .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = style,
            });
        }
        window.writeCell(0, 0, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = style });
        window.writeCell(window.width - 1, 0, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = style });
        window.writeCell(0, window.height - 1, .{ .char = .{ .grapheme = "└", .width = 1 }, .style = style });
        window.writeCell(window.width - 1, window.height - 1, .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = style });

        // Items
        const inner = window.child(.{
            .x_off = 1,
            .y_off = 1,
            .width = window.width -| 2,
            .height = window.height -| 2,
        });

        for (menu.items, 0..) |item, i| {
            if (i >= inner.height) break;
            const row_window = inner.child(.{ .y_off = @intCast(i), .height = 1 });

            if (item.separator) {
                for (0..inner.width) |col| {
                    row_window.writeCell(@intCast(col), 0, .{
                        .char = .{ .grapheme = "─", .width = 1 },
                        .style = self.separator_style,
                    });
                }
                continue;
            }

            const is_selected = i == self.menu_selected_index;
            const item_style = if (is_selected and item.enabled) self.highlight_style else if (!item.enabled) self.disabled_style else self.style;

            row_window.fill(.{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = item_style,
            });

            // Label
            _ = row_window.printSegment(.{ .text = item.label, .style = item_style }, .{ .wrap = .none });

            // Shortcut
            if (item.shortcut) |shortcut| {
                const shortcut_width = ansi.visibleWidth(shortcut);
                if (shortcut_width < inner.width) {
                    const shortcut_x = inner.width -| shortcut_width;
                    const shortcut_window = row_window.child(.{
                        .x_off = @intCast(shortcut_x),
                        .width = @intCast(shortcut_width),
                    });
                    _ = shortcut_window.printSegment(.{
                        .text = shortcut,
                        .style = if (is_selected) self.highlight_style else self.disabled_style,
                    }, .{ .wrap = .none });
                }
            }
        }
    }

    fn computeDropdownWidth(self: *const MenuBar, menu: Menu) usize {
        _ = self;
        var max_width: usize = 4; // minimum with borders
        for (menu.items) |item| {
            var width = ansi.visibleWidth(item.label) + 2;
            if (item.shortcut) |shortcut| {
                width += ansi.visibleWidth(shortcut) + 4;
            }
            max_width = @max(max_width, width);
        }
        return @min(max_width, 40);
    }

    pub fn handleKey(self: *MenuBar, key: keys.Key) MenuResult {
        self.clampSelectedMenu();
        if (!self.open) {
            switch (key) {
                .left => {
                    if (self.selected_index > 0) {
                        self.selected_index -= 1;
                    } else if (self.menus.len > 0) {
                        self.selected_index = self.menus.len - 1;
                    }
                    return .ignored;
                },
                .right => {
                    if (self.menus.len > 0 and self.selected_index + 1 < self.menus.len) {
                        self.selected_index += 1;
                    } else {
                        self.selected_index = 0;
                    }
                    return .ignored;
                },
                .down, .enter => {
                    if (self.menus.len > 0) {
                        self.open = true;
                        self.selectFirstMenuItem();
                    }
                    return .ignored;
                },
                .escape => return .dismissed,
                else => return .ignored,
            }
        } else {
            switch (key) {
                .down => {
                    self.moveMenuSelection(1);
                    return .ignored;
                },
                .up => {
                    self.moveMenuSelection(-1);
                    return .ignored;
                },
                .left => {
                    if (self.selected_index > 0) {
                        self.selected_index -= 1;
                    } else {
                        self.selected_index = self.menus.len -| 1;
                    }
                    self.menu_selected_index = 0;
                    return .ignored;
                },
                .right => {
                    if (self.selected_index + 1 < self.menus.len) {
                        self.selected_index += 1;
                    } else {
                        self.selected_index = 0;
                    }
                    self.menu_selected_index = 0;
                    return .ignored;
                },
                .enter => {
                    if (self.selected_index < self.menus.len) {
                        const menu = self.menus[self.selected_index];
                        if (self.menu_selected_index < menu.items.len and
                            menu.items[self.menu_selected_index].enabled and
                            !menu.items[self.menu_selected_index].separator)
                        {
                            self.open = false;
                            return .{ .selected = self.menu_selected_index };
                        }
                    }
                    return .ignored;
                },
                .escape => {
                    self.open = false;
                    return .ignored;
                },
                else => return .ignored,
            }
        }
    }

    fn moveMenuSelection(self: *MenuBar, direction: i2) void {
        self.clampSelectedMenu();
        if (self.selected_index >= self.menus.len) return;
        const menu = self.menus[self.selected_index];
        if (menu.items.len == 0) return;

        const count: i32 = @intCast(menu.items.len);
        var new_idx: i32 = @intCast(@min(self.menu_selected_index, menu.items.len - 1));

        var visited: usize = 0;
        while (visited < menu.items.len) : (visited += 1) {
            new_idx += direction;
            if (new_idx < 0) new_idx = count - 1;
            if (new_idx >= count) new_idx = 0;

            const idx: usize = @intCast(new_idx);
            if (!menu.items[idx].separator) {
                self.menu_selected_index = idx;
                break;
            }

        }
    }

    fn clampSelectedMenu(self: *MenuBar) void {
        if (self.menus.len == 0) {
            self.selected_index = 0;
            self.menu_selected_index = 0;
            return;
        }
        self.selected_index = @min(self.selected_index, self.menus.len - 1);
        self.menu_selected_index = @min(self.menu_selected_index, self.menus[self.selected_index].items.len);
    }

    fn selectFirstMenuItem(self: *MenuBar) void {
        self.clampSelectedMenu();
        if (self.selected_index >= self.menus.len) return;
        const menu = self.menus[self.selected_index];
        self.menu_selected_index = 0;
        while (self.menu_selected_index < menu.items.len and menu.items[self.menu_selected_index].separator) {
            self.menu_selected_index += 1;
        }
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const MenuBar = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

pub const ContextMenu = struct {
    items: []const MenuItem,
    selected_index: usize = 0,
    style: vaxis.Cell.Style = .{},
    highlight_style: vaxis.Cell.Style = .{ .reverse = true },
    disabled_style: vaxis.Cell.Style = .{ .dim = true },
    separator_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    border_style: vaxis.Cell.Style = .{},
    width: ?usize = null,

    pub fn drawComponent(self: *const ContextMenu) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const ContextMenu,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        _ = ctx;
        window.clear();

        const menu_width = self.width orelse self.computeWidth();
        const menu_height = @min(self.items.len + 2, @as(usize, window.height));
        if (menu_width < 2 or menu_height < 2 or window.width < 2 or window.height < 2) {
            return .{ .width = @intCast(@min(menu_width, @as(usize, window.width))), .height = @intCast(menu_height) };
        }

        if (menu_width > window.width or menu_height > window.height) {
            return .{ .width = window.width, .height = window.height };
        }

        // Border
        const bstyle = self.border_style;
        for (0..menu_width) |col| {
            window.writeCell(@intCast(col), 0, .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = bstyle,
            });
            window.writeCell(@intCast(col), @intCast(menu_height - 1), .{
                .char = .{ .grapheme = "─", .width = 1 },
                .style = bstyle,
            });
        }
        for (1..menu_height - 1) |row| {
            window.writeCell(0, @intCast(row), .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = bstyle,
            });
            window.writeCell(@intCast(menu_width - 1), @intCast(row), .{
                .char = .{ .grapheme = "│", .width = 1 },
                .style = bstyle,
            });
        }
        window.writeCell(0, 0, .{ .char = .{ .grapheme = "┌", .width = 1 }, .style = bstyle });
        window.writeCell(@intCast(menu_width - 1), 0, .{ .char = .{ .grapheme = "┐", .width = 1 }, .style = bstyle });
        window.writeCell(0, @intCast(menu_height - 1), .{ .char = .{ .grapheme = "└", .width = 1 }, .style = bstyle });
        window.writeCell(@intCast(menu_width - 1), @intCast(menu_height - 1), .{ .char = .{ .grapheme = "┘", .width = 1 }, .style = bstyle });

        // Items
        const inner = window.child(.{
            .x_off = 1,
            .y_off = 1,
            .width = @intCast(menu_width - 2),
            .height = @intCast(menu_height - 2),
        });

        for (self.items, 0..) |item, i| {
            if (i >= inner.height) break;
            const row_window = inner.child(.{ .y_off = @intCast(i), .height = 1 });

            if (item.separator) {
                for (0..inner.width) |col| {
                    row_window.writeCell(@intCast(col), 0, .{
                        .char = .{ .grapheme = "─", .width = 1 },
                        .style = self.separator_style,
                    });
                }
                continue;
            }

            const is_selected = i == self.selected_index;
            const item_style = if (is_selected and item.enabled) self.highlight_style else if (!item.enabled) self.disabled_style else self.style;

            row_window.fill(.{
                .char = .{ .grapheme = " ", .width = 1 },
                .style = item_style,
            });

            _ = row_window.printSegment(.{ .text = item.label, .style = item_style }, .{ .wrap = .none });
        }

        return .{ .width = @intCast(menu_width), .height = @intCast(menu_height) };
    }

    pub fn handleKey(self: *ContextMenu, key: keys.Key) MenuResult {
        switch (key) {
            .down => {
                self.moveSelection(1);
                return .ignored;
            },
            .up => {
                self.moveSelection(-1);
                return .ignored;
            },
            .enter => {
                if (self.selected_index < self.items.len and
                    self.items[self.selected_index].enabled and
                    !self.items[self.selected_index].separator)
                {
                    return .{ .selected = self.selected_index };
                }
                return .ignored;
            },
            .escape => return .dismissed,
            else => return .ignored,
        }
    }

    fn moveSelection(self: *ContextMenu, direction: i2) void {
        if (self.items.len == 0) return;
        const count: i32 = @intCast(self.items.len);
        var new_idx: i32 = @intCast(@min(self.selected_index, self.items.len - 1));

        var visited: usize = 0;
        while (visited < self.items.len) : (visited += 1) {
            new_idx += direction;
            if (new_idx < 0) new_idx = count - 1;
            if (new_idx >= count) new_idx = 0;

            const idx: usize = @intCast(new_idx);
            if (!self.items[idx].separator) {
                self.selected_index = idx;
                break;
            }
        }
    }

    fn computeWidth(self: *const ContextMenu) usize {
        var max_width: usize = 4;
        for (self.items) |item| {
            var width = ansi.visibleWidth(item.label) + 2;
            if (item.shortcut) |shortcut| {
                width += ansi.visibleWidth(shortcut) + 4;
            }
            max_width = @max(max_width, width);
        }
        return @min(max_width, 40);
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const ContextMenu = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "menu bar renders labels and handles navigation" {
    const menus = &[_]Menu{
        .{
            .label = "File",
            .items = &[_]MenuItem{
                .{ .label = "Open", .shortcut = "Ctrl+O" },
                .{ .label = "Save", .shortcut = "Ctrl+S" },
                .{ .separator = true },
                .{ .label = "Exit" },
            },
        },
        .{ .label = "Edit", .items = &[_]MenuItem{.{ .label = "Copy" }} },
    };

    var menu_bar = MenuBar{ .menus = menus };

    var screen = try test_helpers.renderToScreen(menu_bar.drawComponent(), 20, 1);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "File") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Edit") != null);

    _ = menu_bar.handleKey(.right);
    try std.testing.expectEqual(@as(usize, 1), menu_bar.selected_index);

    _ = menu_bar.handleKey(.down);
    try std.testing.expect(menu_bar.open);
}

test "context menu renders items with border" {
    const items = &[_]MenuItem{
        .{ .label = "Copy" },
        .{ .label = "Paste", .enabled = false },
        .{ .separator = true },
        .{ .label = "Delete" },
    };

    var menu = ContextMenu{ .items = items, .width = 12 };

    var screen = try test_helpers.renderToScreen(menu.drawComponent(), 12, 6);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Paste") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Delete") != null);

    const result = menu.handleKey(.enter);
    try std.testing.expectEqual(@as(usize, 0), result.selected);
}

test "menu bar clamps stale selected index before opening" {
    const menus = &[_]Menu{
        .{ .label = "File", .items = &[_]MenuItem{.{ .label = "Open" }} },
    };

    var menu_bar = MenuBar{ .menus = menus, .selected_index = 99 };
    _ = menu_bar.handleKey(.down);

    try std.testing.expect(menu_bar.open);
    try std.testing.expectEqual(@as(usize, 0), menu_bar.selected_index);
    try std.testing.expectEqual(@as(usize, 0), menu_bar.menu_selected_index);
}

test "menu bar all-separator menu navigation terminates" {
    const menus = &[_]Menu{
        .{ .label = "File", .items = &[_]MenuItem{
            .{ .separator = true },
            .{ .separator = true },
        } },
    };

    var menu_bar = MenuBar{ .menus = menus };
    _ = menu_bar.handleKey(.down);
    _ = menu_bar.handleKey(.down);
    _ = menu_bar.handleKey(.up);

    try std.testing.expect(menu_bar.open);
    try std.testing.expectEqual(@as(usize, 2), menu_bar.menu_selected_index);
}

test "context menu handles tiny windows" {
    const items = &[_]MenuItem{.{ .label = "Copy" }};
    const menu = ContextMenu{ .items = items, .width = 1 };

    var screen = try test_helpers.renderToScreen(menu.drawComponent(), 1, 1);
    defer screen.deinit(std.testing.allocator);

    try test_helpers.expectCell(&screen, 0, 0, " ", .{});
}
