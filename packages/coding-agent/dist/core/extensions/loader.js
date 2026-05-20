/**
 * Extension loader - loads TypeScript extension modules using jiti.
 *
 */
import * as fs from "node:fs";
import { createRequire } from "node:module";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import * as _bundledPiAgentCore from "@earendil-works/pi-agent-core";
import * as _bundledPiAi from "@earendil-works/pi-ai";
import * as _bundledPiAiOauth from "@earendil-works/pi-ai/oauth";
import * as _bundledPiTui from "@earendil-works/pi-tui";
import { createJiti } from "jiti";
// Static imports of packages that extensions may use.
// These MUST be static so Bun bundles them into the compiled binary.
// The virtualModules option then makes them available to extensions.
import * as _bundledTypebox from "typebox";
import * as _bundledTypeboxCompile from "typebox/compile";
import * as _bundledTypeboxValue from "typebox/value";
import { CONFIG_DIR_NAME, getAgentDir, isBunBinary } from "../../config.js";
// NOTE: This import works because loader.ts exports are NOT re-exported from index.ts,
// avoiding a circular dependency. Extensions can import from @earendil-works/pi-coding-agent.
import * as _bundledPiCodingAgent from "../../index.js";
import { attachDiagnosticEnvelope, createDiagnosticEnvelope } from "../diagnostics.js";
import { createEventBus } from "../event-bus.js";
import { execCommand } from "../exec.js";
import { assertExtensionGrant, createTypeScriptExtensionIdentity, } from "../extension-policy.js";
import { createSyntheticSourceInfo } from "../source-info.js";
import { hasWasmExtensionManifest } from "../wasm-extension-package.js";
import { assertSubAgentReservedNameAllowed, isSubAgentExtensionFactory, isSubAgentReservedName, } from "./subagent-reserved-names.js";
import { isExtensionEventName } from "./types.js";
/** Modules available to extensions via virtualModules (for compiled Bun binary) */
const VIRTUAL_MODULES = {
    typebox: _bundledTypebox,
    "typebox/compile": _bundledTypeboxCompile,
    "typebox/value": _bundledTypeboxValue,
    "@sinclair/typebox": _bundledTypebox,
    "@sinclair/typebox/compile": _bundledTypeboxCompile,
    "@sinclair/typebox/value": _bundledTypeboxValue,
    "@earendil-works/pi-agent-core": _bundledPiAgentCore,
    "@earendil-works/pi-tui": _bundledPiTui,
    "@earendil-works/pi-ai": _bundledPiAi,
    "@earendil-works/pi-ai/oauth": _bundledPiAiOauth,
    "@earendil-works/pi-coding-agent": _bundledPiCodingAgent,
    "@mariozechner/pi-agent-core": _bundledPiAgentCore,
    "@mariozechner/pi-tui": _bundledPiTui,
    "@mariozechner/pi-ai": _bundledPiAi,
    "@mariozechner/pi-ai/oauth": _bundledPiAiOauth,
    "@mariozechner/pi-coding-agent": _bundledPiCodingAgent,
};
const require = createRequire(import.meta.url);
/**
 * Get aliases for jiti so extensions can import workspace packages and
 * typebox-compatible specifiers consistently.
 */
