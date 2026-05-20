import type { AgentTool } from "@earendil-works/pi-agent-core";
import { type Static, Type } from "typebox";
import type { ToolRenderer } from "./types.js";
declare const extractDocumentSchema: Type.TObject<{
    url: Type.TString;
}>;
export type ExtractDocumentParams = Static<typeof extractDocumentSchema>;
export interface ExtractDocumentResult {
    extractedText: string;
    format: string;
    fileName: string;
    size: number;
}
export declare function createExtractDocumentTool(): AgentTool<typeof extractDocumentSchema, ExtractDocumentResult> & {
    corsProxyUrl?: string;
};
export declare const extractDocumentTool: AgentTool<Type.TObject<{
    url: Type.TString;
}>, ExtractDocumentResult> & {
    corsProxyUrl?: string;
};
export declare const extractDocumentRenderer: ToolRenderer<ExtractDocumentParams, ExtractDocumentResult>;
export {};
//# sourceMappingURL=extract-document.d.ts.map