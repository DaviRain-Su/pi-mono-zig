export interface SSHResult {
    stdout: string;
    stderr: string;
    exitCode: number;
}
/**
 * Execute an SSH command and return the result
 */
export declare const sshExec: (sshCmd: string, command: string, options?: {
    keepAlive?: boolean | undefined;
} | undefined) => Promise<SSHResult>;
/**
 * Execute an SSH command with streaming output to console
 */
export declare const sshExecStream: (sshCmd: string, command: string, options?: {
    silent?: boolean | undefined;
    forceTTY?: boolean | undefined;
    keepAlive?: boolean | undefined;
} | undefined) => Promise<number>;
/**
 * Copy a file to remote via SCP
 */
export declare const scpFile: (sshCmd: string, localPath: string, remotePath: string) => Promise<boolean>;
//# sourceMappingURL=ssh.d.ts.map