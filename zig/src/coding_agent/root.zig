const std = @import("std");

pub const tools = @import("tools/root.zig");
pub const session_manager = @import("session_manager.zig");
pub const session = @import("session.zig");
pub const system_prompt = @import("system_prompt.zig");
pub const print_mode = @import("print_mode.zig");
pub const rpc_mode = @import("rpc_mode.zig");
pub const provider_config = @import("provider_config.zig");
pub const interactive_mode = @import("interactive_mode.zig");

pub const SessionManager = session_manager.SessionManager;
pub const SessionContext = session_manager.SessionContext;
pub const SessionTreeNode = session_manager.SessionTreeNode;
pub const AgentSession = session.AgentSession;
pub const CompactionSettings = session.CompactionSettings;
pub const RetrySettings = session.RetrySettings;
pub const CompactionResult = session.CompactionResult;
pub const BuildSystemPromptOptions = system_prompt.BuildSystemPromptOptions;
pub const buildSystemPrompt = system_prompt.buildSystemPrompt;
pub const OutputMode = print_mode.OutputMode;
pub const RunPrintModeOptions = print_mode.RunPrintModeOptions;
pub const runPrintMode = print_mode.runPrintMode;
pub const RunRpcModeOptions = rpc_mode.RunRpcModeOptions;
pub const runRpcMode = rpc_mode.runRpcMode;
pub const ResolvedProviderConfig = provider_config.ResolvedProviderConfig;
pub const ResolveProviderError = provider_config.ResolveProviderError;
pub const resolveProviderConfig = provider_config.resolveProviderConfig;
pub const resolveProviderErrorMessage = provider_config.resolveProviderErrorMessage;
pub const RunInteractiveModeOptions = interactive_mode.RunInteractiveModeOptions;
pub const runInteractiveMode = interactive_mode.runInteractiveMode;

test {
    _ = @import("tools/root.zig");
    _ = @import("session_manager.zig");
    _ = @import("session.zig");
    _ = @import("system_prompt.zig");
    _ = @import("print_mode.zig");
    _ = @import("rpc_mode.zig");
    _ = @import("provider_config.zig");
    _ = @import("interactive_mode.zig");
}
