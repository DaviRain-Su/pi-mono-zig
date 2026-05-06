import { createHash } from "node:crypto";
import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { isAbsolute, join, relative, resolve } from "node:path";

export const WASM_EXTENSION_MANIFEST_NAME = "pi-extension.json";
export const WASM_EXTENSION_SCHEMA_VERSION = "pi-extension.v0";
export const WASM_DENIED_CAPABILITY_CATEGORY = "denied_capability";
export const WASM_CANONICAL_CAPABILITIES = [
	"file.read",
	"file.write",
	"network",
	"shell",
	"env",
	"model",
	"session",
	"ui.notify",
] as const;

const CAPABILITIES = new Set<string>(WASM_CANONICAL_CAPABILITIES);
const UNSUPPORTED_SURFACE_FIELDS = [
	"commands",
	"widgets",
	"providers",
	"editorHooks",
	"extensions",
	"shortcuts",
	"themes",
	"prompts",
	"skills",
];

export interface WasmExtensionPackageManifest {
	kind: "wasm-extension";
	packageRoot: string;
	manifestPath: string;
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
}

type JsonObject = Record<string, unknown>;

export function hasWasmExtensionManifest(packageRoot: string): boolean {
	return existsSync(join(packageRoot, WASM_EXTENSION_MANIFEST_NAME));
}

export function validateWasmExtensionPackage(packageRoot: string): WasmExtensionPackageManifest {
	const manifestPath = join(packageRoot, WASM_EXTENSION_MANIFEST_NAME);
	let parsed: unknown;
	try {
		parsed = JSON.parse(readFileSync(manifestPath, "utf-8"));
	} catch (error) {
		if (!existsSync(manifestPath)) {
			throw new Error("discover: pi-extension.json was not found");
		}
		throw new Error(`$: malformed JSON${messageSuffix(error)}`);
	}

	const root = expectObject(parsed, "$");
	const schemaVersion = requiredString(root, "$", "schemaVersion");
	if (schemaVersion !== WASM_EXTENSION_SCHEMA_VERSION) {
		throw new Error(
			`$.schemaVersion: unsupported schema version "${schemaVersion}"; expected ${WASM_EXTENSION_SCHEMA_VERSION}`,
		);
	}

	const id = requiredString(root, "$", "id");
	const name = requiredString(root, "$", "name");
	const version = requiredString(root, "$", "version");
	const description = requiredString(root, "$", "description");

	const artifact = requiredObject(root, "$", "artifact");
	const artifactKind = requiredString(artifact, "$.artifact", "kind");
	if (artifactKind !== "wasm-component") {
		throw new Error(`$.artifact.kind: unsupported artifact kind "${artifactKind}"; expected wasm-component`);
	}
	const artifactPath = requiredString(artifact, "$.artifact", "path");

	if (Object.hasOwn(root, "tools")) {
		throw new Error("$.tools: v0 manifests must declare exactly one tool in $.tool");
	}
	const tool = requiredObject(root, "$", "tool");
	const toolId = requiredString(tool, "$.tool", "id");
	const toolDescription = requiredString(tool, "$.tool", "description");
	requiredObject(tool, "$.tool", "inputSchema");
	requiredObject(tool, "$.tool", "outputSchema");

	for (const field of UNSUPPORTED_SURFACE_FIELDS) {
		if (Object.hasOwn(root, field)) {
			throw new Error(`$.${field}: unsupported v0 surface; only $.tool is supported`);
		}
	}

	const capabilities = readCapabilities(root);
	denyRequestedCapabilities(capabilities);
	const artifactAbsolutePath = validateArtifactPath(packageRoot, artifactPath);
	const artifactSha256 = createHash("sha256").update(readFileSync(artifactAbsolutePath)).digest("hex");

	return {
		kind: "wasm-extension",
		packageRoot: realpathSync(packageRoot),
		manifestPath,
		schemaVersion,
		id,
		name,
		version,
		description,
		artifactKind: "wasm-component",
		artifactPath,
		artifactAbsolutePath,
		artifactSha256,
		toolId,
		toolDescription,
		capabilities,
	};
}

