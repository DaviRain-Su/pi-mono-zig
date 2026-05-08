/**
 * Substrate-only sub-agent readiness envelopes.
 *
 * These data contracts intentionally model identity, lineage, task routing,
 * results, and replay-safe metadata only. They do not authorize privileges,
 * spawn child agents, or define user-facing product UX.
 */

export type SubAgentTaskStatus = "pending" | "running" | "completed" | "failed" | "cancelled";
export type SubAgentCancellationState = "pending" | "requested" | "propagated" | "completed";

export interface SubAgentCorrelationIds {
	agentId: string;
	runId: string;
	taskId: string;
	sessionId: string;
	toolCallId?: string;
}

export interface SubAgentLineage {
	parentAgentId?: string;
	parentRunId?: string;
	parentTaskId?: string;
	parentSessionId?: string;
	parentId?: string;
}

export interface SubAgentResourceLimits {
	maxChildren?: number;
	depth?: number;
	turns?: number;
	timeoutMs?: number;
	outputBytes?: number;
	outputLines?: number;
	toolScopes?: string[];
}

export type SubAgentNumericResourceLimit =
	| "maxChildren"
	| "depth"
	| "turns"
	| "timeoutMs"
	| "outputBytes"
	| "outputLines";

export interface SubAgentResourceLimitDetail {
	limit: number;
	actual?: number;
	truncated: boolean;
	reason?: string;
}

export type SubAgentResourceLimitDetails = Partial<
	Record<SubAgentNumericResourceLimit, SubAgentResourceLimitDetail>
> & {
	toolScopes?: string[];
};

export interface SubAgentCancellationMetadata {
	signalId?: string;
	state: SubAgentCancellationState;
	reason?: string;
	parentRunId?: string;
	parentTaskId?: string;
	propagatedFrom?: string;
}

export interface SubAgentTaskInvocationEnvelope extends SubAgentCorrelationIds, SubAgentLineage {
	type: "sub_agent_task_invocation";
	route?: string;
	input: Record<string, unknown>;
	limits?: SubAgentResourceLimits;
	cancellation?: SubAgentCancellationMetadata;
	metadata?: Record<string, unknown>;
}

export interface SubAgentTaskError {
	reason: string;
	message?: string;
	details?: Record<string, unknown>;
}

export interface SubAgentUsageSummary {
	inputTokens?: number;
	outputTokens?: number;
	totalTokens?: number;
	toolCalls?: number;
}

export interface SubAgentResourceSummary {
	turns?: number;
	outputBytes?: number;
	outputLines?: number;
	childrenStarted?: number;
	limitDetails?: SubAgentResourceLimitDetails;
}

export interface SubAgentTaskResultEnvelope extends SubAgentCorrelationIds, SubAgentLineage {
	type: "sub_agent_task_result";
	status: SubAgentTaskStatus;
	content?: unknown;
	details?: Record<string, unknown>;
	error?: SubAgentTaskError;
	startedAt: number;
	completedAt: number;
	usage?: SubAgentUsageSummary;
	resourceSummary?: SubAgentResourceSummary;
}

export type SubAgentReadinessEnvelope = SubAgentTaskInvocationEnvelope | SubAgentTaskResultEnvelope;

