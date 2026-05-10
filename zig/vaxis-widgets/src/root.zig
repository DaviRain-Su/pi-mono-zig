const std = @import("std");
const vaxis = @import("vaxis");

pub const draw = @import("draw.zig");
pub const ansi = @import("ansi.zig");
pub const layout = @import("layout.zig");
pub const constraints = @import("constraints.zig");
pub const keys = @import("keys.zig");
pub const scroll = @import("scroll.zig");
pub const test_helpers = @import("test_helpers.zig");

/// Each component module is imported once here, then re-exported individually
/// for ergonomics. This avoids the historical duplication of having two
/// independent `@import("components/foo.zig")` calls per component (one for the
/// type re-export, one for the namespace, plus a third inside `test {}`).
pub const components = struct {
    pub const autocomplete = @import("components/autocomplete.zig");
    pub const accordion = @import("components/accordion.zig");
    pub const badge = @import("components/badge.zig");
    pub const bar_chart = @import("components/bar_chart.zig");
    pub const big_text = @import("components/big_text.zig");
    pub const box = @import("components/box.zig");
    pub const breadcrumbs = @import("components/breadcrumbs.zig");
    pub const calendar = @import("components/calendar.zig");
    pub const cancellable_loader = @import("components/cancellable_loader.zig");
    pub const canvas = @import("components/canvas.zig");
    pub const chart = @import("components/chart.zig");
    pub const checkbox = @import("components/checkbox.zig");
    pub const clear = @import("components/clear.zig");
    pub const dialog = @import("components/dialog.zig");
    pub const diff_viewer = @import("components/diff_viewer.zig");
    pub const editor = @import("components/editor.zig");
    pub const file_tree = @import("components/file_tree.zig");
    pub const fill = @import("components/fill.zig");
    pub const flex = @import("components/flex.zig");
    pub const gauge = @import("components/gauge.zig");
    pub const image = @import("components/image.zig");
    pub const input = @import("components/input.zig");
    pub const line_gauge = @import("components/line_gauge.zig");
    pub const line_number = @import("components/line_number.zig");
    pub const list = @import("components/list.zig");
    pub const loader = @import("components/loader.zig");
    pub const log_viewer = @import("components/log_viewer.zig");
    pub const markdown = @import("components/markdown.zig");
    pub const menu = @import("components/menu.zig");
    pub const meter = @import("components/meter.zig");
    pub const metric_card = @import("components/metric_card.zig");
    pub const pagination = @import("components/pagination.zig");
    pub const paragraph = @import("components/paragraph.zig");
    pub const placeholder = @import("components/placeholder.zig");
    pub const popup = @import("components/popup.zig");
    pub const progress = @import("components/progress.zig");
    pub const radio = @import("components/radio.zig");
    pub const resizable_split = @import("components/resizable_split.zig");
    pub const scroll_box = @import("components/scroll_box.zig");
    pub const scrollbar = @import("components/scrollbar.zig");
    pub const select_list = @import("components/select_list.zig");
    pub const settings_list = @import("components/settings_list.zig");
    pub const slider = @import("components/slider.zig");
    pub const spacer = @import("components/spacer.zig");
    pub const span = @import("components/span.zig");
    pub const sparkline = @import("components/sparkline.zig");
    pub const split = @import("components/split.zig");
    pub const status_bar = @import("components/status_bar.zig");
    pub const table = @import("components/table.zig");
    pub const tabs = @import("components/tabs.zig");
    pub const tag = @import("components/tag.zig");
    pub const terminal_panel = @import("components/terminal_panel.zig");
    pub const text = @import("components/text.zig");
    pub const toast = @import("components/toast.zig");
    pub const toggle = @import("components/toggle.zig");
    pub const tooltip = @import("components/tooltip.zig");
    pub const tree = @import("components/tree.zig");
    pub const truncated_text = @import("components/truncated_text.zig");
    pub const viewport = @import("components/viewport.zig");
    pub const wizard = @import("components/wizard.zig");
};