let _aliases = null;
function getAliases() {
    if (_aliases)
        return _aliases;
    const __dirname = path.dirname(fileURLToPath(import.meta.url));
    const typeboxEntry = require.resolve("typebox");
    const typeboxCompileEntry = require.resolve("typebox/compile");
    const typeboxValueEntry = require.resolve("typebox/value");
    const packagesRoot = path.resolve(__dirname, "../../../../");
    const resolveWorkspaceOrImport = (workspaceRelativePaths, specifier) => {
        for (const workspaceRelativePath of workspaceRelativePaths) {
            const workspacePath = path.join(packagesRoot, workspaceRelativePath);
            if (fs.existsSync(workspacePath)) {
                return workspacePath;
            }
        }
        return require.resolve(specifier);
    };
    const piCodingAgentEntry = resolveWorkspaceOrImport(["coding-agent/dist/index.js", "coding-agent/src/index.ts"], "@earendil-works/pi-coding-agent");
    const piAgentCoreEntry = resolveWorkspaceOrImport(["agent/dist/index.js", "agent/src/index.ts"], "@earendil-works/pi-agent-core");
    const piTuiEntry = resolveWorkspaceOrImport(["tui/dist/index.js", "tui/src/index.ts"], "@earendil-works/pi-tui");
    const piAiEntry = resolveWorkspaceOrImport(["ai/dist/index.js", "ai/src/index.ts"], "@earendil-works/pi-ai");
    const piAiOauthEntry = resolveWorkspaceOrImport(["ai/dist/oauth.js", "ai/src/oauth.ts"], "@earendil-works/pi-ai/oauth");
    _aliases = {
        "@earendil-works/pi-coding-agent": piCodingAgentEntry,
        "@earendil-works/pi-agent-core": piAgentCoreEntry,
        "@earendil-works/pi-tui": piTuiEntry,
        "@earendil-works/pi-ai": piAiEntry,
        "@earendil-works/pi-ai/oauth": piAiOauthEntry,
        "@mariozechner/pi-coding-agent": piCodingAgentEntry,
        "@mariozechner/pi-agent-core": piAgentCoreEntry,
        "@mariozechner/pi-tui": piTuiEntry,
        "@mariozechner/pi-ai": piAiEntry,
        "@mariozechner/pi-ai/oauth": piAiOauthEntry,
        typebox: typeboxEntry,
        "typebox/compile": typeboxCompileEntry,
        "typebox/value": typeboxValueEntry,
        "@sinclair/typebox": typeboxEntry,
        "@sinclair/typebox/compile": typeboxCompileEntry,
        "@sinclair/typebox/value": typeboxValueEntry,
    };
    return _aliases;
}
const UNICODE_SPACES = /[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g;
function normalizeUnicodeSpaces(str) {
    return str.replace(UNICODE_SPACES, " ");
}
function expandPath(p) {
    const normalized = normalizeUnicodeSpaces(p);
    if (normalized.startsWith("~/")) {
        return path.join(os.homedir(), normalized.slice(2));
    }
    if (normalized.startsWith("~")) {
        return path.join(os.homedir(), normalized.slice(1));
    }
    return normalized;
}
function resolvePath(extPath, cwd) {
    const expanded = expandPath(extPath);
    if (path.isAbsolute(expanded)) {
        return expanded;
    }
    return path.resolve(cwd, expanded);
}
/**
 * Create a runtime with throwing stubs for action methods.
 * Runner.bindCore() replaces these with real implementations.
 */
export function createExtensionRuntime() {
    const notInitialized = () => {
        throw new Error("Extension runtime not initialized. Action methods cannot be called during extension loading.");
    };
    const state = {};
    const assertActive = () => {
        if (state.staleMessage) {
            throw new Error(state.staleMessage);
        }
    };
    const runtime = {
        sendMessage: notInitialized,
        sendUserMessage: notInitialized,
        appendEntry: notInitialized,
        setSessionName: notInitialized,
        getSessionName: notInitialized,
        setLabel: notInitialized,
        getActiveTools: notInitialized,
        getAllTools: notInitialized,
        setActiveTools: notInitialized,
        // registerTool() is valid during extension load; refresh is only needed post-bind.
        refreshTools: () => { },
        getCommands: notInitialized,
        setModel: () => Promise.reject(new Error("Extension runtime not initialized")),
        getThinkingLevel: notInitialized,
        setThinkingLevel: notInitialized,
        flagValues: new Map(),
        pendingProviderRegistrations: [],
        assertActive,
        invalidate: (message) => {
            state.staleMessage ??=
                message ??
                    "This extension ctx is stale after session replacement or reload. Do not use a captured pi or command ctx after ctx.newSession(), ctx.fork(), ctx.switchSession(), or ctx.reload(). For newSession, fork, and switchSession, move post-replacement work into withSession and use the ctx passed to withSession. For reload, do not use the old ctx after await ctx.reload().";
        },
        // Pre-bind: queue registrations so bindCore() can flush them once the
        // model registry is available. bindCore() replaces both with direct calls.
        registerProvider: (name, config, extensionPath = "<unknown>") => {
            runtime.pendingProviderRegistrations.push({ name, config, extensionPath });
        },
        unregisterProvider: (name) => {
            runtime.pendingProviderRegistrations = runtime.pendingProviderRegistrations.filter((r) => r.name !== name);
        },
    };
    return runtime;
}
function createRevocableEventBus(eventBus, assertActive) {
    return {
        emit(channel, data) {
            assertActive();
            eventBus.emit(channel, data);
        },
        on(channel, handler) {
            assertActive();
            let subscribed = true;
            const unsubscribe = eventBus.on(channel, (data) => {
                if (!subscribed)
                    return;
                try {
                    assertActive();
                }
                catch {
                    return;
                }
                return handler(data);
            });
            return () => {
                assertActive();
                subscribed = false;
                unsubscribe();
            };
        },
    };
}
/**
 * Create the ExtensionAPI for an extension.
 * Registration methods write to the extension object.
 * Action methods delegate to the shared runtime.
 */
function createExtensionAPI(extension, runtime, cwd, eventBus) {
    const assertGrant = (capability, operation, target) => assertExtensionGrant(extension.identity, extension.effectivePolicy, capability, operation, target);
    const api = {
        getExtensionIdentity() {
            runtime.assertActive();
            return extension.identity;
        },
        getExtensionPolicy() {
            runtime.assertActive();
            return extension.effectivePolicy;
        },
        // Registration methods - write to extension
        on(event, handler) {
            runtime.assertActive();
            if (typeof event !== "string" || !isExtensionEventName(event)) {
                throw new Error(`Unknown extension event "${String(event)}". Supported events: use ExtensionEventName.`);
            }
            const list = extension.handlers.get(event) ?? [];
            list.push(handler);
            extension.handlers.set(event, list);
        },
        registerTool(tool) {
            runtime.assertActive();
            assertSubAgentReservedNameAllowed(tool.name, extension.ownsSubAgentReservedNames, "register");
            extension.tools.set(tool.name, {
                definition: tool,
                sourceInfo: extension.sourceInfo,
            });
            runtime.refreshTools();
        },
        registerCommand(name, options) {
            runtime.assertActive();
            assertSubAgentReservedNameAllowed(name, extension.ownsSubAgentReservedNames, "register");
            extension.commands.set(name, {
                name,
                sourceInfo: extension.sourceInfo,
                ...options,
            });
        },
        registerShortcut(shortcut, options) {
            runtime.assertActive();
            extension.shortcuts.set(shortcut, { shortcut, extensionPath: extension.path, ...options });
        },
        registerFlag(name, options) {
            runtime.assertActive();
            extension.flags.set(name, { name, extensionPath: extension.path, ...options });
            if (options.default !== undefined && !runtime.flagValues.has(name)) {
                runtime.flagValues.set(name, options.default);
            }
        },
        registerMessageRenderer(customType, renderer) {
            runtime.assertActive();
            assertSubAgentReservedNameAllowed(customType, extension.ownsSubAgentReservedNames, "register");
            extension.messageRenderers.set(customType, renderer);
        },
        // Flag access - checks extension registered it, reads from runtime
        getFlag(name) {
            runtime.assertActive();
            if (!extension.flags.has(name))
                return undefined;
            return runtime.flagValues.get(name);
        },
        // Action methods - delegate to shared runtime
        sendMessage(message, options) {
            runtime.assertActive();
            const customType = String(message.customType);
            const isSubAgentReserved = isSubAgentReservedName(customType);
            assertSubAgentReservedNameAllowed(customType, extension.ownsSubAgentReservedNames, "write");
            if (!isSubAgentReserved) {
                assertGrant("session.write", "send_message");
            }
            runtime.sendMessage(message, options);
        },
        sendUserMessage(content, options) {
            runtime.assertActive();
            assertGrant("session.write", "send_user_message");
            runtime.sendUserMessage(content, options);
        },
        appendEntry(customType, data) {
            runtime.assertActive();
            const isSubAgentReserved = isSubAgentReservedName(customType);
            assertSubAgentReservedNameAllowed(customType, extension.ownsSubAgentReservedNames, "write");
            if (!isSubAgentReserved) {
                assertGrant("session.write", "append_entry", { customType });
            }
            runtime.appendEntry(customType, data);
        },
        setSessionName(name) {
            runtime.assertActive();
            assertGrant("session.write", "set_session_name");
            runtime.setSessionName(name);
        },
        getSessionName() {
            runtime.assertActive();
            return runtime.getSessionName();
        },
        setLabel(entryId, label) {
            runtime.assertActive();
            assertGrant("session.write", "set_label", { entryId });
            runtime.setLabel(entryId, label);
        },
        exec(command, args, options) {
            runtime.assertActive();
            assertGrant("shell.run", "exec", { command });
            if (typeof command !== "string" || command.length === 0) {
                throw new Error("exec command must be a non-empty string");
            }
            if (!Array.isArray(args) || args.some((arg) => typeof arg !== "string")) {
                throw new Error("exec args must be a string array");
            }
            return execCommand(command, args, options?.cwd ?? cwd, options);
        },
        getActiveTools() {
            runtime.assertActive();
            return runtime.getActiveTools();
        },
        getAllTools() {
            runtime.assertActive();
            return runtime.getAllTools();
        },
        setActiveTools(toolNames) {
            runtime.assertActive();
            assertGrant("tool.use", "set_active_tools");
            runtime.setActiveTools(toolNames);
        },
        getCommands() {
            runtime.assertActive();
            return runtime.getCommands();
        },
        setModel(model) {
            runtime.assertActive();
            assertGrant("model.call", "set_model", { provider: model.provider, id: model.id });
            return runtime.setModel(model);
        },
        getThinkingLevel() {
            runtime.assertActive();
            return runtime.getThinkingLevel();
        },
        setThinkingLevel(level) {
            runtime.assertActive();
            assertGrant("model.call", "set_thinking_level");
            runtime.setThinkingLevel(level);
        },
        registerProvider(name, config) {
            runtime.assertActive();
            assertGrant("model.call", "register_provider", { provider: name });
            runtime.registerProvider(name, config, extension.path);
        },
        unregisterProvider(name) {
            runtime.assertActive();
            assertGrant("model.call", "unregister_provider", { provider: name });
            runtime.unregisterProvider(name, extension.path);
        },
        events: createRevocableEventBus(eventBus, () => runtime.assertActive()),
    };
    return api;
}
async function loadExtensionModule(extensionPath) {
    const jiti = createJiti(import.meta.url, {
        moduleCache: false,
        // In Bun binary: use virtualModules for bundled packages (no filesystem resolution).
        // Also disable tryNative so jiti handles all imports, not just the entry point.
        // In Node.js/dev: use aliases to resolve to workspace or node_modules paths.
        ...(isBunBinary ? { virtualModules: VIRTUAL_MODULES, tryNative: false } : { alias: getAliases() }),
    });
    const module = await jiti.import(extensionPath, { default: true });
    const factory = module;
    return typeof factory !== "function" ? undefined : factory;
}
/**
 * Create an Extension object with empty collections.
 */
function createExtension(extensionPath, resolvedPath, options) {
    const source = extensionPath.startsWith("<") && extensionPath.endsWith(">")
        ? extensionPath.slice(1, -1).split(":")[0] || "temporary"
        : "local";
    const baseDir = extensionPath.startsWith("<") ? undefined : path.dirname(resolvedPath);
    const sourceInfo = options?.sourceInfo ?? createSyntheticSourceInfo(extensionPath, { source, baseDir });
    return {
        path: extensionPath,
        resolvedPath,
        sourceInfo,
        identity: createTypeScriptExtensionIdentity({ configuredPath: extensionPath, resolvedPath, sourceInfo }),
        effectivePolicy: options?.effectivePolicy,
        ownsSubAgentReservedNames: options?.ownsSubAgentReservedNames,
        handlers: new Map(),
        tools: new Map(),
        messageRenderers: new Map(),
        commands: new Map(),
        flags: new Map(),
        shortcuts: new Map(),
    };
}
async function loadExtension(extensionPath, cwd, eventBus, runtime, options) {
    const resolvedPath = resolvePath(extensionPath, cwd);
    try {
        const sourceInfo = options?.resolveSourceInfo?.({ configuredPath: extensionPath, resolvedPath });
        const factory = await loadExtensionModule(resolvedPath);
        if (!factory) {
            return {
                extension: null,
                error: createLoadExtensionError(extensionPath, `Extension does not export a valid factory function: ${extensionPath}`),
            };
        }
        const extension = createExtension(extensionPath, resolvedPath, {
            sourceInfo,
            ownsSubAgentReservedNames: isSubAgentExtensionFactory(factory),
        });
        extension.effectivePolicy = options?.resolveEffectivePolicy?.(extension.identity);
        const api = createExtensionAPI(extension, runtime, cwd, eventBus);
        await factory(api);
        return { extension, error: null };
    }
    catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        return {
            extension: null,
            error: createLoadExtensionError(extensionPath, `Failed to load extension: ${message}`),
        };
    }
}
function createLoadExtensionError(extensionPath, message) {
    const envelope = createDiagnosticEnvelope({
        severity: "error",
        phase: "load",
        runtimeKind: "typescript",
        category: "extension_load_failed",
        message,
        recoveryHint: "Fix or remove the extension, then reload extensions.",
        source: { path: extensionPath },
        path: extensionPath,
    });
    return attachDiagnosticEnvelope({ path: extensionPath, error: envelope.message }, envelope);
}
/**
 * Create an Extension from an inline factory function.
 */
