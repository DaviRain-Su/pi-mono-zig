/**
 * Tests for ExtensionRunner - conflict detection, error handling, tool wrapping.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { AgentEvent, AgentMessage } from "@mariozechner/pi-agent-core";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { createEventBus } from "../src/core/event-bus.js";
import {
	createExtensionRuntime,
	discoverAndLoadExtensions,
	loadExtensionFromFactory,
} from "../src/core/extensions/loader.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import {
	createSubAgentExtension,
	SUB_AGENT_DELEGATION_RESULT_ENTRY,
	SUB_AGENT_READINESS_ENTRY,
} from "../src/core/extensions/subagent-extension.js";
import {
	validateSubAgentReadinessEnvelope,
	validateSubAgentTaskInvocationEnvelope,
	validateSubAgentTaskResultEnvelope,
} from "../src/core/extensions/subagent-readiness.js";
import type {
	ExtensionActions,
	ExtensionContextActions,
	ExtensionEventName,
	ProviderConfig,
} from "../src/core/extensions/types.js";
import { EXTENSION_EVENT_NAMES } from "../src/core/extensions/types.js";
import { KeybindingsManager, type KeyId } from "../src/core/keybindings.js";
import { ModelRegistry } from "../src/core/model-registry.js";
import { SessionManager } from "../src/core/session-manager.js";

const SUB_AGENT_FORBIDDEN_PRODUCT_FIELDS = [
	"ui",
	"ux",
	"slashCommand",
	"spawn",
	"spawnPolicy",
	"automaticSpawn",
	"orchestrationPolicy",
	"modelSelectionUi",
	"approvalPolicy",
] as const;

const AGENT_EVENT_GOLDEN_FIXTURES = [
	"agent_start",
	"turn_start",
	"message_start_user",
	"message_start_assistant",
	"message_update_text_delta",
	"message_update_thinking_delta",
	"message_update_toolcall_delta",
	"message_update_abort_error",
	"message_end_assistant",
	"message_end_tool_result",
	"tool_execution_start",
	"tool_execution_update_partial",
	"tool_execution_end_success",
	"tool_execution_end_error",
	"turn_end",
	"agent_end",
] as const;

function readJsonFixture(relativePath: string): unknown {
	return JSON.parse(fs.readFileSync(new URL(relativePath, import.meta.url), "utf8")) as unknown;
}

function expectRecord(value: unknown, path: string): Record<string, unknown> {
	expect(value, `${path} should be an object`).toBeTypeOf("object");
	expect(value, `${path} should not be null`).not.toBeNull();
	expect(Array.isArray(value), `${path} should not be an array`).toBe(false);
	return value as Record<string, unknown>;
}

function expectString(value: unknown, path: string): string {
	expect(value, `${path} should be a string`).toBeTypeOf("string");
	return value as string;
}

function expectNumber(value: unknown, path: string): number {
	expect(value, `${path} should be a number`).toBeTypeOf("number");
	return value as number;
}

function expectBoolean(value: unknown, path: string): boolean {
	expect(value, `${path} should be a boolean`).toBeTypeOf("boolean");
	return value as boolean;
}

function expectArray(value: unknown, path: string): unknown[] {
	expect(Array.isArray(value), `${path} should be an array`).toBe(true);
	return value as unknown[];
}

function expectNoSnakeCasePayloadFields(value: unknown, path = "$"): void {
	if (Array.isArray(value)) {
		value.forEach((item, index) => {
			expectNoSnakeCasePayloadFields(item, `${path}[${index}]`);
		});
		return;
	}
	if (!value || typeof value !== "object") return;
	for (const [key, child] of Object.entries(value)) {
		expect(key, `${path}.${key} should use TS-compatible camelCase`).not.toContain("_");
		expectNoSnakeCasePayloadFields(child, `${path}.${key}`);
	}
}

function expectContentBlocks(value: unknown, path: string): void {
	const blocks = expectArray(value, path);
	for (const [index, blockValue] of blocks.entries()) {
		const block = expectRecord(blockValue, `${path}[${index}]`);
		const type = expectString(block.type, `${path}[${index}].type`);
		if (type === "text") {
			expectString(block.text, `${path}[${index}].text`);
		} else if (type === "image") {
			expectString(block.data, `${path}[${index}].data`);
			expectString(block.mimeType, `${path}[${index}].mimeType`);
		} else if (type === "thinking") {
			expectString(block.thinking, `${path}[${index}].thinking`);
		} else if (type === "toolCall") {
			expectString(block.id, `${path}[${index}].id`);
			expectString(block.name, `${path}[${index}].name`);
			expectRecord(block.arguments, `${path}[${index}].arguments`);
		} else {
			throw new Error(`${path}[${index}].type: invalid content block type '${type}'`);
		}
	}
}

function expectUsage(value: unknown, path: string): void {
	const usage = expectRecord(value, path);
	for (const field of ["input", "output", "cacheRead", "cacheWrite", "totalTokens"] as const) {
		expectNumber(usage[field], `${path}.${field}`);
	}
	const cost = expectRecord(usage.cost, `${path}.cost`);
	for (const field of ["input", "output", "cacheRead", "cacheWrite", "total"] as const) {
		expectNumber(cost[field], `${path}.cost.${field}`);
	}
}

function expectAgentMessage(value: unknown, path: string): void {
	const message = expectRecord(value, path);
	const role = expectString(message.role, `${path}.role`);
	if (role === "user") {
		if (typeof message.content !== "string") expectContentBlocks(message.content, `${path}.content`);
		expectNumber(message.timestamp, `${path}.timestamp`);
		return;
	}
	if (role === "assistant") {
		expectContentBlocks(message.content, `${path}.content`);
		expectString(message.api, `${path}.api`);
		expectString(message.provider, `${path}.provider`);
		expectString(message.model, `${path}.model`);
		expectUsage(message.usage, `${path}.usage`);
		expect(["stop", "length", "toolUse", "error", "aborted"]).toContain(
			expectString(message.stopReason, `${path}.stopReason`),
		);
		expectNumber(message.timestamp, `${path}.timestamp`);
		return;
	}
	if (role === "toolResult") {
		expectToolResultMessage(value, path);
		return;
	}
	throw new Error(`${path}.role: invalid message role '${role}'`);
}

function expectToolResultMessage(value: unknown, path: string): void {
	const message = expectRecord(value, path);
	expectString(message.toolCallId, `${path}.toolCallId`);
	expectString(message.toolName, `${path}.toolName`);
	expectContentBlocks(message.content, `${path}.content`);
	expectBoolean(message.isError, `${path}.isError`);
	expectNumber(message.timestamp, `${path}.timestamp`);
}

function expectAssistantMessageEvent(value: unknown, path: string): void {
	const event = expectRecord(value, path);
	const type = expectString(event.type, `${path}.type`);
	if (type === "start") {
		expectAgentMessage(event.partial, `${path}.partial`);
		return;
	}
	if (
		type.endsWith("_start") ||
		type.endsWith("_delta") ||
		type === "text_end" ||
		type === "thinking_end" ||
		type === "toolcall_end"
	) {
		expectNumber(event.contentIndex, `${path}.contentIndex`);
		if (type.endsWith("_delta")) expectString(event.delta, `${path}.delta`);
		if (type === "text_end" || type === "thinking_end") expectString(event.content, `${path}.content`);
		if (type === "toolcall_end") {
			const toolCall = expectRecord(event.toolCall, `${path}.toolCall`);
			expectString(toolCall.id ?? toolCall.toolCallId, `${path}.toolCall.id`);
			expectString(toolCall.name, `${path}.toolCall.name`);
			expectRecord(toolCall.arguments, `${path}.toolCall.arguments`);
		}
		expectAgentMessage(event.partial, `${path}.partial`);
		return;
	}
	if (type === "done") {
		expect(["stop", "length", "toolUse"]).toContain(expectString(event.reason, `${path}.reason`));
		expectAgentMessage(event.message, `${path}.message`);
		return;
	}
	if (type === "error") {
		expect(["error", "aborted"]).toContain(expectString(event.reason, `${path}.reason`));
		expectAgentMessage(event.error, `${path}.error`);
		return;
	}
	throw new Error(`${path}.type: invalid assistant message event type '${type}'`);
}

function expectAgentToolResult(value: unknown, path: string): void {
	const result = expectRecord(value, path);
	expectContentBlocks(result.content, `${path}.content`);
}

function expectAgentEventWirePayload(value: unknown): asserts value is AgentEvent {
	expectNoSnakeCasePayloadFields(value);
	const event = expectRecord(value, "$");
	const type = expectString(event.type, "$.type");
	if (type === "agent_start" || type === "turn_start") return;
	if (type === "agent_end") {
		expectArray(event.messages, "$.messages").forEach((message, index) => {
			expectAgentMessage(message, `$.messages[${index}]`);
		});
		return;
	}
	if (type === "turn_end") {
		expectAgentMessage(event.message, "$.message");
		expectArray(event.toolResults, "$.toolResults").forEach((result, index) => {
			expectToolResultMessage(result, `$.toolResults[${index}]`);
		});
		return;
	}
	if (type === "message_start" || type === "message_end") {
		expectAgentMessage(event.message, "$.message");
		return;
	}
	if (type === "message_update") {
		expectAgentMessage(event.message, "$.message");
		expectAssistantMessageEvent(event.assistantMessageEvent, "$.assistantMessageEvent");
		return;
	}
	if (type === "tool_execution_start") {
		expectString(event.toolCallId, "$.toolCallId");
		expectString(event.toolName, "$.toolName");
		expectRecord(event.args, "$.args");
		return;
	}
	if (type === "tool_execution_update") {
		expectString(event.toolCallId, "$.toolCallId");
		expectString(event.toolName, "$.toolName");
		expectRecord(event.args, "$.args");
		expectAgentToolResult(event.partialResult, "$.partialResult");
		return;
	}
	if (type === "tool_execution_end") {
		expectString(event.toolCallId, "$.toolCallId");
		expectString(event.toolName, "$.toolName");
		expectAgentToolResult(event.result, "$.result");
		expectBoolean(event.isError, "$.isError");
		return;
	}
	throw new Error(`$.type: invalid agent event type '${type}'`);
}

describe("subscriber event contract parity", () => {
	it("keeps the TS event surface fixture in sync with ExtensionEvent names", () => {
		const fixture = readJsonFixture("./fixtures/extension-event-surface-names.json");
		expect(fixture).toEqual([...EXTENSION_EVENT_NAMES]);
		expect(new Set(EXTENSION_EVENT_NAMES).size).toBe(EXTENSION_EVENT_NAMES.length);

		const checkedNames = EXTENSION_EVENT_NAMES satisfies readonly ExtensionEventName[];
		expect(checkedNames).toHaveLength(30);
	});

	it("parses Zig JSON wire goldens as TS-compatible AgentEvent payloads", () => {
		const parsedEvents: AgentEvent[] = [];
		for (const name of AGENT_EVENT_GOLDEN_FIXTURES) {
			const payload = readJsonFixture(`../../../zig/test/golden/json/${name}.json`);
			expectAgentEventWirePayload(payload);
			parsedEvents.push(payload);
		}

		expect(parsedEvents.map((event) => event.type)).toEqual([
			"agent_start",
			"turn_start",
			"message_start",
			"message_start",
			"message_update",
			"message_update",
			"message_update",
			"message_update",
			"message_end",
			"message_end",
			"tool_execution_start",
			"tool_execution_update",
			"tool_execution_end",
			"tool_execution_end",
			"turn_end",
			"agent_end",
		]);
	});
});

describe("sub-agent readiness envelope validation", () => {
	const invocation = {
		type: "sub_agent_task_invocation",
		agentId: "agent-opaque",
		runId: "run-opaque",
		taskId: "task-opaque",
		sessionId: "session-opaque",
		toolCallId: "tool-call-opaque",
		parentAgentId: "parent-agent",
		parentRunId: "parent-run",
		parentTaskId: "parent-task",
		parentSessionId: "parent-session",
		parentId: "parent-record",
		route: "delegate",
		input: { text: "summarize" },
		limits: {
			maxChildren: 0,
			depth: 1,
			turns: 3,
			timeoutMs: 2500,
			outputBytes: 4096,
			outputLines: 80,
			toolScopes: ["read-only"],
		},
		cancellation: {
			signalId: "cancel-1",
			state: "pending",
			parentRunId: "parent-run",
			parentTaskId: "parent-task",
		},
		metadata: { substrateOnly: true },
	};

	const result = {
		type: "sub_agent_task_result",
		agentId: "agent-opaque",
		runId: "run-opaque",
		taskId: "task-opaque",
		sessionId: "session-opaque",
		parentAgentId: "parent-agent",
		parentRunId: "parent-run",
		parentTaskId: "parent-task",
		parentSessionId: "parent-session",
		status: "completed",
		content: [{ type: "text", text: "done" }],
		details: { replaySafe: true },
		startedAt: 10,
		completedAt: 20,
		usage: { inputTokens: 1, outputTokens: 2, totalTokens: 3, toolCalls: 0 },
		resourceSummary: {
			turns: 1,
			outputBytes: 128,
			outputLines: 2,
			childrenStarted: 0,
			limitDetails: {
				outputBytes: { limit: 4096, actual: 5000, truncated: true, reason: "output truncated" },
				timeoutMs: { limit: 2500, actual: 2500, truncated: false },
				toolScopes: ["read-only"],
			},
		},
	};

	it("accepts substrate-only invocation and result envelopes with opaque identity lineage", () => {
		expect(validateSubAgentTaskInvocationEnvelope(invocation)).toBe(invocation);
		expect(validateSubAgentTaskResultEnvelope(result)).toBe(result);
		expect(validateSubAgentReadinessEnvelope(invocation).type).toBe("sub_agent_task_invocation");
		expect(validateSubAgentReadinessEnvelope(result).type).toBe("sub_agent_task_result");
	});

	it("rejects missing or invalid correlation identifiers with deterministic paths", () => {
		expect(() => validateSubAgentReadinessEnvelope({ ...invocation, agentId: "" })).toThrow(
			"$.agentId: must not be empty",
		);
		expect(() => {
			const { taskId: _taskId, ...withoutTaskId } = invocation;
			validateSubAgentReadinessEnvelope(withoutTaskId);
		}).toThrow("$.taskId: missing required field");
		expect(() => validateSubAgentReadinessEnvelope({ ...result, runId: 42 })).toThrow("$.runId: expected string");
	});

	it("rejects product UX, automatic spawning policy, and invalid wire fields", () => {
		for (const field of SUB_AGENT_FORBIDDEN_PRODUCT_FIELDS) {
			expect(() => validateSubAgentTaskInvocationEnvelope({ ...invocation, [field]: { automatic: true } })).toThrow(
				`$.${field}: product UX/spawn policy is not allowed`,
			);
			expect(() => validateSubAgentTaskResultEnvelope({ ...result, [field]: { automatic: true } })).toThrow(
				`$.${field}: product UX/spawn policy is not allowed`,
			);
		}
		expect(() => validateSubAgentTaskInvocationEnvelope({ ...invocation, limits: { toolScopes: [""] } })).toThrow(
			"$.limits.toolScopes[0]: must not be empty",
		);
		expect(() => validateSubAgentTaskResultEnvelope({ ...result, status: "complete" })).toThrow(
			'$.status: unsupported task status "complete"',
		);
	});

	it("validates cancellation propagation and resource limit detail paths", () => {
		expect(() =>
			validateSubAgentTaskInvocationEnvelope({
				...invocation,
				cancellation: { state: "aborted", propagatedFrom: "parent-run" },
			}),
		).toThrow('$.cancellation.state: unsupported cancellation state "aborted"');
		expect(() =>
			validateSubAgentTaskInvocationEnvelope({
				...invocation,
				cancellation: { state: "propagated", parentRunId: "" },
			}),
		).toThrow("$.cancellation.parentRunId: must not be empty");
		expect(() => validateSubAgentTaskInvocationEnvelope({ ...invocation, limits: { maxChildren: -1 } })).toThrow(
			"$.limits.maxChildren: expected non-negative integer",
		);
		expect(() =>
			validateSubAgentTaskResultEnvelope({
				...result,
				resourceSummary: {
					limitDetails: { outputBytes: { limit: -1 } },
				},
			}),
		).toThrow("$.resourceSummary.limitDetails.outputBytes.limit: expected non-negative number");
		expect(() =>
			validateSubAgentTaskResultEnvelope({
				...result,
				resourceSummary: {
					limitDetails: { outputBytes: { limit: 4096, actual: 5000 } },
				},
			}),
		).toThrow("$.resourceSummary.limitDetails.outputBytes.truncated: missing required field");
	});

	it("persists readiness records as replay-only session data outside LLM context", () => {
		const sessionDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-subagent-readiness-"));
		try {
			const session = SessionManager.create("/tmp/subagent-project", sessionDir);
			const userId = session.appendMessage({ role: "user", content: "delegate safely", timestamp: 1 });
			const readinessId = session.appendCustomEntry(
				"sub_agent.readiness",
				validateSubAgentReadinessEnvelope(invocation),
			);
			session.appendMessage({
				role: "assistant",
				content: [{ type: "text", text: "recorded readiness metadata" }],
				api: "faux",
				provider: "faux",
				model: "faux",
				usage: {
					input: 1,
					output: 1,
					cacheRead: 0,
					cacheWrite: 0,
					totalTokens: 2,
					cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
				},
				stopReason: "stop",
				timestamp: 2,
			});

			const sessionFile = session.getSessionFile();
			expect(sessionFile).toBeTypeOf("string");
			const reopened = SessionManager.open(sessionFile!, sessionDir);
			const readinessEntry = reopened.getEntry(readinessId);
			expect(readinessEntry?.type).toBe("custom");
			if (readinessEntry?.type !== "custom") throw new Error("missing readiness custom entry");
			expect(readinessEntry.id).toBe(readinessId);
			expect(readinessEntry.customType).toBe("sub_agent.readiness");
			expect(readinessEntry.parentId).toBe(userId);
			expect(readinessEntry.timestamp).toMatch(/^\d{4}-\d{2}-\d{2}T/);
			expect(readinessEntry.data).toMatchObject({
				type: "sub_agent_task_invocation",
				taskId: "task-opaque",
				parentSessionId: "parent-session",
				parentRunId: "parent-run",
				cancellation: { state: "pending" },
			});

			const context = reopened.buildSessionContext();
			expect(context.messages).toHaveLength(2);
			expect(context.messages.map((message) => message.role)).toEqual(["user", "assistant"]);
			expect(JSON.stringify(context.messages)).not.toContain("sub_agent_task_invocation");
		} finally {
			fs.rmSync(sessionDir, { recursive: true, force: true });
		}
	});
});

describe("neutral sub-agent delegation extension", () => {
	let tempDir: string;
	let sessionManager: SessionManager;
	let modelRegistry: ModelRegistry;

	const delegateInput = {
		agentId: "agent-neutral",
		runId: "run-neutral",
		taskId: "task-neutral",
		sessionId: "session-neutral",
		parentAgentId: "parent-agent",
		route: "neutral-route",
		input: { prompt: "summarize neutrally" },
		limits: { maxChildren: 1, depth: 1, turns: 2, outputBytes: 512, outputLines: 10, toolScopes: ["read"] },
		metadata: { source: "test" },
	};

	function bindRunnerCore(
		runner: ExtensionRunner,
		sessionManager: SessionManager,
		sentMessages: unknown[] = [],
	): void {
		const defaultActions: ExtensionActions = {
			sendMessage: () => {},
			sendUserMessage: () => {},
			appendEntry: () => {},
			setSessionName: () => {},
			getSessionName: () => undefined,
			setLabel: () => {},
			getActiveTools: () => [],
			getAllTools: () => [],
			setActiveTools: () => {},
			refreshTools: () => {},
			getCommands: () => [],
			setModel: async () => false,
			getThinkingLevel: () => "off",
			setThinkingLevel: () => {},
		};
		const defaultContextActions: ExtensionContextActions = {
			getModel: () => undefined,
			isIdle: () => true,
			getSignal: () => undefined,
			abort: () => {},
			hasPendingMessages: () => false,
			shutdown: () => {},
			getContextUsage: () => undefined,
			compact: () => {},
			getSystemPrompt: () => "",
		};
		runner.bindCore(
			{
				...defaultActions,
				sendMessage: (message) => {
					sentMessages.push(message);
				},
				appendEntry: (customType, data) => {
					sessionManager.appendCustomEntry(customType, data);
				},
			},
			defaultContextActions,
		);
	}

	function textFromToolResult(result: { content: Array<{ type: string; text?: string }> }): string {
		const text = result.content.find((block) => block.type === "text")?.text;
		if (text === undefined) throw new Error("missing text result");
		return text;
	}

	beforeEach(() => {
		tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-sub-agent-extension-test-"));
		sessionManager = SessionManager.inMemory(tempDir);
		const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
		modelRegistry = ModelRegistry.create(authStorage);
	});

	afterEach(() => {
		fs.rmSync(tempDir, { recursive: true, force: true });
	});

	it("registers neutral tool and command while default-denying delegation without side effects", async () => {
		let delegateCalls = 0;
		const runtime = createExtensionRuntime();
		const extension = await loadExtensionFromFactory(
			createSubAgentExtension({
				delegate: async () => {
					delegateCalls++;
					throw new Error("delegate must not run without grant");
				},
			}),
			tempDir,
			createEventBus(),
			runtime,
			"<sub-agent-extension>",
		);
		const runner = new ExtensionRunner([extension], runtime, tempDir, sessionManager, modelRegistry);
		bindRunnerCore(runner, sessionManager);

		const tool = runner.getToolDefinition("sub_agent.delegate");
		expect(tool).toBeDefined();
		expect(runner.getRegisteredCommands().map((command) => command.name)).toContain("sub-agent");

		const result = await tool!.execute(
			"tool-call-denied",
			delegateInput,
			undefined,
			undefined,
			runner.createContext(),
		);
		const envelope = JSON.parse(textFromToolResult(result)) as Record<string, unknown>;

		expect(delegateCalls).toBe(0);
		expect(envelope.status).toBe("failed");
		expect(envelope.error).toMatchObject({ reason: "denied_capability" });
		expect(envelope.details).toMatchObject({
			capability: "agent.delegate",
			operation: "agent.delegate",
			replayed: false,
		});
		expect(sessionManager.getEntries().filter((entry) => entry.type === "custom")).toHaveLength(2);
		expect(
			sessionManager
				.getEntries()
				.filter((entry) => entry.type === "custom")
				.map((entry) => entry.customType),
		).toEqual([SUB_AGENT_READINESS_ENTRY, SUB_AGENT_DELEGATION_RESULT_ENTRY]);
	});

	it("delegates through the neutral substrate and replays recorded results without re-execution", async () => {
		let delegateCalls = 0;
		const runtime = createExtensionRuntime();
		const extension = await loadExtensionFromFactory(
			createSubAgentExtension({
				approvedCapabilities: ["agent.delegate"],
				delegate: async (invocation) => {
					delegateCalls++;
					return {
						type: "sub_agent_task_result",
						agentId: invocation.agentId,
						runId: invocation.runId,
						taskId: invocation.taskId,
						sessionId: invocation.sessionId,
						parentAgentId: invocation.parentAgentId,
						status: "completed",
						content: [{ type: "text", text: "delegated done" }],
						startedAt: 10,
						completedAt: 20,
						usage: { inputTokens: 1, outputTokens: 2, totalTokens: 3, toolCalls: 0 },
						resourceSummary: {
							turns: 1,
							outputBytes: 14,
							outputLines: 1,
							childrenStarted: 1,
							limitDetails: {
								outputBytes: { limit: 512, actual: 14, truncated: false },
								outputLines: { limit: 10, actual: 1, truncated: false },
								toolScopes: ["read"],
							},
						},
						details: { substrate: "generic" },
					};
				},
			}),
			tempDir,
			createEventBus(),
			runtime,
			"<sub-agent-extension>",
		);
		const runner = new ExtensionRunner([extension], runtime, tempDir, sessionManager, modelRegistry);
		bindRunnerCore(runner, sessionManager);
		const tool = runner.getToolDefinition("sub_agent.delegate");
		expect(tool).toBeDefined();

		const first = await tool!.execute(
			"tool-call-allowed",
			delegateInput,
			undefined,
			undefined,
			runner.createContext(),
		);
		const replay = await tool!.execute(
			"tool-call-replay",
			delegateInput,
			undefined,
			undefined,
			runner.createContext(),
		);
		const firstEnvelope = JSON.parse(textFromToolResult(first)) as Record<string, unknown>;
		const replayEnvelope = JSON.parse(textFromToolResult(replay)) as Record<string, unknown>;

		expect(delegateCalls).toBe(1);
		expect(firstEnvelope).toMatchObject({ status: "completed", content: [{ text: "delegated done" }] });
		expect(firstEnvelope.resourceSummary).toMatchObject({
			turns: 1,
			outputBytes: 14,
			outputLines: 1,
			childrenStarted: 1,
		});
		expect(replayEnvelope).toEqual(firstEnvelope);
		expect(sessionManager.getEntries().filter((entry) => entry.type === "custom")).toHaveLength(2);
	});

	it("propagates cancellation metadata and prevents delegated work when cancellation is requested", async () => {
		let delegateCalls = 0;
		const runtime = createExtensionRuntime();
		const extension = await loadExtensionFromFactory(
			createSubAgentExtension({
				approvedCapabilities: ["agent.delegate"],
				delegate: async () => {
					delegateCalls++;
					throw new Error("cancelled delegation must not execute");
				},
			}),
			tempDir,
			createEventBus(),
			runtime,
			"<sub-agent-extension>",
		);
		const runner = new ExtensionRunner([extension], runtime, tempDir, sessionManager, modelRegistry);
		const sentMessages: unknown[] = [];
		bindRunnerCore(runner, sessionManager, sentMessages);
		const command = runner.getCommand("sub-agent");
		expect(command).toBeDefined();

		await command!.handler(
			JSON.stringify({
				...delegateInput,
				taskId: "task-cancelled",
				cancellation: { state: "requested", reason: "user cancelled" },
			}),
			runner.createCommandContext(),
		);

		const customEntries = sessionManager.getEntries().filter((entry) => entry.type === "custom");
		const readiness = customEntries.find((entry) => entry.customType === SUB_AGENT_READINESS_ENTRY);
		const result = customEntries.find((entry) => entry.customType === SUB_AGENT_DELEGATION_RESULT_ENTRY);
		expect(delegateCalls).toBe(0);
		expect(readiness?.data).toMatchObject({
			type: "sub_agent_task_invocation",
			taskId: "task-cancelled",
			cancellation: { state: "propagated", reason: "user cancelled" },
		});
		expect(result?.data).toMatchObject({
			type: "sub_agent_task_result",
			status: "cancelled",
			error: { reason: "cancelled" },
			resourceSummary: { childrenStarted: 0 },
		});
		expect(sentMessages).toHaveLength(1);
	});
});

describe("ExtensionRunner", () => {
	let tempDir: string;
	let extensionsDir: string;
	let sessionManager: SessionManager;
	let modelRegistry: ModelRegistry;
	const defaultKeybindings = new KeybindingsManager().getEffectiveConfig();

	beforeEach(() => {
		tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-runner-test-"));
		extensionsDir = path.join(tempDir, "extensions");
		fs.mkdirSync(extensionsDir);
		sessionManager = SessionManager.inMemory();
		const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
		modelRegistry = ModelRegistry.create(authStorage);
	});

	afterEach(() => {
		fs.rmSync(tempDir, { recursive: true, force: true });
	});

	const providerModelConfig: ProviderConfig = {
		baseUrl: "https://provider.test/v1",
		apiKey: "PROVIDER_TEST_KEY",
		api: "openai-completions",
		models: [
			{
				id: "instant-model",
				name: "Instant Model",
				reasoning: false,
				input: ["text"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 128000,
				maxTokens: 4096,
			},
		],
	};

	const extensionActions: ExtensionActions = {
		sendMessage: () => {},
		sendUserMessage: () => {},
		appendEntry: () => {},
		setSessionName: () => {},
		getSessionName: () => undefined,
		setLabel: () => {},
		getActiveTools: () => [],
		getAllTools: () => [],
		setActiveTools: () => {},
		refreshTools: () => {},
		getCommands: () => [],
		setModel: async () => false,
		getThinkingLevel: () => "off",
		setThinkingLevel: () => {},
	};

	const extensionContextActions: ExtensionContextActions = {
		getModel: () => undefined,
		isIdle: () => true,
		getSignal: () => undefined,
		abort: () => {},
		hasPendingMessages: () => false,
		shutdown: () => {},
		getContextUsage: () => undefined,
		compact: () => {},
		getSystemPrompt: () => "",
	};

	describe("shortcut conflicts", () => {
		it("warns when extension shortcut conflicts with built-in", async () => {
			const extCode = `
				export default function(pi) {
					pi.registerShortcut("ctrl+c", {
						description: "Conflicts with built-in",
						handler: async () => {},
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "conflict.ts"), extCode);

			const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const shortcuts = runner.getShortcuts(defaultKeybindings);

			expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("conflicts with built-in"));
			expect(shortcuts.has("ctrl+c")).toBe(false);

			warnSpy.mockRestore();
		});

		it("allows a shortcut when the reserved set no longer contains the default key", async () => {
			const extCode = `
				export default function(pi) {
					pi.registerShortcut("ctrl+p", {
						description: "Uses freed default",
						handler: async () => {},
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "rebinding.ts"), extCode);

			const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const keybindings = { ...defaultKeybindings, "app.model.cycleForward": "ctrl+n" as KeyId };
			const shortcuts = runner.getShortcuts(keybindings);

			expect(shortcuts.has("ctrl+p")).toBe(true);
			expect(warnSpy).not.toHaveBeenCalledWith(expect.stringContaining("conflicts with built-in"));

			warnSpy.mockRestore();
		});

		it("warns but allows when extension uses non-reserved built-in shortcut", async () => {
			const pasteImageKey = Array.isArray(defaultKeybindings["app.clipboard.pasteImage"])
				? (defaultKeybindings["app.clipboard.pasteImage"][0] ?? "")
				: defaultKeybindings["app.clipboard.pasteImage"];
			const extCode = `
				export default function(pi) {
					pi.registerShortcut("${pasteImageKey}", {
						description: "Overrides non-reserved",
						handler: async () => {},
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "non-reserved.ts"), extCode);

			const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const shortcuts = runner.getShortcuts(defaultKeybindings);

			expect(warnSpy).toHaveBeenCalledWith(
				expect.stringContaining("built-in shortcut for app.clipboard.pasteImage"),
			);
			expect(shortcuts.has(pasteImageKey as KeyId)).toBe(true);

			warnSpy.mockRestore();
		});

		it("blocks shortcuts for reserved actions even when rebound", async () => {
			const extCode = `
				export default function(pi) {
					pi.registerShortcut("ctrl+x", {
						description: "Conflicts with rebound reserved",
						handler: async () => {},
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "rebound-reserved.ts"), extCode);

			const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const keybindings = { ...defaultKeybindings, "app.interrupt": "ctrl+x" as KeyId };
			const shortcuts = runner.getShortcuts(keybindings);

			expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("conflicts with built-in"));
			expect(shortcuts.has("ctrl+x")).toBe(false);

			warnSpy.mockRestore();
		});

		it("blocks shortcuts when reserved key is also bound to non-reserved actions", async () => {
			const extCode = `
				export default function(pi) {
					pi.registerShortcut("ctrl+p", {
						description: "Conflicts with shared reserved default",
						handler: async () => {},
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "shared-reserved.ts"), extCode);

			const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const shortcuts = runner.getShortcuts(defaultKeybindings);

			expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("conflicts with built-in"));
			expect(shortcuts.has("ctrl+p")).toBe(false);

			warnSpy.mockRestore();
		});

		it("blocks shortcuts when reserved action has multiple keys", async () => {
			const extCode = `
				export default function(pi) {
					pi.registerShortcut("ctrl+y", {
						description: "Conflicts with multi-key reserved",
						handler: async () => {},
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "multi-reserved.ts"), extCode);

			const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const keybindings = { ...defaultKeybindings, "app.clear": ["ctrl+x", "ctrl+y"] as KeyId[] };
			const shortcuts = runner.getShortcuts(keybindings);

			expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("conflicts with built-in"));
			expect(shortcuts.has("ctrl+y")).toBe(false);

			warnSpy.mockRestore();
		});

		it("warns but allows when non-reserved action has multiple keys", async () => {
			const extCode = `
				export default function(pi) {
					pi.registerShortcut("ctrl+y", {
						description: "Overrides multi-key non-reserved",
						handler: async () => {},
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "multi-non-reserved.ts"), extCode);

			const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const keybindings = { ...defaultKeybindings, "app.clipboard.pasteImage": ["ctrl+x", "ctrl+y"] as KeyId[] };
			const shortcuts = runner.getShortcuts(keybindings);

			expect(warnSpy).toHaveBeenCalledWith(
				expect.stringContaining("built-in shortcut for app.clipboard.pasteImage"),
			);
			expect(shortcuts.has("ctrl+y")).toBe(true);

			warnSpy.mockRestore();
		});

		it("warns when two extensions register same shortcut", async () => {
			// Use a non-reserved shortcut
			const extCode1 = `
				export default function(pi) {
					pi.registerShortcut("ctrl+shift+x", {
						description: "First extension",
						handler: async () => {},
					});
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.registerShortcut("ctrl+shift+x", {
						description: "Second extension",
						handler: async () => {},
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "ext1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "ext2.ts"), extCode2);

			const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const shortcuts = runner.getShortcuts(defaultKeybindings);

			expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("shortcut conflict"));
			// Last one wins
			expect(shortcuts.has("ctrl+shift+x")).toBe(true);

			warnSpy.mockRestore();
		});
	});

	describe("tool collection", () => {
		it("collects tools from multiple extensions", async () => {
			const toolCode = (name: string) => `
				import { Type } from "typebox";
				export default function(pi) {
					pi.registerTool({
						name: "${name}",
						label: "${name}",
						description: "Test tool",
						parameters: Type.Object({}),
						execute: async () => ({ content: [{ type: "text", text: "ok" }], details: {} }),
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "tool-a.ts"), toolCode("tool_a"));
			fs.writeFileSync(path.join(extensionsDir, "tool-b.ts"), toolCode("tool_b"));

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const tools = runner.getAllRegisteredTools();

			expect(tools.length).toBe(2);
			expect(tools.map((t) => t.definition.name).sort()).toEqual(["tool_a", "tool_b"]);
		});

		it("keeps first tool when two extensions register the same name", async () => {
			const first = `
				import { Type } from "typebox";
				export default function(pi) {
					pi.registerTool({
						name: "shared",
						label: "shared",
						description: "first",
						parameters: Type.Object({}),
						execute: async () => ({ content: [{ type: "text", text: "first result" }], details: { source: "first" } }),
					});
				}
			`;
			const second = `
				import { Type } from "typebox";
				export default function(pi) {
					pi.registerTool({
						name: "shared",
						label: "shared",
						description: "second",
						parameters: Type.Object({}),
						execute: async () => ({ content: [{ type: "text", text: "second result" }], details: { source: "second" } }),
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "a-first.ts"), first);
			fs.writeFileSync(path.join(extensionsDir, "b-second.ts"), second);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const tools = runner.getAllRegisteredTools();

			expect(tools).toHaveLength(1);
			const selectedTool = tools[0];
			expect(selectedTool).toBeDefined();
			if (!selectedTool) throw new Error("missing duplicate winner tool");
			expect(selectedTool.definition.description).toBe("first");
			expect(runner.getToolDefinition("shared")?.description).toBe("first");
			await expect(
				selectedTool.definition.execute("tool-call-1", {}, undefined, undefined, runner.createContext()),
			).resolves.toEqual({
				content: [{ type: "text", text: "first result" }],
				details: { source: "first" },
			});
		});
	});

	describe("command collection", () => {
		it("collects commands from multiple extensions", async () => {
			const cmdCode = (name: string) => `
				export default function(pi) {
					pi.registerCommand("${name}", {
						description: "Test command",
						handler: async () => {},
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "cmd-a.ts"), cmdCode("cmd-a"));
			fs.writeFileSync(path.join(extensionsDir, "cmd-b.ts"), cmdCode("cmd-b"));

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const commands = runner.getRegisteredCommands();

			expect(commands.length).toBe(2);
			expect(commands.map((c) => c.name).sort()).toEqual(["cmd-a", "cmd-b"]);
			expect(commands.map((c) => c.invocationName).sort()).toEqual(["cmd-a", "cmd-b"]);
		});

		it("gets command by invocation name", async () => {
			const cmdCode = `
				export default function(pi) {
					pi.registerCommand("my-cmd", {
						description: "My command",
						handler: async () => {},
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "cmd.ts"), cmdCode);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);

			const cmd = runner.getCommand("my-cmd");
			expect(cmd).toBeDefined();
			expect(cmd?.name).toBe("my-cmd");
			expect(cmd?.invocationName).toBe("my-cmd");
			expect(cmd?.description).toBe("My command");

			const missing = runner.getCommand("not-exists");
			expect(missing).toBeUndefined();
		});

		it("suffixes duplicate extension commands in insertion order", async () => {
			const cmdCode = (description: string) => `
				export default function(pi) {
					pi.registerCommand("shared-cmd", {
						description: "${description}",
						handler: async () => {},
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "cmd-a.ts"), cmdCode("First command"));
			fs.writeFileSync(path.join(extensionsDir, "cmd-b.ts"), cmdCode("Second command"));

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const commands = runner.getRegisteredCommands();
			const diagnostics = runner.getCommandDiagnostics();

			expect(commands).toHaveLength(2);
			expect(commands.map((command) => command.name)).toEqual(["shared-cmd", "shared-cmd"]);
			expect(commands.map((command) => command.invocationName)).toEqual(["shared-cmd:1", "shared-cmd:2"]);
			expect(commands.map((command) => command.description)).toEqual(["First command", "Second command"]);
			expect(diagnostics).toEqual([]);
			expect(runner.getCommand("shared-cmd:1")?.description).toBe("First command");
			expect(runner.getCommand("shared-cmd:2")?.description).toBe("Second command");
		});
	});

	describe("context creation", () => {
		it("exposes the current abort signal on ExtensionContext", async () => {
			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const controller = new AbortController();

			runner.bindCore(extensionActions, {
				...extensionContextActions,
				getSignal: () => controller.signal,
			});

			const ctx = runner.createContext();
			expect(ctx.signal).toBe(controller.signal);
			expect(ctx.signal?.aborted).toBe(false);

			controller.abort();
			expect(ctx.signal?.aborted).toBe(true);
		});
	});

	describe("error handling", () => {
		it("calls error listeners when handler throws", async () => {
			const extCode = `
				export default function(pi) {
					pi.on("context", async () => {
						throw new Error("Handler error!");
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "throws.ts"), extCode);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);

			const errors: Array<{ extensionPath: string; event: string; error: string }> = [];
			runner.onError((err) => {
				errors.push(err);
			});

			// Emit context event which will trigger the throwing handler
			await runner.emitContext([]);

			expect(errors.length).toBe(1);
			expect(errors[0].error).toContain("Handler error!");
			expect(errors[0].event).toBe("context");
		});
	});

	describe("message renderers", () => {
		it("gets message renderer by type", async () => {
			const extCode = `
				export default function(pi) {
					pi.registerMessageRenderer("my-type", (message, options, theme) => null);
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "renderer.ts"), extCode);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);

			const renderer = runner.getMessageRenderer("my-type");
			expect(renderer).toBeDefined();

			const missing = runner.getMessageRenderer("not-exists");
			expect(missing).toBeUndefined();
		});
	});

	describe("flags", () => {
		it("collects flags from extensions", async () => {
			const extCode = `
				export default function(pi) {
					pi.registerFlag("my-flag", {
						description: "My flag",
						handler: async () => {},
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "with-flag.ts"), extCode);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const flags = runner.getFlags();

			expect(flags.has("my-flag")).toBe(true);
		});

		it("keeps first flag when two extensions register the same name", async () => {
			const first = `
				export default function(pi) {
					pi.registerFlag("shared-flag", {
						description: "first",
						type: "boolean",
						default: true,
					});
				}
			`;
			const second = `
				export default function(pi) {
					pi.registerFlag("shared-flag", {
						description: "second",
						type: "boolean",
						default: false,
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "a-first.ts"), first);
			fs.writeFileSync(path.join(extensionsDir, "b-second.ts"), second);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const flags = runner.getFlags();

			expect(flags.get("shared-flag")?.description).toBe("first");
			expect(result.runtime.flagValues.get("shared-flag")).toBe(true);
		});

		it("can set flag values", async () => {
			const extCode = `
				export default function(pi) {
					pi.registerFlag("test-flag", {
						description: "Test flag",
						handler: async () => {},
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "flag.ts"), extCode);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);

			// Setting a flag value should not throw
			runner.setFlagValue("--test-flag", true);

			// The flag values are stored in the shared runtime
			expect(result.runtime.flagValues.get("--test-flag")).toBe(true);
		});
	});

	describe("before_agent_start", () => {
		it("keeps ctx.getSystemPrompt() in sync with chained system prompt updates", async () => {
			const extCode1 = `
				export default function(pi) {
					pi.on("before_agent_start", async (_event, ctx) => {
						return {
							systemPrompt: ctx.getSystemPrompt() + "\\nfirst",
						};
					});
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.on("before_agent_start", async (_event, ctx) => {
						return {
							systemPrompt: ctx.getSystemPrompt() + "\\nsecond",
						};
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "before-agent-start-1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "before-agent-start-2.ts"), extCode2);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			expect(result.errors).toEqual([]);
			expect(result.extensions).toHaveLength(2);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const errors: string[] = [];
			runner.onError((error) => errors.push(error.error));
			runner.bindCore(extensionActions, extensionContextActions);

			const chained = await runner.emitBeforeAgentStart("hello", undefined, "base", {
				cwd: tempDir,
			});

			expect(errors).toEqual([]);

			expect(chained).toEqual({
				messages: undefined,
				systemPrompt: "base\nfirst\nsecond",
			});
		});

		it("aggregates injected messages and isolates thrown handlers", async () => {
			const extCode1 = `
				export default function(pi) {
					pi.on("before_agent_start", async () => ({
						message: { customType: "note", content: "first" },
						systemPrompt: "first prompt",
					}));
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.on("before_agent_start", async () => {
						throw new Error("before boom");
					});
				}
			`;
			const extCode3 = `
				export default function(pi) {
					pi.on("before_agent_start", async (event) => ({
						message: { customType: "note", content: event.systemPrompt },
						systemPrompt: event.systemPrompt + " + third",
					}));
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "before-agent-start-message-1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "before-agent-start-message-2.ts"), extCode2);
			fs.writeFileSync(path.join(extensionsDir, "before-agent-start-message-3.ts"), extCode3);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const errors: string[] = [];
			runner.onError((error) => errors.push(error.error));
			runner.bindCore(extensionActions, extensionContextActions);

			const chained = await runner.emitBeforeAgentStart("hello", undefined, "base", { cwd: tempDir });

			expect(errors).toEqual(["before boom"]);
			expect(chained).toEqual({
				messages: [
					{ customType: "note", content: "first" },
					{ customType: "note", content: "first prompt" },
				],
				systemPrompt: "first prompt + third",
			});
		});
	});

	describe("tool_result chaining", () => {
		it("chains content modifications across handlers", async () => {
			const extCode1 = `
				export default function(pi) {
					pi.on("tool_result", async (event) => {
						return {
							content: [...event.content, { type: "text", text: "ext1" }],
						};
					});
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.on("tool_result", async (event) => {
						return {
							content: [...event.content, { type: "text", text: "ext2" }],
						};
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "tool-result-1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "tool-result-2.ts"), extCode2);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);

			const chained = await runner.emitToolResult({
				type: "tool_result",
				toolName: "my_tool",
				toolCallId: "call-1",
				input: {},
				content: [{ type: "text", text: "base" }],
				details: { initial: true },
				isError: false,
			});

			expect(chained).toBeDefined();
			const chainedContent = chained?.content;
			expect(chainedContent).toBeDefined();
			expect(chainedContent![0]).toEqual({ type: "text", text: "base" });
			expect(chainedContent).toHaveLength(3);
			const appendedText = chainedContent!
				.slice(1)
				.filter((item): item is { type: "text"; text: string } => item.type === "text")
				.map((item) => item.text);
			expect(appendedText.sort()).toEqual(["ext1", "ext2"]);
		});

		it("preserves previous modifications when later handlers return partial patches", async () => {
			const extCode1 = `
				export default function(pi) {
					pi.on("tool_result", async () => {
						return {
							content: [{ type: "text", text: "first" }],
							details: { source: "ext1" },
						};
					});
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.on("tool_result", async () => {
						return {
							isError: true,
						};
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "tool-result-partial-1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "tool-result-partial-2.ts"), extCode2);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);

			const chained = await runner.emitToolResult({
				type: "tool_result",
				toolName: "my_tool",
				toolCallId: "call-2",
				input: {},
				content: [{ type: "text", text: "base" }],
				details: { initial: true },
				isError: false,
			});

			expect(chained).toEqual({
				content: [{ type: "text", text: "first" }],
				details: { source: "ext1" },
				isError: true,
			});
		});

		it("reports thrown handlers and continues later patches", async () => {
			const extCode1 = `
				export default function(pi) {
					pi.on("tool_result", async () => {
						throw new Error("tool result boom");
					});
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.on("tool_result", async () => ({
						content: [{ type: "text", text: "after" }],
					}));
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "tool-result-error-1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "tool-result-error-2.ts"), extCode2);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const errors: string[] = [];
			runner.onError((error) => errors.push(error.error));

			const chained = await runner.emitToolResult({
				type: "tool_result",
				toolName: "my_tool",
				toolCallId: "call-3",
				input: {},
				content: [{ type: "text", text: "base" }],
				details: undefined,
				isError: false,
			});

			expect(errors).toEqual(["tool result boom"]);
			expect(chained?.content).toEqual([{ type: "text", text: "after" }]);
		});
	});

	describe("result-bearing subscriber aggregation", () => {
		it("aggregates resources with provenance and error isolation", async () => {
			const extCode1 = `
				export default function(pi) {
					pi.on("resources_discover", async () => ({
						skillPaths: ["/skills/one"],
						promptPaths: ["/prompts/one"],
					}));
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.on("resources_discover", async () => {
						throw new Error("resources boom");
					});
				}
			`;
			const extCode3 = `
				export default function(pi) {
					pi.on("resources_discover", async () => ({
						themePaths: ["/themes/three"],
					}));
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "resources-1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "resources-2.ts"), extCode2);
			fs.writeFileSync(path.join(extensionsDir, "resources-3.ts"), extCode3);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const errors: string[] = [];
			runner.onError((error) => errors.push(error.error));

			const resources = await runner.emitResourcesDiscover(tempDir, "startup");

			expect(errors).toEqual(["resources boom"]);
			expect(resources.skillPaths).toEqual([
				{ path: "/skills/one", extensionPath: path.join(extensionsDir, "resources-1.ts") },
			]);
			expect(resources.promptPaths).toEqual([
				{ path: "/prompts/one", extensionPath: path.join(extensionsDir, "resources-1.ts") },
			]);
			expect(resources.themePaths).toEqual([
				{ path: "/themes/three", extensionPath: path.join(extensionsDir, "resources-3.ts") },
			]);
		});

		it("short-circuits cancellable lifecycle events at the first cancellation", async () => {
			const extCode1 = `
				export default function(pi) {
					pi.on("session_before_switch", async () => undefined);
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.on("session_before_switch", async () => ({ cancel: true }));
				}
			`;
			const extCode3 = `
				export default function(pi) {
					pi.on("session_before_switch", async () => {
						globalThis.afterCancel = true;
					});
				}
			`;
			delete (globalThis as { afterCancel?: boolean }).afterCancel;
			fs.writeFileSync(path.join(extensionsDir, "session-before-1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "session-before-2.ts"), extCode2);
			fs.writeFileSync(path.join(extensionsDir, "session-before-3.ts"), extCode3);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);

			const cancellation = await runner.emit({ type: "session_before_switch", reason: "new" });

			expect(cancellation).toEqual({ cancel: true });
			expect((globalThis as { afterCancel?: boolean }).afterCancel).toBeUndefined();
		});

		it("lets subscribers observe sub-agent readiness without owning lifecycle transitions", async () => {
			const extCode1 = `
				export default function(pi) {
					pi.on("sub_agent_readiness", async (event) => {
						globalThis.readinessObserved = {
							taskId: event.envelope.taskId,
							phase: event.phase,
							owner: event.owner,
							readOnly: event.readOnly,
						};
						return { cancel: true, spawnPolicy: { automatic: true } };
					});
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.on("sub_agent_readiness", async () => {
						globalThis.readinessSecondObserverCalled = true;
					});
				}
			`;
			delete (globalThis as { readinessObserved?: unknown }).readinessObserved;
			delete (globalThis as { readinessSecondObserverCalled?: boolean }).readinessSecondObserverCalled;
			fs.writeFileSync(path.join(extensionsDir, "readiness-observer-1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "readiness-observer-2.ts"), extCode2);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const readinessEnvelope = validateSubAgentReadinessEnvelope({
				type: "sub_agent_task_invocation",
				agentId: "agent-opaque",
				runId: "run-opaque",
				taskId: "task-opaque",
				sessionId: "session-opaque",
				input: { text: "observe only" },
				cancellation: { state: "requested", reason: "abort signal requested" },
				limits: { maxChildren: 0, depth: 1, turns: 1 },
			});

			const ownerResult = await runner.emit({
				type: "sub_agent_readiness",
				envelope: readinessEnvelope,
				phase: "recorded",
				owner: "agent",
				readOnly: true,
			});

			expect(ownerResult).toBeUndefined();
			expect((globalThis as { readinessObserved?: unknown }).readinessObserved).toEqual({
				taskId: "task-opaque",
				phase: "recorded",
				owner: "agent",
				readOnly: true,
			});
			expect((globalThis as { readinessSecondObserverCalled?: boolean }).readinessSecondObserverCalled).toBe(true);
		});

		it("chains same-role message_end replacements and rejects invalid roles", async () => {
			const extCode1 = `
				export default function(pi) {
					pi.on("message_end", async (event) => ({
						message: { ...event.message, content: "first" },
					}));
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.on("message_end", async (event) => ({
						message: { ...event.message, role: "assistant", content: [] },
					}));
				}
			`;
			const extCode3 = `
				export default function(pi) {
					pi.on("message_end", async (event) => ({
						message: { ...event.message, content: event.message.content + " third" },
					}));
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "message-end-1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "message-end-2.ts"), extCode2);
			fs.writeFileSync(path.join(extensionsDir, "message-end-3.ts"), extCode3);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const errors: string[] = [];
			runner.onError((error) => errors.push(error.error));
			const message: AgentMessage = { role: "user", content: "base", timestamp: 1 };

			const replacement = await runner.emitMessageEnd({ type: "message_end", message });

			expect(errors).toEqual(["message_end handlers must return a message with the same role"]);
			expect(replacement).toEqual({ role: "user", content: "first third", timestamp: 1 });
		});

		it("chains context and provider request replacements through thrown handlers", async () => {
			const contextMessage: AgentMessage = { role: "user", content: "base", timestamp: 1 };
			const extCode1 = `
				export default function(pi) {
					pi.on("context", async (event) => ({
						messages: [...event.messages, { role: "user", content: "first", timestamp: 2 }],
					}));
					pi.on("before_provider_request", async (event) => ({
						...event.payload,
						first: true,
					}));
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.on("context", async () => {
						throw new Error("context boom");
					});
					pi.on("before_provider_request", async () => {
						throw new Error("provider boom");
					});
				}
			`;
			const extCode3 = `
				export default function(pi) {
					pi.on("context", async (event) => ({
						messages: [...event.messages, { role: "user", content: String(event.messages.length), timestamp: 3 }],
					}));
					pi.on("before_provider_request", async (event) => ({
						...event.payload,
						count: Object.keys(event.payload).length,
					}));
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "context-provider-1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "context-provider-2.ts"), extCode2);
			fs.writeFileSync(path.join(extensionsDir, "context-provider-3.ts"), extCode3);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const errors: string[] = [];
			runner.onError((error) => errors.push(error.error));

			const context = await runner.emitContext([contextMessage]);
			const payload = await runner.emitBeforeProviderRequest({ base: true });
			const contextContents = context.map((message) => {
				if (!("content" in message)) throw new Error(`unexpected message role: ${message.role}`);
				return message.content;
			});

			expect(errors).toEqual(["context boom", "provider boom"]);
			expect(contextContents).toEqual(["base", "first", "2"]);
			expect(payload).toEqual({ base: true, first: true, count: 2 });
		});

		it("keeps tool_call mutation visibility, first block, and error isolation", async () => {
			const extCode1 = `
				export default function(pi) {
					pi.on("tool_call", async (event) => {
						event.input.command += " first";
					});
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.on("tool_call", async () => {
						throw new Error("tool call boom");
					});
				}
			`;
			const extCode3 = `
				export default function(pi) {
					pi.on("tool_call", async (event) => {
						if (event.input.command === "base first") return { block: true, reason: "blocked" };
					});
				}
			`;
			const extCode4 = `
				export default function(pi) {
					pi.on("tool_call", async (event) => {
						event.input.command += " skipped";
					});
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "tool-call-1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "tool-call-2.ts"), extCode2);
			fs.writeFileSync(path.join(extensionsDir, "tool-call-3.ts"), extCode3);
			fs.writeFileSync(path.join(extensionsDir, "tool-call-4.ts"), extCode4);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const errors: string[] = [];
			runner.onError((error) => errors.push(error.error));
			const input = { command: "base" };

			const block = await runner.emitToolCall({
				type: "tool_call",
				toolName: "bash",
				toolCallId: "call-1",
				input,
			});

			expect(errors).toEqual(["tool call boom"]);
			expect(block).toEqual({ block: true, reason: "blocked" });
			expect(input.command).toBe("base first");
		});

		it("returns the first user_bash result after undefined and thrown handlers", async () => {
			const extCode1 = `
				export default function(pi) {
					pi.on("user_bash", async () => undefined);
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.on("user_bash", async () => {
						throw new Error("bash boom");
					});
				}
			`;
			const extCode3 = `
				export default function(pi) {
					pi.on("user_bash", async () => ({
						result: { output: "handled", exitCode: 0, cancelled: false, truncated: false },
					}));
				}
			`;
			const extCode4 = `
				export default function(pi) {
					pi.on("user_bash", async () => ({
						result: { output: "skipped", exitCode: 0, cancelled: false, truncated: false },
					}));
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "user-bash-1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "user-bash-2.ts"), extCode2);
			fs.writeFileSync(path.join(extensionsDir, "user-bash-3.ts"), extCode3);
			fs.writeFileSync(path.join(extensionsDir, "user-bash-4.ts"), extCode4);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const errors: string[] = [];
			runner.onError((error) => errors.push(error.error));

			const userBash = await runner.emitUserBash({
				type: "user_bash",
				command: "echo hi",
				excludeFromContext: false,
				cwd: tempDir,
			});

			expect(errors).toEqual(["bash boom"]);
			expect(userBash?.result?.output).toBe("handled");
		});
	});

	describe("provider registration", () => {
		it("bindCore ignores invalid queued registrations and reports extension error", () => {
			const runtime = createExtensionRuntime();
			runtime.registerProvider(
				"broken-provider",
				{
					streamSimple: (() => {
						throw new Error("should not run");
					}) as any,
				},
				"/tmp/broken-extension.ts",
			);

			const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);
			const errors: string[] = [];
			runner.onError((error) => errors.push(`${error.extensionPath}: ${error.error}`));

			expect(() => runner.bindCore(extensionActions, extensionContextActions)).not.toThrow();
			expect(errors).toEqual([
				'/tmp/broken-extension.ts: Provider broken-provider: "api" is required when registering streamSimple.',
			]);
			expect(() => modelRegistry.refresh()).not.toThrow();
		});

		it("pre-bind unregister removes all queued registrations for a provider", () => {
			const runtime = createExtensionRuntime();

			runtime.registerProvider("queued-provider", providerModelConfig);
			runtime.registerProvider("queued-provider", {
				...providerModelConfig,
				models: [
					{
						id: "instant-model-2",
						name: "Instant Model 2",
						reasoning: false,
						input: ["text"],
						cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
						contextWindow: 128000,
						maxTokens: 4096,
					},
				],
			});
			expect(runtime.pendingProviderRegistrations).toHaveLength(2);

			runtime.unregisterProvider("queued-provider");
			expect(runtime.pendingProviderRegistrations).toHaveLength(0);
		});

		it("post-bind register and unregister take effect immediately", () => {
			const runtime = createExtensionRuntime();
			const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);

			runner.bindCore(extensionActions, extensionContextActions);
			expect(runtime.pendingProviderRegistrations).toHaveLength(0);

			runtime.registerProvider("instant-provider", providerModelConfig);
			expect(runtime.pendingProviderRegistrations).toHaveLength(0);
			expect(modelRegistry.find("instant-provider", "instant-model")).toBeDefined();

			runtime.unregisterProvider("instant-provider");
			expect(modelRegistry.find("instant-provider", "instant-model")).toBeUndefined();
		});
	});

	describe("command context", () => {
		it("passes fork options through to the bound handler", async () => {
			const runtime = createExtensionRuntime();
			const runner = new ExtensionRunner([], runtime, tempDir, sessionManager, modelRegistry);
			const fork = vi.fn(async () => ({ cancelled: false }));

			runner.bindCommandContext({
				waitForIdle: async () => {},
				newSession: async () => ({ cancelled: false }),
				fork,
				navigateTree: async () => ({ cancelled: false }),
				switchSession: async () => ({ cancelled: false }),
				reload: async () => {},
			});

			const commandContext = runner.createCommandContext();
			await commandContext.fork("entry-1");
			expect(fork).toHaveBeenCalledWith("entry-1", undefined);

			await commandContext.fork("entry-2", { position: "at" });
			expect(fork).toHaveBeenLastCalledWith("entry-2", { position: "at" });
		});
	});

	describe("hasHandlers", () => {
		it("returns true when handlers exist for event type", async () => {
			const extCode = `
				export default function(pi) {
					pi.on("tool_call", async () => undefined);
				}
			`;
			fs.writeFileSync(path.join(extensionsDir, "handler.ts"), extCode);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);

			expect(runner.hasHandlers("tool_call")).toBe(true);
			expect(runner.hasHandlers("agent_end")).toBe(false);
		});
	});
});