pub const Spacer = components.spacer.Spacer;
pub const Box = components.box.Box;
pub const Borders = components.box.Borders;
pub const BorderStyle = components.box.BorderStyle;
pub const CornerStyle = components.box.CornerStyle;
pub const Text = components.text.Text;
pub const TextGradient = components.text.TextGradient;
pub const TruncatedText = components.truncated_text.TruncatedText;
pub const TruncationMode = components.truncated_text.TruncationMode;
pub const Table = components.table.Table;
pub const TableState = components.table.TableState;
pub const TableCell = components.table.Cell;
pub const TableRow = components.table.Row;
pub const TableSortOrder = components.table.SortOrder;
pub const Row = components.table.Row;
pub const Cell = components.table.Cell;
pub const Tabs = components.tabs.Tabs;
pub const Sparkline = components.sparkline.Sparkline;
pub const Clear = components.clear.Clear;
pub const Gauge = components.gauge.Gauge;
pub const LineGauge = components.line_gauge.LineGauge;
pub const BarChart = components.bar_chart.BarChart;
pub const BarChartBar = components.bar_chart.Bar;
pub const Scrollbar = components.scrollbar.Scrollbar;
pub const ScrollbarState = components.scrollbar.ScrollbarState;
pub const ScrollbarOrientation = components.scrollbar.Orientation;
pub const Paragraph = components.paragraph.Paragraph;
pub const List = components.list.List;
pub const ListWidget = List;
pub const ListItem = components.list.ListItem;
pub const ListState = components.list.ListState;
pub const Chart = components.chart.Chart;
pub const Dataset = components.chart.Dataset;
pub const Canvas = components.canvas.Canvas;
pub const Point = components.canvas.Point;
pub const Line = components.canvas.Line;
pub const Label = components.canvas.Label;
pub const Circle = components.canvas.Circle;
pub const Rectangle = components.canvas.Rectangle;
pub const Split = components.split.Split;
pub const SplitDirection = components.split.SplitDirection;
pub const Placeholder = components.placeholder.Placeholder;
pub const StatusBar = components.status_bar.StatusBar;
pub const StatusBarSection = components.status_bar.StatusBarSection;
pub const Calendar = components.calendar.Calendar;
pub const Tree = components.tree.Tree;
pub const TreeWidget = Tree;
pub const TreeNode = components.tree.TreeNode;
pub const TreeState = components.tree.TreeState;
pub const Input = components.input.Input;
pub const Popup = components.popup.Popup;
pub const SelectList = components.select_list.SelectList;
pub const SelectItem = components.select_list.SelectItem;
pub const HandleResult = components.select_list.HandleResult;
pub const SettingsList = components.settings_list.SettingsList;
pub const SettingItem = components.settings_list.SettingItem;
pub const SettingsListTheme = components.settings_list.SettingsListTheme;
pub const SettingsListHandleResult = components.settings_list.HandleResult;
pub const Viewport = components.viewport.Viewport;
pub const Editor = components.editor.Editor;
pub const EditorAction = components.editor.EditorAction;
pub const Markdown = components.markdown.Markdown;
pub const MarkdownStyles = components.markdown.MarkdownStyles;
pub const Autocomplete = components.autocomplete;

// Dialog, Menu, Toast
pub const Dialog = components.dialog.Dialog;
pub const DialogButton = components.dialog.DialogButton;
pub const DialogResult = components.dialog.DialogResult;
pub const MenuBar = components.menu.MenuBar;
pub const Menu = components.menu.Menu;
pub const MenuItem = components.menu.MenuItem;
pub const MenuResult = components.menu.MenuResult;
pub const ContextMenu = components.menu.ContextMenu;
pub const Toast = components.toast.Toast;
pub const ToastLevel = components.toast.ToastLevel;
pub const ToastStack = components.toast.ToastStack;

// Form controls
pub const Checkbox = components.checkbox.Checkbox;
pub const Radio = components.radio.Radio;
pub const RadioOption = components.radio.RadioOption;
pub const Toggle = components.toggle.Toggle;
pub const Accordion = components.accordion.Accordion;
pub const AccordionItem = components.accordion.AccordionItem;

// Navigation and display
pub const Tooltip = components.tooltip.Tooltip;
pub const Slider = components.slider.Slider;
pub const Breadcrumbs = components.breadcrumbs.Breadcrumbs;
pub const BreadcrumbItem = components.breadcrumbs.BreadcrumbItem;
pub const Pagination = components.pagination.Pagination;

// Drawing primitives
pub const Fill = components.fill.Fill;

// Containers
pub const ScrollBox = components.scroll_box.ScrollBox;

// Gutter / line numbers
pub const LineNumber = components.line_number.LineNumber;

// Inline text
pub const Span = components.span.Span;
pub const RichText = components.span.RichText;
pub const BigText = components.big_text.BigText;

// Specialized viewers
pub const DiffViewer = components.diff_viewer.DiffViewer;
pub const DiffLine = components.diff_viewer.DiffLine;
pub const DiffLineType = components.diff_viewer.DiffLineType;
pub const LogViewer = components.log_viewer.LogViewer;
pub const LogEntry = components.log_viewer.LogEntry;
pub const LogLevel = components.log_viewer.LogLevel;
pub const FileTree = components.file_tree.FileTree;
pub const FileTreeNode = components.file_tree.FileTreeNode;
pub const FileType = components.file_tree.FileType;
pub const ResizableSplit = components.resizable_split.ResizableSplit;
pub const Wizard = components.wizard.Wizard;
pub const WizardStep = components.wizard.WizardStep;

// Utility / display
pub const Tag = components.tag.Tag;
pub const TagGroup = components.tag.TagGroup;
pub const Badge = components.badge.Badge;
pub const Meter = components.meter.Meter;
pub const IndeterminateProgress = components.progress.IndeterminateProgress;
pub const Spinner = components.progress.Spinner;
pub const TerminalPanel = components.terminal_panel.TerminalPanel;
pub const TerminalLine = components.terminal_panel.TerminalLine;
pub const MetricCard = components.metric_card.MetricCard;
pub const TrendDirection = components.metric_card.TrendDirection;

pub const Image = components.image.Image;
pub const Loader = components.loader.Loader;
pub const LoaderStyle = components.loader.LoaderStyle;
pub const LoaderIndicatorOptions = components.loader.LoaderIndicatorOptions;
pub const CancellableLoader = components.loader.CancellableLoader;
pub const CancellableHandleResult = components.loader.CancellableHandleResult;
pub const Flex = components.flex.Flex;
pub const FlexChild = components.flex.FlexChild;
pub const ImageDimensions = components.image.ImageDimensions;

test {
    // Pull tests from every component module without redundant import lines.
    inline for (@typeInfo(components).@"struct".decls) |decl| {
        _ = @field(components, decl.name);
    }
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
