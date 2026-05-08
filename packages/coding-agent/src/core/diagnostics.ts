export const DIAGNOSTIC_ENVELOPE_SCHEMA_VERSION = "diagnostic-envelope.v0";
export const DIAGNOSTIC_REDACTED_VALUE = "[REDACTED]";

export type DiagnosticSeverity = "info" | "warning" | "error";
export type DiagnosticPhase =
	| "load"
	| "event"
	| "call"
	| "resolve"
	| "write"
	| "unload"
	| "initialize"
	| "runtime"
	| "schema";
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
	name: string; // skill name, command/tool/flag name, prompt name, theme name
	winnerPath: string;
	loserPath: string;
	winnerSource?: string; // e.g., "npm:foo", "git:...", "local"
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

const SENSITIVE_KEY_PATTERN =
	/(^|[-_])(authorization|api[-_]?key|apikey|access[-_]?token|refresh[-_]?token|id[-_]?token|token|oauth|password|passwd|secret|credential|cookie|set[-_]?cookie|x[-_]?api[-_]?key|provider[-_]?token)($|[-_])/i;
const SENSITIVE_QUERY_KEYS = new Set([
	"access_token",
	"api_key",
	"apikey",
	"auth",
	"authorization",
	"code",
	"credential",
	"key",
	"oauth_token",
	"password",
	"refresh_token",
	"secret",
	"signature",
	"token",
]);
const SECRET_VALUE_PATTERNS = [
	/\bBearer\s+[A-Za-z0-9._~+/=-]+/gi,
	/\bBasic\s+[A-Za-z0-9+/=-]+/gi,
	/\bsk-[A-Za-z0-9_-]{8,}\b/g,
	/\bgithub_pat_[A-Za-z0-9_]{8,}\b/g,
	/\bgh[opsu]_[A-Za-z0-9_]{8,}\b/g,
	/\bxox[baprs]-[A-Za-z0-9-]{8,}\b/g,
	/\bAIza[0-9A-Za-z_-]{8,}\b/g,
];
const SECRET_ASSIGNMENT_PATTERN =
	/((?:^|\s|["'])[-A-Za-z0-9_]*(?:API[-_]?KEY|TOKEN|OAUTH|PASSWORD|PASSWD|SECRET|CREDENTIAL|AUTHORIZATION)[-A-Za-z0-9_]*\s*=\s*)(?:"[^"]*"|'[^']*'|[^\s"'&]+)/gi;
const SECRET_CLI_FLAG_PATTERN =
	/(--[-A-Za-z0-9_]*(?:api[-_]?key|token|oauth|password|passwd|secret|credential|authorization)[-A-Za-z0-9_]*(?:=|\s+))(?:"[^"]*"|'[^']*'|[^\s"']+)/gi;

function isPlainRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isSensitiveKey(key: string): boolean {
	return SENSITIVE_KEY_PATTERN.test(key);
}

function normalizePhase(value: string | undefined, fallback: DiagnosticPhase): DiagnosticPhase {
	if (
		value === "load" ||
		value === "event" ||
		value === "call" ||
		value === "resolve" ||
		value === "write" ||
		value === "unload" ||
		value === "initialize" ||
		value === "runtime" ||
		value === "schema"
	) {
		return value;
	}
	return fallback;
}

function normalizeRuntimeKind(value: string | undefined, fallback: DiagnosticRuntimeKind): DiagnosticRuntimeKind {
	if (
		value === "typescript" ||
		value === "process_jsonl" ||
		value === "wasm" ||
		value === "native" ||
		value === "remote" ||
		value === "unknown"
	) {
		return value;
	}
	return fallback;
}

function stableObject<T extends Record<string, unknown>>(value: T): T {
	const result: Record<string, unknown> = {};
	for (const key of Object.keys(value).sort()) {
		const entry = value[key];
		if (entry !== undefined) {
			result[key] = entry;
		}
	}
	return result as T;
}

function redactUrl(value: string): string {
	return value.replace(/https?:\/\/[^\s"'<>]+/gi, (candidate) => {
		try {
			const url = new URL(candidate);
			if (url.username) url.username = DIAGNOSTIC_REDACTED_VALUE;
			if (url.password) url.password = DIAGNOSTIC_REDACTED_VALUE;
			for (const key of [...url.searchParams.keys()]) {
				if (SENSITIVE_QUERY_KEYS.has(key.toLowerCase()) || isSensitiveKey(key)) {
					url.searchParams.set(key, DIAGNOSTIC_REDACTED_VALUE);
				}
			}
			return url.toString().replace(/%5BREDACTED%5D/gi, DIAGNOSTIC_REDACTED_VALUE);
		} catch {
			return candidate;
		}
	});
}

function redactString(value: string): string {
	let redacted = redactUrl(value);
	redacted = redacted.replace(/(Authorization\s*[:=]\s*)(?:Bearer\s+)?[^\s,;]+/gi, `$1${DIAGNOSTIC_REDACTED_VALUE}`);
	redacted = redacted.replace(SECRET_ASSIGNMENT_PATTERN, `$1${DIAGNOSTIC_REDACTED_VALUE}`);
	redacted = redacted.replace(SECRET_CLI_FLAG_PATTERN, `$1${DIAGNOSTIC_REDACTED_VALUE}`);
	for (const pattern of SECRET_VALUE_PATTERNS) {
		redacted = redacted.replace(pattern, (match) => {
			if (/^Bearer\s+/i.test(match)) return `Bearer ${DIAGNOSTIC_REDACTED_VALUE}`;
			if (/^Basic\s+/i.test(match)) return `Basic ${DIAGNOSTIC_REDACTED_VALUE}`;
			return DIAGNOSTIC_REDACTED_VALUE;
		});
	}
	return redacted;
}

export function redactDiagnosticValue(value: unknown, key?: string): unknown {
	if (key && isSensitiveKey(key)) {
		return DIAGNOSTIC_REDACTED_VALUE;
	}
	if (typeof value === "string") {
		return redactString(value);
	}
	if (Array.isArray(value)) {
		return value.map((entry) => redactDiagnosticValue(entry));
	}
	if (isPlainRecord(value)) {
		const result: Record<string, unknown> = {};
		for (const childKey of Object.keys(value).sort()) {
			result[childKey] = redactDiagnosticValue(value[childKey], childKey);
		}
		return result;
	}
	return value;
}

function redactSource(source: DiagnosticSourceV0 | undefined): DiagnosticSourceV0 | undefined {
	if (!source) return undefined;
	const redacted = redactDiagnosticValue(source);
	return isPlainRecord(redacted) ? (redacted as DiagnosticSourceV0) : undefined;
}

export function createDiagnosticEnvelope(input: DiagnosticEnvelopeInput): DiagnosticEnvelopeV0 {
	const envelope: DiagnosticEnvelopeV0 = {
		schemaVersion: DIAGNOSTIC_ENVELOPE_SCHEMA_VERSION,
		severity: input.severity,
		phase: input.phase,
		runtimeKind: input.runtimeKind,
		category: input.category,
		message: redactString(input.message),
		recoveryHint: redactString(input.recoveryHint ?? "Review the extension configuration and retry."),
	};
	const source = redactSource(input.source);
	if (source) envelope.source = stableObject(source as Record<string, unknown>) as DiagnosticSourceV0;
	if (input.extensionIdentity !== undefined) envelope.extensionIdentity = redactString(input.extensionIdentity);
	if (input.event !== undefined) envelope.event = redactString(input.event);
	if (input.capability !== undefined) envelope.capability = redactString(input.capability);
	if (input.operation !== undefined) envelope.operation = redactString(input.operation);
	if (input.target !== undefined) envelope.target = redactDiagnosticValue(input.target, "target");
	if (input.path !== undefined) envelope.path = redactString(input.path);
	if (input.expected !== undefined) envelope.expected = redactDiagnosticValue(input.expected, "expected");
	if (input.actual !== undefined) envelope.actual = redactDiagnosticValue(input.actual, "actual");
	if (input.details !== undefined) envelope.details = redactDiagnosticValue(input.details, "details");
	return envelope;
}

export function attachDiagnosticEnvelope<T extends object>(target: T, envelope: DiagnosticEnvelopeV0): T {
	Object.defineProperty(target, "envelope", {
		value: envelope,
		enumerable: false,
		configurable: true,
		writable: false,
	});
	return target;
}

export function adaptResourceDiagnosticToEnvelope(
	diagnostic: ResourceDiagnostic,
	defaults: Partial<Pick<DiagnosticEnvelopeInput, "phase" | "runtimeKind" | "extensionIdentity" | "source">> = {},
): DiagnosticEnvelopeV0 {
	if (diagnostic.envelope) return diagnostic.envelope;
	const category = diagnostic.type === "collision" ? "resource_collision" : "resource_diagnostic";
	const recoveryHint =
		diagnostic.type === "collision"
			? "Rename or remove one of the colliding resources."
			: "Review the resource path and extension configuration.";
	return createDiagnosticEnvelope({
		severity: diagnostic.type === "error" ? "error" : "warning",
		phase: defaults.phase ?? "load",
		runtimeKind: defaults.runtimeKind ?? "typescript",
		category,
		message: diagnostic.message,
		recoveryHint,
		source: defaults.source ?? (diagnostic.path ? { path: diagnostic.path } : undefined),
		extensionIdentity: defaults.extensionIdentity,
		path: diagnostic.path,
		details: diagnostic.collision ? { collision: diagnostic.collision } : undefined,
	});
}

export function attachResourceDiagnosticEnvelope(
	diagnostic: ResourceDiagnostic,
	defaults: Partial<Pick<DiagnosticEnvelopeInput, "phase" | "runtimeKind" | "extensionIdentity" | "source">> = {},
): ResourceDiagnostic {
	if (diagnostic.envelope) return diagnostic;
	return attachDiagnosticEnvelope(diagnostic, adaptResourceDiagnosticToEnvelope(diagnostic, defaults));
}

export function adaptExtensionErrorToDiagnosticEnvelope(error: ExtensionDiagnosticInput): DiagnosticEnvelopeV0 {
	if (error.envelope) return error.envelope;
	return createDiagnosticEnvelope({
		severity: "error",
		phase: normalizePhase(error.phase, "event"),
		runtimeKind: normalizeRuntimeKind(error.runtimeKind, "typescript"),
		category: error.category ?? "extension_runtime_error",
		message: error.error,
		recoveryHint: "Disable or fix the extension that emitted this diagnostic, then reload extensions.",
		source: { path: error.extensionPath },
		extensionIdentity: error.extensionIdentity,
		event: error.event,
		capability: error.capability,
		operation: error.operation,
		target: error.target,
		details: {
			principal: error.principal,
			stack: error.stack,
		},
	});
}

export function sanitizeExtensionError<T extends ExtensionDiagnosticInput>(
	error: T,
): T & { envelope: DiagnosticEnvelopeV0 } {
	const envelope = adaptExtensionErrorToDiagnosticEnvelope(error);
	const sanitized = {
		...error,
		error: envelope.message,
		stack: typeof error.stack === "string" ? redactString(error.stack) : undefined,
		target: error.target === undefined ? undefined : redactDiagnosticValue(error.target, "target"),
		principal: error.principal === undefined ? undefined : redactDiagnosticValue(error.principal, "principal"),
	} as T & { envelope: DiagnosticEnvelopeV0 };
	return attachDiagnosticEnvelope(sanitized, envelope) as T & { envelope: DiagnosticEnvelopeV0 };
}

export function adaptProvenanceDiagnosticToEnvelope(
	diagnostic: ProvenanceDiagnosticInput,
	runtimeKind: DiagnosticRuntimeKind = "typescript",
): DiagnosticEnvelopeV0 {
	if (diagnostic.envelope) return diagnostic.envelope;
	return createDiagnosticEnvelope({
		severity: "warning",
		phase: normalizePhase(diagnostic.phase, "resolve"),
		runtimeKind,
		category: diagnostic.category,
		message: diagnostic.message,
		recoveryHint:
			diagnostic.recoveryHint ?? "Run install or update for the package to refresh trusted extension provenance.",
		source: {
			path: diagnostic.lockfilePath,
			scope: diagnostic.scope,
			source: diagnostic.source,
			packageRoot: diagnostic.packageRoot,
		},
		path: diagnostic.path ?? diagnostic.field,
		expected: diagnostic.expected,
		actual: diagnostic.actual,
		details: {
			artifactPath: diagnostic.artifactPath,
			lockfilePath: diagnostic.lockfilePath,
			manifestPath: diagnostic.manifestPath,
			packageRoot: diagnostic.packageRoot,
			scope: diagnostic.scope,
			source: diagnostic.source,
		},
	});
}
