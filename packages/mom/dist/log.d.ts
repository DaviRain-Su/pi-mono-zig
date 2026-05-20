export interface LogContext {
    channelId: string;
    userName?: string;
    channelName?: string;
}
export declare function logUserMessage(ctx: LogContext, text: string): void;
export declare function logToolStart(ctx: LogContext, toolName: string, label: string, args: Record<string, unknown>): void;
export declare function logToolSuccess(ctx: LogContext, toolName: string, durationMs: number, result: string): void;
export declare function logToolError(ctx: LogContext, toolName: string, durationMs: number, error: string): void;
export declare function logResponseStart(ctx: LogContext): void;
export declare function logThinking(ctx: LogContext, thinking: string): void;
export declare function logResponse(ctx: LogContext, text: string): void;
export declare function logDownloadStart(ctx: LogContext, filename: string, localPath: string): void;
export declare function logDownloadSuccess(ctx: LogContext, sizeKB: number): void;
export declare function logDownloadError(ctx: LogContext, filename: string, error: string): void;
export declare function logStopRequest(ctx: LogContext): void;
export declare function logInfo(message: string): void;
export declare function logWarning(message: string, details?: string): void;
export declare function logAgentError(ctx: LogContext | "system", error: string): void;
export declare function logUsageSummary(ctx: LogContext, usage: {
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
    cost: {
        input: number;
        output: number;
        cacheRead: number;
        cacheWrite: number;
        total: number;
    };
}, contextTokens?: number, contextWindow?: number): string;
export declare function logStartup(workingDir: string, sandbox: string): void;
export declare function logConnected(): void;
export declare function logDisconnected(): void;
export declare function logBackfillStart(channelCount: number): void;
export declare function logBackfillChannel(channelName: string, messageCount: number): void;
export declare function logBackfillComplete(totalMessages: number, durationMs: number): void;
//# sourceMappingURL=log.d.ts.map