import { homedir } from "node:os";
import { join } from "node:path";

const CONFIG_DIR_NAME = ".pi";
const ENV_ORCHESTRATOR_DIR = "PI_ORCHESTRATOR_DIR";

export function getOrchestratorDir(): string {
	const envDir = process.env[ENV_ORCHESTRATOR_DIR];
	if (envDir) {
		return envDir;
	}

	const piDir = process.env.PI_CONFIG_DIR || join(homedir(), CONFIG_DIR_NAME);
	return join(piDir, "orchestrator");
}

export function getAuthPath(): string {
	return join(getOrchestratorDir(), "auth.json");
}

export function getMachinePath(): string {
	return join(getOrchestratorDir(), "machine.json");
}

export function getInstancesPath(): string {
	return join(getOrchestratorDir(), "instances.json");
}

export function getSocketPath(): string {
	return join(getOrchestratorDir(), "orchestrator.sock");
}
