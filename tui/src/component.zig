const std = @import("std");

/// Base component interface.
pub const Component = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        render: *const fn (ptr: *anyopaque, width: u16) []const []const u8,
        handle_input: ?*const fn (ptr: *anyopaque, data: []const u8) void = null,
        invalidate: *const fn (ptr: *anyopaque) void,
    };

    pub fn render(self: Component, width: u16) []const []const u8 {
        return self.vtable.render(self.ptr, width);
    }

    pub fn handleInput(self: Component, data: []const u8) void {
        if (self.vtable.handle_input) |f| f(self.ptr, data);
    }

    pub fn invalidate(self: Component) void {
        self.vtable.invalidate(self.ptr);
    }
};

pub const Container = struct {
    children: std.ArrayList(Component),
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Container {
        return .{ .children = std.ArrayList(Component).empty, .gpa = gpa };
    }

    pub fn deinit(self: *Container) void {
        self.children.deinit(self.gpa);
    }

    pub fn addChild(self: *Container, child: Component) void {
        self.children.append(self.gpa, child) catch @panic("OOM");
    }

    pub fn removeChild(self: *Container, child: Component) void {
        for (self.children.items, 0..) |c, i| {
            if (c.ptr == child.ptr) {
                _ = self.children.orderedRemove(i);
                return;
            }
        }
    }

    pub fn clear(self: *Container) void {
        self.children.clearRetainingCapacity();
    }

    pub fn asComponent(self: *Container) Component {
        return .{ .ptr = self, .vtable = &.{
            .render = struct {
                fn f(ptr: *anyopaque, width: u16) []const []const u8 {
                    const c: *Container = @ptrCast(@alignCast(ptr));
                    return renderContainer(c, width);
                }
            }.f,
            .invalidate = struct {
                fn f(ptr: *anyopaque) void {
                    const c: *Container = @ptrCast(@alignCast(ptr));
                    for (c.children.items) |child| child.invalidate();
                }
            }.f,
        } };
    }

    fn renderContainer(c: *Container, width: u16) []const []const u8 {
        var lines = std.ArrayList([]const u8).empty;
        defer lines.deinit(c.gpa);
        for (c.children.items) |child| {
            const child_lines = child.render(width);
            for (child_lines) |line| {
                lines.append(c.gpa, line) catch @panic("OOM");
            }
        }
        return lines.toOwnedSlice(c.gpa) catch @panic("OOM");
    }
};

pub const Text = struct {
    text: []const u8,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, text: []const u8) Text {
        return .{ .text = text, .gpa = gpa };
    }

    pub fn setText(self: *Text, text: []const u8) void {
        self.text = text;
    }

    pub fn asComponent(self: *Text) Component {
        return .{ .ptr = self, .vtable = &.{
            .render = struct {
                fn f(ptr: *anyopaque, width: u16) []const []const u8 {
                    const t: *Text = @ptrCast(@alignCast(ptr));
                    return renderText(t, width);
                }
            }.f,
            .invalidate = struct {
                fn f(ptr: *anyopaque) void {
                    _ = ptr;
                }
            }.f,
        } };
    }

    fn renderText(t: *Text, width: u16) []const []const u8 {
        _ = width;
        const lines = std.mem.splitScalar(u8, t.text, '\n');
        var list = std.ArrayList([]const u8).empty;
        defer list.deinit(t.gpa);
        while (lines.next()) |line| {
            list.append(t.gpa, line) catch @panic("OOM");
        }
        return list.toOwnedSlice(t.gpa) catch @panic("OOM");
    }
};
