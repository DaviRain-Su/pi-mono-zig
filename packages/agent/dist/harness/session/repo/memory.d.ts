import type { Session, SessionMetadata, SessionRepo } from "../../types.js";
export declare class InMemorySessionRepo implements SessionRepo<SessionMetadata, {
    id?: string;
}, void> {
    private sessions;
    create(options?: {
        id?: string;
    }): Promise<Session<SessionMetadata>>;
    open(metadata: SessionMetadata): Promise<Session<SessionMetadata>>;
    list(): Promise<SessionMetadata[]>;
    delete(metadata: SessionMetadata): Promise<void>;
    fork(sourceMetadata: SessionMetadata, options: {
        entryId?: string;
        position?: "before" | "at";
        id?: string;
    }): Promise<Session<SessionMetadata>>;
}
//# sourceMappingURL=memory.d.ts.map