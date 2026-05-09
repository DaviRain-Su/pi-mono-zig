# TUI Phase 0: Table Component Pilot

## Goal
Validate the Ratatui-inspired component architecture in pi by implementing a new `Table` widget and a `Constraint` layout engine. This component does not replace any existing code and serves as a proof of concept for the modern draw-path.

## Why Table
- pi currently has no table widget. All overlays use `SelectList` (single-column lists).
- A `Table` needs constraint-based column widths, scrolling, and selection highlighting — exactly the complexity needed to validate the architecture.
- It can be adopted immediately for model lists (provider / model / status columns), session lists (name / date / message count), and token-usage dashboards.

## Out of Scope
- Replacing existing `SelectList` or `Flex` components
- Stateful overlay integration (Phase 1)
- Column-spanning cells, footer rows, or multi-line cells
- Mouse support on table cells

## Architecture

### Files

| File | Lines (est) | Description |
|------|-------------|-------------|
| `zig/src/tui/constraints.zig` | ~120 | Constraint definitions and area-splitting algorithm |
| `zig/src/tui/components/table.zig` | ~450 | Table, Row, Cell, TableState widgets |
| `zig/src/tui/components/table_test.zig` | ~300 | Unit tests for constraints, table rendering, scrolling |

### Constraint Layout Engine

```zig
pub const Constraint = union(enum) {
    length: usize,
    percentage: u16,  // 0-100
    min: usize,
    max: usize,
    ratio: struct { numerator: u32, denominator: u32 },
    fill: usize,      // flex-grow weight
};

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

/// Split a horizontal area into columns based on constraints.
/// Returns a slice of Rects (one per constraint), allocated from `arena`.
pub fn splitHorizontal(arena: std.mem.Allocator, area: Rect, constraints: []const Constraint, spacing: u16) std.mem.Allocator.Error![]Rect;
```

Algorithm (Ratatui-style, adapted to Zig):
1. Resolve all `length` and `percentage` constraints to exact pixel widths.
2. Resolve `min` and `max` bounds on `fill` constraints.
3. Distribute remaining space proportionally to `fill` weights.
4. Clamp each result to `min`/`max` bounds.
5. Distribute any rounding remainder from left to right.

### Table Widget

```zig
pub const Cell = struct {
    text: []const u8,
    style: ?vaxis.Cell.Style = null,
    alignment: layout.AlignItems = .start,
};

pub const Row = struct {
    cells: []const Cell,
    style: ?vaxis.Cell.Style = null,
    height: u16 = 1,
};

pub const TableState = struct {
    selected_index: ?usize = null,
    offset: usize = 0,  // scroll offset in rows

    pub fn select(self: *TableState, index: ?usize, total_rows: usize) void;
    pub fn selectNext(self: *TableState, total_rows: usize) void;
    pub fn selectPrevious(self: *TableState, total_rows: usize) void;
};

pub const Table = struct {
    rows: []const Row,
    header: ?Row = null,
    widths: []const Constraint,
    column_spacing: u16 = 1,
    row_highlight_style: ?vaxis.Cell.Style = null,
    highlight_symbol: []const u8 = ">",
    header_separator: bool = true,

    pub fn draw(
        self: Table,
        window: vaxis.Window,
        ctx: draw.DrawContext,
        state: *TableState,
    ) std.mem.Allocator.Error!draw.Size;
};
```

#### Rendering Pipeline

1. **Measure**: `column_count = max(row.cells.len, header.cells.len)`.
2. **Split widths**: `constraints.splitHorizontal(arena, area, widths, column_spacing)` → `[]Rect` per column.
3. **Layout vertical**:
   - Header area: `header.height + 1` (separator)
   - Rows area: remaining height
4. **Render header** (if present): write cells into header row rects, draw `─` separator line.
5. **Compute visible rows**:
   - `state.offset` clamped so `selected_index` stays visible (auto-scroll).
   - `start = state.offset`, iterate rows until `y + height > rows_area.height`.
6. **Render rows**: for each visible row, write cells into column rects. Apply `row_highlight_style` to full row if selected.
7. **Render highlight symbol**: if row selected, prepend `highlight_symbol` in selection column (left of first column).

### Theme Integration

Table uses `vaxis.Cell.Style` directly (not `ThemeToken`), because it is a generic component. Callers map `ThemeToken` → `vaxis.Cell.Style` via `styleFor()` before constructing the Table.

Example:
```zig
const selected_style = style.styleFor(theme, .select_selected);
const header_style = style.styleFromSpec(.{ .fg = theme.colors.get(.primary), .bold = true });

var table = Table{
    .rows = rows,
    .widths = &.{ .{ .length = 20 }, .{ .fill = 1 }, .{ .length = 12 } },
    .header = .{ .cells = header_cells, .style = header_style },
    .row_highlight_style = selected_style,
};
```

## API Usage Example

```zig
const rows = &[_]Row{
    .{ .cells = &.{ .{ .text = "OpenAI" }, .{ .text = "gpt-5.4" }, .{ .text = "available" } } },
    .{ .cells = &.{ .{ .text = "Anthropic" }, .{ .text = "claude-sonnet-4" }, .{ .text = "available" } } },
};

var state = TableState{};
state.select(0, rows.len);

const size = try table.draw(window, ctx, &state);
```

## Test Plan

### constraints.zig tests
- `split 3 columns [Length(5), Fill(1), Length(8)] in width 30` → exact widths
- `split [Percentage(50), Percentage(50)] in width 11` → 5, 6 (remainder distributed)
- `split [Min(10), Fill(1)] in width 15` → 10, 5
- `split [Fill(1), Fill(2)] in width 12` → 4, 8
- `split with spacing 1` → spacing subtracted from available width

### table.zig tests
- `render empty table` → returns size, writes nothing
- `render table with header` → header visible, separator drawn
- `render table with selection` → selected row has highlight style + symbol
- `render table wider than area` → content truncated per column
- `render table taller than area` → only visible rows drawn, offset preserved
- `scroll selected row into view` → auto-scroll when selected > visible range
- `theme integration` → correct colors from ThemeToken mapping

## Integration Path (Future Phases)

Phase 1: Replace `SelectList` in `ModelOverlay` with `Table` (provider / model / status columns).
Phase 2: Add `Table` to `SessionOverlay` (name / modified / message count).
Phase 3: Use `Table` for new token-usage dashboard.

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Constraint algorithm diverges from Flex behavior | Keep tests comparing Table + Flex side-by-side during Phase 1 |
| Performance of per-frame constraint solving | Constraints are cheap integer math; if problematic, cache in TableState |
| Column width overflow with CJK/emoji | Use vaxis `gwidth` for visible-width truncation (same as existing `ansi.visibleWidth`) |

## Verification

Run `zig build test` and ensure:
1. All new tests pass
2. All existing TUI tests still pass
3. No new compiler warnings

## Timeline

| Day | Task |
|-----|------|
| 1 | Write `constraints.zig` + tests |
| 2-3 | Write `table.zig` core rendering + tests |
| 4 | Theme integration, header/separator, edge cases |
| 5 | Final review, `npm run check` pass, PR |
