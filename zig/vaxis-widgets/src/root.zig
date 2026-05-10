const std = @import("std");
const vaxis = @import("vaxis");

pub const draw = @import("draw.zig");
pub const ansi = @import("ansi.zig");
pub const layout = @import("layout.zig");
pub const constraints = @import("constraints.zig");
pub const keys = @import("keys.zig");
pub const test_helpers = @import("test_helpers.zig");

pub const Spacer = @import("components/spacer.zig").Spacer;
pub const Box = @import("components/box.zig").Box;
pub const Borders = @import("components/box.zig").Borders;
pub const BorderStyle = @import("components/box.zig").BorderStyle;
pub const CornerStyle = @import("components/box.zig").CornerStyle;
pub const Text = @import("components/text.zig").Text;
pub const TextGradient = @import("components/text.zig").TextGradient;
pub const TruncatedText = @import("components/truncated_text.zig").TruncatedText;
pub const TruncationMode = @import("components/truncated_text.zig").TruncationMode;
pub const Table = @import("components/table.zig").Table;
pub const TableState = @import("components/table.zig").TableState;
pub const TableCell = @import("components/table.zig").Cell;
pub const TableRow = @import("components/table.zig").Row;
pub const Row = @import("components/table.zig").Row;
pub const Cell = @import("components/table.zig").Cell;
pub const Tabs = @import("components/tabs.zig").Tabs;
pub const Sparkline = @import("components/sparkline.zig").Sparkline;
pub const Clear = @import("components/clear.zig").Clear;
pub const Gauge = @import("components/gauge.zig").Gauge;
pub const LineGauge = @import("components/line_gauge.zig").LineGauge;
pub const BarChart = @import("components/bar_chart.zig").BarChart;
pub const BarChartBar = @import("components/bar_chart.zig").Bar;
pub const Scrollbar = @import("components/scrollbar.zig").Scrollbar;
pub const ScrollbarState = @import("components/scrollbar.zig").ScrollbarState;
pub const ScrollbarOrientation = @import("components/scrollbar.zig").Orientation;
pub const Paragraph = @import("components/paragraph.zig").Paragraph;
pub const List = @import("components/list.zig").List;
pub const ListWidget = List;
pub const ListItem = @import("components/list.zig").ListItem;
pub const Chart = @import("components/chart.zig").Chart;
pub const Dataset = @import("components/chart.zig").Dataset;
pub const Canvas = @import("components/canvas.zig").Canvas;
pub const Point = @import("components/canvas.zig").Point;
pub const Line = @import("components/canvas.zig").Line;
pub const Label = @import("components/canvas.zig").Label;
pub const Circle = @import("components/canvas.zig").Circle;
pub const Rectangle = @import("components/canvas.zig").Rectangle;
pub const Split = @import("components/split.zig").Split;
pub const SplitDirection = @import("components/split.zig").SplitDirection;
pub const Placeholder = @import("components/placeholder.zig").Placeholder;
pub const StatusBar = @import("components/status_bar.zig").StatusBar;
pub const StatusBarSection = @import("components/status_bar.zig").StatusBarSection;
pub const Calendar = @import("components/calendar.zig").Calendar;
pub const Tree = @import("components/tree.zig").Tree;
pub const TreeWidget = Tree;
pub const TreeNode = @import("components/tree.zig").TreeNode;
pub const TreeState = @import("components/tree.zig").TreeState;
pub const Input = @import("components/input.zig").Input;
pub const Popup = @import("components/popup.zig").Popup;
pub const SelectList = @import("components/select_list.zig").SelectList;
pub const SelectItem = @import("components/select_list.zig").SelectItem;
pub const HandleResult = @import("components/select_list.zig").HandleResult;
pub const Viewport = @import("components/viewport.zig").Viewport;
pub const Editor = @import("components/editor.zig").Editor;
pub const EditorAction = @import("components/editor.zig").EditorAction;
pub const Markdown = @import("components/markdown.zig").Markdown;
pub const MarkdownStyles = @import("components/markdown.zig").MarkdownStyles;
pub const Autocomplete = @import("components/autocomplete.zig");

// Dialog, Menu, Toast
pub const Dialog = @import("components/dialog.zig").Dialog;
pub const DialogButton = @import("components/dialog.zig").DialogButton;
pub const DialogResult = @import("components/dialog.zig").DialogResult;
pub const MenuBar = @import("components/menu.zig").MenuBar;
pub const Menu = @import("components/menu.zig").Menu;
pub const MenuItem = @import("components/menu.zig").MenuItem;
pub const MenuResult = @import("components/menu.zig").MenuResult;
pub const ContextMenu = @import("components/menu.zig").ContextMenu;
pub const Toast = @import("components/toast.zig").Toast;
pub const ToastLevel = @import("components/toast.zig").ToastLevel;
pub const ToastStack = @import("components/toast.zig").ToastStack;