const INVOCATION_TYPE = "sub_agent_task_invocation";
const RESULT_TYPE = "sub_agent_task_result";
const CORRELATION_FIELDS = ["agentId", "runId", "taskId", "sessionId"] as const;
const OPTIONAL_ID_FIELDS = [
	"toolCallId",
	"parentAgentId",
	"parentRunId",
	"parentTaskId",
	"parentSessionId",
	"parentId",
] as const;
const RESOURCE_LIMIT_FIELDS = new Set([
	"maxChildren",
	"depth",
	"turns",
	"timeoutMs",
	"outputBytes",
	"outputLines",
	"toolScopes",
]);
const NUMERIC_RESOURCE_LIMIT_FIELDS = [
	"maxChildren",
	"depth",
	"turns",
	"timeoutMs",
	"outputBytes",
	"outputLines",
] as const;
const RESOURCE_SUMMARY_FIELDS = new Set(["turns", "outputBytes", "outputLines", "childrenStarted", "limitDetails"]);
const RESOURCE_LIMIT_DETAIL_FIELDS = new Set(["limit", "actual", "truncated", "reason"]);
const FORBIDDEN_PRODUCT_FIELDS = new Set([
	"ui",
	"ux",
	"slashCommand",
	"workflow",
	"workflowPreset",
	"wiki",
	"wikiPreset",
	"qa",
	"qaPreset",
	"review",
	"reviewPreset",
	"spawn",
	"spawnPolicy",
	"automaticSpawn",
	"orchestrationPolicy",
	"remoteUrl",
	"remoteWasmUrl",
	"signature",
	"signing",
	"publisher",
	"marketplace",
	"modelSelectionUi",
	"approvalPolicy",
	"approvalUi",
]);
const CANCELLATION_STATES = new Set<SubAgentCancellationState>(["pending", "requested", "propagated", "completed"]);
const RESULT_STATUSES = new Set<SubAgentTaskStatus>(["pending", "running", "completed", "failed", "cancelled"]);

type JsonObject = Record<string, unknown>;

export function validateSubAgentReadinessEnvelope(value: unknown): SubAgentReadinessEnvelope {
	const root = expectObject(value, "$");
	rejectForbiddenProductFields(root, "$");
	const type = expectRequiredString(root, "$", "type");
	if (type === INVOCATION_TYPE) return validateSubAgentTaskInvocationEnvelope(root);
	if (type === RESULT_TYPE) return validateSubAgentTaskResultEnvelope(root);
	throw new Error(`$.type: unsupported sub-agent readiness envelope "${type}"`);
}

export function validateSubAgentTaskInvocationEnvelope(value: unknown): SubAgentTaskInvocationEnvelope {
	const root = expectObject(value, "$");
	rejectForbiddenProductFields(root, "$");
	expectExactType(root, INVOCATION_TYPE);
	validateCorrelation(root);
	validateOptionalIds(root);
	optionalString(root, "$", "route");
	expectObject(requiredValue(root, "$", "input"), "$.input");
	validateOptionalObject(root, "$", "metadata");
	if (Object.hasOwn(root, "limits")) validateResourceLimits(expectObject(root.limits, "$.limits"));
	if (Object.hasOwn(root, "cancellation")) validateCancellation(expectObject(root.cancellation, "$.cancellation"));
	return root as unknown as SubAgentTaskInvocationEnvelope;
}

export function validateSubAgentTaskResultEnvelope(value: unknown): SubAgentTaskResultEnvelope {
	const root = expectObject(value, "$");
	rejectForbiddenProductFields(root, "$");
	expectExactType(root, RESULT_TYPE);
	validateCorrelation(root);
	validateOptionalIds(root);
	validateStatus(root);
	nonNegativeNumber(root, "$", "startedAt", true);
	nonNegativeNumber(root, "$", "completedAt", true);
	validateOptionalObject(root, "$", "details");
	if (Object.hasOwn(root, "error")) validateTaskError(expectObject(root.error, "$.error"));
	if (Object.hasOwn(root, "usage")) validateNumericSummary(expectObject(root.usage, "$.usage"), "$.usage");
	if (Object.hasOwn(root, "resourceSummary")) {
		validateResourceSummary(expectObject(root.resourceSummary, "$.resourceSummary"));
	}
	return root as unknown as SubAgentTaskResultEnvelope;
}

function expectExactType(object: JsonObject, expected: string): void {
	const actual = expectRequiredString(object, "$", "type");
	if (actual !== expected) throw new Error(`$.type: expected "${expected}"`);
}

function validateCorrelation(object: JsonObject): void {
	for (const field of CORRELATION_FIELDS) {
		const value = expectRequiredString(object, "$", field);
		if (value.length === 0) throw new Error(`$.${field}: must not be empty`);
	}
}

