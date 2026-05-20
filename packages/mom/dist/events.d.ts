import type { SlackBot } from "./slack.js";
export interface ImmediateEvent {
    type: "immediate";
    channelId: string;
    text: string;
}
export interface OneShotEvent {
    type: "one-shot";
    channelId: string;
    text: string;
    at: string;
}
export interface PeriodicEvent {
    type: "periodic";
    channelId: string;
    text: string;
    schedule: string;
    timezone: string;
}
export type MomEvent = ImmediateEvent | OneShotEvent | PeriodicEvent;
export declare class EventsWatcher {
    private eventsDir;
    private slack;
    private timers;
    private crons;
    private debounceTimers;
    private startTime;
    private watcher;
    private knownFiles;
    constructor(eventsDir: string, slack: SlackBot);
    /**
     * Start watching for events. Call this after SlackBot is ready.
     */
    start(): void;
    /**
     * Stop watching and cancel all scheduled events.
     */
    stop(): void;
    private debounce;
    private scanExisting;
    private handleFileChange;
    private handleDelete;
    private cancelScheduled;
    private handleFile;
    private parseEvent;
    private handleImmediate;
    private handleOneShot;
    private handlePeriodic;
    private execute;
    private deleteFile;
    private sleep;
}
/**
 * Create and start an events watcher.
 */
export declare function createEventsWatcher(workspaceDir: string, slack: SlackBot): EventsWatcher;
//# sourceMappingURL=events.d.ts.map