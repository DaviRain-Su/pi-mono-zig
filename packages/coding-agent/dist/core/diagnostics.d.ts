export declare const DIAGNOSTIC_ENVELOPE_SCHEMA_VERSION = "diagnostic-envelope.v0";
export declare const DIAGNOSTIC_REDACTED_VALUE = "[REDACTED]";
export type DiagnosticSeverity = "info" | "warning" | "error";
export type DiagnosticPhase = "load" | "event" | "call" | "resolve" | "write" | "unload" | "initialize" | "runtime" | "schema";
export type DiagnosticRuntimeKind = "typescript" | "process_jsonl" | "wasm" | "native" | "remote" | "unknown";
export interface DiagnosticSourceV0 {
    path?: string;
    resourcePath?: string;
    baseDir?: string;
    scope?: string;
    origin?: string;
    source?: string;
    runtimeKind?: DiagnosticRuntimeKind;
    packageRoot?: string;
    descriptorId?: string;
}
export interface DiagnosticEnvelopeV0 {
    schemaVersion: typeof DIAGNOSTIC_ENVELOPE_SCHEMA_VERSION;
    severity: DiagnosticSeverity;
    phase: DiagnosticPhase;
    runtimeKind: DiagnosticRuntimeKind;
    category: string;
    message: string;
    recoveryHint: string;
    source?: DiagnosticSourceV0;
    extensionIdentity?: string;
    event?: string;
    capability?: string;
    operation?: string;
    target?: unknown;
    path?: string;
    expected?: unknown;
    actual?: unknown;
    details?: unknown;
}
export interface DiagnosticEnvelopeInput {
    severity: DiagnosticSeverity;
    phase: DiagnosticPhase;
    runtimeKind: DiagnosticRuntimeKind;
    category: string;
    message: string;
    recoveryHint?: string;
    source?: DiagnosticSourceV0;
    extensionIdentity?: string;
    event?: string;
    capability?: string;
    operation?: string;
    target?: unknown;
    path?: string;
    expected?: unknown;
    actual?: unknown;
    details?: unknown;
}
export interface ResourceCollision {
    resourceType: "extension" | "skill" | "prompt" | "theme";
    name: string;
    winnerPath: string;
    loserPath: string;
    winnerSource?: string;
    loserSource?: string;
}
export interface ResourceDiagnostic {
    type: "warning" | "error" | "collision";
    message: string;
    path?: string;
    collision?: ResourceCollision;
    envelope?: DiagnosticEnvelopeV0;
}
export interface ExtensionDiagnosticInput {
    extensionPath: string;
    event: string;
    error: string;
    stack?: string;
    phase?: string;
    runtimeKind?: string;
    category?: string;
    capability?: string;
    operation?: string;
    target?: unknown;
    principal?: unknown;
    extensionIdentity?: string;
    envelope?: DiagnosticEnvelopeV0;
}
export interface ProvenanceDiagnosticInput {
    category: string;
    scope?: string;
    lockfilePath?: string;
    message: string;
    phase?: string;
    recoveryHint?: string;
    source?: string;
    path?: string;
    field?: string;
    expected?: unknown;
    actual?: unknown;
    packageRoot?: string;
    manifestPath?: string;
    artifactPath?: string;
    envelope?: DiagnosticEnvelopeV0;
}
export declare function redactDiagnosticValue(value: unknown, key?: string): unknown;
export declare function createDiagnosticEnvelope(input: DiagnosticEnvelopeInput): DiagnosticEnvelopeV0;
export declare function attachDiagnosticEnvelope<T extends object>(target: T, envelope: DiagnosticEnvelopeV0): T;
export declare function adaptResourceDiagnosticToEnvelope(diagnostic: ResourceDiagnostic, defaults?: Partial<Pick<DiagnosticEnvelopeInput, "phase" | "runtimeKind" | "extensionIdentity" | "source">>): DiagnosticEnvelopeV0;
export declare function attachResourceDiagnosticEnvelope(diagnostic: ResourceDiagnostic, defaults?: Partial<Pick<DiagnosticEnvelopeInput, "phase" | "runtimeKind" | "extensionIdentity" | "source">>): ResourceDiagnostic;
export declare function adaptExtensionErrorToDiagnosticEnvelope(error: ExtensionDiagnosticInput): DiagnosticEnvelopeV0;
export declare function sanitizeExtensionError<T extends ExtensionDiagnosticInput>(error: T): T & {
    envelope: DiagnosticEnvelopeV0;
};
export declare function adaptProvenanceDiagnosticToEnvelope(diagnostic: ProvenanceDiagnosticInput, runtimeKind?: DiagnosticRuntimeKind): DiagnosticEnvelopeV0;
//# sourceMappingURL=diagnostics.d.ts.map