/**
 * Substrate-only sub-agent readiness envelopes.
 *
 * These data contracts intentionally model identity, lineage, task routing,
 * results, and replay-safe metadata only. They do not authorize privileges,
 * spawn child agents, or define user-facing product UX.
 */
const INVOCATION_TYPE = "sub_agent_task_invocation";
const RESULT_TYPE = "sub_agent_task_result";
const CORRELATION_FIELDS = ["agentId", "runId", "taskId", "sessionId"];
const OPTIONAL_ID_FIELDS = [
    "toolCallId",
    "parentAgentId",
    "parentRunId",
    "parentTaskId",
    "parentSessionId",
    "parentId",
];
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
];
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
const CANCELLATION_STATES = new Set(["pending", "requested", "propagated", "completed"]);
const RESULT_STATUSES = new Set(["pending", "running", "completed", "failed", "cancelled"]);
export function validateSubAgentReadinessEnvelope(value) {
    const root = expectObject(value, "$");
    rejectForbiddenProductFields(root, "$");
    const type = expectRequiredString(root, "$", "type");
    if (type === INVOCATION_TYPE)
        return validateSubAgentTaskInvocationEnvelope(root);
    if (type === RESULT_TYPE)
        return validateSubAgentTaskResultEnvelope(root);
    throw new Error(`$.type: unsupported sub-agent readiness envelope "${type}"`);
}
export function validateSubAgentTaskInvocationEnvelope(value) {
    const root = expectObject(value, "$");
    rejectForbiddenProductFields(root, "$");
    expectExactType(root, INVOCATION_TYPE);
    validateCorrelation(root);
    validateOptionalIds(root);
    optionalString(root, "$", "route");
    expectObject(requiredValue(root, "$", "input"), "$.input");
    validateOptionalObject(root, "$", "metadata");
    if (Object.hasOwn(root, "limits"))
        validateResourceLimits(expectObject(root.limits, "$.limits"));
    if (Object.hasOwn(root, "cancellation"))
        validateCancellation(expectObject(root.cancellation, "$.cancellation"));
    return root;
}
export function validateSubAgentTaskResultEnvelope(value) {
    const root = expectObject(value, "$");
    rejectForbiddenProductFields(root, "$");
    expectExactType(root, RESULT_TYPE);
    validateCorrelation(root);
    validateOptionalIds(root);
    validateStatus(root);
    nonNegativeNumber(root, "$", "startedAt", true);
    nonNegativeNumber(root, "$", "completedAt", true);
    validateOptionalObject(root, "$", "details");
    if (Object.hasOwn(root, "error"))
        validateTaskError(expectObject(root.error, "$.error"));
    if (Object.hasOwn(root, "usage"))
        validateNumericSummary(expectObject(root.usage, "$.usage"), "$.usage");
    if (Object.hasOwn(root, "resourceSummary")) {
        validateResourceSummary(expectObject(root.resourceSummary, "$.resourceSummary"));
    }
    return root;
}
function expectExactType(object, expected) {
    const actual = expectRequiredString(object, "$", "type");
    if (actual !== expected)
        throw new Error(`$.type: expected "${expected}"`);
}
function validateCorrelation(object) {
    for (const field of CORRELATION_FIELDS) {
        const value = expectRequiredString(object, "$", field);
        if (value.length === 0)
            throw new Error(`$.${field}: must not be empty`);
    }
}
function validateOptionalIds(object) {
    for (const field of OPTIONAL_ID_FIELDS) {
        const value = optionalString(object, "$", field);
        if (value !== undefined && value.length === 0)
            throw new Error(`$.${field}: must not be empty`);
    }
}
function validateStatus(object) {
    const status = expectRequiredString(object, "$", "status");
    if (!RESULT_STATUSES.has(status)) {
        throw new Error(`$.status: unsupported task status "${status}"`);
    }
}
function validateResourceLimits(object) {
    for (const field of Object.keys(object)) {
        if (!RESOURCE_LIMIT_FIELDS.has(field))
            throw new Error(`$.limits.${field}: unsupported resource limit`);
    }
    for (const field of NUMERIC_RESOURCE_LIMIT_FIELDS) {
        nonNegativeInteger(object, "$.limits", field, false);
    }
    if (!Object.hasOwn(object, "toolScopes"))
        return;
    const scopes = object.toolScopes;
    if (!Array.isArray(scopes))
        throw new Error("$.limits.toolScopes: expected array");
    scopes.forEach((scope, index) => {
        if (typeof scope !== "string")
            throw new Error(`$.limits.toolScopes[${index}]: expected string`);
        if (scope.length === 0)
            throw new Error(`$.limits.toolScopes[${index}]: must not be empty`);
    });
}
function validateResourceSummary(object) {
    for (const field of Object.keys(object)) {
        if (!RESOURCE_SUMMARY_FIELDS.has(field))
            throw new Error(`$.resourceSummary.${field}: unsupported resource summary field`);
    }
    for (const field of ["turns", "outputBytes", "outputLines", "childrenStarted"]) {
        nonNegativeNumber(object, "$.resourceSummary", field, false);
    }
    if (Object.hasOwn(object, "limitDetails"))
        validateLimitDetails(expectObject(object.limitDetails, "$.resourceSummary.limitDetails"));
}
function validateLimitDetails(object) {
    for (const field of Object.keys(object)) {
        if (!RESOURCE_LIMIT_FIELDS.has(field)) {
            throw new Error(`$.resourceSummary.limitDetails.${field}: unsupported resource limit detail`);
        }
    }
    for (const field of NUMERIC_RESOURCE_LIMIT_FIELDS) {
        if (!Object.hasOwn(object, field))
            continue;
        validateLimitDetail(expectObject(object[field], `$.resourceSummary.limitDetails.${field}`), field);
    }
    if (!Object.hasOwn(object, "toolScopes"))
        return;
    const scopes = object.toolScopes;
    if (!Array.isArray(scopes))
        throw new Error("$.resourceSummary.limitDetails.toolScopes: expected array");
    scopes.forEach((scope, index) => {
        if (typeof scope !== "string")
            throw new Error(`$.resourceSummary.limitDetails.toolScopes[${index}]: expected string`);
        if (scope.length === 0)
            throw new Error(`$.resourceSummary.limitDetails.toolScopes[${index}]: must not be empty`);
    });
}
function validateLimitDetail(object, field) {
    const path = `$.resourceSummary.limitDetails.${field}`;
    for (const detailField of Object.keys(object)) {
        if (!RESOURCE_LIMIT_DETAIL_FIELDS.has(detailField))
            throw new Error(`${path}.${detailField}: unsupported limit detail field`);
    }
    nonNegativeNumber(object, path, "limit", true);
    nonNegativeNumber(object, path, "actual", false);
    requiredBoolean(object, path, "truncated");
    const reason = optionalString(object, path, "reason");
    if (reason !== undefined && reason.length === 0)
        throw new Error(`${path}.reason: must not be empty`);
}
function validateCancellation(object) {
    const state = expectRequiredString(object, "$.cancellation", "state");
    if (!CANCELLATION_STATES.has(state)) {
        throw new Error(`$.cancellation.state: unsupported cancellation state "${state}"`);
    }
    for (const field of ["signalId", "reason", "parentRunId", "parentTaskId", "propagatedFrom"]) {
        const value = optionalString(object, "$.cancellation", field);
        if (value !== undefined && value.length === 0)
            throw new Error(`$.cancellation.${field}: must not be empty`);
    }
}
function validateTaskError(object) {
    const reason = expectRequiredString(object, "$.error", "reason");
    if (reason.length === 0)
        throw new Error("$.error.reason: must not be empty");
    optionalString(object, "$.error", "message");
    validateOptionalObject(object, "$.error", "details");
}
function validateNumericSummary(object, path) {
    for (const field of Object.keys(object)) {
        nonNegativeNumber(object, path, field, true);
    }
}
function rejectForbiddenProductFields(object, path) {
    for (const [field, value] of Object.entries(object)) {
        const fieldPath = `${path}.${field}`;
        if (FORBIDDEN_PRODUCT_FIELDS.has(field))
            throw new Error(`${fieldPath}: product UX/spawn policy is not allowed`);
        rejectForbiddenProductFieldsInValue(value, fieldPath);
    }
}
function rejectForbiddenProductFieldsInValue(value, path) {
    if (value === null || typeof value !== "object") {
        return;
    }
    if (Array.isArray(value)) {
        for (const [index, entry] of value.entries()) {
            rejectForbiddenProductFieldsInValue(entry, `${path}[${index}]`);
        }
        return;
    }
    for (const [field, entry] of Object.entries(value)) {
        const fieldPath = `${path}.${field}`;
        if (FORBIDDEN_PRODUCT_FIELDS.has(field))
            throw new Error(`${fieldPath}: product UX/spawn policy is not allowed`);
        rejectForbiddenProductFieldsInValue(entry, fieldPath);
    }
}
function validateOptionalObject(object, parentPath, field) {
    if (!Object.hasOwn(object, field))
        return;
    expectObject(object[field], `${parentPath}.${field}`);
}
function requiredValue(object, parentPath, field) {
    if (!Object.hasOwn(object, field))
        throw new Error(`${parentPath}.${field}: missing required field`);
    return object[field];
}
function expectObject(value, path) {
    if (value === null || typeof value !== "object" || Array.isArray(value))
        throw new Error(`${path}: expected object`);
    return value;
}
function expectRequiredString(object, parentPath, field) {
    const value = requiredValue(object, parentPath, field);
    if (typeof value !== "string")
        throw new Error(`${parentPath}.${field}: expected string`);
    return value;
}
function optionalString(object, parentPath, field) {
    const value = object[field];
    if (value === undefined)
        return undefined;
    if (typeof value !== "string")
        throw new Error(`${parentPath}.${field}: expected string`);
    return value;
}
function requiredBoolean(object, parentPath, field) {
    const value = requiredValue(object, parentPath, field);
    if (typeof value !== "boolean")
        throw new Error(`${parentPath}.${field}: expected boolean`);
    return value;
}
function nonNegativeInteger(object, parentPath, field, required) {
    const value = required ? requiredValue(object, parentPath, field) : object[field];
    if (value === undefined && !required)
        return;
    if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
        throw new Error(`${parentPath}.${field}: expected non-negative integer`);
    }
}
function nonNegativeNumber(object, parentPath, field, required) {
    const value = required ? requiredValue(object, parentPath, field) : object[field];
    if (value === undefined && !required)
        return;
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
        throw new Error(`${parentPath}.${field}: expected non-negative number`);
    }
}
//# sourceMappingURL=subagent-readiness.js.map