import { InMemorySessionStorage } from "../storage/memory.js";
import { createSessionId, createTimestamp, getEntriesToFork, toSession } from "./shared.js";
export class InMemorySessionRepo {
    sessions = new Map();
    async create(options = {}) {
        const metadata = {
            id: options.id ?? createSessionId(),
            createdAt: createTimestamp(),
        };
        const storage = new InMemorySessionStorage({ metadata });
        const session = toSession(storage);
        this.sessions.set(metadata.id, session);
        return session;
    }
    async open(metadata) {
        const session = this.sessions.get(metadata.id);
        if (!session) {
            throw new Error(`Session not found: ${metadata.id}`);
        }
        return session;
    }
    async list() {
        return Promise.all([...this.sessions.values()].map((session) => session.getMetadata()));
    }
    async delete(metadata) {
        this.sessions.delete(metadata.id);
    }
    async fork(sourceMetadata, options) {
        const source = await this.open(sourceMetadata);
        const forkedEntries = await getEntriesToFork(source.getStorage(), options);
        const metadata = {
            id: options.id ?? createSessionId(),
            createdAt: createTimestamp(),
        };
        const leafId = forkedEntries[forkedEntries.length - 1]?.id ?? null;
        const storage = new InMemorySessionStorage({ metadata, entries: forkedEntries, leafId });
        const session = toSession(storage);
        this.sessions.set(metadata.id, session);
        return session;
    }
}
//# sourceMappingURL=memory.js.map