/**
 * Extension loader - loads TypeScript extension modules using jiti.
 *
 */
import { type EventBus } from "../event-bus.js";
import { type ExtensionPolicy, type TypeScriptExtensionIdentity } from "../extension-policy.js";
import { type SourceInfo } from "../source-info.js";
import type { Extension, ExtensionFactory, ExtensionRuntime, LoadExtensionsResult } from "./types.js";
export interface LoadExtensionOptions {
    resolveSourceInfo?: (request: {
        configuredPath: string;
        resolvedPath: string;
    }) => SourceInfo | undefined;
    resolveEffectivePolicy?: (identity: TypeScriptExtensionIdentity) => ExtensionPolicy | undefined;
}
/**
 * Create a runtime with throwing stubs for action methods.
 * Runner.bindCore() replaces these with real implementations.
 */
export declare function createExtensionRuntime(): ExtensionRuntime;
/**
 * Create an Extension from an inline factory function.
 */
export declare function loadExtensionFromFactory(factory: ExtensionFactory, cwd: string, eventBus: EventBus, runtime: ExtensionRuntime, extensionPath?: string, effectivePolicy?: ExtensionPolicy): Promise<Extension>;
/**
 * Load extensions from paths.
 */
export declare function loadExtensions(paths: string[], cwd: string, eventBus?: EventBus, options?: LoadExtensionOptions): Promise<LoadExtensionsResult>;
/**
 * Discover and load extensions from standard locations.
 */
export declare function discoverAndLoadExtensions(configuredPaths: string[], cwd: string, agentDir?: string, eventBus?: EventBus): Promise<LoadExtensionsResult>;
//# sourceMappingURL=loader.d.ts.map