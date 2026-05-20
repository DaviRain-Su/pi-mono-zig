/**
 * Extension runner - executes extensions and manages their lifecycle.
 */
import { existsSync, realpathSync } from "node:fs";
import { basename, isAbsolute, relative, resolve } from "node:path";
import { theme } from "../../modes/interactive/theme/theme.js";
import { attachResourceDiagnosticEnvelope, sanitizeExtensionError } from "../diagnostics.js";
import { createExtensionPolicyDenialError, ExtensionPolicyDeniedError, hasExtensionGrant, } from "../extension-policy.js";
import { DEFAULT_EXTENSION_HANDLER_TIMEOUT_MS } from "./types.js";
// Extension shortcuts compete with canonical keybinding ids from keybindings.json.
// Only editor-global shortcuts are reserved here. Picker-specific bindings are not.
const RESERVED_KEYBINDINGS_FOR_EXTENSION_CONFLICTS = [
    "app.interrupt",
    "app.clear",
    "app.exit",
    "app.suspend",
    "app.thinking.cycle",
    "app.model.cycleForward",
    "app.model.cycleBackward",
    "app.model.select",
    "app.tools.expand",
    "app.thinking.toggle",
    "app.editor.external",
    "app.message.followUp",
    "tui.input.submit",
    "tui.select.confirm",
    "tui.select.cancel",
    "tui.input.copy",
    "tui.editor.deleteToLineEnd",
];
const buildBuiltinKeybindings = (resolvedKeybindings) => {
    const builtinKeybindings = {};
    for (const [keybinding, keys] of Object.entries(resolvedKeybindings)) {
        if (keys === undefined)
            continue;
        const keyList = Array.isArray(keys) ? keys : [keys];
        const restrictOverride = RESERVED_KEYBINDINGS_FOR_EXTENSION_CONFLICTS.includes(keybinding);
        for (const key of keyList) {
            const normalizedKey = key.toLowerCase();
            // If multiple actions bind the same key, the reserved action wins so extensions
            // remain blocked by reserved shortcuts regardless of iteration order.
            const existing = builtinKeybindings[normalizedKey];
            if (existing?.restrictOverride && !restrictOverride)
                continue;
            builtinKeybindings[normalizedKey] = {
                keybinding,
                restrictOverride,
            };
        }
    }
    return builtinKeybindings;
};
function cloneForExtensionHandler(value, seen = new WeakMap()) {
    if (value === null || typeof value !== "object") {
        return value;
    }
    if (Array.isArray(value)) {
        const existing = seen.get(value);
        if (existing)
            return existing;
        const clone = [];
        seen.set(value, clone);
        for (const item of value) {
            clone.push(cloneForExtensionHandler(item, seen));
        }
        return clone;
    }
    const source = value;
    const existing = seen.get(source);
    if (existing)
        return existing;
    const prototype = Object.getPrototypeOf(source);
    if (prototype !== Object.prototype && prototype !== null) {
        return value;
    }
    const clone = Object.create(prototype);
    seen.set(source, clone);
    for (const key of Reflect.ownKeys(source)) {
        const descriptor = Object.getOwnPropertyDescriptor(source, key);
        if (!descriptor)
            continue;
        const clonedDescriptor = { ...descriptor };
        if ("value" in clonedDescriptor) {
            clonedDescriptor.value = cloneForExtensionHandler(clonedDescriptor.value, seen);
        }
        Object.defineProperty(clone, key, clonedDescriptor);
    }
    return clone;
}
function createRevocableFacade(getTarget, assertActive, options = {}) {
    const functionCache = new Map();
    const deniedMethods = new Set(options.deniedMethods ?? []);
    const denyMutation = (property) => {
        throw new Error(`read-only extension facade denied method ${String(property)}`);
    };
    return new Proxy({}, {
        get(_target, property) {
            assertActive();
            if (deniedMethods.has(property)) {
                return () => denyMutation(property);
            }
            const target = getTarget();
            const value = Reflect.get(target, property, target);
            if (typeof value !== "function") {
                return value;
            }
            const cached = functionCache.get(property);
            if (cached) {
                return cached;
            }
            const wrapper = (...args) => {
                assertActive();
                const activeTarget = getTarget();
                const activeValue = Reflect.get(activeTarget, property, activeTarget);
                if (typeof activeValue !== "function") {
                    throw new TypeError(`Revoked extension facade property ${String(property)} is not callable`);
                }
                return Reflect.apply(activeValue, activeTarget, args);
            };
            functionCache.set(property, wrapper);
            return wrapper;
        },
        set(_target, property, value) {
            assertActive();
            if (options.readOnly) {
                denyMutation(property);
            }
            return Reflect.set(getTarget(), property, value);
        },
        has(_target, property) {
            assertActive();
            return property in getTarget();
        },
        ownKeys() {
            assertActive();
            return Reflect.ownKeys(getTarget()).filter((property) => !deniedMethods.has(property));
        },
        getOwnPropertyDescriptor(_target, property) {
            assertActive();
            if (deniedMethods.has(property))
                return undefined;
            const descriptor = Reflect.getOwnPropertyDescriptor(getTarget(), property);
            if (!descriptor)
                return undefined;
            return { ...descriptor, configurable: true };
        },
    });
}
function isRecord(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}
function invalid(path, message) {
    return { ok: false, path, message };
}
function valid(value) {
    return { ok: true, value };
}
function validateResultObject(value, eventType) {
    if (value === undefined)
        return valid(undefined);
    if (!isRecord(value)) {
        return invalid("$", `${eventType} handlers must return an object or undefined`);
    }
    return valid(value);
}
function validateOptionalBoolean(record, field) {
    const value = record[field];
    if (value !== undefined && typeof value !== "boolean") {
        return invalid(`$.${field}`, "expected boolean");
    }
    return valid(undefined);
}
function validateOptionalString(record, field) {
    const value = record[field];
    if (value !== undefined && typeof value !== "string") {
        return invalid(`$.${field}`, "expected string");
    }
    return valid(undefined);
}
function validateOptionalNumber(record, field) {
    const value = record[field];
    if (value !== undefined && typeof value !== "number") {
        return invalid(`$.${field}`, "expected number");
    }
    return valid(undefined);
}
function validateStringArray(value, path) {
    if (value === undefined)
        return valid(undefined);
    if (!Array.isArray(value)) {
        return invalid(path, "expected string array");
    }
    for (const [index, item] of value.entries()) {
        if (typeof item !== "string") {
            return invalid(`${path}[${index}]`, "expected string");
        }
    }
    return valid(value);
}
function validateContentBlock(value, path) {
    if (!isRecord(value)) {
        return invalid(path, "expected content block object");
    }
    if (value.type === "text") {
        if (typeof value.text !== "string")
            return invalid(`${path}.text`, "expected string");
        return valid(undefined);
    }
    if (value.type === "image") {
        if (typeof value.data !== "string")
            return invalid(`${path}.data`, "expected string");
        if (typeof value.mimeType !== "string")
            return invalid(`${path}.mimeType`, "expected string");
        return valid(undefined);
    }
    return invalid(`${path}.type`, 'expected "text" or "image"');
}
function validateContentBlocks(value, path) {
    if (value === undefined)
        return valid(undefined);
    if (!Array.isArray(value)) {
        return invalid(path, "expected content block array");
    }
    for (const [index, item] of value.entries()) {
        const result = validateContentBlock(item, `${path}[${index}]`);
        if (!result.ok)
            return result;
    }
    return valid(value);
}
function validateOptionalImageArray(value, path) {
    if (value === undefined)
        return valid(undefined);
    if (!Array.isArray(value)) {
        return invalid(path, "expected image array");
    }
    for (const [index, item] of value.entries()) {
        if (!isRecord(item) || item.type !== "image")
            return invalid(`${path}[${index}]`, "expected image block");
        const block = validateContentBlock(item, `${path}[${index}]`);
        if (!block.ok)
            return block;
    }
    return valid(value);
}
const HANDLER_TIMEOUT = Symbol("extension-handler-timeout");
const GENERATED_HANDLER_SIGNAL = Symbol("generated-extension-handler-signal");
/**
 * Helper function to emit session_shutdown event to extensions.
 * Returns true if the event was emitted, false if there were no handlers.
 */