function validateOptionalIds(object: JsonObject): void {
	for (const field of OPTIONAL_ID_FIELDS) {
		const value = optionalString(object, "$", field);
		if (value !== undefined && value.length === 0) throw new Error(`$.${field}: must not be empty`);
	}
}

function validateStatus(object: JsonObject): void {
	const status = expectRequiredString(object, "$", "status");
	if (!RESULT_STATUSES.has(status as SubAgentTaskStatus)) {
		throw new Error(`$.status: unsupported task status "${status}"`);
	}
}

function validateResourceLimits(object: JsonObject): void {
	for (const field of Object.keys(object)) {
		if (!RESOURCE_LIMIT_FIELDS.has(field)) throw new Error(`$.limits.${field}: unsupported resource limit`);
	}
	for (const field of NUMERIC_RESOURCE_LIMIT_FIELDS) {
		nonNegativeInteger(object, "$.limits", field, false);
	}
	if (!Object.hasOwn(object, "toolScopes")) return;
	const scopes = object.toolScopes;
	if (!Array.isArray(scopes)) throw new Error("$.limits.toolScopes: expected array");
	scopes.forEach((scope, index) => {
		if (typeof scope !== "string") throw new Error(`$.limits.toolScopes[${index}]: expected string`);
		if (scope.length === 0) throw new Error(`$.limits.toolScopes[${index}]: must not be empty`);
	});
}

function validateResourceSummary(object: JsonObject): void {
	for (const field of Object.keys(object)) {
		if (!RESOURCE_SUMMARY_FIELDS.has(field))
			throw new Error(`$.resourceSummary.${field}: unsupported resource summary field`);
	}
	for (const field of ["turns", "outputBytes", "outputLines", "childrenStarted"] as const) {
		nonNegativeNumber(object, "$.resourceSummary", field, false);
	}
	if (Object.hasOwn(object, "limitDetails"))
		validateLimitDetails(expectObject(object.limitDetails, "$.resourceSummary.limitDetails"));
}

function validateLimitDetails(object: JsonObject): void {
	for (const field of Object.keys(object)) {
		if (!RESOURCE_LIMIT_FIELDS.has(field)) {
			throw new Error(`$.resourceSummary.limitDetails.${field}: unsupported resource limit detail`);
		}
	}
	for (const field of NUMERIC_RESOURCE_LIMIT_FIELDS) {
		if (!Object.hasOwn(object, field)) continue;
		validateLimitDetail(expectObject(object[field], `$.resourceSummary.limitDetails.${field}`), field);
	}
	if (!Object.hasOwn(object, "toolScopes")) return;
	const scopes = object.toolScopes;
	if (!Array.isArray(scopes)) throw new Error("$.resourceSummary.limitDetails.toolScopes: expected array");
	scopes.forEach((scope, index) => {
		if (typeof scope !== "string")
			throw new Error(`$.resourceSummary.limitDetails.toolScopes[${index}]: expected string`);
		if (scope.length === 0) throw new Error(`$.resourceSummary.limitDetails.toolScopes[${index}]: must not be empty`);
	});
}

function validateLimitDetail(object: JsonObject, field: SubAgentNumericResourceLimit): void {
	const path = `$.resourceSummary.limitDetails.${field}`;
	for (const detailField of Object.keys(object)) {
		if (!RESOURCE_LIMIT_DETAIL_FIELDS.has(detailField))
			throw new Error(`${path}.${detailField}: unsupported limit detail field`);
	}
	nonNegativeNumber(object, path, "limit", true);
	nonNegativeNumber(object, path, "actual", false);
	requiredBoolean(object, path, "truncated");
	const reason = optionalString(object, path, "reason");
	if (reason !== undefined && reason.length === 0) throw new Error(`${path}.reason: must not be empty`);
}

