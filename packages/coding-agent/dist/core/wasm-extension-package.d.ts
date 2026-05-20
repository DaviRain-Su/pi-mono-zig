export declare const WASM_EXTENSION_MANIFEST_NAME = "pi-extension.json";
export declare const WASM_EXTENSION_SCHEMA_VERSION = "pi-extension.v0";
export declare const WASM_DENIED_CAPABILITY_CATEGORY = "denied_capability";
export declare const WASM_CANONICAL_SECURITY_GRANTS: readonly ["file.read", "file.write", "network.request", "shell.run", "env.read", "model.call", "session.read", "session.write", "ui.notify", "tool.use", "agent.spawn", "agent.delegate"];
export declare const WASM_CANONICAL_CAPABILITIES: readonly ["file.read", "file.write", "network.request", "shell.run", "env.read", "model.call", "session.read", "session.write", "ui.notify", "tool.use", "agent.spawn", "agent.delegate"];
export interface WasmExtensionPackageManifest {
    kind: "wasm-extension";
    packageRoot: string;
    manifestPath: string;
    policyLookupKey: string;
    schemaVersion: string;
    id: string;
    name: string;
    version: string;
    description: string;
    artifactKind: "wasm-component";
    artifactPath: string;
    artifactAbsolutePath: string;
    artifactSha256: string;
    toolId: string;
    toolDescription: string;
    capabilities: string[];
    resourceLimits: WasmExtensionResourceLimits;
}
export interface WasmExtensionResourceLimits {
    maxChildren?: number;
    depth?: number;
    turns?: number;
    timeoutMs?: number;
    outputBytes?: number;
    outputLines?: number;
    toolScopes: string[];
}
export interface WasmExtensionPackagePolicyRequest {
    packageRoot: string;
    manifestPath: string;
    policyLookupKey: string;
    schemaVersion: string;
    id: string;
    name: string;
    version: string;
    description: string;
    artifactPath: string;
    toolId: string;
    toolDescription: string;
    capabilities: string[];
    resourceLimits: WasmExtensionResourceLimits;
}
export interface WasmExtensionPackageValidationOptions {
    approvedCapabilities?: readonly string[];
    resolveApprovedCapabilities?: (request: WasmExtensionPackagePolicyRequest) => readonly string[] | undefined;
}
export interface WasmExtensionCapabilityDenialDetails {
    category: typeof WASM_DENIED_CAPABILITY_CATEGORY;
    capability: string;
    operation: string;
    branch: string;
    phase: "validate";
    mode: "manifest-request";
    reason: "grant is not approved";
    path: string;
    principal: {
        runtimeKind: "wasm";
        extensionId: string;
        policyLookupKey: string;
        toolId: string;
    };
    source: {
        manifestPath: string;
        packageRoot: string;
        artifactPath: string;
    };
}
export declare class WasmExtensionCapabilityDenialError extends Error {
    readonly details: WasmExtensionCapabilityDenialDetails;
    constructor(message: string, details: WasmExtensionCapabilityDenialDetails);
}
export declare function hasWasmExtensionManifest(packageRoot: string): boolean;
export declare function validateWasmExtensionPackage(packageRoot: string, options?: WasmExtensionPackageValidationOptions): WasmExtensionPackageManifest;
export declare function readWasmExtensionPackagePolicyRequest(packageRoot: string): WasmExtensionPackagePolicyRequest;
//# sourceMappingURL=wasm-extension-package.d.ts.map