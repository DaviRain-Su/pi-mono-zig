import { describe, expect, it } from "vitest";
import type {
	PiExtensionManifest,
	PiExtensionNormalizedDeclarationMetadata,
	PiExtensionV1Manifest,
} from "../docs/extension-manifest-authoring.types.ts";

const typescriptManifest = {
	schemaVersion: "pi-extension.v1",
	id: "com.pi.typescript.authoring",
	name: "TypeScript Authoring Example",
	version: "0.1.0",
	description: "Documents the TypeScript manifest shape accepted by Zig validators.",
	runtime: {
		kind: "typescript",
		entrypoint: "src/index.ts",
		limits: {
			timeoutMs: 30000,
			outputBytes: 1048576,
			toolScopes: ["typescript.echo"],
		},
	},
	tools: [
		{
			name: "typescript.echo",
			description: "Echo a string through a TypeScript extension.",
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
				id: "typescript.echo",
				kind: "tool",
				version: "0.1.0",
			},
		],
		imports: [],
	},
	permissions: [],
	dependencies: [],
} satisfies PiExtensionV1Manifest;

const javascriptManifest = {
	schemaVersion: "pi-extension.v1",
	id: "com.pi.javascript.authoring",
	name: "JavaScript Authoring Example",
	version: "0.1.0",
	runtime: {
		kind: "javascript",
		entrypoint: "dist/index.js",
	},
} satisfies PiExtensionV1Manifest;

const processJsonlManifest = {
	schemaVersion: "pi-extension.v1",
	id: "com.pi.process.authoring",
	name: "Process JSONL Authoring Example",
	version: "0.1.0",
	runtime: {
		kind: "process_jsonl",
		entrypoint: {
			argv: ["node", "host.ts"],
		},
	},
} satisfies PiExtensionV1Manifest;

const manifests = [
	typescriptManifest,
	javascriptManifest,
	processJsonlManifest,
] satisfies readonly PiExtensionManifest[];

const normalizedTypeScriptToolMetadata = {
	owner: {
		id: "com.pi.typescript.authoring",
		name: "TypeScript Authoring Example",
		version: "0.1.0",
		manifestPath: "/tmp/typescript/pi-extension.json",
		packageRoot: "/tmp/typescript",
	},
	runtime: {
		kind: "typescript",
		adapter: "ts-js-extension-loader",
		executable: true,
	},
} satisfies PiExtensionNormalizedDeclarationMetadata;

const unsupportedWasmRuntime = {
	schemaVersion: "pi-extension.v1",
	id: "com.pi.wasm.invalid",
	name: "Invalid WASM",
	version: "0.1.0",
	runtime: {
		// @ts-expect-error Zig manifest authoring no longer supports WASM runtimes.
		kind: "wasm",
		entrypoint: {
			// @ts-expect-error Zig manifest authoring no longer supports WASM artifact entrypoints.
			artifactPath: "wasm/plugin.wasm",
		},
	},
} satisfies PiExtensionV1Manifest;

const unsupportedNativeRuntime = {
	schemaVersion: "pi-extension.v1",
	id: "com.pi.native.invalid",
	name: "Invalid Native",
	version: "0.1.0",
	runtime: {
		// @ts-expect-error Zig manifest authoring no longer supports native runtimes.
		kind: "native",
		entrypoint: {
			// @ts-expect-error Zig manifest authoring no longer supports native descriptors.
			descriptor: "native://static/example",
		},
	},
} satisfies PiExtensionV1Manifest;

describe("extension manifest authoring types", () => {
	it("keeps docs fixtures aligned with supported TypeScript and process authoring shapes", () => {
		expect(manifests.map((manifest) => manifest.runtime.kind)).toEqual(["typescript", "javascript", "process_jsonl"]);
		expect(typescriptManifest.runtime.entrypoint).toBe("src/index.ts");
		expect(javascriptManifest.runtime.entrypoint).toBe("dist/index.js");
		expect(processJsonlManifest.runtime.entrypoint.argv).toEqual(["node", "host.ts"]);
		expect(normalizedTypeScriptToolMetadata.runtime.adapter).toBe("ts-js-extension-loader");
		expect(unsupportedWasmRuntime.runtime.entrypoint.artifactPath).toBe("wasm/plugin.wasm");
		expect(unsupportedNativeRuntime.runtime.entrypoint.descriptor).toBe("native://static/example");
	});
});
