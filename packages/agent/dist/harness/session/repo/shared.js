import { v7 as uuidv7 } from "uuid";
import { Session } from "../session.js";
export function createSessionId() {
    return uuidv7();
}
export function createTimestamp() {
    return new Date().toISOString();
}
export function toSession(storage) {
    return new Session(storage);
}
export async function getEntriesToFork(storage, options) {
    if (!options.entryId)
        return storage.getEntries();
    const target = await storage.getEntry(options.entryId);
    if (!target) {
        throw new Error(`Entry ${options.entryId} not found`);
    }
    let effectiveLeafId;
    if ((options.position ?? "before") === "at") {
        effectiveLeafId = target.id;
    }
    else {
        if (target.type !== "message" || target.message.role !== "user") {
            throw new Error(`Entry ${options.entryId} is not a user message`);
        }
        effectiveLeafId = target.parentId;
    }
    return storage.getPathToRoot(effectiveLeafId);
}
//# sourceMappingURL=shared.js.map