import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { existsSync, mkdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { PassThrough } from "node:stream";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createWasmExtensionManifestPolicyKey } from "../src/core/extension-policy.js";
import { DefaultPackageManager, type ProgressEvent, type ResolvedResource } from "../src/core/package-manager.js";
import { SettingsManager, type SettingsScope, type SettingsStorage } from "../src/core/settings-manager.js";
import {
	WASM_CANONICAL_SECURITY_GRANTS,
	WasmExtensionCapabilityDenialError,
} from "../src/core/wasm-extension-package.js";
import { shouldUseWindowsShell } from "../src/utils/child-process.js";

function normalizeForMatch(value: string): string {
	return value.replace(/\\/g, "/");
}

function pathEndsWith(actualPath: string, suffix: string): boolean {
	return normalizeForMatch(actualPath).endsWith(normalizeForMatch(suffix));
}

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const securityGrantFixturePath = join(repoRoot, "packages/coding-agent/test/fixtures/extension-security-grants.json");
const pureWasmFixtureRoot = join(repoRoot, "zig/test/fixtures/wasm/pure-truncate-head-v0");
const browserWasmFixtureRoot = join(repoRoot, "zig/test/fixtures/wasm/browser-tool-v0");

function writeWasmPackage(
	packageRoot: string,
	options: {
		artifactPath?: string;
		artifactBytes?: Buffer | string;
		capabilities?: string[];
		id?: string;
		name?: string;
		resourceLimits?: Record<string, unknown>;
		toolId?: string;
		version?: string;
	} = {},
): void {
	const artifactPath = options.artifactPath ?? "wasm/plugin.wasm";
	mkdirSync(join(packageRoot, dirname(artifactPath)), { recursive: true });
	writeFileSync(join(packageRoot, artifactPath), options.artifactBytes ?? Buffer.from([0x00, 0x61, 0x73, 0x6d]));
	const manifest: Record<string, unknown> = {
		schemaVersion: "pi-extension.v0",
		id: "com.example.local-wasm",
		name: "Local Wasm Fixture",
		version: "0.1.0",
		description: "Local Wasm package fixture.",
		artifact: {
			kind: "wasm-component",
			path: artifactPath,
		},
		tool: {
			id: options.toolId ?? "fixture.echo",
			description: "Echoes deterministic JSON from a local Wasm fixture.",
			inputSchema: {},
			outputSchema: {},
		},
		capabilities: options.capabilities ?? [],
	};
	if (options.id !== undefined) {
		manifest.id = options.id;
	}
	if (options.name !== undefined) {
		manifest.name = options.name;
	}
	if (options.version !== undefined) {
		manifest.version = options.version;
	}
	if (options.resourceLimits !== undefined) {
		manifest.resourceLimits = options.resourceLimits;
	}
	writeFileSync(join(packageRoot, "pi-extension.json"), JSON.stringify(manifest));
}

function writeTypeScriptPackage(packageRoot: string, options: { name?: string; version?: string } = {}): string {
	mkdirSync(join(packageRoot, "extensions"), { recursive: true });
	const entryPath = join(packageRoot, "extensions", "entry.ts");
	writeFileSync(entryPath, "export default function() {}");
	writeFileSync(
		join(packageRoot, "package.json"),
		JSON.stringify({
			name: options.name ?? "local-typescript-package",
			version: options.version ?? "1.0.0",
			pi: {
				extensions: ["extensions/entry.ts"],
			},
		}),
	);
	return entryPath;
}

function readJsonFile(path: string): unknown {
	return JSON.parse(readFileSync(path, "utf-8"));
}

class FailNextSettingsStorage implements SettingsStorage {
	private global: string | undefined;
	private project: string | undefined;
	private failNextWrites = new Set<SettingsScope>();

	constructor(initialGlobal: Record<string, unknown> = {}, initialProject: Record<string, unknown> = {}) {
		this.global = JSON.stringify(initialGlobal, null, 2);
		this.project = JSON.stringify(initialProject, null, 2);
	}

	failNextWrite(scope: SettingsScope): void {
		this.failNextWrites.add(scope);
	}

	read(scope: SettingsScope): string | undefined {
		return scope === "global" ? this.global : this.project;
	}

	withLock(scope: SettingsScope, fn: (current: string | undefined) => string | undefined): void {
		const current = this.read(scope);
		const next = fn(current);
		if (next === undefined) {
			return;
		}
		if (this.failNextWrites.delete(scope)) {
			throw new Error(`injected ${scope} settings write failure`);
		}
		if (scope === "global") {
			this.global = next;
		} else {
			this.project = next;
		}
	}
}

class MockSpawnedProcess extends EventEmitter {
	stdout = new PassThrough();
	stderr = new PassThrough();

	kill(): boolean {
		this.emit("close", null, "SIGTERM");
		return true;
	}
}

// Helper to check if a resource is enabled
const isEnabled = (r: ResolvedResource, pathMatch: string, matchFn: "endsWith" | "includes" = "endsWith") => {
	const normalizedPath = normalizeForMatch(r.path);
	const normalizedMatch = normalizeForMatch(pathMatch);
	return matchFn === "endsWith"
		? normalizedPath.endsWith(normalizedMatch) && r.enabled
		: normalizedPath.includes(normalizedMatch) && r.enabled;
};

const isDisabled = (r: ResolvedResource, pathMatch: string, matchFn: "endsWith" | "includes" = "endsWith") => {
	const normalizedPath = normalizeForMatch(r.path);
	const normalizedMatch = normalizeForMatch(pathMatch);
	return matchFn === "endsWith"
		? normalizedPath.endsWith(normalizedMatch) && !r.enabled
		: normalizedPath.includes(normalizedMatch) && !r.enabled;
};

