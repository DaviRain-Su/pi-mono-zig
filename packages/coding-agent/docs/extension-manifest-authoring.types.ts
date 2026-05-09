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

export interface PiExtensionV0Tool {
	readonly id: string;
	readonly description: string;
	readonly inputSchema: PiExtensionJsonObject;
	readonly outputSchema: PiExtensionJsonObject;
}

export interface PiExtensionV0WasmManifest {
	readonly schemaVersion: "pi-extension.v0";
	readonly id: string;
	readonly name: string;
	readonly version: string;
	readonly description: string;
	readonly artifact: {
		readonly kind: "wasm-component";
		readonly path: `${string}.wasm`;
	};
	readonly tool: PiExtensionV0Tool;
	readonly capabilities?: readonly PiExtensionCanonicalCapability[];
	readonly resourceLimits?: PiExtensionResourceLimits;
	readonly tools?: never;
	readonly workflow?: never;
	readonly workflowPreset?: never;
	readonly wiki?: never;
	readonly qa?: never;
	readonly review?: never;
	readonly webSimulator?: never;
	readonly marketplace?: never;
	readonly signing?: never;
	readonly publisher?: never;
	readonly remoteUrl?: never;
	readonly remoteWasmUrl?: never;
	readonly slashCommand?: never;
	readonly slashCommands?: never;
}

export type PiExtensionV1RuntimeKind = "typescript" | "javascript" | "process_jsonl" | "wasm" | "native" | "future";

export interface PiExtensionV1RuntimeLimits extends PiExtensionResourceLimits {
	readonly timeoutMs?: number;
	readonly outputBytes?: number;
	readonly toolScopes?: readonly string[];
}

export interface PiExtensionV1WasmRuntime {
	readonly kind: "wasm";
	readonly entrypoint: {
		readonly artifactPath: `${string}.wasm`;
	};
	readonly limits?: PiExtensionV1RuntimeLimits;
}

export interface PiExtensionV1NativeRuntime {
	readonly kind: "native";
	readonly entrypoint: {
		readonly descriptor: string;
		readonly library_path?: never;
		readonly dynamic_library_path?: never;
		readonly remote_url?: never;
	};
	readonly limits?: PiExtensionV1RuntimeLimits;
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
	| PiExtensionV1WasmRuntime
	| PiExtensionV1NativeRuntime
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

export interface PiExtensionV1BaseManifest {
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

export interface PiExtensionV1NativeManifest extends PiExtensionV1BaseManifest {
	readonly runtime: PiExtensionV1NativeRuntime;
}

export interface PiExtensionV1WasmManifest extends PiExtensionV1BaseManifest {
	readonly runtime: PiExtensionV1WasmRuntime;
}

export type PiExtensionV1Manifest = PiExtensionV1BaseManifest;

export type PiExtensionManifest = PiExtensionV0WasmManifest | PiExtensionV1Manifest;

export type PiNativeAbiVersion = "pi_native_extension_abi_v0";

export interface PiExtensionRuntimeMetadata {
	readonly kind: PiExtensionV1RuntimeKind;
	readonly adapter: string;
	readonly executable: boolean;
	readonly abi?: {
		readonly name: PiNativeAbiVersion;
		readonly minimum?: 0;
		readonly maximum?: 0;
	};
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

export interface PiExtensionDigestBoundPolicyPrincipal {
	readonly scope: "user" | "project";
	readonly sourceIdentity: string;
	readonly packageId: string;
	readonly packageVersion: string;
	readonly runtimeKind: "wasm" | "native";
	readonly packageRootSha256: string;
	readonly selectedArtifactSha256: string;
	readonly selectedArtifactPath?: string;
	readonly selectedArtifactOs?: string;
	readonly selectedArtifactArch?: string;
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
