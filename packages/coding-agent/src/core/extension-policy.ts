import { relative, resolve, sep } from "node:path";
import type { SourceInfo } from "./source-info.js";
import {
	WASM_CANONICAL_SECURITY_GRANTS,
	type WasmExtensionPackageManifest,
	type WasmExtensionResourceLimits,
} from "./wasm-extension-package.js";

export const CANONICAL_EXTENSION_GRANTS = WASM_CANONICAL_SECURITY_GRANTS;

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

export type CanonicalExtensionIdentity =
	| TypeScriptExtensionIdentity
	| WasmExtensionIdentity
	| NativeExtensionIdentity
	| ProcessJsonlExtensionIdentity;

const GRANTS = new Set<string>(CANONICAL_EXTENSION_GRANTS);
const RESOURCE_LIMIT_FIELDS = new Set([
	"maxChildren",
	"depth",
	"turns",
	"timeoutMs",
	"outputBytes",
	"outputLines",
	"toolScopes",
]);
const POLICY_FIELDS = new Set(["approvedGrants", "resourceLimits"]);

function toPolicyPath(value: string): string {
	return value.split(sep).join("/");
}

function relativePolicyPath(baseDir: string | undefined, filePath: string): string | undefined {
	if (!baseDir) return undefined;
	const rel = relative(baseDir, filePath);
	if (!rel || rel.startsWith("..") || rel === filePath) return undefined;
	return toPolicyPath(rel);
}

export function isCanonicalExtensionGrant(value: string): value is CanonicalExtensionGrant {
	return GRANTS.has(value);
}

export function createTypeScriptExtensionIdentity(options: {
	configuredPath: string;
	resolvedPath: string;
	sourceInfo: SourceInfo;
}): TypeScriptExtensionIdentity {
	const configuredPath = toPolicyPath(options.configuredPath);
	const resolvedPath = toPolicyPath(options.resolvedPath);
	const sourceInfo = {
		...options.sourceInfo,
		path: toPolicyPath(options.sourceInfo.path),
		baseDir: options.sourceInfo.baseDir ? toPolicyPath(options.sourceInfo.baseDir) : undefined,
	};

	if (configuredPath.startsWith("<") && configuredPath.endsWith(">")) {
		const source = sourceInfo.source || "temporary";
		return {
			kind: "typescript-inline",
			runtimeKind: "typescript",
			key: `typescript:inline:${source}:${configuredPath}`,
			displayName: configuredPath,
			configuredPath,
			resolvedPath,
			sourceInfo,
		};
	}

	if (sourceInfo.origin === "package") {
		const entryPath = relativePolicyPath(sourceInfo.baseDir, resolvedPath) ?? resolvedPath;
		return {
			kind: "typescript-package",
			runtimeKind: "typescript",
			key: `typescript:package:${sourceInfo.scope}:${sourceInfo.source}:${entryPath}:${resolvedPath}`,
			displayName: entryPath,
			configuredPath,
			resolvedPath,
			sourceInfo,
			baseDir: sourceInfo.baseDir,
			packageSource: sourceInfo.source,
			entryPath,
		};
	}

	return {
		kind: "typescript-local",
		runtimeKind: "typescript",
		key: `typescript:local:${sourceInfo.scope}:${resolvedPath}`,
		displayName: resolvedPath,
		configuredPath,
		resolvedPath,
		sourceInfo,
		baseDir: sourceInfo.baseDir,
	};
}

export function createWasmExtensionIdentity(
	manifest: WasmExtensionPackageManifest,
	sourceInfo: SourceInfo,
): WasmExtensionIdentity {
	const manifestPath = toPolicyPath(manifest.manifestPath);
	const packageRoot = toPolicyPath(manifest.packageRoot);
	const artifactAbsolutePath = toPolicyPath(manifest.artifactAbsolutePath);
	return {
		kind: "wasm-manifest",
		runtimeKind: "wasm",
		key: `wasm:${manifest.schemaVersion}:${manifest.id}:${manifest.version}:${manifest.artifactSha256}:${manifestPath}:${artifactAbsolutePath}`,
		displayName: manifest.id,
		schemaVersion: manifest.schemaVersion,
		manifestId: manifest.id,
		name: manifest.name,
		version: manifest.version,
		manifestPath,
		packageRoot,
		artifactPath: toPolicyPath(manifest.artifactPath),
		artifactAbsolutePath,
		artifactSha256: manifest.artifactSha256,
		toolId: manifest.toolId,
		sourceInfo: {
			...sourceInfo,
			path: toPolicyPath(sourceInfo.path),
			baseDir: sourceInfo.baseDir ? toPolicyPath(sourceInfo.baseDir) : undefined,
		},
	};
}

