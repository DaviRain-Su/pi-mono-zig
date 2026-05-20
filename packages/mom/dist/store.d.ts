export interface Attachment {
    original: string;
    local: string;
}
export interface LoggedMessage {
    date: string;
    ts: string;
    user: string;
    userName?: string;
    displayName?: string;
    text: string;
    attachments: Attachment[];
    isBot: boolean;
}
export interface ChannelStoreConfig {
    workingDir: string;
    botToken: string;
}
export declare class ChannelStore {
    private workingDir;
    private botToken;
    private pendingDownloads;
    private isDownloading;
    private recentlyLogged;
    constructor(config: ChannelStoreConfig);
    /**
     * Get or create the directory for a channel/DM
     */
    getChannelDir(channelId: string): string;
    /**
     * Generate a unique local filename for an attachment
     */
    generateLocalFilename(originalName: string, timestamp: string): string;
    /**
     * Process attachments from a Slack message event
     * Returns attachment metadata and queues downloads
     */
    processAttachments(channelId: string, files: Array<{
        name?: string;
        url_private_download?: string;
        url_private?: string;
    }>, timestamp: string): Attachment[];
    /**
     * Log a message to the channel's log.jsonl
     * Returns false if message was already logged (duplicate)
     */
    logMessage(channelId: string, message: LoggedMessage): Promise<boolean>;
    /**
     * Log a bot response
     */
    logBotResponse(channelId: string, text: string, ts: string): Promise<void>;
    /**
     * Get the timestamp of the last logged message for a channel
     * Returns null if no log exists
     */
    getLastTimestamp(channelId: string): string | null;
    private processDownloadQueue;
    private downloadAttachment;
}
//# sourceMappingURL=store.d.ts.map