export async function loadExtensionFromFactory(factory, cwd, eventBus, runtime, extensionPath = "<inline>", effectivePolicy) {
    const extension = createExtension(extensionPath, extensionPath, {
        effectivePolicy,
        ownsSubAgentReservedNames: isSubAgentExtensionFactory(factory),
    });
    const api = createExtensionAPI(extension, runtime, cwd, eventBus);
    await factory(api);
    return extension;
}
/**
 * Load extensions from paths.
 */
export async function loadExtensions(paths, cwd, eventBus, options) {
    const extensions = [];
    const errors = [];
    const resolvedEventBus = eventBus ?? createEventBus();
    const runtime = createExtensionRuntime();
    for (const extPath of paths) {
        const { extension, error } = await loadExtension(extPath, cwd, resolvedEventBus, runtime, options);
        if (error) {
            errors.push(error);
            continue;
        }
        if (extension) {
            extensions.push(extension);
        }
    }
    return {
        extensions,
        errors,
        runtime,
    };
}
function readPiManifest(packageJsonPath) {
    try {
        const content = fs.readFileSync(packageJsonPath, "utf-8");
        const pkg = JSON.parse(content);
        if (pkg.pi && typeof pkg.pi === "object") {
            return pkg.pi;
        }
        return null;
    }
    catch {
        return null;
    }
}
function isExtensionFile(name) {
    return name.endsWith(".ts") || name.endsWith(".js");
}
/**
 * Resolve extension entry points from a directory.
 *
 * Checks for:
 * 1. package.json with "pi.extensions" field -> returns declared paths
 * 2. index.ts or index.js -> returns the index file
 *
 * Returns resolved paths or null if no entry points found.
 */
