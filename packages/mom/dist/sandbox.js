import { spawn } from "child_process";
export function parseSandboxArg(value) {
    if (value === "host") {
        return { type: "host" };
    }
    if (value.startsWith("docker:")) {
        const container = value.slice("docker:".length);
        if (!container) {
            console.error("Error: docker sandbox requires container name (e.g., docker:mom-sandbox)");
            process.exit(1);
        }
        return { type: "docker", container };
    }
    console.error(`Error: Invalid sandbox type '${value}'. Use 'host' or 'docker:<container-name>'`);
    process.exit(1);
}
export async function validateSandbox(config) {
    if (config.type === "host") {
        return;
    }
    // Check if Docker is available
    try {
        await execSimple("docker", ["--version"]);
    }
    catch {
        console.error("Error: Docker is not installed or not in PATH");
        process.exit(1);
    }
    // Check if container exists and is running
    try {
        const result = await execSimple("docker", ["inspect", "-f", "{{.State.Running}}", config.container]);
        if (result.trim() !== "true") {
            console.error(`Error: Container '${config.container}' is not running.`);
            console.error(`Start it with: docker start ${config.container}`);
            process.exit(1);
        }
    }
    catch {
        console.error(`Error: Container '${config.container}' does not exist.`);
        console.error("Create it with: ./docker.sh create <data-dir>");
        process.exit(1);
    }
    console.log(`  Docker container '${config.container}' is running.`);
}
function execSimple(cmd, args) {
    return new Promise((resolve, reject) => {
        const child = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"] });
        let stdout = "";
        let stderr = "";
        child.stdout?.on("data", (d) => {
            stdout += d;
        });
        child.stderr?.on("data", (d) => {
            stderr += d;
        });
        child.on("close", (code) => {
            if (code === 0)
                resolve(stdout);
            else
                reject(new Error(stderr || `Exit code ${code}`));
        });
    });
}
/**
 * Create an executor that runs commands either on host or in Docker container
 */
export function createExecutor(config) {
    if (config.type === "host") {
        return new HostExecutor();
    }
    return new DockerExecutor(config.container);
}
class HostExecutor {
    async exec(command, options) {
        return new Promise((resolve, reject) => {
            const shell = process.platform === "win32" ? "cmd" : "sh";
            const shellArgs = process.platform === "win32" ? ["/c"] : ["-c"];
            const child = spawn(shell, [...shellArgs, command], {
                detached: true,
                stdio: ["ignore", "pipe", "pipe"],
            });
            let stdout = "";
            let stderr = "";
            let timedOut = false;
            const timeoutHandle = options?.timeout && options.timeout > 0
                ? setTimeout(() => {
                    timedOut = true;
                    killProcessTree(child.pid);
                }, options.timeout * 1000)
                : undefined;
            const onAbort = () => {
                if (child.pid)
                    killProcessTree(child.pid);
            };
            if (options?.signal) {
                if (options.signal.aborted) {
                    onAbort();
                }
                else {
                    options.signal.addEventListener("abort", onAbort, { once: true });
                }
            }
            child.stdout?.on("data", (data) => {
                stdout += data.toString();
                if (stdout.length > 10 * 1024 * 1024) {
                    stdout = stdout.slice(0, 10 * 1024 * 1024);
                }
            });
            child.stderr?.on("data", (data) => {
                stderr += data.toString();
                if (stderr.length > 10 * 1024 * 1024) {
                    stderr = stderr.slice(0, 10 * 1024 * 1024);
                }
            });
            child.on("close", (code) => {
                if (timeoutHandle)
                    clearTimeout(timeoutHandle);
                if (options?.signal) {
                    options.signal.removeEventListener("abort", onAbort);
                }
                if (options?.signal?.aborted) {
                    reject(new Error(`${stdout}\n${stderr}\nCommand aborted`.trim()));
                    return;
                }
                if (timedOut) {
                    reject(new Error(`${stdout}\n${stderr}\nCommand timed out after ${options?.timeout} seconds`.trim()));
                    return;
                }
                resolve({ stdout, stderr, code: code ?? 0 });
            });
        });
    }
    getWorkspacePath(hostPath) {
        return hostPath;
    }
}
class DockerExecutor {
    container;
    constructor(container) {
        this.container = container;
    }
    async exec(command, options) {
        // Wrap command for docker exec
        const dockerCmd = `docker exec ${this.container} sh -c ${shellEscape(command)}`;
        const hostExecutor = new HostExecutor();
        return hostExecutor.exec(dockerCmd, options);
    }
    getWorkspacePath(_hostPath) {
        // Docker container sees /workspace
        return "/workspace";
    }
}
function killProcessTree(pid) {
    if (process.platform === "win32") {
        try {
            spawn("taskkill", ["/F", "/T", "/PID", String(pid)], {
                stdio: "ignore",
                detached: true,
            });
        }
        catch {
            // Ignore errors
        }
    }
    else {
        try {
            process.kill(-pid, "SIGKILL");
        }
        catch {
            try {
                process.kill(pid, "SIGKILL");
            }
            catch {
                // Process already dead
            }
        }
    }
}
function shellEscape(s) {
    // Escape for passing to sh -c
    return `'${s.replace(/'/g, "'\\''")}'`;
}
//# sourceMappingURL=sandbox.js.map