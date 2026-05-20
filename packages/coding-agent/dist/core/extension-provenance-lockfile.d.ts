import { type DiagnosticEnvelopeV0 } from "./diagnostics.js";
import type { WasmExtensionPackageManifest } from "./wasm-extension-package.js";
export declare const EXTENSION_PROVENANCE_LOCKFILE_NAME = "extensions.lock.json";
export declare const EXTENSION_PROVENANCE_LOCK_SCHEMA_VERSION = "pi-extension-lock.v0";
export type ExtensionProvenanceScope = "user" | "project";
export type ExtensionProvenanceSourceType = "local" | "npm" | "git";
export interface ExtensionProvenanceSourceIdentity {
    type: ExtensionProvenanceSourceType;
    identity: string;
    specifier?: string;
}
export interface ExtensionProvenanceManifestIdentity {
    kind: "typescript-package" | "wasm-extension" | "resource-package";
    packageName?: string;
    packageVersion?: string;
    schemaVersion?: string;
    id?: string;
    name?: string;
    version?: string;
    toolId?: string;
}
export interface ExtensionProvenanceArtifactIdentity {
    kind: "wasm-component";
    path: string;
    absolutePath: string;
    sha256: string;
}
export interface ExtensionProvenanceDigests {
    packageRootSha256: string;
}
export interface ExtensionProvenanceLockEntry {
    key: string;
    scope: ExtensionProvenanceScope;
    source: ExtensionProvenanceSourceIdentity;
    manifest: ExtensionProvenanceManifestIdentity;
    packageRoot: string;
    manifestPath: string;
    artifact?: ExtensionProvenanceArtifactIdentity;
    digests: ExtensionProvenanceDigests;
}
export interface ExtensionProvenanceLockfile {
    schemaVersion: typeof EXTENSION_PROVENANCE_LOCK_SCHEMA_VERSION;
    entries: ExtensionProvenanceLockEntry[];
}
export type ExtensionProvenanceDiagnosticCategory = "missing_lockfile" | "missing_lock_entry" | "malformed_lockfile" | "source_identity_mismatch" | "package_root_mismatch" | "manifest_provenance_mismatch" | "artifact_path_mismatch" | "artifact_digest_mismatch" | "package_root_digest_mismatch" | "policy_digest_mismatch" | "package_validation_failed";
export interface ExtensionProvenanceDiagnostic {
    category: ExtensionProvenanceDiagnosticCategory;
    scope: ExtensionProvenanceScope;
    lockfilePath: string;
    message: string;
    phase: "resolve" | "write";
    recoveryHint: string;
    source?: string;
    path?: string;
    field?: string;
    expected?: string;
    actual?: string;
    packageRoot?: string;
    manifestPath?: string;
    artifactPath?: string;
    envelope?: DiagnosticEnvelopeV0;
}
export interface ExtensionProvenanceLoadResult {
    entries: Map<string, ExtensionProvenanceLockEntry>;
    diagnostic?: ExtensionProvenanceDiagnostic;
}
export declare function getExtensionProvenanceLockfilePath(options: {
    scope: ExtensionProvenanceScope;
    agentDir: string;
    cwd: string;
    configDirName: string;
}): string;
export declare function makeExtensionProvenanceEntryKey(source: ExtensionProvenanceSourceIdentity): string;
export declare function readExtensionProvenanceLockfile(options: {
    scope: ExtensionProvenanceScope;
    lockfilePath: string;
    phase: "resolve" | "write";
}): ExtensionProvenanceLoadResult;
export declare function createMissingLockfileDiagnostic(options: {
    scope: ExtensionProvenanceScope;
    source: string;
    lockfilePath: string;
}): ExtensionProvenanceDiagnostic;
export declare function createMissingLockEntryDiagnostic(options: {
    scope: ExtensionProvenanceScope;
    source: string;
    lockfilePath: string;
}): ExtensionProvenanceDiagnostic;
export declare function serializeExtensionProvenanceLockfile(entries: Iterable<ExtensionProvenanceLockEntry>): string;
export declare function writeExtensionProvenanceLockEntry(options: {
    scope: ExtensionProvenanceScope;
    lockfilePath: string;
    entry: ExtensionProvenanceLockEntry;
}): void;
export declare function removeExtensionProvenanceLockEntry(options: {
    scope: ExtensionProvenanceScope;
    lockfilePath: string;
    key: string;
}): boolean;
export declare function createExtensionProvenanceLockEntry(options: {
    scope: ExtensionProvenanceScope;
    source: ExtensionProvenanceSourceIdentity;
    packageRoot: string;
    manifestPath: string;
    manifest: ExtensionProvenanceManifestIdentity;
    artifact?: ExtensionProvenanceArtifactIdentity;
}): ExtensionProvenanceLockEntry;
export declare function createWasmArtifactIdentity(manifest: WasmExtensionPackageManifest): ExtensionProvenanceArtifactIdentity;
export declare function normalizeEntryForSerialization(entry: ExtensionProvenanceLockEntry): ExtensionProvenanceLockEntry;
export declare function computePackageRootSha256(packageRoot: string): string;
//# sourceMappingURL=extension-provenance-lockfile.d.ts.map