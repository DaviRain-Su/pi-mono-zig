import { randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { createInterface } from "node:readline";
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
function headerToSessionMetadata(header, path) {
    return {
        id: header.id,
        createdAt: header.timestamp,
        cwd: header.cwd,
        path,
        parentSessionPath: header.parentSession,
    };
}
export async function loadJsonlSessionMetadata(filePath) {
    const stream = createReadStream(filePath, { encoding: "utf8" });
    const lines = createInterface({ input: stream, crlfDelay: Infinity });
    try {
        for await (const line of lines) {
            if (!line.trim())
                break;
            try {
                const header = JSON.parse(line);
                return headerToSessionMetadata(header, resolve(filePath));
            }
            catch {
                throw new Error(`Invalid JSONL session file ${filePath}: first line is not a valid session header`);
            }
        }
        throw new Error(`Invalid JSONL session file ${filePath}: missing session header`);
    }
    finally {
        lines.close();
        stream.destroy();
    }
}
async function loadJsonlStorage(filePath) {
    const content = await readFile(filePath, "utf8");
    const lines = content.split("\n").filter((line) => line.trim());
    if (lines.length === 0) {
        throw new Error(`Invalid JSONL session file ${filePath}: missing session header`);
    }
    let header;
    try {
        header = JSON.parse(lines[0]);
    }
    catch {
        throw new Error(`Invalid JSONL session file ${filePath}: first line is not a valid session header`);
    }
    const entries = [];
    let leafId = null;
    for (const line of lines.slice(1)) {
        try {
            const entry = JSON.parse(line);
            entries.push(entry);
            leafId = entry.id;
        }
        catch {
            // ignore malformed entry lines
        }
    }
    return { header, entries, leafId };
}
export class JsonlSessionStorage {
    filePath;
    metadata;
    entries;
    byId;
    labelsById;
    currentLeafId;
    constructor(filePath, header, entries, leafId) {
        this.filePath = resolve(filePath);
        this.metadata = headerToSessionMetadata(header, this.filePath);
        this.entries = entries;
        this.byId = new Map(entries.map((entry) => [entry.id, entry]));
        this.labelsById = buildLabelsById(entries);
        this.currentLeafId = leafId;
    }
    static async open(filePath) {
        const resolvedPath = resolve(filePath);
        const loaded = await loadJsonlStorage(resolvedPath);
        return new JsonlSessionStorage(resolvedPath, loaded.header, loaded.entries, loaded.leafId);
    }
    static async create(filePath, options) {
        const resolvedPath = resolve(filePath);
        const header = {
            type: "session",
            version: 3,
            id: options.sessionId,
            timestamp: new Date().toISOString(),
            cwd: options.cwd,
            parentSession: options.parentSessionPath,
        };
        await mkdir(dirname(resolvedPath), { recursive: true });
        await writeFile(resolvedPath, `${JSON.stringify(header)}\n`);
        return new JsonlSessionStorage(resolvedPath, header, [], null);
    }
    async getMetadata() {
        return this.metadata;
    }
    async getLeafId() {
        return this.currentLeafId;
    }
    async setLeafId(leafId) {
        if (leafId !== null && !this.byId.has(leafId)) {
            throw new Error(`Entry ${leafId} not found`);
        }
        this.currentLeafId = leafId;
    }
    async createEntryId() {
        return generateEntryId(this.byId);
    }
    async appendEntry(entry) {
        await appendFile(this.filePath, `${JSON.stringify(entry)}\n`);
        this.entries.push(entry);
        this.byId.set(entry.id, entry);
        updateLabelCache(this.labelsById, entry);
        this.currentLeafId = entry.id;
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
//# sourceMappingURL=jsonl.js.map