export function createNativeExtensionIdentity(options: {
	id: string;
	name: string;
	version: string;
	description: string;
	extensionPath?: string;
}): NativeExtensionIdentity {
	return {
		kind: "native-descriptor",
		runtimeKind: "native",
		key: `native:${options.id}:${options.version}:${options.name}`,
		displayName: options.id,
		descriptorId: options.id,
		name: options.name,
		version: options.version,
		description: options.description,
		extensionPath: options.extensionPath ? toPolicyPath(options.extensionPath) : undefined,
	};
}

export function createProcessJsonlExtensionIdentity(options: {
	argv: readonly string[];
	extensionPath?: string;
	cwd?: string;
}): ProcessJsonlExtensionIdentity {
	const commandPath = toPolicyPath(options.argv[0] ?? "");
	const argv = options.argv.map(toPolicyPath);
	const extensionPath = options.extensionPath ? toPolicyPath(options.extensionPath) : undefined;
	const cwd = options.cwd ? toPolicyPath(resolve(options.cwd)) : undefined;
	return {
		kind: "process-jsonl",
		runtimeKind: "process_jsonl",
		key: `process_jsonl:${JSON.stringify({ argv, extensionPath, cwd })}`,
		displayName: extensionPath ?? commandPath,
		commandPath,
		argv,
		extensionPath,
		cwd,
	};
}

export function validateExtensionPolicyShape(value: unknown, path = "$"): ExtensionPolicy {
	if (value === null || typeof value !== "object" || Array.isArray(value)) {
		throw new Error(`${path}: expected object`);
	}
	const object = value as Record<string, unknown>;
	for (const key of Object.keys(object)) {
		if (!POLICY_FIELDS.has(key)) {
			throw new Error(`${path}.${key}: unsupported policy field`);
		}
	}
	const policy: ExtensionPolicy = {};

	if (Object.hasOwn(object, "approvedGrants")) {
		const approvedGrants = object.approvedGrants;
		if (!Array.isArray(approvedGrants)) {
			throw new Error(`${path}.approvedGrants: expected array`);
		}
		policy.approvedGrants = approvedGrants.map((grant, index) => {
			if (typeof grant !== "string") {
				throw new Error(`${path}.approvedGrants[${index}]: expected string`);
			}
			if (!isCanonicalExtensionGrant(grant)) {
				throw new Error(`${path}.approvedGrants[${index}]: unknown grant "${grant}"`);
			}
			return grant;
		});
	}

	if (Object.hasOwn(object, "resourceLimits")) {
		policy.resourceLimits = validateResourceLimits(object.resourceLimits, `${path}.resourceLimits`);
	}

	return policy;
}

export function validateExtensionPolicyMap(value: unknown, path = "$"): ExtensionPolicyMapValidationResult {
	if (value === null || typeof value !== "object" || Array.isArray(value)) {
		throw new Error(`${path}: expected object`);
	}

	const policies: ExtensionPolicyMap = {};
	const errors: Error[] = [];
	for (const [identity, policyValue] of Object.entries(value as Record<string, unknown>)) {
		const policyPath = `${path}[${JSON.stringify(identity)}]`;
		if (identity.length === 0) {
			errors.push(new Error(`${policyPath}: extension identity must not be empty`));
			continue;
		}
		try {
			policies[identity] = validateExtensionPolicyShape(policyValue, policyPath);
		} catch (error) {
			errors.push(error instanceof Error ? error : new Error(String(error)));
		}
	}

	return { policies, errors };
}

