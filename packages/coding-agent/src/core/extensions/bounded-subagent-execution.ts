import type {
	SubAgentCancellationMetadata,
	SubAgentResourceLimitDetail,
	SubAgentResourceLimitDetails,
	SubAgentResourceLimits,
	SubAgentResourceSummary,
	SubAgentTaskInvocationEnvelope,
	SubAgentTaskResultEnvelope,
} from "./subagent-readiness.js";
import { validateSubAgentTaskInvocationEnvelope, validateSubAgentTaskResultEnvelope } from "./subagent-readiness.js";

export interface BoundedSubAgentToolResult {
	ok: boolean;
	output?: unknown;
	error?: {
		reason: string;
		message: string;
		details?: Record<string, unknown>;
	};
}

export type BoundedSubAgentToolHandler = (input: unknown) => Promise<unknown> | unknown;

export interface BoundedSubAgentExecutionContext {
	readonly invocation: SubAgentTaskInvocationEnvelope;
	readonly signal: AbortSignal;
	consumeTurn(count?: number): void;
	runTool(name: string, input: unknown): Promise<BoundedSubAgentToolResult>;
}

export type BoundedSubAgentExecutor = (
	invocation: SubAgentTaskInvocationEnvelope,
	context: BoundedSubAgentExecutionContext,
) => Promise<SubAgentTaskResultEnvelope> | SubAgentTaskResultEnvelope;

export interface BoundedSubAgentAdmissionDenial {
	reason: string;
	message: string;
	details?: Record<string, unknown>;
}

export interface BoundedSubAgentExecutionStore {
	findResult?: (invocation: SubAgentTaskInvocationEnvelope) => SubAgentTaskResultEnvelope | undefined;
	appendInvocation?: (invocation: SubAgentTaskInvocationEnvelope) => Promise<void> | void;
	appendResult?: (result: SubAgentTaskResultEnvelope) => Promise<void> | void;
}

export interface BoundedSubAgentExecutionOptions {
	executor?: BoundedSubAgentExecutor;
	signal?: AbortSignal;
	store?: BoundedSubAgentExecutionStore;
	tools?: Readonly<Record<string, BoundedSubAgentToolHandler>>;
	admission?: (invocation: SubAgentTaskInvocationEnvelope) => BoundedSubAgentAdmissionDenial | undefined;
	now?: () => number;
}

class ResourceLimitError extends Error {
	readonly limitName: keyof SubAgentResourceLimits;
	readonly limit: number | undefined;
	readonly actual: number | undefined;

	constructor(limitName: keyof SubAgentResourceLimits, limit: number | undefined, actual: number | undefined) {
		super(`resource limit exceeded: ${limitName}`);
		this.limitName = limitName;
		this.limit = limit;
		this.actual = actual;
	}
}

class CancelledExecutionError extends Error {
	constructor() {
		super("delegation cancelled");
	}
}

interface RuntimeAccounting {
	turns: number;
	childrenStarted: number;
	deniedTool?: string;
}

interface OutputAccounting {
	content: unknown;
	actualBytes: number;
	actualLines: number;
	boundedBytes: number;
	boundedLines: number;
	truncatedBytes: boolean;
	truncatedLines: boolean;
}

const textEncoder = new TextEncoder();

