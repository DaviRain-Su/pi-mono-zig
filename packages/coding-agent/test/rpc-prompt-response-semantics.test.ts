import { existsSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Agent } from "@earendil-works/pi-agent-core";
import {
	type AssistantMessage,
	type AssistantMessageEvent,
	EventStream,
	getModel,
	type Model,
} from "@earendil-works/pi-ai";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AgentSession } from "../src/core/agent-session.js";
import type { AgentSessionRuntime } from "../src/core/agent-session-runtime.js";
import { AuthStorage } from "../src/core/auth-storage.js";
import type { ExtensionFactory } from "../src/core/extensions/index.js";
import { createSubAgentExtension, SUB_AGENT_STATUS_MESSAGE } from "../src/core/extensions/subagent-extension.js";
import { ModelRegistry } from "../src/core/model-registry.js";
import { SessionManager } from "../src/core/session-manager.js";
import { SettingsManager } from "../src/core/settings-manager.js";
import { runRpcMode } from "../src/modes/rpc/rpc-mode.js";
import { createTestExtensionsResult, createTestResourceLoader } from "./utilities.js";

const rpcIo = vi.hoisted(() => ({
	outputLines: [] as string[],
	lineHandler: undefined as ((line: string) => void) | undefined,
}));

vi.mock("../src/core/output-guard.js", () => ({
	takeOverStdout: vi.fn(),
	writeRawStdout: (line: string) => {
		rpcIo.outputLines.push(line);
	},
}));

vi.mock("../src/modes/interactive/theme/theme.js", () => ({ theme: {} }));

vi.mock("../src/modes/rpc/jsonl.js", () => ({
	attachJsonlLineReader: vi.fn((_stream: NodeJS.ReadableStream, onLine: (line: string) => void) => {
		rpcIo.lineHandler = onLine;
		return () => {};
	}),
	serializeJsonLine: (value: unknown) => `${JSON.stringify(value)}\n`,
}));

class MockAssistantStream extends EventStream<AssistantMessageEvent, AssistantMessage> {
	constructor() {
		super(
			(event) => event.type === "done" || event.type === "error",
			(event) => {
				if (event.type === "done") return event.message;
				if (event.type === "error") return event.error;
				throw new Error("Unexpected event type");
			},
		);
	}
}

function createAssistantMessage(text: string): AssistantMessage {
	return {
		role: "assistant",
		content: [{ type: "text", text }],
		api: "anthropic-messages",
		provider: "anthropic",
		model: "claude-sonnet-4-5",
		usage: {
			input: 0,
			output: 0,
			cacheRead: 0,
			cacheWrite: 0,
			totalTokens: 0,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
		},
		stopReason: "stop",
		timestamp: Date.now(),
	};
}

type ParsedOutputLine = Record<string, unknown>;

function parseOutputLines(outputLines: string[]): ParsedOutputLine[] {
	return outputLines
		.flatMap((line) => line.split("\n"))
		.filter((line) => line.trim().length > 0)
		.map((line) => JSON.parse(line) as ParsedOutputLine);
}

