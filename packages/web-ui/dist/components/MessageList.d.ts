import type { AgentMessage, AgentTool } from "@earendil-works/pi-agent-core";
import { LitElement, type TemplateResult } from "lit";
export declare class MessageList extends LitElement {
    messages: AgentMessage[];
    tools: AgentTool[];
    pendingToolCalls?: ReadonlySet<string>;
    isStreaming: boolean;
    onCostClick?: () => void;
    protected createRenderRoot(): HTMLElement | DocumentFragment;
    connectedCallback(): void;
    private buildRenderItems;
    render(): TemplateResult<1>;
}
//# sourceMappingURL=MessageList.d.ts.map