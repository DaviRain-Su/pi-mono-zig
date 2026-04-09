const std = @import("std");

pub const terminal = @import("terminal.zig");
pub const component = @import("component.zig");

pub const Terminal = terminal.Terminal;
pub const ProcessTerminal = terminal.ProcessTerminal;
pub const Component = component.Component;
pub const Container = component.Container;
pub const Text = component.Text;

test "tui types compile" {
    _ = ProcessTerminal.init();
    var container = Container.init(std.testing.allocator);
    defer container.deinit();
}
