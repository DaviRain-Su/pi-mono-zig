import type { AgentTool } from "@mariozechner/pi-agent-core";
import type { Executor } from "../sandbox.js";
declare const editSchema: import("@sinclair/typebox").TObject<{
    label: import("@sinclair/typebox").TString;
    path: import("@sinclair/typebox").TString;
    oldText: import("@sinclair/typebox").TString;
    newText: import("@sinclair/typebox").TString;
}>;
export declare function createEditTool(executor: Executor): AgentTool<typeof editSchema>;
export {};
//# sourceMappingURL=edit.d.ts.map