function messageSuffix(error: unknown): string {
	return error instanceof Error && error.message ? `: ${error.message}` : "";
}

function expectObject(value: unknown, path: string): JsonObject {
	if (value === null || typeof value !== "object" || Array.isArray(value)) {
		throw new Error(`${path}: expected object`);
	}
	return value as JsonObject;
}

function requiredValue(object: JsonObject, parentPath: string, field: string): unknown {
	if (!Object.hasOwn(object, field)) {
		throw new Error(`${parentPath}.${field}: missing required field`);
	}
	return object[field];
}

function requiredString(object: JsonObject, parentPath: string, field: string): string {
	const value = requiredValue(object, parentPath, field);
	if (typeof value !== "string") {
		throw new Error(`${parentPath}.${field}: expected string`);
	}
	return value;
}

function requiredObject(object: JsonObject, parentPath: string, field: string): JsonObject {
	return expectObject(requiredValue(object, parentPath, field), `${parentPath}.${field}`);
}

function readCapabilities(root: JsonObject): string[] {
	const value = root.capabilities;
	if (value === undefined) return [];
	if (!Array.isArray(value)) {
		throw new Error("$.capabilities: expected array");
	}

	return value.map((capability, index) => {
		if (typeof capability !== "string") {
			throw new Error(`$.capabilities[${index}]: expected string`);
		}
		if (!CAPABILITIES.has(capability)) {
			throw new Error(`$.capabilities[${index}]: unknown capability "${capability}"`);
		}
		return capability;
	});
}

function denyRequestedCapabilities(capabilities: string[]): void {
	for (const [index, capability] of capabilities.entries()) {
		throw new Error(
			`$.capabilities[${index}]: ${WASM_DENIED_CAPABILITY_CATEGORY}: capability "${capability}" is not approved for manifest-request`,
		);
	}
}

function validateArtifactPath(packageRoot: string, artifactPath: string): string {
	if (artifactPath.length === 0) {
		throw new Error("$.artifact.path: artifact path must not be empty");
	}
	if (isAbsolute(artifactPath)) {
		throw new Error("$.artifact.path: artifact path must be package-relative");
	}
	if (artifactPath.includes("\\")) {
		throw new Error("$.artifact.path: artifact path must use '/' separators");
	}
	if (!artifactPath.endsWith(".wasm")) {
		throw new Error("$.artifact.path: artifact path must point to a .wasm file");
	}
	for (const component of artifactPath.split("/")) {
		if (!component || component === ".") {
			throw new Error("$.artifact.path: artifact path must be normalized");
		}
		if (component === "..") {
			throw new Error("$.artifact.path: artifact path escapes package root");
		}
	}

	let rootReal: string;
	try {
		rootReal = realpathSync(packageRoot);
	} catch {
		throw new Error("$: package root was not found");
	}

	const candidate = resolve(rootReal, artifactPath);
	if (!isWithin(rootReal, candidate)) {
		throw new Error("$.artifact.path: artifact path escapes package root");
	}

	let artifactReal: string;
	try {
		artifactReal = realpathSync(candidate);
	} catch {
		throw new Error("$.artifact.path: artifact file was not found");
	}
	if (!isWithin(rootReal, artifactReal)) {
		throw new Error("$.artifact.path: artifact path resolves outside package root");
	}
	if (!statSync(artifactReal).isFile()) {
		throw new Error("$.artifact.path: artifact path must point to a file");
	}

	const bytes = readFileSync(artifactReal);
	if (bytes.length < 4 || bytes[0] !== 0x00 || bytes[1] !== 0x61 || bytes[2] !== 0x73 || bytes[3] !== 0x6d) {
		throw new Error("$.artifact.path: artifact file is not a valid Wasm binary");
	}

	return artifactReal;
}

function isWithin(root: string, candidate: string): boolean {
	const rel = relative(root, candidate);
	const firstComponent = rel.split(/[\\/]/)[0];
	return rel === "" || (firstComponent !== ".." && !isAbsolute(rel));
}