export async function executeBoundedSubAgentTask(
	input: SubAgentTaskInvocationEnvelope,
	options: BoundedSubAgentExecutionOptions = {},
): Promise<SubAgentTaskResultEnvelope> {
	const invocation = validateSubAgentTaskInvocationEnvelope(input);
	const now = options.now ?? Date.now;
	const replayed = options.store?.findResult?.(invocation);
	if (replayed !== undefined) {
		const replayedResult = validateSubAgentTaskResultEnvelope(replayed);
		if (replayKeyMatches(invocation, replayedResult)) return replayedResult;
	}

	if (invocation.cancellation?.state === "requested" || options.signal?.aborted === true) {
		const propagatedInvocation = propagateCancellation(invocation, options.signal);
		await options.store?.appendInvocation?.(propagatedInvocation);
		const result = buildCancelledResult(propagatedInvocation, now);
		await options.store?.appendResult?.(result);
		return result;
	}

	await options.store?.appendInvocation?.(invocation);

	const admissionDenial = options.admission?.(invocation);
	if (admissionDenial !== undefined) {
		const result = buildFailedResult(invocation, now, {
			reason: admissionDenial.reason,
			message: admissionDenial.message,
			details: admissionDenial.details,
			resourceSummary: zeroResourceSummary(invocation.limits),
		});
		await options.store?.appendResult?.(result);
		return result;
	}

	const admissionLimit = exhaustedAdmissionLimit(invocation.limits);
	if (admissionLimit !== undefined) {
		const result = buildResourceLimitResult(invocation, now, admissionLimit, zeroResourceSummary(invocation.limits));
		await options.store?.appendResult?.(result);
		return result;
	}

	const abortController = new AbortController();
	const runtime: RuntimeAccounting = { turns: 0, childrenStarted: 1 };
	const signalCleanups: Array<() => void> = [];
	let timeoutHandle: ReturnType<typeof setTimeout> | undefined;
	let timeoutExpired = false;

	const abortFromParent = (): void => abortController.abort(options.signal?.reason);
	if (options.signal !== undefined) {
		if (options.signal.aborted) {
			abortFromParent();
		} else {
			options.signal.addEventListener("abort", abortFromParent, { once: true });
			signalCleanups.push(() => options.signal?.removeEventListener("abort", abortFromParent));
		}
	}

	const timeoutPromise =
		invocation.limits?.timeoutMs === undefined
			? undefined
			: new Promise<never>((_resolve, reject) => {
					timeoutHandle = setTimeout(() => {
						timeoutExpired = true;
						abortController.abort("timeoutMs");
						reject(
							new ResourceLimitError("timeoutMs", invocation.limits?.timeoutMs, invocation.limits?.timeoutMs),
						);
					}, invocation.limits?.timeoutMs);
				});
	const cancellationPromise = new Promise<never>((_resolve, reject) => {
		if (abortController.signal.aborted) {
			reject(new CancelledExecutionError());
			return;
		}
		const onAbort = (): void => reject(new CancelledExecutionError());
		abortController.signal.addEventListener("abort", onAbort, { once: true });
		signalCleanups.push(() => abortController.signal.removeEventListener("abort", onAbort));
	});

	try {
		const context = buildExecutionContext(invocation, abortController.signal, runtime, options.tools);
		const executor = options.executor ?? defaultBoundedSubAgentExecutor;
		const execution = Promise.resolve(executor(invocation, context));
		const raced =
			timeoutPromise === undefined
				? Promise.race([execution, cancellationPromise])
				: Promise.race([execution, timeoutPromise, cancellationPromise]);
		const delegated = await raced;
		const result = normalizeResultIdentity(invocation, validateSubAgentTaskResultEnvelope(delegated));
		if (abortController.signal.aborted) {
			const cancelled = timeoutExpired
				? buildResourceLimitResult(
						invocation,
						now,
						new ResourceLimitError("timeoutMs", invocation.limits?.timeoutMs, invocation.limits?.timeoutMs),
						zeroResourceSummary(invocation.limits),
					)
				: buildCancelledResult(propagateCancellation(invocation, options.signal), now);
			await options.store?.appendResult?.(cancelled);
			return cancelled;
		}
		const bounded = enforceRuntimeBoundaries(invocation, result, runtime, now);
		await options.store?.appendResult?.(bounded);
		return bounded;
	} catch (error) {
		const result =
			error instanceof ResourceLimitError
				? buildResourceLimitResult(invocation, now, error, summaryFromRuntime(invocation.limits, runtime))
				: abortController.signal.aborted || error instanceof CancelledExecutionError
					? timeoutExpired
						? buildResourceLimitResult(
								invocation,
								now,
								new ResourceLimitError("timeoutMs", invocation.limits?.timeoutMs, invocation.limits?.timeoutMs),
								summaryFromRuntime(invocation.limits, runtime),
							)
						: buildCancelledResult(
								propagateCancellation(invocation, options.signal),
								now,
								summaryFromRuntime(invocation.limits, runtime),
							)
					: buildFailedResult(invocation, now, {
							reason: "child_execution_failed",
							message: error instanceof Error ? error.message : "child execution failed",
							details: {},
							resourceSummary: summaryFromRuntime(invocation.limits, runtime),
						});
		await options.store?.appendResult?.(result);
		return result;
	} finally {
		if (timeoutHandle !== undefined) clearTimeout(timeoutHandle);
		for (const cleanup of signalCleanups) cleanup();
	}
}

