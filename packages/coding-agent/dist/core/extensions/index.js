/**
 * Extension system for lifecycle events and custom tools.
 */
export { defaultBoundedSubAgentExecutor, executeBoundedSubAgentTask, } from "./bounded-subagent-execution.js";
export { createExtensionRuntime, discoverAndLoadExtensions, loadExtensionFromFactory, loadExtensions, } from "./loader.js";
export { ExtensionRunner } from "./runner.js";
export { createSubAgentExtension, SUB_AGENT_DELEGATION_COMMAND, SUB_AGENT_DELEGATION_RESULT_ENTRY, SUB_AGENT_DELEGATION_TOOL, SUB_AGENT_READINESS_ENTRY, SUB_AGENT_STATUS_MESSAGE, subAgentDelegationInputSchema, } from "./subagent-extension.js";
export { validateSubAgentReadinessEnvelope, validateSubAgentTaskInvocationEnvelope, validateSubAgentTaskResultEnvelope, } from "./subagent-readiness.js";
// Type guards
export { DEFAULT_EXTENSION_HANDLER_TIMEOUT_MS, defineTool, EXTENSION_LIFECYCLE_SUPPORT_MATRIX, isBashToolResult, isEditToolResult, isFindToolResult, isGrepToolResult, isLsToolResult, isReadToolResult, isToolCallEventType, isWriteToolResult, } from "./types.js";
export { wrapRegisteredTool, wrapRegisteredTools } from "./wrapper.js";
//# sourceMappingURL=index.js.map