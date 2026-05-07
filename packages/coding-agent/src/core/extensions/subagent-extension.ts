import { type Static, Type } from "typebox";
import type { ExtensionPolicy, ExtensionResourceLimits, TypeScriptExtensionIdentity } from "../extension-policy.js";
import type { CustomEntry } from "../session-manager.js";
import type { SourceInfo } from "../source-info.js";
import {
	type BoundedSubAgentExecutor,
	defaultBoundedSubAgentExecutor,
	executeBoundedSubAgentTask,
} from "./bounded-subagent-execution.js";
import {
	type SubAgentCancellationMetadata,
	type SubAgentResourceLimits,
	type SubAgentTaskInvocationEnvelope,
	type SubAgentTaskResultEnvelope,
	validateSubAgentTaskInvocationEnvelope,
	validateSubAgentTaskResultEnvelope,
} from "./subagent-readiness.js";
import type { AgentToolResult, ExtensionAPI, ExtensionContext, ExtensionFactory } from "./types.js";

export const SUB_AGENT_READINESS_ENTRY = "sub_agent.readiness";
export const SUB_AGENT_DELEGATION_RESULT_ENTRY = "sub_agent.delegation.result";
export const SUB_AGENT_STATUS_MESSAGE = "sub_agent.status";
export const SUB_AGENT_DELEGATION_TOOL = "sub_agent.delegate";
export const SUB_AGENT_DELEGATION_COMMAND = "sub-agent";

export type SubAgentDelegationCapability = "agent.delegate";

export interface SubAgentDelegationHostContext {
	readonly signal: AbortSignal | undefined;
	readonly context: ExtensionContext;
}

export type SubAgentDelegationHost = (
	invocation: SubAgentTaskInvocationEnvelope,
	context: SubAgentDelegationHostContext,
) => Promise<SubAgentTaskResultEnvelope> | SubAgentTaskResultEnvelope;

export interface SubAgentExtensionOptions {
	approvedCapabilities?: readonly SubAgentDelegationCapability[];
	delegate?: SubAgentDelegationHost;
}

const resourceLimitsSchema = Type.Object(
	{
		maxChildren: Type.Optional(Type.Integer({ minimum: 0 })),
		depth: Type.Optional(Type.Integer({ minimum: 0 })),
		turns: Type.Optional(Type.Integer({ minimum: 0 })),
		timeoutMs: Type.Optional(Type.Integer({ minimum: 0 })),
		outputBytes: Type.Optional(Type.Integer({ minimum: 0 })),
		outputLines: Type.Optional(Type.Integer({ minimum: 0 })),
		toolScopes: Type.Optional(Type.Array(Type.String({ minLength: 1 }))),
	},
	{ additionalProperties: false },
);

const cancellationSchema = Type.Object(
	{
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
	},
	{ additionalProperties: false },
);

export const subAgentDelegationInputSchema = Type.Object(
	{
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
	},
	{ additionalProperties: false },
);

export type SubAgentDelegationInput = Static<typeof subAgentDelegationInputSchema>;

export function createSubAgentExtension(options: SubAgentExtensionOptions = {}): ExtensionFactory {
	const fallbackApprovedCapabilities = new Set(options.approvedCapabilities ?? []);

	return (pi: ExtensionAPI): void => {
		const executeDelegation = async (
			params: SubAgentDelegationInput,
			signal: AbortSignal | undefined,
			ctx: ExtensionContext,
		): Promise<SubAgentTaskResultEnvelope> => {
			const policy = pi.getExtensionPolicy();
			const approvedCapabilities = approvedCapabilitiesFor(policy, fallbackApprovedCapabilities);
			const policyDetails = policyDiagnosticDetails(pi.getExtensionIdentity());
			const invocation = buildInvocation(params, signal, policy?.resourceLimits, policyDetails);
			let replayedResult: SubAgentTaskResultEnvelope | undefined;
			const executor: BoundedSubAgentExecutor = async (boundedInvocation, executionContext) => {
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
				admission: () =>
					approvedCapabilities.has("agent.delegate")
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
				pi.sendMessage(
					{
						customType: SUB_AGENT_STATUS_MESSAGE,
						content: result.status,
						details: result,
						display: true,
					},
					{ triggerTurn: false },
				);
			},
		});
	};
}

async function emitReadinessObservation(
	ctx: ExtensionContext,
	envelope: SubAgentTaskInvocationEnvelope | SubAgentTaskResultEnvelope,
	phase: "recorded" | "replayed",
): Promise<void> {
	await ctx.emitSubAgentReadiness?.({
		envelope,
		phase,
		owner: "agent",
		signal: ctx.signal,
	});
}

function parseCommandPayload(args: string): SubAgentDelegationInput {
	const trimmed = args.trim();
	if (trimmed.length === 0) throw new Error("sub-agent command expects a JSON payload");
	return JSON.parse(trimmed) as SubAgentDelegationInput;
}

function buildInvocation(
	params: SubAgentDelegationInput,
	signal: AbortSignal | undefined,
	policyLimits: ExtensionResourceLimits | undefined,
	policyDetails: Record<string, unknown>,
): SubAgentTaskInvocationEnvelope {
	const cancellation = normalizeCancellation(params.cancellation, signal);
	const candidate: Record<string, unknown> = {
		...params,
		type: "sub_agent_task_invocation",
		metadata: {
			...params.metadata,
			policyDiagnostics: policyDetails,
		},
	};
	const limits = narrowResourceLimits(policyLimits, params.limits);
	if (limits !== undefined) candidate.limits = limits;
	if (cancellation !== undefined) candidate.cancellation = cancellation;
	return validateSubAgentTaskInvocationEnvelope(candidate);
}

