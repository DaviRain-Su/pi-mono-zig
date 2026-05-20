/**
 * Context management for mom.
 *
 * Mom uses two files per channel:
 * - context.jsonl: Structured API messages for LLM context (same format as coding-agent sessions)
 * - log.jsonl: Human-readable channel history for grep (no tool results)
 *
 * This module provides:
 * - syncLogToSessionManager: Syncs messages from log.jsonl to SessionManager
 * - createMomSettingsManager: Creates a SettingsManager backed by workspace settings.json
 */
import { SettingsManager } from "@mariozechner/pi-coding-agent";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { dirname, join } from "path";
/**
 * Sync user messages from log.jsonl to SessionManager.
 *
 * This ensures that messages logged while mom wasn't running (channel chatter,
 * backfilled messages, messages while busy) are added to the LLM context.
 *
 * @param sessionManager - The SessionManager to sync to
 * @param channelDir - Path to channel directory containing log.jsonl
 * @param excludeSlackTs - Slack timestamp of current message (will be added via prompt(), not sync)
 * @returns Number of messages synced
 */
export function syncLogToSessionManager(sessionManager, channelDir, excludeSlackTs) {
    const logFile = join(channelDir, "log.jsonl");
    if (!existsSync(logFile))
        return 0;
    // Build set of existing message content from session
    const existingMessages = new Set();
    for (const entry of sessionManager.getEntries()) {
        if (entry.type === "message") {
            const msgEntry = entry;
            const msg = msgEntry.message;
            if (msg.role === "user" && msg.content !== undefined) {
                const content = msg.content;
                if (typeof content === "string") {
                    // Strip timestamp prefix for comparison (live messages have it, synced don't)
                    // Format: [YYYY-MM-DD HH:MM:SS+HH:MM] [username]: text
                    let normalized = content.replace(/^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}\] /, "");
                    // Strip attachments section
                    const attachmentsIdx = normalized.indexOf("\n\n<slack_attachments>\n");
                    if (attachmentsIdx !== -1) {
                        normalized = normalized.substring(0, attachmentsIdx);
                    }
                    existingMessages.add(normalized);
                }
                else if (Array.isArray(content)) {
                    for (const part of content) {
                        if (typeof part === "object" &&
                            part !== null &&
                            "type" in part &&
                            part.type === "text" &&
                            "text" in part) {
                            let normalized = part.text;
                            normalized = normalized.replace(/^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}\] /, "");
                            const attachmentsIdx = normalized.indexOf("\n\n<slack_attachments>\n");
                            if (attachmentsIdx !== -1) {
                                normalized = normalized.substring(0, attachmentsIdx);
                            }
                            existingMessages.add(normalized);
                        }
                    }
                }
            }
        }
    }
    // Read log.jsonl and find user messages not in context
    const logContent = readFileSync(logFile, "utf-8");
    const logLines = logContent.trim().split("\n").filter(Boolean);
    const newMessages = [];
    for (const line of logLines) {
        try {
            const logMsg = JSON.parse(line);
            const slackTs = logMsg.ts;
            const date = logMsg.date;
            if (!slackTs || !date)
                continue;
            // Skip the current message being processed (will be added via prompt())
            if (excludeSlackTs && slackTs === excludeSlackTs)
                continue;
            // Skip bot messages - added through agent flow
            if (logMsg.isBot)
                continue;
            // Build the message text as it would appear in context
            const messageText = `[${logMsg.userName || logMsg.user || "unknown"}]: ${logMsg.text || ""}`;
            // Skip if this exact message text is already in context
            if (existingMessages.has(messageText))
                continue;
            const msgTime = new Date(date).getTime() || Date.now();
            const userMessage = {
                role: "user",
                content: [{ type: "text", text: messageText }],
                timestamp: msgTime,
            };
            newMessages.push({ timestamp: msgTime, message: userMessage });
            existingMessages.add(messageText); // Track to avoid duplicates within this sync
        }
        catch {
            // Skip malformed lines
        }
    }
    if (newMessages.length === 0)
        return 0;
    // Sort by timestamp and add to session
    newMessages.sort((a, b) => a.timestamp - b.timestamp);
    for (const { message } of newMessages) {
        sessionManager.appendMessage(message);
    }
    return newMessages.length;
}
class WorkspaceSettingsStorage {
    settingsPath;
    constructor(workspaceDir) {
        this.settingsPath = join(workspaceDir, "settings.json");
    }
    withLock(scope, fn) {
        if (scope === "project") {
            // Mom stores all settings in a single workspace file.
            fn(undefined);
            return;
        }
        const current = existsSync(this.settingsPath) ? readFileSync(this.settingsPath, "utf-8") : undefined;
        const next = fn(current);
        if (next === undefined) {
            return;
        }
        const dir = dirname(this.settingsPath);
        if (!existsSync(dir)) {
            mkdirSync(dir, { recursive: true });
        }
        writeFileSync(this.settingsPath, next, "utf-8");
    }
}
export function createMomSettingsManager(workspaceDir) {
    return SettingsManager.fromStorage(new WorkspaceSettingsStorage(workspaceDir));
}
//# sourceMappingURL=context.js.map