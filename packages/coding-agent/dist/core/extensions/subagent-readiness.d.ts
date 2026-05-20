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
export type SubAgentNumericResourceLimit = "maxChildren" | "depth" | "turns" | "timeoutMs" | "outputBytes" | "outputLines";
export interface SubAgentResourceLimitDetail {
    limit: number;
    actual?: number;
    truncated: boolean;
    reason?: string;
}
export type SubAgentResourceLimitDetails = Partial<Record<SubAgentNumericResourceLimit, SubAgentResourceLimitDetail>> & {
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
export declare function validateSubAgentReadinessEnvelope(value: unknown): SubAgentReadinessEnvelope;
export declare function validateSubAgentTaskInvocationEnvelope(value: unknown): SubAgentTaskInvocationEnvelope;
export declare function validateSubAgentTaskResultEnvelope(value: unknown): SubAgentTaskResultEnvelope;
//# sourceMappingURL=subagent-readiness.d.ts.map