import type { AgentTool } from "@mariozechner/pi-agent-core";
import type { Executor } from "../sandbox.js";
declare const writeSchema: import("@sinclair/typebox").TObject<{
    label: import("@sinclair/typebox").TString;
    path: import("@sinclair/typebox").TString;
    content: import("@sinclair/typebox").TString;
}>;
export declare function createWriteTool(executor: Executor): AgentTool<typeof writeSchema>;
export {};
//# sourceMappingURL=write.d.ts.map