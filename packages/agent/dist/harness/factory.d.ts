import { AgentHarness } from "./agent-harness.js";
import { Session } from "./session/session.js";
import type { AgentHarnessOptions, SessionMetadata, SessionStorage } from "./types.js";
export declare function createSession<TMetadata extends SessionMetadata>(storage: SessionStorage<TMetadata>): Session<TMetadata>;
export declare function createAgentHarness(options: AgentHarnessOptions): AgentHarness;
//# sourceMappingURL=factory.d.ts.map