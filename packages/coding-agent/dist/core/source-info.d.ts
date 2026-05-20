import type { PathMetadata } from "./package-manager.js";
export type SourceScope = "user" | "project" | "temporary";
export type SourceOrigin = "package" | "top-level";
export interface SourceProvenanceBinding {
    lockEntryKey: string;
    sourceIdentity: string;
    packageRoot: string;
    packageRootSha256: string;
    artifactSha256?: string;
}
export interface SourceInfo {
    path: string;
    source: string;
    scope: SourceScope;
    origin: SourceOrigin;
    baseDir?: string;
    provenance?: SourceProvenanceBinding;
}
export declare function createSourceInfo(path: string, metadata: PathMetadata): SourceInfo;
export declare function createSyntheticSourceInfo(path: string, options: {
    source: string;
    scope?: SourceScope;
    origin?: SourceOrigin;
    baseDir?: string;
}): SourceInfo;
//# sourceMappingURL=source-info.d.ts.map