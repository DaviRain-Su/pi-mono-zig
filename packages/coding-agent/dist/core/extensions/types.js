/**
 * Extension system types.
 *
 * Extensions are TypeScript modules that can:
 * - Subscribe to agent lifecycle events
 * - Register LLM-callable tools
 * - Register commands, keyboard shortcuts, and CLI flags
 * - Interact with the user via UI primitives
 */
/**
 * Preserve parameter inference for standalone tool definitions.
 *
 * Use this when assigning a tool to a variable or passing it through arrays such
 * as `customTools`, where contextual typing would otherwise widen params to
 * `unknown`.
 */
export function defineTool(tool) {
    return tool;
}
/**
 * Default bounded wait for one extension subscriber handler.
 *
 * Source/override: ExtensionRunnerOptions.handlerTimeoutMs. A timeout aborts the
 * handler-local signal when the JavaScript runtime supports AbortController and
 * ignores any late result from the timed-out handler.
 */
export const DEFAULT_EXTENSION_HANDLER_TIMEOUT_MS = 5000;
// Type guards for ToolResultEvent
export function isBashToolResult(e) {
    return e.toolName === "bash";
}
export function isReadToolResult(e) {
    return e.toolName === "read";
}
export function isEditToolResult(e) {
    return e.toolName === "edit";
}
export function isWriteToolResult(e) {
    return e.toolName === "write";
}
export function isGrepToolResult(e) {
    return e.toolName === "grep";
}
export function isFindToolResult(e) {
    return e.toolName === "find";
}
export function isLsToolResult(e) {
    return e.toolName === "ls";
}
export function isToolCallEventType(toolName, event) {
    return event.toolName === toolName;
}
export const EXTENSION_EVENT_NAMES = [
    "resources_discover",
    "session_start",
    "session_before_switch",
    "session_before_fork",
    "session_before_compact",
    "session_compact",
    "session_shutdown",
    "session_before_tree",
    "session_tree",
    "before_agent_start",
    "agent_start",
    "agent_end",
    "sub_agent_readiness",
    "turn_start",
    "turn_end",
    "message_start",
    "message_update",
    "message_end",
    "tool_execution_start",
    "tool_execution_update",
    "tool_execution_end",
    "tool_call",
    "tool_result",
    "user_bash",
    "context",
    "before_provider_request",
    "after_provider_response",
    "model_select",
    "thinking_level_select",
    "input",
];
export function isExtensionEventName(event) {
    return EXTENSION_EVENT_NAMES.includes(event);
}
export const EXTENSION_LIFECYCLE_SUPPORT_MATRIX = {
    typescript: {
        events: EXTENSION_EVENT_NAMES,
        payloadFields: {
            session_start: ["type", "reason", "previousSessionFile", "signal"],
            session_shutdown: ["type", "reason", "targetSessionFile", "signal"],
            resources_discover: ["type", "cwd", "reason", "signal"],
            session_before_switch: ["type", "reason", "targetSessionFile", "signal"],
            session_before_fork: ["type", "entryId", "position", "signal"],
        },
        reasons: ["startup", "reload", "new", "resume", "fork"],
        results: ["none", "cancellable", "resources"],
        timeout: {
            source: "ExtensionRunnerOptions.handlerTimeoutMs",
            defaultMs: DEFAULT_EXTENSION_HANDLER_TIMEOUT_MS,
            override: "per-runner",
            abortSignal: true,
            lateResults: "ignored",
        },
        shutdown: { supported: true, timeout: "same-handler-timeout", exactlyOnce: true },
        unsupportedDiagnostics: true,
    },
    process_jsonl: {
        events: EXTENSION_EVENT_NAMES,
        payloadFields: {
            session_start: ["type", "reason", "previousSessionFile"],
            session_shutdown: ["type", "reason", "targetSessionFile"],
            resources_discover: ["type", "cwd", "reason"],
        },
        reasons: ["startup", "reload", "new", "resume", "fork"],
        results: ["none", "cancellable", "resources"],
        timeout: {
            source: "lifecycle-handler-timeout-ms",
            defaultMs: DEFAULT_EXTENSION_HANDLER_TIMEOUT_MS,
            override: "runtime-host",
            abortSignal: false,
            lateResults: "ignored",
        },
        shutdown: { supported: true, timeout: "runtime-shutdown-timeout", exactlyOnce: true },
        unsupportedDiagnostics: true,
    },
    wasm: {
        events: ["session_start", "session_shutdown", "resources_discover"],
        payloadFields: {
            session_start: ["type", "reason", "previousSessionFile"],
            session_shutdown: ["type", "reason", "targetSessionFile"],
            resources_discover: ["type", "cwd", "reason"],
        },
        reasons: ["startup", "reload", "new", "resume", "fork"],
        results: ["none", "resources"],
        timeout: {
            source: "lifecycle-handler-timeout-ms",
            defaultMs: DEFAULT_EXTENSION_HANDLER_TIMEOUT_MS,
            override: "runtime-host",
            abortSignal: false,
            lateResults: "ignored",
        },
        shutdown: { supported: true, timeout: "runtime-shutdown-timeout", exactlyOnce: true },
        unsupportedDiagnostics: false,
    },
    native: {
        events: ["session_start", "session_shutdown", "resources_discover"],
        payloadFields: {
            session_start: ["type", "reason", "previousSessionFile"],
            session_shutdown: ["type", "reason", "targetSessionFile"],
            resources_discover: ["type", "cwd", "reason"],
        },
        reasons: ["startup", "reload", "new", "resume", "fork"],
        results: ["none", "resources"],
        timeout: {
            source: "lifecycle-handler-timeout-ms",
            defaultMs: DEFAULT_EXTENSION_HANDLER_TIMEOUT_MS,
            override: "runtime-host",
            abortSignal: false,
            lateResults: "ignored",
        },
        shutdown: { supported: true, timeout: "runtime-shutdown-timeout", exactlyOnce: true },
        unsupportedDiagnostics: false,
    },
};
//# sourceMappingURL=types.js.map