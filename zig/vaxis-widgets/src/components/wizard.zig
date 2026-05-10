const std = @import("std");
const vaxis = @import("vaxis");
const ansi = @import("../ansi.zig");
const draw_mod = @import("../draw.zig");
const test_helpers = @import("../test_helpers.zig");

pub const WizardStep = struct {
    label: []const u8,
    content: draw_mod.Component,
    description: []const u8 = "",
};

pub const Wizard = struct {
    steps: []const WizardStep,
    current_step: usize = 0,
    style: vaxis.Cell.Style = .{},
    active_style: vaxis.Cell.Style = .{ .bold = true, .fg = .{ .index = 39 } },
    completed_style: vaxis.Cell.Style = .{ .fg = .{ .index = 82 } },
    pending_style: vaxis.Cell.Style = .{ .fg = .{ .index = 8 } },
    connector_char: []const u8 = "───",
    show_step_numbers: bool = true,
    show_description: bool = false,

    pub fn drawComponent(self: *const Wizard) draw_mod.Component {
        return .{
            .ptr = self,
            .drawFn = drawOpaque,
        };
    }

    pub fn draw(
        self: *const Wizard,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        window.clear();

        const step_header_height: u16 = if (self.show_description) 3 else 2;
        const step_header = window.child(.{ .height = step_header_height });

        // Draw step indicators
        var x: u16 = 0;
        for (self.steps, 0..) |step, i| {
            if (x >= step_header.width) break;

            const style = if (i < self.current_step)
                self.completed_style
            else if (i == self.current_step)
                self.active_style
            else
                self.pending_style;

            // Step number or bullet
            var label_buf: [32]u8 = undefined;
            const label = if (self.show_step_numbers)
                std.fmt.bufPrint(&label_buf, "({d}) {s}", .{ i + 1, step.label }) catch step.label
            else
                step.label;

            // Draw label
            var idx: usize = 0;
            while (idx < label.len and x < step_header.width) {
                const cluster = ansi.nextDisplayCluster(label, idx);
                if (cluster.end <= idx) break;
                step_header.writeCell(x, 0, .{
                    .char = .{ .grapheme = label[idx..cluster.end], .width = @intCast(cluster.width) },
                    .style = style,
                });
                x += @intCast(cluster.width);
                idx = cluster.end;
            }

            // Connector
            if (i < self.steps.len - 1 and x < step_header.width) {
                var cidx: usize = 0;
                while (cidx < self.connector_char.len and x < step_header.width) {
                    step_header.writeCell(x, 0, .{
                        .char = .{ .grapheme = self.connector_char[cidx .. cidx + 1], .width = 1 },
                        .style = self.pending_style,
                    });
                    x += 1;
                    cidx += 1;
                }
            }

            // Spacing between steps
            if (i < self.steps.len - 1 and x < step_header.width) {
                step_header.writeCell(x, 0, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{} });
                x += 1;
            }
        }

        // Description
        if (self.show_description and self.current_step < self.steps.len) {
            const desc = self.steps[self.current_step].description;
            if (desc.len > 0) {
                const desc_window = step_header.child(.{ .y_off = 1, .height = 1 });
                _ = desc_window.printSegment(.{ .text = desc, .style = self.pending_style }, .{ .wrap = .none });
            }
        }

        // Content
        if (self.current_step < self.steps.len and step_header_height < window.height) {
            const content_window = window.child(.{
                .y_off = step_header_height,
                .height = window.height - step_header_height,
            });
            _ = try self.steps[self.current_step].content.draw(content_window, ctx);
        }

        return .{ .width = window.width, .height = window.height };
    }

    pub fn next(self: *Wizard) void {
        if (self.current_step + 1 < self.steps.len) {
            self.current_step += 1;
        }
    }

    pub fn prev(self: *Wizard) void {
        if (self.current_step > 0) {
            self.current_step -= 1;
        }
    }

    pub fn goTo(self: *Wizard, step: usize) void {
        self.current_step = @min(step, self.steps.len -| 1);
    }

    pub fn isFirst(self: *const Wizard) bool {
        return self.current_step == 0;
    }

    pub fn isLast(self: *const Wizard) bool {
        return self.steps.len == 0 or self.current_step == self.steps.len - 1;
    }

    fn drawOpaque(
        ptr: *const anyopaque,
        window: vaxis.Window,
        ctx: draw_mod.DrawContext,
    ) std.mem.Allocator.Error!draw_mod.Size {
        const self: *const Wizard = @ptrCast(@alignCast(ptr));
        return self.draw(window, ctx);
    }
};

test "wizard renders steps and content" {
    const StaticText = struct {
        text: []const u8,
        fn drawComponent(self: *const @This()) draw_mod.Component {
            return .{ .ptr = self, .drawFn = draw };
        }
        fn draw(ptr: *const anyopaque, w: vaxis.Window, _: draw_mod.DrawContext) std.mem.Allocator.Error!draw_mod.Size {
            const s: *const @This() = @ptrCast(@alignCast(ptr));
            _ = w.printSegment(.{ .text = s.text }, .{ .wrap = .none });
            return .{ .width = w.width, .height = 1 };
        }
    };

    const content = StaticText{ .text = "Step content" };
    const steps = &[_]WizardStep{
        .{ .label = "Name", .content = content.drawComponent() },
        .{ .label = "Config", .content = content.drawComponent() },
        .{ .label = "Done", .content = content.drawComponent() },
    };

    var wizard = Wizard{ .steps = steps, .current_step = 1 };

    var screen = try test_helpers.renderToScreen(wizard.drawComponent(), 40, 3);
    defer screen.deinit(std.testing.allocator);

    const rendered = try test_helpers.screenToString(&screen);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Config") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Done") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Step content") != null);
}

test "wizard navigation" {
    const StaticText = struct {
        text: []const u8,
        fn drawComponent(self: *const @This()) draw_mod.Component {
            return .{ .ptr = self, .drawFn = draw };
        }
        fn draw(ptr: *const anyopaque, w: vaxis.Window, _: draw_mod.DrawContext) std.mem.Allocator.Error!draw_mod.Size {
            const s: *const @This() = @ptrCast(@alignCast(ptr));
            _ = w.printSegment(.{ .text = s.text }, .{ .wrap = .none });
            return .{ .width = w.width, .height = 1 };
        }
    };

    const text_a = StaticText{ .text = "a" };
    const text_b = StaticText{ .text = "b" };
    const steps = &[_]WizardStep{
        .{ .label = "A", .content = text_a.drawComponent() },
        .{ .label = "B", .content = text_b.drawComponent() },
    };

    var wizard = Wizard{ .steps = steps };
    try std.testing.expect(wizard.isFirst());

    wizard.next();
    try std.testing.expect(wizard.isLast());

    wizard.next(); // clamped
    try std.testing.expect(wizard.isLast());

    wizard.prev();
    try std.testing.expect(wizard.isFirst());
}
