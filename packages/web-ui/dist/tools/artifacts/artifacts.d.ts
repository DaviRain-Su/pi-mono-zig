import "@mariozechner/mini-lit/dist/MarkdownBlock.js";
import type { Agent, AgentMessage, AgentTool } from "@earendil-works/pi-agent-core";
import { LitElement, type TemplateResult } from "lit";
import { type Static, Type } from "typebox";
export interface Artifact {
    filename: string;
    content: string;
    createdAt: Date;
    updatedAt: Date;
}
declare const artifactsParamsSchema: Type.TObject<{
    command: Type.TUnsafe<string>;
    filename: Type.TString;
    content: Type.TOptional<Type.TString>;
    old_str: Type.TOptional<Type.TString>;
    new_str: Type.TOptional<Type.TString>;
}>;
export type ArtifactsParams = Static<typeof artifactsParamsSchema>;
export declare class ArtifactsPanel extends LitElement {
    private _artifacts;
    private _activeFilename;
    private artifactElements;
    private contentRef;
    agent?: Agent;
    sandboxUrlProvider?: () => string;
    onArtifactsChange?: () => void;
    onClose?: () => void;
    onOpen?: () => void;
    collapsed: boolean;
    overlay: boolean;
    get artifacts(): Map<string, Artifact>;
    private getHtmlArtifactRuntimeProviders;
    protected createRenderRoot(): HTMLElement | DocumentFragment;
    connectedCallback(): void;
    disconnectedCallback(): void;
    private getFileType;
    private getOrCreateArtifactElement;
    private showArtifact;
    openArtifact(filename: string): void;
    get tool(): AgentTool<typeof artifactsParamsSchema, undefined>;
    reconstructFromMessages(messages: Array<AgentMessage | {
        role: "aborted";
    } | {
        role: "artifact";
    }>): Promise<void>;
    private executeCommand;
    private waitForHtmlExecution;
    private reloadAllHtmlArtifacts;
    private createArtifact;
    private updateArtifact;
    private rewriteArtifact;
    private getArtifact;
    private deleteArtifact;
    private getLogs;
    render(): TemplateResult;
}
declare global {
    interface HTMLElementTagNameMap {
        "artifacts-panel": ArtifactsPanel;
    }
}
export {};
//# sourceMappingURL=artifacts.d.ts.map