describe("DefaultPackageManager", () => {
	let tempDir: string;
	let agentDir: string;
	let settingsManager: SettingsManager;
	let packageManager: DefaultPackageManager;
	let previousOfflineEnv: string | undefined;

	beforeEach(() => {
		previousOfflineEnv = process.env.PI_OFFLINE;
		delete process.env.PI_OFFLINE;
		tempDir = join(tmpdir(), `pm-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
		mkdirSync(tempDir, { recursive: true });
		agentDir = join(tempDir, "agent");
		mkdirSync(agentDir, { recursive: true });

		settingsManager = SettingsManager.inMemory();
		packageManager = new DefaultPackageManager({
			cwd: tempDir,
			agentDir,
			settingsManager,
		});
	});

	afterEach(() => {
		if (previousOfflineEnv === undefined) {
			delete process.env.PI_OFFLINE;
		} else {
			process.env.PI_OFFLINE = previousOfflineEnv;
		}
		vi.restoreAllMocks();
		vi.unstubAllGlobals();
		rmSync(tempDir, { recursive: true, force: true });
	});

	describe("resolve", () => {
		it("should return no package-sourced paths when no sources configured", async () => {
			const result = await packageManager.resolve();
			expect(result.extensions).toEqual([]);
			expect(result.prompts).toEqual([]);
			expect(result.themes).toEqual([]);
			expect(result.skills.every((r) => r.metadata.source === "auto" && r.metadata.origin === "top-level")).toBe(
				true,
			);
		});

		it("should resolve local extension paths from settings", async () => {
			const extDir = join(agentDir, "extensions");
			mkdirSync(extDir, { recursive: true });
			const extPath = join(extDir, "my-extension.ts");
			writeFileSync(extPath, "export default function() {}");
			settingsManager.setExtensionPaths(["extensions/my-extension.ts"]);

			const result = await packageManager.resolve();
			expect(result.extensions.some((r) => r.path === extPath && r.enabled)).toBe(true);
		});

		it("should resolve skill paths from settings", async () => {
			const skillDir = join(agentDir, "skills", "my-skill");
			mkdirSync(skillDir, { recursive: true });
			const skillFile = join(skillDir, "SKILL.md");
			writeFileSync(
				skillFile,
				`---
name: test-skill
description: A test skill
---
Content`,
			);

			settingsManager.setSkillPaths(["skills"]);

			const result = await packageManager.resolve();
			// Skills with SKILL.md are returned as file paths
			expect(result.skills.some((r) => r.path === skillFile && r.enabled)).toBe(true);
		});

		it("should auto-discover root markdown skills from .pi skill dirs", async () => {
			const skillFile = join(agentDir, "skills", "single-file.md");
			mkdirSync(join(agentDir, "skills"), { recursive: true });
			writeFileSync(
				skillFile,
				`---
name: single-file
description: A root markdown skill
---
Content`,
			);

			const result = await packageManager.resolve();
			expect(result.skills.some((r) => r.path === skillFile && r.enabled)).toBe(true);
		});

		it("should resolve project paths relative to .pi", async () => {
			const extDir = join(tempDir, ".pi", "extensions");
			mkdirSync(extDir, { recursive: true });
			const extPath = join(extDir, "project-ext.ts");
			writeFileSync(extPath, "export default function() {}");

			settingsManager.setProjectExtensionPaths(["extensions/project-ext.ts"]);

			const result = await packageManager.resolve();
			expect(result.extensions.some((r) => r.path === extPath && r.enabled)).toBe(true);
		});

		it("should auto-discover user prompts with overrides", async () => {
			const promptsDir = join(agentDir, "prompts");
			mkdirSync(promptsDir, { recursive: true });
			const promptPath = join(promptsDir, "auto.md");
			writeFileSync(promptPath, "Auto prompt");

			settingsManager.setPromptTemplatePaths(["!prompts/auto.md"]);

			const result = await packageManager.resolve();
			expect(result.prompts.some((r) => r.path === promptPath && !r.enabled)).toBe(true);
		});

		it("should resolve symlinked user and project resources once", async () => {
			const previousHome = process.env.HOME;
			process.env.HOME = tempDir;

			try {
				const sharedDir = join(tempDir, "shared-resources");
				const sharedExtensionsDir = join(sharedDir, "extensions");
				const sharedSkillsDir = join(sharedDir, "skills");
				const sharedPromptsDir = join(sharedDir, "prompts");
				const sharedThemesDir = join(sharedDir, "themes");
				mkdirSync(sharedExtensionsDir, { recursive: true });
				mkdirSync(sharedSkillsDir, { recursive: true });
				mkdirSync(sharedPromptsDir, { recursive: true });
				mkdirSync(sharedThemesDir, { recursive: true });

				writeFileSync(join(sharedExtensionsDir, "shared.ts"), "export default function() {}");
				mkdirSync(join(sharedSkillsDir, "shared-skill"), { recursive: true });
				writeFileSync(
					join(sharedSkillsDir, "shared-skill", "SKILL.md"),
					`---
name: shared-skill
description: Shared skill
---
Content`,
				);
				writeFileSync(join(sharedPromptsDir, "shared.md"), "Shared prompt");
				writeFileSync(join(sharedThemesDir, "shared.json"), JSON.stringify({ name: "shared-theme" }));

				mkdirSync(join(agentDir), { recursive: true });
				mkdirSync(join(tempDir, ".pi"), { recursive: true });
				symlinkSync(sharedExtensionsDir, join(agentDir, "extensions"), "dir");
				symlinkSync(sharedSkillsDir, join(agentDir, "skills"), "dir");
				symlinkSync(sharedPromptsDir, join(agentDir, "prompts"), "dir");
				symlinkSync(sharedThemesDir, join(agentDir, "themes"), "dir");
				symlinkSync(sharedExtensionsDir, join(tempDir, ".pi", "extensions"), "dir");
				symlinkSync(sharedSkillsDir, join(tempDir, ".pi", "skills"), "dir");
				symlinkSync(sharedPromptsDir, join(tempDir, ".pi", "prompts"), "dir");
				symlinkSync(sharedThemesDir, join(tempDir, ".pi", "themes"), "dir");

				const result = await packageManager.resolve();

				expect({
					extensions: result.extensions.length,
					skills: result.skills.length,
					prompts: result.prompts.length,
					themes: result.themes.length,
				}).toEqual({
					extensions: 1,
					skills: 1,
					prompts: 1,
					themes: 1,
				});

				// Project auto-discovered has higher precedence than user auto-discovered,
				// so the surviving entry should be scoped to project.
				expect(result.extensions[0].metadata.scope).toBe("project");
				expect(result.skills[0].metadata.scope).toBe("project");
				expect(result.prompts[0].metadata.scope).toBe("project");
				expect(result.themes[0].metadata.scope).toBe("project");
			} finally {
				if (previousHome === undefined) {
					delete process.env.HOME;
				} else {
					process.env.HOME = previousHome;
				}
			}
		});

		it("should auto-discover project prompts with overrides", async () => {
			const promptsDir = join(tempDir, ".pi", "prompts");
			mkdirSync(promptsDir, { recursive: true });
			const promptPath = join(promptsDir, "is.md");
			writeFileSync(promptPath, "Is prompt");

			settingsManager.setProjectPromptTemplatePaths(["!prompts/is.md"]);

			const result = await packageManager.resolve();
			expect(result.prompts.some((r) => r.path === promptPath && !r.enabled)).toBe(true);
		});

		it("should resolve directory with package.json pi.extensions in extensions setting", async () => {
			// Create a package with pi.extensions in package.json
			const pkgDir = join(tempDir, "my-extensions-pkg");
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			writeFileSync(
				join(pkgDir, "package.json"),
				JSON.stringify({
					name: "my-extensions-pkg",
					pi: {
						extensions: ["./extensions/clip.ts", "./extensions/cost.ts"],
					},
				}),
			);
			writeFileSync(join(pkgDir, "extensions", "clip.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "extensions", "cost.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "extensions", "helper.ts"), "export const x = 1;"); // Not in manifest, shouldn't be loaded

			// Add the directory to extensions setting (not packages setting)
			settingsManager.setExtensionPaths([pkgDir]);

			const result = await packageManager.resolve();

			// Should find the extensions declared in package.json pi.extensions
			expect(result.extensions.some((r) => r.path === join(pkgDir, "extensions", "clip.ts") && r.enabled)).toBe(
				true,
			);
			expect(result.extensions.some((r) => r.path === join(pkgDir, "extensions", "cost.ts") && r.enabled)).toBe(
				true,
			);

			// Should NOT find helper.ts (not declared in manifest)
			expect(result.extensions.some((r) => pathEndsWith(r.path, "helper.ts"))).toBe(false);
		});

		it("should ignore local package directories without package resources", async () => {
			const pkgDir = join(tempDir, "empty-package");
			mkdirSync(pkgDir, { recursive: true });
			settingsManager.setPackages([pkgDir]);

			const result = await packageManager.resolve();

			expect(result.extensions.some((r) => r.path === pkgDir)).toBe(false);
		});

		it("should discover and classify local pi-extension.json Wasm packages", async () => {
			const pkgDir = join(tempDir, "local-wasm-package");
			mkdirSync(pkgDir, { recursive: true });
			writeWasmPackage(pkgDir, { toolId: "fixture.local" });
			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();

			const result = await packageManager.resolve();

			expect(result.extensions).toHaveLength(0);
			expect(result.wasmExtensions).toHaveLength(1);
			expect(result.wasmExtensions[0]).toMatchObject({
				enabled: true,
				path: join(pkgDir, "pi-extension.json"),
				packageRoot: realpathSync(pkgDir),
				manifestPath: join(pkgDir, "pi-extension.json"),
				artifactPath: "wasm/plugin.wasm",
				artifactAbsolutePath: realpathSync(resolve(pkgDir, "wasm/plugin.wasm")),
				artifactKind: "wasm-component",
				toolId: "fixture.local",
			});
			expect(result.wasmExtensions[0].metadata.origin).toBe("package");
			expect(result.wasmExtensions[0].metadata.baseDir).toBe(pkgDir);
			expect(result.wasmExtensions[0].artifactSha256).toHaveLength(64);
		});

		it("should keep mixed Wasm package roots metadata-only under package discovery paths", async () => {
			const pkgDir = join(tempDir, "mixed-wasm-package");
			mkdirSync(join(pkgDir, "src"), { recursive: true });
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			writeWasmPackage(pkgDir, { toolId: "fixture.mixed" });
			writeFileSync(join(pkgDir, "index.ts"), "throw new Error('index.ts must not load for Wasm packages');");
			writeFileSync(join(pkgDir, "extensions", "extra.ts"), "throw new Error('extension dir must not load');");
			writeFileSync(join(pkgDir, "src", "manifest-entry.ts"), "throw new Error('pi.extensions must not load');");
			writeFileSync(
				join(pkgDir, "package.json"),
				JSON.stringify({
					name: "mixed-wasm-package",
					pi: {
						extensions: ["./src/manifest-entry.ts"],
					},
				}),
			);

			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();
			const unfiltered = await packageManager.resolve();

			expect(unfiltered.extensions).toHaveLength(0);
			expect(unfiltered.wasmExtensions.map((extension) => extension.toolId)).toEqual(["fixture.mixed"]);

			settingsManager.setPackages([
				{
					source: pkgDir,
					extensions: ["**/*.ts"],
					skills: [],
					prompts: [],
					themes: [],
				},
			]);
			const filtered = await packageManager.resolve();

			expect(filtered.extensions).toHaveLength(0);
			expect(filtered.wasmExtensions.map((extension) => extension.toolId)).toEqual(["fixture.mixed"]);

			const direct = await packageManager.resolveExtensionSources([pkgDir]);
			expect(direct.extensions).toHaveLength(0);
			expect(direct.wasmExtensions.map((extension) => extension.toolId)).toEqual(["fixture.mixed"]);
		});

		it("should validate local Wasm artifacts before install success or persistence", async () => {
			const missingArtifactPackage = join(tempDir, "missing-artifact-package");
			mkdirSync(missingArtifactPackage, { recursive: true });
			writeWasmPackage(missingArtifactPackage);
			writeFileSync(
				join(missingArtifactPackage, "pi-extension.json"),
				readFileSync(join(missingArtifactPackage, "pi-extension.json"), "utf-8").replace(
					"wasm/plugin.wasm",
					"wasm/missing.wasm",
				),
			);

			const invalidArtifactPackage = join(tempDir, "invalid-artifact-package");
			mkdirSync(invalidArtifactPackage, { recursive: true });
			writeWasmPackage(invalidArtifactPackage, { artifactBytes: "not wasm" });

			const events: ProgressEvent[] = [];
			packageManager.setProgressCallback((event) => events.push(event));

			await expect(packageManager.installAndPersist(missingArtifactPackage)).rejects.toThrow(
				"$.artifact.path: artifact file was not found",
			);
			await expect(packageManager.installAndPersist(invalidArtifactPackage)).rejects.toThrow(
				"$.artifact.path: artifact file is not a valid Wasm binary",
			);
			expect(events.some((event) => event.type === "complete")).toBe(false);
			expect(settingsManager.getGlobalSettings().packages ?? []).toHaveLength(0);
		});

		it("should reject unsafe Wasm manifests before settings mutation", async () => {
			const cases: Array<{
				name: string;
				mutate: (packageRoot: string) => void;
				expected: string;
			}> = [
				{
					name: "malformed-json",
					mutate: (packageRoot) => writeFileSync(join(packageRoot, "pi-extension.json"), "{"),
					expected: "$: malformed JSON",
				},
				{
					name: "unsupported-surface",
					mutate: (packageRoot) => {
						const manifest = JSON.parse(readFileSync(join(packageRoot, "pi-extension.json"), "utf-8"));
						manifest.commands = [];
						writeFileSync(join(packageRoot, "pi-extension.json"), JSON.stringify(manifest));
					},
					expected: "$.commands: unsupported v0 surface; only $.tool is supported",
				},
				{
					name: "unknown-capability",
					mutate: (packageRoot) => {
						const manifest = JSON.parse(readFileSync(join(packageRoot, "pi-extension.json"), "utf-8"));
						manifest.capabilities = ["database"];
						writeFileSync(join(packageRoot, "pi-extension.json"), JSON.stringify(manifest));
					},
					expected: '$.capabilities[0]: unknown capability "database"',
				},
				{
					name: "absolute-artifact",
					mutate: (packageRoot) => {
						const manifest = JSON.parse(readFileSync(join(packageRoot, "pi-extension.json"), "utf-8"));
						manifest.artifact.path = resolve(packageRoot, "wasm/plugin.wasm");
						writeFileSync(join(packageRoot, "pi-extension.json"), JSON.stringify(manifest));
					},
					expected: "$.artifact.path: artifact path must be package-relative",
				},
				{
					name: "non-normalized-artifact",
					mutate: (packageRoot) => {
						const manifest = JSON.parse(readFileSync(join(packageRoot, "pi-extension.json"), "utf-8"));
						manifest.artifact.path = "wasm/./plugin.wasm";
						writeFileSync(join(packageRoot, "pi-extension.json"), JSON.stringify(manifest));
					},
					expected: "$.artifact.path: artifact path must be normalized",
				},
				{
					name: "escaping-artifact",
					mutate: (packageRoot) => {
						const manifest = JSON.parse(readFileSync(join(packageRoot, "pi-extension.json"), "utf-8"));
						manifest.artifact.path = "../outside.wasm";
						writeFileSync(join(packageRoot, "pi-extension.json"), JSON.stringify(manifest));
					},
					expected: "$.artifact.path: artifact path escapes package root",
				},
				{
					name: "non-file-artifact",
					mutate: (packageRoot) => {
						rmSync(join(packageRoot, "wasm", "plugin.wasm"));
						mkdirSync(join(packageRoot, "wasm", "plugin.wasm"));
					},
					expected: "$.artifact.path: artifact path must point to a file",
				},
			];

			for (const testCase of cases) {
				const pkgDir = join(tempDir, `unsafe-${testCase.name}`);
				mkdirSync(pkgDir, { recursive: true });
				writeWasmPackage(pkgDir);
				testCase.mutate(pkgDir);

				await expect(packageManager.installAndPersist(pkgDir), testCase.name).rejects.toThrow(testCase.expected);
				expect(settingsManager.getGlobalSettings().packages ?? [], testCase.name).toHaveLength(0);
			}
		});

		it("should deny local Wasm capabilities before artifact validation or persistence", async () => {
			const deniedCapabilityPackage = join(tempDir, "denied-capability-package");
			mkdirSync(deniedCapabilityPackage, { recursive: true });
			writeWasmPackage(deniedCapabilityPackage, {
				artifactPath: "wasm/missing.wasm",
				capabilities: ["file.read"],
			});
			rmSync(join(deniedCapabilityPackage, "wasm", "missing.wasm"));

			const events: ProgressEvent[] = [];
			packageManager.setProgressCallback((event) => events.push(event));

			await expect(packageManager.installAndPersist(deniedCapabilityPackage)).rejects.toMatchObject({
				message:
					'$.capabilities[0]: denied_capability: capability "file.read" is not approved for manifest-request',
				details: {
					category: "denied_capability",
					capability: "file.read",
					operation: "file.read",
					branch: "filesystem.read",
					phase: "validate",
					mode: "manifest-request",
					reason: "grant is not approved",
					path: "$.capabilities[0]",
					principal: {
						runtimeKind: "wasm",
						extensionId: "com.example.local-wasm",
						toolId: "fixture.echo",
					},
					source: {
						artifactPath: "wasm/missing.wasm",
					},
				},
			});
			await expect(packageManager.installAndPersist(deniedCapabilityPackage)).rejects.toBeInstanceOf(
				WasmExtensionCapabilityDenialError,
			);
			expect(events.some((event) => event.type === "complete")).toBe(false);
			expect(settingsManager.getGlobalSettings().packages ?? []).toHaveLength(0);
		});

		it("should treat Wasm resource limits as constraints without granting capabilities", async () => {
			const constrainedPackage = join(tempDir, "resource-limited-package");
			mkdirSync(constrainedPackage, { recursive: true });
			const resourceLimits = {
				maxChildren: 0,
				depth: 1,
				turns: 3,
				timeoutMs: 1000,
				outputBytes: 4096,
				outputLines: 80,
				toolScopes: ["fixture.echo", "builtin.truncateHead"],
			};
			writeWasmPackage(constrainedPackage, { resourceLimits });

			const result = await packageManager.resolveExtensionSources([constrainedPackage]);

			expect(result.extensions).toHaveLength(0);
			expect(result.wasmExtensions).toHaveLength(1);
			expect(result.wasmExtensions[0].capabilities).toEqual([]);
			expect(result.wasmExtensions[0].resourceLimits).toEqual(resourceLimits);
		});

		it("should expose canonical WASM policy identities with artifact metadata and name-collision resistance", async () => {
			const firstPackage = join(tempDir, "wasm-principal-a");
			const secondPackage = join(tempDir, "wasm-principal-b");
			writeWasmPackage(firstPackage, {
				id: "com.example.same-principal-id",
				name: "Same Display Name",
				artifactBytes: Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01]),
			});
			writeWasmPackage(secondPackage, {
				id: "com.example.same-principal-id",
				name: "Same Display Name",
				artifactBytes: Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x02]),
			});

			const result = await packageManager.resolveExtensionSources([firstPackage, secondPackage], { local: true });

			expect(result.wasmExtensions).toHaveLength(2);
			const identities = result.wasmExtensions.map((extension) => extension.identity);
			expect(new Set(identities.map((identity) => identity.key)).size).toBe(2);
			expect(identities[0].kind).toBe("wasm-manifest");
			expect(identities[0].manifestId).toBe("com.example.same-principal-id");
			expect(identities[0].name).toBe("Same Display Name");
			expect(identities[0].key).toContain("wasm:pi-extension.v0:com.example.same-principal-id:");
			expect(identities[0].key).toContain(result.wasmExtensions[0].artifactSha256);
			expect(identities[0].key).toContain(result.wasmExtensions[0].artifactAbsolutePath);
			expect(identities[0].key).not.toBe("Same Display Name");
			expect(identities.map((identity) => identity.sourceInfo.origin)).toEqual(["package", "package"]);
		});

		it("should reject invalid Wasm resource limits deterministically", async () => {
			const cases: Array<{
				name: string;
				resourceLimits: unknown;
				expected: string;
			}> = [
				{
					name: "wrong-type",
					resourceLimits: [],
					expected: "$.resourceLimits: expected object",
				},
				{
					name: "unknown-field",
					resourceLimits: { network: 1 },
					expected: "$.resourceLimits.network: unsupported resource limit",
				},
				{
					name: "negative-timeout",
					resourceLimits: { timeoutMs: -1 },
					expected: "$.resourceLimits.timeoutMs: expected non-negative integer",
				},
				{
					name: "fractional-turns",
					resourceLimits: { turns: 1.5 },
					expected: "$.resourceLimits.turns: expected non-negative integer",
				},
				{
					name: "non-array-tool-scopes",
					resourceLimits: { toolScopes: "fixture.echo" },
					expected: "$.resourceLimits.toolScopes: expected array",
				},
				{
					name: "empty-tool-scope",
					resourceLimits: { toolScopes: ["fixture.echo", ""] },
					expected: "$.resourceLimits.toolScopes[1]: must not be empty",
				},
			];

			for (const testCase of cases) {
				const pkgDir = join(tempDir, `invalid-resource-limit-${testCase.name}`);
				mkdirSync(pkgDir, { recursive: true });
				writeWasmPackage(pkgDir, { resourceLimits: testCase.resourceLimits as Record<string, unknown> });

				await expect(packageManager.installAndPersist(pkgDir), testCase.name).rejects.toThrow(testCase.expected);
				expect(settingsManager.getGlobalSettings().packages ?? [], testCase.name).toHaveLength(0);
			}
		});

		it("should keep resource limits independent from Wasm capability denial", async () => {
			const deniedCapabilityPackage = join(tempDir, "resource-limited-denied-capability-package");
			mkdirSync(deniedCapabilityPackage, { recursive: true });
			writeWasmPackage(deniedCapabilityPackage, {
				artifactPath: "wasm/missing.wasm",
				capabilities: ["file.read"],
				resourceLimits: {
					timeoutMs: 1000,
					toolScopes: ["fixture.echo"],
				},
			});
			rmSync(join(deniedCapabilityPackage, "wasm", "missing.wasm"));

			await expect(packageManager.installAndPersist(deniedCapabilityPackage)).rejects.toThrow(
				'$.capabilities[0]: denied_capability: capability "file.read" is not approved for manifest-request',
			);
			expect(settingsManager.getGlobalSettings().packages ?? []).toHaveLength(0);
		});

		it("should share canonical security grants with the parity fixture", () => {
			const fixture = JSON.parse(readFileSync(securityGrantFixturePath, "utf-8"));
			expect(WASM_CANONICAL_SECURITY_GRANTS).toEqual(fixture);
			expect(WASM_CANONICAL_SECURITY_GRANTS).toEqual([
				"file.read",
				"file.write",
				"network.request",
				"shell.run",
				"env.read",
				"model.call",
				"session.read",
				"session.write",
				"ui.notify",
				"tool.use",
				"agent.spawn",
				"agent.delegate",
			]);
		});

		it("should deny every canonical Wasm security grant before artifact validation or persistence", async () => {
			for (const capability of WASM_CANONICAL_SECURITY_GRANTS) {
				const deniedCapabilityPackage = join(tempDir, `denied-${capability.replaceAll(".", "-")}-package`);
				mkdirSync(deniedCapabilityPackage, { recursive: true });
				writeWasmPackage(deniedCapabilityPackage, {
					artifactPath: "wasm/missing.wasm",
					capabilities: [capability],
				});
				rmSync(join(deniedCapabilityPackage, "wasm", "missing.wasm"));

				await expect(packageManager.installAndPersist(deniedCapabilityPackage), capability).rejects.toThrow(
					`$.capabilities[0]: denied_capability: capability "${capability}" is not approved for manifest-request`,
				);
				expect(settingsManager.getGlobalSettings().packages ?? [], capability).toHaveLength(0);
			}
		});

		it("should apply exact approved Wasm policy grants before artifact persistence", async () => {
			const approvedCapabilityPackage = join(tempDir, "approved-capability-package");
			mkdirSync(approvedCapabilityPackage, { recursive: true });
			writeWasmPackage(approvedCapabilityPackage, {
				artifactPath: "wasm/missing.wasm",
				capabilities: ["file.read"],
			});
			rmSync(join(approvedCapabilityPackage, "wasm", "missing.wasm"));
			settingsManager.setExtensionPolicy(
				createWasmExtensionManifestPolicyKey({
					schemaVersion: "pi-extension.v0",
					id: "com.example.local-wasm",
					version: "0.1.0",
					manifestPath: join(approvedCapabilityPackage, "pi-extension.json"),
					packageRoot: approvedCapabilityPackage,
					artifactPath: "wasm/missing.wasm",
				}),
				{ approvedGrants: ["file.read"] },
			);

			await expect(packageManager.installAndPersist(approvedCapabilityPackage)).rejects.toThrow(
				"$.artifact.path: artifact file was not found",
			);
			expect(settingsManager.getGlobalSettings().packages ?? []).toHaveLength(0);
		});

		it("should not let Wasm resource limits or sibling grants approve requested capabilities", async () => {
			const resourceOnlyPackage = join(tempDir, "resource-only-policy-package");
			mkdirSync(resourceOnlyPackage, { recursive: true });
			writeWasmPackage(resourceOnlyPackage, {
				artifactPath: "wasm/missing.wasm",
				capabilities: ["file.write"],
				resourceLimits: { toolScopes: ["fixture.echo"], turns: 1 },
			});
			rmSync(join(resourceOnlyPackage, "wasm", "missing.wasm"));
			const policyKey = createWasmExtensionManifestPolicyKey({
				schemaVersion: "pi-extension.v0",
				id: "com.example.local-wasm",
				version: "0.1.0",
				manifestPath: join(resourceOnlyPackage, "pi-extension.json"),
				packageRoot: resourceOnlyPackage,
				artifactPath: "wasm/missing.wasm",
			});
			settingsManager.setExtensionPolicy(policyKey, {
				approvedGrants: ["file.read"],
				resourceLimits: { toolScopes: ["fixture.echo"], turns: 1 },
			});

			await expect(packageManager.installAndPersist(resourceOnlyPackage)).rejects.toThrow(
				'$.capabilities[0]: denied_capability: capability "file.write" is not approved for manifest-request',
			);
			expect(settingsManager.getGlobalSettings().packages ?? []).toHaveLength(0);
		});

		it("should resolve valid Wasm packages with final-identity approved policy snapshots", async () => {
			const packageRoot = join(tempDir, "final-identity-approved-wasm");
			mkdirSync(packageRoot, { recursive: true });
			writeWasmPackage(packageRoot);
			const baseline = await packageManager.resolveExtensionSources([packageRoot]);
			const identityKey = baseline.wasmExtensions[0]?.identity.key;
			expect(identityKey).toBeDefined();

			settingsManager.setExtensionPolicy(identityKey!, {
				approvedGrants: ["file.read"],
				resourceLimits: { turns: 1, toolScopes: ["fixture.echo"] },
			});
			writeWasmPackage(packageRoot, { capabilities: ["file.read"] });

			const approved = await packageManager.resolveExtensionSources([packageRoot]);

			expect(approved.wasmExtensions).toHaveLength(1);
			expect(approved.wasmExtensions[0].capabilities).toEqual(["file.read"]);
			expect(approved.wasmExtensions[0].effectivePolicy).toEqual({
				approvedGrants: ["file.read"],
				resourceLimits: { turns: 1, toolScopes: ["fixture.echo"] },
			});

			settingsManager.setExtensionPolicy(identityKey!, { resourceLimits: { turns: 0 } });
			expect(approved.wasmExtensions[0].effectivePolicy).toEqual({
				approvedGrants: ["file.read"],
				resourceLimits: { turns: 1, toolScopes: ["fixture.echo"] },
			});
			await expect(packageManager.installAndPersist(packageRoot)).rejects.toThrow(
				'$.capabilities[0]: denied_capability: capability "file.read" is not approved for manifest-request',
			);
		});

		it("should ignore legacy Wasm manifest policies for locked packages", async () => {
			const packageRoot = join(tempDir, "locked-legacy-policy-wasm");
			mkdirSync(packageRoot, { recursive: true });
			writeWasmPackage(packageRoot);
			await packageManager.installAndPersist(packageRoot);
			await settingsManager.flush();
			const legacyPolicyKey = createWasmExtensionManifestPolicyKey({
				schemaVersion: "pi-extension.v0",
				id: "com.example.local-wasm",
				version: "0.1.0",
				manifestPath: join(packageRoot, "pi-extension.json"),
				packageRoot,
				artifactPath: "wasm/plugin.wasm",
			});
			settingsManager.setExtensionPolicy(legacyPolicyKey, {
				approvedGrants: ["file.read"],
				resourceLimits: { turns: 1, toolScopes: ["fixture.echo"] },
			});

			const resolved = await packageManager.resolve();

			expect(resolved.wasmExtensions).toHaveLength(1);
			expect(resolved.wasmExtensions[0].effectivePolicy).toBeUndefined();
			expect(resolved.diagnostics).toEqual(
				expect.arrayContaining([
					expect.objectContaining({
						category: "policy_digest_mismatch",
						scope: "user",
						actual: legacyPolicyKey,
					}),
				]),
			);
		});

		it("should not reuse user-scope Wasm policies for project-scoped locked packages", async () => {
			const packageRoot = join(tempDir, "cross-scope-policy-wasm");
			mkdirSync(packageRoot, { recursive: true });
			writeWasmPackage(packageRoot);
			await packageManager.installAndPersist(packageRoot);
			await settingsManager.flush();
			const userResolved = await packageManager.resolve();
			const userIdentityKey = userResolved.wasmExtensions[0]?.identity.key;
			expect(userIdentityKey).toBeDefined();
			settingsManager.setExtensionPolicy(userIdentityKey!, {
				approvedGrants: ["file.read"],
				resourceLimits: { turns: 1 },
			});
			const userApprovedResolved = await packageManager.resolve();
			expect(userApprovedResolved.wasmExtensions[0].effectivePolicy).toEqual({
				approvedGrants: ["file.read"],
				resourceLimits: { turns: 1 },
			});

			await packageManager.installAndPersist(packageRoot, { local: true });
			await settingsManager.flush();
			const projectResolved = await packageManager.resolve();

			expect(projectResolved.wasmExtensions).toHaveLength(1);
			expect(projectResolved.wasmExtensions[0].metadata.scope).toBe("project");
			expect(projectResolved.wasmExtensions[0].identity.key).not.toBe(userIdentityKey);
			expect(projectResolved.wasmExtensions[0].effectivePolicy).toBeUndefined();
			expect(projectResolved.diagnostics).toEqual(
				expect.arrayContaining([
					expect.objectContaining({
						category: "policy_digest_mismatch",
						scope: "project",
						actual: userIdentityKey,
					}),
				]),
			);
		});

		it("should reject legacy broad Wasm security grants as unknown", async () => {
			for (const capability of ["network", "shell", "env", "model", "session"]) {
				const unknownCapabilityPackage = join(tempDir, `unknown-${capability}-package`);
				mkdirSync(unknownCapabilityPackage, { recursive: true });
				writeWasmPackage(unknownCapabilityPackage, {
					capabilities: [capability],
				});

				await expect(packageManager.installAndPersist(unknownCapabilityPackage), capability).rejects.toThrow(
					`$.capabilities[0]: unknown capability "${capability}"`,
				);
				expect(settingsManager.getGlobalSettings().packages ?? [], capability).toHaveLength(0);
			}
		});

		it("should accept repository Wasm fixtures with normalized handoff identities", async () => {
			const result = await packageManager.resolveExtensionSources([pureWasmFixtureRoot, browserWasmFixtureRoot]);

			expect(result.extensions).toHaveLength(0);
			expect(result.wasmExtensions.map((extension) => extension.toolId).sort()).toEqual([
				"builtin.truncateHead",
				"fixture.echo",
			]);

			const pureFixture = result.wasmExtensions.find((extension) => extension.toolId === "builtin.truncateHead");
			expect(pureFixture).toBeDefined();
			expect(pureFixture?.manifestPath).toBe(join(pureWasmFixtureRoot, "pi-extension.json"));
			expect(pureFixture?.packageRoot).toBe(realpathSync(pureWasmFixtureRoot));
			expect(pureFixture?.artifactPath).toBe("wasm/plugin.wasm");
			expect(pureFixture?.artifactAbsolutePath).toBe(resolve(pureWasmFixtureRoot, "wasm/plugin.wasm"));
			expect(pureFixture?.artifactSha256).toBe(
				createHash("sha256")
					.update(readFileSync(resolve(pureWasmFixtureRoot, "wasm/plugin.wasm")))
					.digest("hex"),
			);
			expect(pureFixture?.capabilities).toEqual([]);
			expect(pureFixture?.enabled).toBe(true);
			expect(pureFixture?.metadata).toMatchObject({
				source: pureWasmFixtureRoot,
				scope: "user",
				origin: "package",
				baseDir: pureWasmFixtureRoot,
			});
		});

		it("should preserve package.json pi.extensions Bun package behavior without pi-extension.json", async () => {
			const pkgDir = join(tempDir, "bun-package");
			mkdirSync(join(pkgDir, "src"), { recursive: true });
			writeFileSync(join(pkgDir, "src", "index.ts"), "export default function() {}");
			writeFileSync(
				join(pkgDir, "package.json"),
				JSON.stringify({
					name: "bun-package",
					pi: {
						extensions: ["./src/index.ts"],
					},
				}),
			);

			const result = await packageManager.resolveExtensionSources([pkgDir]);

			expect(result.extensions).toHaveLength(1);
			expect(result.extensions[0].path).toBe(join(pkgDir, "src", "index.ts"));
			expect(result.wasmExtensions).toEqual([]);
		});
	});

	describe(".agents/skills auto-discovery", () => {
		it("should scan .agents/skills from cwd up to git repo root", async () => {
			const repoRoot = join(tempDir, "repo");
			const nestedCwd = join(repoRoot, "packages", "feature");
			mkdirSync(nestedCwd, { recursive: true });
			mkdirSync(join(repoRoot, ".git"), { recursive: true });

			const aboveRepoSkill = join(tempDir, ".agents", "skills", "above-repo", "SKILL.md");
			mkdirSync(join(tempDir, ".agents", "skills", "above-repo"), { recursive: true });
			writeFileSync(aboveRepoSkill, "---\nname: above-repo\ndescription: above\n---\n");

			const repoRootSkill = join(repoRoot, ".agents", "skills", "repo-root", "SKILL.md");
			mkdirSync(join(repoRoot, ".agents", "skills", "repo-root"), { recursive: true });
			writeFileSync(repoRootSkill, "---\nname: repo-root\ndescription: repo\n---\n");

			const nestedSkill = join(repoRoot, "packages", ".agents", "skills", "nested", "SKILL.md");
			mkdirSync(join(repoRoot, "packages", ".agents", "skills", "nested"), { recursive: true });
			writeFileSync(nestedSkill, "---\nname: nested\ndescription: nested\n---\n");

			const pm = new DefaultPackageManager({
				cwd: nestedCwd,
				agentDir,
				settingsManager,
			});

			const result = await pm.resolve();
			expect(result.skills.some((r) => r.path === repoRootSkill && r.enabled)).toBe(true);
			expect(result.skills.some((r) => r.path === nestedSkill && r.enabled)).toBe(true);
			expect(result.skills.some((r) => r.path === aboveRepoSkill)).toBe(false);
		});

		it("should scan .agents/skills up to filesystem root when not in a git repo", async () => {
			const nonRepoRoot = join(tempDir, "non-repo");
			const nestedCwd = join(nonRepoRoot, "a", "b");
			mkdirSync(nestedCwd, { recursive: true });

			const rootSkill = join(nonRepoRoot, ".agents", "skills", "root", "SKILL.md");
			mkdirSync(join(nonRepoRoot, ".agents", "skills", "root"), { recursive: true });
			writeFileSync(rootSkill, "---\nname: root\ndescription: root\n---\n");

			const middleSkill = join(nonRepoRoot, "a", ".agents", "skills", "middle", "SKILL.md");
			mkdirSync(join(nonRepoRoot, "a", ".agents", "skills", "middle"), { recursive: true });
			writeFileSync(middleSkill, "---\nname: middle\ndescription: middle\n---\n");

			const pm = new DefaultPackageManager({
				cwd: nestedCwd,
				agentDir,
				settingsManager,
			});

			const result = await pm.resolve();
			expect(result.skills.some((r) => r.path === rootSkill && r.enabled)).toBe(true);
			expect(result.skills.some((r) => r.path === middleSkill && r.enabled)).toBe(true);
		});

		it("should ignore root markdown files in .agents/skills", async () => {
			const agentsSkillsDir = join(tempDir, ".agents", "skills");
			mkdirSync(join(agentsSkillsDir, "nested-skill"), { recursive: true });
			const rootSkill = join(agentsSkillsDir, "root-file.md");
			const nestedSkill = join(agentsSkillsDir, "nested-skill", "SKILL.md");
			writeFileSync(rootSkill, "---\nname: root-file\ndescription: Root markdown file\n---\n");
			writeFileSync(nestedSkill, "---\nname: nested-skill\ndescription: Nested skill\n---\n");

			const pm = new DefaultPackageManager({
				cwd: join(tempDir, "work"),
				agentDir,
				settingsManager,
			});
			mkdirSync(join(tempDir, "work"), { recursive: true });

			const result = await pm.resolve();
			expect(result.skills.some((r) => r.path === rootSkill)).toBe(false);
			expect(result.skills.some((r) => r.path === nestedSkill && r.enabled)).toBe(true);
		});

		it("should keep ~/.agents/skills user-scoped when cwd is under home in a non-git directory", async () => {
			const previousHome = process.env.HOME;
			process.env.HOME = tempDir;

			try {
				const cwd = join(tempDir, "scratch", "nested");
				const localAgentDir = join(tempDir, ".pi", "agent");
				const localSettingsManager = SettingsManager.inMemory();
				mkdirSync(cwd, { recursive: true });
				mkdirSync(localAgentDir, { recursive: true });

				const homeSkill = join(tempDir, ".agents", "skills", "home-skill", "SKILL.md");
				mkdirSync(join(tempDir, ".agents", "skills", "home-skill"), { recursive: true });
				writeFileSync(homeSkill, "---\nname: home-skill\ndescription: home\n---\n");

				const pm = new DefaultPackageManager({
					cwd,
					agentDir: localAgentDir,
					settingsManager: localSettingsManager,
				});

				const result = await pm.resolve();
				const matchingSkills = result.skills.filter((r) => r.path === homeSkill);
				expect(matchingSkills).toHaveLength(1);
				expect(matchingSkills[0]?.enabled).toBe(true);
				expect(matchingSkills[0]?.metadata.scope).toBe("user");
				expect(matchingSkills[0]?.metadata.source).toBe("auto");
			} finally {
				if (previousHome === undefined) {
					delete process.env.HOME;
				} else {
					process.env.HOME = previousHome;
				}
			}
		});

		it("should dedupe user skill entries when ~/.pi/agent/skills is a symlink to ~/.agents/skills", async () => {
			const previousHome = process.env.HOME;
			process.env.HOME = tempDir;

			try {
				const agentSkillsDir = join(agentDir, "skills");
				const agentsSkillsDir = join(tempDir, ".agents", "skills");
				mkdirSync(agentsSkillsDir, { recursive: true });
				// Use junction on Windows to avoid EPERM when symlink privileges are unavailable.
				const directoryLinkType = process.platform === "win32" ? "junction" : "dir";
				symlinkSync(agentsSkillsDir, agentSkillsDir, directoryLinkType);

				const skillPath = join(agentsSkillsDir, "foo", "SKILL.md");
				mkdirSync(join(agentsSkillsDir, "foo"), { recursive: true });
				writeFileSync(skillPath, "---\nname: foo\ndescription: foo\n---\n");

				const result = await packageManager.resolve();
				const fooSkills = result.skills.filter((r) => pathEndsWith(r.path, "foo/SKILL.md"));

				expect(fooSkills).toHaveLength(1);
			} finally {
				if (previousHome === undefined) {
					delete process.env.HOME;
				} else {
					process.env.HOME = previousHome;
				}
			}
		});
	});

	describe("ignore files", () => {
		it("should respect .gitignore in skill directories", async () => {
			const skillsDir = join(agentDir, "skills");
			mkdirSync(skillsDir, { recursive: true });
			writeFileSync(join(skillsDir, ".gitignore"), "venv\n__pycache__\n");

			const goodSkillDir = join(skillsDir, "good-skill");
			mkdirSync(goodSkillDir, { recursive: true });
			writeFileSync(join(goodSkillDir, "SKILL.md"), "---\nname: good-skill\ndescription: Good\n---\nContent");

			const ignoredSkillDir = join(skillsDir, "venv", "bad-skill");
			mkdirSync(ignoredSkillDir, { recursive: true });
			writeFileSync(join(ignoredSkillDir, "SKILL.md"), "---\nname: bad-skill\ndescription: Bad\n---\nContent");

			settingsManager.setSkillPaths(["skills"]);

			const result = await packageManager.resolve();
			expect(result.skills.some((r) => r.path.includes("good-skill") && r.enabled)).toBe(true);
			expect(result.skills.some((r) => r.path.includes("venv") && r.enabled)).toBe(false);
		});

		it("should not apply parent .gitignore to .pi auto-discovery", async () => {
			writeFileSync(join(tempDir, ".gitignore"), ".pi\n");

			const skillDir = join(tempDir, ".pi", "skills", "auto-skill");
			mkdirSync(skillDir, { recursive: true });
			const skillPath = join(skillDir, "SKILL.md");
			writeFileSync(skillPath, "---\nname: auto-skill\ndescription: Auto\n---\nContent");

			const result = await packageManager.resolve();
			expect(result.skills.some((r) => r.path === skillPath && r.enabled)).toBe(true);
		});
	});

	describe("resolveExtensionSources", () => {
		it("should resolve local paths", async () => {
			const extPath = join(tempDir, "ext.ts");
			writeFileSync(extPath, "export default function() {}");

			const result = await packageManager.resolveExtensionSources([extPath]);
			expect(result.extensions.some((r) => r.path === extPath && r.enabled)).toBe(true);
		});

		it("should handle directories with pi manifest", async () => {
			const pkgDir = join(tempDir, "my-package");
			mkdirSync(pkgDir, { recursive: true });
			writeFileSync(
				join(pkgDir, "package.json"),
				JSON.stringify({
					name: "my-package",
					pi: {
						extensions: ["./src/index.ts"],
						skills: ["./skills"],
					},
				}),
			);
			mkdirSync(join(pkgDir, "src"), { recursive: true });
			writeFileSync(join(pkgDir, "src", "index.ts"), "export default function() {}");
			mkdirSync(join(pkgDir, "skills", "my-skill"), { recursive: true });
			writeFileSync(
				join(pkgDir, "skills", "my-skill", "SKILL.md"),
				"---\nname: my-skill\ndescription: Test\n---\nContent",
			);

			const result = await packageManager.resolveExtensionSources([pkgDir]);
			expect(result.extensions.some((r) => r.path === join(pkgDir, "src", "index.ts") && r.enabled)).toBe(true);
			// Skills with SKILL.md are returned as file paths
			expect(result.skills.some((r) => r.path === join(pkgDir, "skills", "my-skill", "SKILL.md") && r.enabled)).toBe(
				true,
			);
		});

		it("should handle directories with auto-discovery layout", async () => {
			const pkgDir = join(tempDir, "auto-pkg");
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			mkdirSync(join(pkgDir, "themes"), { recursive: true });
			writeFileSync(join(pkgDir, "extensions", "main.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "themes", "dark.json"), "{}");

			const result = await packageManager.resolveExtensionSources([pkgDir]);
			expect(result.extensions.some((r) => pathEndsWith(r.path, "main.ts") && r.enabled)).toBe(true);
			expect(result.themes.some((r) => pathEndsWith(r.path, "dark.json") && r.enabled)).toBe(true);
		});

		it("should stop recursing when a package skill directory contains SKILL.md", async () => {
			const pkgDir = join(tempDir, "skill-root-pkg");
			mkdirSync(join(pkgDir, "skills", "root-skill", "nested-skill"), { recursive: true });
			const rootSkill = join(pkgDir, "skills", "root-skill", "SKILL.md");
			const nestedSkill = join(pkgDir, "skills", "root-skill", "nested-skill", "SKILL.md");
			writeFileSync(rootSkill, "---\nname: root-skill\ndescription: Root skill\n---\n");
			writeFileSync(nestedSkill, "---\nname: nested-skill\ndescription: Nested skill\n---\n");

			const result = await packageManager.resolveExtensionSources([pkgDir]);
			expect(result.skills.some((r) => r.path === rootSkill && r.enabled)).toBe(true);
			expect(result.skills.some((r) => r.path === nestedSkill)).toBe(false);
		});
	});

	describe("progress callback", () => {
		it("should emit progress events", async () => {
			const events: ProgressEvent[] = [];
			packageManager.setProgressCallback((event) => events.push(event));

			const extPath = join(tempDir, "ext.ts");
			writeFileSync(extPath, "export default function() {}");

			// Local paths don't trigger install progress, but we can verify the callback is set
			await packageManager.resolveExtensionSources([extPath]);

			// For now just verify no errors - npm/git would trigger actual events
			expect(events.length).toBe(0);
		});
	});

	describe("windows command spawning", () => {
		it("should avoid the shell for git so Windows paths with spaces stay single arguments", () => {
			vi.spyOn(process, "platform", "get").mockReturnValue("win32");

			expect(shouldUseWindowsShell("git")).toBe(false);
			expect(shouldUseWindowsShell("npm")).toBe(true);
			expect(shouldUseWindowsShell("pnpm")).toBe(true);
			expect(shouldUseWindowsShell("C:/Program Files/nodejs/npm.cmd")).toBe(true);
		});
	});

	describe("npmCommand", () => {
		it("should use npmCommand argv for npm installs", async () => {
			settingsManager = SettingsManager.inMemory({
				npmCommand: ["mise", "exec", "node@20", "--", "npm"],
			});
			packageManager = new DefaultPackageManager({
				cwd: tempDir,
				agentDir,
				settingsManager,
			});

			const runCommandSpy = vi.spyOn(packageManager as any, "runCommand").mockResolvedValue(undefined);

			await packageManager.install("npm:@scope/pkg");

			expect(runCommandSpy).toHaveBeenCalledWith(
				"mise",
				["exec", "node@20", "--", "npm", "install", "-g", "@scope/pkg"],
				undefined,
			);
		});

		it("should install git package dependencies with --omit=dev", async () => {
			const source = "git:github.com/user/repo";
			const targetDir = join(agentDir, "git", "github.com", "user", "repo");
			const runCommandSpy = vi
				.spyOn(packageManager as any, "runCommand")
				.mockImplementation(async (...callArgs: unknown[]) => {
					const [command, args] = callArgs as [string, string[]];
					if (command === "git" && args[0] === "clone") {
						mkdirSync(targetDir, { recursive: true });
						writeFileSync(join(targetDir, "package.json"), JSON.stringify({ name: "repo", version: "1.0.0" }));
					}
				});

			await packageManager.install(source);

			expect(runCommandSpy).toHaveBeenCalledWith("npm", ["install", "--omit=dev"], { cwd: targetDir });
		});

		it("should use plain install for git package dependencies when npmCommand is configured", async () => {
			settingsManager = SettingsManager.inMemory({
				npmCommand: ["pnpm"],
			});
			packageManager = new DefaultPackageManager({
				cwd: tempDir,
				agentDir,
				settingsManager,
			});

			const source = "git:github.com/user/repo";
			const targetDir = join(agentDir, "git", "github.com", "user", "repo");
			const runCommandSpy = vi
				.spyOn(packageManager as any, "runCommand")
				.mockImplementation(async (...callArgs: unknown[]) => {
					const [command, args] = callArgs as [string, string[]];
					if (command === "git" && args[0] === "clone") {
						mkdirSync(targetDir, { recursive: true });
						writeFileSync(join(targetDir, "package.json"), JSON.stringify({ name: "repo", version: "1.0.0" }));
					}
				});

			await packageManager.install(source);

			expect(runCommandSpy).toHaveBeenCalledWith("pnpm", ["install"], { cwd: targetDir });
		});

		it("should update git package dependencies with --omit=dev", async () => {
			const source = "git:github.com/user/repo";
			const targetDir = join(tempDir, ".pi", "git", "github.com", "user", "repo");
			mkdirSync(targetDir, { recursive: true });
			writeFileSync(join(targetDir, "package.json"), JSON.stringify({ name: "repo", version: "1.0.0" }));
			settingsManager.setProjectPackages([source]);

			vi.spyOn(packageManager as any, "runCommandCapture").mockImplementation(async (...callArgs: unknown[]) => {
				const [_command, args] = callArgs as [string, string[]];
				if (args[0] === "rev-parse" && args[1] === "--abbrev-ref" && args[2] === "@{upstream}") {
					return "origin/main";
				}
				if (args[0] === "rev-parse" && args[1] === "@{upstream}") {
					return "remote-head";
				}
				if (args[0] === "rev-parse" && args[1] === "HEAD") {
					return "local-head";
				}
				throw new Error(`Unexpected runCommandCapture args: ${args.join(" ")}`);
			});
			const runCommandSpy = vi.spyOn(packageManager as any, "runCommand").mockResolvedValue(undefined);

			await packageManager.update(source);

			expect(runCommandSpy).toHaveBeenCalledWith("npm", ["install", "--omit=dev"], { cwd: targetDir });
		});

		it("should use plain install through npmCommand argv when updating git package dependencies", async () => {
			settingsManager = SettingsManager.inMemory({
				npmCommand: ["mise", "exec", "node@20", "--", "pnpm"],
			});
			packageManager = new DefaultPackageManager({
				cwd: tempDir,
				agentDir,
				settingsManager,
			});

			const source = "git:github.com/user/repo";
			const targetDir = join(tempDir, ".pi", "git", "github.com", "user", "repo");
			mkdirSync(targetDir, { recursive: true });
			writeFileSync(join(targetDir, "package.json"), JSON.stringify({ name: "repo", version: "1.0.0" }));
			settingsManager.setProjectPackages([source]);

			vi.spyOn(packageManager as any, "runCommandCapture").mockImplementation(async (...callArgs: unknown[]) => {
				const [_command, args] = callArgs as [string, string[]];
				if (args[0] === "rev-parse" && args[1] === "--abbrev-ref" && args[2] === "@{upstream}") {
					return "origin/main";
				}
				if (args[0] === "rev-parse" && args[1] === "@{upstream}") {
					return "remote-head";
				}
				if (args[0] === "rev-parse" && args[1] === "HEAD") {
					return "local-head";
				}
				throw new Error(`Unexpected runCommandCapture args: ${args.join(" ")}`);
			});
			const runCommandSpy = vi.spyOn(packageManager as any, "runCommand").mockResolvedValue(undefined);

			await packageManager.update(source);

			expect(runCommandSpy).toHaveBeenCalledWith("mise", ["exec", "node@20", "--", "pnpm", "install"], {
				cwd: targetDir,
			});
		});

		it("should use npmCommand argv for npm root lookup and invalidate cached root when npmCommand changes", () => {
			settingsManager = SettingsManager.inMemory({
				npmCommand: ["mise", "exec", "node@20", "--", "npm"],
			});
			packageManager = new DefaultPackageManager({
				cwd: tempDir,
				agentDir,
				settingsManager,
			});

			const root20 = join(tempDir, "node20", "lib", "node_modules");
			const root22 = join(tempDir, "node22", "lib", "node_modules");
			mkdirSync(join(root20, "@scope", "pkg"), { recursive: true });

			const runCommandSyncSpy = vi
				.spyOn(packageManager as any, "runCommandSync")
				.mockImplementation((...callArgs: unknown[]) => {
					const [command, args] = callArgs as [string, string[]];
					if (command !== "mise") {
						throw new Error(`unexpected command ${command}`);
					}
					if (args[1] === "node@20") {
						return root20;
					}
					if (args[1] === "node@22") {
						return root22;
					}
					throw new Error(`unexpected args ${args.join(" ")}`);
				});

			expect(packageManager.getInstalledPath("npm:@scope/pkg", "user")).toBe(join(root20, "@scope", "pkg"));
			expect(runCommandSyncSpy).toHaveBeenNthCalledWith(1, "mise", ["exec", "node@20", "--", "npm", "root", "-g"]);

			settingsManager.setNpmCommand(["mise", "exec", "node@22", "--", "npm"]);

			expect(packageManager.getInstalledPath("npm:@scope/pkg", "user")).toBeUndefined();
			expect(runCommandSyncSpy).toHaveBeenNthCalledWith(2, "mise", ["exec", "node@22", "--", "npm", "root", "-g"]);
		});
	});

	describe("source parsing", () => {
		it("should emit progress events on install attempt", async () => {
			const events: ProgressEvent[] = [];
			packageManager.setProgressCallback((event) => events.push(event));

			// Use public install method which emits progress events
			try {
				await packageManager.install("npm:nonexistent-package@1.0.0");
			} catch {
				// Expected to fail - package doesn't exist
			}

			// Should have emitted start event before failure
			expect(events.some((e) => e.type === "start" && e.action === "install")).toBe(true);
			// Should have emitted error event
			expect(events.some((e) => e.type === "error")).toBe(true);
		});

		it("should recognize github URLs without git: prefix", async () => {
			const events: ProgressEvent[] = [];
			packageManager.setProgressCallback((event) => events.push(event));
			const previousGitTerminalPrompt = process.env.GIT_TERMINAL_PROMPT;
			process.env.GIT_TERMINAL_PROMPT = "0";

			try {
				// This should be parsed as a git source, not throw "unsupported"
				try {
					await packageManager.install("https://github.com/nonexistent/repo");
				} catch {
					// Expected to fail - repo doesn't exist
				}
			} finally {
				if (previousGitTerminalPrompt === undefined) {
					delete process.env.GIT_TERMINAL_PROMPT;
				} else {
					process.env.GIT_TERMINAL_PROMPT = previousGitTerminalPrompt;
				}
			}

			// Should have attempted clone, not thrown unsupported error
			expect(events.some((e) => e.type === "start" && e.action === "install")).toBe(true);
		});

		it("should parse package source types from docs examples", () => {
			expect((packageManager as any).parseSource("npm:@scope/pkg@1.2.3").type).toBe("npm");
			expect((packageManager as any).parseSource("npm:pkg").type).toBe("npm");

			expect((packageManager as any).parseSource("git:github.com/user/repo@v1").type).toBe("git");
			expect((packageManager as any).parseSource("https://github.com/user/repo@v1").type).toBe("git");
			expect((packageManager as any).parseSource("git:git@github.com:user/repo@v1").type).toBe("git");
			expect((packageManager as any).parseSource("ssh://git@github.com/user/repo@v1").type).toBe("git");

			expect((packageManager as any).parseSource("/absolute/path/to/package").type).toBe("local");
			expect((packageManager as any).parseSource("./relative/path/to/package").type).toBe("local");
			expect((packageManager as any).parseSource("../relative/path/to/package").type).toBe("local");
		});

		it("should never parse dot-relative paths as git", () => {
			const dotSlash = (packageManager as any).parseSource("./packages/agent-timers");
			expect(dotSlash.type).toBe("local");
			expect(dotSlash.path).toBe("./packages/agent-timers");

			const dotDotSlash = (packageManager as any).parseSource("../packages/agent-timers");
			expect(dotDotSlash.type).toBe("local");
			expect(dotDotSlash.path).toBe("../packages/agent-timers");
		});
	});

	describe("settings source normalization", () => {
		it("should store global local packages relative to agent settings base", () => {
			const pkgDir = join(tempDir, "packages", "local-global-pkg");
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			writeFileSync(join(pkgDir, "extensions", "index.ts"), "export default function() {}");

			const added = packageManager.addSourceToSettings("./packages/local-global-pkg");
			expect(added).toBe(true);

			const settings = settingsManager.getGlobalSettings();
			const rel = relative(agentDir, pkgDir);
			const expected = rel.startsWith(".") ? rel : `./${rel}`;
			expect(settings.packages?.[0]).toBe(expected);
		});

		it("should store project local packages relative to .pi settings base", () => {
			const projectPkgDir = join(tempDir, "project-local-pkg");
			mkdirSync(join(projectPkgDir, "extensions"), { recursive: true });
			writeFileSync(join(projectPkgDir, "extensions", "index.ts"), "export default function() {}");

			const added = packageManager.addSourceToSettings("./project-local-pkg", { local: true });
			expect(added).toBe(true);

			const settings = settingsManager.getProjectSettings();
			const rel = relative(join(tempDir, ".pi"), projectPkgDir);
			const expected = rel.startsWith(".") ? rel : `./${rel}`;
			expect(settings.packages?.[0]).toBe(expected);
		});

		it("should remove local package entries using equivalent path forms", () => {
			const pkgDir = join(tempDir, "remove-local-pkg");
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			writeFileSync(join(pkgDir, "extensions", "index.ts"), "export default function() {}");

			packageManager.addSourceToSettings("./remove-local-pkg");
			const removed = packageManager.removeSourceFromSettings(`${pkgDir}/`);
			expect(removed).toBe(true);
			expect(settingsManager.getGlobalSettings().packages ?? []).toHaveLength(0);
		});
	});

	describe("extension provenance lockfiles", () => {
		it("should write deterministic scope-local lockfiles with normalized provenance", async () => {
			const userPackage = join(tempDir, "user-package");
			const projectPackage = join(tempDir, "project-package");
			writeTypeScriptPackage(userPackage, { name: "user-package", version: "1.0.0" });
			writeWasmPackage(projectPackage, { toolId: "fixture.project" });

			await packageManager.installAndPersist(userPackage);
			await settingsManager.flush();
			const userLockPath = join(agentDir, "extensions.lock.json");
			const projectLockPath = join(tempDir, ".pi", "extensions.lock.json");
			expect(existsSync(userLockPath)).toBe(true);
			expect(existsSync(projectLockPath)).toBe(false);
			const firstUserLockBytes = readFileSync(userLockPath, "utf-8");

			await packageManager.installAndPersist(`${userPackage}/`);
			await settingsManager.flush();
			expect(readFileSync(userLockPath, "utf-8")).toBe(firstUserLockBytes);

			await packageManager.installAndPersist(projectPackage, { local: true });
			await settingsManager.flush();
			expect(readFileSync(userLockPath, "utf-8")).toBe(firstUserLockBytes);
			expect(existsSync(projectLockPath)).toBe(true);

			const userLock = readJsonFile(userLockPath) as {
				schemaVersion: string;
				entries: Array<{
					key: string;
					scope: string;
					source: { type: string; identity: string };
					manifest: { kind: string; packageName: string; packageVersion: string };
					packageRoot: string;
					manifestPath: string;
					digests: { packageRootSha256: string };
				}>;
			};
			expect(firstUserLockBytes.endsWith("\n")).toBe(true);
			expect(userLock.schemaVersion).toBe("pi-extension-lock.v0");
			expect(userLock.entries).toHaveLength(1);
			expect(userLock.entries[0]).toMatchObject({
				key: `local:${realpathSync(userPackage)}`,
				scope: "user",
				source: { type: "local", identity: realpathSync(userPackage) },
				manifest: { kind: "typescript-package", packageName: "user-package", packageVersion: "1.0.0" },
				packageRoot: realpathSync(userPackage),
				manifestPath: join(userPackage, "package.json"),
			});
			expect(userLock.entries[0].digests.packageRootSha256).toMatch(/^[a-f0-9]{64}$/);

			const projectLock = readJsonFile(projectLockPath) as {
				entries: Array<{
					scope: string;
					manifest: { kind: string; schemaVersion: string; id: string; name: string; version: string };
					artifact: { kind: string; path: string; absolutePath: string; sha256: string };
					digests: { packageRootSha256: string };
				}>;
			};
			expect(projectLock.entries).toHaveLength(1);
			expect(projectLock.entries[0]).toMatchObject({
				scope: "project",
				manifest: {
					kind: "wasm-extension",
					schemaVersion: "pi-extension.v0",
					id: "com.example.local-wasm",
					name: "Local Wasm Fixture",
					version: "0.1.0",
				},
				artifact: {
					kind: "wasm-component",
					path: "wasm/plugin.wasm",
					absolutePath: realpathSync(join(projectPackage, "wasm/plugin.wasm")),
				},
			});
			expect(projectLock.entries[0].artifact.sha256).toMatch(/^[a-f0-9]{64}$/);
			expect(projectLock.entries[0].digests.packageRootSha256).toMatch(/^[a-f0-9]{64}$/);
			expect(readFileSync(projectLockPath, "utf-8")).not.toContain("signature");
			expect(readFileSync(projectLockPath, "utf-8")).not.toContain("publisher");
			expect(readFileSync(projectLockPath, "utf-8")).not.toContain("marketplace");
			expect(readFileSync(projectLockPath, "utf-8")).not.toContain("approvalUi");
			expect(readFileSync(projectLockPath, "utf-8")).not.toContain("remoteWasmUrl");
		});

		it("should leave settings and lockfile unchanged when settings persistence fails during install", async () => {
			const storage = new FailNextSettingsStorage({ packages: [] });
			settingsManager = SettingsManager.fromStorage(storage);
			packageManager = new DefaultPackageManager({
				cwd: tempDir,
				agentDir,
				settingsManager,
			});
			const pkgDir = join(tempDir, "settings-failure-package");
			writeTypeScriptPackage(pkgDir, { name: "settings-failure-package" });
			const initialSettingsBytes = storage.read("global");

			storage.failNextWrite("global");
			await expect(packageManager.installAndPersist(pkgDir)).rejects.toThrow(
				"injected global settings write failure",
			);

			expect(storage.read("global")).toBe(initialSettingsBytes);
			expect(settingsManager.getGlobalSettings().packages ?? []).toEqual([]);
			expect(existsSync(join(agentDir, "extensions.lock.json"))).toBe(false);
		});

		it("should atomically refresh local package provenance on update while preserving unrelated entries", async () => {
			const refreshedPackage = join(tempDir, "refreshed-package");
			const unrelatedPackage = join(tempDir, "unrelated-refresh-package");
			writeTypeScriptPackage(refreshedPackage, { name: "refreshed-package", version: "1.0.0" });
			writeTypeScriptPackage(unrelatedPackage, { name: "unrelated-refresh-package", version: "1.0.0" });

			await packageManager.installAndPersist(refreshedPackage);
			await packageManager.installAndPersist(unrelatedPackage);
			await settingsManager.flush();
			const lockPath = join(agentDir, "extensions.lock.json");
			const settingsBeforeUpdate = settingsManager.getGlobalSettings().packages ?? [];
			const lockBeforeUpdate = readJsonFile(lockPath) as {
				entries: Array<{
					key: string;
					manifest: { packageVersion?: string };
					digests: { packageRootSha256: string };
				}>;
			};
			const refreshedKey = `local:${realpathSync(refreshedPackage)}`;
			const unrelatedKey = `local:${realpathSync(unrelatedPackage)}`;
			const refreshedBefore = lockBeforeUpdate.entries.find((entry) => entry.key === refreshedKey);
			const unrelatedBefore = lockBeforeUpdate.entries.find((entry) => entry.key === unrelatedKey);
			expect(refreshedBefore).toBeDefined();
			expect(unrelatedBefore).toBeDefined();

			writeTypeScriptPackage(refreshedPackage, { name: "refreshed-package", version: "1.0.1" });
			await packageManager.update(refreshedPackage);
			await settingsManager.flush();

			expect(settingsManager.getGlobalSettings().packages ?? []).toEqual(settingsBeforeUpdate);
			const lockAfterUpdate = readJsonFile(lockPath) as typeof lockBeforeUpdate;
			const refreshedAfter = lockAfterUpdate.entries.find((entry) => entry.key === refreshedKey);
			const unrelatedAfter = lockAfterUpdate.entries.find((entry) => entry.key === unrelatedKey);
			expect(lockAfterUpdate.entries).toHaveLength(2);
			expect(refreshedAfter?.manifest.packageVersion).toBe("1.0.1");
			expect(refreshedAfter?.digests.packageRootSha256).not.toBe(refreshedBefore?.digests.packageRootSha256);
			expect(unrelatedAfter).toEqual(unrelatedBefore);
		});

		it("should preserve the previous trusted lock entry when a local update fails validation", async () => {
			const pkgDir = join(tempDir, "failed-update-wasm-package");
			writeWasmPackage(pkgDir);

			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();
			const lockPath = join(agentDir, "extensions.lock.json");
			const lockBeforeUpdate = readFileSync(lockPath, "utf-8");

			writeWasmPackage(pkgDir, { artifactBytes: "not wasm" });
			await expect(packageManager.update(pkgDir)).rejects.toThrow(
				"$.artifact.path: artifact file is not a valid Wasm binary",
			);

			expect(readFileSync(lockPath, "utf-8")).toBe(lockBeforeUpdate);
		});

		it("should not trust configured packages from missing or malformed lockfiles", async () => {
			const pkgDir = join(tempDir, "configured-without-lock");
			writeTypeScriptPackage(pkgDir);
			settingsManager.setPackages([pkgDir]);

			const missing = await packageManager.resolve();
			expect(missing.extensions).toHaveLength(0);
			expect(missing.diagnostics).toEqual([
				expect.objectContaining({
					category: "missing_lockfile",
					scope: "user",
					source: pkgDir,
					lockfilePath: join(agentDir, "extensions.lock.json"),
				}),
			]);
			expect(existsSync(join(agentDir, "extensions.lock.json"))).toBe(false);

			const lockPath = join(agentDir, "extensions.lock.json");
			writeFileSync(lockPath, "{");
			const beforeBytes = readFileSync(lockPath, "utf-8");
			const malformed = await packageManager.resolve();
			expect(malformed.extensions).toHaveLength(0);
			expect(malformed.diagnostics).toEqual([
				expect.objectContaining({
					category: "malformed_lockfile",
					scope: "user",
					lockfilePath: lockPath,
					path: "$",
				}),
			]);
			expect(readFileSync(lockPath, "utf-8")).toBe(beforeBytes);
		});

		it("should reject unsupported v0 trust surfaces without trusting partial lock data", async () => {
			const pkgDir = join(tempDir, "unsupported-lock-surface");
			writeTypeScriptPackage(pkgDir);
			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();
			const lockPath = join(agentDir, "extensions.lock.json");
			const lock = readJsonFile(lockPath) as { entries: Array<Record<string, unknown>> };
			lock.entries[0].signature = "not-supported";
			writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`);
			settingsManager.setPackages([pkgDir]);

			const result = await packageManager.resolve();
			expect(result.extensions).toHaveLength(0);
			expect(result.diagnostics).toEqual([
				expect.objectContaining({
					category: "malformed_lockfile",
					scope: "user",
					lockfilePath: lockPath,
					path: "$.entries[0].signature",
				}),
			]);
			expect(readFileSync(lockPath, "utf-8")).toContain("not-supported");
		});

		it("should preserve unrelated lock entries when updating one package", async () => {
			const firstPackage = join(tempDir, "first-package");
			const secondPackage = join(tempDir, "second-package");
			writeTypeScriptPackage(firstPackage, { name: "first-package" });
			writeTypeScriptPackage(secondPackage, { name: "second-package" });

			await packageManager.installAndPersist(firstPackage);
			await settingsManager.flush();
			const lockPath = join(agentDir, "extensions.lock.json");
			const firstEntry = (readJsonFile(lockPath) as { entries: unknown[] }).entries[0];

			await packageManager.installAndPersist(secondPackage);
			await settingsManager.flush();
			const twoEntryLock = readJsonFile(lockPath) as { entries: unknown[] };
			expect(twoEntryLock.entries).toHaveLength(2);
			expect(twoEntryLock.entries).toContainEqual(firstEntry);
		});

		it("should bind package-root digests to trusted package content and ignore fixed host noise", async () => {
			const pkgDir = join(tempDir, "digest-bound-package");
			writeTypeScriptPackage(pkgDir, { name: "digest-bound-package" });
			mkdirSync(join(pkgDir, "lib"), { recursive: true });
			mkdirSync(join(pkgDir, "data"), { recursive: true });
			mkdirSync(join(pkgDir, "prompts"), { recursive: true });
			mkdirSync(join(pkgDir, "skills", "digest-skill"), { recursive: true });
			mkdirSync(join(pkgDir, "themes"), { recursive: true });
			writeFileSync(join(pkgDir, "lib", "helper.js"), "export const helper = 1;\n");
			writeFileSync(join(pkgDir, "data", "config.json"), JSON.stringify({ enabled: true }));
			writeFileSync(join(pkgDir, "prompts", "digest.md"), "Prompt v1\n");
			writeFileSync(
				join(pkgDir, "skills", "digest-skill", "SKILL.md"),
				`---
name: digest-skill
description: Digest skill
---
Skill v1
`,
			);
			writeFileSync(join(pkgDir, "themes", "digest.json"), JSON.stringify({ name: "digest-theme" }));
			writeFileSync(join(pkgDir, ".gitignore"), "dist\n");

			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();
			const lockPath = join(agentDir, "extensions.lock.json");
			const readDigest = () =>
				(
					readJsonFile(lockPath) as {
						entries: Array<{ digests: { packageRootSha256: string } }>;
					}
				).entries[0].digests.packageRootSha256;
			let previousDigest = readDigest();

			const trustedContentMutations = [
				() =>
					writeFileSync(
						join(pkgDir, "package.json"),
						readFileSync(join(pkgDir, "package.json"), "utf-8").replace("1.0.0", "1.0.1"),
					),
				() => writeFileSync(join(pkgDir, "extensions", "entry.ts"), "export default function changed() {}\n"),
				() => writeFileSync(join(pkgDir, "lib", "helper.js"), "export const helper = 2;\n"),
				() => writeFileSync(join(pkgDir, "data", "config.json"), JSON.stringify({ enabled: false })),
				() => writeFileSync(join(pkgDir, "prompts", "digest.md"), "Prompt v2\n"),
				() =>
					writeFileSync(
						join(pkgDir, "skills", "digest-skill", "SKILL.md"),
						`---
name: digest-skill
description: Digest skill
---
Skill v2
`,
					),
				() => writeFileSync(join(pkgDir, "themes", "digest.json"), JSON.stringify({ name: "digest-theme-v2" })),
				() => writeFileSync(join(pkgDir, ".gitignore"), "dist\ncoverage\n"),
			];

			for (const mutateTrustedContent of trustedContentMutations) {
				mutateTrustedContent();
				await packageManager.installAndPersist(pkgDir);
				await settingsManager.flush();
				const nextDigest = readDigest();
				expect(nextDigest).not.toBe(previousDigest);
				previousDigest = nextDigest;
			}

			mkdirSync(join(pkgDir, ".git"), { recursive: true });
			mkdirSync(join(pkgDir, ".pi"), { recursive: true });
			mkdirSync(join(pkgDir, ".cache"), { recursive: true });
			writeFileSync(join(pkgDir, ".git", "HEAD"), "ref: refs/heads/main\n");
			writeFileSync(join(pkgDir, ".pi", "extensions.lock.json"), "{}\n");
			writeFileSync(join(pkgDir, ".cache", "tool-output.json"), JSON.stringify({ timestamp: Date.now() }));
			writeFileSync(join(pkgDir, "package-lock.json"), JSON.stringify({ lockfileVersion: 3 }));

			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();
			expect(readDigest()).toBe(previousDigest);
		});

		it("should reject package-root drift during resolve without refreshing trust and recover after install", async () => {
			const pkgDir = join(tempDir, "resolve-drift-package");
			const entryPath = writeTypeScriptPackage(pkgDir, { name: "resolve-drift-package" });

			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();
			settingsManager.setPackages([pkgDir]);
			const lockPath = join(agentDir, "extensions.lock.json");
			const trustedLockBytes = readFileSync(lockPath, "utf-8");
			const trustedLock = readJsonFile(lockPath) as {
				entries: Array<{ digests: { packageRootSha256: string }; packageRoot: string }>;
			};
			const expectedDigest = trustedLock.entries[0].digests.packageRootSha256;

			writeFileSync(entryPath, "export default function changed() {}\n");
			const drifted = await packageManager.resolve();

			expect(drifted.extensions).toHaveLength(0);
			expect(drifted.diagnostics).toEqual([
				expect.objectContaining({
					category: "package_root_digest_mismatch",
					scope: "user",
					source: pkgDir,
					lockfilePath: lockPath,
					packageRoot: realpathSync(pkgDir),
					expected: expectedDigest,
					phase: "resolve",
				}),
			]);
			expect(drifted.diagnostics[0]?.actual).toMatch(/^[a-f0-9]{64}$/);
			expect(drifted.diagnostics[0]?.actual).not.toBe(expectedDigest);
			expect(readFileSync(lockPath, "utf-8")).toBe(trustedLockBytes);

			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();
			const recovered = await packageManager.resolve();
			expect(recovered.diagnostics).toEqual([]);
			expect(recovered.extensions.some((extension) => extension.path === entryPath)).toBe(true);
		});

		it("should classify Wasm artifact, artifact path, and manifest drift before package-root drift", async () => {
			const artifactDigestPackage = join(tempDir, "artifact-digest-drift-package");
			writeWasmPackage(artifactDigestPackage, {
				artifactBytes: Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x01]),
			});
			await packageManager.installAndPersist(artifactDigestPackage);
			await settingsManager.flush();
			settingsManager.setPackages([artifactDigestPackage]);
			const lockPath = join(agentDir, "extensions.lock.json");
			const digestLock = readJsonFile(lockPath) as {
				entries: Array<{ artifact: { sha256: string; path: string; absolutePath: string } }>;
			};
			writeFileSync(join(artifactDigestPackage, "wasm", "plugin.wasm"), Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x02]));

			const artifactDigestDrift = await packageManager.resolve();
			expect(artifactDigestDrift.wasmExtensions).toHaveLength(0);
			expect(artifactDigestDrift.diagnostics).toEqual([
				expect.objectContaining({
					category: "artifact_digest_mismatch",
					scope: "user",
					source: artifactDigestPackage,
					artifactPath: "wasm/plugin.wasm",
					expected: digestLock.entries[0].artifact.sha256,
				}),
			]);
			expect(artifactDigestDrift.diagnostics[0]?.actual).toMatch(/^[a-f0-9]{64}$/);

			const artifactPathPackage = join(tempDir, "artifact-path-drift-package");
			writeWasmPackage(artifactPathPackage, {
				artifactBytes: Buffer.from([0x00, 0x61, 0x73, 0x6d, 0x03]),
			});
			await packageManager.installAndPersist(artifactPathPackage);
			await settingsManager.flush();
			settingsManager.setPackages([artifactPathPackage]);
			const pathManifest = readJsonFile(join(artifactPathPackage, "pi-extension.json")) as {
				artifact: { path: string };
			};
			mkdirSync(join(artifactPathPackage, "alternate"), { recursive: true });
			writeFileSync(
				join(artifactPathPackage, "alternate", "plugin.wasm"),
				readFileSync(join(artifactPathPackage, "wasm", "plugin.wasm")),
			);
			pathManifest.artifact.path = "alternate/plugin.wasm";
			writeFileSync(join(artifactPathPackage, "pi-extension.json"), JSON.stringify(pathManifest));

			const artifactPathDrift = await packageManager.resolve();
			expect(artifactPathDrift.wasmExtensions).toHaveLength(0);
			expect(artifactPathDrift.diagnostics).toEqual([
				expect.objectContaining({
					category: "artifact_path_mismatch",
					scope: "user",
					source: artifactPathPackage,
					artifactPath: "alternate/plugin.wasm",
					expected: "wasm/plugin.wasm",
					actual: "alternate/plugin.wasm",
				}),
			]);

			const manifestPackage = join(tempDir, "manifest-drift-package");
			writeWasmPackage(manifestPackage, { id: "com.example.original-manifest" });
			await packageManager.installAndPersist(manifestPackage);
			await settingsManager.flush();
			settingsManager.setPackages([manifestPackage]);
			const manifest = readJsonFile(join(manifestPackage, "pi-extension.json")) as { id: string };
			manifest.id = "com.example.changed-manifest";
			writeFileSync(join(manifestPackage, "pi-extension.json"), JSON.stringify(manifest));

			const manifestDrift = await packageManager.resolve();
			expect(manifestDrift.wasmExtensions).toHaveLength(0);
			expect(manifestDrift.diagnostics).toEqual([
				expect.objectContaining({
					category: "manifest_provenance_mismatch",
					scope: "user",
					source: manifestPackage,
					manifestPath: join(manifestPackage, "pi-extension.json"),
					expected: "com.example.original-manifest",
					actual: "com.example.changed-manifest",
				}),
			]);
		});

		it("should deny lockfile source identity and package-root provenance mismatches", async () => {
			const pkgDir = join(tempDir, "identity-mismatch-package");
			writeTypeScriptPackage(pkgDir);
			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();
			settingsManager.setPackages([pkgDir]);
			const lockPath = join(agentDir, "extensions.lock.json");
			const lock = readJsonFile(lockPath) as {
				entries: Array<{ source: { identity: string }; packageRoot: string }>;
			};
			lock.entries[0].source.identity = join(tempDir, "other-source");
			writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`);

			const sourceMismatch = await packageManager.resolve();
			expect(sourceMismatch.extensions).toHaveLength(0);
			expect(sourceMismatch.diagnostics).toEqual([
				expect.objectContaining({
					category: "source_identity_mismatch",
					scope: "user",
					source: pkgDir,
					expected: join(tempDir, "other-source"),
					actual: realpathSync(pkgDir),
				}),
			]);

			lock.entries[0].source.identity = realpathSync(pkgDir);
			lock.entries[0].packageRoot = join(tempDir, "other-root");
			writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`);

			const rootMismatch = await packageManager.resolve();
			expect(rootMismatch.extensions).toHaveLength(0);
			expect(rootMismatch.diagnostics).toEqual([
				expect.objectContaining({
					category: "package_root_mismatch",
					scope: "user",
					source: pkgDir,
					expected: join(tempDir, "other-root"),
					actual: realpathSync(pkgDir),
				}),
			]);
		});

		it("should isolate drift diagnostics to the offending package", async () => {
			const driftedPackage = join(tempDir, "isolated-drift-package");
			const cleanPackage = join(tempDir, "isolated-clean-package");
			const driftedEntry = writeTypeScriptPackage(driftedPackage, { name: "isolated-drift-package" });
			const cleanEntry = writeTypeScriptPackage(cleanPackage, { name: "isolated-clean-package" });

			await packageManager.installAndPersist(driftedPackage);
			await packageManager.installAndPersist(cleanPackage);
			await settingsManager.flush();
			settingsManager.setPackages([driftedPackage, cleanPackage]);
			writeFileSync(driftedEntry, "export default function drifted() {}\n");

			const result = await packageManager.resolve();
			expect(result.extensions.map((extension) => extension.path)).toEqual([cleanEntry]);
			expect(result.diagnostics).toEqual([
				expect.objectContaining({
					category: "package_root_digest_mismatch",
					scope: "user",
					source: driftedPackage,
				}),
			]);
		});

		it("should remove only matching scope-local lock provenance after settings removal", async () => {
			const removedPackage = join(tempDir, "removed-package");
			const unrelatedPackage = join(tempDir, "unrelated-package");
			const projectPackage = join(tempDir, "project-package-for-remove");
			writeTypeScriptPackage(removedPackage, { name: "removed-package" });
			writeTypeScriptPackage(unrelatedPackage, { name: "unrelated-package" });
			writeTypeScriptPackage(projectPackage, { name: "project-package-for-remove" });

			await packageManager.installAndPersist(removedPackage);
			await packageManager.installAndPersist(unrelatedPackage);
			await packageManager.installAndPersist(projectPackage, { local: true });
			await settingsManager.flush();

			const userLockPath = join(agentDir, "extensions.lock.json");
			const projectLockPath = join(tempDir, ".pi", "extensions.lock.json");
			const projectLockBeforeRemove = readFileSync(projectLockPath, "utf-8");
			const unrelatedKey = `local:${realpathSync(unrelatedPackage)}`;
			const removedKey = `local:${realpathSync(removedPackage)}`;

			await expect(packageManager.removeAndPersist(removedPackage)).resolves.toBe(true);
			await settingsManager.flush();

			const userLockAfterRemove = readJsonFile(userLockPath) as {
				entries: Array<{ key: string; packageRoot: string }>;
			};
			expect(userLockAfterRemove.entries.map((entry) => entry.key)).toEqual([unrelatedKey]);
			expect(userLockAfterRemove.entries[0].packageRoot).toBe(realpathSync(unrelatedPackage));
			expect(readFileSync(projectLockPath, "utf-8")).toBe(projectLockBeforeRemove);
			const remainingSettings = settingsManager.getGlobalSettings().packages ?? [];
			expect(remainingSettings).toHaveLength(1);
			expect(realpathSync(join(agentDir, String(remainingSettings[0])))).toBe(realpathSync(unrelatedPackage));

			settingsManager.setPackages([removedPackage, unrelatedPackage]);
			const staleResolve = await packageManager.resolve();
			expect(staleResolve.extensions.some((extension) => extension.metadata.baseDir === removedPackage)).toBe(false);
			expect(staleResolve.extensions.some((extension) => extension.metadata.baseDir === unrelatedPackage)).toBe(
				true,
			);
			expect(staleResolve.diagnostics).toEqual([
				expect.objectContaining({
					category: "missing_lock_entry",
					scope: "user",
					source: removedPackage,
				}),
			]);

			await packageManager.installAndPersist(removedPackage);
			await settingsManager.flush();
			const userLockAfterReinstall = readJsonFile(userLockPath) as {
				entries: Array<{ key: string }>;
			};
			expect(userLockAfterReinstall.entries.map((entry) => entry.key).sort()).toEqual(
				[removedKey, unrelatedKey].sort(),
			);
			const recoveredResolve = await packageManager.resolve();
			expect(recoveredResolve.diagnostics).toEqual([]);
			expect(recoveredResolve.extensions.some((extension) => extension.metadata.baseDir === removedPackage)).toBe(
				true,
			);
		});

		it("should not persist temporary extension source provenance", async () => {
			const pkgDir = join(tempDir, "temporary-source");
			writeTypeScriptPackage(pkgDir);

			const result = await packageManager.resolveExtensionSources([pkgDir], { temporary: true });
			expect(result.extensions).toHaveLength(1);
			expect(existsSync(join(agentDir, "extensions.lock.json"))).toBe(false);
			expect(existsSync(join(tempDir, ".pi", "extensions.lock.json"))).toBe(false);
			expect(result.diagnostics).toEqual([]);
		});
	});

	describe("HTTPS git URL parsing (old behavior)", () => {
		it("should parse HTTPS GitHub URLs correctly", async () => {
			const parsed = (packageManager as any).parseSource("https://github.com/user/repo");
			expect(parsed.type).toBe("git");
			expect(parsed.host).toBe("github.com");
			expect(parsed.path).toBe("user/repo");
			expect(parsed.pinned).toBe(false);
		});

		it("should parse HTTPS URLs with git: prefix", async () => {
			const parsed = (packageManager as any).parseSource("git:https://github.com/user/repo");
			expect(parsed.type).toBe("git");
			expect(parsed.host).toBe("github.com");
			expect(parsed.path).toBe("user/repo");
		});

		it("should parse HTTPS URLs with ref", async () => {
			const parsed = (packageManager as any).parseSource("https://github.com/user/repo@v1.2.3");
			expect(parsed.type).toBe("git");
			expect(parsed.host).toBe("github.com");
			expect(parsed.path).toBe("user/repo");
			expect(parsed.ref).toBe("v1.2.3");
			expect(parsed.pinned).toBe(true);
		});

		it("should parse host/path shorthand only with git: prefix", async () => {
			const parsed = (packageManager as any).parseSource("git:github.com/user/repo");
			expect(parsed.type).toBe("git");
			expect(parsed.host).toBe("github.com");
			expect(parsed.path).toBe("user/repo");
		});

		it("should treat host/path shorthand as local without git: prefix", async () => {
			const parsed = (packageManager as any).parseSource("github.com/user/repo");
			expect(parsed.type).toBe("local");
		});

		it("should parse HTTPS URLs with .git suffix", async () => {
			const parsed = (packageManager as any).parseSource("https://github.com/user/repo.git");
			expect(parsed.type).toBe("git");
			expect(parsed.host).toBe("github.com");
			expect(parsed.path).toBe("user/repo");
		});

		it("should parse GitLab HTTPS URLs", async () => {
			const parsed = (packageManager as any).parseSource("https://gitlab.com/user/repo");
			expect(parsed.type).toBe("git");
			expect(parsed.host).toBe("gitlab.com");
			expect(parsed.path).toBe("user/repo");
		});

		it("should parse Bitbucket HTTPS URLs", async () => {
			const parsed = (packageManager as any).parseSource("https://bitbucket.org/user/repo");
			expect(parsed.type).toBe("git");
			expect(parsed.host).toBe("bitbucket.org");
			expect(parsed.path).toBe("user/repo");
		});

		it("should parse Codeberg HTTPS URLs", async () => {
			const parsed = (packageManager as any).parseSource("https://codeberg.org/user/repo");
			expect(parsed.type).toBe("git");
			expect(parsed.host).toBe("codeberg.org");
			expect(parsed.path).toBe("user/repo");
		});

		it("should generate correct package identity for protocol and git:-prefixed URLs", async () => {
			const identity1 = (packageManager as any).getPackageIdentity("https://github.com/user/repo");
			const identity2 = (packageManager as any).getPackageIdentity("https://github.com/user/repo@v1.0.0");
			const identity3 = (packageManager as any).getPackageIdentity("git:github.com/user/repo");
			const identity4 = (packageManager as any).getPackageIdentity("https://github.com/user/repo.git");

			// All should have the same identity (normalized)
			expect(identity1).toBe("git:github.com/user/repo");
			expect(identity2).toBe("git:github.com/user/repo");
			expect(identity3).toBe("git:github.com/user/repo");
			expect(identity4).toBe("git:github.com/user/repo");
		});

		it("should deduplicate git URLs with different supported formats", async () => {
			const pkgDir = join(tempDir, "https-dedup-pkg");
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			writeFileSync(join(pkgDir, "extensions", "test.ts"), "export default function() {}");

			// Mock the package as if it were cloned from different URL formats
			// In reality, these would all point to the same local dir after install
			settingsManager.setPackages([
				"https://github.com/user/repo",
				"git:github.com/user/repo",
				"https://github.com/user/repo.git",
			]);

			// Since these URLs don't actually exist and we can't clone them,
			// we verify they produce the same identity
			const id1 = (packageManager as any).getPackageIdentity("https://github.com/user/repo");
			const id2 = (packageManager as any).getPackageIdentity("git:github.com/user/repo");
			const id3 = (packageManager as any).getPackageIdentity("https://github.com/user/repo.git");

			expect(id1).toBe(id2);
			expect(id2).toBe(id3);
		});

		it("should handle HTTPS URLs with refs in resolve", async () => {
			// This tests that the ref is properly extracted and stored
			const parsed = (packageManager as any).parseSource("https://github.com/user/repo@main");
			expect(parsed.ref).toBe("main");
			expect(parsed.pinned).toBe(true);

			const parsed2 = (packageManager as any).parseSource("https://github.com/user/repo@feature/branch");
			expect(parsed2.ref).toBe("feature/branch");
		});
	});

	describe("pattern filtering in top-level arrays", () => {
		it("should exclude extensions with ! pattern", async () => {
			const extDir = join(agentDir, "extensions");
			mkdirSync(extDir, { recursive: true });
			writeFileSync(join(extDir, "keep.ts"), "export default function() {}");
			writeFileSync(join(extDir, "remove.ts"), "export default function() {}");

			settingsManager.setExtensionPaths(["extensions", "!**/remove.ts"]);

			const result = await packageManager.resolve();
			expect(result.extensions.some((r) => isEnabled(r, "keep.ts"))).toBe(true);
			expect(result.extensions.some((r) => isDisabled(r, "remove.ts"))).toBe(true);
		});

		it("should filter themes with glob patterns", async () => {
			const themesDir = join(agentDir, "themes");
			mkdirSync(themesDir, { recursive: true });
			writeFileSync(join(themesDir, "dark.json"), "{}");
			writeFileSync(join(themesDir, "light.json"), "{}");
			writeFileSync(join(themesDir, "funky.json"), "{}");

			settingsManager.setThemePaths(["themes", "!funky.json"]);

			const result = await packageManager.resolve();
			expect(result.themes.some((r) => isEnabled(r, "dark.json"))).toBe(true);
			expect(result.themes.some((r) => isEnabled(r, "light.json"))).toBe(true);
			expect(result.themes.some((r) => isDisabled(r, "funky.json"))).toBe(true);
		});

		it("should filter prompts with exclusion pattern", async () => {
			const promptsDir = join(agentDir, "prompts");
			mkdirSync(promptsDir, { recursive: true });
			writeFileSync(join(promptsDir, "review.md"), "Review code");
			writeFileSync(join(promptsDir, "explain.md"), "Explain code");

			settingsManager.setPromptTemplatePaths(["prompts", "!explain.md"]);

			const result = await packageManager.resolve();
			expect(result.prompts.some((r) => isEnabled(r, "review.md"))).toBe(true);
			expect(result.prompts.some((r) => isDisabled(r, "explain.md"))).toBe(true);
		});

		it("should filter skills with exclusion pattern", async () => {
			const skillsDir = join(agentDir, "skills");
			mkdirSync(join(skillsDir, "good-skill"), { recursive: true });
			mkdirSync(join(skillsDir, "bad-skill"), { recursive: true });
			writeFileSync(
				join(skillsDir, "good-skill", "SKILL.md"),
				"---\nname: good-skill\ndescription: Good\n---\nContent",
			);
			writeFileSync(
				join(skillsDir, "bad-skill", "SKILL.md"),
				"---\nname: bad-skill\ndescription: Bad\n---\nContent",
			);

			settingsManager.setSkillPaths(["skills", "!**/bad-skill"]);

			const result = await packageManager.resolve();
			expect(result.skills.some((r) => isEnabled(r, "good-skill", "includes"))).toBe(true);
			expect(result.skills.some((r) => isDisabled(r, "bad-skill", "includes"))).toBe(true);
		});

		it("should work without patterns (backward compatible)", async () => {
			const extDir = join(agentDir, "extensions");
			mkdirSync(extDir, { recursive: true });
			const extPath = join(extDir, "my-ext.ts");
			writeFileSync(extPath, "export default function() {}");

			settingsManager.setExtensionPaths(["extensions/my-ext.ts"]);

			const result = await packageManager.resolve();
			expect(result.extensions.some((r) => r.path === extPath && r.enabled)).toBe(true);
		});
	});

	describe("pattern filtering in pi manifest", () => {
		it("should support glob patterns in manifest extensions", async () => {
			const pkgDir = join(tempDir, "manifest-pkg");
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			mkdirSync(join(pkgDir, "node_modules/dep/extensions"), { recursive: true });
			writeFileSync(join(pkgDir, "extensions", "local.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "node_modules/dep/extensions", "remote.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "node_modules/dep/extensions", "skip.ts"), "export default function() {}");
			writeFileSync(
				join(pkgDir, "package.json"),
				JSON.stringify({
					name: "manifest-pkg",
					pi: {
						extensions: ["extensions", "node_modules/dep/extensions", "!**/skip.ts"],
					},
				}),
			);

			const result = await packageManager.resolveExtensionSources([pkgDir]);
			expect(result.extensions.some((r) => isEnabled(r, "local.ts"))).toBe(true);
			expect(result.extensions.some((r) => isEnabled(r, "remote.ts"))).toBe(true);
			expect(result.extensions.some((r) => pathEndsWith(r.path, "skip.ts"))).toBe(false);
		});

		it("should support glob patterns in manifest skills", async () => {
			const pkgDir = join(tempDir, "skill-manifest-pkg");
			mkdirSync(join(pkgDir, "skills/good-skill"), { recursive: true });
			mkdirSync(join(pkgDir, "skills/bad-skill"), { recursive: true });
			writeFileSync(
				join(pkgDir, "skills/good-skill", "SKILL.md"),
				"---\nname: good-skill\ndescription: Good\n---\nContent",
			);
			writeFileSync(
				join(pkgDir, "skills/bad-skill", "SKILL.md"),
				"---\nname: bad-skill\ndescription: Bad\n---\nContent",
			);
			writeFileSync(
				join(pkgDir, "package.json"),
				JSON.stringify({
					name: "skill-manifest-pkg",
					pi: {
						skills: ["skills", "!**/bad-skill"],
					},
				}),
			);

			const result = await packageManager.resolveExtensionSources([pkgDir]);
			expect(result.skills.some((r) => isEnabled(r, "good-skill", "includes"))).toBe(true);
			expect(result.skills.some((r) => r.path.includes("bad-skill"))).toBe(false);
		});

		it("should expand positive glob manifest entries before collecting skills", async () => {
			const pkgDir = join(tempDir, "skill-manifest-glob-pkg");
			mkdirSync(join(pkgDir, "plugins/pdf-to-markdown/skills/pdf-to-markdown"), { recursive: true });
			mkdirSync(join(pkgDir, "plugins/nutrient-dws/skills/document-processor-api"), { recursive: true });
			writeFileSync(
				join(pkgDir, "plugins/pdf-to-markdown/skills/pdf-to-markdown", "SKILL.md"),
				"---\nname: pdf-to-markdown\ndescription: PDF to Markdown\n---\nContent",
			);
			writeFileSync(
				join(pkgDir, "plugins/nutrient-dws/skills/document-processor-api", "SKILL.md"),
				"---\nname: document-processor-api\ndescription: DWS\n---\nContent",
			);
			writeFileSync(
				join(pkgDir, "package.json"),
				JSON.stringify({
					name: "skill-manifest-glob-pkg",
					pi: {
						skills: ["./plugins/*/skills"],
					},
				}),
			);

			const result = await packageManager.resolveExtensionSources([pkgDir]);
			expect(result.skills.some((r) => isEnabled(r, "pdf-to-markdown", "includes"))).toBe(true);
			expect(result.skills.some((r) => isEnabled(r, "document-processor-api", "includes"))).toBe(true);
		});
	});

	describe("pattern filtering in package filters", () => {
		it("should apply user filters on top of manifest filters (not replace)", async () => {
			// Manifest excludes baz.ts, user excludes bar.ts
			// Result should exclude BOTH
			const pkgDir = join(tempDir, "layered-pkg");
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			writeFileSync(join(pkgDir, "extensions", "foo.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "extensions", "bar.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "extensions", "baz.ts"), "export default function() {}");
			writeFileSync(
				join(pkgDir, "package.json"),
				JSON.stringify({
					name: "layered-pkg",
					pi: {
						extensions: ["extensions", "!**/baz.ts"],
					},
				}),
			);
			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();

			// User filter adds exclusion for bar.ts
			settingsManager.setPackages([
				{
					source: pkgDir,
					extensions: ["!**/bar.ts"],
					skills: [],
					prompts: [],
					themes: [],
				},
			]);

			const result = await packageManager.resolve();
			// foo.ts should be included (not excluded by anyone)
			expect(result.extensions.some((r) => isEnabled(r, "foo.ts"))).toBe(true);
			// bar.ts should be excluded (by user)
			expect(result.extensions.some((r) => isDisabled(r, "bar.ts"))).toBe(true);
			// baz.ts should be excluded (by manifest)
			expect(result.extensions.some((r) => pathEndsWith(r.path, "baz.ts"))).toBe(false);
		});

		it("should exclude extensions from package with ! pattern", async () => {
			const pkgDir = join(tempDir, "pattern-pkg");
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			writeFileSync(join(pkgDir, "extensions", "foo.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "extensions", "bar.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "extensions", "baz.ts"), "export default function() {}");
			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();

			settingsManager.setPackages([
				{
					source: pkgDir,
					extensions: ["!**/baz.ts"],
					skills: [],
					prompts: [],
					themes: [],
				},
			]);

			const result = await packageManager.resolve();
			expect(result.extensions.some((r) => isEnabled(r, "foo.ts"))).toBe(true);
			expect(result.extensions.some((r) => isEnabled(r, "bar.ts"))).toBe(true);
			expect(result.extensions.some((r) => isDisabled(r, "baz.ts"))).toBe(true);
		});

		it("should filter themes from package", async () => {
			const pkgDir = join(tempDir, "theme-pkg");
			mkdirSync(join(pkgDir, "themes"), { recursive: true });
			writeFileSync(join(pkgDir, "themes", "nice.json"), "{}");
			writeFileSync(join(pkgDir, "themes", "ugly.json"), "{}");
			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();

			settingsManager.setPackages([
				{
					source: pkgDir,
					extensions: [],
					skills: [],
					prompts: [],
					themes: ["!ugly.json"],
				},
			]);

			const result = await packageManager.resolve();
			expect(result.themes.some((r) => isEnabled(r, "nice.json"))).toBe(true);
			expect(result.themes.some((r) => isDisabled(r, "ugly.json"))).toBe(true);
		});

		it("should combine include and exclude patterns", async () => {
			const pkgDir = join(tempDir, "combo-pkg");
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			writeFileSync(join(pkgDir, "extensions", "alpha.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "extensions", "beta.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "extensions", "gamma.ts"), "export default function() {}");
			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();

			settingsManager.setPackages([
				{
					source: pkgDir,
					extensions: ["**/alpha.ts", "**/beta.ts", "!**/beta.ts"],
					skills: [],
					prompts: [],
					themes: [],
				},
			]);

			const result = await packageManager.resolve();
			expect(result.extensions.some((r) => isEnabled(r, "alpha.ts"))).toBe(true);
			expect(result.extensions.some((r) => isDisabled(r, "beta.ts"))).toBe(true);
			expect(result.extensions.some((r) => isDisabled(r, "gamma.ts"))).toBe(true);
		});

		it("should work with direct paths (no patterns)", async () => {
			const pkgDir = join(tempDir, "direct-pkg");
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			writeFileSync(join(pkgDir, "extensions", "one.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "extensions", "two.ts"), "export default function() {}");
			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();

			settingsManager.setPackages([
				{
					source: pkgDir,
					extensions: ["extensions/one.ts"],
					skills: [],
					prompts: [],
					themes: [],
				},
			]);

			const result = await packageManager.resolve();
			expect(result.extensions.some((r) => isEnabled(r, "one.ts"))).toBe(true);
			expect(result.extensions.some((r) => isDisabled(r, "two.ts"))).toBe(true);
		});
	});

	describe("force-include patterns", () => {
		it("should force-include extensions with + pattern after exclusion", async () => {
			const extDir = join(agentDir, "extensions");
			mkdirSync(extDir, { recursive: true });
			writeFileSync(join(extDir, "keep.ts"), "export default function() {}");
			writeFileSync(join(extDir, "excluded.ts"), "export default function() {}");
			writeFileSync(join(extDir, "force-back.ts"), "export default function() {}");

			// Exclude all, then force-include one back
			settingsManager.setExtensionPaths(["extensions", "!extensions/*.ts", "+extensions/force-back.ts"]);

			const result = await packageManager.resolve();
			expect(result.extensions.some((r) => isDisabled(r, "keep.ts"))).toBe(true);
			expect(result.extensions.some((r) => isDisabled(r, "excluded.ts"))).toBe(true);
			expect(result.extensions.some((r) => isEnabled(r, "force-back.ts"))).toBe(true);
		});

		it("should force-include overrides exclude in package filters", async () => {
			const pkgDir = join(tempDir, "force-pkg");
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			writeFileSync(join(pkgDir, "extensions", "alpha.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "extensions", "beta.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "extensions", "gamma.ts"), "export default function() {}");
			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();

			settingsManager.setPackages([
				{
					source: pkgDir,
					extensions: ["!**/*.ts", "+extensions/beta.ts"],
					skills: [],
					prompts: [],
					themes: [],
				},
			]);

			const result = await packageManager.resolve();
			expect(result.extensions.some((r) => isDisabled(r, "alpha.ts"))).toBe(true);
			expect(result.extensions.some((r) => isEnabled(r, "beta.ts"))).toBe(true);
			expect(result.extensions.some((r) => isDisabled(r, "gamma.ts"))).toBe(true);
		});

		it("should force-include multiple resources", async () => {
			const pkgDir = join(tempDir, "multi-force-pkg");
			mkdirSync(join(pkgDir, "skills/skill-a"), { recursive: true });
			mkdirSync(join(pkgDir, "skills/skill-b"), { recursive: true });
			mkdirSync(join(pkgDir, "skills/skill-c"), { recursive: true });
			writeFileSync(join(pkgDir, "skills/skill-a", "SKILL.md"), "---\nname: skill-a\ndescription: A\n---\nContent");
			writeFileSync(join(pkgDir, "skills/skill-b", "SKILL.md"), "---\nname: skill-b\ndescription: B\n---\nContent");
			writeFileSync(join(pkgDir, "skills/skill-c", "SKILL.md"), "---\nname: skill-c\ndescription: C\n---\nContent");
			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();

			settingsManager.setPackages([
				{
					source: pkgDir,
					extensions: [],
					skills: ["!**/*", "+skills/skill-a", "+skills/skill-c"],
					prompts: [],
					themes: [],
				},
			]);

			const result = await packageManager.resolve();
			expect(result.skills.some((r) => isEnabled(r, "skill-a", "includes"))).toBe(true);
			expect(result.skills.some((r) => isDisabled(r, "skill-b", "includes"))).toBe(true);
			expect(result.skills.some((r) => isEnabled(r, "skill-c", "includes"))).toBe(true);
		});

		it("should force-include after specific exclusion", async () => {
			const extDir = join(agentDir, "extensions");
			mkdirSync(extDir, { recursive: true });
			writeFileSync(join(extDir, "a.ts"), "export default function() {}");
			writeFileSync(join(extDir, "b.ts"), "export default function() {}");

			// Specifically exclude b.ts, then force it back
			settingsManager.setExtensionPaths(["extensions", "!extensions/b.ts", "+extensions/b.ts"]);

			const result = await packageManager.resolve();
			expect(result.extensions.some((r) => isEnabled(r, "a.ts"))).toBe(true);
			expect(result.extensions.some((r) => isEnabled(r, "b.ts"))).toBe(true);
		});

		it("should handle force-include in manifest patterns", async () => {
			const pkgDir = join(tempDir, "manifest-force-pkg");
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			writeFileSync(join(pkgDir, "extensions", "one.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "extensions", "two.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "extensions", "three.ts"), "export default function() {}");
			writeFileSync(
				join(pkgDir, "package.json"),
				JSON.stringify({
					name: "manifest-force-pkg",
					pi: {
						extensions: ["extensions", "!**/two.ts", "+extensions/two.ts"],
					},
				}),
			);

			const result = await packageManager.resolveExtensionSources([pkgDir]);
			expect(result.extensions.some((r) => isEnabled(r, "one.ts"))).toBe(true);
			expect(result.extensions.some((r) => isEnabled(r, "two.ts"))).toBe(true);
			expect(result.extensions.some((r) => isEnabled(r, "three.ts"))).toBe(true);
		});

		it("should force-include themes", async () => {
			const themesDir = join(agentDir, "themes");
			mkdirSync(themesDir, { recursive: true });
			writeFileSync(join(themesDir, "dark.json"), "{}");
			writeFileSync(join(themesDir, "light.json"), "{}");
			writeFileSync(join(themesDir, "special.json"), "{}");

			settingsManager.setThemePaths(["themes", "!themes/*.json", "+themes/special.json"]);

			const result = await packageManager.resolve();
			expect(result.themes.some((r) => isDisabled(r, "dark.json"))).toBe(true);
			expect(result.themes.some((r) => isDisabled(r, "light.json"))).toBe(true);
			expect(result.themes.some((r) => isEnabled(r, "special.json"))).toBe(true);
		});

		it("should force-include prompts", async () => {
			const promptsDir = join(agentDir, "prompts");
			mkdirSync(promptsDir, { recursive: true });
			writeFileSync(join(promptsDir, "review.md"), "Review");
			writeFileSync(join(promptsDir, "explain.md"), "Explain");
			writeFileSync(join(promptsDir, "debug.md"), "Debug");

			settingsManager.setPromptTemplatePaths(["prompts", "!prompts/*.md", "+prompts/debug.md"]);

			const result = await packageManager.resolve();
			expect(result.prompts.some((r) => isDisabled(r, "review.md"))).toBe(true);
			expect(result.prompts.some((r) => isDisabled(r, "explain.md"))).toBe(true);
			expect(result.prompts.some((r) => isEnabled(r, "debug.md"))).toBe(true);
		});
	});

	describe("force-exclude patterns", () => {
		it("should force-exclude top-level resources", async () => {
			const extDir = join(agentDir, "extensions");
			mkdirSync(extDir, { recursive: true });
			writeFileSync(join(extDir, "alpha.ts"), "export default function() {}");
			writeFileSync(join(extDir, "beta.ts"), "export default function() {}");

			settingsManager.setExtensionPaths(["extensions", "+extensions/alpha.ts", "-extensions/alpha.ts"]);

			const result = await packageManager.resolve();
			expect(result.extensions.some((r) => isDisabled(r, "alpha.ts"))).toBe(true);
			expect(result.extensions.some((r) => isEnabled(r, "beta.ts"))).toBe(true);
		});

		it("should force-exclude in package filters", async () => {
			const pkgDir = join(tempDir, "force-exclude-pkg");
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			writeFileSync(join(pkgDir, "extensions", "alpha.ts"), "export default function() {}");
			writeFileSync(join(pkgDir, "extensions", "beta.ts"), "export default function() {}");
			await packageManager.installAndPersist(pkgDir);
			await settingsManager.flush();

			settingsManager.setPackages([
				{
					source: pkgDir,
					extensions: ["extensions/*.ts", "+extensions/alpha.ts", "-extensions/alpha.ts"],
					skills: [],
					prompts: [],
					themes: [],
				},
			]);

			const result = await packageManager.resolve();
			expect(result.extensions.some((r) => isDisabled(r, "alpha.ts"))).toBe(true);
			expect(result.extensions.some((r) => isEnabled(r, "beta.ts"))).toBe(true);
		});
	});

	describe("package deduplication", () => {
		it("should dedupe same local package in global and project (project wins)", async () => {
			const pkgDir = join(tempDir, "shared-pkg");
			mkdirSync(join(pkgDir, "extensions"), { recursive: true });
			writeFileSync(join(pkgDir, "extensions", "shared.ts"), "export default function() {}");
			await packageManager.installAndPersist(pkgDir);
			await packageManager.installAndPersist(pkgDir, { local: true });
			await settingsManager.flush();

			// Same package in both global and project
			settingsManager.setPackages([pkgDir]); // global
			settingsManager.setProjectPackages([pkgDir]); // project

			// Debug: verify settings are stored correctly
			const globalSettings = settingsManager.getGlobalSettings();
			const projectSettings = settingsManager.getProjectSettings();
			expect(globalSettings.packages).toEqual([pkgDir]);
			expect(projectSettings.packages).toEqual([pkgDir]);

			const result = await packageManager.resolve();
			// Should only appear once (deduped), with project scope
			const sharedPaths = result.extensions.filter((r) => r.path.includes("shared-pkg"));
			expect(sharedPaths.length).toBe(1);
			expect(sharedPaths[0].metadata.scope).toBe("project");
		});

		it("should keep both if different packages", async () => {
			const pkg1Dir = join(tempDir, "pkg1");
			const pkg2Dir = join(tempDir, "pkg2");
			mkdirSync(join(pkg1Dir, "extensions"), { recursive: true });
			mkdirSync(join(pkg2Dir, "extensions"), { recursive: true });
			writeFileSync(join(pkg1Dir, "extensions", "from-pkg1.ts"), "export default function() {}");
			writeFileSync(join(pkg2Dir, "extensions", "from-pkg2.ts"), "export default function() {}");
			await packageManager.installAndPersist(pkg1Dir);
			await packageManager.installAndPersist(pkg2Dir, { local: true });
			await settingsManager.flush();

			settingsManager.setPackages([pkg1Dir]); // global
			settingsManager.setProjectPackages([pkg2Dir]); // project

			const result = await packageManager.resolve();
			expect(result.extensions.some((r) => r.path.includes("pkg1"))).toBe(true);
			expect(result.extensions.some((r) => r.path.includes("pkg2"))).toBe(true);
		});

		it("should dedupe SSH and HTTPS URLs for same repo", async () => {
			// Same repository, different URL formats
			const httpsUrl = "https://github.com/user/repo";
			const sshUrl = "git:git@github.com:user/repo";

			const httpsIdentity = (packageManager as any).getPackageIdentity(httpsUrl);
			const sshIdentity = (packageManager as any).getPackageIdentity(sshUrl);

			// Both should resolve to the same identity
			expect(httpsIdentity).toBe("git:github.com/user/repo");
			expect(sshIdentity).toBe("git:github.com/user/repo");
			expect(httpsIdentity).toBe(sshIdentity);
		});

		it("should dedupe SSH and HTTPS with refs", async () => {
			const httpsUrl = "https://github.com/user/repo@v1.0.0";
			const sshUrl = "git:git@github.com:user/repo@v1.0.0";

			const httpsIdentity = (packageManager as any).getPackageIdentity(httpsUrl);
			const sshIdentity = (packageManager as any).getPackageIdentity(sshUrl);

			// Identity should ignore ref (version)
			expect(httpsIdentity).toBe("git:github.com/user/repo");
			expect(sshIdentity).toBe("git:github.com/user/repo");
			expect(httpsIdentity).toBe(sshIdentity);
		});

		it("should dedupe SSH URL with ssh:// protocol and git@ format", async () => {
			const sshProtocol = "ssh://git@github.com/user/repo";
			const gitAt = "git:git@github.com:user/repo";

			const sshProtocolIdentity = (packageManager as any).getPackageIdentity(sshProtocol);
			const gitAtIdentity = (packageManager as any).getPackageIdentity(gitAt);

			// Both SSH formats should resolve to same identity
			expect(sshProtocolIdentity).toBe("git:github.com/user/repo");
			expect(gitAtIdentity).toBe("git:github.com/user/repo");
			expect(sshProtocolIdentity).toBe(gitAtIdentity);
		});

		it("should dedupe all supported URL formats for same repo", async () => {
			const urls = [
				"https://github.com/user/repo",
				"https://github.com/user/repo.git",
				"ssh://git@github.com/user/repo",
				"git:https://github.com/user/repo",
				"git:github.com/user/repo",
				"git:git@github.com:user/repo",
				"git:git@github.com:user/repo.git",
			];

			const identities = urls.map((url) => (packageManager as any).getPackageIdentity(url));

			// All should produce the same identity
			const uniqueIdentities = [...new Set(identities)];
			expect(uniqueIdentities.length).toBe(1);
			expect(uniqueIdentities[0]).toBe("git:github.com/user/repo");
		});

		it("should keep different repos separate (HTTPS vs SSH)", async () => {
			const repo1Https = "https://github.com/user/repo1";
			const repo2Ssh = "git:git@github.com:user/repo2";

			const id1 = (packageManager as any).getPackageIdentity(repo1Https);
			const id2 = (packageManager as any).getPackageIdentity(repo2Ssh);

			// Different repos should have different identities
			expect(id1).toBe("git:github.com/user/repo1");
			expect(id2).toBe("git:github.com/user/repo2");
			expect(id1).not.toBe(id2);
		});
	});

	describe("multi-file extension discovery (issue #1102)", () => {
		it("should only load index.ts from subdirectories, not helper modules", async () => {
			// Regression test: packages with multi-file extensions in subdirectories
			// should only load the index.ts entry point, not helper modules like agents.ts
			const pkgDir = join(tempDir, "multifile-pkg");
			mkdirSync(join(pkgDir, "extensions", "subagent"), { recursive: true });

			// Main entry point
			writeFileSync(
				join(pkgDir, "extensions", "subagent", "index.ts"),
				`import { helper } from "./agents.js";
export default function(api) { api.registerTool({ name: "test", description: "test", execute: async () => helper() }); }`,
			);
			// Helper module (should NOT be loaded as standalone extension)
			writeFileSync(
				join(pkgDir, "extensions", "subagent", "agents.ts"),
				`export function helper() { return "helper"; }`,
			);
			// Top-level extension file (should be loaded)
			writeFileSync(join(pkgDir, "extensions", "standalone.ts"), "export default function(api) {}");

			const result = await packageManager.resolveExtensionSources([pkgDir]);

			// Should find the index.ts and standalone.ts
			expect(result.extensions.some((r) => pathEndsWith(r.path, "subagent/index.ts") && r.enabled)).toBe(true);
			expect(result.extensions.some((r) => pathEndsWith(r.path, "standalone.ts") && r.enabled)).toBe(true);

			// Should NOT find agents.ts as a standalone extension
			expect(result.extensions.some((r) => pathEndsWith(r.path, "agents.ts"))).toBe(false);
		});

		it("should respect package.json pi.extensions manifest in subdirectories", async () => {
			const pkgDir = join(tempDir, "manifest-subdir-pkg");
			mkdirSync(join(pkgDir, "extensions", "custom"), { recursive: true });

			// Subdirectory with its own manifest
			writeFileSync(
				join(pkgDir, "extensions", "custom", "package.json"),
				JSON.stringify({
					pi: {
						extensions: ["./main.ts"],
					},
				}),
			);
			writeFileSync(join(pkgDir, "extensions", "custom", "main.ts"), "export default function(api) {}");
			writeFileSync(join(pkgDir, "extensions", "custom", "utils.ts"), "export const util = 1;");

			const result = await packageManager.resolveExtensionSources([pkgDir]);

			// Should find main.ts declared in manifest
			expect(result.extensions.some((r) => pathEndsWith(r.path, "custom/main.ts") && r.enabled)).toBe(true);

			// Should NOT find utils.ts (not declared in manifest)
			expect(result.extensions.some((r) => pathEndsWith(r.path, "utils.ts"))).toBe(false);
		});

		it("should handle mixed top-level files and subdirectories", async () => {
			const pkgDir = join(tempDir, "mixed-pkg");
			mkdirSync(join(pkgDir, "extensions", "complex"), { recursive: true });

			// Top-level extension
			writeFileSync(join(pkgDir, "extensions", "simple.ts"), "export default function(api) {}");

			// Subdirectory with index.ts + helpers
			writeFileSync(
				join(pkgDir, "extensions", "complex", "index.ts"),
				"import { a } from './a.js'; export default function(api) {}",
			);
			writeFileSync(join(pkgDir, "extensions", "complex", "a.ts"), "export const a = 1;");
			writeFileSync(join(pkgDir, "extensions", "complex", "b.ts"), "export const b = 2;");

			const result = await packageManager.resolveExtensionSources([pkgDir]);

			// Should find simple.ts and complex/index.ts
			expect(result.extensions.some((r) => pathEndsWith(r.path, "simple.ts") && r.enabled)).toBe(true);
			expect(result.extensions.some((r) => pathEndsWith(r.path, "complex/index.ts") && r.enabled)).toBe(true);

			// Should NOT find helper modules
			expect(result.extensions.some((r) => pathEndsWith(r.path, "complex/a.ts"))).toBe(false);
			expect(result.extensions.some((r) => pathEndsWith(r.path, "complex/b.ts"))).toBe(false);

			// Total should be exactly 2
			expect(result.extensions.filter((r) => r.enabled).length).toBe(2);
		});

		it("should skip subdirectories without index.ts or manifest", async () => {
			const pkgDir = join(tempDir, "no-entry-pkg");
			mkdirSync(join(pkgDir, "extensions", "broken"), { recursive: true });

			// Subdirectory with no index.ts and no manifest
			writeFileSync(join(pkgDir, "extensions", "broken", "helper.ts"), "export const x = 1;");
			writeFileSync(join(pkgDir, "extensions", "broken", "another.ts"), "export const y = 2;");

			// Valid top-level extension
			writeFileSync(join(pkgDir, "extensions", "valid.ts"), "export default function(api) {}");

			const result = await packageManager.resolveExtensionSources([pkgDir]);

			// Should only find the valid top-level extension
			expect(result.extensions.some((r) => pathEndsWith(r.path, "valid.ts") && r.enabled)).toBe(true);
			expect(result.extensions.filter((r) => r.enabled).length).toBe(1);
		});
	});

	describe("offline mode and network timeouts", () => {
		it("should update project npm packages using @latest when newer version is available", async () => {
			const installedPath = join(tempDir, ".pi", "npm", "node_modules", "example");
			mkdirSync(installedPath, { recursive: true });
			writeFileSync(join(installedPath, "package.json"), JSON.stringify({ name: "example", version: "1.0.0" }));
			settingsManager.setProjectPackages(["npm:example"]);

			const runCommandCaptureSpy = vi.spyOn(packageManager as any, "runCommandCapture").mockResolvedValue('"1.2.3"');
			const runCommandSpy = vi.spyOn(packageManager as any, "runCommand").mockResolvedValue(undefined);

			await packageManager.update("npm:example");

			expect(runCommandCaptureSpy).toHaveBeenCalledWith(
				"npm",
				["view", "example", "version", "--json"],
				expect.objectContaining({ cwd: tempDir, timeoutMs: expect.any(Number) }),
			);
			expect(runCommandSpy).toHaveBeenCalledWith(
				"npm",
				["install", "example@latest", "--prefix", join(tempDir, ".pi", "npm")],
				undefined,
			);
		});

		it("should skip project npm update when installed version matches latest", async () => {
			const installedPath = join(tempDir, ".pi", "npm", "node_modules", "example");
			mkdirSync(installedPath, { recursive: true });
			writeFileSync(join(installedPath, "package.json"), JSON.stringify({ name: "example", version: "1.2.3" }));
			settingsManager.setProjectPackages(["npm:example"]);

			const runCommandCaptureSpy = vi.spyOn(packageManager as any, "runCommandCapture").mockResolvedValue('"1.2.3"');
			const runCommandSpy = vi.spyOn(packageManager as any, "runCommand").mockResolvedValue(undefined);

			await packageManager.update("npm:example");

			expect(runCommandCaptureSpy).toHaveBeenCalledWith(
				"npm",
				["view", "example", "version", "--json"],
				expect.objectContaining({ cwd: tempDir, timeoutMs: expect.any(Number) }),
			);
			expect(runCommandSpy).not.toHaveBeenCalled();
		});

		it("should batch npm updates per scope and run git updates in parallel while skipping pinned and current packages", async () => {
			vi.spyOn(packageManager as any, "getGlobalNpmRoot").mockReturnValue(join(agentDir, "node_modules"));

			const userOldPath = join(agentDir, "node_modules", "user-old");
			const userCurrentPath = join(agentDir, "node_modules", "user-current");
			const userUnknownPath = join(agentDir, "node_modules", "user-unknown");
			const projectOldPath = join(tempDir, ".pi", "npm", "node_modules", "project-old");
			const projectCurrentPath = join(tempDir, ".pi", "npm", "node_modules", "project-current");
			const installPaths = [userOldPath, userCurrentPath, userUnknownPath, projectOldPath, projectCurrentPath];
			for (const installPath of installPaths) {
				mkdirSync(installPath, { recursive: true });
			}
			writeFileSync(join(userOldPath, "package.json"), JSON.stringify({ name: "user-old", version: "1.0.0" }));
			writeFileSync(
				join(userCurrentPath, "package.json"),
				JSON.stringify({ name: "user-current", version: "1.0.0" }),
			);
			writeFileSync(
				join(userUnknownPath, "package.json"),
				JSON.stringify({ name: "user-unknown", version: "1.0.0" }),
			);
			writeFileSync(join(projectOldPath, "package.json"), JSON.stringify({ name: "project-old", version: "1.0.0" }));
			writeFileSync(
				join(projectCurrentPath, "package.json"),
				JSON.stringify({ name: "project-current", version: "1.0.0" }),
			);

			settingsManager.setPackages([
				"npm:user-old",
				"npm:user-current",
				"npm:user-unknown",
				"npm:user-pinned@1.0.0",
				"git:github.com/example/user-repo-a",
				"git:github.com/example/user-repo-b",
				"git:github.com/example/user-repo-pinned@v1",
			]);
			settingsManager.setProjectPackages([
				"npm:project-old",
				"npm:project-current",
				"npm:project-missing",
				"git:github.com/example/project-repo-a",
			]);

			const runCommandCaptureSpy = vi
				.spyOn(packageManager as any, "runCommandCapture")
				.mockImplementation(async (...callArgs: unknown[]) => {
					const [_command, args] = callArgs as [string, string[]];
					if (args[0] !== "view") {
						throw new Error(`Unexpected runCommandCapture args: ${args.join(" ")}`);
					}
					switch (args[1]) {
						case "user-old":
						case "project-old":
							return '"2.0.0"';
						case "user-current":
						case "project-current":
							return '"1.0.0"';
						case "user-unknown":
							throw new Error("registry unavailable");
						default:
							throw new Error(`Unexpected package lookup: ${args[1]}`);
					}
				});

			let activeNpmUpdates = 0;
			let maxConcurrentNpmUpdates = 0;
			const runCommandSpy = vi
				.spyOn(packageManager as any, "runCommand")
				.mockImplementation(async (...callArgs: unknown[]) => {
					const [command, args] = callArgs as [string, string[]];
					if (command !== "npm") {
						throw new Error(`Unexpected runCommand call: ${command} ${args.join(" ")}`);
					}
					activeNpmUpdates += 1;
					maxConcurrentNpmUpdates = Math.max(maxConcurrentNpmUpdates, activeNpmUpdates);
					await new Promise((resolve) => setTimeout(resolve, 20));
					activeNpmUpdates -= 1;
				});

			let activeGitUpdates = 0;
			let maxConcurrentGitUpdates = 0;
			const updateGitSpy = vi.spyOn(packageManager as any, "updateGit").mockImplementation(async () => {
				activeGitUpdates += 1;
				maxConcurrentGitUpdates = Math.max(maxConcurrentGitUpdates, activeGitUpdates);
				await new Promise((resolve) => setTimeout(resolve, 20));
				activeGitUpdates -= 1;
			});

			await packageManager.update();

			expect(runCommandCaptureSpy).toHaveBeenCalledTimes(5);
			expect(runCommandSpy).toHaveBeenCalledTimes(2);
			expect(runCommandSpy).toHaveBeenNthCalledWith(
				1,
				"npm",
				["install", "-g", "user-old@latest", "user-unknown@latest"],
				undefined,
			);
			expect(runCommandSpy).toHaveBeenNthCalledWith(
				2,
				"npm",
				["install", "project-old@latest", "project-missing@latest", "--prefix", join(tempDir, ".pi", "npm")],
				undefined,
			);
			expect(updateGitSpy).toHaveBeenCalledTimes(3);
			expect(maxConcurrentNpmUpdates).toBeGreaterThan(1);
			expect(maxConcurrentGitUpdates).toBeGreaterThan(1);
		});

		it("should suggest npm source prefixes for update lookups", async () => {
			settingsManager.setProjectPackages(["npm:example"]);

			await expect(packageManager.update("example")).rejects.toThrow(
				"No matching package found for example. Did you mean npm:example?",
			);
		});

		it("should suggest git source prefixes for update lookups", async () => {
			settingsManager.setProjectPackages(["git:github.com/example/repo"]);

			await expect(packageManager.update("github.com/example/repo")).rejects.toThrow(
				"No matching package found for github.com/example/repo. Did you mean git:github.com/example/repo?",
			);
		});

		it("should skip installing missing package sources when offline", async () => {
			process.env.PI_OFFLINE = "1";
			settingsManager.setProjectPackages(["npm:missing-package", "git:github.com/example/missing-repo"]);

			const installParsedSourceSpy = vi.spyOn(packageManager as any, "installParsedSource");

			const result = await packageManager.resolve();
			const allResources = [...result.extensions, ...result.skills, ...result.prompts, ...result.themes];
			expect(allResources.some((r) => r.metadata.origin === "package")).toBe(false);
			expect(installParsedSourceSpy).not.toHaveBeenCalled();
		});

		it("should skip refreshing temporary git sources when offline", async () => {
			process.env.PI_OFFLINE = "1";
			const gitSource = "git:github.com/example/repo";
			const parsedGitSource = (packageManager as any).parseSource(gitSource);
			const installedPath = (packageManager as any).getGitInstallPath(parsedGitSource, "temporary") as string;

			mkdirSync(join(installedPath, "extensions"), { recursive: true });
			writeFileSync(join(installedPath, "extensions", "index.ts"), "export default function() {};");

			const refreshTemporaryGitSourceSpy = vi.spyOn(packageManager as any, "refreshTemporaryGitSource");

			const result = await packageManager.resolveExtensionSources([gitSource], { temporary: true });
			expect(result.extensions.some((r) => pathEndsWith(r.path, "extensions/index.ts") && r.enabled)).toBe(true);
			expect(refreshTemporaryGitSourceSpy).not.toHaveBeenCalled();
		});

		it("should not run npm view during resolve for installed unpinned packages", async () => {
			const installedPath = join(tempDir, ".pi", "npm", "node_modules", "example");
			mkdirSync(join(installedPath, "extensions"), { recursive: true });
			writeFileSync(join(installedPath, "package.json"), JSON.stringify({ name: "example", version: "1.0.0" }));
			writeFileSync(join(installedPath, "extensions", "index.ts"), "export default function() {};");
			settingsManager.setProjectPackages(["npm:example"]);
			(packageManager as any).writeProvenanceLockForSource("npm:example", "project");

			const runCommandCaptureSpy = vi.spyOn(packageManager as any, "runCommandCapture");

			const result = await packageManager.resolve();
			expect(result.extensions.some((r) => pathEndsWith(r.path, "extensions/index.ts") && r.enabled)).toBe(true);
			expect(runCommandCaptureSpy).not.toHaveBeenCalled();
		});

		it("should reinstall pinned npm packages when installed version does not match", async () => {
			const installedPath = join(tempDir, ".pi", "npm", "node_modules", "example");
			mkdirSync(installedPath, { recursive: true });
			writeFileSync(join(installedPath, "package.json"), JSON.stringify({ name: "example", version: "1.0.0" }));
			settingsManager.setProjectPackages(["npm:example@2.0.0"]);
			(packageManager as any).writeProvenanceLockForSource("npm:example@2.0.0", "project");

			const installParsedSourceSpy = vi
				.spyOn(packageManager as any, "installParsedSource")
				.mockResolvedValue(undefined);

			await packageManager.resolve();
			expect(installParsedSourceSpy).toHaveBeenCalledTimes(1);
		});

		it("should not check package updates when offline", async () => {
			process.env.PI_OFFLINE = "1";
			const runCommandCaptureSpy = vi.spyOn(packageManager as any, "runCommandCapture");

			const updates = await packageManager.checkForAvailableUpdates();
			expect(updates).toEqual([]);
			expect(runCommandCaptureSpy).not.toHaveBeenCalled();
		});

		it("should report updates for installed unpinned npm packages", async () => {
			const installedPath = join(tempDir, ".pi", "npm", "node_modules", "example");
			mkdirSync(installedPath, { recursive: true });
			writeFileSync(join(installedPath, "package.json"), JSON.stringify({ name: "example", version: "1.0.0" }));
			settingsManager.setProjectPackages(["npm:example"]);

			vi.spyOn(packageManager as any, "runCommandCapture").mockResolvedValue('"1.2.3"');

			const updates = await packageManager.checkForAvailableUpdates();
			expect(updates).toEqual([
				{
					source: "npm:example",
					displayName: "example",
					type: "npm",
					scope: "project",
				},
			]);
		});

		it("should skip pinned packages when checking for updates", async () => {
			const installedNpmPath = join(tempDir, ".pi", "npm", "node_modules", "example");
			mkdirSync(installedNpmPath, { recursive: true });
			writeFileSync(join(installedNpmPath, "package.json"), JSON.stringify({ name: "example", version: "1.0.0" }));
			const parsedGitSource = (packageManager as any).parseSource("git:github.com/example/repo@v1");
			const installedGitPath = (packageManager as any).getGitInstallPath(parsedGitSource, "project") as string;
			mkdirSync(installedGitPath, { recursive: true });

			settingsManager.setProjectPackages(["npm:example@1.0.0", "git:github.com/example/repo@v1"]);

			const runCommandCaptureSpy = vi.spyOn(packageManager as any, "runCommandCapture");
			const gitUpdateSpy = vi.spyOn(packageManager as any, "gitHasAvailableUpdate");

			const updates = await packageManager.checkForAvailableUpdates();
			expect(updates).toEqual([]);
			expect(runCommandCaptureSpy).not.toHaveBeenCalled();
			expect(gitUpdateSpy).not.toHaveBeenCalled();
		});

		it("should use npm view to fetch latest version", async () => {
			const runCommandCaptureSpy = vi.spyOn(packageManager as any, "runCommandCapture").mockResolvedValue('"1.2.3"');

			const latest = await (packageManager as any).getLatestNpmVersion("example");
			expect(latest).toBe("1.2.3");
			expect(runCommandCaptureSpy).toHaveBeenCalledTimes(1);
			expect(runCommandCaptureSpy).toHaveBeenCalledWith(
				"npm",
				["view", "example", "version", "--json"],
				expect.objectContaining({ cwd: tempDir, timeoutMs: expect.any(Number) }),
			);
		});

		it("should use npmCommand argv for npm update checks", async () => {
			settingsManager = SettingsManager.inMemory({
				npmCommand: ["mise", "exec", "node@20", "--", "npm"],
			});
			packageManager = new DefaultPackageManager({
				cwd: tempDir,
				agentDir,
				settingsManager,
			});

			const runCommandCaptureSpy = vi.spyOn(packageManager as any, "runCommandCapture").mockResolvedValue('"1.2.3"');

			const latest = await (packageManager as any).getLatestNpmVersion("@scope/pkg");
			expect(latest).toBe("1.2.3");
			expect(runCommandCaptureSpy).toHaveBeenCalledWith(
				"mise",
				["exec", "node@20", "--", "npm", "view", "@scope/pkg", "version", "--json"],
				expect.objectContaining({ cwd: tempDir }),
			);
		});

		it("should wait for close before resolving captured stdout", async () => {
			const managerWithInternals = packageManager as unknown as {
				spawnCaptureCommand(
					command: string,
					args: string[],
					options?: { cwd?: string; env?: Record<string, string> },
				): MockSpawnedProcess;
				runCommandCapture(
					command: string,
					args: string[],
					options?: { cwd?: string; timeoutMs?: number; env?: Record<string, string> },
				): Promise<string>;
			};
			const child = new MockSpawnedProcess();
			vi.spyOn(managerWithInternals, "spawnCaptureCommand").mockReturnValue(child);

			let settled = false;
			const capturePromise = managerWithInternals.runCommandCapture("git", ["rev-parse", "HEAD"]).then((value) => {
				settled = true;
				return value;
			});

			child.emit("exit", 0, null);
			await Promise.resolve();
			expect(settled).toBe(false);

			child.stdout.write("abc123\n");
			child.stdout.end();
			child.emit("close", 0, null);

			await expect(capturePromise).resolves.toBe("abc123");
		});
	});
});