export function mergeExtensionPolicy(base: ExtensionPolicy | undefined, override: ExtensionPolicy): ExtensionPolicy {
	const merged: ExtensionPolicy = {};
	if (base?.approvedGrants !== undefined) {
		merged.approvedGrants = [...base.approvedGrants];
	}
	if (base?.resourceLimits !== undefined) {
		merged.resourceLimits = { ...base.resourceLimits };
		if (base.resourceLimits.toolScopes !== undefined) {
			merged.resourceLimits.toolScopes = [...base.resourceLimits.toolScopes];
		}
	}

	if (override.approvedGrants !== undefined) {
		merged.approvedGrants = [...override.approvedGrants];
	}
	if (override.resourceLimits !== undefined) {
		merged.resourceLimits = {
			...(merged.resourceLimits ?? {}),
			...override.resourceLimits,
			toolScopes:
				override.resourceLimits.toolScopes !== undefined
					? [...override.resourceLimits.toolScopes]
					: merged.resourceLimits?.toolScopes,
		};
	}

	return merged;
}

export function mergeExtensionPolicyMaps(
	base: ExtensionPolicyMap | undefined,
	overrides: ExtensionPolicyMap | undefined,
): ExtensionPolicyMap | undefined {
	if (!base && !overrides) {
		return undefined;
	}

	const merged: ExtensionPolicyMap = {};
	for (const [identity, policy] of Object.entries(base ?? {})) {
		merged[identity] = mergeExtensionPolicy(undefined, policy);
	}
	for (const [identity, policy] of Object.entries(overrides ?? {})) {
		merged[identity] = mergeExtensionPolicy(merged[identity], policy);
	}
	return merged;
}

function validateResourceLimits(value: unknown, path: string): ExtensionResourceLimits {
	if (value === null || typeof value !== "object" || Array.isArray(value)) {
		throw new Error(`${path}: expected object`);
	}
	const object = value as Record<string, unknown>;
	for (const key of Object.keys(object)) {
		if (!RESOURCE_LIMIT_FIELDS.has(key)) {
			throw new Error(`${path}.${key}: unsupported resource limit`);
		}
	}
	const limits: ExtensionResourceLimits = {};
	setResourceLimitInteger(limits, object, path, "maxChildren");
	setResourceLimitInteger(limits, object, path, "depth");
	setResourceLimitInteger(limits, object, path, "turns");
	setResourceLimitInteger(limits, object, path, "timeoutMs");
	setResourceLimitInteger(limits, object, path, "outputBytes");
	setResourceLimitInteger(limits, object, path, "outputLines");
	const toolScopes = optionalToolScopes(object, path);
	if (toolScopes !== undefined) {
		limits.toolScopes = toolScopes;
	}
	return limits;
}

function setResourceLimitInteger(
	limits: ExtensionResourceLimits,
	object: Record<string, unknown>,
	path: string,
	field: keyof Omit<ExtensionResourceLimits, "toolScopes">,
): void {
	const value = optionalResourceLimitInteger(object, path, field);
	if (value !== undefined) {
		limits[field] = value;
	}
}

function optionalResourceLimitInteger(
	object: Record<string, unknown>,
	path: string,
	field: string,
): number | undefined {
	const value = object[field];
	if (value === undefined) return undefined;
	if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
		throw new Error(`${path}.${field}: expected non-negative integer`);
	}
	return value;
}

function optionalToolScopes(object: Record<string, unknown>, path: string): readonly string[] | undefined {
	const value = object.toolScopes;
	if (value === undefined) return undefined;
	if (!Array.isArray(value)) {
		throw new Error(`${path}.toolScopes: expected array`);
	}
	return value.map((scope, index) => {
		if (typeof scope !== "string") {
			throw new Error(`${path}.toolScopes[${index}]: expected string`);
		}
		if (scope.length === 0) {
			throw new Error(`${path}.toolScopes[${index}]: must not be empty`);
		}
		return scope;
	});
}

export function normalizeWasmResourceLimits(limits: WasmExtensionResourceLimits): ExtensionResourceLimits {
	return {
		maxChildren: limits.maxChildren,
		depth: limits.depth,
		turns: limits.turns,
		timeoutMs: limits.timeoutMs,
		outputBytes: limits.outputBytes,
		outputLines: limits.outputLines,
		toolScopes: limits.toolScopes,
	};
}