// Form controls
pub const Checkbox = @import("components/checkbox.zig").Checkbox;
pub const Radio = @import("components/radio.zig").Radio;
pub const RadioOption = @import("components/radio.zig").RadioOption;
pub const Toggle = @import("components/toggle.zig").Toggle;
pub const Accordion = @import("components/accordion.zig").Accordion;
pub const AccordionItem = @import("components/accordion.zig").AccordionItem;

// Navigation and display
pub const Tooltip = @import("components/tooltip.zig").Tooltip;
pub const Slider = @import("components/slider.zig").Slider;
pub const Breadcrumbs = @import("components/breadcrumbs.zig").Breadcrumbs;
pub const BreadcrumbItem = @import("components/breadcrumbs.zig").BreadcrumbItem;
pub const Pagination = @import("components/pagination.zig").Pagination;

// Drawing primitives
pub const Fill = @import("components/fill.zig").Fill;

// Containers
pub const ScrollBox = @import("components/scroll_box.zig").ScrollBox;

// Gutter / line numbers
pub const LineNumber = @import("components/line_number.zig").LineNumber;

// Inline text
pub const Span = @import("components/span.zig").Span;
pub const RichText = @import("components/span.zig").RichText;
pub const BigText = @import("components/big_text.zig").BigText;

// Specialized viewers
pub const DiffViewer = @import("components/diff_viewer.zig").DiffViewer;
pub const DiffLine = @import("components/diff_viewer.zig").DiffLine;
pub const DiffLineType = @import("components/diff_viewer.zig").DiffLineType;
pub const LogViewer = @import("components/log_viewer.zig").LogViewer;
pub const LogEntry = @import("components/log_viewer.zig").LogEntry;
pub const LogLevel = @import("components/log_viewer.zig").LogLevel;
pub const FileTree = @import("components/file_tree.zig").FileTree;
pub const FileTreeNode = @import("components/file_tree.zig").FileTreeNode;
pub const FileType = @import("components/file_tree.zig").FileType;
pub const ResizableSplit = @import("components/resizable_split.zig").ResizableSplit;
pub const Wizard = @import("components/wizard.zig").Wizard;
pub const WizardStep = @import("components/wizard.zig").WizardStep;

// Utility / display
pub const Tag = @import("components/tag.zig").Tag;
pub const TagGroup = @import("components/tag.zig").TagGroup;
pub const Badge = @import("components/badge.zig").Badge;
pub const Meter = @import("components/meter.zig").Meter;
pub const IndeterminateProgress = @import("components/progress.zig").IndeterminateProgress;
pub const Spinner = @import("components/progress.zig").Spinner;
pub const TerminalPanel = @import("components/terminal_panel.zig").TerminalPanel;
pub const TerminalLine = @import("components/terminal_panel.zig").TerminalLine;
pub const MetricCard = @import("components/metric_card.zig").MetricCard;
pub const TrendDirection = @import("components/metric_card.zig").TrendDirection;

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
    pub const table = @import("components/table.zig");
    pub const tabs = @import("components/tabs.zig");
    pub const gauge = @import("components/gauge.zig");
    pub const scrollbar = @import("components/scrollbar.zig");
    pub const paragraph = @import("components/paragraph.zig");
    pub const list = @import("components/list.zig");
    pub const chart = @import("components/chart.zig");
    pub const canvas = @import("components/canvas.zig");
    pub const split = @import("components/split.zig");
    pub const placeholder = @import("components/placeholder.zig");
    pub const status_bar = @import("components/status_bar.zig");
    pub const calendar = @import("components/calendar.zig");
    pub const tree = @import("components/tree.zig");
    pub const input = @import("components/input.zig");
    pub const popup = @import("components/popup.zig");
    pub const sparkline = @import("components/sparkline.zig");
    pub const clear = @import("components/clear.zig");
    pub const bar_chart = @import("components/bar_chart.zig");
    pub const line_gauge = @import("components/line_gauge.zig");
    pub const dialog = @import("components/dialog.zig");
    pub const menu = @import("components/menu.zig");
    pub const toast = @import("components/toast.zig");
    pub const checkbox = @import("components/checkbox.zig");
    pub const radio = @import("components/radio.zig");
    pub const toggle = @import("components/toggle.zig");
    pub const accordion = @import("components/accordion.zig");
    pub const tooltip = @import("components/tooltip.zig");
    pub const slider = @import("components/slider.zig");
    pub const breadcrumbs = @import("components/breadcrumbs.zig");
    pub const pagination = @import("components/pagination.zig");
    pub const diff_viewer = @import("components/diff_viewer.zig");
    pub const log_viewer = @import("components/log_viewer.zig");
    pub const file_tree = @import("components/file_tree.zig");
    pub const resizable_split = @import("components/resizable_split.zig");
    pub const wizard = @import("components/wizard.zig");
    pub const tag = @import("components/tag.zig");
    pub const badge = @import("components/badge.zig");
    pub const meter = @import("components/meter.zig");
    pub const progress = @import("components/progress.zig");
    pub const terminal_panel = @import("components/terminal_panel.zig");
    pub const metric_card = @import("components/metric_card.zig");
    pub const fill = @import("components/fill.zig");
    pub const big_text = @import("components/big_text.zig");
    pub const scroll_box = @import("components/scroll_box.zig");
    pub const line_number = @import("components/line_number.zig");
    pub const span = @import("components/span.zig");
};
pub const Image = @import("components/image.zig").Image;
pub const Loader = @import("components/loader.zig").Loader;
pub const LoaderStyle = @import("components/loader.zig").LoaderStyle;
pub const LoaderIndicatorOptions = @import("components/loader.zig").LoaderIndicatorOptions;
pub const CancellableLoader = @import("components/loader.zig").CancellableLoader;
pub const CancellableHandleResult = @import("components/loader.zig").CancellableHandleResult;
pub const Flex = @import("components/flex.zig").Flex;
pub const FlexChild = @import("components/flex.zig").FlexChild;
pub const ImageDimensions = @import("components/image.zig").ImageDimensions;

