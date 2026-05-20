import { Type } from "typebox";
import { defaultBoundedSubAgentExecutor, executeBoundedSubAgentTask, } from "./bounded-subagent-execution.js";
import { validateSubAgentTaskInvocationEnvelope, validateSubAgentTaskResultEnvelope, } from "./subagent-readiness.js";
import { markSubAgentExtensionFactory } from "./subagent-reserved-names.js";
export const SUB_AGENT_READINESS_ENTRY = "sub_agent.readiness";
export const SUB_AGENT_DELEGATION_RESULT_ENTRY = "sub_agent.delegation.result";
export const SUB_AGENT_STATUS_MESSAGE = "sub_agent.status";
export const SUB_AGENT_DELEGATION_TOOL = "sub_agent.delegate";
export const SUB_AGENT_DELEGATION_COMMAND = "sub-agent";
const resourceLimitsSchema = Type.Object({
    maxChildren: Type.Optional(Type.Integer({ minimum: 0 })),
    depth: Type.Optional(Type.Integer({ minimum: 0 })),
    turns: Type.Optional(Type.Integer({ minimum: 0 })),
    timeoutMs: Type.Optional(Type.Integer({ minimum: 0 })),
    outputBytes: Type.Optional(Type.Integer({ minimum: 0 })),
    outputLines: Type.Optional(Type.Integer({ minimum: 0 })),
    toolScopes: Type.Optional(Type.Array(Type.String({ minLength: 1 }))),
}, { additionalProperties: false });
const cancellationSchema = Type.Object({
    signalId: Type.Optional(Type.String({ minLength: 1 })),
    state: Type.Union([
        Type.Literal("pending"),
        Type.Literal("requested"),
        Type.Literal("propagated"),
        Type.Literal("completed"),
    ]),
    reason: Type.Optional(Type.String({ minLength: 1 })),
    parentRunId: Type.Optional(Type.String({ minLength: 1 })),
    parentTaskId: Type.Optional(Type.String({ minLength: 1 })),
    propagatedFrom: Type.Optional(Type.String({ minLength: 1 })),
}, { additionalProperties: false });
export const subAgentDelegationInputSchema = Type.Object({
    agentId: Type.String({ minLength: 1 }),
    runId: Type.String({ minLength: 1 }),
    taskId: Type.String({ minLength: 1 }),
    sessionId: Type.String({ minLength: 1 }),
    toolCallId: Type.Optional(Type.String({ minLength: 1 })),
    parentAgentId: Type.Optional(Type.String({ minLength: 1 })),
    parentRunId: Type.Optional(Type.String({ minLength: 1 })),
    parentTaskId: Type.Optional(Type.String({ minLength: 1 })),
    parentSessionId: Type.Optional(Type.String({ minLength: 1 })),
    parentId: Type.Optional(Type.String({ minLength: 1 })),
    route: Type.Optional(Type.String()),
    input: Type.Record(Type.String(), Type.Unknown()),
    limits: Type.Optional(resourceLimitsSchema),
    cancellation: Type.Optional(cancellationSchema),
    metadata: Type.Optional(Type.Record(Type.String(), Type.Unknown())),
}, { additionalProperties: false });
export function createSubAgentExtension(options = {}) {
    const fallbackApprovedCapabilities = new Set(options.approvedCapabilities ?? []);
    const factory = (pi) => {
        const executeDelegation = async (params, signal, ctx) => {
            const policy = pi.getExtensionPolicy();
            const approvedCapabilities = approvedCapabilitiesFor(policy, fallbackApprovedCapabilities);
            const policyDetails = policyDiagnosticDetails(pi.getExtensionIdentity());
            const invocation = buildInvocation(params, signal, policy?.resourceLimits, policyDetails);
            let replayedResult;
            const executor = async (boundedInvocation, executionContext) => {
                const delegate = options.delegate ?? defaultDelegate;
                return delegate(boundedInvocation, { signal: executionContext.signal, context: ctx });
            };
            const result = await executeBoundedSubAgentTask(invocation, {
                signal,
                executor,
                store: {
                    findResult: (candidate) => {
                        replayedResult = findRecordedDelegationResult(ctx, candidate);
                        return replayedResult;
                    },
                    appendInvocation: async (candidate) => {
                        pi.appendEntry(SUB_AGENT_READINESS_ENTRY, candidate);
                        await emitReadinessObservation(ctx, candidate, "recorded");
                    },
                    appendResult: async (candidate) => {
                        pi.appendEntry(SUB_AGENT_DELEGATION_RESULT_ENTRY, candidate);
                        await emitReadinessObservation(ctx, candidate, "recorded");
                    },
                },
                admission: () => approvedCapabilities.has("agent.delegate")
                    ? undefined
                    : {
                        reason: "denied_capability",
                        message: "grant is not approved",
                        details: {
                            category: "denied_capability",
                            capability: "agent.delegate",
                            operation: "agent.delegate",
                            branch: "agent.delegate",
                            phase: "call",
                            mode: "typescript/sub-agent-admission",
                            reason: "grant is not approved",
                            ...policyDetails,
                        },
                    },
            });
            if (replayedResult !== undefined) {
                await emitReadinessObservation(ctx, replayedResult, "replayed");
            }
            return result;
        };
        pi.registerTool({
            name: SUB_AGENT_DELEGATION_TOOL,
            label: "Sub-agent Delegate",
            description: "Delegate a substrate-only task through the generic child-agent delegation substrate.",
            parameters: subAgentDelegationInputSchema,
            execute: async (_toolCallId, params, signal, _onUpdate, ctx) => {
                const result = await executeDelegation(params, signal, ctx);
                return toToolResult(result);
            },
        });
        pi.registerCommand(SUB_AGENT_DELEGATION_COMMAND, {
            description: "Delegate a neutral sub-agent task from a JSON payload.",
            handler: async (args, ctx) => {
                const parsed = parseCommandPayload(args);
                const result = await executeDelegation(parsed, ctx.signal, ctx);
                pi.sendMessage({
                    customType: SUB_AGENT_STATUS_MESSAGE,
                    content: result.status,
                    details: result,
                    display: true,
                }, { triggerTurn: false });
            },
        });
    };
    return markSubAgentExtensionFactory(factory);
}
async function emitReadinessObservation(ctx, envelope, phase) {
    await ctx.emitSubAgentReadiness?.({
        envelope,
        phase,
        owner: "agent",
        signal: ctx.signal,
    });
}
function parseCommandPayload(args) {
    const trimmed = args.trim();
    if (trimmed.length === 0)
        throw new Error("sub-agent command expects a JSON payload");
    return JSON.parse(trimmed);
}
function buildInvocation(params, signal, policyLimits, policyDetails) {
    const cancellation = normalizeCancellation(params.cancellation, signal);
    const candidate = {
        ...params,
        type: "sub_agent_task_invocation",
        metadata: {
            ...params.metadata,
            policyDiagnostics: policyDetails,
        },
    };
    const limits = narrowResourceLimits(policyLimits, params.limits);
    if (limits !== undefined)
        candidate.limits = limits;
    if (cancellation !== undefined)
        candidate.cancellation = cancellation;
    return validateSubAgentTaskInvocationEnvelope(candidate);
}
function approvedCapabilitiesFor(policy, fallbackApprovedCapabilities) {
    if (policy?.approvedGrants !== undefined) {
        return new Set(policy.approvedGrants.filter((grant) => grant === "agent.delegate"));
    }
    return fallbackApprovedCapabilities;
}
function narrowResourceLimits(policyLimits, requestLimits) {
    if (policyLimits === undefined && requestLimits === undefined)
        return undefined;
    const limits = {};
    narrowNumericLimit(limits, "maxChildren", policyLimits?.maxChildren, requestLimits?.maxChildren);
    narrowNumericLimit(limits, "depth", policyLimits?.depth, requestLimits?.depth);
    narrowNumericLimit(limits, "turns", policyLimits?.turns, requestLimits?.turns);
    narrowNumericLimit(limits, "timeoutMs", policyLimits?.timeoutMs, requestLimits?.timeoutMs);
    narrowNumericLimit(limits, "outputBytes", policyLimits?.outputBytes, requestLimits?.outputBytes);
    narrowNumericLimit(limits, "outputLines", policyLimits?.outputLines, requestLimits?.outputLines);
    const toolScopes = narrowToolScopes(policyLimits?.toolScopes, requestLimits?.toolScopes);
    if (toolScopes !== undefined)
        limits.toolScopes = toolScopes;
    return limits;
}
function narrowNumericLimit(limits, field, policyLimit, requestLimit) {
    if (policyLimit === undefined && requestLimit === undefined)
        return;
    limits[field] =
        policyLimit === undefined
            ? requestLimit
            : requestLimit === undefined
                ? policyLimit
                : Math.min(policyLimit, requestLimit);
}
function narrowToolScopes(policyScopes, requestScopes) {
    if (policyScopes === undefined && requestScopes === undefined)
        return undefined;
    if (policyScopes === undefined)
        return [...(requestScopes ?? [])];
    if (requestScopes === undefined)
        return [...policyScopes];
    const requestSet = new Set(requestScopes);
    return policyScopes.filter((scope) => requestSet.has(scope));
}
function policyDiagnosticDetails(identity) {
    return {
        extensionIdentity: identity.key,
        extensionKind: identity.kind,
        extensionDisplayName: identity.displayName,
        runtimeKind: identity.runtimeKind,
        principal: {
            runtimeKind: identity.runtimeKind,
            extensionId: identity.key,
            extensionKind: identity.kind,
            displayName: identity.displayName,
        },
        target: { id: SUB_AGENT_DELEGATION_TOOL },
        source: sourceDiagnosticDetails(identity.sourceInfo),
    };
}
function sourceDiagnosticDetails(sourceInfo) {
    return {
        scope: sourceInfo.scope,
        source: sourceInfo.source,
        origin: sourceInfo.origin,
        path: sourceInfo.path,
        baseDir: sourceInfo.baseDir,
    };
}
function normalizeCancellation(cancellation, signal) {
    if (signal?.aborted === true) {
        return {
            ...cancellation,
            state: "requested",
            reason: cancellation?.reason ?? signalCancellationReason(signal),
        };
    }
    return cancellation;
}
function signalCancellationReason(signal) {
    const reason = signal.reason;
    if (typeof reason === "string" && reason.length > 0)
        return reason;
    if (reason instanceof Error && reason.message.length > 0)
        return reason.message;
    return "abort signal requested";
}
const defaultDelegate = (invocation, context) => {
    return defaultBoundedSubAgentExecutor(invocation, {
        invocation,
        signal: context.signal ?? new AbortController().signal,
        consumeTurn: () => { },
        runTool: async () => ({ ok: true }),
    });
};
function findRecordedDelegationResult(ctx, invocation) {
    const entries = ctx.sessionManager.getEntries();
    for (let index = entries.length - 1; index >= 0; index--) {
        const entry = entries[index];
        if (entry?.type !== "custom")
            continue;
        const custom = entry;
        if (custom.customType !== SUB_AGENT_DELEGATION_RESULT_ENTRY)
            continue;
        try {
            const result = validateSubAgentTaskResultEnvelope(custom.data);
            if (result.agentId === invocation.agentId &&
                result.runId === invocation.runId &&
                result.taskId === invocation.taskId &&
                result.sessionId === invocation.sessionId) {
                return result;
            }
        }
        catch { }
    }
    return undefined;
}
function toToolResult(result) {
    return {
        content: [{ type: "text", text: JSON.stringify(result) }],
        details: result,
    };
}
//# sourceMappingURL=subagent-extension.js.map