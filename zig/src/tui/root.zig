pub const vaxis = @import("vaxis");
pub const ansi = @import("ansi.zig");
pub const component = @import("component.zig");
pub const draw = @import("draw.zig");
pub const keys = @import("keys.zig");
pub const layout = @import("layout.zig");
pub const style = @import("style.zig");
pub const terminal = @import("terminal.zig");
pub const test_helpers = @import("test_helpers.zig");
pub const theme = @import("theme.zig");
pub const tui = @import("tui.zig");
pub const vaxis_adapter = @import("vaxis_adapter.zig");
pub const components = struct {
    pub const autocomplete = @import("components/autocomplete.zig");
    pub const text = @import("components/text.zig");
    pub const box = @import("components/box.zig");
    pub const editor = @import("components/editor.zig");
    pub const flex = @import("components/flex.zig");
    pub const image = @import("components/image.zig");
    pub const loader = @import("components/loader.zig");
    pub const markdown = @import("components/markdown.zig");
    pub const select_list = @import("components/select_list.zig");
    pub const spacer = @import("components/spacer.zig");
    pub const truncated_text = @import("components/truncated_text.zig");
    pub const viewport = @import("components/viewport.zig");
};

pub const Component = component.Component;
pub const DrawComponent = draw.Component;
pub const DrawContext = draw.DrawContext;
pub const DrawSize = draw.Size;
pub const LineList = component.LineList;
pub const Key = keys.Key;
pub const ParseResult = keys.ParseResult;
pub const Axis = layout.Axis;
pub const JustifyContent = layout.JustifyContent;
pub const AlignItems = layout.AlignItems;
pub const Insets = layout.Insets;
pub const ViewportAnchor = layout.ViewportAnchor;
pub const Terminal = terminal.Terminal;
pub const Backend = terminal.Backend;
pub const Size = terminal.Size;
pub const Renderer = tui.Renderer;
pub const VaxisAdapter = vaxis_adapter.VaxisAdapter;
pub const Theme = theme.Theme;
pub const ThemeColor = theme.ThemeColor;
pub const ThemeColors = theme.ThemeColors;
pub const ThemeToken = theme.ThemeToken;
pub const StyleSpec = theme.StyleSpec;
pub const styleFor = style.styleFor;
pub const OverlayAnchor = tui.OverlayAnchor;
pub const OverlayMargin = tui.OverlayMargin;
pub const OverlayAnimation = tui.OverlayAnimation;
pub const OverlayAnimationKind = tui.OverlayAnimationKind;
pub const OverlayOptions = tui.OverlayOptions;
pub const Text = components.text.Text;
pub const TextGradient = components.text.TextGradient;
pub const Box = components.box.Box;
pub const BorderStyle = components.box.BorderStyle;
pub const CornerStyle = components.box.CornerStyle;
pub const Editor = components.editor.Editor;
pub const Flex = components.flex.Flex;
pub const FlexChild = components.flex.FlexChild;
pub const Image = components.image.Image;
pub const ImageDimensions = components.image.ImageDimensions;
pub const Loader = components.loader.Loader;
pub const LoaderStyle = components.loader.LoaderStyle;
pub const LoaderIndicatorOptions = components.loader.LoaderIndicatorOptions;
pub const CancellableLoader = components.loader.CancellableLoader;
pub const CancellableHandleResult = components.loader.CancellableHandleResult;
pub const Markdown = components.markdown.Markdown;
pub const SelectList = components.select_list.SelectList;
pub const SelectItem = components.select_list.SelectItem;
pub const Spacer = components.spacer.Spacer;
pub const TruncatedText = components.truncated_text.TruncatedText;
pub const TruncationMode = components.truncated_text.TruncationMode;
pub const Viewport = components.viewport.Viewport;

test {
    _ = @import("ansi.zig");
    _ = @import("component.zig");
    _ = @import("draw.zig");
    _ = @import("keys.zig");
    _ = @import("layout.zig");
    _ = @import("style.zig");
    _ = @import("terminal.zig");
    _ = @import("test_helpers.zig");
    _ = @import("theme.zig");
    _ = @import("tui.zig");
    _ = @import("vaxis_adapter.zig");
    _ = @import("components/autocomplete.zig");
    _ = @import("components/text.zig");
    _ = @import("components/box.zig");
    _ = @import("components/editor.zig");
    _ = @import("components/flex.zig");
    _ = @import("components/image.zig");
    _ = @import("components/loader.zig");
    _ = @import("components/markdown.zig");
    _ = @import("components/select_list.zig");
    _ = @import("components/spacer.zig");
    _ = @import("components/truncated_text.zig");
    _ = @import("components/viewport.zig");
}

test "components export autocomplete module" {
    _ = components.autocomplete;
    _ = components.autocomplete.Item;
}

test "exports vaxis module" {
    _ = vaxis.Vaxis;
    _ = vaxis.Tty;
    _ = vaxis.Loop;
}
