const std = @import("std");

pub const vaxis = @import("vaxis");

// Re-export generic infrastructure from vaxis-widgets
const vw = @import("vaxis-widgets");
pub const ansi = vw.ansi;
pub const draw = vw.draw;
pub const keys = vw.keys;
pub const layout = vw.layout;
pub const constraints = vw.constraints;
pub const test_helpers = vw.test_helpers;

// Pi-specific modules (retained locally)
pub const cell_rows = @import("cell_rows.zig");
pub const style = @import("style.zig");
pub const terminal = @import("terminal.zig");
pub const theme = @import("theme.zig");
pub const tui = @import("tui.zig");
pub const visual_parity = @import("visual_parity.zig");

// Components: generic ones from vaxis-widgets, pi-specific ones local
pub const components = struct {
    pub const autocomplete = @import("components/autocomplete.zig");
    pub const text = vw.components.text;
    pub const box = vw.components.box;
    pub const editor = vw.components.editor;
    pub const flex = vw.components.flex;
    pub const image = vw.components.image;
    pub const loader = vw.components.loader;
    pub const markdown = vw.components.markdown;
    pub const select_list = vw.components.select_list;
    pub const spacer = vw.components.spacer;
    pub const truncated_text = vw.components.truncated_text;
    pub const viewport = vw.components.viewport;
    pub const table = vw.components.table;
    pub const tabs = vw.components.tabs;
    pub const gauge = vw.components.gauge;
    pub const scrollbar = vw.components.scrollbar;
    pub const paragraph = vw.components.paragraph;
    pub const list = vw.components.list;
    pub const chart = vw.components.chart;
    pub const canvas = vw.components.canvas;
    pub const split = vw.components.split;
    pub const placeholder = vw.components.placeholder;
    pub const status_bar = vw.components.status_bar;
    pub const calendar = vw.components.calendar;
    pub const tree = vw.components.tree;
    pub const input = vw.components.input;
    pub const popup = vw.components.popup;
    pub const sparkline = vw.components.sparkline;
    pub const clear = vw.components.clear;
    pub const bar_chart = vw.components.bar_chart;
    pub const line_gauge = vw.components.line_gauge;
    pub const dialog = vw.components.dialog;
    pub const menu = vw.components.menu;
    pub const toast = vw.components.toast;
};

// Top-level re-exports (backward compatible)
pub const DrawComponent = draw.Component;
pub const DrawContext = draw.DrawContext;
pub const DrawSize = draw.Size;
pub const Key = keys.Key;
pub const Axis = layout.Axis;
pub const JustifyContent = layout.JustifyContent;
pub const AlignItems = layout.AlignItems;
pub const Insets = layout.Insets;
pub const ViewportAnchor = layout.ViewportAnchor;
pub const Constraint = constraints.Constraint;
pub const splitHorizontal = constraints.splitHorizontal;
pub const splitVertical = constraints.splitVertical;
pub const Terminal = terminal.Terminal;
pub const Backend = terminal.Backend;
pub const Size = terminal.Size;
pub const Renderer = tui.Renderer;
pub const Theme = theme.Theme;
pub const ThemeColor = theme.ThemeColor;
pub const ThemeColors = theme.ThemeColors;
pub const ThemeToken = theme.ThemeToken;
pub const StyleSpec = theme.StyleSpec;
pub const PaletteTemplate = theme.PaletteTemplate;
pub const styleFor = style.styleFor;
pub const markdownStylesFor = style.markdownStylesFor;
pub const OverlayAnchor = tui.OverlayAnchor;
pub const OverlayMargin = tui.OverlayMargin;
pub const OverlayAnimation = tui.OverlayAnimation;
pub const OverlayAnimationKind = tui.OverlayAnimationKind;
pub const OverlayOptions = tui.OverlayOptions;