function resolveExtensionEntries(dir) {
    if (hasWasmExtensionManifest(dir)) {
        return null;
    }
    // Check for package.json with "pi" field first
    const packageJsonPath = path.join(dir, "package.json");
    if (fs.existsSync(packageJsonPath)) {
        const manifest = readPiManifest(packageJsonPath);
        if (manifest?.extensions?.length) {
            const entries = [];
            for (const extPath of manifest.extensions) {
                const resolvedExtPath = path.resolve(dir, extPath);
                if (fs.existsSync(resolvedExtPath)) {
                    entries.push(resolvedExtPath);
                }
            }
            if (entries.length > 0) {
                return entries;
            }
        }
    }
    // Check for index.ts or index.js
    const indexTs = path.join(dir, "index.ts");
    const indexJs = path.join(dir, "index.js");
    if (fs.existsSync(indexTs)) {
        return [indexTs];
    }
    if (fs.existsSync(indexJs)) {
        return [indexJs];
    }
    return null;
}
/**
 * Discover extensions in a directory.
 *
 * Discovery rules:
 * 1. Direct files: `extensions/*.ts` or `*.js` → load
 * 2. Subdirectory with index: `extensions/* /index.ts` or `index.js` → load
 * 3. Subdirectory with package.json: `extensions/* /package.json` with "pi" field → load what it declares
 *
 * No recursion beyond one level. Complex packages must use package.json manifest.
 */
