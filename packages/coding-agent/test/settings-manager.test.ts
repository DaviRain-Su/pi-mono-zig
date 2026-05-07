import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { CANONICAL_EXTENSION_GRANTS, validateExtensionPolicyShape } from "../src/core/extension-policy.js";
import { SettingsManager } from "../src/core/settings-manager.js";

describe("SettingsManager", () => {
	const testDir = join(process.cwd(), "test-settings-tmp");
	const agentDir = join(testDir, "agent");
	const projectDir = join(testDir, "project");

	beforeEach(() => {
		// Clean up and create fresh directories
		if (existsSync(testDir)) {
			rmSync(testDir, { recursive: true });
		}
		mkdirSync(agentDir, { recursive: true });
		mkdirSync(join(projectDir, ".pi"), { recursive: true });
	});

	afterEach(() => {
		if (existsSync(testDir)) {
			rmSync(testDir, { recursive: true });
		}
	});

	describe("extension policy shape", () => {
		it("should separate canonical approved grants from resource limits", () => {
			const policy = validateExtensionPolicyShape({
				approvedGrants: ["agent.delegate", "tool.use"],
				resourceLimits: {
					turns: 2,
					timeoutMs: 1000,
					toolScopes: ["fixture.echo"],
				},
			});

			expect(CANONICAL_EXTENSION_GRANTS).toContain("agent.delegate");
			expect(policy.approvedGrants).toEqual(["agent.delegate", "tool.use"]);
			expect(policy.resourceLimits).toEqual({
				turns: 2,
				timeoutMs: 1000,
				toolScopes: ["fixture.echo"],
			});
		});

		it("should reject unknown grants and malformed resource limits deterministically", () => {
			expect(() => validateExtensionPolicyShape({ approvedGrants: ["agent"] })).toThrow(
				'$.approvedGrants[0]: unknown grant "agent"',
			);
			expect(() => validateExtensionPolicyShape({ approvedGrants: [1] })).toThrow(
				"$.approvedGrants[0]: expected string",
			);
			expect(() => validateExtensionPolicyShape({ resourceLimits: [] })).toThrow(
				"$.resourceLimits: expected object",
			);
			expect(() => validateExtensionPolicyShape({ resourceLimits: { shell: 1 } })).toThrow(
				"$.resourceLimits.shell: unsupported resource limit",
			);
			expect(() => validateExtensionPolicyShape({ resourceLimits: { turns: 1.5 } })).toThrow(
				"$.resourceLimits.turns: expected non-negative integer",
			);
			expect(() =>
				validateExtensionPolicyShape({ resourceLimits: { timeoutMs: Number.MAX_SAFE_INTEGER + 1 } }),
			).toThrow("$.resourceLimits.timeoutMs: expected non-negative integer");
			expect(() => validateExtensionPolicyShape({ resourceLimits: { toolScopes: "fixture.echo" } })).toThrow(
				"$.resourceLimits.toolScopes: expected array",
			);
			expect(() => validateExtensionPolicyShape({ resourceLimits: { toolScopes: [1] } })).toThrow(
				"$.resourceLimits.toolScopes[0]: expected string",
			);
			expect(() => validateExtensionPolicyShape({ resourceLimits: { toolScopes: [""] } })).toThrow(
				"$.resourceLimits.toolScopes[0]: must not be empty",
			);
			expect(() => validateExtensionPolicyShape({ approvalPrompt: true })).toThrow(
				"$.approvalPrompt: unsupported policy field",
			);
		});
	});

	describe("extension policy persistence", () => {
		const identityA = "typescript:local:project:/tmp/policy-a.ts";
		const identityB = "typescript:local:project:/tmp/policy-b.ts";

		it("should round-trip user and project policies without leaking across scopes", async () => {
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(settingsPath, JSON.stringify({ theme: "dark" }));
			rmSync(join(projectDir, ".pi"), { recursive: true });

			const manager = SettingsManager.create(projectDir, agentDir);
			expect(existsSync(join(projectDir, ".pi"))).toBe(false);

			manager.setExtensionPolicy(identityA, {
				approvedGrants: ["agent.delegate"],
				resourceLimits: { turns: 2, toolScopes: ["fixture.echo"] },
			});
			await manager.flush();

			const userRoundTrip = SettingsManager.create(projectDir, agentDir);
			expect(userRoundTrip.getGlobalSettings().extensionPolicies?.[identityA]).toEqual({
				approvedGrants: ["agent.delegate"],
				resourceLimits: { turns: 2, toolScopes: ["fixture.echo"] },
			});
			expect(userRoundTrip.getGlobalSettings().theme).toBe("dark");
			const userSettingsText = readFileSync(settingsPath, "utf-8");
			expect(userSettingsText).toContain('\n  "extensionPolicies":');
			expect(JSON.parse(userSettingsText).extensionPolicies[identityA].approvedGrants).toEqual(["agent.delegate"]);

			userRoundTrip.setProjectExtensionPolicy(identityB, {
				approvedGrants: ["tool.use"],
				resourceLimits: { toolScopes: [] },
			});
			await userRoundTrip.flush();

			const projectSettingsPath = join(projectDir, ".pi", "settings.json");
			const projectRoundTrip = SettingsManager.create(projectDir, agentDir);
			expect(existsSync(projectSettingsPath)).toBe(true);
			expect(projectRoundTrip.getProjectSettings().extensionPolicies?.[identityB]).toEqual({
				approvedGrants: ["tool.use"],
				resourceLimits: { toolScopes: [] },
			});
			expect(projectRoundTrip.getGlobalSettings().extensionPolicies?.[identityB]).toBeUndefined();
		});

		it("should merge effective policies deterministically with project overrides", () => {
			writeFileSync(
				join(agentDir, "settings.json"),
				JSON.stringify({
					extensionPolicies: {
						[identityB]: { approvedGrants: ["file.read"] },
						[identityA]: {
							approvedGrants: ["agent.delegate", "tool.use"],
							resourceLimits: {
								turns: 5,
								timeoutMs: 1000,
								outputLines: 20,
								toolScopes: ["fixture.echo", "fixture.read"],
							},
						},
					},
				}),
			);
			writeFileSync(
				join(projectDir, ".pi", "settings.json"),
				JSON.stringify({
					extensionPolicies: {
						[identityA]: {
							approvedGrants: ["tool.use"],
							resourceLimits: {
								turns: 1,
								toolScopes: [],
							},
						},
					},
				}),
			);

			const manager = SettingsManager.create(projectDir, agentDir);

			expect(manager.getExtensionPolicy(identityA)).toEqual({
				approvedGrants: ["tool.use"],
				resourceLimits: {
					turns: 1,
					timeoutMs: 1000,
					outputLines: 20,
					toolScopes: [],
				},
			});
			expect(manager.getExtensionPolicy(identityB)).toEqual({ approvedGrants: ["file.read"] });
			expect(manager.getExtensionPolicies()).toEqual(manager.getExtensionPolicies());
		});

		it("should keep invalid policy entries granular and preserve valid scopes", () => {
			writeFileSync(
				join(agentDir, "settings.json"),
				JSON.stringify({
					extensionPolicies: {
						[identityA]: { approvedGrants: ["agent.delegate"] },
						[identityB]: { approvedGrants: ["agent"] },
					},
				}),
			);
			writeFileSync(
				join(projectDir, ".pi", "settings.json"),
				JSON.stringify({
					extensionPolicies: {
						[identityB]: { resourceLimits: { turns: 1 } },
					},
				}),
			);

			const manager = SettingsManager.create(projectDir, agentDir);
			const errors = manager.drainErrors();

			expect(errors).toHaveLength(1);
			expect(errors[0]?.scope).toBe("global");
			expect(errors[0]?.error.message).toBe(
				'$.extensionPolicies["typescript:local:project:/tmp/policy-b.ts"].approvedGrants[0]: unknown grant "agent"',
			);
			expect(manager.getGlobalSettings().extensionPolicies?.[identityA]).toEqual({
				approvedGrants: ["agent.delegate"],
			});
			expect(manager.getGlobalSettings().extensionPolicies?.[identityB]).toBeUndefined();
			expect(manager.getExtensionPolicy(identityB)).toEqual({ resourceLimits: { turns: 1 } });
		});

		it("should reject malformed policy maps without dropping unrelated settings", () => {
			writeFileSync(
				join(agentDir, "settings.json"),
				JSON.stringify({
					theme: "dark",
					extensionPolicies: [],
				}),
			);

			const manager = SettingsManager.create(projectDir, agentDir);
			const errors = manager.drainErrors();

			expect(errors).toHaveLength(1);
			expect(errors[0]?.scope).toBe("global");
			expect(errors[0]?.error.message).toBe("$.extensionPolicies: expected object");
			expect(manager.getTheme()).toBe("dark");
			expect(manager.getExtensionPolicies()).toEqual({});
		});

		it("should preserve externally added policy entries when writing unrelated settings", async () => {
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(
				settingsPath,
				JSON.stringify({
					extensionPolicies: {
						[identityA]: { approvedGrants: ["agent.delegate"] },
					},
				}),
			);

			const manager = SettingsManager.create(projectDir, agentDir);
			const currentSettings = JSON.parse(readFileSync(settingsPath, "utf-8"));
			currentSettings.extensionPolicies[identityB] = { resourceLimits: { outputLines: 4 } };
			writeFileSync(settingsPath, JSON.stringify(currentSettings, null, 2));

			manager.setTheme("light");
			await manager.flush();

			const savedSettings = JSON.parse(readFileSync(settingsPath, "utf-8"));
			expect(savedSettings.extensionPolicies[identityA]).toEqual({ approvedGrants: ["agent.delegate"] });
			expect(savedSettings.extensionPolicies[identityB]).toEqual({ resourceLimits: { outputLines: 4 } });
			expect(savedSettings.theme).toBe("light");
		});

		it("should skip writes while policy load errors are active", async () => {
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(
				settingsPath,
				JSON.stringify({
					extensionPolicies: {
						[identityA]: { approvedGrants: ["network"] },
					},
				}),
			);

			const manager = SettingsManager.create(projectDir, agentDir);
			manager.setTheme("light");
			await manager.flush();

			const savedSettings = JSON.parse(readFileSync(settingsPath, "utf-8"));
			expect(savedSettings.theme).toBeUndefined();
			expect(savedSettings.extensionPolicies[identityA]).toEqual({ approvedGrants: ["network"] });
			expect(manager.drainErrors()).toHaveLength(1);
		});

		it("should support in-memory policy tests and reload updates", async () => {
			const manager = SettingsManager.inMemory({
				extensionPolicies: {
					[identityA]: { approvedGrants: ["agent.delegate"] },
				},
			});

			expect(manager.getExtensionPolicy(identityA)).toEqual({ approvedGrants: ["agent.delegate"] });

			manager.setExtensionPolicy(identityB, { resourceLimits: { maxChildren: 0 } });
			await manager.flush();
			await manager.reload();

			expect(manager.getExtensionPolicy(identityA)).toEqual({ approvedGrants: ["agent.delegate"] });
			expect(manager.getExtensionPolicy(identityB)).toEqual({ resourceLimits: { maxChildren: 0 } });
		});
	});

	describe("preserves externally added settings", () => {
		it("should preserve enabledModels when changing thinking level", async () => {
			// Create initial settings file
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(
				settingsPath,
				JSON.stringify({
					theme: "dark",
					defaultModel: "claude-sonnet",
				}),
			);

			// Create SettingsManager (simulates pi starting up)
			const manager = SettingsManager.create(projectDir, agentDir);

			// Simulate user editing settings.json externally to add enabledModels
			const currentSettings = JSON.parse(readFileSync(settingsPath, "utf-8"));
			currentSettings.enabledModels = ["claude-opus-4-5", "gpt-5.2-codex"];
			writeFileSync(settingsPath, JSON.stringify(currentSettings, null, 2));

			// User changes thinking level via Shift+Tab
			manager.setDefaultThinkingLevel("high");
			await manager.flush();

			// Verify enabledModels is preserved
			const savedSettings = JSON.parse(readFileSync(settingsPath, "utf-8"));
			expect(savedSettings.enabledModels).toEqual(["claude-opus-4-5", "gpt-5.2-codex"]);
			expect(savedSettings.defaultThinkingLevel).toBe("high");
			expect(savedSettings.theme).toBe("dark");
			expect(savedSettings.defaultModel).toBe("claude-sonnet");
		});

		it("should preserve custom settings when changing theme", async () => {
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(
				settingsPath,
				JSON.stringify({
					defaultModel: "claude-sonnet",
				}),
			);

			const manager = SettingsManager.create(projectDir, agentDir);

			// User adds custom settings externally
			const currentSettings = JSON.parse(readFileSync(settingsPath, "utf-8"));
			currentSettings.shellPath = "/bin/zsh";
			currentSettings.extensions = ["/path/to/extension.ts"];
			writeFileSync(settingsPath, JSON.stringify(currentSettings, null, 2));

			// User changes theme
			manager.setTheme("light");
			await manager.flush();

			// Verify all settings preserved
			const savedSettings = JSON.parse(readFileSync(settingsPath, "utf-8"));
			expect(savedSettings.shellPath).toBe("/bin/zsh");
			expect(savedSettings.extensions).toEqual(["/path/to/extension.ts"]);
			expect(savedSettings.theme).toBe("light");
		});

		it("should let in-memory changes override file changes for same key", async () => {
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(
				settingsPath,
				JSON.stringify({
					theme: "dark",
				}),
			);

			const manager = SettingsManager.create(projectDir, agentDir);

			// User externally sets thinking level to "low"
			const currentSettings = JSON.parse(readFileSync(settingsPath, "utf-8"));
			currentSettings.defaultThinkingLevel = "low";
			writeFileSync(settingsPath, JSON.stringify(currentSettings, null, 2));

			// But then changes it via UI to "high"
			manager.setDefaultThinkingLevel("high");
			await manager.flush();

			// In-memory change should win
			const savedSettings = JSON.parse(readFileSync(settingsPath, "utf-8"));
			expect(savedSettings.defaultThinkingLevel).toBe("high");
		});
	});

	describe("packages migration", () => {
		it("should keep local-only extensions in extensions array", () => {
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(
				settingsPath,
				JSON.stringify({
					extensions: ["/local/ext.ts", "./relative/ext.ts"],
				}),
			);

			const manager = SettingsManager.create(projectDir, agentDir);

			expect(manager.getPackages()).toEqual([]);
			expect(manager.getExtensionPaths()).toEqual(["/local/ext.ts", "./relative/ext.ts"]);
		});

		it("should handle packages with filtering objects", () => {
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(
				settingsPath,
				JSON.stringify({
					packages: [
						"npm:simple-pkg",
						{
							source: "npm:shitty-extensions",
							extensions: ["extensions/oracle.ts"],
							skills: [],
						},
					],
				}),
			);

			const manager = SettingsManager.create(projectDir, agentDir);

			const packages = manager.getPackages();
			expect(packages).toHaveLength(2);
			expect(packages[0]).toBe("npm:simple-pkg");
			expect(packages[1]).toEqual({
				source: "npm:shitty-extensions",
				extensions: ["extensions/oracle.ts"],
				skills: [],
			});
		});
	});

	describe("reload", () => {
		it("should reload global settings from disk", async () => {
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(
				settingsPath,
				JSON.stringify({
					theme: "dark",
					extensions: ["/before.ts"],
				}),
			);

			const manager = SettingsManager.create(projectDir, agentDir);

			writeFileSync(
				settingsPath,
				JSON.stringify({
					theme: "light",
					extensions: ["/after.ts"],
					defaultModel: "claude-sonnet",
				}),
			);

			await manager.reload();

			expect(manager.getTheme()).toBe("light");
			expect(manager.getExtensionPaths()).toEqual(["/after.ts"]);
			expect(manager.getDefaultModel()).toBe("claude-sonnet");
		});

		it("should keep previous settings when file is invalid", async () => {
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(settingsPath, JSON.stringify({ theme: "dark" }));

			const manager = SettingsManager.create(projectDir, agentDir);

			writeFileSync(settingsPath, "{ invalid json");
			await manager.reload();

			expect(manager.getTheme()).toBe("dark");
		});
	});

	describe("error tracking", () => {
		it("should collect and clear load errors via drainErrors", () => {
			const globalSettingsPath = join(agentDir, "settings.json");
			const projectSettingsPath = join(projectDir, ".pi", "settings.json");
			writeFileSync(globalSettingsPath, "{ invalid global json");
			writeFileSync(projectSettingsPath, "{ invalid project json");

			const manager = SettingsManager.create(projectDir, agentDir);
			const errors = manager.drainErrors();

			expect(errors).toHaveLength(2);
			expect(errors.map((e) => e.scope).sort()).toEqual(["global", "project"]);
			expect(manager.drainErrors()).toEqual([]);
		});
	});

	describe("project settings directory creation", () => {
		it("should not create .pi folder when only reading project settings", () => {
			// Create agent dir with global settings, but NO .pi folder in project
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(settingsPath, JSON.stringify({ theme: "dark" }));

			// Delete the .pi folder that beforeEach created
			rmSync(join(projectDir, ".pi"), { recursive: true });

			// Create SettingsManager (reads both global and project settings)
			const manager = SettingsManager.create(projectDir, agentDir);

			// .pi folder should NOT have been created just from reading
			expect(existsSync(join(projectDir, ".pi"))).toBe(false);

			// Settings should still be loaded from global
			expect(manager.getTheme()).toBe("dark");
		});

		it("should create .pi folder when writing project settings", async () => {
			// Create agent dir with global settings, but NO .pi folder in project
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(settingsPath, JSON.stringify({ theme: "dark" }));

			// Delete the .pi folder that beforeEach created
			rmSync(join(projectDir, ".pi"), { recursive: true });

			const manager = SettingsManager.create(projectDir, agentDir);

			// .pi folder should NOT exist yet
			expect(existsSync(join(projectDir, ".pi"))).toBe(false);

			// Write a project-specific setting
			manager.setProjectPackages([{ source: "npm:test-pkg" }]);
			await manager.flush();

			// Now .pi folder should exist
			expect(existsSync(join(projectDir, ".pi"))).toBe(true);

			// And settings file should be created
			expect(existsSync(join(projectDir, ".pi", "settings.json"))).toBe(true);
		});
	});

	describe("shellCommandPrefix", () => {
		it("should load shellCommandPrefix from settings", () => {
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(settingsPath, JSON.stringify({ shellCommandPrefix: "shopt -s expand_aliases" }));

			const manager = SettingsManager.create(projectDir, agentDir);

			expect(manager.getShellCommandPrefix()).toBe("shopt -s expand_aliases");
		});

		it("should return undefined when shellCommandPrefix is not set", () => {
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(settingsPath, JSON.stringify({ theme: "dark" }));

			const manager = SettingsManager.create(projectDir, agentDir);

			expect(manager.getShellCommandPrefix()).toBeUndefined();
		});

		it("should preserve shellCommandPrefix when saving unrelated settings", async () => {
			const settingsPath = join(agentDir, "settings.json");
			writeFileSync(settingsPath, JSON.stringify({ shellCommandPrefix: "shopt -s expand_aliases" }));

			const manager = SettingsManager.create(projectDir, agentDir);
			manager.setTheme("light");
			await manager.flush();

			const savedSettings = JSON.parse(readFileSync(settingsPath, "utf-8"));
			expect(savedSettings.shellCommandPrefix).toBe("shopt -s expand_aliases");
			expect(savedSettings.theme).toBe("light");
		});
	});

	describe("getSessionDir", () => {
		it("should return undefined when not set", () => {
			writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ theme: "dark" }));
			const manager = SettingsManager.create(projectDir, agentDir);
			expect(manager.getSessionDir()).toBeUndefined();
		});

		it("should return global sessionDir", () => {
			writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ sessionDir: "/tmp/sessions" }));
			const manager = SettingsManager.create(projectDir, agentDir);
			expect(manager.getSessionDir()).toBe("/tmp/sessions");
		});

		it("should return project sessionDir, overriding global", () => {
			writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ sessionDir: "/global/sessions" }));
			writeFileSync(join(projectDir, ".pi", "settings.json"), JSON.stringify({ sessionDir: "./sessions" }));
			const manager = SettingsManager.create(projectDir, agentDir);
			expect(manager.getSessionDir()).toBe("./sessions");
		});

		it("should expand ~ in sessionDir", () => {
			writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ sessionDir: "~/sessions" }));
			const manager = SettingsManager.create(projectDir, agentDir);
			expect(manager.getSessionDir()).toBe(join(homedir(), "sessions"));
		});
	});
});
