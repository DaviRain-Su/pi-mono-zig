import type { SessionMetadata, SessionStorage, SessionTreeEntry } from "../../types.js";
import { Session } from "../session.js";
export declare function createSessionId(): string;
export declare function createTimestamp(): string;
export declare function toSession<TMetadata extends SessionMetadata>(storage: SessionStorage<TMetadata>): Session<TMetadata>;
export declare function getEntriesToFork(storage: SessionStorage, options: {
    entryId?: string;
    position?: "before" | "at";
}): Promise<SessionTreeEntry[]>;
//# sourceMappingURL=shared.d.ts.map