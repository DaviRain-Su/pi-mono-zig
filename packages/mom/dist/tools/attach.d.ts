import type { AgentTool } from "@mariozechner/pi-agent-core";
export declare function setUploadFunction(fn: (filePath: string, title?: string) => Promise<void>): void;
declare const attachSchema: import("@sinclair/typebox").TObject<{
    label: import("@sinclair/typebox").TString;
    path: import("@sinclair/typebox").TString;
    title: import("@sinclair/typebox").TOptional<import("@sinclair/typebox").TString>;
}>;
export declare const attachTool: AgentTool<typeof attachSchema>;
export {};
//# sourceMappingURL=attach.d.ts.map