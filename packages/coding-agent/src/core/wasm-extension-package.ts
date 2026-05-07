import { createHash } from "node:crypto";
import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { isAbsolute, join, relative, resolve } from "node:path";

export const WASM_EXTENSION_MANIFEST_NAME = "pi-extension.json";
export const WASM_EXTENSION_SCHEMA_VERSION = "pi-extension.v0";
export const WASM_DENIED_CAPABILITY_CATEGORY = "denied_capability";
export const WASM_CANONICAL_SECURITY_GRANTS = [
	"file.read",
	"file.write",
	"network.request",
	"shell.run",
	"env.read",
	"model.call",
	"session.read",
	"session.write",
	"ui.notify",
	"tool.use",
	"agent.spawn",
	"agent.delegate",
] as const;
export const WASM_CANONICAL_CAPABILITIES = WASM_CANONICAL_SECURITY_GRANTS;

const SECURITY_GRANTS = new Set<string>(WASM_CANONICAL_SECURITY_GRANTS);
const RESOURCE_LIMIT_FIELDS = new Set([
	"maxChildren",
	"depth",
	"turns",
	"timeoutMs",
	"outputBytes",
	"outputLines",
	"toolScopes",
]);
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

type JsonObject = Record<string, unknown>;

function toPolicyPath(value: string): string {
	return value.replace(/\\/g, "/");
}

export function hasWasmExtensionManifest(packageRoot: string): boolean {
	return existsSync(join(packageRoot, WASM_EXTENSION_MANIFEST_NAME));
}

export function validateWasmExtensionPackage(
	packageRoot: string,
	options: WasmExtensionPackageValidationOptions = {},
): WasmExtensionPackageManifest {
	const request = readWasmExtensionPackagePolicyRequest(packageRoot);
	const approvedCapabilities = options.resolveApprovedCapabilities?.(request) ?? options.approvedCapabilities ?? [];
	denyRequestedCapabilities(request.capabilities, approvedCapabilities);
	const artifactAbsolutePath = validateArtifactPath(packageRoot, request.artifactPath);
	const artifactSha256 = createHash("sha256").update(readFileSync(artifactAbsolutePath)).digest("hex");

	return {
		kind: "wasm-extension",
		packageRoot: realpathSync(packageRoot),
		manifestPath: request.manifestPath,
		policyLookupKey: createManifestPolicyLookupKey(request),
		schemaVersion: request.schemaVersion,
		id: request.id,
		name: request.name,
		version: request.version,
		description: request.description,
		artifactKind: "wasm-component",
		artifactPath: request.artifactPath,
		artifactAbsolutePath,
		artifactSha256,
		toolId: request.toolId,
		toolDescription: request.toolDescription,
		capabilities: request.capabilities,
		resourceLimits: request.resourceLimits,
	};
}

export function readWasmExtensionPackagePolicyRequest(packageRoot: string): WasmExtensionPackagePolicyRequest {
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
	const resourceLimits = readResourceLimits(root);
	return {
		manifestPath,
		policyLookupKey: createManifestPolicyLookupKey({
			packageRoot,
			manifestPath,
			schemaVersion,
			id,
			version,
			artifactPath,
		}),
		schemaVersion,
		id,
		name,
		version,
		description,
		artifactPath,
		toolId,
		toolDescription,
		capabilities,
		resourceLimits,
		packageRoot,
	};
}

function createManifestPolicyLookupKey(request: {
	schemaVersion: string;
	id: string;
	version: string;
	packageRoot: string;
	manifestPath: string;
	artifactPath: string;
}): string {
	return `wasm:manifest:${request.schemaVersion}:${request.id}:${request.version}:${toPolicyPath(request.packageRoot)}:${toPolicyPath(request.manifestPath)}:${toPolicyPath(request.artifactPath)}`;
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
		if (!SECURITY_GRANTS.has(capability)) {
			throw new Error(`$.capabilities[${index}]: unknown capability "${capability}"`);
		}
		return capability;
	});
}

function readResourceLimits(root: JsonObject): WasmExtensionResourceLimits {
	const value = root.resourceLimits;
	if (value === undefined) return { toolScopes: [] };
	const limits = expectObject(value, "$.resourceLimits");

	for (const field of Object.keys(limits)) {
		if (!RESOURCE_LIMIT_FIELDS.has(field)) {
			throw new Error(`$.resourceLimits.${field}: unsupported resource limit`);
		}
	}

	return {
		maxChildren: optionalResourceLimitInteger(limits, "$.resourceLimits", "maxChildren"),
		depth: optionalResourceLimitInteger(limits, "$.resourceLimits", "depth"),
		turns: optionalResourceLimitInteger(limits, "$.resourceLimits", "turns"),
		timeoutMs: optionalResourceLimitInteger(limits, "$.resourceLimits", "timeoutMs"),
		outputBytes: optionalResourceLimitInteger(limits, "$.resourceLimits", "outputBytes"),
		outputLines: optionalResourceLimitInteger(limits, "$.resourceLimits", "outputLines"),
		toolScopes: readToolScopes(limits),
	};
}

function optionalResourceLimitInteger(object: JsonObject, parentPath: string, field: string): number | undefined {
	const value = object[field];
	if (value === undefined) return undefined;
	if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
		throw new Error(`${parentPath}.${field}: expected non-negative integer`);
	}
	return value;
}

function readToolScopes(limits: JsonObject): string[] {
	const value = limits.toolScopes;
	if (value === undefined) return [];
	if (!Array.isArray(value)) {
		throw new Error("$.resourceLimits.toolScopes: expected array");
	}
	return value.map((scope, index) => {
		if (typeof scope !== "string") {
			throw new Error(`$.resourceLimits.toolScopes[${index}]: expected string`);
		}
		if (scope.length === 0) {
			throw new Error(`$.resourceLimits.toolScopes[${index}]: must not be empty`);
		}
		return scope;
	});
}

function denyRequestedCapabilities(capabilities: string[], approvedCapabilities: readonly string[]): void {
	const approved = new Set(approvedCapabilities);
	for (const [index, capability] of capabilities.entries()) {
		if (approved.has(capability)) {
			continue;
		}
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
