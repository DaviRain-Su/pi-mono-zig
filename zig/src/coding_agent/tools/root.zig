const std = @import("std");

pub const common = @import("common.zig");
pub const args_parser = @import("args_parser.zig");
pub const parseArgsFromJson = args_parser.parseArgsFromJson;
pub const file_mutation_queue = @import("file_mutation_queue.zig");
pub const edit_diff = @import("edit_diff.zig");
pub const output_accumulator = @import("output_accumulator.zig");
pub const path_utils = @import("path_utils.zig");
pub const render_utils = @import("render_utils.zig");
pub const tool_definition_wrapper = @import("tool_definition_wrapper.zig");
pub const truncate = @import("truncate.zig");
pub const read = @import("read.zig");
pub const bash = @import("bash.zig");
pub const write = @import("write.zig");
pub const edit = @import("edit.zig");
pub const grep = @import("grep.zig");
pub const find = @import("find.zig");
pub const ls = @import("ls.zig");

pub const deinitContentBlocks = common.deinitContentBlocks;
pub const makeTextContent = common.makeTextContent;
pub const resolvePath = common.resolvePath;
pub const writeFileAbsolute = common.writeFileAbsolute;
pub const OutputAccumulator = output_accumulator.OutputAccumulator;
pub const OutputAccumulatorOptions = output_accumulator.OutputAccumulatorOptions;
pub const OutputSnapshot = output_accumulator.OutputSnapshot;

pub const DEFAULT_MAX_LINES = truncate.DEFAULT_MAX_LINES;
pub const DEFAULT_MAX_BYTES = truncate.DEFAULT_MAX_BYTES;
pub const TruncationOptions = truncate.TruncationOptions;
pub const TruncatedBy = truncate.TruncatedBy;
pub const TruncationResult = truncate.TruncationResult;
pub const truncateHead = truncate.truncateHead;
pub const truncateTail = truncate.truncateTail;

pub const ReadArgs = read.ReadArgs;
pub const ReadDetails = read.ReadDetails;
pub const ReadExecutionResult = read.ReadExecutionResult;
pub const ReadTool = read.ReadTool;

pub const BashArgs = bash.BashArgs;
pub const BashDetails = bash.BashDetails;
pub const BashExecutionResult = bash.BashExecutionResult;
pub const BashTool = bash.BashTool;

pub const WriteArgs = write.WriteArgs;
pub const WriteExecutionResult = write.WriteExecutionResult;
pub const WriteTool = write.WriteTool;

pub const EditArgs = edit.EditArgs;
pub const EditExecutionResult = edit.EditExecutionResult;
pub const EditTool = edit.EditTool;
pub const EditDiffResult = edit_diff.EditDiffResult;
pub const computeEditDiff = edit_diff.computeEditDiff;
pub const computeEditsDiff = edit_diff.computeEditsDiff;

pub const GrepArgs = grep.GrepArgs;
pub const GrepDetails = grep.GrepDetails;
pub const GrepExecutionResult = grep.GrepExecutionResult;
pub const GrepTool = grep.GrepTool;

pub const FindArgs = find.FindArgs;
pub const FindDetails = find.FindDetails;
pub const FindExecutionResult = find.FindExecutionResult;
pub const FindTool = find.FindTool;

pub const LsArgs = ls.LsArgs;
pub const LsDetails = ls.LsDetails;
pub const LsExecutionResult = ls.LsExecutionResult;
pub const LsTool = ls.LsTool;

/// Compile-time list of all built-in tool types, in registration order.
/// Each entry must expose: name, description, fn schema(), and have an `init(cwd, io)` constructor.
pub const ALL: []const type = &.{
    ReadTool,
    BashTool,
    WriteTool,
    EditTool,
    GrepTool,
    FindTool,
    LsTool,
};

/// Visitor callback invoked once per built-in tool type at comptime.
/// `ctx` is caller-supplied runtime context; `T` is the tool type.
pub fn forEach(comptime ctx: anytype, comptime callback: fn (comptime ctx: @TypeOf(ctx), comptime T: type) void) void {
    inline for (ALL) |T| {
        callback(ctx, T);
    }
}

test {
    _ = @import("common.zig");
    _ = @import("args_parser.zig");
    _ = @import("file_mutation_queue.zig");
    _ = @import("edit_diff.zig");
    _ = @import("output_accumulator.zig");
    _ = @import("path_utils.zig");
    _ = @import("render_utils.zig");
    _ = @import("tool_definition_wrapper.zig");
    _ = @import("truncate.zig");
    _ = @import("read.zig");
    _ = @import("bash.zig");
    _ = @import("write.zig");
    _ = @import("edit.zig");
    _ = @import("grep.zig");
    _ = @import("find.zig");
    _ = @import("ls.zig");
}
