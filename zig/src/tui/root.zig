pub const ansi = @import("ansi.zig");
pub const component = @import("component.zig");
pub const keys = @import("keys.zig");
pub const terminal = @import("terminal.zig");
pub const tui = @import("tui.zig");
pub const components = struct {
    pub const text = @import("components/text.zig");
    pub const box = @import("components/box.zig");
    pub const editor = @import("components/editor.zig");
};

pub const Component = component.Component;
pub const LineList = component.LineList;
pub const Key = keys.Key;
pub const ParseResult = keys.ParseResult;
pub const Terminal = terminal.Terminal;
pub const Backend = terminal.Backend;
pub const Size = terminal.Size;
pub const Renderer = tui.Renderer;
pub const Text = components.text.Text;
pub const Box = components.box.Box;
pub const Editor = components.editor.Editor;

test {
    _ = @import("ansi.zig");
    _ = @import("component.zig");
    _ = @import("keys.zig");
    _ = @import("terminal.zig");
    _ = @import("tui.zig");
    _ = @import("components/text.zig");
    _ = @import("components/box.zig");
    _ = @import("components/editor.zig");
}
