import type { AgentTool } from "@mariozechner/pi-agent-core";
import type { Executor } from "../sandbox.js";
declare const readSchema: import("@sinclair/typebox").TObject<{
    label: import("@sinclair/typebox").TString;
    path: import("@sinclair/typebox").TString;
    offset: import("@sinclair/typebox").TOptional<import("@sinclair/typebox").TNumber>;
    limit: import("@sinclair/typebox").TOptional<import("@sinclair/typebox").TNumber>;
}>;
export declare function createReadTool(executor: Executor): AgentTool<typeof readSchema>;
export {};
//# sourceMappingURL=read.d.ts.map