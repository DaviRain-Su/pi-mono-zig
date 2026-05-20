import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync, } from "node:fs";
import { basename, dirname, join, relative, sep } from "node:path";
import { adaptProvenanceDiagnosticToEnvelope, attachDiagnosticEnvelope, } from "./diagnostics.js";
export const EXTENSION_PROVENANCE_LOCKFILE_NAME = "extensions.lock.json";
export const EXTENSION_PROVENANCE_LOCK_SCHEMA_VERSION = "pi-extension-lock.v0";
const UNSUPPORTED_TRUST_SURFACE_FIELDS = new Set([
    "signature",
    "publisher",
    "marketplace",
    "approvalUi",
    "remoteWasmUrl",
]);
const HOST_NOISE_DIRS = new Set([
    ".git",
    ".hg",
    ".svn",
    ".pi",
    ".cache",
    ".npm",
    ".yarn",
    ".pnpm-store",
    ".parcel-cache",
    ".turbo",
]);
const HOST_NOISE_FILES = new Set([
    EXTENSION_PROVENANCE_LOCKFILE_NAME,
    "package-lock.json",
    "npm-shrinkwrap.json",
    "pnpm-lock.yaml",
    "yarn.lock",
    "bun.lock",
    "bun.lockb",
    ".DS_Store",
]);
function toPosixPath(value) {
    return value.split(sep).join("/");
}
function isSha256(value) {
    return /^[a-f0-9]{64}$/.test(value);
}
function expectObject(value, path) {
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
        throw new Error(`${path}: expected object`);
    }
    return value;
}
function requiredString(object, path, field) {
    if (!Object.hasOwn(object, field)) {
        throw new Error(`${path}.${field}: missing required field`);
    }
    const value = object[field];
    if (typeof value !== "string") {
        throw new Error(`${path}.${field}: expected string`);
    }
    return value;
}
function optionalString(object, path, field) {
    if (!Object.hasOwn(object, field)) {
        return undefined;
    }
    const value = object[field];
    if (typeof value !== "string") {
        throw new Error(`${path}.${field}: expected string`);
    }
    return value;
}
function scanUnsupportedTrustSurface(value, path) {
    if (value === null || typeof value !== "object") {
        return undefined;
    }
    if (Array.isArray(value)) {
        for (const [index, entry] of value.entries()) {
            const nested = scanUnsupportedTrustSurface(entry, `${path}[${index}]`);
            if (nested)
                return nested;
        }
        return undefined;
    }
    for (const [key, entry] of Object.entries(value)) {
        const fieldPath = `${path}.${key}`;
        if (UNSUPPORTED_TRUST_SURFACE_FIELDS.has(key)) {
            return fieldPath;
        }
        const nested = scanUnsupportedTrustSurface(entry, fieldPath);
        if (nested)
            return nested;
    }
    return undefined;
}
function validateSource(value, path) {
    const object = expectObject(value, path);
    const type = requiredString(object, path, "type");
    if (type !== "local" && type !== "npm" && type !== "git") {
        throw new Error(`${path}.type: unsupported source type`);
    }
    const identity = requiredString(object, path, "identity");
    const specifier = optionalString(object, path, "specifier");
    return specifier === undefined ? { type, identity } : { type, identity, specifier };
}
function validateManifest(value, path) {
    const object = expectObject(value, path);
    const kind = requiredString(object, path, "kind");
    if (kind !== "typescript-package" && kind !== "wasm-extension" && kind !== "resource-package") {
        throw new Error(`${path}.kind: unsupported manifest kind`);
    }
    return {
        kind,
        packageName: optionalString(object, path, "packageName"),
        packageVersion: optionalString(object, path, "packageVersion"),
        schemaVersion: optionalString(object, path, "schemaVersion"),
        id: optionalString(object, path, "id"),
        name: optionalString(object, path, "name"),
        version: optionalString(object, path, "version"),
        toolId: optionalString(object, path, "toolId"),
    };
}
function validateArtifact(value, path) {
    const object = expectObject(value, path);
    const kind = requiredString(object, path, "kind");
    if (kind !== "wasm-component") {
        throw new Error(`${path}.kind: unsupported artifact kind`);
    }
    const artifactPath = requiredString(object, path, "path");
    const absolutePath = requiredString(object, path, "absolutePath");
    const sha256 = requiredString(object, path, "sha256");
    if (!isSha256(sha256)) {
        throw new Error(`${path}.sha256: expected lowercase SHA-256 hex`);
    }
    return { kind, path: artifactPath, absolutePath, sha256 };
}
function validateDigests(value, path) {
    const object = expectObject(value, path);
    const packageRootSha256 = requiredString(object, path, "packageRootSha256");
    if (!isSha256(packageRootSha256)) {
        throw new Error(`${path}.packageRootSha256: expected lowercase SHA-256 hex`);
    }
    return { packageRootSha256 };
}
function validateEntry(value, path) {
    const object = expectObject(value, path);
    const key = requiredString(object, path, "key");
    const scope = requiredString(object, path, "scope");
    if (scope !== "user" && scope !== "project") {
        throw new Error(`${path}.scope: unsupported scope`);
    }
    const source = validateSource(object.source, `${path}.source`);
    const manifest = validateManifest(object.manifest, `${path}.manifest`);
    const packageRoot = requiredString(object, path, "packageRoot");
    const manifestPath = requiredString(object, path, "manifestPath");
    const artifact = Object.hasOwn(object, "artifact")
        ? validateArtifact(object.artifact, `${path}.artifact`)
        : undefined;
    const digests = validateDigests(object.digests, `${path}.digests`);
    return artifact === undefined
        ? { key, scope, source, manifest, packageRoot, manifestPath, digests }
        : { key, scope, source, manifest, packageRoot, manifestPath, artifact, digests };
}
function createDiagnostic(options) {
    const diagnostic = {
        category: options.category,
        scope: options.scope,
        lockfilePath: options.lockfilePath,
        phase: options.phase,
        source: options.source,
        path: options.path,
        expected: options.expected,
        actual: options.actual,
        message: options.message,
        recoveryHint: "Run install or update for the package to refresh trusted extension provenance.",
    };
    return attachDiagnosticEnvelope(diagnostic, adaptProvenanceDiagnosticToEnvelope(diagnostic));
}
export function getExtensionProvenanceLockfilePath(options) {
    return options.scope === "user"
        ? join(options.agentDir, EXTENSION_PROVENANCE_LOCKFILE_NAME)
        : join(options.cwd, options.configDirName, EXTENSION_PROVENANCE_LOCKFILE_NAME);
}
export function makeExtensionProvenanceEntryKey(source) {
    return `${source.type}:${source.identity}`;
}
export function readExtensionProvenanceLockfile(options) {
    if (!existsSync(options.lockfilePath)) {
        return { entries: new Map() };
    }
    let parsed;
    try {
        parsed = JSON.parse(readFileSync(options.lockfilePath, "utf-8"));
    }
    catch (error) {
        const suffix = error instanceof Error && error.message ? `: ${error.message}` : "";
        return {
            entries: new Map(),
            diagnostic: createDiagnostic({
                category: "malformed_lockfile",
                scope: options.scope,
                lockfilePath: options.lockfilePath,
                phase: options.phase,
                path: "$",
                message: `Malformed extension provenance lockfile${suffix}`,
            }),
        };
    }
    try {
        const unsupportedPath = scanUnsupportedTrustSurface(parsed, "$");
        if (unsupportedPath) {
            throw new Error(`${unsupportedPath}: unsupported v0 trust surface`);
        }
        const object = expectObject(parsed, "$");
        const schemaVersion = requiredString(object, "$", "schemaVersion");
        if (schemaVersion !== EXTENSION_PROVENANCE_LOCK_SCHEMA_VERSION) {
            return {
                entries: new Map(),
                diagnostic: createDiagnostic({
                    category: "malformed_lockfile",
                    scope: options.scope,
                    lockfilePath: options.lockfilePath,
                    phase: options.phase,
                    path: "$.schemaVersion",
                    expected: EXTENSION_PROVENANCE_LOCK_SCHEMA_VERSION,
                    actual: schemaVersion,
                    message: `Malformed extension provenance lockfile: $.schemaVersion: unsupported schema version "${schemaVersion}"; expected ${EXTENSION_PROVENANCE_LOCK_SCHEMA_VERSION}`,
                }),
            };
        }
        if (!Array.isArray(object.entries)) {
            throw new Error("$.entries: expected array");
        }
        const entries = new Map();
        for (const [index, rawEntry] of object.entries.entries()) {
            const entry = validateEntry(rawEntry, `$.entries[${index}]`);
            entries.set(entry.key, entry);
        }
        return { entries };
    }
    catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        const path = message.match(/^(\$[^:]*):/)?.[1] ?? "$";
        return {
            entries: new Map(),
            diagnostic: createDiagnostic({
                category: "malformed_lockfile",
                scope: options.scope,
                lockfilePath: options.lockfilePath,
                phase: options.phase,
                path,
                message: `Malformed extension provenance lockfile: ${message}`,
            }),
        };
    }
}
export function createMissingLockfileDiagnostic(options) {
    return createDiagnostic({
        category: "missing_lockfile",
        scope: options.scope,
        source: options.source,
        lockfilePath: options.lockfilePath,
        phase: "resolve",
        message: `Missing extension provenance lockfile for ${options.scope} package source ${options.source}`,
    });
}
export function createMissingLockEntryDiagnostic(options) {
    return createDiagnostic({
        category: "missing_lock_entry",
        scope: options.scope,
        source: options.source,
        lockfilePath: options.lockfilePath,
        phase: "resolve",
        message: `Missing extension provenance lock entry for ${options.scope} package source ${options.source}`,
    });
}
export function serializeExtensionProvenanceLockfile(entries) {
    const sortedEntries = Array.from(entries).sort((a, b) => a.key.localeCompare(b.key));
    const lockfile = {
        schemaVersion: EXTENSION_PROVENANCE_LOCK_SCHEMA_VERSION,
        entries: sortedEntries.map(normalizeEntryForSerialization),
    };
    return `${JSON.stringify(lockfile, null, 2)}\n`;
}
function writeLockfileAtomically(lockfilePath, serialized) {
    const dir = dirname(lockfilePath);
    mkdirSync(dir, { recursive: true });
    const tempPath = join(dir, `.${basename(lockfilePath)}.${process.pid}.${Date.now()}.tmp`);
    try {
        writeFileSync(tempPath, serialized, "utf-8");
        renameSync(tempPath, lockfilePath);
    }
    catch (error) {
        rmSync(tempPath, { force: true });
        throw error;
    }
}
export function writeExtensionProvenanceLockEntry(options) {
    const current = readExtensionProvenanceLockfile({
        scope: options.scope,
        lockfilePath: options.lockfilePath,
        phase: "write",
    });
    if (current.diagnostic) {
        throw new Error(current.diagnostic.message);
    }
    current.entries.set(options.entry.key, normalizeEntryForSerialization(options.entry));
    const serialized = serializeExtensionProvenanceLockfile(current.entries.values());
    writeLockfileAtomically(options.lockfilePath, serialized);
}
export function removeExtensionProvenanceLockEntry(options) {
    if (!existsSync(options.lockfilePath)) {
        return false;
    }
    const current = readExtensionProvenanceLockfile({
        scope: options.scope,
        lockfilePath: options.lockfilePath,
        phase: "write",
    });
    if (current.diagnostic) {
        throw new Error(current.diagnostic.message);
    }
    const removed = current.entries.delete(options.key);
    if (!removed) {
        return false;
    }
    const serialized = serializeExtensionProvenanceLockfile(current.entries.values());
    writeLockfileAtomically(options.lockfilePath, serialized);
    return true;
}
export function createExtensionProvenanceLockEntry(options) {
    const packageRoot = realpathSync(options.packageRoot);
    const entry = {
        key: makeExtensionProvenanceEntryKey(options.source),
        scope: options.scope,
        source: options.source,
        manifest: options.manifest,
        packageRoot,
        manifestPath: options.manifestPath,
        artifact: options.artifact,
        digests: {
            packageRootSha256: computePackageRootSha256(packageRoot),
        },
    };
    return normalizeEntryForSerialization(entry);
}
export function createWasmArtifactIdentity(manifest) {
    return {
        kind: "wasm-component",
        path: manifest.artifactPath,
        absolutePath: manifest.artifactAbsolutePath,
        sha256: manifest.artifactSha256,
    };
}
export function normalizeEntryForSerialization(entry) {
    const normalized = {
        key: entry.key,
        scope: entry.scope,
        source: entry.source.specifier === undefined
            ? { type: entry.source.type, identity: entry.source.identity }
            : { type: entry.source.type, identity: entry.source.identity, specifier: entry.source.specifier },
        manifest: normalizeManifestForSerialization(entry.manifest),
        packageRoot: entry.packageRoot,
        manifestPath: entry.manifestPath,
        digests: { packageRootSha256: entry.digests.packageRootSha256 },
    };
    if (entry.artifact) {
        normalized.artifact = {
            kind: entry.artifact.kind,
            path: entry.artifact.path,
            absolutePath: entry.artifact.absolutePath,
            sha256: entry.artifact.sha256,
        };
    }
    return normalized;
}
function normalizeManifestForSerialization(manifest) {
    const normalized = { kind: manifest.kind };
    if (manifest.packageName !== undefined)
        normalized.packageName = manifest.packageName;
    if (manifest.packageVersion !== undefined)
        normalized.packageVersion = manifest.packageVersion;
    if (manifest.schemaVersion !== undefined)
        normalized.schemaVersion = manifest.schemaVersion;
    if (manifest.id !== undefined)
        normalized.id = manifest.id;
    if (manifest.name !== undefined)
        normalized.name = manifest.name;
    if (manifest.version !== undefined)
        normalized.version = manifest.version;
    if (manifest.toolId !== undefined)
        normalized.toolId = manifest.toolId;
    return normalized;
}
export function computePackageRootSha256(packageRoot) {
    const root = realpathSync(packageRoot);
    const files = collectPackageDigestFiles(root);
    const hash = createHash("sha256");
    for (const file of files) {
        const relativePath = toPosixPath(relative(root, file));
        hash.update(relativePath);
        hash.update("\0");
        hash.update(readFileSync(file));
        hash.update("\0");
    }
    return hash.digest("hex");
}
function collectPackageDigestFiles(root) {
    const files = [];
    collectPackageDigestFilesInto(root, files);
    return files.sort((a, b) => toPosixPath(relative(root, a)).localeCompare(toPosixPath(relative(root, b))));
}
function collectPackageDigestFilesInto(dir, files) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
        if (entry.name.startsWith(".") && HOST_NOISE_DIRS.has(entry.name)) {
            continue;
        }
        if (HOST_NOISE_FILES.has(entry.name)) {
            continue;
        }
        const fullPath = join(dir, entry.name);
        if (entry.isSymbolicLink()) {
            const stats = statSync(fullPath);
            if (stats.isDirectory()) {
                collectPackageDigestFilesInto(realpathSync(fullPath), files);
            }
            else if (stats.isFile()) {
                files.push(realpathSync(fullPath));
            }
            continue;
        }
        if (entry.isDirectory()) {
            collectPackageDigestFilesInto(fullPath, files);
            continue;
        }
        if (entry.isFile()) {
            files.push(fullPath);
        }
    }
}
//# sourceMappingURL=extension-provenance-lockfile.js.map