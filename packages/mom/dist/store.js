import { existsSync, mkdirSync, readFileSync } from "fs";
import { appendFile, writeFile } from "fs/promises";
import { join } from "path";
import * as log from "./log.js";
export class ChannelStore {
    workingDir;
    botToken;
    pendingDownloads = [];
    isDownloading = false;
    // Track recently logged message timestamps to prevent duplicates
    // Key: "channelId:ts", automatically cleaned up after 60 seconds
    recentlyLogged = new Map();
    constructor(config) {
        this.workingDir = config.workingDir;
        this.botToken = config.botToken;
        // Ensure working directory exists
        if (!existsSync(this.workingDir)) {
            mkdirSync(this.workingDir, { recursive: true });
        }
    }
    /**
     * Get or create the directory for a channel/DM
     */
    getChannelDir(channelId) {
        const dir = join(this.workingDir, channelId);
        if (!existsSync(dir)) {
            mkdirSync(dir, { recursive: true });
        }
        return dir;
    }
    /**
     * Generate a unique local filename for an attachment
     */
    generateLocalFilename(originalName, timestamp) {
        // Convert slack timestamp (1234567890.123456) to milliseconds
        const ts = Math.floor(parseFloat(timestamp) * 1000);
        // Sanitize original name (remove problematic characters)
        const sanitized = originalName.replace(/[^a-zA-Z0-9._-]/g, "_");
        return `${ts}_${sanitized}`;
    }
    /**
     * Process attachments from a Slack message event
     * Returns attachment metadata and queues downloads
     */
    processAttachments(channelId, files, timestamp) {
        const attachments = [];
        for (const file of files) {
            const url = file.url_private_download || file.url_private;
            if (!url)
                continue;
            if (!file.name) {
                log.logWarning("Attachment missing name, skipping", url);
                continue;
            }
            const filename = this.generateLocalFilename(file.name, timestamp);
            const localPath = `${channelId}/attachments/${filename}`;
            attachments.push({
                original: file.name,
                local: localPath,
            });
            // Queue for background download
            this.pendingDownloads.push({ channelId, localPath, url });
        }
        // Trigger background download
        this.processDownloadQueue();
        return attachments;
    }
    /**
     * Log a message to the channel's log.jsonl
     * Returns false if message was already logged (duplicate)
     */
    async logMessage(channelId, message) {
        // Check for duplicate (same channel + timestamp)
        const dedupeKey = `${channelId}:${message.ts}`;
        if (this.recentlyLogged.has(dedupeKey)) {
            return false; // Already logged
        }
        // Mark as logged and schedule cleanup after 60 seconds
        this.recentlyLogged.set(dedupeKey, Date.now());
        setTimeout(() => this.recentlyLogged.delete(dedupeKey), 60000);
        const logPath = join(this.getChannelDir(channelId), "log.jsonl");
        // Ensure message has a date field
        if (!message.date) {
            // Parse timestamp to get date
            let date;
            if (message.ts.includes(".")) {
                // Slack timestamp format (1234567890.123456)
                date = new Date(parseFloat(message.ts) * 1000);
            }
            else {
                // Epoch milliseconds
                date = new Date(parseInt(message.ts, 10));
            }
            message.date = date.toISOString();
        }
        const line = `${JSON.stringify(message)}\n`;
        await appendFile(logPath, line, "utf-8");
        return true;
    }
    /**
     * Log a bot response
     */
    async logBotResponse(channelId, text, ts) {
        await this.logMessage(channelId, {
            date: new Date().toISOString(),
            ts,
            user: "bot",
            text,
            attachments: [],
            isBot: true,
        });
    }
    /**
     * Get the timestamp of the last logged message for a channel
     * Returns null if no log exists
     */
    getLastTimestamp(channelId) {
        const logPath = join(this.workingDir, channelId, "log.jsonl");
        if (!existsSync(logPath)) {
            return null;
        }
        try {
            const content = readFileSync(logPath, "utf-8");
            const lines = content.trim().split("\n");
            if (lines.length === 0 || lines[0] === "") {
                return null;
            }
            const lastLine = lines[lines.length - 1];
            const message = JSON.parse(lastLine);
            return message.ts;
        }
        catch {
            return null;
        }
    }
    /**
     * Process the download queue in the background
     */
    async processDownloadQueue() {
        if (this.isDownloading || this.pendingDownloads.length === 0)
            return;
        this.isDownloading = true;
        while (this.pendingDownloads.length > 0) {
            const item = this.pendingDownloads.shift();
            if (!item)
                break;
            try {
                await this.downloadAttachment(item.localPath, item.url);
                // Success - could add success logging here if we have context
            }
            catch (error) {
                const errorMsg = error instanceof Error ? error.message : String(error);
                log.logWarning(`Failed to download attachment`, `${item.localPath}: ${errorMsg}`);
            }
        }
        this.isDownloading = false;
    }
    /**
     * Download a single attachment
     */
    async downloadAttachment(localPath, url) {
        const filePath = join(this.workingDir, localPath);
        // Ensure directory exists
        const dir = join(this.workingDir, localPath.substring(0, localPath.lastIndexOf("/")));
        if (!existsSync(dir)) {
            mkdirSync(dir, { recursive: true });
        }
        const response = await fetch(url, {
            headers: {
                Authorization: `Bearer ${this.botToken}`,
            },
        });
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }
        const buffer = await response.arrayBuffer();
        await writeFile(filePath, Buffer.from(buffer));
    }
}
//# sourceMappingURL=store.js.map