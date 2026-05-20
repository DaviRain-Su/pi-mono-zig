import type { Attachment, ChannelStore } from "./store.js";
export interface SlackEvent {
    type: "mention" | "dm";
    channel: string;
    ts: string;
    user: string;
    text: string;
    files?: Array<{
        name?: string;
        url_private_download?: string;
        url_private?: string;
    }>;
    /** Processed attachments with local paths (populated after logUserMessage) */
    attachments?: Attachment[];
}
export interface SlackUser {
    id: string;
    userName: string;
    displayName: string;
}
export interface SlackChannel {
    id: string;
    name: string;
}
export interface ChannelInfo {
    id: string;
    name: string;
}
export interface UserInfo {
    id: string;
    userName: string;
    displayName: string;
}
export interface SlackContext {
    message: {
        text: string;
        rawText: string;
        user: string;
        userName?: string;
        channel: string;
        ts: string;
        attachments: Array<{
            local: string;
        }>;
    };
    channelName?: string;
    channels: ChannelInfo[];
    users: UserInfo[];
    respond: (text: string, shouldLog?: boolean) => Promise<void>;
    replaceMessage: (text: string) => Promise<void>;
    respondInThread: (text: string) => Promise<void>;
    setTyping: (isTyping: boolean) => Promise<void>;
    uploadFile: (filePath: string, title?: string) => Promise<void>;
    setWorking: (working: boolean) => Promise<void>;
    deleteMessage: () => Promise<void>;
}
export interface MomHandler {
    /**
     * Check if channel is currently running (SYNC)
     */
    isRunning(channelId: string): boolean;
    /**
     * Handle an event that triggers mom (ASYNC)
     * Called only when isRunning() returned false for user messages.
     * Events always queue and pass isEvent=true.
     */
    handleEvent(event: SlackEvent, slack: SlackBot, isEvent?: boolean): Promise<void>;
    /**
     * Handle stop command (ASYNC)
     * Called when user says "stop" while mom is running
     */
    handleStop(channelId: string, slack: SlackBot): Promise<void>;
}
export declare class SlackBot {
    private socketClient;
    private webClient;
    private handler;
    private workingDir;
    private store;
    private botUserId;
    private startupTs;
    private users;
    private channels;
    private queues;
    constructor(handler: MomHandler, config: {
        appToken: string;
        botToken: string;
        workingDir: string;
        store: ChannelStore;
    });
    start(): Promise<void>;
    getUser(userId: string): SlackUser | undefined;
    getChannel(channelId: string): SlackChannel | undefined;
    getAllUsers(): SlackUser[];
    getAllChannels(): SlackChannel[];
    postMessage(channel: string, text: string): Promise<string>;
    updateMessage(channel: string, ts: string, text: string): Promise<void>;
    deleteMessage(channel: string, ts: string): Promise<void>;
    postInThread(channel: string, threadTs: string, text: string): Promise<string>;
    uploadFile(channel: string, filePath: string, title?: string): Promise<void>;
    /**
     * Log a message to log.jsonl (SYNC)
     * This is the ONLY place messages are written to log.jsonl
     */
    logToFile(channel: string, entry: object): void;
    /**
     * Log a bot response to log.jsonl
     */
    logBotResponse(channel: string, text: string, ts: string): void;
    /**
     * Enqueue an event for processing. Always queues (no "already working" rejection).
     * Returns true if enqueued, false if queue is full (max 5).
     */
    enqueueEvent(event: SlackEvent): boolean;
    private getQueue;
    private setupEventHandlers;
    /**
     * Log a user message to log.jsonl (SYNC)
     * Downloads attachments in background via store
     */
    private logUserMessage;
    private getExistingTimestamps;
    private backfillChannel;
    private backfillAllChannels;
    private fetchUsers;
    private fetchChannels;
}
//# sourceMappingURL=slack.d.ts.map