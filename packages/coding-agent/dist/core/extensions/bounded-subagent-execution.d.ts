import type { SubAgentTaskInvocationEnvelope, SubAgentTaskResultEnvelope } from "./subagent-readiness.js";
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
export type BoundedSubAgentExecutor = (invocation: SubAgentTaskInvocationEnvelope, context: BoundedSubAgentExecutionContext) => Promise<SubAgentTaskResultEnvelope> | SubAgentTaskResultEnvelope;
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
export declare function executeBoundedSubAgentTask(input: SubAgentTaskInvocationEnvelope, options?: BoundedSubAgentExecutionOptions): Promise<SubAgentTaskResultEnvelope>;
export declare const defaultBoundedSubAgentExecutor: BoundedSubAgentExecutor;
//# sourceMappingURL=bounded-subagent-execution.d.ts.map