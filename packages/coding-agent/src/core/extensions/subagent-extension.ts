import { type Static, Type } from "typebox";
import type { CustomEntry } from "../session-manager.js";
import {
	type SubAgentCancellationMetadata,
	type SubAgentResourceLimits,
	type SubAgentResourceSummary,
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
	const approvedCapabilities = new Set(options.approvedCapabilities ?? []);

	return (pi: ExtensionAPI): void => {
		const executeDelegation = async (
			params: SubAgentDelegationInput,
			signal: AbortSignal | undefined,
			ctx: ExtensionContext,
		): Promise<SubAgentTaskResultEnvelope> => {
			const invocation = buildInvocation(params, signal);
			const replayed = findRecordedDelegationResult(ctx, invocation);
			if (replayed) return replayed;

			if (invocation.cancellation?.state === "requested" || signal?.aborted === true) {
				const propagatedInvocation = propagateCancellation(invocation, signal);
				pi.appendEntry(SUB_AGENT_READINESS_ENTRY, propagatedInvocation);
				const result = buildCancelledResult(propagatedInvocation);
				pi.appendEntry(SUB_AGENT_DELEGATION_RESULT_ENTRY, result);
				return result;
			}

			pi.appendEntry(SUB_AGENT_READINESS_ENTRY, invocation);

			const denialReason = delegationDenialReason(approvedCapabilities, invocation.limits);
			if (denialReason) {
				const result = buildDeniedResult(invocation, denialReason);
				pi.appendEntry(SUB_AGENT_DELEGATION_RESULT_ENTRY, result);
				return result;
			}

			const delegated = await (options.delegate ?? defaultDelegate)(invocation, { signal, context: ctx });
			const result = validateSubAgentTaskResultEnvelope(delegated);
			pi.appendEntry(SUB_AGENT_DELEGATION_RESULT_ENTRY, result);
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

function parseCommandPayload(args: string): SubAgentDelegationInput {
	const trimmed = args.trim();
	if (trimmed.length === 0) throw new Error("sub-agent command expects a JSON payload");
	return JSON.parse(trimmed) as SubAgentDelegationInput;
}

function buildInvocation(
	params: SubAgentDelegationInput,
	signal: AbortSignal | undefined,
): SubAgentTaskInvocationEnvelope {
	const cancellation = normalizeCancellation(params.cancellation, signal);
	const candidate: Record<string, unknown> = {
		...params,
		type: "sub_agent_task_invocation",
	};
	if (cancellation !== undefined) candidate.cancellation = cancellation;
	return validateSubAgentTaskInvocationEnvelope(candidate);
}

function normalizeCancellation(
	cancellation: SubAgentCancellationMetadata | undefined,
	signal: AbortSignal | undefined,
): SubAgentCancellationMetadata | undefined {
	if (signal?.aborted === true) {
		return {
			...cancellation,
			state: "requested",
			reason: cancellation?.reason ?? "abort signal requested",
		};
	}
	return cancellation;
}

function propagateCancellation(
	invocation: SubAgentTaskInvocationEnvelope,
	signal: AbortSignal | undefined,
): SubAgentTaskInvocationEnvelope {
	return validateSubAgentTaskInvocationEnvelope({
		...invocation,
		cancellation: {
			...invocation.cancellation,
			state: "propagated",
			reason: invocation.cancellation?.reason ?? (signal?.aborted === true ? "abort signal requested" : "cancelled"),
			propagatedFrom: invocation.cancellation?.propagatedFrom ?? invocation.parentRunId ?? invocation.runId,
		},
	});
}

function delegationDenialReason(
	approvedCapabilities: ReadonlySet<SubAgentDelegationCapability>,
	limits: SubAgentResourceLimits | undefined,
): string | undefined {
	if (!approvedCapabilities.has("agent.delegate")) return "grant is not approved";
	if (limits?.maxChildren !== undefined && limits.maxChildren < 1) return "resource limit exceeded: maxChildren";
	if (limits?.depth !== undefined && limits.depth < 1) return "resource limit exceeded: depth";
	if (limits?.turns !== undefined && limits.turns < 1) return "resource limit exceeded: turns";
	if (limits?.timeoutMs !== undefined && limits.timeoutMs < 1) return "resource limit exceeded: timeoutMs";
	return undefined;
}

function buildDeniedResult(invocation: SubAgentTaskInvocationEnvelope, reason: string): SubAgentTaskResultEnvelope {
	return validateSubAgentTaskResultEnvelope({
		...correlationFromInvocation(invocation),
		type: "sub_agent_task_result",
		status: "failed",
		startedAt: Date.now(),
		completedAt: Date.now(),
		error: {
			reason: reason === "grant is not approved" ? "denied_capability" : "resource_limit_exceeded",
			message: reason,
			details: {
				capability: "agent.delegate",
				operation: "agent.delegate",
			},
		},
		details: {
			capability: "agent.delegate",
			operation: "agent.delegate",
			replayed: false,
		},
		resourceSummary: zeroResourceSummary(invocation.limits),
	});
}

function buildCancelledResult(invocation: SubAgentTaskInvocationEnvelope): SubAgentTaskResultEnvelope {
	return validateSubAgentTaskResultEnvelope({
		...correlationFromInvocation(invocation),
		type: "sub_agent_task_result",
		status: "cancelled",
		startedAt: Date.now(),
		completedAt: Date.now(),
		error: {
			reason: "cancelled",
			message: invocation.cancellation?.reason ?? "delegation cancelled",
			details: { cancellation: invocation.cancellation },
		},
		details: {
			capability: "agent.delegate",
			operation: "agent.delegate",
			cancellation: invocation.cancellation,
		},
		resourceSummary: zeroResourceSummary(invocation.limits),
	});
}

function correlationFromInvocation(invocation: SubAgentTaskInvocationEnvelope): Record<string, unknown> {
	return {
		agentId: invocation.agentId,
		runId: invocation.runId,
		taskId: invocation.taskId,
		sessionId: invocation.sessionId,
		toolCallId: invocation.toolCallId,
		parentAgentId: invocation.parentAgentId,
		parentRunId: invocation.parentRunId,
		parentTaskId: invocation.parentTaskId,
		parentSessionId: invocation.parentSessionId,
		parentId: invocation.parentId,
	};
}

function zeroResourceSummary(limits: SubAgentResourceLimits | undefined): SubAgentResourceSummary {
	return {
		turns: 0,
		outputBytes: 0,
		outputLines: 0,
		childrenStarted: 0,
		limitDetails: limitDetailsForActuals(limits, {
			turns: 0,
			outputBytes: 0,
			outputLines: 0,
			childrenStarted: 0,
		}),
	};
}

const defaultDelegate: SubAgentDelegationHost = (invocation) => {
	const text = `delegated:${invocation.route ?? "default"}:${JSON.stringify(invocation.input)}`;
	const outputBytes = new TextEncoder().encode(text).length;
	const outputLines = countLines(text);
	return validateSubAgentTaskResultEnvelope({
		...correlationFromInvocation(invocation),
		type: "sub_agent_task_result",
		status: "completed",
		content: [{ type: "text", text }],
		startedAt: Date.now(),
		completedAt: Date.now(),
		resourceSummary: {
			turns: 1,
			outputBytes,
			outputLines,
			childrenStarted: 1,
			limitDetails: limitDetailsForActuals(invocation.limits, {
				turns: 1,
				outputBytes,
				outputLines,
				childrenStarted: 1,
			}),
		},
		details: {
			capability: "agent.delegate",
			operation: "agent.delegate",
			route: invocation.route,
		},
	});
};

function limitDetailsForActuals(
	limits: SubAgentResourceLimits | undefined,
	actuals: { turns: number; outputBytes: number; outputLines: number; childrenStarted: number },
): SubAgentResourceSummary["limitDetails"] {
	if (!limits) return undefined;
	const details: NonNullable<SubAgentResourceSummary["limitDetails"]> = {};
	if (limits.turns !== undefined) {
		details.turns = { limit: limits.turns, actual: actuals.turns, truncated: actuals.turns > limits.turns };
	}
	if (limits.outputBytes !== undefined) {
		details.outputBytes = {
			limit: limits.outputBytes,
			actual: actuals.outputBytes,
			truncated: actuals.outputBytes > limits.outputBytes,
		};
	}
	if (limits.outputLines !== undefined) {
		details.outputLines = {
			limit: limits.outputLines,
			actual: actuals.outputLines,
			truncated: actuals.outputLines > limits.outputLines,
		};
	}
	if (limits.maxChildren !== undefined) {
		details.maxChildren = {
			limit: limits.maxChildren,
			actual: actuals.childrenStarted,
			truncated: actuals.childrenStarted > limits.maxChildren,
		};
	}
	if (limits.toolScopes !== undefined) details.toolScopes = limits.toolScopes;
	return details;
}

function countLines(text: string): number {
	if (text.length === 0) return 0;
	return text.split(/\r\n|\r|\n/).length;
}

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
