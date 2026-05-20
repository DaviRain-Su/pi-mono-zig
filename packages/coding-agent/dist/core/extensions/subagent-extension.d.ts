import { type Static, Type } from "typebox";
import { type SubAgentTaskInvocationEnvelope, type SubAgentTaskResultEnvelope } from "./subagent-readiness.js";
import type { ExtensionContext, ExtensionFactory } from "./types.js";
export declare const SUB_AGENT_READINESS_ENTRY = "sub_agent.readiness";
export declare const SUB_AGENT_DELEGATION_RESULT_ENTRY = "sub_agent.delegation.result";
export declare const SUB_AGENT_STATUS_MESSAGE = "sub_agent.status";
export declare const SUB_AGENT_DELEGATION_TOOL = "sub_agent.delegate";
export declare const SUB_AGENT_DELEGATION_COMMAND = "sub-agent";
export type SubAgentDelegationCapability = "agent.delegate";
export interface SubAgentDelegationHostContext {
    readonly signal: AbortSignal | undefined;
    readonly context: ExtensionContext;
}
export type SubAgentDelegationHost = (invocation: SubAgentTaskInvocationEnvelope, context: SubAgentDelegationHostContext) => Promise<SubAgentTaskResultEnvelope> | SubAgentTaskResultEnvelope;
export interface SubAgentExtensionOptions {
    approvedCapabilities?: readonly SubAgentDelegationCapability[];
    delegate?: SubAgentDelegationHost;
}
export declare const subAgentDelegationInputSchema: Type.TObject<{
    agentId: Type.TString;
    runId: Type.TString;
    taskId: Type.TString;
    sessionId: Type.TString;
    toolCallId: Type.TOptional<Type.TString>;
    parentAgentId: Type.TOptional<Type.TString>;
    parentRunId: Type.TOptional<Type.TString>;
    parentTaskId: Type.TOptional<Type.TString>;
    parentSessionId: Type.TOptional<Type.TString>;
    parentId: Type.TOptional<Type.TString>;
    route: Type.TOptional<Type.TString>;
    input: Type.TRecord<"^.*$", Type.TUnknown>;
    limits: Type.TOptional<Type.TObject<{
        maxChildren: Type.TOptional<Type.TInteger>;
        depth: Type.TOptional<Type.TInteger>;
        turns: Type.TOptional<Type.TInteger>;
        timeoutMs: Type.TOptional<Type.TInteger>;
        outputBytes: Type.TOptional<Type.TInteger>;
        outputLines: Type.TOptional<Type.TInteger>;
        toolScopes: Type.TOptional<Type.TArray<Type.TString>>;
    }>>;
    cancellation: Type.TOptional<Type.TObject<{
        signalId: Type.TOptional<Type.TString>;
        state: Type.TUnion<[Type.TLiteral<"pending">, Type.TLiteral<"requested">, Type.TLiteral<"propagated">, Type.TLiteral<"completed">]>;
        reason: Type.TOptional<Type.TString>;
        parentRunId: Type.TOptional<Type.TString>;
        parentTaskId: Type.TOptional<Type.TString>;
        propagatedFrom: Type.TOptional<Type.TString>;
    }>>;
    metadata: Type.TOptional<Type.TRecord<"^.*$", Type.TUnknown>>;
}>;
export type SubAgentDelegationInput = Static<typeof subAgentDelegationInputSchema>;
export declare function createSubAgentExtension(options?: SubAgentExtensionOptions): ExtensionFactory;
//# sourceMappingURL=subagent-extension.d.ts.map