import { constants } from "node:fs";
import { access, mkdir, readdir, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import { JsonlSessionStorage, loadJsonlSessionMetadata } from "../storage/jsonl.js";
import { createSessionId, createTimestamp, getEntriesToFork, toSession } from "./shared.js";
async function exists(path) {
    try {
        await access(path, constants.F_OK);
        return true;
    }
    catch {
        return false;
    }
}
function encodeCwd(cwd) {
    return `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
}
export class JsonlSessionRepo {
    sessionsRoot;
    constructor(options) {
        this.sessionsRoot = resolve(options.sessionsRoot);
    }
    getSessionDir(cwd) {
        return join(this.sessionsRoot, encodeCwd(cwd));
    }
    createSessionFilePath(cwd, sessionId, timestamp) {
        return join(this.getSessionDir(cwd), `${timestamp.replace(/[:.]/g, "-")}_${sessionId}.jsonl`);
    }
    async create(options) {
        await mkdir(this.sessionsRoot, { recursive: true });
        const id = options.id ?? createSessionId();
        const createdAt = createTimestamp();
        const filePath = this.createSessionFilePath(options.cwd, id, createdAt);
        const storage = await JsonlSessionStorage.create(filePath, {
            cwd: options.cwd,
            sessionId: id,
            parentSessionPath: options.parentSessionPath,
        });
        return toSession(storage);
    }
    async open(metadata) {
        if (!(await exists(metadata.path))) {
            throw new Error(`Session not found: ${metadata.path}`);
        }
        const storage = await JsonlSessionStorage.open(metadata.path);
        return toSession(storage);
    }
    async list(options = {}) {
        const dirs = options.cwd ? [this.getSessionDir(options.cwd)] : await this.listSessionDirs();
        const sessions = [];
        for (const dir of dirs) {
            if (!(await exists(dir)))
                continue;
            const files = (await readdir(dir)).filter((file) => file.endsWith(".jsonl")).map((file) => join(dir, file));
            for (const filePath of files) {
                try {
                    sessions.push(await loadJsonlSessionMetadata(filePath));
                }
                catch {
                    // Ignore invalid session files when listing a directory.
                }
            }
        }
        sessions.sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());
        return sessions;
    }
    async delete(metadata) {
        await rm(metadata.path, { force: true });
    }
    async fork(sourceMetadata, options) {
        const source = await this.open(sourceMetadata);
        const forkedEntries = await getEntriesToFork(source.getStorage(), options);
        const id = options.id ?? createSessionId();
        const createdAt = createTimestamp();
        const storage = await JsonlSessionStorage.create(this.createSessionFilePath(options.cwd, id, createdAt), {
            cwd: options.cwd,
            sessionId: id,
            parentSessionPath: options.parentSessionPath ?? sourceMetadata.path,
        });
        for (const entry of forkedEntries) {
            await storage.appendEntry(entry);
        }
        return toSession(storage);
    }
    async listSessionDirs() {
        if (!(await exists(this.sessionsRoot)))
            return [];
        const entries = await readdir(this.sessionsRoot, { withFileTypes: true });
        return entries.filter((entry) => entry.isDirectory()).map((entry) => join(this.sessionsRoot, entry.name));
    }
}
//# sourceMappingURL=jsonl.js.map