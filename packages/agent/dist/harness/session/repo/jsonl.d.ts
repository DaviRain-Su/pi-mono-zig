import type { JsonlSessionCreateOptions, JsonlSessionListOptions, JsonlSessionMetadata, JsonlSessionRepoApi, Session } from "../../types.js";
export declare class JsonlSessionRepo implements JsonlSessionRepoApi {
    private sessionsRoot;
    constructor(options: {
        sessionsRoot: string;
    });
    private getSessionDir;
    private createSessionFilePath;
    create(options: JsonlSessionCreateOptions): Promise<Session<JsonlSessionMetadata>>;
    open(metadata: JsonlSessionMetadata): Promise<Session<JsonlSessionMetadata>>;
    list(options?: JsonlSessionListOptions): Promise<JsonlSessionMetadata[]>;
    delete(metadata: JsonlSessionMetadata): Promise<void>;
    fork(sourceMetadata: JsonlSessionMetadata, options: JsonlSessionCreateOptions & {
        entryId?: string;
        position?: "before" | "at";
        id?: string;
    }): Promise<Session<JsonlSessionMetadata>>;
    private listSessionDirs;
}
//# sourceMappingURL=jsonl.d.ts.map