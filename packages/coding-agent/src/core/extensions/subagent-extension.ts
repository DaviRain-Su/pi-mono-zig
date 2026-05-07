import { type Static, Type } from "typebox";
import type { CustomEntry } from "../session-manager.js";
import {
	type BoundedSubAgentExecutor,
	defaultBoundedSubAgentExecutor,
	executeBoundedSubAgentTask,
} from "./bounded-subagent-execution.js";
import {
	type SubAgentCancellationMetadata,
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
			const executor: BoundedSubAgentExecutor = async (boundedInvocation, executionContext) => {
				const delegate = options.delegate ?? defaultDelegate;
				return delegate(boundedInvocation, { signal: executionContext.signal, context: ctx });
			};
			return executeBoundedSubAgentTask(invocation, {
				signal,
				executor,
				store: {
					findResult: (candidate) => findRecordedDelegationResult(ctx, candidate),
					appendInvocation: (candidate) => pi.appendEntry(SUB_AGENT_READINESS_ENTRY, candidate),
					appendResult: (result) => pi.appendEntry(SUB_AGENT_DELEGATION_RESULT_ENTRY, result),
				},
				admission: () =>
					approvedCapabilities.has("agent.delegate")
						? undefined
						: {
								reason: "denied_capability",
								message: "grant is not approved",
								details: {
									capability: "agent.delegate",
									operation: "agent.delegate",
								},
							},
			});
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
