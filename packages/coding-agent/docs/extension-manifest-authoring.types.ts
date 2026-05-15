/**
 * TypeScript-facing authoring contract for `pi-extension.json` manifests.
 *
 * These types are documentation and schema-parity inputs for authors and tests.
 * They are not imported by the production TypeScript runtime.
 */

export type PiExtensionJsonScalar = string | number | boolean | null;

export type PiExtensionJsonValue =
	| PiExtensionJsonScalar
	| readonly PiExtensionJsonValue[]
	| { readonly [key: string]: PiExtensionJsonValue };

export type PiExtensionJsonObject = { readonly [key: string]: PiExtensionJsonValue };

export type PiExtensionCanonicalCapability =
	| "file.read"
	| "file.write"
	| "network.request"
	| "shell.run"
	| "env.read"
	| "model.call"
	| "session.read"
	| "session.write"
	| "ui.notify"
	| "tool.use"
	| "agent.spawn"
	| "agent.delegate";

export interface PiExtensionResourceLimits {
	readonly maxChildren?: number;
	readonly depth?: number;
	readonly turns?: number;
	readonly timeoutMs?: number;
	readonly outputBytes?: number;
	readonly outputLines?: number;
	readonly toolScopes?: readonly string[];
}

export type PiExtensionV1RuntimeKind = "typescript" | "javascript" | "process_jsonl" | "future";

export interface PiExtensionV1RuntimeLimits extends PiExtensionResourceLimits {
	readonly timeoutMs?: number;
	readonly outputBytes?: number;
	readonly toolScopes?: readonly string[];
}

export interface PiExtensionV1TypeScriptRuntime {
	readonly kind: "typescript";
	readonly entrypoint: `${string}.ts` | `${string}.js`;
	readonly limits?: PiExtensionV1RuntimeLimits;
}

export interface PiExtensionV1JavaScriptRuntime {
	readonly kind: "javascript";
	readonly entrypoint: `${string}.js`;
	readonly limits?: PiExtensionV1RuntimeLimits;
}

export interface PiExtensionV1ProcessJsonlRuntime {
	readonly kind: "process_jsonl";
	readonly entrypoint: {
		readonly argv: readonly [string, ...string[]];
	};
	readonly limits?: PiExtensionV1RuntimeLimits;
}

export interface PiExtensionV1FutureRuntime {
	readonly kind: "future";
	readonly entrypoint: {
		readonly contract: string;
	};
	readonly limits?: PiExtensionV1RuntimeLimits;
}

export type PiExtensionV1Runtime =
	| PiExtensionV1TypeScriptRuntime
	| PiExtensionV1JavaScriptRuntime
	| PiExtensionV1ProcessJsonlRuntime
	| PiExtensionV1FutureRuntime;

export interface PiExtensionV1Tool {
	readonly name: string;
	readonly label?: string;
	readonly description?: string;
	readonly inputSchema?: PiExtensionJsonObject;
	readonly parameters?: PiExtensionJsonObject;
}

export interface PiExtensionV1CapabilityExport {
	readonly id: string;
	readonly kind?: "tool" | "command" | "resource" | "provider" | "hook" | string;
	readonly version?: string;
	readonly policy?: PiExtensionJsonObject;
}

export interface PiExtensionV1CapabilityImport {
	readonly id: string;
	readonly kind?: "tool" | "command" | "resource" | "provider" | "hook" | string;
	readonly version?: string;
	readonly provider?: string;
}

export interface PiExtensionV1Capabilities {
	readonly exports?: readonly PiExtensionV1CapabilityExport[];
	readonly imports?: readonly PiExtensionV1CapabilityImport[];
}

export interface PiExtensionV1Manifest {
	readonly schemaVersion: "pi-extension.v1";
	readonly id: string;
	readonly name: string;
	readonly version: string;
	readonly description?: string;
	readonly runtime: PiExtensionV1Runtime;
	readonly lifecycle?: PiExtensionJsonObject;
	readonly exposure?: PiExtensionJsonObject;
	readonly tools?: readonly PiExtensionV1Tool[];
	readonly commands?: readonly PiExtensionJsonObject[];
	readonly resources?: readonly PiExtensionJsonObject[];
	readonly providers?: readonly PiExtensionJsonObject[];
	readonly hooks?: readonly PiExtensionJsonObject[];
	readonly capabilities?: PiExtensionV1Capabilities;
	readonly permissions?: readonly PiExtensionJsonObject[];
	readonly dependencies?: readonly PiExtensionJsonObject[];
	readonly workflows?: readonly PiExtensionJsonObject[];
}

export type PiExtensionManifest = PiExtensionV1Manifest;

export interface PiExtensionRuntimeMetadata {
	readonly kind: PiExtensionV1RuntimeKind;
	readonly adapter: string;
	readonly executable: boolean;
}

export interface PiExtensionOwnerMetadata {
	readonly id: string;
	readonly name: string;
	readonly version: string;
	readonly manifestPath: string;
	readonly packageRoot: string;
}

export interface PiExtensionNormalizedDeclarationMetadata {
	readonly owner: PiExtensionOwnerMetadata;
	readonly runtime: PiExtensionRuntimeMetadata;
}

export interface PiExtensionDiagnosticEnvelope {
	readonly code: string;
	readonly severity: "error" | "warning" | "info";
	readonly phase: string;
	readonly path: string;
	readonly message: string;
	readonly packageId?: string;
	readonly runtime?: PiExtensionV1RuntimeKind;
	readonly capabilityId?: string;
}
