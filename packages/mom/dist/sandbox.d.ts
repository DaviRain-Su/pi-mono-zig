export type SandboxConfig = {
    type: "host";
} | {
    type: "docker";
    container: string;
};
export declare function parseSandboxArg(value: string): SandboxConfig;
export declare function validateSandbox(config: SandboxConfig): Promise<void>;
/**
 * Create an executor that runs commands either on host or in Docker container
 */
export declare function createExecutor(config: SandboxConfig): Executor;
export interface Executor {
    /**
     * Execute a bash command
     */
    exec(command: string, options?: ExecOptions): Promise<ExecResult>;
    /**
     * Get the workspace path prefix for this executor
     * Host: returns the actual path
     * Docker: returns /workspace
     */
    getWorkspacePath(hostPath: string): string;
}
export interface ExecOptions {
    timeout?: number;
    signal?: AbortSignal;
}
export interface ExecResult {
    stdout: string;
    stderr: string;
    code: number;
}
//# sourceMappingURL=sandbox.d.ts.map