export const defaultBoundedSubAgentExecutor: BoundedSubAgentExecutor = (invocation) => {
	const text = `delegated:${invocation.route ?? "default"}:${JSON.stringify(invocation.input)}`;
	const outputBytes = textEncoder.encode(text).length;
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

function buildExecutionContext(
	invocation: SubAgentTaskInvocationEnvelope,
	signal: AbortSignal,
	runtime: RuntimeAccounting,
	tools: Readonly<Record<string, BoundedSubAgentToolHandler>> | undefined,
): BoundedSubAgentExecutionContext {
	return {
		invocation,
		signal,
		consumeTurn: (count = 1) => {
			const next = runtime.turns + count;
			const limit = invocation.limits?.turns;
			if (limit !== undefined && next > limit) {
				runtime.turns = limit;
				throw new ResourceLimitError("turns", limit, next);
			}
			runtime.turns = next;
		},
		runTool: async (name, input) => {
			const scopes = invocation.limits?.toolScopes;
			if (scopes !== undefined && !scopes.includes(name)) {
				runtime.deniedTool = name;
				return {
					ok: false,
					error: {
						reason: "resource_limit_exceeded",
						message: "resource limit exceeded: toolScopes",
						details: { tool: name, toolScopes: scopes },
					},
				};
			}
			const handler = tools?.[name];
			if (handler === undefined) return { ok: true, output: undefined };
			return { ok: true, output: await handler(input) };
		},
	};
}

function exhaustedAdmissionLimit(limits: SubAgentResourceLimits | undefined): ResourceLimitError | undefined {
	if (limits?.maxChildren !== undefined && limits.maxChildren < 1) {
		return new ResourceLimitError("maxChildren", limits.maxChildren, 0);
	}
	if (limits?.depth !== undefined && limits.depth < 1) return new ResourceLimitError("depth", limits.depth, 0);
	if (limits?.turns !== undefined && limits.turns < 1) return new ResourceLimitError("turns", limits.turns, 0);
	if (limits?.timeoutMs !== undefined && limits.timeoutMs < 1) {
		return new ResourceLimitError("timeoutMs", limits.timeoutMs, 0);
	}
	return undefined;
}

function enforceRuntimeBoundaries(
	invocation: SubAgentTaskInvocationEnvelope,
	result: SubAgentTaskResultEnvelope,
	runtime: RuntimeAccounting,
	now: () => number,
): SubAgentTaskResultEnvelope {
	const summary = mergeResourceSummary(invocation.limits, result.resourceSummary, runtime);
	if (runtime.deniedTool !== undefined) {
		return buildResourceLimitResult(
			invocation,
			now,
			new ResourceLimitError("toolScopes", undefined, undefined),
			{
				...summary,
				limitDetails: {
					...summary.limitDetails,
					toolScopes: invocation.limits?.toolScopes,
				},
			},
			{ tool: runtime.deniedTool, toolScopes: invocation.limits?.toolScopes },
		);
	}
	const turnLimit = invocation.limits?.turns;
	if (turnLimit !== undefined && (summary.turns ?? 0) > turnLimit) {
		return buildResourceLimitResult(invocation, now, new ResourceLimitError("turns", turnLimit, summary.turns), {
			...summary,
			turns: turnLimit,
		});
	}
	const childLimit = invocation.limits?.maxChildren;
	if (childLimit !== undefined && (summary.childrenStarted ?? 0) > childLimit) {
		return buildResourceLimitResult(
			invocation,
			now,
			new ResourceLimitError("maxChildren", childLimit, summary.childrenStarted),
			{ ...summary, childrenStarted: childLimit },
		);
	}
	const output = boundOutput(result.content, invocation.limits);
	const boundedSummary = mergeLimitDetails(invocation.limits, {
		...summary,
		outputBytes: output.boundedBytes,
		outputLines: output.boundedLines,
	});
	return validateSubAgentTaskResultEnvelope({
		...result,
		content: output.content,
		resourceSummary: {
			...boundedSummary,
			limitDetails: {
				...boundedSummary.limitDetails,
				...(invocation.limits?.outputBytes === undefined
					? {}
					: {
							outputBytes: {
								limit: invocation.limits.outputBytes,
								actual: output.actualBytes,
								truncated: output.truncatedBytes,
								reason: output.truncatedBytes ? "resource limit exceeded: outputBytes" : undefined,
							},
						}),
				...(invocation.limits?.outputLines === undefined
					? {}
					: {
							outputLines: {
								limit: invocation.limits.outputLines,
								actual: output.actualLines,
								truncated: output.truncatedLines,
								reason: output.truncatedLines ? "resource limit exceeded: outputLines" : undefined,
							},
						}),
			},
		},
	});
}

function boundOutput(content: unknown, limits: SubAgentResourceLimits | undefined): OutputAccounting {
	const text = extractSingleText(content);
	const actualText = text ?? stringifyContentForLimitAccounting(content);
	const actualBytes = textEncoder.encode(actualText).length;
	const actualLines = countLines(actualText);
	const lineBounded = truncateLines(actualText, limits?.outputLines);
	const byteBounded = truncateUtf8(lineBounded.text, limits?.outputBytes);
	const boundedText = byteBounded.text;
	return {
		content:
			text === undefined
				? boundedText === actualText
					? content
					: boundedText
				: replaceSingleText(content, boundedText),
		actualBytes,
		actualLines,
		boundedBytes: textEncoder.encode(boundedText).length,
		boundedLines: countLines(boundedText),
		truncatedBytes: byteBounded.truncated,
		truncatedLines: lineBounded.truncated,
	};
}

function stringifyContentForLimitAccounting(content: unknown): string {
	if (content === undefined) return "";
	try {
		const encoded = JSON.stringify(content);
		return encoded === undefined ? String(content) : encoded;
	} catch {
		return String(content);
	}
}

function extractSingleText(content: unknown): string | undefined {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return undefined;
	const blocks = content.filter(
		(block): block is { type?: unknown; text: string } =>
			block !== null && typeof block === "object" && "text" in block && typeof block.text === "string",
	);
	if (blocks.length !== 1) return undefined;
	return blocks[0]?.text;
}

function replaceSingleText(content: unknown, text: string): unknown {
	if (typeof content === "string") return text;
	if (!Array.isArray(content)) return content;
	return content.map((block) => {
		if (block !== null && typeof block === "object" && "text" in block && typeof block.text === "string") {
			return { ...block, text };
		}
		return block;
	});
}

function truncateLines(text: string, limit: number | undefined): { text: string; truncated: boolean } {
	if (limit === undefined || countLines(text) <= limit) return { text, truncated: false };
	if (limit === 0) return { text: "", truncated: text.length > 0 };
	return {
		text: text
			.split(/\r\n|\r|\n/)
			.slice(0, limit)
			.join("\n"),
		truncated: true,
	};
}

function truncateUtf8(text: string, limit: number | undefined): { text: string; truncated: boolean } {
	if (limit === undefined || textEncoder.encode(text).length <= limit) return { text, truncated: false };
	let output = "";
	for (const character of text) {
		const next = `${output}${character}`;
		if (textEncoder.encode(next).length > limit) break;
		output = next;
	}
	return { text: output, truncated: true };
}

function normalizeResultIdentity(
	invocation: SubAgentTaskInvocationEnvelope,
	result: SubAgentTaskResultEnvelope,
): SubAgentTaskResultEnvelope {
	return validateSubAgentTaskResultEnvelope({
		...result,
		...correlationFromInvocation(invocation),
	});
}

function replayKeyMatches(invocation: SubAgentTaskInvocationEnvelope, result: SubAgentTaskResultEnvelope): boolean {
	return (
		result.agentId === invocation.agentId &&
		result.runId === invocation.runId &&
		result.taskId === invocation.taskId &&
		result.sessionId === invocation.sessionId
	);
}

function propagateCancellation(
	invocation: SubAgentTaskInvocationEnvelope,
	signal: AbortSignal | undefined,
): SubAgentTaskInvocationEnvelope {
	const cancellation: SubAgentCancellationMetadata = {
		...invocation.cancellation,
		state: "propagated",
		reason: invocation.cancellation?.reason ?? signalCancellationReason(signal) ?? "cancelled",
		propagatedFrom: invocation.cancellation?.propagatedFrom ?? invocation.parentRunId ?? invocation.runId,
	};
	return validateSubAgentTaskInvocationEnvelope({
		...invocation,
		cancellation,
	});
}

function signalCancellationReason(signal: AbortSignal | undefined): string | undefined {
	if (signal?.aborted !== true) return undefined;
	const reason = signal.reason as unknown;
	if (typeof reason === "string" && reason.length > 0) return reason;
	if (reason instanceof Error && reason.message.length > 0) return reason.message;
	return "abort signal requested";
}

function buildCancelledResult(
	invocation: SubAgentTaskInvocationEnvelope,
	now: () => number,
	resourceSummary = zeroResourceSummary(invocation.limits),
): SubAgentTaskResultEnvelope {
	const timestamp = now();
	return validateSubAgentTaskResultEnvelope({
		...correlationFromInvocation(invocation),
		type: "sub_agent_task_result",
		status: "cancelled",
		startedAt: timestamp,
		completedAt: timestamp,
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
		resourceSummary,
	});
}

function buildResourceLimitResult(
	invocation: SubAgentTaskInvocationEnvelope,
	now: () => number,
	error: ResourceLimitError,
	resourceSummary: SubAgentResourceSummary,
	extraDetails: Record<string, unknown> = {},
): SubAgentTaskResultEnvelope {
	const details = mergeLimitDetails(invocation.limits, {
		...resourceSummary,
		limitDetails: {
			...resourceSummary.limitDetails,
			...(error.limitName === "toolScopes"
				? { toolScopes: invocation.limits?.toolScopes }
				: {
						[error.limitName]: {
							limit: error.limit ?? 0,
							actual: error.actual,
							truncated: true,
							reason: error.message,
						},
					}),
		},
	});
	return buildFailedResult(invocation, now, {
		reason: "resource_limit_exceeded",
		message: error.message,
		details: {
			limit: error.limitName,
			...extraDetails,
		},
		resourceSummary: details,
	});
}

function buildFailedResult(
	invocation: SubAgentTaskInvocationEnvelope,
	now: () => number,
	options: {
		reason: string;
		message: string;
		details?: Record<string, unknown>;
		resourceSummary: SubAgentResourceSummary;
	},
): SubAgentTaskResultEnvelope {
	const timestamp = now();
	return validateSubAgentTaskResultEnvelope({
		...correlationFromInvocation(invocation),
		type: "sub_agent_task_result",
		status: "failed",
		startedAt: timestamp,
		completedAt: timestamp,
		error: {
			reason: options.reason,
			message: options.message,
			details: options.details,
		},
		details: {
			capability: "agent.delegate",
			operation: "agent.delegate",
			replayed: false,
			...options.details,
		},
		resourceSummary: options.resourceSummary,
	});
}

function summaryFromRuntime(
	limits: SubAgentResourceLimits | undefined,
	runtime: RuntimeAccounting,
): SubAgentResourceSummary {
	return mergeLimitDetails(limits, {
		turns: runtime.turns,
		outputBytes: 0,
		outputLines: 0,
		childrenStarted: runtime.childrenStarted,
	});
}

function zeroResourceSummary(limits: SubAgentResourceLimits | undefined): SubAgentResourceSummary {
	return mergeLimitDetails(limits, {
		turns: 0,
		outputBytes: 0,
		outputLines: 0,
		childrenStarted: 0,
	});
}

function mergeResourceSummary(
	limits: SubAgentResourceLimits | undefined,
	summary: SubAgentResourceSummary | undefined,
	runtime: RuntimeAccounting,
): SubAgentResourceSummary {
	return mergeLimitDetails(limits, {
		turns: Math.max(summary?.turns ?? 0, runtime.turns),
		outputBytes: summary?.outputBytes ?? 0,
		outputLines: summary?.outputLines ?? 0,
		childrenStarted: summary?.childrenStarted ?? runtime.childrenStarted,
		limitDetails: summary?.limitDetails,
	});
}

function mergeLimitDetails(
	limits: SubAgentResourceLimits | undefined,
	summary: SubAgentResourceSummary,
): SubAgentResourceSummary {
	return {
		...summary,
		limitDetails: {
			...limitDetailsForActuals(limits, {
				turns: summary.turns ?? 0,
				outputBytes: summary.outputBytes ?? 0,
				outputLines: summary.outputLines ?? 0,
				childrenStarted: summary.childrenStarted ?? 0,
			}),
			...summary.limitDetails,
		},
	};
}

function limitDetailsForActuals(
	limits: SubAgentResourceLimits | undefined,
	actuals: { turns: number; outputBytes: number; outputLines: number; childrenStarted: number },
): SubAgentResourceLimitDetails | undefined {
	if (!limits) return undefined;
	const details: SubAgentResourceLimitDetails = {};
	addDetail(details, "turns", limits.turns, actuals.turns);
	addDetail(details, "outputBytes", limits.outputBytes, actuals.outputBytes);
	addDetail(details, "outputLines", limits.outputLines, actuals.outputLines);
	addDetail(details, "maxChildren", limits.maxChildren, actuals.childrenStarted);
	if (limits.depth !== undefined) details.depth = { limit: limits.depth, actual: limits.depth, truncated: false };
	if (limits.timeoutMs !== undefined) {
		details.timeoutMs = { limit: limits.timeoutMs, actual: limits.timeoutMs, truncated: false };
	}
	if (limits.toolScopes !== undefined) details.toolScopes = limits.toolScopes;
	return details;
}

function addDetail(
	details: SubAgentResourceLimitDetails,
	field: "turns" | "outputBytes" | "outputLines" | "maxChildren",
	limit: number | undefined,
	actual: number,
): void {
	if (limit === undefined) return;
	const detail: SubAgentResourceLimitDetail = {
		limit,
		actual,
		truncated: actual > limit,
	};
	if (detail.truncated) detail.reason = `resource limit exceeded: ${field}`;
	details[field] = detail;
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

function countLines(text: string): number {
	if (text.length === 0) return 0;
	return text.split(/\r\n|\r|\n/).length;
}
