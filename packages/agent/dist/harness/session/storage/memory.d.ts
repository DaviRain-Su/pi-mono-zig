import type { SessionMetadata, SessionStorage, SessionTreeEntry } from "../../types.js";
export declare class InMemorySessionStorage implements SessionStorage {
    private readonly metadata;
    private entries;
    private byId;
    private labelsById;
    private leafId;
    constructor(options?: {
        entries?: SessionTreeEntry[];
        leafId?: string | null;
        metadata?: SessionMetadata;
    });
    getMetadata(): Promise<SessionMetadata>;
    getLeafId(): Promise<string | null>;
    setLeafId(leafId: string | null): Promise<void>;
    createEntryId(): Promise<string>;
    appendEntry(entry: SessionTreeEntry): Promise<void>;
    getEntry(id: string): Promise<SessionTreeEntry | undefined>;
    findEntries<TType extends SessionTreeEntry["type"]>(type: TType): Promise<Array<Extract<SessionTreeEntry, {
        type: TType;
    }>>>;
    getLabel(id: string): Promise<string | undefined>;
    getPathToRoot(leafId: string | null): Promise<SessionTreeEntry[]>;
    getEntries(): Promise<SessionTreeEntry[]>;
}
//# sourceMappingURL=memory.d.ts.map