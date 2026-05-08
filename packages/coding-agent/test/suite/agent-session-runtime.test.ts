import { existsSync, mkdirSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fauxAssistantMessage, fauxToolCall, registerFauxProvider } from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it } from "vitest";
import {
	type CreateAgentSessionRuntimeFactory,
	createAgentSessionFromServices,
	createAgentSessionRuntime,
	createAgentSessionServices,
} from "../../src/core/agent-session-runtime.js";
import { AuthStorage } from "../../src/core/auth-storage.js";
import {
	createSubAgentExtension,
	SUB_AGENT_DELEGATION_RESULT_ENTRY,
	SUB_AGENT_READINESS_ENTRY,
	SUB_AGENT_STATUS_MESSAGE,
} from "../../src/core/extensions/subagent-extension.js";
import { convertToLlm } from "../../src/core/messages.js";
import { SessionManager } from "../../src/core/session-manager.js";
import type {
	ExtensionAPI,
	ExtensionFactory,
	SessionBeforeForkEvent,
	SessionBeforeSwitchEvent,
	SessionShutdownEvent,
	SessionStartEvent,
} from "../../src/index.js";
import { createHarness, type Harness } from "./harness.js";

type RecordedSessionEvent =
	| SessionBeforeSwitchEvent
	| SessionBeforeForkEvent
	| SessionShutdownEvent
	| SessionStartEvent;

