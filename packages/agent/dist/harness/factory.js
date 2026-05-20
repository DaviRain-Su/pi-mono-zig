import { AgentHarness } from "./agent-harness.js";
import { Session } from "./session/session.js";
export function createSession(storage) {
    return new Session(storage);
}
export function createAgentHarness(options) {
    return new AgentHarness(options);
}
//# sourceMappingURL=factory.js.map