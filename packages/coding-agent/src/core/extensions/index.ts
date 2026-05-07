/**
 * Extension system for lifecycle events and custom tools.
 */

export type { SlashCommandInfo, SlashCommandSource } from "../slash-commands.js";
export type { SourceInfo } from "../source-info.js";
export type {
	BoundedSubAgentAdmissionDenial,
	BoundedSubAgentExecutionContext,
	BoundedSubAgentExecutionOptions,
	BoundedSubAgentExecutionStore,
	BoundedSubAgentExecutor,
	BoundedSubAgentToolHandler,
	BoundedSubAgentToolResult,
} from "./bounded-subagent-execution.js";
export {
	defaultBoundedSubAgentExecutor,
	executeBoundedSubAgentTask,
} from "./bounded-subagent-execution.js";
export {
	createExtensionRuntime,
	discoverAndLoadExtensions,
	loadExtensionFromFactory,
	loadExtensions,
} from "./loader.js";
export type {
	ExtensionErrorListener,
	ForkHandler,
	NavigateTreeHandler,
	NewSessionHandler,
	ShutdownHandler,
	SwitchSessionHandler,
} from "./runner.js";
export { ExtensionRunner } from "./runner.js";
export type {
	SubAgentDelegationCapability,
	SubAgentDelegationHost,
	SubAgentDelegationHostContext,
	SubAgentDelegationInput,
	SubAgentExtensionOptions,
} from "./subagent-extension.js";
export {
	createSubAgentExtension,
	SUB_AGENT_DELEGATION_COMMAND,
	SUB_AGENT_DELEGATION_RESULT_ENTRY,
	SUB_AGENT_DELEGATION_TOOL,
	SUB_AGENT_READINESS_ENTRY,
	SUB_AGENT_STATUS_MESSAGE,
	subAgentDelegationInputSchema,
} from "./subagent-extension.js";
export type {
	SubAgentCancellationMetadata,
	SubAgentCancellationState,
	SubAgentCorrelationIds,
	SubAgentLineage,
	SubAgentNumericResourceLimit,
	SubAgentReadinessEnvelope,
	SubAgentResourceLimitDetail,
	SubAgentResourceLimitDetails,
	SubAgentResourceLimits,
	SubAgentResourceSummary,
	SubAgentTaskError,
	SubAgentTaskInvocationEnvelope,
	SubAgentTaskResultEnvelope,
	SubAgentTaskStatus,
	SubAgentUsageSummary,
} from "./subagent-readiness.js";
export {
	validateSubAgentReadinessEnvelope,
	validateSubAgentTaskInvocationEnvelope,
	validateSubAgentTaskResultEnvelope,
} from "./subagent-readiness.js";
export type {
	AfterProviderResponseEvent,
	AgentEndEvent,
	AgentStartEvent,
	// Re-exports
	AgentToolResult,
	AgentToolUpdateCallback,
	AppendEntryHandler,
	// App keybindings (for custom editors)
	AppKeybinding,
	AutocompleteProviderFactory,
	// Events - Tool (ToolCallEvent types)
	BashToolCallEvent,
	BashToolResultEvent,
	BeforeAgentStartEvent,
	BeforeAgentStartEventResult,
	BeforeProviderRequestEvent,
	BeforeProviderRequestEventResult,
	BuildSystemPromptOptions,
	// Context
	CompactOptions,
	// Events - Agent
	ContextEvent,
	// Event Results
	ContextEventResult,
	ContextUsage,
	CustomToolCallEvent,
	CustomToolResultEvent,
	EditorFactory,
	EditToolCallEvent,
	EditToolResultEvent,
	ExecOptions,
	ExecResult,
	Extension,
	ExtensionActions,
	// API
	ExtensionAPI,
	ExtensionCommandContext,
	ExtensionCommandContextActions,
	ExtensionContext,
	ExtensionContextActions,
	// Errors
	ExtensionError,
	ExtensionEvent,
	ExtensionFactory,
	ExtensionFlag,
	ExtensionHandler,
	// Runtime
	ExtensionRuntime,
	ExtensionShortcut,
	ExtensionUIContext,
	ExtensionUIDialogOptions,
	ExtensionWidgetOptions,
	FindToolCallEvent,
	FindToolResultEvent,
	GetActiveToolsHandler,
	GetAllToolsHandler,
	GetCommandsHandler,
	GetThinkingLevelHandler,
	GrepToolCallEvent,
	GrepToolResultEvent,
	// Events - Input
	InputEvent,
	InputEventResult,
	InputSource,
	KeybindingsManager,
	LoadExtensionsResult,
	LsToolCallEvent,
	LsToolResultEvent,
	// Events - Message
	MessageEndEvent,
	// Message Rendering
	MessageRenderer,
	MessageRenderOptions,
	MessageStartEvent,
	MessageUpdateEvent,
	ModelSelectEvent,
	ModelSelectSource,
	// Provider Registration
	ProviderConfig,
	ProviderModelConfig,
	ReadToolCallEvent,
	ReadToolResultEvent,
	// Commands
	RegisteredCommand,
	RegisteredTool,
	ReplacedSessionContext,
	ResolvedCommand,
	// Events - Resources
	ResourcesDiscoverEvent,
	ResourcesDiscoverResult,
	SendMessageHandler,
	SendUserMessageHandler,
	SessionBeforeCompactEvent,
	SessionBeforeCompactResult,
	SessionBeforeForkEvent,
	SessionBeforeForkResult,
	SessionBeforeSwitchEvent,
	SessionBeforeSwitchResult,
	SessionBeforeTreeEvent,
	SessionBeforeTreeResult,
	SessionCompactEvent,
	SessionEvent,
	SessionShutdownEvent,
	// Events - Session
	SessionStartEvent,
	SessionTreeEvent,
	SetActiveToolsHandler,
	SetLabelHandler,
	SetModelHandler,
	SetThinkingLevelHandler,
	SubAgentReadinessEvent,
	TerminalInputHandler,
	// Events - Tool
	ToolCallEvent,
	ToolCallEventResult,
	// Tools
	ToolDefinition,
	// Events - Tool Execution
	ToolExecutionEndEvent,
	// Tool execution mode
	ToolExecutionMode,
	ToolExecutionStartEvent,
	ToolExecutionUpdateEvent,
	ToolInfo,
	ToolRenderResultOptions,
	ToolResultEvent,
	ToolResultEventResult,
	TreePreparation,
	TurnEndEvent,
	TurnStartEvent,
	// Events - User Bash
	UserBashEvent,
	UserBashEventResult,
	WidgetPlacement,
	WorkingIndicatorOptions,
	WriteToolCallEvent,
	WriteToolResultEvent,
} from "./types.js";
// Type guards
export {
	defineTool,
	isBashToolResult,
	isEditToolResult,
	isFindToolResult,
	isGrepToolResult,
	isLsToolResult,
	isReadToolResult,
	isToolCallEventType,
	isWriteToolResult,
} from "./types.js";
export { wrapRegisteredTool, wrapRegisteredTools } from "./wrapper.js";