function approvedCapabilitiesFor(
	policy: ExtensionPolicy | undefined,
	fallbackApprovedCapabilities: ReadonlySet<SubAgentDelegationCapability>,
): ReadonlySet<SubAgentDelegationCapability> {
	if (policy?.approvedGrants !== undefined) {
		return new Set(
			policy.approvedGrants.filter((grant): grant is SubAgentDelegationCapability => grant === "agent.delegate"),
		);
	}
	return fallbackApprovedCapabilities;
}

function narrowResourceLimits(
	policyLimits: ExtensionResourceLimits | undefined,
	requestLimits: SubAgentResourceLimits | undefined,
): SubAgentResourceLimits | undefined {
	if (policyLimits === undefined && requestLimits === undefined) return undefined;
	const limits: SubAgentResourceLimits = {};
	narrowNumericLimit(limits, "maxChildren", policyLimits?.maxChildren, requestLimits?.maxChildren);
	narrowNumericLimit(limits, "depth", policyLimits?.depth, requestLimits?.depth);
	narrowNumericLimit(limits, "turns", policyLimits?.turns, requestLimits?.turns);
	narrowNumericLimit(limits, "timeoutMs", policyLimits?.timeoutMs, requestLimits?.timeoutMs);
	narrowNumericLimit(limits, "outputBytes", policyLimits?.outputBytes, requestLimits?.outputBytes);
	narrowNumericLimit(limits, "outputLines", policyLimits?.outputLines, requestLimits?.outputLines);
	const toolScopes = narrowToolScopes(policyLimits?.toolScopes, requestLimits?.toolScopes);
	if (toolScopes !== undefined) limits.toolScopes = toolScopes;
	return limits;
}

function narrowNumericLimit(
	limits: SubAgentResourceLimits,
	field: Exclude<keyof SubAgentResourceLimits, "toolScopes">,
	policyLimit: number | undefined,
	requestLimit: number | undefined,
): void {
	if (policyLimit === undefined && requestLimit === undefined) return;
	limits[field] =
		policyLimit === undefined
			? requestLimit
			: requestLimit === undefined
				? policyLimit
				: Math.min(policyLimit, requestLimit);
}

function narrowToolScopes(
	policyScopes: readonly string[] | undefined,
	requestScopes: readonly string[] | undefined,
): string[] | undefined {
	if (policyScopes === undefined && requestScopes === undefined) return undefined;
	if (policyScopes === undefined) return [...(requestScopes ?? [])];
	if (requestScopes === undefined) return [...policyScopes];
	const requestSet = new Set(requestScopes);
	return policyScopes.filter((scope) => requestSet.has(scope));
}

function policyDiagnosticDetails(identity: TypeScriptExtensionIdentity): Record<string, unknown> {
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

function sourceDiagnosticDetails(sourceInfo: SourceInfo): Record<string, unknown> {
	return {
		scope: sourceInfo.scope,
		source: sourceInfo.source,
		origin: sourceInfo.origin,
		path: sourceInfo.path,
		baseDir: sourceInfo.baseDir,
	};
}

function normalizeCancellation(
	cancellation: SubAgentCancellationMetadata | undefined,
	signal: AbortSignal | undefined,
): SubAgentCancellationMetadata | undefined {
	if (signal?.aborted === true) {
		return {
			...cancellation,
			state: "requested",
			reason: cancellation?.reason ?? signalCancellationReason(signal),
		};
	}
	return cancellation;
}

function signalCancellationReason(signal: AbortSignal): string {
	const reason = signal.reason as unknown;
	if (typeof reason === "string" && reason.length > 0) return reason;
	if (reason instanceof Error && reason.message.length > 0) return reason.message;
	return "abort signal requested";
}

const defaultDelegate: SubAgentDelegationHost = (invocation, context) => {
	return defaultBoundedSubAgentExecutor(invocation, {
		invocation,
		signal: context.signal ?? new AbortController().signal,
		consumeTurn: () => {},
		runTool: async () => ({ ok: true }),
	});
};

function findRecordedDelegationResult(
	ctx: ExtensionContext,
	invocation: SubAgentTaskInvocationEnvelope,
): SubAgentTaskResultEnvelope | undefined {
	const entries = ctx.sessionManager.getEntries();
	for (let index = entries.length - 1; index >= 0; index--) {
		const entry = entries[index];
		if (entry?.type !== "custom") continue;
		const custom = entry as CustomEntry<unknown>;
		if (custom.customType !== SUB_AGENT_DELEGATION_RESULT_ENTRY) continue;
		try {
			const result = validateSubAgentTaskResultEnvelope(custom.data);
			if (
				result.agentId === invocation.agentId &&
				result.runId === invocation.runId &&
				result.taskId === invocation.taskId &&
				result.sessionId === invocation.sessionId
			) {
				return result;
			}
		} catch {}
	}
	return undefined;
}

function toToolResult(result: SubAgentTaskResultEnvelope): AgentToolResult<SubAgentTaskResultEnvelope> {
	return {
		content: [{ type: "text", text: JSON.stringify(result) }],
		details: result,
	};
}
