import type { SourceInfo } from "./source-info.js";
import { type WasmExtensionPackageManifest, type WasmExtensionResourceLimits } from "./wasm-extension-package.js";
export declare const CANONICAL_EXTENSION_GRANTS: readonly ["file.read", "file.write", "network.request", "shell.run", "env.read", "model.call", "session.read", "session.write", "ui.notify", "tool.use", "agent.spawn", "agent.delegate"];
export type CanonicalExtensionGrant = (typeof CANONICAL_EXTENSION_GRANTS)[number];
export interface ExtensionResourceLimits {
    maxChildren?: number;
    depth?: number;
    turns?: number;
    timeoutMs?: number;
    outputBytes?: number;
    outputLines?: number;
    toolScopes?: readonly string[];
}
export interface ExtensionPolicy {
    approvedGrants?: readonly CanonicalExtensionGrant[];
    resourceLimits?: ExtensionResourceLimits;
}
export type ExtensionPolicyMap = Record<string, ExtensionPolicy>;
export interface ExtensionPolicyDenialDetails {
    category: "denied_capability";
    capability: CanonicalExtensionGrant;
    operation: string;
    phase: "call";
    runtimeKind: ExtensionPolicyRuntimeKind;
    extensionIdentity: string;
    principal: {
        runtimeKind: ExtensionPolicyRuntimeKind;
        extensionId: string;
    };
    target?: unknown;
}
export declare class ExtensionPolicyDeniedError extends Error {
    readonly details: ExtensionPolicyDenialDetails;
    constructor(details: ExtensionPolicyDenialDetails);
}
export interface ExtensionPolicyMapValidationResult {
    policies: ExtensionPolicyMap;
    errors: Error[];
}
export type ExtensionPolicyRuntimeKind = "typescript" | "wasm" | "native" | "process_jsonl";
interface ExtensionIdentityBase {
    key: string;
    runtimeKind: ExtensionPolicyRuntimeKind;
    displayName: string;
}
export interface TypeScriptExtensionIdentity extends ExtensionIdentityBase {
    kind: "typescript-inline" | "typescript-local" | "typescript-package";
    runtimeKind: "typescript";
    configuredPath: string;
    resolvedPath: string;
    sourceInfo: SourceInfo;
    baseDir?: string;
    packageSource?: string;
    entryPath?: string;
}
export interface WasmExtensionIdentity extends ExtensionIdentityBase {
    kind: "wasm-manifest";
    runtimeKind: "wasm";
    schemaVersion: string;
    manifestId: string;
    name: string;
    version: string;
    manifestPath: string;
    packageRoot: string;
    artifactPath: string;
    artifactAbsolutePath: string;
    artifactSha256: string;
    toolId: string;
    sourceInfo: SourceInfo;
}
export interface NativeExtensionIdentity extends ExtensionIdentityBase {
    kind: "native-descriptor";
    runtimeKind: "native";
    descriptorId: string;
    name: string;
    version: string;
    description: string;
    extensionPath?: string;
}
export interface ProcessJsonlExtensionIdentity extends ExtensionIdentityBase {
    kind: "process-jsonl";
    runtimeKind: "process_jsonl";
    commandPath: string;
    argv: readonly string[];
    extensionPath?: string;
    cwd?: string;
}
export type CanonicalExtensionIdentity = TypeScriptExtensionIdentity | WasmExtensionIdentity | NativeExtensionIdentity | ProcessJsonlExtensionIdentity;
export declare function createWasmExtensionPolicyPrefix(options: {
    schemaVersion: string;
    id: string;
    version: string;
}): string;
export declare function createWasmExtensionLegacyPolicyKey(manifest: WasmExtensionPackageManifest): string;
export declare function createWasmExtensionManifestPolicyKey(options: {
    schemaVersion: string;
    id: string;
    version: string;
    manifestPath: string;
    packageRoot: string;
    artifactPath: string;
}): string;
export declare function isCanonicalExtensionGrant(value: string): value is CanonicalExtensionGrant;
export declare function hasExtensionGrant(policy: ExtensionPolicy | undefined, grant: CanonicalExtensionGrant): boolean;
export declare function createExtensionPolicyDenialError(identity: CanonicalExtensionIdentity, capability: CanonicalExtensionGrant, operation: string, target?: unknown): ExtensionPolicyDeniedError;
export declare function assertExtensionGrant(identity: CanonicalExtensionIdentity, policy: ExtensionPolicy | undefined, capability: CanonicalExtensionGrant, operation: string, target?: unknown): void;
export declare function createTypeScriptExtensionIdentity(options: {
    configuredPath: string;
    resolvedPath: string;
    sourceInfo: SourceInfo;
}): TypeScriptExtensionIdentity;
export declare function createWasmExtensionIdentity(manifest: WasmExtensionPackageManifest, sourceInfo: SourceInfo): WasmExtensionIdentity;
export declare function createNativeExtensionIdentity(options: {
    id: string;
    name: string;
    version: string;
    description: string;
    extensionPath?: string;
}): NativeExtensionIdentity;
export declare function createProcessJsonlExtensionIdentity(options: {
    argv: readonly string[];
    extensionPath?: string;
    cwd?: string;
}): ProcessJsonlExtensionIdentity;
export declare function validateExtensionPolicyShape(value: unknown, path?: string): ExtensionPolicy;
export declare function validateExtensionPolicyMap(value: unknown, path?: string): ExtensionPolicyMapValidationResult;
export declare function mergeExtensionPolicy(base: ExtensionPolicy | undefined, override: ExtensionPolicy): ExtensionPolicy;
export declare function mergeExtensionPolicyMaps(base: ExtensionPolicyMap | undefined, overrides: ExtensionPolicyMap | undefined): ExtensionPolicyMap | undefined;
export declare function normalizeWasmResourceLimits(limits: WasmExtensionResourceLimits): ExtensionResourceLimits;
export {};
//# sourceMappingURL=extension-policy.d.ts.map