describe("AgentSessionRuntime characterization", () => {
	const cleanups: Array<() => Promise<void> | void> = [];

	afterEach(async () => {
		while (cleanups.length > 0) {
			await cleanups.pop()?.();
		}
	});

	async function createRuntimeForTest(
		extensionFactory: ExtensionFactory,
		options?: { cwd?: string; bootstrapModel?: boolean; bootstrapThinkingLevel?: boolean },
	) {
		const tempDir =
			options?.cwd ?? join(tmpdir(), `pi-runtime-suite-${Date.now()}-${Math.random().toString(36).slice(2)}`);
		mkdirSync(tempDir, { recursive: true });

		const faux = registerFauxProvider({
			models: [
				{ id: "faux-1", reasoning: true },
				{ id: "faux-2", reasoning: false },
			],
		});
		faux.setResponses([fauxAssistantMessage("one"), fauxAssistantMessage("two"), fauxAssistantMessage("three")]);

		const authStorage = AuthStorage.inMemory();
		authStorage.setRuntimeApiKey(faux.getModel().provider, "faux-key");
		const fauxProviderConfig = {
			baseUrl: faux.getModel().baseUrl,
			apiKey: "faux-key",
			api: faux.api,
			models: faux.models.map((registeredModel) => ({
				id: registeredModel.id,
				name: registeredModel.name,
				api: registeredModel.api,
				reasoning: registeredModel.reasoning,
				input: registeredModel.input,
				cost: registeredModel.cost,
				contextWindow: registeredModel.contextWindow,
				maxTokens: registeredModel.maxTokens,
			})),
		};

		const runtimeOptions = {
			agentDir: tempDir,
			authStorage,
			model: options?.bootstrapModel === false ? undefined : faux.getModel(),
			thinkingLevel: options?.bootstrapThinkingLevel === false ? undefined : undefined,
			resourceLoaderOptions: {
				extensionFactories: [extensionFactory],
				noSkills: true,
				noPromptTemplates: true,
				noThemes: true,
			},
		};
		const createRuntime: CreateAgentSessionRuntimeFactory = async ({ cwd, sessionManager, sessionStartEvent }) => {
			const services = await createAgentSessionServices({
				...runtimeOptions,
				cwd,
			});
			services.modelRegistry.registerProvider(faux.getModel().provider, fauxProviderConfig);
			return {
				...(await createAgentSessionFromServices({
					services,
					sessionManager,
					sessionStartEvent,
					model: runtimeOptions.model,
					thinkingLevel: runtimeOptions.thinkingLevel,
				})),
				services,
				diagnostics: services.diagnostics,
			};
		};
		const runtime = await createAgentSessionRuntime(createRuntime, {
			cwd: tempDir,
			agentDir: tempDir,
			sessionManager: SessionManager.create(tempDir),
		});
		await runtime.session.bindExtensions({});

		cleanups.push(async () => {
			await runtime.dispose();
			faux.unregister();
			if (existsSync(tempDir)) {
				rmSync(tempDir, { recursive: true, force: true });
			}
		});

		return { runtime, faux, tempDir };
	}

	it("persists message_end assistant replacements to the session manager", async () => {
		const { runtime } = await createRuntimeForTest((pi: ExtensionAPI) => {
			pi.on("message_end", (event) => {
				if (event.message.role !== "assistant") return;

				return {
					message: {
						...event.message,
						usage: {
							...event.message.usage,
							cost: {
								...event.message.usage.cost,
								total: 0.123,
							},
						},
					},
				};
			});
		});

		await runtime.session.prompt("hello");

		const sessionAssistant = runtime.session.messages.find((message) => message.role === "assistant");
		expect(sessionAssistant?.role).toBe("assistant");
		if (sessionAssistant?.role !== "assistant") {
			throw new Error("missing assistant message");
		}
		expect(sessionAssistant.usage.cost.total).toBe(0.123);

		const persistedAssistant = runtime.session.sessionManager
			.getEntries()
			.filter((entry) => entry.type === "message")
			.map((entry) => entry.message)
			.find((message) => message.role === "assistant");
		expect(persistedAssistant?.role).toBe("assistant");
		if (persistedAssistant?.role !== "assistant") {
			throw new Error("missing persisted assistant message");
		}
		expect(persistedAssistant.usage.cost.total).toBe(0.123);
	});

	it("emits session_before_switch and session_start for new and resume flows", async () => {
		const events: RecordedSessionEvent[] = [];
		const { runtime } = await createRuntimeForTest((pi: ExtensionAPI) => {
			pi.on("session_before_switch", (event) => {
				events.push(event);
			});
			pi.on("session_shutdown", (event) => {
				events.push(event);
			});
			pi.on("session_start", (event) => {
				events.push(event);
			});
		});

		expect(events).toEqual([{ type: "session_start", reason: "startup" }]);
		events.length = 0;

		await runtime.session.prompt("hello");
		const originalSessionFile = runtime.session.sessionFile;
		const originalSession = runtime.session;

		const newSessionResult = await runtime.newSession();
		expect(newSessionResult.cancelled).toBe(false);
		await runtime.session.bindExtensions({});
		expect(runtime.session).not.toBe(originalSession);
		expect(runtime.session.messages).toEqual([]);
		const secondSessionFile = runtime.session.sessionFile;
		expect(events).toEqual([
			{ type: "session_before_switch", reason: "new", targetSessionFile: undefined },
			{ type: "session_shutdown", reason: "new", targetSessionFile: secondSessionFile },
			{ type: "session_start", reason: "new", previousSessionFile: originalSessionFile },
		]);

		events.length = 0;

		const switchResult = await runtime.switchSession(originalSessionFile!);
		expect(switchResult.cancelled).toBe(false);
		await runtime.session.bindExtensions({});
		expect(events).toEqual([
			{ type: "session_before_switch", reason: "resume", targetSessionFile: originalSessionFile },
			{ type: "session_shutdown", reason: "resume", targetSessionFile: originalSessionFile },
			{ type: "session_start", reason: "resume", previousSessionFile: secondSessionFile },
		]);
	});

	it("honors session_before_switch cancellation for new and resume", async () => {
		const events: RecordedSessionEvent[] = [];
		let cancelReason: "new" | "resume" | undefined;
		const { runtime } = await createRuntimeForTest((pi: ExtensionAPI) => {
			pi.on("session_before_switch", (event) => {
				events.push(event);
				if (event.reason === cancelReason) {
					return { cancel: true };
				}
			});
			pi.on("session_start", (event) => {
				events.push(event);
			});
		});

		await runtime.session.prompt("hello");
		const originalSessionFile = runtime.session.sessionFile;

		cancelReason = "new";
		const newResult = await runtime.newSession();
		expect(newResult.cancelled).toBe(true);
		expect(runtime.session.sessionFile).toBe(originalSessionFile);

		events.length = 0;
		const otherDir = join(tmpdir(), `pi-runtime-other-${Date.now()}-${Math.random().toString(36).slice(2)}`);
		mkdirSync(otherDir, { recursive: true });
		const otherSession = SessionManager.create(otherDir);
		otherSession.appendMessage({ role: "user", content: [{ type: "text", text: "other" }], timestamp: Date.now() });
		const otherSessionFile = otherSession.getSessionFile();
		cancelReason = "resume";
		const resumeResult = await runtime.switchSession(otherSessionFile!);
		expect(resumeResult.cancelled).toBe(true);
		expect(runtime.session.sessionFile).toBe(originalSessionFile);
	});

	it("emits session_before_fork and session_start and honors cancellation", async () => {
		const events: RecordedSessionEvent[] = [];
		let cancelNextFork = false;
		const { runtime } = await createRuntimeForTest((pi: ExtensionAPI) => {
			pi.on("session_before_fork", (event) => {
				events.push(event);
				if (cancelNextFork) {
					cancelNextFork = false;
					return { cancel: true };
				}
			});
			pi.on("session_shutdown", (event) => {
				events.push(event);
			});
			pi.on("session_start", (event) => {
				events.push(event);
			});
		});

		events.length = 0;
		await runtime.session.prompt("hello");
		const userMessage = runtime.session.getUserMessagesForForking()[0]!;
		const previousSessionFile = runtime.session.sessionFile;

		const successResult = await runtime.fork(userMessage.entryId);
		expect(successResult.cancelled).toBe(false);
		expect(successResult.selectedText).toBe("hello");
		await runtime.session.bindExtensions({});
		expect(events).toEqual([
			{ type: "session_before_fork", entryId: userMessage.entryId, position: "before" },
			{ type: "session_shutdown", reason: "fork", targetSessionFile: runtime.session.sessionFile },
			{ type: "session_start", reason: "fork", previousSessionFile },
		]);

		events.length = 0;
		cancelNextFork = true;
		const cancelResult = await runtime.fork(userMessage.entryId);
		expect(cancelResult).toEqual({ cancelled: true });
		expect(events).toEqual([{ type: "session_before_fork", entryId: userMessage.entryId, position: "before" }]);

		events.length = 0;
		cancelNextFork = true;
		const cancelAtResult = await runtime.fork("missing-entry", { position: "at" });
		expect(cancelAtResult).toEqual({ cancelled: true });
		expect(events).toEqual([{ type: "session_before_fork", entryId: "missing-entry", position: "at" }]);
	});

	it("duplicates the current active branch when forking at the current position", async () => {
		const { runtime } = await createRuntimeForTest(() => {});
		await runtime.session.prompt("hello");
		await runtime.session.prompt("again");

		const beforeMessages = runtime.session.messages.map((message) => ({
			role: message.role,
			text:
				message.role === "user"
					? typeof message.content === "string"
						? message.content
						: message.content
								.filter((part): part is { type: "text"; text: string } => part.type === "text")
								.map((part) => part.text)
								.join("")
					: undefined,
		}));
		const previousSessionFile = runtime.session.sessionFile;
		const leafId = runtime.session.sessionManager.getLeafId();
		expect(leafId).toBeTruthy();

		const result = await runtime.fork(leafId!, { position: "at" });
		expect(result).toEqual({ cancelled: false, selectedText: undefined });
		expect(runtime.session.sessionFile).not.toBe(previousSessionFile);
		expect(
			runtime.session.messages.map((message) => ({
				role: message.role,
				text:
					message.role === "user"
						? typeof message.content === "string"
							? message.content
							: message.content
									.filter((part): part is { type: "text"; text: string } => part.type === "text")
									.map((part) => part.text)
									.join("")
						: undefined,
			})),
		).toEqual(beforeMessages);
	});

	it("duplicates the current active branch in-memory when forking at the current position", async () => {
		const tempDir = join(tmpdir(), `pi-runtime-suite-in-memory-${Date.now()}-${Math.random().toString(36).slice(2)}`);
		mkdirSync(tempDir, { recursive: true });

		const faux = registerFauxProvider({
			models: [
				{ id: "faux-1", reasoning: true },
				{ id: "faux-2", reasoning: false },
			],
		});
		faux.setResponses([fauxAssistantMessage("one"), fauxAssistantMessage("two"), fauxAssistantMessage("three")]);

		const authStorage = AuthStorage.inMemory();
		authStorage.setRuntimeApiKey(faux.getModel().provider, "faux-key");

		const runtimeOptions = {
			agentDir: tempDir,
			authStorage,
			model: faux.getModel(),
			resourceLoaderOptions: {
				extensionFactories: [
					(pi: ExtensionAPI) => {
						pi.registerProvider(faux.getModel().provider, {
							baseUrl: faux.getModel().baseUrl,
							apiKey: "faux-key",
							api: faux.api,
							models: faux.models.map((registeredModel) => ({
								id: registeredModel.id,
								name: registeredModel.name,
								api: registeredModel.api,
								reasoning: registeredModel.reasoning,
								input: registeredModel.input,
								cost: registeredModel.cost,
								contextWindow: registeredModel.contextWindow,
								maxTokens: registeredModel.maxTokens,
							})),
						});
					},
				],
				noSkills: true,
				noPromptTemplates: true,
				noThemes: true,
			},
		};
		const createRuntime: CreateAgentSessionRuntimeFactory = async ({ cwd, sessionManager, sessionStartEvent }) => {
			const services = await createAgentSessionServices({
				...runtimeOptions,
				cwd,
			});
			return {
				...(await createAgentSessionFromServices({
					services,
					sessionManager,
					sessionStartEvent,
					model: runtimeOptions.model,
				})),
				services,
				diagnostics: services.diagnostics,
			};
		};
		const runtime = await createAgentSessionRuntime(createRuntime, {
			cwd: tempDir,
			agentDir: tempDir,
			sessionManager: SessionManager.inMemory(tempDir),
		});
		await runtime.session.bindExtensions({});
		cleanups.push(async () => {
			await runtime.dispose();
			faux.unregister();
			if (existsSync(tempDir)) {
				rmSync(tempDir, { recursive: true, force: true });
			}
		});

		await runtime.session.prompt("hello");
		await runtime.session.prompt("again");

		const beforeMessages = runtime.session.messages.map((message) => ({
			role: message.role,
			text:
				message.role === "user"
					? typeof message.content === "string"
						? message.content
						: message.content
								.filter((part): part is { type: "text"; text: string } => part.type === "text")
								.map((part) => part.text)
								.join("")
					: undefined,
		}));
		const leafId = runtime.session.sessionManager.getLeafId();
		expect(leafId).toBeTruthy();
		expect(runtime.session.sessionFile).toBeUndefined();

		const result = await runtime.fork(leafId!, { position: "at" });
		expect(result).toEqual({ cancelled: false, selectedText: undefined });
		expect(runtime.session.sessionFile).toBeUndefined();
		expect(
			runtime.session.messages.map((message) => ({
				role: message.role,
				text:
					message.role === "user"
						? typeof message.content === "string"
							? message.content
							: message.content
									.filter((part): part is { type: "text"; text: string } => part.type === "text")
									.map((part) => part.text)
									.join("")
						: undefined,
			})),
		).toEqual(beforeMessages);
	});

	it("throws when forking with an invalid entry id", async () => {
		const { runtime } = await createRuntimeForTest(() => {});
		await expect(runtime.fork("missing-entry")).rejects.toThrow("Invalid entry ID for forking");
	});

	it("updates the runtime session cwd on cross-cwd session replacement", async () => {
		const firstDir = join(tmpdir(), `pi-runtime-cwd-a-${Date.now()}-${Math.random().toString(36).slice(2)}`);
		const secondDir = join(tmpdir(), `pi-runtime-cwd-b-${Date.now()}-${Math.random().toString(36).slice(2)}`);
		mkdirSync(firstDir, { recursive: true });
		mkdirSync(secondDir, { recursive: true });
		const { runtime, faux, tempDir } = await createRuntimeForTest(() => {}, { cwd: firstDir });
		const otherAuthStorage = AuthStorage.inMemory();
		otherAuthStorage.setRuntimeApiKey(faux.getModel().provider, "faux-key");
		const otherRuntimeOptions = {
			agentDir: tempDir,
			authStorage: otherAuthStorage,
			resourceLoaderOptions: {
				noSkills: true,
				noPromptTemplates: true,
				noThemes: true,
			},
		};
		const otherProviderConfig = {
			baseUrl: faux.getModel().baseUrl,
			apiKey: "faux-key",
			api: faux.api,
			models: faux.models.map((registeredModel) => ({
				id: registeredModel.id,
				name: registeredModel.name,
				api: registeredModel.api,
				reasoning: registeredModel.reasoning,
				input: registeredModel.input,
				cost: registeredModel.cost,
				contextWindow: registeredModel.contextWindow,
				maxTokens: registeredModel.maxTokens,
			})),
		};
		const createOtherRuntime: CreateAgentSessionRuntimeFactory = async ({
			cwd,
			sessionManager,
			sessionStartEvent,
		}) => {
			const services = await createAgentSessionServices({
				...otherRuntimeOptions,
				cwd,
			});
			services.modelRegistry.registerProvider(faux.getModel().provider, otherProviderConfig);
			return {
				...(await createAgentSessionFromServices({
					services,
					sessionManager,
					sessionStartEvent,
				})),
				services,
				diagnostics: services.diagnostics,
			};
		};
		const otherRuntime = await createAgentSessionRuntime(createOtherRuntime, {
			cwd: secondDir,
			agentDir: tempDir,
			sessionManager: SessionManager.create(secondDir),
		});
		cleanups.push(async () => {
			await otherRuntime.dispose();
		});
		await otherRuntime.session.prompt("other");
		const otherSessionFile = otherRuntime.session.sessionFile!;

		await runtime.switchSession(otherSessionFile);

		expect(realpathSync(runtime.session.sessionManager.getCwd())).toBe(realpathSync(secondDir));
		expect(realpathSync(runtime.cwd)).toBe(realpathSync(secondDir));
	});

	it("restores model and thinking state from the destination session", async () => {
		const { runtime, faux, tempDir } = await createRuntimeForTest(() => {}, {
			bootstrapModel: false,
			bootstrapThinkingLevel: false,
		});
		const otherDir = join(tempDir, "other");
		mkdirSync(otherDir, { recursive: true });
		const otherAuthStorage = AuthStorage.inMemory();
		otherAuthStorage.setRuntimeApiKey(faux.getModel().provider, "faux-key");
		const otherRuntimeOptions = {
			agentDir: tempDir,
			authStorage: otherAuthStorage,
			resourceLoaderOptions: {
				noSkills: true,
				noPromptTemplates: true,
				noThemes: true,
			},
		};
		const otherProviderConfig = {
			baseUrl: faux.getModel().baseUrl,
			apiKey: "faux-key",
			api: faux.api,
			models: faux.models.map((registeredModel) => ({
				id: registeredModel.id,
				name: registeredModel.name,
				api: registeredModel.api,
				reasoning: registeredModel.reasoning,
				input: registeredModel.input,
				cost: registeredModel.cost,
				contextWindow: registeredModel.contextWindow,
				maxTokens: registeredModel.maxTokens,
			})),
		};
		const createOtherRuntime: CreateAgentSessionRuntimeFactory = async ({
			cwd,
			sessionManager,
			sessionStartEvent,
		}) => {
			const services = await createAgentSessionServices({
				...otherRuntimeOptions,
				cwd,
			});
			services.modelRegistry.registerProvider(faux.getModel().provider, otherProviderConfig);
			return {
				...(await createAgentSessionFromServices({
					services,
					sessionManager,
					sessionStartEvent,
				})),
				services,
				diagnostics: services.diagnostics,
			};
		};
		const otherRuntime = await createAgentSessionRuntime(createOtherRuntime, {
			cwd: otherDir,
			agentDir: tempDir,
			sessionManager: SessionManager.create(otherDir),
		});
		cleanups.push(async () => {
			await otherRuntime.dispose();
		});
		await otherRuntime.session.setModel(faux.getModel("faux-2")!);
		otherRuntime.session.setThinkingLevel("off");
		await otherRuntime.session.prompt("hello");
		const targetSessionFile = otherRuntime.session.sessionFile!;

		await runtime.switchSession(targetSessionFile);

		expect(runtime.session.model?.id).toBe("faux-2");
		expect(runtime.session.thinkingLevel).toBe("off");
	});

	it("keeps sub-agent replay records and status details outside model-visible context", async () => {
		let delegateCalls = 0;
		const harness: Harness = await createHarness({
			extensionFactories: [
				createSubAgentExtension({
					approvedCapabilities: ["agent.delegate"],
					delegate: (invocation) => {
						delegateCalls++;
						return {
							type: "sub_agent_task_result",
							agentId: invocation.agentId,
							runId: invocation.runId,
							taskId: invocation.taskId,
							sessionId: invocation.sessionId,
							parentAgentId: invocation.parentAgentId,
							status: "completed",
							content: [{ type: "text", text: "agent-session delegated" }],
							startedAt: 10,
							completedAt: 20,
							resourceSummary: {
								turns: 1,
								outputBytes: 23,
								outputLines: 1,
								childrenStarted: 1,
							},
						};
					},
				}),
			],
		});
		cleanups.push(() => harness.cleanup());

		const payload = {
			agentId: "agent-runtime",
			runId: "run-runtime",
			taskId: "task-runtime",
			sessionId: "session-runtime",
			parentAgentId: "parent-runtime",
			route: "runtime-route",
			input: { prompt: "delegate from runtime" },
			limits: { maxChildren: 1, depth: 1, turns: 1, outputBytes: 256, outputLines: 5 },
		};

		await harness.session.prompt(`/sub-agent ${JSON.stringify(payload)}`);

		expect(delegateCalls).toBe(1);
		expect(harness.getPendingResponseCount()).toBe(0);
		const entries = harness.sessionManager.getEntries();
		const customTypes = entries.filter((entry) => entry.type === "custom").map((entry) => entry.customType);
		expect(customTypes).toEqual([SUB_AGENT_READINESS_ENTRY, SUB_AGENT_DELEGATION_RESULT_ENTRY]);
		const statusEntry = entries.find(
			(entry) => entry.type === "custom_message" && entry.customType === SUB_AGENT_STATUS_MESSAGE,
		);
		expect(statusEntry).toMatchObject({
			type: "custom_message",
			customType: SUB_AGENT_STATUS_MESSAGE,
			content: "completed",
			details: { type: "sub_agent_task_result", taskId: "task-runtime", status: "completed" },
		});

		const context = harness.sessionManager.buildSessionContext();
		expect(context.messages).toHaveLength(1);
		expect(context.messages[0]).toMatchObject({
			role: "custom",
			customType: SUB_AGENT_STATUS_MESSAGE,
			content: "completed",
		});
		const modelVisibleStatus = JSON.stringify(convertToLlm(context.messages));
		expect(modelVisibleStatus).toContain("completed");
		expect(modelVisibleStatus).not.toContain("sub_agent_task_invocation");
		expect(modelVisibleStatus).not.toContain("sub_agent_task_result");
		expect(modelVisibleStatus).not.toContain("agent-session delegated");

		harness.setResponses([
			(providerRequest) => {
				const modelVisibleMessages = JSON.stringify(providerRequest.messages);
				expect(modelVisibleMessages).toContain("completed");
				expect(modelVisibleMessages).not.toContain("sub_agent_task_invocation");
				expect(modelVisibleMessages).not.toContain("sub_agent_task_result");
				expect(modelVisibleMessages).not.toContain("agent-session delegated");
				return fauxAssistantMessage("after status boundary");
			},
		]);

		await harness.session.prompt("continue after sub-agent status");

		expect(delegateCalls).toBe(1);
	});

	it("routes assistant sub-agent tool calls through bounded delegation with read-only observations", async () => {
		let delegateCalls = 0;
		const observed: Array<{ type: string; taskId: string; phase: string; readOnly: true }> = [];
		const payload = {
			agentId: "agent-toolcall",
			runId: "run-toolcall",
			taskId: "task-toolcall",
			sessionId: "session-toolcall",
			toolCallId: "tool-call-toolcall",
			parentAgentId: "parent-toolcall",
			route: "assistant-tool-call",
			input: { prompt: "delegate from assistant tool call" },
			limits: { maxChildren: 1, depth: 1, turns: 1, outputBytes: 256, outputLines: 5 },
		};
		const harness: Harness = await createHarness({
			extensionFactories: [
				createSubAgentExtension({
					approvedCapabilities: ["agent.delegate"],
					delegate: (invocation) => {
						delegateCalls++;
						return {
							type: "sub_agent_task_result",
							agentId: invocation.agentId,
							runId: invocation.runId,
							taskId: invocation.taskId,
							sessionId: invocation.sessionId,
							toolCallId: invocation.toolCallId,
							parentAgentId: invocation.parentAgentId,
							status: "completed",
							content: [{ type: "text", text: "assistant tool-call delegated" }],
							startedAt: 100,
							completedAt: 200,
							resourceSummary: {
								turns: 1,
								outputBytes: 29,
								outputLines: 1,
								childrenStarted: 1,
							},
						};
					},
				}),
				(pi) => {
					pi.on("sub_agent_readiness", (event) => {
						observed.push({
							type: event.envelope.type,
							taskId: event.envelope.taskId,
							phase: event.phase,
							readOnly: event.readOnly,
						});
						return { cancel: true, automaticSpawn: true } as unknown as undefined;
					});
				},
			],
		});
		cleanups.push(() => harness.cleanup());

		harness.setResponses([
			fauxAssistantMessage(fauxToolCall("sub_agent.delegate", payload, { id: "tool-call-toolcall" }), {
				stopReason: "toolUse",
			}),
			(providerRequest) => {
				const toolResult = providerRequest.messages.find((message) => message.role === "toolResult");
				const toolText =
					toolResult?.role === "toolResult"
						? toolResult.content
								.filter((part): part is { type: "text"; text: string } => part.type === "text")
								.map((part) => part.text)
								.join("\n")
						: "";
				expect(toolText).toContain("assistant tool-call delegated");
				expect(toolText).toContain('"type":"sub_agent_task_result"');
				return fauxAssistantMessage("after assistant tool-call");
			},
		]);

		await harness.session.prompt("delegate using the sub-agent tool");

		expect(delegateCalls).toBe(1);
		expect(observed).toEqual([
			{ type: "sub_agent_task_invocation", taskId: "task-toolcall", phase: "recorded", readOnly: true },
			{ type: "sub_agent_task_result", taskId: "task-toolcall", phase: "recorded", readOnly: true },
		]);
		const entries = harness.sessionManager.getEntries();
		expect(entries.filter((entry) => entry.type === "custom").map((entry) => entry.customType)).toEqual([
			SUB_AGENT_READINESS_ENTRY,
			SUB_AGENT_DELEGATION_RESULT_ENTRY,
		]);
		const toolResult = harness.session.messages.find(
			(message) => message.role === "toolResult" && message.toolName === "sub_agent.delegate",
		);
		expect(toolResult).toMatchObject({
			role: "toolResult",
			toolCallId: "tool-call-toolcall",
			isError: false,
		});
		expect(JSON.stringify(toolResult)).toContain("assistant tool-call delegated");

		harness.setResponses([
			fauxAssistantMessage(fauxToolCall("sub_agent.delegate", payload, { id: "tool-call-toolcall-replay" }), {
				stopReason: "toolUse",
			}),
			fauxAssistantMessage("after replay"),
		]);

		await harness.session.prompt("delegate using the sub-agent tool again");

		expect(delegateCalls).toBe(1);
		expect(observed.at(-1)).toEqual({
			type: "sub_agent_task_result",
			taskId: "task-toolcall",
			phase: "replayed",
			readOnly: true,
		});
		expect(entries.filter((entry) => entry.type === "custom")).toHaveLength(2);
	});
});
