import { SocketModeClient } from "@slack/socket-mode";
import { WebClient } from "@slack/web-api";
import { appendFileSync, existsSync, mkdirSync, readFileSync } from "fs";
import { basename, join } from "path";
import * as log from "./log.js";
class ChannelQueue {
    queue = [];
    processing = false;
    enqueue(work) {
        this.queue.push(work);
        this.processNext();
    }
    size() {
        return this.queue.length;
    }
    async processNext() {
        if (this.processing || this.queue.length === 0)
            return;
        this.processing = true;
        const work = this.queue.shift();
        try {
            await work();
        }
        catch (err) {
            log.logWarning("Queue error", err instanceof Error ? err.message : String(err));
        }
        this.processing = false;
        this.processNext();
    }
}
// ============================================================================
// SlackBot
// ============================================================================
export class SlackBot {
    socketClient;
    webClient;
    handler;
    workingDir;
    store;
    botUserId = null;
    startupTs = null; // Messages older than this are just logged, not processed
    users = new Map();
    channels = new Map();
    queues = new Map();
    constructor(handler, config) {
        this.handler = handler;
        this.workingDir = config.workingDir;
        this.store = config.store;
        this.socketClient = new SocketModeClient({ appToken: config.appToken });
        this.webClient = new WebClient(config.botToken);
    }
    // ==========================================================================
    // Public API
    // ==========================================================================
    async start() {
        const auth = await this.webClient.auth.test();
        this.botUserId = auth.user_id;
        await Promise.all([this.fetchUsers(), this.fetchChannels()]);
        log.logInfo(`Loaded ${this.channels.size} channels, ${this.users.size} users`);
        await this.backfillAllChannels();
        this.setupEventHandlers();
        await this.socketClient.start();
        // Record startup time - messages older than this are just logged, not processed
        this.startupTs = (Date.now() / 1000).toFixed(6);
        log.logConnected();
    }
    getUser(userId) {
        return this.users.get(userId);
    }
    getChannel(channelId) {
        return this.channels.get(channelId);
    }
    getAllUsers() {
        return Array.from(this.users.values());
    }
    getAllChannels() {
        return Array.from(this.channels.values());
    }
    async postMessage(channel, text) {
        const result = await this.webClient.chat.postMessage({ channel, text });
        return result.ts;
    }
    async updateMessage(channel, ts, text) {
        await this.webClient.chat.update({ channel, ts, text });
    }
    async deleteMessage(channel, ts) {
        await this.webClient.chat.delete({ channel, ts });
    }
    async postInThread(channel, threadTs, text) {
        const result = await this.webClient.chat.postMessage({ channel, thread_ts: threadTs, text });
        return result.ts;
    }
    async uploadFile(channel, filePath, title) {
        const fileName = title || basename(filePath);
        const fileContent = readFileSync(filePath);
        await this.webClient.files.uploadV2({
            channel_id: channel,
            file: fileContent,
            filename: fileName,
            title: fileName,
        });
    }
    /**
     * Log a message to log.jsonl (SYNC)
     * This is the ONLY place messages are written to log.jsonl
     */
    logToFile(channel, entry) {
        const dir = join(this.workingDir, channel);
        if (!existsSync(dir))
            mkdirSync(dir, { recursive: true });
        appendFileSync(join(dir, "log.jsonl"), `${JSON.stringify(entry)}\n`);
    }
    /**
     * Log a bot response to log.jsonl
     */
    logBotResponse(channel, text, ts) {
        this.logToFile(channel, {
            date: new Date().toISOString(),
            ts,
            user: "bot",
            text,
            attachments: [],
            isBot: true,
        });
    }
    // ==========================================================================
    // Events Integration
    // ==========================================================================
    /**
     * Enqueue an event for processing. Always queues (no "already working" rejection).
     * Returns true if enqueued, false if queue is full (max 5).
     */
    enqueueEvent(event) {
        const queue = this.getQueue(event.channel);
        if (queue.size() >= 5) {
            log.logWarning(`Event queue full for ${event.channel}, discarding: ${event.text.substring(0, 50)}`);
            return false;
        }
        log.logInfo(`Enqueueing event for ${event.channel}: ${event.text.substring(0, 50)}`);
        queue.enqueue(() => this.handler.handleEvent(event, this, true));
        return true;
    }
    // ==========================================================================
    // Private - Event Handlers
    // ==========================================================================
    getQueue(channelId) {
        let queue = this.queues.get(channelId);
        if (!queue) {
            queue = new ChannelQueue();
            this.queues.set(channelId, queue);
        }
        return queue;
    }
    setupEventHandlers() {
        // Channel @mentions
        this.socketClient.on("app_mention", ({ event, ack }) => {
            const e = event;
            // Skip DMs (handled by message event)
            if (e.channel.startsWith("D")) {
                ack();
                return;
            }
            const slackEvent = {
                type: "mention",
                channel: e.channel,
                ts: e.ts,
                user: e.user,
                text: e.text.replace(/<@[A-Z0-9]+>/gi, "").trim(),
                files: e.files,
            };
            // SYNC: Log to log.jsonl (ALWAYS, even for old messages)
            // Also downloads attachments in background and stores local paths
            slackEvent.attachments = this.logUserMessage(slackEvent);
            // Only trigger processing for messages AFTER startup (not replayed old messages)
            if (this.startupTs && e.ts < this.startupTs) {
                log.logInfo(`[${e.channel}] Logged old message (pre-startup), not triggering: ${slackEvent.text.substring(0, 30)}`);
                ack();
                return;
            }
            // Check for stop command - execute immediately, don't queue!
            if (slackEvent.text.toLowerCase().trim() === "stop") {
                if (this.handler.isRunning(e.channel)) {
                    this.handler.handleStop(e.channel, this); // Don't await, don't queue
                }
                else {
                    this.postMessage(e.channel, "_Nothing running_");
                }
                ack();
                return;
            }
            // SYNC: Check if busy
            if (this.handler.isRunning(e.channel)) {
                this.postMessage(e.channel, "_Already working. Say `@mom stop` to cancel._");
            }
            else {
                this.getQueue(e.channel).enqueue(() => this.handler.handleEvent(slackEvent, this));
            }
            ack();
        });
        // All messages (for logging) + DMs (for triggering)
        this.socketClient.on("message", ({ event, ack }) => {
            const e = event;
            // Skip bot messages, edits, etc.
            if (e.bot_id || !e.user || e.user === this.botUserId) {
                ack();
                return;
            }
            if (e.subtype !== undefined && e.subtype !== "file_share") {
                ack();
                return;
            }
            if (!e.text && (!e.files || e.files.length === 0)) {
                ack();
                return;
            }
            const isDM = e.channel_type === "im";
            const isBotMention = e.text?.includes(`<@${this.botUserId}>`);
            // Skip channel @mentions - already handled by app_mention event
            if (!isDM && isBotMention) {
                ack();
                return;
            }
            const slackEvent = {
                type: isDM ? "dm" : "mention",
                channel: e.channel,
                ts: e.ts,
                user: e.user,
                text: (e.text || "").replace(/<@[A-Z0-9]+>/gi, "").trim(),
                files: e.files,
            };
            // SYNC: Log to log.jsonl (ALL messages - channel chatter and DMs)
            // Also downloads attachments in background and stores local paths
            slackEvent.attachments = this.logUserMessage(slackEvent);
            // Only trigger processing for messages AFTER startup (not replayed old messages)
            if (this.startupTs && e.ts < this.startupTs) {
                log.logInfo(`[${e.channel}] Skipping old message (pre-startup): ${slackEvent.text.substring(0, 30)}`);
                ack();
                return;
            }
            // Only trigger handler for DMs
            if (isDM) {
                // Check for stop command - execute immediately, don't queue!
                if (slackEvent.text.toLowerCase().trim() === "stop") {
                    if (this.handler.isRunning(e.channel)) {
                        this.handler.handleStop(e.channel, this); // Don't await, don't queue
                    }
                    else {
                        this.postMessage(e.channel, "_Nothing running_");
                    }
                    ack();
                    return;
                }
                if (this.handler.isRunning(e.channel)) {
                    this.postMessage(e.channel, "_Already working. Say `stop` to cancel._");
                }
                else {
                    this.getQueue(e.channel).enqueue(() => this.handler.handleEvent(slackEvent, this));
                }
            }
            ack();
        });
    }
    /**
     * Log a user message to log.jsonl (SYNC)
     * Downloads attachments in background via store
     */
    logUserMessage(event) {
        const user = this.users.get(event.user);
        // Process attachments - queues downloads in background
        const attachments = event.files ? this.store.processAttachments(event.channel, event.files, event.ts) : [];
        this.logToFile(event.channel, {
            date: new Date(parseFloat(event.ts) * 1000).toISOString(),
            ts: event.ts,
            user: event.user,
            userName: user?.userName,
            displayName: user?.displayName,
            text: event.text,
            attachments,
            isBot: false,
        });
        return attachments;
    }
    // ==========================================================================
    // Private - Backfill
    // ==========================================================================
    getExistingTimestamps(channelId) {
        const logPath = join(this.workingDir, channelId, "log.jsonl");
        const timestamps = new Set();
        if (!existsSync(logPath))
            return timestamps;
        const content = readFileSync(logPath, "utf-8");
        const lines = content.trim().split("\n").filter(Boolean);
        for (const line of lines) {
            try {
                const entry = JSON.parse(line);
                if (entry.ts)
                    timestamps.add(entry.ts);
            }
            catch { }
        }
        return timestamps;
    }
    async backfillChannel(channelId) {
        const existingTs = this.getExistingTimestamps(channelId);
        // Find the biggest ts in log.jsonl
        let latestTs;
        for (const ts of existingTs) {
            if (!latestTs || parseFloat(ts) > parseFloat(latestTs))
                latestTs = ts;
        }
        const allMessages = [];
        let cursor;
        let pageCount = 0;
        const maxPages = 3;
        do {
            const result = await this.webClient.conversations.history({
                channel: channelId,
                oldest: latestTs, // Only fetch messages newer than what we have
                inclusive: false,
                limit: 1000,
                cursor,
            });
            if (result.messages) {
                allMessages.push(...result.messages);
            }
            cursor = result.response_metadata?.next_cursor;
            pageCount++;
        } while (cursor && pageCount < maxPages);
        // Filter: include mom's messages, exclude other bots, skip already logged
        const relevantMessages = allMessages.filter((msg) => {
            if (!msg.ts || existingTs.has(msg.ts))
                return false; // Skip duplicates
            if (msg.user === this.botUserId)
                return true;
            if (msg.bot_id)
                return false;
            if (msg.subtype !== undefined && msg.subtype !== "file_share")
                return false;
            if (!msg.user)
                return false;
            if (!msg.text && (!msg.files || msg.files.length === 0))
                return false;
            return true;
        });
        // Reverse to chronological order
        relevantMessages.reverse();
        // Log each message to log.jsonl
        for (const msg of relevantMessages) {
            const isMomMessage = msg.user === this.botUserId;
            const user = this.users.get(msg.user);
            // Strip @mentions from text (same as live messages)
            const text = (msg.text || "").replace(/<@[A-Z0-9]+>/gi, "").trim();
            // Process attachments - queues downloads in background
            const attachments = msg.files ? this.store.processAttachments(channelId, msg.files, msg.ts) : [];
            this.logToFile(channelId, {
                date: new Date(parseFloat(msg.ts) * 1000).toISOString(),
                ts: msg.ts,
                user: isMomMessage ? "bot" : msg.user,
                userName: isMomMessage ? undefined : user?.userName,
                displayName: isMomMessage ? undefined : user?.displayName,
                text,
                attachments,
                isBot: isMomMessage,
            });
        }
        return relevantMessages.length;
    }
    async backfillAllChannels() {
        const startTime = Date.now();
        // Only backfill channels that already have a log.jsonl (mom has interacted with them before)
        const channelsToBackfill = [];
        for (const [channelId, channel] of this.channels) {
            const logPath = join(this.workingDir, channelId, "log.jsonl");
            if (existsSync(logPath)) {
                channelsToBackfill.push([channelId, channel]);
            }
        }
        log.logBackfillStart(channelsToBackfill.length);
        let totalMessages = 0;
        for (const [channelId, channel] of channelsToBackfill) {
            try {
                const count = await this.backfillChannel(channelId);
                if (count > 0)
                    log.logBackfillChannel(channel.name, count);
                totalMessages += count;
            }
            catch (error) {
                log.logWarning(`Failed to backfill #${channel.name}`, String(error));
            }
        }
        const durationMs = Date.now() - startTime;
        log.logBackfillComplete(totalMessages, durationMs);
    }
    // ==========================================================================
    // Private - Fetch Users/Channels
    // ==========================================================================
    async fetchUsers() {
        let cursor;
        do {
            const result = await this.webClient.users.list({ limit: 200, cursor });
            const members = result.members;
            if (members) {
                for (const u of members) {
                    if (u.id && u.name && !u.deleted) {
                        this.users.set(u.id, { id: u.id, userName: u.name, displayName: u.real_name || u.name });
                    }
                }
            }
            cursor = result.response_metadata?.next_cursor;
        } while (cursor);
    }
    async fetchChannels() {
        // Fetch public/private channels
        let cursor;
        do {
            const result = await this.webClient.conversations.list({
                types: "public_channel,private_channel",
                exclude_archived: true,
                limit: 200,
                cursor,
            });
            const channels = result.channels;
            if (channels) {
                for (const c of channels) {
                    if (c.id && c.name && c.is_member) {
                        this.channels.set(c.id, { id: c.id, name: c.name });
                    }
                }
            }
            cursor = result.response_metadata?.next_cursor;
        } while (cursor);
        // Also fetch DM channels (IMs)
        cursor = undefined;
        do {
            const result = await this.webClient.conversations.list({
                types: "im",
                limit: 200,
                cursor,
            });
            const ims = result.channels;
            if (ims) {
                for (const im of ims) {
                    if (im.id) {
                        // Use user's name as channel name for DMs
                        const user = im.user ? this.users.get(im.user) : undefined;
                        const name = user ? `DM:${user.userName}` : `DM:${im.id}`;
                        this.channels.set(im.id, { id: im.id, name });
                    }
                }
            }
            cursor = result.response_metadata?.next_cursor;
        } while (cursor);
    }
}
//# sourceMappingURL=slack.js.map