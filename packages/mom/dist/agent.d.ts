import { type SandboxConfig } from "./sandbox.js";
import type { SlackContext } from "./slack.js";
import type { ChannelStore } from "./store.js";
export interface PendingMessage {
    userName: string;
    text: string;
    attachments: {
        local: string;
    }[];
    timestamp: number;
}
export interface AgentRunner {
    run(ctx: SlackContext, store: ChannelStore, pendingMessages?: PendingMessage[]): Promise<{
        stopReason: string;
        errorMessage?: string;
    }>;
    abort(): void;
}
/**
 * Get or create an AgentRunner for a channel.
 * Runners are cached - one per channel, persistent across messages.
 */
export declare function getOrCreateRunner(sandboxConfig: SandboxConfig, channelId: string, channelDir: string): AgentRunner;
//# sourceMappingURL=agent.d.ts.map