test {
    _ = @import("components/accordion.zig");
    _ = @import("components/autocomplete.zig");
    _ = @import("components/badge.zig");
    _ = @import("components/bar_chart.zig");
    _ = @import("components/big_text.zig");
    _ = @import("components/box.zig");
    _ = @import("components/breadcrumbs.zig");
    _ = @import("components/calendar.zig");
    _ = @import("components/canvas.zig");
    _ = @import("components/chart.zig");
    _ = @import("components/checkbox.zig");
    _ = @import("components/clear.zig");
    _ = @import("components/dialog.zig");
    _ = @import("components/diff_viewer.zig");
    _ = @import("components/editor.zig");
    _ = @import("components/file_tree.zig");
    _ = @import("components/fill.zig");
    _ = @import("components/flex.zig");
    _ = @import("components/gauge.zig");
    _ = @import("components/image.zig");
    _ = @import("components/input.zig");
    _ = @import("components/line_gauge.zig");
    _ = @import("components/line_number.zig");
    _ = @import("components/list.zig");
    _ = @import("components/loader.zig");
    _ = @import("components/log_viewer.zig");
    _ = @import("components/markdown.zig");
    _ = @import("components/menu.zig");
    _ = @import("components/meter.zig");
    _ = @import("components/metric_card.zig");
    _ = @import("components/pagination.zig");
    _ = @import("components/paragraph.zig");
    _ = @import("components/placeholder.zig");
    _ = @import("components/popup.zig");
    _ = @import("components/progress.zig");
    _ = @import("components/radio.zig");
    _ = @import("components/resizable_split.zig");
    _ = @import("components/scroll_box.zig");
    _ = @import("components/scrollbar.zig");
    _ = @import("components/select_list.zig");
    _ = @import("components/slider.zig");
    _ = @import("components/spacer.zig");
    _ = @import("components/span.zig");
    _ = @import("components/sparkline.zig");
    _ = @import("components/split.zig");
    _ = @import("components/status_bar.zig");
    _ = @import("components/table.zig");
    _ = @import("components/tabs.zig");
    _ = @import("components/tag.zig");
    _ = @import("components/terminal_panel.zig");
    _ = @import("components/text.zig");
    _ = @import("components/toast.zig");
    _ = @import("components/toggle.zig");
    _ = @import("components/tooltip.zig");
    _ = @import("components/tree.zig");
    _ = @import("components/truncated_text.zig");
    _ = @import("components/viewport.zig");
    _ = @import("components/wizard.zig");
}

/// Convenience re-export of vaxis types commonly used with widgets.
pub const vaxis_types = struct {
    pub const Window = vaxis.Window;
    pub const Screen = vaxis.Screen;
    pub const AllocatingScreen = vaxis.AllocatingScreen;
    pub const Cell = vaxis.Cell;
    pub const Style = vaxis.Cell.Style;
    pub const Color = vaxis.Cell.Color;
    pub const Segment = vaxis.Segment;
};