function validateCancellation(object: JsonObject): void {
	const state = expectRequiredString(object, "$.cancellation", "state");
	if (!CANCELLATION_STATES.has(state as SubAgentCancellationState)) {
		throw new Error(`$.cancellation.state: unsupported cancellation state "${state}"`);
	}
	for (const field of ["signalId", "reason", "parentRunId", "parentTaskId", "propagatedFrom"] as const) {
		const value = optionalString(object, "$.cancellation", field);
		if (value !== undefined && value.length === 0) throw new Error(`$.cancellation.${field}: must not be empty`);
	}
}

function validateTaskError(object: JsonObject): void {
	const reason = expectRequiredString(object, "$.error", "reason");
	if (reason.length === 0) throw new Error("$.error.reason: must not be empty");
	optionalString(object, "$.error", "message");
	validateOptionalObject(object, "$.error", "details");
}

function validateNumericSummary(object: JsonObject, path: string): void {
	for (const field of Object.keys(object)) {
		nonNegativeNumber(object, path, field, true);
	}
}

function rejectForbiddenProductFields(object: JsonObject, path: string): void {
	for (const [field, value] of Object.entries(object)) {
		const fieldPath = `${path}.${field}`;
		if (FORBIDDEN_PRODUCT_FIELDS.has(field)) throw new Error(`${fieldPath}: product UX/spawn policy is not allowed`);
		rejectForbiddenProductFieldsInValue(value, fieldPath);
	}
}

function rejectForbiddenProductFieldsInValue(value: unknown, path: string): void {
	if (value === null || typeof value !== "object") {
		return;
	}
	if (Array.isArray(value)) {
		for (const [index, entry] of value.entries()) {
			rejectForbiddenProductFieldsInValue(entry, `${path}[${index}]`);
		}
		return;
	}
	for (const [field, entry] of Object.entries(value as JsonObject)) {
		const fieldPath = `${path}.${field}`;
		if (FORBIDDEN_PRODUCT_FIELDS.has(field)) throw new Error(`${fieldPath}: product UX/spawn policy is not allowed`);
		rejectForbiddenProductFieldsInValue(entry, fieldPath);
	}
}

function validateOptionalObject(object: JsonObject, parentPath: string, field: string): void {
	if (!Object.hasOwn(object, field)) return;
	expectObject(object[field], `${parentPath}.${field}`);
}

function requiredValue(object: JsonObject, parentPath: string, field: string): unknown {
	if (!Object.hasOwn(object, field)) throw new Error(`${parentPath}.${field}: missing required field`);
	return object[field];
}

function expectObject(value: unknown, path: string): JsonObject {
	if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error(`${path}: expected object`);
	return value as JsonObject;
}

function expectRequiredString(object: JsonObject, parentPath: string, field: string): string {
	const value = requiredValue(object, parentPath, field);
	if (typeof value !== "string") throw new Error(`${parentPath}.${field}: expected string`);
	return value;
}

function optionalString(object: JsonObject, parentPath: string, field: string): string | undefined {
	const value = object[field];
	if (value === undefined) return undefined;
	if (typeof value !== "string") throw new Error(`${parentPath}.${field}: expected string`);
	return value;
}

function requiredBoolean(object: JsonObject, parentPath: string, field: string): boolean {
	const value = requiredValue(object, parentPath, field);
	if (typeof value !== "boolean") throw new Error(`${parentPath}.${field}: expected boolean`);
	return value;
}

function nonNegativeInteger(object: JsonObject, parentPath: string, field: string, required: boolean): void {
	const value = required ? requiredValue(object, parentPath, field) : object[field];
	if (value === undefined && !required) return;
	if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
		throw new Error(`${parentPath}.${field}: expected non-negative integer`);
	}
}

function nonNegativeNumber(object: JsonObject, parentPath: string, field: string, required: boolean): void {
	const value = required ? requiredValue(object, parentPath, field) : object[field];
	if (value === undefined && !required) return;
	if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
		throw new Error(`${parentPath}.${field}: expected non-negative number`);
	}
}