function getPromptResponses(outputLines: string[], id: string): ParsedOutputLine[] {
	return parseOutputLines(outputLines).filter(
		(record) => record.id === id && record.type === "response" && record.command === "prompt",
	);
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

async function createRuntimeHost(options: {
	withAuth: boolean;
	responseDelayMs: number;
	model?: Model<any>;
	extensionFactories?: ExtensionFactory[];
	onProviderCall?: () => void;
}): Promise<{
	runtimeHost: AgentSessionRuntime;
	cleanup: () => Promise<void>;
}> {
	const tempDir = join(tmpdir(), `pi-rpc-prompt-${Date.now()}-${Math.random().toString(36).slice(2)}`);
	mkdirSync(tempDir, { recursive: true });

	const model = options.model ?? getModel("anthropic", "claude-sonnet-4-5");
	if (!model) {
		throw new Error("Test model not found");
	}

	const agent = new Agent({
		getApiKey: () => "test-key",
		initialState: {
			model,
			systemPrompt: "Test",
			tools: [],
		},
		streamFn: (_model, _context, _options) => {
			options.onProviderCall?.();
			const stream = new MockAssistantStream();
			queueMicrotask(() => {
				stream.push({ type: "start", partial: createAssistantMessage("") });
				setTimeout(() => {
					stream.push({ type: "done", reason: "stop", message: createAssistantMessage("done") });
				}, options.responseDelayMs);
			});
			return stream;
		},
	});

	const sessionManager = SessionManager.inMemory();
	const settingsManager = SettingsManager.create(tempDir, tempDir);
	const authStorage = AuthStorage.create(join(tempDir, "auth.json"));
	const modelRegistry = ModelRegistry.create(authStorage, tempDir);
	if (options.withAuth) {
		authStorage.setRuntimeApiKey("anthropic", "test-key");
	}

	const extensionsResult = options.extensionFactories
		? await createTestExtensionsResult(options.extensionFactories, tempDir)
		: undefined;
	const session = new AgentSession({
		agent,
		sessionManager,
		settingsManager,
		cwd: tempDir,
		modelRegistry,
		resourceLoader: createTestResourceLoader(extensionsResult ? { extensionsResult } : undefined),
	});

	const runtimeHost = {
		session,
		newSession: vi.fn(async () => ({ cancelled: true })),
		switchSession: vi.fn(async () => ({ cancelled: true })),
		fork: vi.fn(async () => ({ cancelled: true, selectedText: "" })),
		dispose: vi.fn(async () => {}),
		setRebindSession: vi.fn(),
	} as unknown as AgentSessionRuntime;

	return {
		runtimeHost,
		cleanup: async () => {
			try {
				if (session.isStreaming) {
					await session.abort();
				}
			} catch {
				// ignore test cleanup failures
			}
			session.dispose();
			if (existsSync(tempDir)) {
				rmSync(tempDir, { recursive: true });
			}
		},
	};
}

async function startRpcMode(options: {
	withAuth: boolean;
	responseDelayMs: number;
	model?: Model<any>;
	extensionFactories?: ExtensionFactory[];
	onProviderCall?: () => void;
}): Promise<{
	lineHandler: (line: string) => void;
	cleanup: () => Promise<void>;
	runtimeHost: AgentSessionRuntime;
}> {
	rpcIo.outputLines = [];
	rpcIo.lineHandler = undefined;

	const { runtimeHost, cleanup } = await createRuntimeHost(options);
	void runRpcMode(runtimeHost);
	await vi.waitFor(() => expect(rpcIo.lineHandler).toBeDefined());

	return { lineHandler: rpcIo.lineHandler!, cleanup, runtimeHost };
}

describe("RPC prompt response semantics", () => {
	afterEach(() => {
		rpcIo.outputLines = [];
		rpcIo.lineHandler = undefined;
	});

	it("emits one failure response when prompt preflight rejects", async () => {
		const { lineHandler, cleanup } = await startRpcMode({
			withAuth: false,
			responseDelayMs: 0,
			model: {
				id: "fake-model",
				name: "Fake Model",
				api: "openai-completions",
				provider: "fake-provider",
				baseUrl: "https://example.invalid",
				reasoning: false,
				input: [],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 0,
				maxTokens: 0,
			},
		});

		try {
			lineHandler(JSON.stringify({ id: "b1", type: "prompt", message: "Hello" }));

			await vi.waitFor(() => {
				const responses = getPromptResponses(rpcIo.outputLines, "b1");
				expect(responses).toHaveLength(1);
				expect(responses[0]).toMatchObject({
					id: "b1",
					type: "response",
					command: "prompt",
					success: false,
					error: expect.stringContaining(
						"No API key found for fake-provider.\n\nUse /login to log into a provider via OAuth or API key. See:",
					),
				});
			});
		} finally {
			await cleanup();
		}
	});

	it("emits one success response when prompt preflight succeeds", async () => {
		const { lineHandler, cleanup } = await startRpcMode({ withAuth: true, responseDelayMs: 0 });

		try {
			lineHandler(JSON.stringify({ id: "b2", type: "prompt", message: "Hello" }));

			await vi.waitFor(() => {
				const responses = getPromptResponses(rpcIo.outputLines, "b2");
				expect(responses).toHaveLength(1);
				expect(responses[0]).toMatchObject({
					id: "b2",
					type: "response",
					command: "prompt",
					success: true,
				});
			});
		} finally {
			await cleanup();
		}
	});

	it("exposes the neutral sub-agent command and executes it via RPC prompt without a provider turn", async () => {
		let delegateCalls = 0;
		let providerCalls = 0;
		const payload = {
			agentId: "agent-rpc",
			runId: "run-rpc",
			taskId: "task-rpc",
			sessionId: "session-rpc",
			parentAgentId: "parent-rpc",
			route: "rpc-route",
			input: { prompt: "delegate from rpc" },
			limits: { maxChildren: 1, depth: 1, turns: 1, outputBytes: 256, outputLines: 5 },
		};
		const { lineHandler, cleanup } = await startRpcMode({
			withAuth: true,
			responseDelayMs: 0,
			onProviderCall: () => {
				providerCalls++;
			},
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
							content: [{ type: "text", text: "rpc delegated" }],
							startedAt: 10,
							completedAt: 20,
							resourceSummary: {
								turns: 1,
								outputBytes: 13,
								outputLines: 1,
								childrenStarted: 1,
							},
						};
					},
				}),
			],
		});

		try {
			lineHandler(JSON.stringify({ id: "commands", type: "get_commands" }));
			await vi.waitFor(() => {
				const commandResponse = parseOutputLines(rpcIo.outputLines).find(
					(record) => record.id === "commands" && record.type === "response" && record.command === "get_commands",
				);
				expect(commandResponse).toBeDefined();
				const commands = (commandResponse?.data as { commands?: Array<{ name: string; description?: string }> })
					.commands;
				const subAgentCommand = commands?.find((command) => command.name === "sub-agent");
				expect(subAgentCommand).toBeDefined();
				expect(JSON.stringify(subAgentCommand)).not.toMatch(/Workflow|Wiki|QA|Review|preset/i);
			});

			rpcIo.outputLines = [];
			lineHandler(
				JSON.stringify({
					id: "sub-agent-prompt",
					type: "prompt",
					message: `/sub-agent ${JSON.stringify(payload)}`,
				}),
			);

			await vi.waitFor(() => {
				const responses = getPromptResponses(rpcIo.outputLines, "sub-agent-prompt");
				expect(responses).toHaveLength(1);
				expect(responses[0]).toMatchObject({ success: true });

				const records = parseOutputLines(rpcIo.outputLines);
				expect(records).toContainEqual(
					expect.objectContaining({
						type: "message_end",
						message: expect.objectContaining({
							role: "custom",
							customType: SUB_AGENT_STATUS_MESSAGE,
							content: "completed",
							details: expect.objectContaining({
								type: "sub_agent_task_result",
								taskId: "task-rpc",
								status: "completed",
							}),
						}),
					}),
				);
			});

			expect(delegateCalls).toBe(1);
			expect(providerCalls).toBe(0);
		} finally {
			await cleanup();
		}
	});

	it("surfaces invalid sub-agent RPC prompt payloads before delegation or status side effects", async () => {
		let delegateCalls = 0;
		const { lineHandler, cleanup, runtimeHost } = await startRpcMode({
			withAuth: true,
			responseDelayMs: 0,
			extensionFactories: [
				createSubAgentExtension({
					approvedCapabilities: ["agent.delegate"],
					delegate: () => {
						delegateCalls++;
						throw new Error("invalid RPC command payload must not delegate");
					},
				}),
			],
		});

		try {
			lineHandler(JSON.stringify({ id: "invalid-sub-agent", type: "prompt", message: "/sub-agent {not-json" }));

			await vi.waitFor(() => {
				expect(getPromptResponses(rpcIo.outputLines, "invalid-sub-agent")).toHaveLength(1);
				expect(parseOutputLines(rpcIo.outputLines)).toContainEqual(
					expect.objectContaining({
						type: "extension_error",
						extensionPath: "command:sub-agent",
						event: "command",
						error: expect.any(String),
					}),
				);
			});

			expect(delegateCalls).toBe(0);
			expect(runtimeHost.session.sessionManager.getEntries()).toHaveLength(0);
			expect(JSON.stringify(parseOutputLines(rpcIo.outputLines))).not.toContain(SUB_AGENT_STATUS_MESSAGE);
		} finally {
			await cleanup();
		}
	});

	it("emits one success response when prompt is queued during streaming", async () => {
		const { lineHandler, cleanup } = await startRpcMode({ withAuth: true, responseDelayMs: 100 });

		try {
			lineHandler(JSON.stringify({ id: "b3-start", type: "prompt", message: "Start" }));
			await vi.waitFor(() => {
				expect(getPromptResponses(rpcIo.outputLines, "b3-start")).toHaveLength(1);
			});

			rpcIo.outputLines = [];
			lineHandler(
				JSON.stringify({
					id: "b3",
					type: "prompt",
					message: "Queue this",
					streamingBehavior: "followUp",
				}),
			);

			await vi.waitFor(() => {
				const responses = getPromptResponses(rpcIo.outputLines, "b3");
				expect(responses).toHaveLength(1);
				expect(responses[0]).toMatchObject({
					id: "b3",
					type: "response",
					command: "prompt",
					success: true,
				});
			});

			await sleep(150);
		} finally {
			await cleanup();
		}
	});
});
