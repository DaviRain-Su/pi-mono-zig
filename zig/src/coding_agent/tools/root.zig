const std = @import("std");

pub const common = @import("common.zig");
pub const file_mutation_queue = @import("file_mutation_queue.zig");
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

test {
    _ = @import("common.zig");
    _ = @import("file_mutation_queue.zig");
    _ = @import("truncate.zig");
    _ = @import("read.zig");
    _ = @import("bash.zig");
    _ = @import("write.zig");
    _ = @import("edit.zig");
    _ = @import("grep.zig");
    _ = @import("find.zig");
    _ = @import("ls.zig");
}