// Widget re-exports
pub const Text = vw.Text;
pub const TextGradient = vw.TextGradient;
pub const Box = vw.Box;
pub const BorderStyle = vw.BorderStyle;
pub const CornerStyle = vw.CornerStyle;
pub const Editor = vw.Editor;
pub const EditorAction = vw.EditorAction;
pub const Flex = vw.Flex;
pub const FlexChild = vw.FlexChild;
pub const Image = vw.Image;
pub const ImageDimensions = vw.ImageDimensions;
pub const Loader = vw.Loader;
pub const LoaderStyle = vw.LoaderStyle;
pub const LoaderIndicatorOptions = vw.LoaderIndicatorOptions;
pub const CancellableLoader = vw.CancellableLoader;
pub const CancellableHandleResult = vw.CancellableHandleResult;
pub const Markdown = vw.Markdown;
pub const MarkdownStyles = vw.MarkdownStyles;
pub const SelectList = vw.SelectList;
pub const SelectItem = vw.SelectItem;
pub const Spacer = vw.Spacer;
pub const TruncatedText = vw.TruncatedText;
pub const TruncationMode = vw.TruncationMode;
pub const Viewport = vw.Viewport;
pub const Table = vw.Table;
pub const TableState = vw.TableState;
pub const TableCell = vw.TableCell;
pub const TableRow = vw.TableRow;
pub const TableSortOrder = vw.TableSortOrder;
pub const Tabs = vw.Tabs;
pub const Gauge = vw.Gauge;
pub const Scrollbar = vw.Scrollbar;
pub const ScrollbarState = vw.ScrollbarState;
pub const ScrollbarOrientation = vw.ScrollbarOrientation;
pub const Sparkline = vw.Sparkline;
pub const Clear = vw.Clear;
pub const BarChart = vw.BarChart;
pub const BarChartBar = vw.BarChartBar;
pub const LineGauge = vw.LineGauge;
pub const Paragraph = vw.Paragraph;
pub const List = vw.List;
pub const ListItem = vw.ListItem;
pub const ListState = vw.ListState;
pub const Chart = vw.Chart;
pub const Dataset = vw.Dataset;
pub const Canvas = vw.Canvas;
pub const Point = vw.Point;
pub const Line = vw.Line;
pub const Label = vw.Label;
pub const Circle = vw.Circle;
pub const Rectangle = vw.Rectangle;
pub const Split = vw.Split;
pub const SplitDirection = vw.SplitDirection;
pub const Placeholder = vw.Placeholder;
pub const StatusBar = vw.StatusBar;
pub const StatusBarSection = vw.StatusBarSection;
pub const Calendar = vw.Calendar;
pub const Tree = vw.Tree;
pub const TreeNode = vw.TreeNode;
pub const TreeState = vw.TreeState;
pub const Input = vw.Input;
pub const Popup = vw.Popup;
pub const Dialog = vw.Dialog;
pub const DialogButton = vw.DialogButton;
pub const DialogResult = vw.DialogResult;
pub const MenuBar = vw.MenuBar;
pub const Menu = vw.Menu;
pub const MenuItem = vw.MenuItem;
pub const MenuResult = vw.MenuResult;
pub const ContextMenu = vw.ContextMenu;
pub const Toast = vw.Toast;
pub const ToastLevel = vw.ToastLevel;
pub const ToastStack = vw.ToastStack;
pub const Checkbox = vw.Checkbox;
pub const Radio = vw.Radio;
pub const RadioOption = vw.RadioOption;
pub const Toggle = vw.Toggle;
pub const Accordion = vw.Accordion;
pub const AccordionItem = vw.AccordionItem;
pub const Tooltip = vw.Tooltip;
pub const Slider = vw.Slider;
pub const Breadcrumbs = vw.Breadcrumbs;
pub const BreadcrumbItem = vw.BreadcrumbItem;
pub const Pagination = vw.Pagination;
pub const DiffViewer = vw.DiffViewer;
pub const DiffLine = vw.DiffLine;
pub const DiffLineType = vw.DiffLineType;
pub const LogViewer = vw.LogViewer;
pub const LogEntry = vw.LogEntry;
pub const LogLevel = vw.LogLevel;
pub const FileTree = vw.FileTree;
pub const FileTreeNode = vw.FileTreeNode;
pub const FileType = vw.FileType;
pub const ResizableSplit = vw.ResizableSplit;
pub const Wizard = vw.Wizard;
pub const WizardStep = vw.WizardStep;

// Utility / display
pub const Tag = vw.Tag;
pub const TagGroup = vw.TagGroup;
pub const Badge = vw.Badge;
pub const Meter = vw.Meter;
pub const IndeterminateProgress = vw.IndeterminateProgress;
pub const Spinner = vw.Spinner;
pub const TerminalPanel = vw.TerminalPanel;
pub const TerminalLine = vw.TerminalLine;
pub const MetricCard = vw.MetricCard;
pub const TrendDirection = vw.TrendDirection;
pub const Fill = vw.Fill;
pub const BigText = vw.BigText;
pub const ScrollBox = vw.ScrollBox;
pub const LineNumber = vw.LineNumber;
pub const Span = vw.Span;
pub const RichText = vw.RichText;

test {
    _ = @import("cell_rows.zig");
    _ = @import("style.zig");
    _ = @import("terminal.zig");
    _ = @import("theme.zig");
    _ = @import("tui.zig");
    _ = @import("visual_parity.zig");
    _ = @import("components/autocomplete.zig");
}

test "components export autocomplete module" {
    _ = components.autocomplete;
    _ = components.autocomplete.Item;
}

test "exports migrated widget aliases" {
    _ = BorderStyle;
    _ = CornerStyle;
    _ = EditorAction;
    _ = ImageDimensions;
    _ = LoaderStyle;
    _ = LoaderIndicatorOptions;
    _ = CancellableLoader;
    _ = CancellableHandleResult;
    _ = TruncationMode;
    _ = ScrollbarOrientation;
    _ = BarChartBar;
    _ = TableSortOrder;
    _ = List;
    _ = ListState;
    _ = Tree;
    _ = TreeState;
}

test "exports vaxis module" {
    _ = vaxis.Vaxis;
    _ = vaxis.Tty;
    _ = vaxis.Loop;
}

test "vaxis kitty graphics delete commands suppress terminal replies" {
    try std.testing.expectEqualStrings("\x1b_Ga=d,q=2\x1b\\", vaxis.ctlseqs.kitty_graphics_clear);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const vx: vaxis.Vaxis = undefined;
    vx.freeImage(&output.writer, 42);

    try std.testing.expectEqualStrings("\x1b_Ga=d,d=I,i=42,q=2\x1b\\", output.writer.buffered());
}
