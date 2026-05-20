import type { AgentTool } from "@mariozechner/pi-agent-core";
import type { Executor } from "../sandbox.js";
declare const bashSchema: import("@sinclair/typebox").TObject<{
    label: import("@sinclair/typebox").TString;
    command: import("@sinclair/typebox").TString;
    timeout: import("@sinclair/typebox").TOptional<import("@sinclair/typebox").TNumber>;
}>;
export declare function createBashTool(executor: Executor): AgentTool<typeof bashSchema>;
export {};
//# sourceMappingURL=bash.d.ts.map