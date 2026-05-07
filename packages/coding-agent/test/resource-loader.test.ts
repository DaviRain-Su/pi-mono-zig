import { existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import { ModelRegistry } from "../src/core/model-registry.js";
import { DefaultPackageManager } from "../src/core/package-manager.js";
import { DefaultResourceLoader } from "../src/core/resource-loader.js";
import { SessionManager } from "../src/core/session-manager.js";
import { SettingsManager } from "../src/core/settings-manager.js";
import type { Skill } from "../src/core/skills.js";
import { createSyntheticSourceInfo } from "../src/core/source-info.js";

describe("DefaultResourceLoader", () => {
	let tempDir: string;
	let agentDir: string;
	let cwd: string;

	beforeEach(() => {
		tempDir = join(tmpdir(), `rl-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
		agentDir = join(tempDir, "agent");
		cwd = join(tempDir, "project");
		mkdirSync(agentDir, { recursive: true });
		mkdirSync(cwd, { recursive: true });
	});

	afterEach(() => {
		rmSync(tempDir, { recursive: true, force: true });
	});

	describe("reload", () => {
		it("should initialize with empty results before reload", () => {
			const loader = new DefaultResourceLoader({ cwd, agentDir });

			expect(loader.getExtensions().extensions).toEqual([]);
			expect(loader.getSkills().skills).toEqual([]);
			expect(loader.getPrompts().prompts).toEqual([]);
			expect(loader.getThemes().themes).toEqual([]);
		});

		it("should discover skills from agentDir", async () => {
			const skillsDir = join(agentDir, "skills");
			mkdirSync(skillsDir, { recursive: true });
			writeFileSync(
				join(skillsDir, "test-skill.md"),
				`---
name: test-skill
description: A test skill
---
Skill content here.`,
			);

			const loader = new DefaultResourceLoader({ cwd, agentDir });
			await loader.reload();

			const { skills } = loader.getSkills();
			expect(skills.some((s) => s.name === "test-skill")).toBe(true);
		});

		it("should ignore extra markdown files in auto-discovered skill dirs", async () => {
			const skillDir = join(agentDir, "skills", "pi-skills", "browser-tools");
			mkdirSync(skillDir, { recursive: true });
			writeFileSync(
				join(skillDir, "SKILL.md"),
				`---
name: browser-tools
description: Browser tools
---
Skill content here.`,
			);
			writeFileSync(join(skillDir, "EFFICIENCY.md"), "No frontmatter here");

			const loader = new DefaultResourceLoader({ cwd, agentDir });
			await loader.reload();

			const { skills, diagnostics } = loader.getSkills();
			expect(skills.some((s) => s.name === "browser-tools")).toBe(true);
			expect(diagnostics.some((d) => d.path?.endsWith("EFFICIENCY.md"))).toBe(false);
		});

		it("should discover prompts from agentDir", async () => {
			const promptsDir = join(agentDir, "prompts");
			mkdirSync(promptsDir, { recursive: true });
			writeFileSync(
				join(promptsDir, "test-prompt.md"),
				`---
description: A test prompt
---
Prompt content.`,
			);

			const loader = new DefaultResourceLoader({ cwd, agentDir });
			await loader.reload();

			const { prompts } = loader.getPrompts();
			expect(prompts.some((p) => p.name === "test-prompt")).toBe(true);
		});

		it("should prefer project resources over user on name collisions", async () => {
			const userPromptsDir = join(agentDir, "prompts");
			const projectPromptsDir = join(cwd, ".pi", "prompts");
			mkdirSync(userPromptsDir, { recursive: true });
			mkdirSync(projectPromptsDir, { recursive: true });
			const userPromptPath = join(userPromptsDir, "commit.md");
			const projectPromptPath = join(projectPromptsDir, "commit.md");
			writeFileSync(userPromptPath, "User prompt");
			writeFileSync(projectPromptPath, "Project prompt");

			const userSkillDir = join(agentDir, "skills", "collision-skill");
			const projectSkillDir = join(cwd, ".pi", "skills", "collision-skill");
			mkdirSync(userSkillDir, { recursive: true });
			mkdirSync(projectSkillDir, { recursive: true });
			const userSkillPath = join(userSkillDir, "SKILL.md");
			const projectSkillPath = join(projectSkillDir, "SKILL.md");
			writeFileSync(
				userSkillPath,
				`---
name: collision-skill
description: user
---
User skill`,
			);
			writeFileSync(
				projectSkillPath,
				`---
name: collision-skill
description: project
---
Project skill`,
			);

			const baseTheme = JSON.parse(
				readFileSync(join(process.cwd(), "src", "modes", "interactive", "theme", "dark.json"), "utf-8"),
			) as { name: string; vars?: Record<string, string> };
			baseTheme.name = "collision-theme";
			const userThemePath = join(agentDir, "themes", "collision.json");
			const projectThemePath = join(cwd, ".pi", "themes", "collision.json");
			mkdirSync(join(agentDir, "themes"), { recursive: true });
			mkdirSync(join(cwd, ".pi", "themes"), { recursive: true });
			writeFileSync(userThemePath, JSON.stringify(baseTheme, null, 2));
			if (baseTheme.vars) {
				baseTheme.vars.accent = "#ff00ff";
			}
			writeFileSync(projectThemePath, JSON.stringify(baseTheme, null, 2));

			const loader = new DefaultResourceLoader({ cwd, agentDir });
			await loader.reload();

			const prompt = loader.getPrompts().prompts.find((p) => p.name === "commit");
			expect(prompt?.filePath).toBe(projectPromptPath);

			const skill = loader.getSkills().skills.find((s) => s.name === "collision-skill");
			expect(skill?.filePath).toBe(projectSkillPath);

			const theme = loader.getThemes().themes.find((t) => t.name === "collision-theme");
			expect(theme?.sourcePath).toBe(projectThemePath);
		});

		it("should load symlinked user and project extensions once", async () => {
			const sharedExtDir = join(tempDir, "shared-extensions");
			mkdirSync(sharedExtDir, { recursive: true });
			writeFileSync(
				join(sharedExtDir, "shared.ts"),
				`export default function(pi) {
	pi.registerCommand("shared", {
		description: "shared command",
		handler: async () => {},
	});
}`,
			);

			mkdirSync(agentDir, { recursive: true });
			mkdirSync(join(cwd, ".pi"), { recursive: true });
			symlinkSync(sharedExtDir, join(agentDir, "extensions"), "dir");
			symlinkSync(sharedExtDir, join(cwd, ".pi", "extensions"), "dir");

			const loader = new DefaultResourceLoader({ cwd, agentDir });
			await loader.reload();

			const extensionsResult = loader.getExtensions();
			expect(extensionsResult.extensions).toHaveLength(1);
			expect(extensionsResult.errors).toEqual([]);

			// mergePaths processes project paths before user paths, so the project
			// alias is the canonical survivor.
			expect(extensionsResult.extensions[0].path).toBe(join(cwd, ".pi", "extensions", "shared.ts"));
		});

		it("should assign canonical policy identities to local, inline, and package TypeScript extensions", async () => {
			const projectExtensionDir = join(cwd, ".pi", "extensions");
			mkdirSync(projectExtensionDir, { recursive: true });
			const localExtensionPath = join(projectExtensionDir, "policy-principal.ts");
			writeFileSync(
				localExtensionPath,
				`export default function(pi) {
	pi.registerCommand("mutable-label", { handler: async () => {} });
}`,
			);

			const packageRoot = join(tempDir, "package-with-extension");
			mkdirSync(join(packageRoot, "extensions"), { recursive: true });
			writeFileSync(
				join(packageRoot, "package.json"),
				JSON.stringify({
					name: "fixture-policy-package",
					version: "1.0.0",
					pi: { extensions: ["extensions/entry.ts"] },
				}),
			);
			const packageEntryPath = join(packageRoot, "extensions", "entry.ts");
			writeFileSync(
				packageEntryPath,
				`export default function(pi) {
	pi.registerCommand("package-command", { handler: async () => {} });
}`,
			);
			writeFileSync(
				join(packageRoot, "extensions", "helper.ts"),
				`export default function(pi) {
	pi.registerCommand("undeclared-helper", { handler: async () => {} });
}`,
			);

			const settingsManager = SettingsManager.inMemory({ packages: [packageRoot] });
			const packageManager = new DefaultPackageManager({ cwd, agentDir, settingsManager });
			await packageManager.installAndPersist(packageRoot);
			await settingsManager.flush();
			settingsManager.setPackages([packageRoot]);
			const loader = new DefaultResourceLoader({
				cwd,
				agentDir,
				settingsManager,
				extensionFactories: [
					(pi) => {
						pi.registerCommand("inline-command", { handler: async () => {} });
					},
				],
			});
			await loader.reload();

			const extensions = loader.getExtensions().extensions;
			const byPath = new Map(extensions.map((extension) => [extension.path, extension]));
			const local = byPath.get(localExtensionPath);
			const packaged = byPath.get(packageEntryPath);
			const inline = byPath.get("<inline:1>");

			expect(local?.identity.kind).toBe("typescript-local");
			expect(local?.identity.key).toBe(`typescript:local:project:${localExtensionPath}`);
			expect(local?.identity.sourceInfo.path).toBe(localExtensionPath);
			expect(local?.identity.sourceInfo.scope).toBe("project");
			expect(local?.identity.sourceInfo.origin).toBe("top-level");
			expect(local?.identity.displayName).not.toBe("mutable-label");

			expect(packaged?.identity.kind).toBe("typescript-package");
			const packageLockfile = JSON.parse(readFileSync(join(agentDir, "extensions.lock.json"), "utf-8")) as {
				entries: Array<{ digests: { packageRootSha256: string }; packageRoot: string }>;
			};
			expect(packaged?.identity.key).toContain("typescript:package:user:");
			expect(packaged?.identity.key).toContain("extensions/entry.ts");
			expect(packaged?.identity.key).toContain(packageLockfile.entries[0].packageRoot);
			expect(packaged?.identity.key).toContain(packageLockfile.entries[0].digests.packageRootSha256);
			expect(packaged?.identity.key).toContain(packageEntryPath);
			expect(packaged?.identity.packageSource).toBe(packageRoot);
			expect(packaged?.identity.entryPath).toBe("extensions/entry.ts");
			expect(packaged?.identity.sourceInfo.origin).toBe("package");
			expect(byPath.has(join(packageRoot, "extensions", "helper.ts"))).toBe(false);

			expect(inline?.identity.kind).toBe("typescript-inline");
			expect(inline?.identity.key).toBe("typescript:inline:inline:<inline:1>");
			expect(inline?.identity.resolvedPath).toBe("<inline:1>");
		});

		it("should verify package provenance before importing a drifted TypeScript extension", async () => {
			const packageRoot = join(tempDir, "package-side-effect-guard");
			const sentinelPath = join(tempDir, "tampered-extension-imported");
			mkdirSync(join(packageRoot, "extensions"), { recursive: true });
			writeFileSync(
				join(packageRoot, "package.json"),
				JSON.stringify({
					name: "package-side-effect-guard",
					version: "1.0.0",
					pi: { extensions: ["extensions/entry.ts"] },
				}),
			);
			writeFileSync(
				join(packageRoot, "extensions", "entry.ts"),
				`import { writeFileSync } from "node:fs";
writeFileSync(${JSON.stringify(sentinelPath)}, "imported");
export default function(pi) {
	pi.registerCommand("tampered-command", { handler: async () => {} });
}`,
			);
			writeFileSync(join(packageRoot, "extensions", "helper.ts"), "export const helper = 1;\n");

			const settingsManager = SettingsManager.inMemory({ packages: [packageRoot] });
			const packageManager = new DefaultPackageManager({ cwd, agentDir, settingsManager });
			await packageManager.installAndPersist(packageRoot);
			await settingsManager.flush();
			settingsManager.setPackages([packageRoot]);
			writeFileSync(join(packageRoot, "extensions", "helper.ts"), "export const helper = 2;\n");

			const loader = new DefaultResourceLoader({ cwd, agentDir, settingsManager });
			await loader.reload();

			expect(loader.getExtensions().extensions).toHaveLength(0);
			expect(loader.getExtensions().errors).toEqual([]);
			expect(existsSync(sentinelPath)).toBe(false);
		});

		it("should ignore non-digest package TypeScript policies for locked packages", async () => {
			const packageRoot = join(tempDir, "package-typescript-legacy-policy");
			mkdirSync(join(packageRoot, "extensions"), { recursive: true });
			writeFileSync(
				join(packageRoot, "package.json"),
				JSON.stringify({
					name: "package-typescript-legacy-policy",
					version: "1.0.0",
					pi: { extensions: ["extensions/entry.ts"] },
				}),
			);
			const entryPath = join(packageRoot, "extensions", "entry.ts");
			writeFileSync(
				entryPath,
				`export default function(pi) {
	pi.registerCommand("legacy-package-policy", { handler: async () => {} });
}`,
			);

			const settingsManager = SettingsManager.inMemory({ packages: [packageRoot] });
			const packageManager = new DefaultPackageManager({ cwd, agentDir, settingsManager });
			await packageManager.installAndPersist(packageRoot);
			await settingsManager.flush();
			settingsManager.setPackages([packageRoot]);
			const legacyIdentityKey = `typescript:package:user:${packageRoot}:extensions/entry.ts:${entryPath}`;
			settingsManager.setExtensionPolicy(legacyIdentityKey, {
				approvedGrants: ["agent.delegate"],
				resourceLimits: { turns: 1 },
			});

			const loader = new DefaultResourceLoader({ cwd, agentDir, settingsManager });
			await loader.reload();

			const loaded = loader.getExtensions().extensions.find((extension) => extension.path === entryPath);
			expect(loaded).toBeDefined();
			expect(loaded?.identity.key).not.toBe(legacyIdentityKey);
			expect(loaded?.effectivePolicy).toBeUndefined();
			const lockfile = JSON.parse(readFileSync(join(agentDir, "extensions.lock.json"), "utf-8")) as {
				entries: Array<{ digests: { packageRootSha256: string } }>;
			};
			expect(loaded?.identity.key).toContain(lockfile.entries[0].digests.packageRootSha256);
		});

		it("should snapshot effective extension policy by canonical TypeScript identity on reload", async () => {
			const projectExtensionDir = join(cwd, ".pi", "extensions");
			mkdirSync(projectExtensionDir, { recursive: true });
			const extensionPath = join(projectExtensionDir, "sub-agent.ts");
			const siblingPath = join(projectExtensionDir, "sibling.ts");
			writeFileSync(extensionPath, "export default function() {}");
			writeFileSync(siblingPath, "export default function() {}");

			const settingsManager = SettingsManager.inMemory();
			const loader = new DefaultResourceLoader({ cwd, agentDir, settingsManager });
			await loader.reload();

			const firstLoad = loader.getExtensions().extensions.find((extension) => extension.path === extensionPath);
			const sibling = loader.getExtensions().extensions.find((extension) => extension.path === siblingPath);
			expect(firstLoad).toBeDefined();
			expect(sibling).toBeDefined();
			const identityKey = firstLoad!.identity.key;

			settingsManager.setExtensionPolicy(identityKey, {
				approvedGrants: ["agent.delegate"],
				resourceLimits: { turns: 5, toolScopes: ["read", "write"] },
			});
			settingsManager.setProjectExtensionPolicy(identityKey, {
				resourceLimits: { turns: 1, toolScopes: ["read"] },
			});
			await loader.reload();

			const policyLoad = loader.getExtensions().extensions.find((extension) => extension.path === extensionPath);
			const unrelated = loader.getExtensions().extensions.find((extension) => extension.path === siblingPath);
			expect(policyLoad?.effectivePolicy).toEqual({
				approvedGrants: ["agent.delegate"],
				resourceLimits: { turns: 1, toolScopes: ["read"] },
			});
			expect(unrelated?.effectivePolicy).toBeUndefined();

			settingsManager.setProjectExtensionPolicy(identityKey, {
				approvedGrants: [],
				resourceLimits: { turns: 0, toolScopes: [] },
			});
			expect(policyLoad?.effectivePolicy).toEqual({
				approvedGrants: ["agent.delegate"],
				resourceLimits: { turns: 1, toolScopes: ["read"] },
			});

			await loader.reload();

			const reloaded = loader.getExtensions().extensions.find((extension) => extension.path === extensionPath);
			expect(reloaded?.effectivePolicy).toEqual({
				approvedGrants: [],
				resourceLimits: { turns: 0, toolScopes: [] },
			});
		});

		it("should keep both extensions loaded when command names collide", async () => {
			const userExtDir = join(agentDir, "extensions");
			const projectExtDir = join(cwd, ".pi", "extensions");
			mkdirSync(userExtDir, { recursive: true });
			mkdirSync(projectExtDir, { recursive: true });

			writeFileSync(
				join(projectExtDir, "project.ts"),
				`export default function(pi) {
	pi.registerCommand("deploy", {
		description: "project deploy",
		handler: async () => {},
	});
	pi.registerCommand("project-only", {
		description: "project only",
		handler: async () => {},
	});
}`,
			);

			writeFileSync(
				join(userExtDir, "user.ts"),
				`export default function(pi) {
	pi.registerCommand("deploy", {
		description: "user deploy",
		handler: async () => {},
	});
	pi.registerCommand("user-only", {
		description: "user only",
		handler: async () => {},
	});
}`,
			);

			const loader = new DefaultResourceLoader({ cwd, agentDir });
			await loader.reload();

			const extensionsResult = loader.getExtensions();
			expect(extensionsResult.extensions).toHaveLength(2);
			expect(extensionsResult.errors.some((e) => e.error.includes('Command "/deploy" conflicts'))).toBe(false);

			const sessionManager = SessionManager.inMemory();
			const authStorage = AuthStorage.create(join(tempDir, "auth.json"));
			const modelRegistry = ModelRegistry.create(authStorage);
			const runner = new ExtensionRunner(
				extensionsResult.extensions,
				extensionsResult.runtime,
				cwd,
				sessionManager,
				modelRegistry,
			);

			expect(runner.getCommand("deploy:1")?.description).toBe("project deploy");
			expect(runner.getCommand("deploy:2")?.description).toBe("user deploy");
			expect(runner.getCommand("project-only")?.description).toBe("project only");
			expect(runner.getCommand("user-only")?.description).toBe("user only");

			const commands = runner.getRegisteredCommands();
			expect(commands.map((command) => command.invocationName)).toEqual([
				"deploy:1",
				"project-only",
				"deploy:2",
				"user-only",
			]);
		});

		it("should honor overrides for auto-discovered resources", async () => {
			const settingsManager = SettingsManager.inMemory();
			settingsManager.setExtensionPaths(["-extensions/disabled.ts"]);
			settingsManager.setSkillPaths(["-skills/skip-skill"]);
			settingsManager.setPromptTemplatePaths(["-prompts/skip.md"]);
			settingsManager.setThemePaths(["-themes/skip.json"]);

			const extensionsDir = join(agentDir, "extensions");
			mkdirSync(extensionsDir, { recursive: true });
			writeFileSync(join(extensionsDir, "disabled.ts"), "export default function() {}");

			const skillDir = join(agentDir, "skills", "skip-skill");
			mkdirSync(skillDir, { recursive: true });
			writeFileSync(
				join(skillDir, "SKILL.md"),
				`---
name: skip-skill
description: Skip me
---
Content`,
			);

			const promptsDir = join(agentDir, "prompts");
			mkdirSync(promptsDir, { recursive: true });
			writeFileSync(join(promptsDir, "skip.md"), "Skip prompt");

			const themesDir = join(agentDir, "themes");
			mkdirSync(themesDir, { recursive: true });
			writeFileSync(join(themesDir, "skip.json"), "{}");

			const loader = new DefaultResourceLoader({ cwd, agentDir, settingsManager });
			await loader.reload();

			const { extensions } = loader.getExtensions();
			const { skills } = loader.getSkills();
			const { prompts } = loader.getPrompts();
			const { themes } = loader.getThemes();

			expect(extensions.some((e) => e.path.endsWith("disabled.ts"))).toBe(false);
			expect(skills.some((s) => s.name === "skip-skill")).toBe(false);
			expect(prompts.some((p) => p.name === "skip")).toBe(false);
			expect(themes.some((t) => t.sourcePath?.endsWith("skip.json"))).toBe(false);
		});

		it("should discover AGENTS.md context files", async () => {
			writeFileSync(join(cwd, "AGENTS.md"), "# Project Guidelines\n\nBe helpful.");

			const loader = new DefaultResourceLoader({ cwd, agentDir });
			await loader.reload();

			const { agentsFiles } = loader.getAgentsFiles();
			expect(agentsFiles.some((f) => f.path.includes("AGENTS.md"))).toBe(true);
		});

		it("should skip AGENTS.md and CLAUDE.md discovery when noContextFiles is true", async () => {
			writeFileSync(join(cwd, "AGENTS.md"), "# Project Guidelines\n\nBe helpful.");
			writeFileSync(join(cwd, "CLAUDE.md"), "# Claude Guidelines\n\nBe helpful.");

			const loader = new DefaultResourceLoader({ cwd, agentDir, noContextFiles: true });
			await loader.reload();

			const { agentsFiles } = loader.getAgentsFiles();
			expect(agentsFiles).toEqual([]);
		});

		it("should discover SYSTEM.md from cwd/.pi", async () => {
			const piDir = join(cwd, ".pi");
			mkdirSync(piDir, { recursive: true });
			writeFileSync(join(piDir, "SYSTEM.md"), "You are a helpful assistant.");

			const loader = new DefaultResourceLoader({ cwd, agentDir });
			await loader.reload();

			expect(loader.getSystemPrompt()).toBe("You are a helpful assistant.");
		});

		it("should discover APPEND_SYSTEM.md", async () => {
			const piDir = join(cwd, ".pi");
			mkdirSync(piDir, { recursive: true });
			writeFileSync(join(piDir, "APPEND_SYSTEM.md"), "Additional instructions.");

			const loader = new DefaultResourceLoader({ cwd, agentDir });
			await loader.reload();

			expect(loader.getAppendSystemPrompt()).toContain("Additional instructions.");
		});
	});

	describe("extendResources", () => {
		it("should load skills and prompts with extension metadata", async () => {
			const extraSkillDir = join(tempDir, "extra-skills", "extra-skill");
			mkdirSync(extraSkillDir, { recursive: true });
			const skillPath = join(extraSkillDir, "SKILL.md");
			writeFileSync(
				skillPath,
				`---
name: extra-skill
description: Extra skill
---
Extra content`,
			);

			const extraPromptDir = join(tempDir, "extra-prompts");
			mkdirSync(extraPromptDir, { recursive: true });
			const promptPath = join(extraPromptDir, "extra.md");
			writeFileSync(
				promptPath,
				`---
description: Extra prompt
---
Extra prompt content`,
			);

			const loader = new DefaultResourceLoader({ cwd, agentDir });
			await loader.reload();

			loader.extendResources({
				skillPaths: [
					{
						path: extraSkillDir,
						metadata: {
							source: "extension:extra",
							scope: "temporary",
							origin: "top-level",
							baseDir: extraSkillDir,
						},
					},
				],
				promptPaths: [
					{
						path: promptPath,
						metadata: {
							source: "extension:extra",
							scope: "temporary",
							origin: "top-level",
							baseDir: extraPromptDir,
						},
					},
				],
			});

			const { skills } = loader.getSkills();
			const loadedSkill = skills.find((skill) => skill.name === "extra-skill");
			expect(loadedSkill).toBeDefined();
			expect(loadedSkill?.sourceInfo?.source).toBe("extension:extra");
			expect(loadedSkill?.sourceInfo?.path).toBe(skillPath);

			const { prompts } = loader.getPrompts();
			const loadedPrompt = prompts.find((prompt) => prompt.name === "extra");
			expect(loadedPrompt).toBeDefined();
			expect(loadedPrompt?.sourceInfo?.source).toBe("extension:extra");
			expect(loadedPrompt?.sourceInfo?.path).toBe(promptPath);
		});
	});

	describe("noSkills option", () => {
		it("should skip skill discovery when noSkills is true", async () => {
			const skillsDir = join(agentDir, "skills");
			mkdirSync(skillsDir, { recursive: true });
			writeFileSync(
				join(skillsDir, "test-skill.md"),
				`---
name: test-skill
description: A test skill
---
Content`,
			);

			const loader = new DefaultResourceLoader({ cwd, agentDir, noSkills: true });
			await loader.reload();

			const { skills } = loader.getSkills();
			expect(skills).toEqual([]);
		});

		it("should still load additional skill paths when noSkills is true", async () => {
			const customSkillDir = join(tempDir, "custom-skills");
			mkdirSync(customSkillDir, { recursive: true });
			writeFileSync(
				join(customSkillDir, "custom.md"),
				`---
name: custom
description: Custom skill
---
Content`,
			);

			const loader = new DefaultResourceLoader({
				cwd,
				agentDir,
				noSkills: true,
				additionalSkillPaths: [customSkillDir],
			});
			await loader.reload();

			const { skills } = loader.getSkills();
			expect(skills.some((s) => s.name === "custom")).toBe(true);
		});
	});

	describe("override functions", () => {
		it("should apply skillsOverride", async () => {
			const injectedSkill: Skill = {
				name: "injected",
				description: "Injected skill",
				filePath: "/fake/path",
				baseDir: "/fake",
				sourceInfo: createSyntheticSourceInfo("/fake/path", { source: "custom" }),
				disableModelInvocation: false,
			};
			const loader = new DefaultResourceLoader({
				cwd,
				agentDir,
				skillsOverride: () => ({
					skills: [injectedSkill],
					diagnostics: [],
				}),
			});
			await loader.reload();

			const { skills } = loader.getSkills();
			expect(skills).toHaveLength(1);
			expect(skills[0].name).toBe("injected");
		});

		it("should apply systemPromptOverride", async () => {
			const loader = new DefaultResourceLoader({
				cwd,
				agentDir,
				systemPromptOverride: () => "Custom system prompt",
			});
			await loader.reload();

			expect(loader.getSystemPrompt()).toBe("Custom system prompt");
		});
	});

	describe("extension conflict detection", () => {
		it("should detect tool conflicts between extensions", async () => {
			// Create two extensions that register the same tool
			const ext1Dir = join(agentDir, "extensions", "ext1");
			const ext2Dir = join(agentDir, "extensions", "ext2");
			mkdirSync(ext1Dir, { recursive: true });
			mkdirSync(ext2Dir, { recursive: true });

			writeFileSync(
				join(ext1Dir, "index.ts"),
				`
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
export default function(pi: ExtensionAPI) {
  pi.registerTool({
    name: "duplicate-tool",
    description: "First",
    parameters: Type.Object({}),
    execute: async () => ({ result: "1" }),
  });
}`,
			);

			writeFileSync(
				join(ext2Dir, "index.ts"),
				`
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
export default function(pi: ExtensionAPI) {
  pi.registerTool({
    name: "duplicate-tool",
    description: "Second",
    parameters: Type.Object({}),
    execute: async () => ({ result: "2" }),
  });
}`,
			);

			const loader = new DefaultResourceLoader({ cwd, agentDir });
			await loader.reload();

			const { errors } = loader.getExtensions();
			expect(errors.some((e) => e.error.includes("duplicate-tool") && e.error.includes("conflicts"))).toBe(true);
		});

		it("should prefer explicit CLI extensions over discovered extensions when commands and tools conflict", async () => {
			const globalExtDir = join(agentDir, "extensions");
			mkdirSync(globalExtDir, { recursive: true });
			const explicitExtPath = join(tempDir, "explicit-extension.ts");

			writeFileSync(
				join(globalExtDir, "global.ts"),
				`
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
export default function(pi: ExtensionAPI) {
  pi.registerTool({
    name: "duplicate-tool",
    description: "global tool",
    parameters: Type.Object({}),
    execute: async () => ({ result: "global" }),
  });
  pi.registerCommand("deploy", {
    description: "global command",
    handler: async () => {},
  });
}`,
			);

			writeFileSync(
				explicitExtPath,
				`
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
export default function(pi: ExtensionAPI) {
  pi.registerTool({
    name: "duplicate-tool",
    description: "explicit tool",
    parameters: Type.Object({}),
    execute: async () => ({ result: "explicit" }),
  });
  pi.registerCommand("deploy", {
    description: "explicit command",
    handler: async () => {},
  });
}`,
			);

			const loader = new DefaultResourceLoader({
				cwd,
				agentDir,
				additionalExtensionPaths: [explicitExtPath],
			});
			await loader.reload();

			const extensionsResult = loader.getExtensions();
			expect(extensionsResult.extensions[0]?.path).toBe(explicitExtPath);

			const sessionManager = SessionManager.inMemory();
			const authStorage = AuthStorage.create(join(tempDir, "auth-explicit.json"));
			const modelRegistry = ModelRegistry.create(authStorage);
			const runner = new ExtensionRunner(
				extensionsResult.extensions,
				extensionsResult.runtime,
				cwd,
				sessionManager,
				modelRegistry,
			);

			expect(runner.getCommand("deploy:1")?.description).toBe("explicit command");
			expect(runner.getCommand("deploy:2")?.description).toBe("global command");
			expect(runner.getToolDefinition("duplicate-tool")?.description).toBe("explicit tool");
		});
	});
});
