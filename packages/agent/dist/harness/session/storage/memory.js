import { randomUUID } from "node:crypto";
import { v7 as uuidv7 } from "uuid";
function updateLabelCache(labelsById, entry) {
    if (entry.type !== "label")
        return;
    const label = entry.label?.trim();
    if (label) {
        labelsById.set(entry.targetId, label);
    }
    else {
        labelsById.delete(entry.targetId);
    }
}
function buildLabelsById(entries) {
    const labelsById = new Map();
    for (const entry of entries) {
        updateLabelCache(labelsById, entry);
    }
    return labelsById;
}
function generateEntryId(byId) {
    for (let i = 0; i < 100; i++) {
        const id = randomUUID().slice(0, 8);
        if (!byId.has(id))
            return id;
    }
    return randomUUID();
}
export class InMemorySessionStorage {
    metadata;
    entries;
    byId;
    labelsById;
    leafId;
    constructor(options) {
        this.entries = options?.entries ? [...options.entries] : [];
        this.byId = new Map(this.entries.map((entry) => [entry.id, entry]));
        this.labelsById = buildLabelsById(this.entries);
        this.leafId = options?.leafId ?? this.entries[this.entries.length - 1]?.id ?? null;
        if (this.leafId !== null && !this.byId.has(this.leafId)) {
            throw new Error(`Entry ${this.leafId} not found`);
        }
        this.metadata = options?.metadata ?? { id: uuidv7(), createdAt: new Date().toISOString() };
    }
    async getMetadata() {
        return this.metadata;
    }
    async getLeafId() {
        return this.leafId;
    }
    async setLeafId(leafId) {
        if (leafId !== null && !this.byId.has(leafId)) {
            throw new Error(`Entry ${leafId} not found`);
        }
        this.leafId = leafId;
    }
    async createEntryId() {
        return generateEntryId(this.byId);
    }
    async appendEntry(entry) {
        this.entries.push(entry);
        this.byId.set(entry.id, entry);
        updateLabelCache(this.labelsById, entry);
        this.leafId = entry.id;
    }
    async getEntry(id) {
        return this.byId.get(id);
    }
    async findEntries(type) {
        return this.entries.filter((entry) => entry.type === type);
    }
    async getLabel(id) {
        return this.labelsById.get(id);
    }
    async getPathToRoot(leafId) {
        if (leafId === null)
            return [];
        const path = [];
        let current = this.byId.get(leafId);
        while (current) {
            path.unshift(current);
            current = current.parentId ? this.byId.get(current.parentId) : undefined;
        }
        return path;
    }
    async getEntries() {
        return [...this.entries];
    }
}
//# sourceMappingURL=memory.js.map