export async function emitSessionShutdownEvent(extensionRunner, event) {
    if (extensionRunner.hasHandlers("session_shutdown")) {
        await extensionRunner.emit(event);
        return true;
    }
    return false;
}
const noOpUIContext = {
    select: async () => undefined,
    confirm: async () => false,
    input: async () => undefined,
    notify: () => { },
    onTerminalInput: () => () => { },
    setStatus: () => { },
    setWorkingMessage: () => { },
    setWorkingVisible: () => { },
    setWorkingIndicator: () => { },
    setHiddenThinkingLabel: () => { },
    setWidget: () => { },
    setFooter: () => { },
    setHeader: () => { },
    setTitle: () => { },
    custom: async () => undefined,
    pasteToEditor: () => { },
    setEditorText: () => { },
    getEditorText: () => "",
    editor: async () => undefined,
    addAutocompleteProvider: () => { },
    setEditorComponent: () => { },
    getEditorComponent: () => undefined,
    get theme() {
        return theme;
    },
    getAllThemes: () => [],
    getTheme: () => undefined,
    setTheme: (_theme) => ({ success: false, error: "UI not available" }),
    getToolsExpanded: () => false,
    setToolsExpanded: () => { },
};
const SESSION_MANAGER_MUTATING_METHODS = [
    "setSessionFile",
    "newSession",
    "_persist",
    "appendMessage",
    "appendThinkingLevelChange",
    "appendModelChange",
    "appendCustomEntry",
    "appendSessionInfo",
    "appendLabelChange",
    "branch",
    "resetLeaf",
    "branchWithSummary",
    "createBranchedSession",
];
const MODEL_REGISTRY_MUTATING_METHODS = ["refresh", "registerProvider", "unregisterProvider"];
export class ExtensionRunner {
    extensions;
    wasmExtensions;
    runtime;
    uiContext;
    cwd;
    sessionManager;
    modelRegistry;
    errorListeners = new Set();
    getModel = () => undefined;
    isIdleFn = () => true;
    getSignalFn = () => undefined;
    waitForIdleFn = async () => { };
    abortFn = () => { };
    hasPendingMessagesFn = () => false;
    getContextUsageFn = () => undefined;
    compactFn = () => { };
    getSystemPromptFn = () => "";
    newSessionHandler = async () => ({ cancelled: false });
    forkHandler = async () => ({ cancelled: false });
    navigateTreeHandler = async () => ({ cancelled: false });
    switchSessionHandler = async () => ({ cancelled: false });
    reloadHandler = async () => { };
    shutdownHandler = () => { };
    shortcutDiagnostics = [];
    commandDiagnostics = [];
    staleMessage;
    handlerTimeoutMs;
    providerActions;
    registeredProviderNames = new Set();
    constructor(extensions, runtime, cwd, sessionManager, modelRegistry, wasmExtensions = [], options = {}) {
        this.extensions = extensions;
        this.wasmExtensions = [...wasmExtensions];
        this.runtime = runtime;
        this.uiContext = noOpUIContext;
        this.cwd = cwd;
        this.sessionManager = sessionManager;
        this.modelRegistry = modelRegistry;
        this.handlerTimeoutMs = options.handlerTimeoutMs ?? DEFAULT_EXTENSION_HANDLER_TIMEOUT_MS;
    }
    bindCore(actions, contextActions, providerActions) {
        this.assertActive();
        this.providerActions = providerActions;
        // Copy actions into the shared runtime (all extension APIs reference this)
        this.runtime.sendMessage = actions.sendMessage;
        this.runtime.sendUserMessage = actions.sendUserMessage;
        this.runtime.appendEntry = actions.appendEntry;
        this.runtime.setSessionName = actions.setSessionName;
        this.runtime.getSessionName = actions.getSessionName;
        this.runtime.setLabel = actions.setLabel;
        this.runtime.getActiveTools = actions.getActiveTools;
        this.runtime.getAllTools = actions.getAllTools;
        this.runtime.setActiveTools = actions.setActiveTools;
        this.runtime.refreshTools = actions.refreshTools;
        this.runtime.getCommands = actions.getCommands;
        this.runtime.setModel = actions.setModel;
        this.runtime.getThinkingLevel = actions.getThinkingLevel;
        this.runtime.setThinkingLevel = actions.setThinkingLevel;
        // Context actions (required)
        this.getModel = contextActions.getModel;
        this.isIdleFn = contextActions.isIdle;
        this.getSignalFn = contextActions.getSignal;
        this.abortFn = contextActions.abort;
        this.hasPendingMessagesFn = contextActions.hasPendingMessages;
        this.shutdownHandler = contextActions.shutdown;
        this.getContextUsageFn = contextActions.getContextUsage;
        this.compactFn = contextActions.compact;
        this.getSystemPromptFn = contextActions.getSystemPrompt;
        // Flush provider registrations queued during extension loading
        for (const { name, config, extensionPath } of this.runtime.pendingProviderRegistrations) {
            try {
                this.registerOwnedProvider(name, config);
            }
            catch (err) {
                this.emitError({
                    extensionPath,
                    event: "register_provider",
                    error: err instanceof Error ? err.message : String(err),
                    stack: err instanceof Error ? err.stack : undefined,
                });
            }
        }
        this.runtime.pendingProviderRegistrations = [];
        // From this point on, provider registration/unregistration takes effect immediately
        // without requiring a /reload.
        this.runtime.registerProvider = (name, config) => {
            this.assertActive();
            this.runtime.assertActive();
            this.registerOwnedProvider(name, config);
        };
        this.runtime.unregisterProvider = (name) => {
            this.assertActive();
            this.runtime.assertActive();
            this.unregisterOwnedProvider(name);
        };
    }
    registerOwnedProvider(name, config) {
        if (this.providerActions?.registerProvider) {
            this.providerActions.registerProvider(name, config);
        }
        else {
            this.modelRegistry.registerProvider(name, config);
        }
        this.registeredProviderNames.add(name);
    }
    unregisterOwnedProvider(name) {
        if (this.providerActions?.unregisterProvider) {
            this.providerActions.unregisterProvider(name);
        }
        else {
            this.modelRegistry.unregisterProvider(name);
        }
        this.registeredProviderNames.delete(name);
    }
    cleanupOwnedProviders() {
        const providerNames = [...this.registeredProviderNames];
        this.registeredProviderNames.clear();
        for (const name of providerNames) {
            try {
                if (this.providerActions?.unregisterProvider) {
                    this.providerActions.unregisterProvider(name);
                }
                else {
                    this.modelRegistry.unregisterProvider(name);
                }
            }
            catch (err) {
                this.emitError({
                    extensionPath: "<runtime>",
                    event: "unregister_provider",
                    error: err instanceof Error ? err.message : String(err),
                    stack: err instanceof Error ? err.stack : undefined,
                    phase: "unload",
                    runtimeKind: "typescript",
                });
            }
        }
    }
    bindCommandContext(actions) {
        if (actions) {
            this.waitForIdleFn = actions.waitForIdle;
            this.newSessionHandler = actions.newSession;
            this.forkHandler = actions.fork;
            this.navigateTreeHandler = actions.navigateTree;
            this.switchSessionHandler = actions.switchSession;
            this.reloadHandler = actions.reload;
            return;
        }
        this.waitForIdleFn = async () => { };
        this.newSessionHandler = async () => ({ cancelled: false });
        this.forkHandler = async () => ({ cancelled: false });
        this.navigateTreeHandler = async () => ({ cancelled: false });
        this.switchSessionHandler = async () => ({ cancelled: false });
        this.reloadHandler = async () => { };
    }
    setUIContext(uiContext) {
        this.uiContext = uiContext ?? noOpUIContext;
    }
    getUIContext() {
        return this.uiContext;
    }
    hasUI() {
        return this.uiContext !== noOpUIContext;
    }
    getExtensionPaths() {
        return this.extensions.map((e) => e.path);
    }
    getWasmExtensions() {
        return [...this.wasmExtensions];
    }
    /** Get all registered tools from all extensions (first registration per name wins). */
    getAllRegisteredTools() {
        const toolsByName = new Map();
        for (const ext of this.extensions) {
            for (const tool of ext.tools.values()) {
                if (!toolsByName.has(tool.definition.name)) {
                    toolsByName.set(tool.definition.name, tool);
                }
            }
        }
        return Array.from(toolsByName.values());
    }
    /** Get a tool definition by name. Returns undefined if not found. */
    getToolDefinition(toolName) {
        for (const ext of this.extensions) {
            const tool = ext.tools.get(toolName);
            if (tool) {
                return tool.definition;
            }
        }
        return undefined;
    }
    getFlags() {
        const allFlags = new Map();
        for (const ext of this.extensions) {
            for (const [name, flag] of ext.flags) {
                if (!allFlags.has(name)) {
                    allFlags.set(name, flag);
                }
            }
        }
        return allFlags;
    }
    setFlagValue(name, value) {
        this.runtime.flagValues.set(name, value);
    }
    getFlagValues() {
        return new Map(this.runtime.flagValues);
    }
    getShortcuts(resolvedKeybindings) {
        this.shortcutDiagnostics = [];
        const builtinKeybindings = buildBuiltinKeybindings(resolvedKeybindings);
        const extensionShortcuts = new Map();
        const addDiagnostic = (message, extensionPath) => {
            this.shortcutDiagnostics.push({ type: "warning", message, path: extensionPath });
            if (!this.hasUI()) {
                console.warn(message);
            }
        };
        for (const ext of this.extensions) {
            for (const [key, shortcut] of ext.shortcuts) {
                const normalizedKey = key.toLowerCase();
                const builtInKeybinding = builtinKeybindings[normalizedKey];
                if (builtInKeybinding?.restrictOverride === true) {
                    addDiagnostic(`Extension shortcut '${key}' from ${shortcut.extensionPath} conflicts with built-in shortcut. Skipping.`, shortcut.extensionPath);
                    continue;
                }
                if (builtInKeybinding?.restrictOverride === false) {
                    addDiagnostic(`Extension shortcut conflict: '${key}' is built-in shortcut for ${builtInKeybinding.keybinding} and ${shortcut.extensionPath}. Using ${shortcut.extensionPath}.`, shortcut.extensionPath);
                }
                const existingExtensionShortcut = extensionShortcuts.get(normalizedKey);
                if (existingExtensionShortcut) {
                    addDiagnostic(`Extension shortcut conflict: '${key}' registered by both ${existingExtensionShortcut.extensionPath} and ${shortcut.extensionPath}. Using ${shortcut.extensionPath}.`, shortcut.extensionPath);
                }
                extensionShortcuts.set(normalizedKey, shortcut);
            }
        }
        return extensionShortcuts;
    }
    getShortcutDiagnostics() {
        return this.shortcutDiagnostics.map((diagnostic) => attachResourceDiagnosticEnvelope(diagnostic));
    }
    invalidate(message = "This extension ctx is stale after session replacement or reload. Do not use a captured pi or command ctx after ctx.newSession(), ctx.fork(), ctx.switchSession(), or ctx.reload(). For newSession, fork, and switchSession, move post-replacement work into withSession and use the ctx passed to withSession. For reload, do not use the old ctx after await ctx.reload().") {
        if (!this.staleMessage) {
            this.staleMessage = message;
            this.runtime.invalidate(message);
            this.runtime.pendingProviderRegistrations = [];
            this.cleanupOwnedProviders();
        }
    }
    assertActive() {
        if (this.staleMessage) {
            throw new Error(this.staleMessage);
        }
    }
    onError(listener) {
        this.errorListeners.add(listener);
        return () => this.errorListeners.delete(listener);
    }
    emitError(error) {
        const sanitized = sanitizeExtensionError(error);
        for (const listener of this.errorListeners) {
            listener(sanitized);
        }
    }
    hasHandlers(eventType) {
        for (const ext of this.extensions) {
            const handlers = ext.handlers.get(eventType);
            if (handlers && handlers.length > 0) {
                return true;
            }
        }
        return false;
    }
    getMessageRenderer(customType) {
        for (const ext of this.extensions) {
            const renderer = ext.messageRenderers.get(customType);
            if (renderer) {
                return renderer;
            }
        }
        return undefined;
    }
    resolveRegisteredCommands() {
        const commands = [];
        const counts = new Map();
        for (const ext of this.extensions) {
            for (const command of ext.commands.values()) {
                commands.push(command);
                counts.set(command.name, (counts.get(command.name) ?? 0) + 1);
            }
        }
        const seen = new Map();
        const takenInvocationNames = new Set();
        return commands.map((command) => {
            const occurrence = (seen.get(command.name) ?? 0) + 1;
            seen.set(command.name, occurrence);
            let invocationName = (counts.get(command.name) ?? 0) > 1 ? `${command.name}:${occurrence}` : command.name;
            if (takenInvocationNames.has(invocationName)) {
                let suffix = occurrence;
                do {
                    suffix++;
                    invocationName = `${command.name}:${suffix}`;
                } while (takenInvocationNames.has(invocationName));
            }
            takenInvocationNames.add(invocationName);
            return {
                ...command,
                invocationName,
            };
        });
    }
    getRegisteredCommands() {
        this.commandDiagnostics = [];
        return this.resolveRegisteredCommands();
    }
    getCommandDiagnostics() {
        return this.commandDiagnostics.map((diagnostic) => attachResourceDiagnosticEnvelope(diagnostic));
    }
    getCommand(name) {
        return this.resolveRegisteredCommands().find((command) => command.invocationName === name);
    }
    /**
     * Request a graceful shutdown. Called by extension tools and event handlers.
     * The actual shutdown behavior is provided by the mode via bindExtensions().
     */
    shutdown() {
        this.shutdownHandler();
    }
    /**
     * Create an ExtensionContext for use in event handlers and tool execution.
     * Context values are resolved at call time, so changes via bindCore/bindUI are reflected.
     */
    createContext() {
        const runner = this;
        const getModel = this.getModel;
        const assertActive = () => runner.assertActive();
        const uiFacade = createRevocableFacade(() => runner.uiContext, assertActive);
        const sessionManagerFacade = createRevocableFacade(() => runner.sessionManager, assertActive, {
            readOnly: true,
            deniedMethods: SESSION_MANAGER_MUTATING_METHODS,
        });
        const modelRegistryFacade = createRevocableFacade(() => runner.modelRegistry, assertActive, {
            readOnly: true,
            deniedMethods: MODEL_REGISTRY_MUTATING_METHODS,
        });
        return {
            get ui() {
                runner.assertActive();
                return uiFacade;
            },
            get hasUI() {
                runner.assertActive();
                return runner.hasUI();
            },
            get cwd() {
                runner.assertActive();
                return runner.cwd;
            },
            get sessionManager() {
                runner.assertActive();
                return sessionManagerFacade;
            },
            get modelRegistry() {
                runner.assertActive();
                return modelRegistryFacade;
            },
            get model() {
                runner.assertActive();
                return getModel();
            },
            isIdle: () => {
                runner.assertActive();
                return runner.isIdleFn();
            },
            get signal() {
                runner.assertActive();
                return runner.getSignalFn();
            },
            abort: () => {
                runner.assertActive();
                runner.abortFn();
            },
            hasPendingMessages: () => {
                runner.assertActive();
                return runner.hasPendingMessagesFn();
            },
            shutdown: () => {
                runner.assertActive();
                runner.shutdownHandler();
            },
            getContextUsage: () => {
                runner.assertActive();
                return runner.getContextUsageFn();
            },
            compact: (options) => {
                runner.assertActive();
                runner.compactFn(options);
            },
            getSystemPrompt: () => {
                runner.assertActive();
                return runner.getSystemPromptFn();
            },
            emitSubAgentReadiness: async (event) => {
                runner.assertActive();
                await runner.emit({
                    type: "sub_agent_readiness",
                    envelope: event.envelope,
                    phase: event.phase,
                    owner: event.owner,
                    readOnly: true,
                    signal: event.signal,
                });
            },
        };
    }
    createCommandContext() {
        // Use property descriptors instead of object spread so the guarded getters from
        // createContext() stay lazy. A spread would eagerly read them once and freeze the
        // old values into the returned object, bypassing stale-instance checks.
        const context = Object.defineProperties({}, Object.getOwnPropertyDescriptors(this.createContext()));
        context.waitForIdle = () => {
            this.assertActive();
            return this.waitForIdleFn();
        };
        context.newSession = (options) => {
            this.assertActive();
            return this.newSessionHandler(options);
        };
        context.fork = (entryId, options) => {
            this.assertActive();
            return this.forkHandler(entryId, options);
        };
        context.navigateTree = (targetId, options) => {
            this.assertActive();
            return this.navigateTreeHandler(targetId, options);
        };
        context.switchSession = (sessionPath, options) => {
            this.assertActive();
            return this.switchSessionHandler(sessionPath, options);
        };
        context.reload = () => {
            this.assertActive();
            return this.reloadHandler();
        };
        return context;
    }
    isSessionBeforeEvent(event) {
        return (event.type === "session_before_switch" ||
            event.type === "session_before_fork" ||
            event.type === "session_before_compact" ||
            event.type === "session_before_tree");
    }
    eventWithHandlerSignal(event, signal) {
        if (event === null || typeof event !== "object" || Array.isArray(event)) {
            return event;
        }
        const record = event;
        const hasCallerSignal = Object.hasOwn(record, "signal") && !record[GENERATED_HANDLER_SIGNAL];
        if (hasCallerSignal || !Object.isExtensible(event)) {
            return event;
        }
        Object.defineProperty(event, "signal", {
            value: signal,
            configurable: true,
            enumerable: false,
        });
        Object.defineProperty(event, GENERATED_HANDLER_SIGNAL, {
            value: true,
            configurable: true,
            enumerable: false,
        });
        return event;
    }
    async invokeHandler(ext, eventType, handler, event, ctx) {
        const timeoutMs = this.handlerTimeoutMs;
        const controller = new AbortController();
        const handlerEvent = this.eventWithHandlerSignal(event, controller.signal);
        const handlerPromise = Promise.resolve().then(() => handler(handlerEvent, ctx));
        let timeoutId;
        const timeoutPromise = timeoutMs > 0
            ? new Promise((resolve) => {
                timeoutId = setTimeout(() => {
                    controller.abort(`timeout:${timeoutMs}`);
                    resolve(HANDLER_TIMEOUT);
                }, timeoutMs);
            })
            : undefined;
        try {
            const result = timeoutPromise === undefined ? await handlerPromise : await Promise.race([handlerPromise, timeoutPromise]);
            if (result === HANDLER_TIMEOUT) {
                void handlerPromise.catch(() => undefined);
                this.emitError({
                    extensionPath: ext.path,
                    event: eventType,
                    error: `Extension handler timed out after ${timeoutMs}ms`,
                    phase: "event",
                    runtimeKind: "typescript",
                    extensionIdentity: ext.identity.key,
                });
                return undefined;
            }
            return result;
        }
        catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            const stack = err instanceof Error ? err.stack : undefined;
            if (err instanceof ExtensionPolicyDeniedError) {
                this.emitError({
                    extensionPath: ext.path,
                    event: eventType,
                    error: message,
                    stack,
                    phase: err.details.phase,
                    runtimeKind: err.details.runtimeKind,
                    category: err.details.category,
                    capability: err.details.capability,
                    operation: err.details.operation,
                    target: err.details.target,
                    principal: err.details.principal,
                    extensionIdentity: err.details.extensionIdentity,
                });
                return undefined;
            }
            this.emitError({
                extensionPath: ext.path,
                event: eventType,
                error: message,
                stack,
                phase: "event",
                runtimeKind: "typescript",
                extensionIdentity: ext.identity.key,
            });
            return undefined;
        }
        finally {
            if (timeoutId) {
                clearTimeout(timeoutId);
            }
        }
    }
    invalidSubscriberResult(ext, eventType, result) {
        if (result.ok) {
            return false;
        }
        this.emitError({
            extensionPath: ext.path,
            event: eventType,
            error: `Invalid subscriber result for ${eventType} at ${result.path}: ${result.message}`,
            phase: "event",
            runtimeKind: "typescript",
            extensionIdentity: ext.identity.key,
        });
        return true;
    }
    validateSessionBeforeResult(ext, eventType, handlerResult) {
        const recordResult = validateResultObject(handlerResult, eventType);
        if (this.invalidSubscriberResult(ext, eventType, recordResult))
            return undefined;
        const record = recordResult.value;
        if (!record)
            return undefined;
        for (const field of ["cancel", "skipConversationRestore", "replaceInstructions"]) {
            const boolResult = validateOptionalBoolean(record, field);
            if (this.invalidSubscriberResult(ext, eventType, boolResult))
                return undefined;
        }
        for (const field of ["customInstructions", "label"]) {
            const stringResult = validateOptionalString(record, field);
            if (this.invalidSubscriberResult(ext, eventType, stringResult))
                return undefined;
        }
        if (record.compaction !== undefined && !isRecord(record.compaction)) {
            this.invalidSubscriberResult(ext, eventType, invalid("$.compaction", "expected object"));
            return undefined;
        }
        if (record.compaction !== undefined) {
            const compaction = record.compaction;
            for (const field of ["summary", "firstKeptEntryId"]) {
                const stringResult = validateOptionalString(compaction, field);
                if (this.invalidSubscriberResult(ext, eventType, stringResult))
                    return undefined;
            }
            const numberResult = validateOptionalNumber(compaction, "tokensBefore");
            if (this.invalidSubscriberResult(ext, eventType, numberResult))
                return undefined;
        }
        if (record.summary !== undefined && !isRecord(record.summary)) {
            this.invalidSubscriberResult(ext, eventType, invalid("$.summary", "expected object"));
            return undefined;
        }
        if (record.summary !== undefined) {
            const summaryResult = validateOptionalString(record.summary, "summary");
            if (this.invalidSubscriberResult(ext, eventType, summaryResult))
                return undefined;
        }
        return record;
    }
    validateResourcesDiscoverResult(ext, handlerResult) {
        const recordResult = validateResultObject(handlerResult, "resources_discover");
        if (this.invalidSubscriberResult(ext, "resources_discover", recordResult))
            return undefined;
        const record = recordResult.value;
        if (!record)
            return undefined;
        for (const field of ["skillPaths", "promptPaths", "themePaths"]) {
            const arrayResult = validateStringArray(record[field], `$.${field}`);
            if (this.invalidSubscriberResult(ext, "resources_discover", arrayResult))
                return undefined;
        }
        return record;
    }
    validateInputResult(ext, handlerResult) {
        const recordResult = validateResultObject(handlerResult, "input");
        if (this.invalidSubscriberResult(ext, "input", recordResult))
            return undefined;
        const record = recordResult.value;
        if (!record)
            return undefined;
        if (record.action !== "continue" && record.action !== "transform" && record.action !== "handled") {
            this.invalidSubscriberResult(ext, "input", invalid("$.action", 'expected "continue", "transform", or "handled"'));
            return undefined;
        }
        if (record.action === "transform" && typeof record.text !== "string") {
            this.invalidSubscriberResult(ext, "input", invalid("$.text", "expected string"));
            return undefined;
        }
        const imagesResult = validateOptionalImageArray(record.images, "$.images");
        if (this.invalidSubscriberResult(ext, "input", imagesResult))
            return undefined;
        return record;
    }
    validateToolResultPatch(ext, handlerResult) {
        const recordResult = validateResultObject(handlerResult, "tool_result");
        if (this.invalidSubscriberResult(ext, "tool_result", recordResult))
            return undefined;
        const record = recordResult.value;
        if (!record)
            return undefined;
        const contentResult = validateContentBlocks(record.content, "$.content");
        if (this.invalidSubscriberResult(ext, "tool_result", contentResult))
            return undefined;
        const isErrorResult = validateOptionalBoolean(record, "isError");
        if (this.invalidSubscriberResult(ext, "tool_result", isErrorResult))
            return undefined;
        return record;
    }
    validateToolCallResult(ext, handlerResult) {
        const recordResult = validateResultObject(handlerResult, "tool_call");
        if (this.invalidSubscriberResult(ext, "tool_call", recordResult))
            return undefined;
        const record = recordResult.value;
        if (!record)
            return undefined;
        const blockResult = validateOptionalBoolean(record, "block");
        if (this.invalidSubscriberResult(ext, "tool_call", blockResult))
            return undefined;
        const reasonResult = validateOptionalString(record, "reason");
        if (this.invalidSubscriberResult(ext, "tool_call", reasonResult))
            return undefined;
        return record;
    }
    validateMessageEndResult(ext, handlerResult) {
        const recordResult = validateResultObject(handlerResult, "message_end");
        if (this.invalidSubscriberResult(ext, "message_end", recordResult))
            return undefined;
        const record = recordResult.value;
        if (!record)
            return undefined;
        if (record.message !== undefined) {
            if (!isRecord(record.message)) {
                this.invalidSubscriberResult(ext, "message_end", invalid("$.message", "expected object"));
                return undefined;
            }
            if (typeof record.message.role !== "string") {
                this.invalidSubscriberResult(ext, "message_end", invalid("$.message.role", "expected string"));
                return undefined;
            }
        }
        return record;
    }
    validateContextResult(ext, handlerResult) {
        const recordResult = validateResultObject(handlerResult, "context");
        if (this.invalidSubscriberResult(ext, "context", recordResult))
            return undefined;
        const record = recordResult.value;
        if (!record)
            return undefined;
        if (record.messages !== undefined && !Array.isArray(record.messages)) {
            this.invalidSubscriberResult(ext, "context", invalid("$.messages", "expected array"));
            return undefined;
        }
        return record;
    }
    validateBeforeAgentStartResult(ext, handlerResult) {
        const recordResult = validateResultObject(handlerResult, "before_agent_start");
        if (this.invalidSubscriberResult(ext, "before_agent_start", recordResult))
            return undefined;
        const record = recordResult.value;
        if (!record)
            return undefined;
        const systemPromptResult = validateOptionalString(record, "systemPrompt");
        if (this.invalidSubscriberResult(ext, "before_agent_start", systemPromptResult))
            return undefined;
        if (record.message !== undefined && !isRecord(record.message)) {
            this.invalidSubscriberResult(ext, "before_agent_start", invalid("$.message", "expected object"));
            return undefined;
        }
        if (isRecord(record.message) && typeof record.message.customType !== "string") {
            this.invalidSubscriberResult(ext, "before_agent_start", invalid("$.message.customType", "expected string"));
            return undefined;
        }
        return record;
    }
    validateUserBashResult(ext, handlerResult) {
        const recordResult = validateResultObject(handlerResult, "user_bash");
        if (this.invalidSubscriberResult(ext, "user_bash", recordResult))
            return undefined;
        const record = recordResult.value;
        if (!record)
            return undefined;
        if (record.operations !== undefined && !isRecord(record.operations)) {
            this.invalidSubscriberResult(ext, "user_bash", invalid("$.operations", "expected object"));
            return undefined;
        }
        if (record.result !== undefined && !isRecord(record.result)) {
            this.invalidSubscriberResult(ext, "user_bash", invalid("$.result", "expected object"));
            return undefined;
        }
        return record;
    }
    metadataForExtension(ext) {
        const source = ext.sourceInfo.origin === "package" ? ext.sourceInfo.source : this.getExtensionSourceLabel(ext.path);
        return {
            source,
            scope: ext.sourceInfo.scope,
            origin: ext.sourceInfo.origin,
            baseDir: ext.sourceInfo.baseDir,
            provenance: ext.sourceInfo.provenance,
        };
    }
    isPathInsideBase(pathValue, baseDir) {
        const resolvedBase = existsSync(baseDir) ? realpathSync(baseDir) : resolve(baseDir);
        const absolutePath = isAbsolute(pathValue) ? pathValue : resolve(resolvedBase, pathValue);
        const resolvedPath = existsSync(absolutePath) ? realpathSync(absolutePath) : resolve(absolutePath);
        const relativePath = relative(resolvedBase, resolvedPath);
        return relativePath === "" || (!relativePath.startsWith("..") && !isAbsolute(relativePath));
    }
    filterResourcePathsByPolicy(ext, paths, capability, operation) {
        const baseDir = ext.sourceInfo.provenance?.packageRoot ?? ext.sourceInfo.baseDir;
        if (!baseDir || hasExtensionGrant(ext.effectivePolicy, capability)) {
            return [...paths];
        }
        const allowedPaths = [];
        for (const pathValue of paths) {
            const absolutePath = isAbsolute(pathValue) ? pathValue : resolve(baseDir, pathValue);
            if (!existsSync(absolutePath) || this.isPathInsideBase(pathValue, baseDir)) {
                allowedPaths.push(pathValue);
                continue;
            }
            const denial = createExtensionPolicyDenialError(ext.identity, capability, operation, { path: pathValue });
            this.emitError({
                extensionPath: ext.path,
                event: operation,
                error: denial.message,
                phase: denial.details.phase,
                runtimeKind: denial.details.runtimeKind,
                category: denial.details.category,
                capability: denial.details.capability,
                operation: denial.details.operation,
                target: denial.details.target,
                principal: denial.details.principal,
                extensionIdentity: denial.details.extensionIdentity,
            });
        }
        return allowedPaths;
    }
    getExtensionSourceLabel(extensionPath) {
        if (extensionPath.startsWith("<")) {
            return `extension:${extensionPath.replace(/[<>]/g, "")}`;
        }
        const base = basename(extensionPath);
        const name = base.replace(/\.(ts|js)$/, "");
        return `extension:${name}`;
    }
    async emit(event) {
        const ctx = this.createContext();
        let result;
        for (const ext of this.extensions) {
            const handlers = ext.handlers.get(event.type);
            if (!handlers || handlers.length === 0)
                continue;
            for (const handler of handlers) {
                const handlerEvent = cloneForExtensionHandler(event);
                const handlerResult = await this.invokeHandler(ext, event.type, handler, handlerEvent, ctx);
                if (this.isSessionBeforeEvent(event) && handlerResult !== undefined) {
                    result = this.validateSessionBeforeResult(ext, event.type, handlerResult);
                    if (!result) {
                        continue;
                    }
                    if (result.cancel) {
                        return result;
                    }
                }
            }
        }
        return result;
    }
    async emitMessageEnd(event) {
        const ctx = this.createContext();
        let currentMessage = event.message;
        let modified = false;
        for (const ext of this.extensions) {
            const handlers = ext.handlers.get("message_end");
            if (!handlers || handlers.length === 0)
                continue;
            for (const handler of handlers) {
                const currentEvent = { ...event, message: cloneForExtensionHandler(currentMessage) };
                const handlerResult = this.validateMessageEndResult(ext, await this.invokeHandler(ext, "message_end", handler, currentEvent, ctx));
                if (!handlerResult?.message)
                    continue;
                if (handlerResult.message.role !== currentMessage.role) {
                    this.emitError({
                        extensionPath: ext.path,
                        event: "message_end",
                        error: "message_end handlers must return a message with the same role",
                        phase: "event",
                        runtimeKind: "typescript",
                        extensionIdentity: ext.identity.key,
                    });
                    continue;
                }
                currentMessage = cloneForExtensionHandler(handlerResult.message);
                modified = true;
            }
        }
        return modified ? currentMessage : undefined;
    }
    async emitToolResult(event) {
        const ctx = this.createContext();
        const currentEvent = { ...event };
        let modified = false;
        for (const ext of this.extensions) {
            const handlers = ext.handlers.get("tool_result");
            if (!handlers || handlers.length === 0)
                continue;
            for (const handler of handlers) {
                const handlerEvent = cloneForExtensionHandler(currentEvent);
                const handlerResult = this.validateToolResultPatch(ext, await this.invokeHandler(ext, "tool_result", handler, handlerEvent, ctx));
                if (!handlerResult)
                    continue;
                if (handlerResult.content !== undefined) {
                    currentEvent.content = handlerResult.content;
                    modified = true;
                }
                if (handlerResult.details !== undefined) {
                    currentEvent.details = handlerResult.details;
                    modified = true;
                }
                if (handlerResult.isError !== undefined) {
                    currentEvent.isError = handlerResult.isError;
                    modified = true;
                }
            }
        }
        if (!modified) {
            return undefined;
        }
        return {
            content: currentEvent.content,
            details: currentEvent.details,
            isError: currentEvent.isError,
        };
    }
    async emitToolCall(event) {
        const ctx = this.createContext();
        let result;
        for (const ext of this.extensions) {
            const handlers = ext.handlers.get("tool_call");
            if (!handlers || handlers.length === 0)
                continue;
            for (const handler of handlers) {
                const handlerResult = this.validateToolCallResult(ext, await this.invokeHandler(ext, "tool_call", handler, event, ctx));
                if (handlerResult) {
                    result = handlerResult;
                    if (result.block) {
                        return result;
                    }
                }
            }
        }
        return result;
    }
    async emitUserBash(event) {
        const ctx = this.createContext();
        for (const ext of this.extensions) {
            const handlers = ext.handlers.get("user_bash");
            if (!handlers || handlers.length === 0)
                continue;
            for (const handler of handlers) {
                const handlerEvent = cloneForExtensionHandler(event);
                const handlerResult = this.validateUserBashResult(ext, await this.invokeHandler(ext, "user_bash", handler, handlerEvent, ctx));
                if (handlerResult) {
                    return handlerResult;
                }
            }
        }
        return undefined;
    }
    async emitContext(messages) {
        const ctx = this.createContext();
        let currentMessages = structuredClone(messages);
        for (const ext of this.extensions) {
            const handlers = ext.handlers.get("context");
            if (!handlers || handlers.length === 0)
                continue;
            for (const handler of handlers) {
                const event = { type: "context", messages: cloneForExtensionHandler(currentMessages) };
                const handlerResult = this.validateContextResult(ext, await this.invokeHandler(ext, "context", handler, event, ctx));
                if (handlerResult?.messages) {
                    currentMessages = cloneForExtensionHandler(handlerResult.messages);
                }
            }
        }
        return currentMessages;
    }
    async emitBeforeProviderRequest(payload) {
        const ctx = this.createContext();
        let currentPayload = payload;
        for (const ext of this.extensions) {
            const handlers = ext.handlers.get("before_provider_request");
            if (!handlers || handlers.length === 0)
                continue;
            for (const handler of handlers) {
                const event = {
                    type: "before_provider_request",
                    payload: cloneForExtensionHandler(currentPayload),
                };
                const handlerResult = await this.invokeHandler(ext, "before_provider_request", handler, event, ctx);
                if (handlerResult !== undefined) {
                    currentPayload = cloneForExtensionHandler(handlerResult);
                }
            }
        }
        return currentPayload;
    }
    async emitBeforeAgentStart(prompt, images, systemPrompt, systemPromptOptions) {
        let currentSystemPrompt = systemPrompt;
        const ctx = Object.defineProperties({}, Object.getOwnPropertyDescriptors(this.createContext()));
        ctx.getSystemPrompt = () => {
            this.assertActive();
            return currentSystemPrompt;
        };
        const messages = [];
        let systemPromptModified = false;
        for (const ext of this.extensions) {
            const handlers = ext.handlers.get("before_agent_start");
            if (!handlers || handlers.length === 0)
                continue;
            for (const handler of handlers) {
                const event = {
                    type: "before_agent_start",
                    prompt,
                    images: cloneForExtensionHandler(images),
                    systemPrompt: currentSystemPrompt,
                    systemPromptOptions: cloneForExtensionHandler(systemPromptOptions),
                };
                const result = this.validateBeforeAgentStartResult(ext, await this.invokeHandler(ext, "before_agent_start", handler, event, ctx));
                if (result) {
                    if (result.message) {
                        messages.push(cloneForExtensionHandler(result.message));
                    }
                    if (result.systemPrompt !== undefined) {
                        currentSystemPrompt = result.systemPrompt;
                        systemPromptModified = true;
                    }
                }
            }
        }
        if (messages.length > 0 || systemPromptModified) {
            return {
                messages: messages.length > 0 ? messages : undefined,
                systemPrompt: systemPromptModified ? currentSystemPrompt : undefined,
            };
        }
        return undefined;
    }
    async emitResourcesDiscover(cwd, reason) {
        const ctx = this.createContext();
        const skillPaths = [];
        const promptPaths = [];
        const themePaths = [];
        for (const ext of this.extensions) {
            const handlers = ext.handlers.get("resources_discover");
            if (!handlers || handlers.length === 0)
                continue;
            for (const handler of handlers) {
                const event = { type: "resources_discover", cwd, reason };
                const result = this.validateResourcesDiscoverResult(ext, await this.invokeHandler(ext, "resources_discover", handler, event, ctx));
                const metadata = this.metadataForExtension(ext);
                const allowedSkillPaths = result?.skillPaths
                    ? this.filterResourcePathsByPolicy(ext, result.skillPaths, "file.read", "resources_discover")
                    : undefined;
                const allowedPromptPaths = result?.promptPaths
                    ? this.filterResourcePathsByPolicy(ext, result.promptPaths, "file.read", "resources_discover")
                    : undefined;
                const allowedThemePaths = result?.themePaths
                    ? this.filterResourcePathsByPolicy(ext, result.themePaths, "file.read", "resources_discover")
                    : undefined;
                if (allowedSkillPaths?.length) {
                    skillPaths.push(...allowedSkillPaths.map((path) => ({ path, extensionPath: ext.path, metadata })));
                }
                if (allowedPromptPaths?.length) {
                    promptPaths.push(...allowedPromptPaths.map((path) => ({ path, extensionPath: ext.path, metadata })));
                }
                if (allowedThemePaths?.length) {
                    themePaths.push(...allowedThemePaths.map((path) => ({ path, extensionPath: ext.path, metadata })));
                }
            }
        }
        return { skillPaths, promptPaths, themePaths };
    }
    /** Emit input event. Transforms chain, "handled" short-circuits. */
    async emitInput(text, images, source) {
        const ctx = this.createContext();
        let currentText = text;
        let currentImages = images;
        for (const ext of this.extensions) {
            for (const handler of ext.handlers.get("input") ?? []) {
                const event = {
                    type: "input",
                    text: currentText,
                    images: cloneForExtensionHandler(currentImages),
                    source,
                };
                const result = this.validateInputResult(ext, await this.invokeHandler(ext, "input", handler, event, ctx));
                if (result?.action === "handled")
                    return result;
                if (result?.action === "transform") {
                    currentText = result.text;
                    currentImages = result.images ?? currentImages;
                }
            }
        }
        return currentText !== text || currentImages !== images
            ? { action: "transform", text: currentText, images: currentImages }
            : { action: "continue" };
    }
}
//# sourceMappingURL=runner.js.map