import { describe, expect, it } from "vitest";
import type {
	PiExtensionDigestBoundPolicyPrincipal,
	PiExtensionManifest,
	PiExtensionNormalizedDeclarationMetadata,
	PiExtensionV0WasmManifest,
	PiExtensionV1NativeManifest,
	PiExtensionV1WasmManifest,
} from "../docs/extension-manifest-authoring.types.js";

const wasmV0Manifest = {
	schemaVersion: "pi-extension.v0",
	id: "com.pi.template.echo",
	name: "Pi Template Echo",
	version: "0.1.0",
	description: "Echoes a message through the public Zig WASM SDK boundary.",
	artifact: {
		kind: "wasm-component",
		path: "wasm/plugin.wasm",
	},
	tool: {
		id: "template.echo",
		description: "Echo a string message.",
		inputSchema: {
			type: "object",
			required: ["message"],
			properties: {
				message: {
					type: "string",
				},
			},
		},
		outputSchema: {
			type: "object",
			required: ["message"],
			properties: {
				message: {
					type: "string",
				},
			},
		},
	},
	capabilities: [],
	resourceLimits: {
		timeoutMs: 30000,
		outputBytes: 1048576,
		toolScopes: [],
	},
} satisfies PiExtensionV0WasmManifest;

const wasmV1Manifest = {
	schemaVersion: "pi-extension.v1",
	id: "com.pi.wasm.authoring",
	name: "WASM Authoring Example",
	version: "0.1.0",
	runtime: {
		kind: "wasm",
		entrypoint: {
			artifactPath: "wasm/plugin.wasm",
		},
		limits: {
			timeoutMs: 30000,
			outputBytes: 1048576,
			toolScopes: [],
		},
	},
	tools: [
		{
			name: "wasm.echo",
			description: "Echo a message.",
			inputSchema: {
				type: "object",
			},
		},
	],
} satisfies PiExtensionV1WasmManifest;

const nativeManifest = {
	schemaVersion: "pi-extension.v1",
	id: "com.pi.native.authoring",
	name: "Native Authoring Example",
	version: "0.1.0",
	description: "Documents the TypeScript-facing native manifest shape accepted by Zig validators.",
	runtime: {
		kind: "native",
		entrypoint: {
			descriptor: "native://static/example",
		},
		limits: {
			timeoutMs: 30000,
			outputBytes: 1048576,
			toolScopes: ["native.echo"],
		},
	},
	tools: [
		{
			name: "native.echo",
			description: "Echo a string through the native runtime boundary.",
			inputSchema: {
				type: "object",
				required: ["message"],
				properties: {
					message: {
						type: "string",
					},
				},
			},
		},
	],
	capabilities: {
		exports: [
			{
				id: "native.echo",
				kind: "tool",
				version: "0.1.0",
			},
		],
		imports: [],
	},
	permissions: [],
	dependencies: [],
} satisfies PiExtensionV1NativeManifest;

const manifests = [wasmV0Manifest, wasmV1Manifest, nativeManifest] satisfies readonly PiExtensionManifest[];

const normalizedNativeToolMetadata = {
	owner: {
		id: "com.pi.native.authoring",
		name: "Native Authoring Example",
		version: "0.1.0",
		manifestPath: "/tmp/native/pi-extension.json",
		packageRoot: "/tmp/native",
	},
	runtime: {
		kind: "native",
		adapter: "zig-native-static-host",
		executable: true,
		abi: {
			name: "pi_native_extension_abi_v0",
			minimum: 0,
			maximum: 0,
		},
	},
} satisfies PiExtensionNormalizedDeclarationMetadata;

const nativePolicyPrincipal = {
	scope: "project",
	sourceIdentity: "/tmp/native",
	packageId: "com.pi.native.authoring",
	packageVersion: "0.1.0",
	runtimeKind: "native",
	packageRootSha256: "0".repeat(64),
	selectedArtifactSha256: "1".repeat(64),
	selectedArtifactPath: "zig-out/lib/libnative.dylib",
	selectedArtifactOs: "macos",
	selectedArtifactArch: "aarch64",
} satisfies PiExtensionDigestBoundPolicyPrincipal;

const unsupportedNativeEntrypoint = {
	schemaVersion: "pi-extension.v1",
	id: "com.pi.native.invalid",
	name: "Invalid Native",
	version: "0.1.0",
	runtime: {
		kind: "native",
		entrypoint: {
			descriptor: "native://static/example",
			// @ts-expect-error native authoring must not document direct dynamic library path entrypoints.
			library_path: "libnative.dylib",
		},
	},
} satisfies PiExtensionV1NativeManifest;

const unsupportedWasmV0Shape = {
	schemaVersion: "pi-extension.v0",
	id: "com.pi.wasm.invalid",
	name: "Invalid WASM",
	version: "0.1.0",
	description: "Invalid shape.",
	artifact: {
		// @ts-expect-error WASM v0 authoring only documents wasm-component artifacts.
		kind: "native-dynamic",
		path: "wasm/plugin.wasm",
	},
	tool: {
		id: "invalid.echo",
		description: "Invalid.",
		inputSchema: {},
		outputSchema: {},
	},
} satisfies PiExtensionV0WasmManifest;

describe("extension manifest authoring types", () => {
	it("keeps docs fixtures aligned with wasm and native authoring shapes", () => {
		expect(manifests.map((manifest) => manifest.schemaVersion)).toEqual([
			"pi-extension.v0",
			"pi-extension.v1",
			"pi-extension.v1",
		]);
		expect(wasmV0Manifest.artifact.kind).toBe("wasm-component");
		expect(wasmV1Manifest.runtime.kind).toBe("wasm");
		expect(nativeManifest.runtime.kind).toBe("native");
		expect(normalizedNativeToolMetadata.runtime.adapter).toBe("zig-native-static-host");
		expect(nativePolicyPrincipal.runtimeKind).toBe("native");
		expect(nativePolicyPrincipal.selectedArtifactSha256).toHaveLength(64);
		expect(unsupportedNativeEntrypoint.runtime.entrypoint.descriptor).toBe("native://static/example");
		expect(unsupportedWasmV0Shape.tool.id).toBe("invalid.echo");
	});
});