function discoverExtensionsInDir(dir) {
    if (!fs.existsSync(dir)) {
        return [];
    }
    if (hasWasmExtensionManifest(dir)) {
        return [];
    }
    const discovered = [];
    try {
        const entries = fs.readdirSync(dir, { withFileTypes: true });
        for (const entry of entries) {
            const entryPath = path.join(dir, entry.name);
            // 1. Direct files: *.ts or *.js
            if ((entry.isFile() || entry.isSymbolicLink()) && isExtensionFile(entry.name)) {
                discovered.push(entryPath);
                continue;
            }
            // 2 & 3. Subdirectories
            if (entry.isDirectory() || entry.isSymbolicLink()) {
                const entries = resolveExtensionEntries(entryPath);
                if (entries) {
                    discovered.push(...entries);
                }
            }
        }
    }
    catch {
        return [];
    }
    return discovered;
}
/**
 * Discover and load extensions from standard locations.
 */
export async function discoverAndLoadExtensions(configuredPaths, cwd, agentDir = getAgentDir(), eventBus) {
    const allPaths = [];
    const seen = new Set();
    const addPaths = (paths) => {
        for (const p of paths) {
            const resolved = path.resolve(p);
            if (!seen.has(resolved)) {
                seen.add(resolved);
                allPaths.push(p);
            }
        }
    };
    // 1. Project-local extensions: cwd/${CONFIG_DIR_NAME}/extensions/
    const localExtDir = path.join(cwd, CONFIG_DIR_NAME, "extensions");
    addPaths(discoverExtensionsInDir(localExtDir));
    // 2. Global extensions: agentDir/extensions/
    const globalExtDir = path.join(agentDir, "extensions");
    addPaths(discoverExtensionsInDir(globalExtDir));
    // 3. Explicitly configured paths
    for (const p of configuredPaths) {
        const resolved = resolvePath(p, cwd);
        if (fs.existsSync(resolved) && fs.statSync(resolved).isDirectory()) {
            if (hasWasmExtensionManifest(resolved)) {
                continue;
            }
            // Check for package.json with pi manifest or index.ts
            const entries = resolveExtensionEntries(resolved);
            if (entries) {
                addPaths(entries);
                continue;
            }
            // No explicit entries - discover individual files in directory
            addPaths(discoverExtensionsInDir(resolved));
            continue;
        }
        addPaths([resolved]);
    }
    return loadExtensions(allPaths, cwd, eventBus);
}
//# sourceMappingURL=loader.js.map