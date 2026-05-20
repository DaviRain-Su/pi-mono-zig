import type { AgentMessage, AgentTool } from "@earendil-works/pi-agent-core";
import type { ToolResultMessage } from "@earendil-works/pi-ai";
import { LitElement } from "lit";
export declare class StreamingMessageContainer extends LitElement {
    tools: AgentTool[];
    isStreaming: boolean;
    pendingToolCalls?: ReadonlySet<string>;
    toolResultsById?: Map<string, ToolResultMessage>;
    onCostClick?: () => void;
    private _message;
    private _pendingMessage;
    private _updateScheduled;
    private _immediateUpdate;
    protected createRenderRoot(): HTMLElement | DocumentFragment;
    connectedCallback(): void;
    setMessage(message: AgentMessage | null, immediate?: boolean): void;
    render(): import("lit-html").TemplateResult<1> | undefined;
}
//# sourceMappingURL=StreamingMessageContainer.d.ts.map