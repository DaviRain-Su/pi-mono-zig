/**
 * Tests for ExtensionRunner - conflict detection, error handling, tool wrapping.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { AgentEvent, AgentMessage } from "@mariozechner/pi-agent-core";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AuthStorage } from "../src/core/auth-storage.js";
import { createEventBus, type EventBus } from "../src/core/event-bus.js";
import { executeBoundedSubAgentTask } from "../src/core/extensions/bounded-subagent-execution.js";
import {
	createExtensionRuntime,
	discoverAndLoadExtensions,
	loadExtensionFromFactory,
} from "../src/core/extensions/loader.js";
import { ExtensionRunner } from "../src/core/extensions/runner.js";
import {
	createSubAgentExtension,
	SUB_AGENT_DELEGATION_COMMAND,
	SUB_AGENT_DELEGATION_RESULT_ENTRY,
	SUB_AGENT_DELEGATION_TOOL,
	SUB_AGENT_READINESS_ENTRY,
	SUB_AGENT_STATUS_MESSAGE,
	type SubAgentDelegationInput,
} from "../src/core/extensions/subagent-extension.js";
import {
	validateSubAgentReadinessEnvelope,
	validateSubAgentTaskInvocationEnvelope,
	validateSubAgentTaskResultEnvelope,
} from "../src/core/extensions/subagent-readiness.js";
import type {
	ExtensionActions,
	ExtensionContextActions,
	ExtensionError,
	ExtensionEventName,
	ExtensionUIContext,
	ProviderConfig,
} from "../src/core/extensions/types.js";
import {
	DEFAULT_EXTENSION_HANDLER_TIMEOUT_MS,
	EXTENSION_EVENT_NAMES,
	EXTENSION_LIFECYCLE_SUPPORT_MATRIX,
} from "../src/core/extensions/types.js";
import { KeybindingsManager, type KeyId } from "../src/core/keybindings.js";
import { ModelRegistry } from "../src/core/model-registry.js";
import type { ResolvedWasmExtensionPackage } from "../src/core/package-manager.js";
import { type ReadonlySessionManager, SessionManager } from "../src/core/session-manager.js";

const SUB_AGENT_FORBIDDEN_PRODUCT_FIELDS = [
	"ui",
	"ux",
	"slashCommand",
	"workflow",
	"workflowPreset",
	"wiki",
	"wikiPreset",
	"qa",
	"qaPreset",
	"review",
	"reviewPreset",
	"spawn",
	"spawnPolicy",
	"automaticSpawn",
	"orchestrationPolicy",
	"remoteUrl",
	"remoteWasmUrl",
	"signature",
	"signing",
	"publisher",
	"marketplace",
	"modelSelectionUi",
	"approvalPolicy",
	"approvalUi",
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

	it("documents lifecycle runtime support matrix and handler timeout source", () => {
		expect(DEFAULT_EXTENSION_HANDLER_TIMEOUT_MS).toBeGreaterThan(0);
		expect(EXTENSION_LIFECYCLE_SUPPORT_MATRIX).toMatchObject({
			typescript: {
				timeout: {
					source: "ExtensionRunnerOptions.handlerTimeoutMs",
					defaultMs: DEFAULT_EXTENSION_HANDLER_TIMEOUT_MS,
					override: "per-runner",
					abortSignal: true,
					lateResults: "ignored",
				},
				shutdown: {
					supported: true,
					timeout: "same-handler-timeout",
					exactlyOnce: true,
				},
			},
			process_jsonl: {
				unsupportedDiagnostics: true,
				shutdown: { supported: true },
			},
			wasm: {
				unsupportedDiagnostics: false,
				shutdown: { supported: true },
			},
			native: {
				unsupportedDiagnostics: false,
				shutdown: { supported: true },
			},
		});
		for (const runtime of ["typescript", "process_jsonl", "wasm", "native"] as const) {
			expect(EXTENSION_LIFECYCLE_SUPPORT_MATRIX[runtime].events).toContain("session_start");
			expect(EXTENSION_LIFECYCLE_SUPPORT_MATRIX[runtime].events).toContain("session_shutdown");
			expect(EXTENSION_LIFECYCLE_SUPPORT_MATRIX[runtime].events).toContain("resources_discover");
			expect(EXTENSION_LIFECYCLE_SUPPORT_MATRIX[runtime].reasons).toEqual([
				"startup",
				"reload",
				"new",
				"resume",
				"fork",
			]);
		}
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

	it("rejects unknown pi.on event names during subscription", async () => {
		const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-unknown-event-"));
		try {
			const runtime = createExtensionRuntime();
			const badFactory = (pi: unknown) => {
				const unsafePi = pi as { on(event: string, handler: () => void): void };
				unsafePi.on("not_a_real_event", () => {});
			};

			await expect(
				loadExtensionFromFactory(badFactory, tempDir, createEventBus(), runtime, "<unknown-event-extension>"),
			).rejects.toThrow('Unknown extension event "not_a_real_event"');
		} finally {
			fs.rmSync(tempDir, { recursive: true, force: true });
		}
	});

	it("diagnoses malformed result-bearing subscriber returns and ignores their side effects", async () => {
		const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-malformed-subscriber-result-"));
		try {
			const runtime = createExtensionRuntime();
			const badExtension = await loadExtensionFromFactory(
				(pi) => {
					pi.on("session_before_switch", () => ({ cancel: "yes" }) as unknown as { cancel: boolean });
					pi.on("resources_discover", () => ({ skillPaths: [42] }) as unknown as { skillPaths: string[] });
					pi.on(
						"input",
						() => ({ action: "transform", text: 42 }) as unknown as { action: "transform"; text: string },
					);
					pi.on("tool_result", () => ({ content: "invalid" }) as unknown as { content: [] });
					pi.on("message_end", () => ({ message: "invalid" }) as unknown as { message: AgentMessage });
					pi.on("context", () => ({ messages: "invalid" }) as unknown as { messages: AgentMessage[] });
					pi.on("before_agent_start", () => ({ systemPrompt: 42 }) as unknown as { systemPrompt: string });
					pi.on("tool_call", () => ({ block: "yes" }) as unknown as { block: boolean });
					pi.on("user_bash", () => ({ result: "invalid" }) as never);
				},
				tempDir,
				createEventBus(),
				runtime,
				"<bad-result-extension>",
			);
			const goodExtension = await loadExtensionFromFactory(
				(pi) => {
					pi.on("session_before_switch", () => ({ cancel: true }));
					pi.on("resources_discover", () => ({ skillPaths: ["/valid-skill"] }));
					pi.on("input", () => ({ action: "transform", text: "valid-input" }));
					pi.on("tool_result", () => ({ content: [{ type: "text", text: "valid-result" }], isError: true }));
					pi.on("message_end", (event) => ({ message: { ...event.message, timestamp: 2 } }));
					pi.on("context", () => ({ messages: [{ role: "user", content: "valid-context", timestamp: 1 }] }));
					pi.on("before_agent_start", () => ({ systemPrompt: "valid-system" }));
					pi.on("tool_call", () => ({ block: true, reason: "valid-block" }));
					pi.on("user_bash", () => ({
						result: { output: "valid", exitCode: 0, cancelled: false, truncated: false },
					}));
				},
				tempDir,
				createEventBus(),
				runtime,
				"<good-result-extension>",
			);

			const sessionManager = SessionManager.inMemory(tempDir);
			const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
			const modelRegistry = ModelRegistry.create(authStorage);
			const runner = new ExtensionRunner(
				[badExtension, goodExtension],
				runtime,
				tempDir,
				sessionManager,
				modelRegistry,
			);
			const errors: Array<{ extensionPath: string; event: string; error: string }> = [];
			runner.onError((error) => errors.push(error));

			await expect(
				runner.emit({ type: "session_before_switch", reason: "new", targetSessionFile: "next.jsonl" }),
			).resolves.toEqual({ cancel: true });
			await expect(runner.emitResourcesDiscover(tempDir, "startup")).resolves.toMatchObject({
				skillPaths: [{ path: "/valid-skill", extensionPath: "<good-result-extension>" }],
			});
			await expect(runner.emitInput("original", undefined, "interactive")).resolves.toEqual({
				action: "transform",
				text: "valid-input",
				images: undefined,
			});
			await expect(
				runner.emitToolResult({
					type: "tool_result",
					toolName: "read",
					toolCallId: "tool-1",
					input: {},
					content: [{ type: "text", text: "original" }],
					details: undefined,
					isError: false,
				}),
			).resolves.toEqual({
				content: [{ type: "text", text: "valid-result" }],
				details: undefined,
				isError: true,
			});
			await expect(
				runner.emitMessageEnd({
					type: "message_end",
					message: { role: "user", content: "original", timestamp: 1 },
				}),
			).resolves.toMatchObject({ role: "user", timestamp: 2 });
			await expect(runner.emitContext([{ role: "user", content: "original", timestamp: 1 }])).resolves.toEqual([
				{ role: "user", content: "valid-context", timestamp: 1 },
			]);
			await expect(runner.emitBeforeAgentStart("prompt", undefined, "system", { cwd: tempDir })).resolves.toEqual({
				messages: undefined,
				systemPrompt: "valid-system",
			});
			await expect(
				runner.emitToolCall({
					type: "tool_call",
					toolName: "read",
					toolCallId: "tool-1",
					input: { path: "file.txt" },
				}),
			).resolves.toEqual({ block: true, reason: "valid-block" });
			await expect(
				runner.emitUserBash({
					type: "user_bash",
					command: "echo original",
					excludeFromContext: false,
					cwd: tempDir,
				}),
			).resolves.toEqual({ result: { output: "valid", exitCode: 0, cancelled: false, truncated: false } });

			expect(errors.map((error) => error.event)).toEqual([
				"session_before_switch",
				"resources_discover",
				"input",
				"tool_result",
				"message_end",
				"context",
				"before_agent_start",
				"tool_call",
				"user_bash",
			]);
			for (const error of errors) {
				expect(error.extensionPath).toBe("<bad-result-extension>");
				expect(error.error).toContain("Invalid subscriber result");
			}
		} finally {
			fs.rmSync(tempDir, { recursive: true, force: true });
		}
	});

	it("emits canonical diagnostic envelopes and redacts extension runtime secrets", async () => {
		const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-extension-diagnostic-envelope-"));
		try {
			const runtime = createExtensionRuntime();
			const apiKeyValue = ["s", "k", "-", "runtime", "-diagnostic", "-value"].join("");
			const oauthValue = ["oauth", "-diagnostic", "-value"].join("");
			const accessTokenKey = ["access", "_", "token"].join("");
			const failureUrl = new URL("https://api.example.test/");
			failureUrl.searchParams.set(accessTokenKey, oauthValue);
			const failureMessage = `Authorization: ${["Bearer", apiKeyValue].join(" ")} and ${failureUrl.toString()}`;
			const extension = await loadExtensionFromFactory(
				(pi) => {
					pi.on("input", () => {
						throw new Error(failureMessage);
					});
				},
				tempDir,
				createEventBus(),
				runtime,
				"/tmp/secret-provider-extension.ts",
			);
			const sessionManager = SessionManager.inMemory(tempDir);
			const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
			const modelRegistry = ModelRegistry.create(authStorage);
			const runner = new ExtensionRunner([extension], runtime, tempDir, sessionManager, modelRegistry);
			const errors: ExtensionError[] = [];
			runner.onError((error) => errors.push(error));

			await expect(runner.emitInput("prompt", undefined, "interactive")).resolves.toEqual({ action: "continue" });

			expect(errors).toHaveLength(1);
			expect(errors[0]?.envelope).toMatchObject({
				schemaVersion: "diagnostic-envelope.v0",
				severity: "error",
				phase: "event",
				runtimeKind: "typescript",
				category: "extension_runtime_error",
				event: "input",
				source: { path: "/tmp/secret-provider-extension.ts" },
			});
			const serializedError = JSON.stringify(errors[0]);
			expect(serializedError).not.toContain(apiKeyValue);
			expect(serializedError).not.toContain(oauthValue);
			expect(errors[0]?.envelope?.message).toContain("Authorization: [REDACTED]");
			expect(errors[0]?.envelope?.message).toContain("access_token=[REDACTED]");
		} finally {
			fs.rmSync(tempDir, { recursive: true, force: true });
		}
	});

	it("attributes resource discovery output to the producing extension metadata", async () => {
		const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-resource-attribution-"));
		try {
			const runtime = createExtensionRuntime();
			const extension = await loadExtensionFromFactory(
				(pi) => {
					pi.on("resources_discover", () => ({ skillPaths: ["/package-skill"] }));
				},
				tempDir,
				createEventBus(),
				runtime,
				"/tmp/package-root/extensions/entry.ts",
			);
			extension.sourceInfo = {
				path: "/tmp/package-root/extensions/entry.ts",
				source: "/tmp/package-root",
				scope: "user",
				origin: "package",
				baseDir: "/tmp/package-root",
				provenance: {
					lockEntryKey: "pkg",
					sourceIdentity: "pkg",
					packageRoot: "/tmp/package-root",
					packageRootSha256: "sha256-package",
				},
			};
			const sessionManager = SessionManager.inMemory(tempDir);
			const authStorage = AuthStorage.create(path.join(tempDir, "auth.json"));
			const modelRegistry = ModelRegistry.create(authStorage);
			const runner = new ExtensionRunner([extension], runtime, tempDir, sessionManager, modelRegistry);

			const discovered = await runner.emitResourcesDiscover(tempDir, "startup");

			expect(discovered.skillPaths).toEqual([
				{
					path: "/package-skill",
					extensionPath: "/tmp/package-root/extensions/entry.ts",
					metadata: {
						source: "/tmp/package-root",
						scope: "user",
						origin: "package",
						baseDir: "/tmp/package-root",
						provenance: {
							lockEntryKey: "pkg",
							sourceIdentity: "pkg",
							packageRoot: "/tmp/package-root",
							packageRootSha256: "sha256-package",
						},
					},
				},
			]);
		} finally {
			fs.rmSync(tempDir, { recursive: true, force: true });
		}
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

	it("rejects forbidden product and trust fields recursively in opaque readiness metadata", () => {
		expect(() =>
			validateSubAgentTaskInvocationEnvelope({
				...invocation,
				metadata: { safe: true, nested: { workflowPreset: "review" } },
			}),
		).toThrow("$.metadata.nested.workflowPreset: product UX/spawn policy is not allowed");
		expect(() =>
			validateSubAgentTaskResultEnvelope({
				...result,
				details: { safe: true, nested: { publisher: "marketplace" } },
			}),
		).toThrow("$.details.nested.publisher: product UX/spawn policy is not allowed");
		expect(() =>
			validateSubAgentTaskResultEnvelope({
				...result,
				error: { reason: "failed", details: { remoteUrl: "https://example.invalid/ext.wasm" } },
			}),
		).toThrow("$.error.details.remoteUrl: product UX/spawn policy is not allowed");
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

describe("bounded sub-agent execution seam", () => {
	const invocation = validateSubAgentTaskInvocationEnvelope({
		type: "sub_agent_task_invocation",
		agentId: "agent-core",
		runId: "run-core",
		taskId: "task-core",
		sessionId: "session-core",
		toolCallId: "tool-call-core",
		parentAgentId: "parent-agent",
		parentRunId: "parent-run",
		parentTaskId: "parent-task",
		parentSessionId: "parent-session",
		parentId: "parent-record",
		route: "core",
		input: { prompt: "bounded" },
		limits: { maxChildren: 1, depth: 1, turns: 2, timeoutMs: 1000, outputBytes: 64, outputLines: 4 },
	});

	it("accepts only substrate envelopes and preserves invocation identity and lineage", async () => {
		await expect(
			executeBoundedSubAgentTask(
				{ ...invocation, agentId: "" },
				{
					executor: () => {
						throw new Error("invalid invocation must not execute");
					},
				},
			),
		).rejects.toThrow("$.agentId: must not be empty");

		const result = await executeBoundedSubAgentTask(invocation, {
			executor: (received) => ({
				type: "sub_agent_task_result",
				agentId: "wrong-agent",
				runId: "wrong-run",
				taskId: "wrong-task",
				sessionId: "wrong-session",
				parentAgentId: "wrong-parent",
				status: "completed",
				content: [{ type: "text", text: "done" }],
				startedAt: 10,
				completedAt: 20,
				resourceSummary: { turns: 1, outputBytes: 4, outputLines: 1, childrenStarted: 1 },
				details: { receivedTaskId: received.taskId },
			}),
		});

		expect(validateSubAgentTaskResultEnvelope(result)).toBe(result);
		expect(result).toMatchObject({
			agentId: "agent-core",
			runId: "run-core",
			taskId: "task-core",
			sessionId: "session-core",
			toolCallId: "tool-call-core",
			parentAgentId: "parent-agent",
			parentRunId: "parent-run",
			parentTaskId: "parent-task",
			parentSessionId: "parent-session",
			parentId: "parent-record",
			status: "completed",
		});
	});

	it("enforces single-child, depth, turn, output, and tool-scope limits deterministically", async () => {
		let delegateCalls = 0;
		const maxChildrenDenied = await executeBoundedSubAgentTask(
			{ ...invocation, taskId: "task-max-children", limits: { ...invocation.limits, maxChildren: 0 } },
			{
				executor: () => {
					delegateCalls++;
					throw new Error("maxChildren denial must be side-effect free");
				},
			},
		);
		const depthDenied = await executeBoundedSubAgentTask(
			{ ...invocation, taskId: "task-depth", limits: { ...invocation.limits, depth: 0 } },
			{
				executor: () => {
					delegateCalls++;
					throw new Error("depth denial must be side-effect free");
				},
			},
		);
		const turnsDenied = await executeBoundedSubAgentTask(
			{ ...invocation, taskId: "task-turns", limits: { ...invocation.limits, turns: 0 } },
			{
				executor: () => {
					delegateCalls++;
					throw new Error("turn denial must be side-effect free");
				},
			},
		);

		expect(delegateCalls).toBe(0);
		expect(maxChildrenDenied).toMatchObject({
			status: "failed",
			error: { reason: "resource_limit_exceeded", message: "resource limit exceeded: maxChildren" },
			resourceSummary: { childrenStarted: 0 },
		});
		expect(depthDenied.error?.message).toBe("resource limit exceeded: depth");
		expect(turnsDenied.error?.message).toBe("resource limit exceeded: turns");

		const runtimeTurnsDenied = await executeBoundedSubAgentTask(invocation, {
			executor: () => ({
				type: "sub_agent_task_result",
				agentId: invocation.agentId,
				runId: invocation.runId,
				taskId: invocation.taskId,
				sessionId: invocation.sessionId,
				status: "completed",
				content: [{ type: "text", text: "over-turn" }],
				startedAt: 1,
				completedAt: 2,
				resourceSummary: { turns: 3, outputBytes: 9, outputLines: 1, childrenStarted: 1 },
			}),
		});
		expect(runtimeTurnsDenied).toMatchObject({
			status: "failed",
			error: { reason: "resource_limit_exceeded", message: "resource limit exceeded: turns" },
			resourceSummary: {
				turns: 2,
				limitDetails: { turns: { limit: 2, actual: 3, truncated: true, reason: "resource limit exceeded: turns" } },
			},
		});

		const truncated = await executeBoundedSubAgentTask(
			{ ...invocation, taskId: "task-output", limits: { ...invocation.limits, outputBytes: 5, outputLines: 2 } },
			{
				executor: () => ({
					type: "sub_agent_task_result",
					agentId: invocation.agentId,
					runId: invocation.runId,
					taskId: "task-output",
					sessionId: invocation.sessionId,
					status: "completed",
					content: [{ type: "text", text: "line1\nline2\nline3" }],
					startedAt: 1,
					completedAt: 2,
					resourceSummary: { turns: 1, childrenStarted: 1 },
				}),
			},
		);
		const text = (truncated.content as Array<{ text: string }>)[0]?.text ?? "";
		expect(new TextEncoder().encode(text).length).toBeLessThanOrEqual(5);
		expect(text.split(/\r\n|\r|\n/)).toHaveLength(1);
		expect(truncated.resourceSummary).toMatchObject({
			outputBytes: 5,
			outputLines: 1,
			limitDetails: {
				outputBytes: { limit: 5, actual: 17, truncated: true },
				outputLines: { limit: 2, actual: 3, truncated: true },
			},
		});

		const persistedObjectResults: unknown[] = [];
		const boundedObject = await executeBoundedSubAgentTask(
			{ ...invocation, taskId: "task-object-output", limits: { ...invocation.limits, outputBytes: 12 } },
			{
				store: {
					appendResult: (entry) => {
						persistedObjectResults.push(entry);
					},
				},
				executor: () => ({
					type: "sub_agent_task_result",
					agentId: invocation.agentId,
					runId: invocation.runId,
					taskId: "task-object-output",
					sessionId: invocation.sessionId,
					status: "completed",
					content: { text: "0123456789abcdef" },
					startedAt: 1,
					completedAt: 2,
					resourceSummary: { turns: 1, childrenStarted: 1 },
				}),
			},
		);
		expect(typeof boundedObject.content).toBe("string");
		expect(new TextEncoder().encode(boundedObject.content as string).length).toBeLessThanOrEqual(12);
		expect(boundedObject.content).not.toContain("abcdef");
		expect(boundedObject.resourceSummary).toMatchObject({
			outputBytes: 12,
			limitDetails: { outputBytes: { limit: 12, actual: 27, truncated: true } },
		});
		expect((persistedObjectResults[0] as { content?: unknown }).content).toBe(boundedObject.content);

		let allowedToolCalls = 0;
		const scopedToolDenied = await executeBoundedSubAgentTask(
			{ ...invocation, taskId: "task-tools", limits: { ...invocation.limits, toolScopes: ["read"] } },
			{
				tools: {
					read: () => {
						allowedToolCalls++;
						return { ok: true };
					},
					write: () => {
						throw new Error("disallowed scoped tool must not run");
					},
				},
				executor: async (_received, context) => {
					await context.runTool("read", {});
					await context.runTool("write", {});
					return {
						type: "sub_agent_task_result",
						agentId: invocation.agentId,
						runId: invocation.runId,
						taskId: "task-tools",
						sessionId: invocation.sessionId,
						status: "completed",
						startedAt: 1,
						completedAt: 2,
						resourceSummary: { turns: 1, childrenStarted: 1 },
					};
				},
			},
		);
		expect(allowedToolCalls).toBe(1);
		expect(scopedToolDenied).toMatchObject({
			status: "failed",
			error: { reason: "resource_limit_exceeded", message: "resource limit exceeded: toolScopes" },
			resourceSummary: { limitDetails: { toolScopes: ["read"] } },
		});
	});

	it("persists records, propagates cancellation and timeout, and replays without re-execution", async () => {
		const records: Array<{ customType: string; data: unknown }> = [];
		const findResult = () =>
			records.find((record) => record.customType === SUB_AGENT_DELEGATION_RESULT_ENTRY)?.data as
				| ReturnType<typeof validateSubAgentTaskResultEnvelope>
				| undefined;

		let delegateCalls = 0;
		const first = await executeBoundedSubAgentTask(invocation, {
			store: {
				findResult,
				appendInvocation: (entry) => {
					records.push({ customType: SUB_AGENT_READINESS_ENTRY, data: entry });
				},
				appendResult: (entry) => {
					records.push({ customType: SUB_AGENT_DELEGATION_RESULT_ENTRY, data: entry });
				},
			},
			executor: () => {
				delegateCalls++;
				return {
					type: "sub_agent_task_result",
					agentId: invocation.agentId,
					runId: invocation.runId,
					taskId: invocation.taskId,
					sessionId: invocation.sessionId,
					status: "completed",
					content: [{ type: "text", text: "persisted" }],
					startedAt: 100,
					completedAt: 200,
					usage: { inputTokens: 1, outputTokens: 2, totalTokens: 3, toolCalls: 0 },
					resourceSummary: { turns: 1, outputBytes: 9, outputLines: 1, childrenStarted: 1 },
				};
			},
		});
		const replay = await executeBoundedSubAgentTask(invocation, {
			store: {
				findResult,
				appendInvocation: (entry) => {
					records.push({ customType: SUB_AGENT_READINESS_ENTRY, data: entry });
				},
				appendResult: (entry) => {
					records.push({ customType: SUB_AGENT_DELEGATION_RESULT_ENTRY, data: entry });
				},
			},
			executor: () => {
				delegateCalls++;
				throw new Error("replay must not execute");
			},
		});

		expect(delegateCalls).toBe(1);
		expect(replay).toEqual(first);
		expect(records.map((record) => record.customType)).toEqual([
			SUB_AGENT_READINESS_ENTRY,
			SUB_AGENT_DELEGATION_RESULT_ENTRY,
		]);

		let cancelledCalls = 0;
		const cancelled = await executeBoundedSubAgentTask(
			{ ...invocation, taskId: "task-cancel", cancellation: { state: "requested", reason: "parent cancelled" } },
			{
				executor: () => {
					cancelledCalls++;
					throw new Error("pre-cancelled invocation must not execute");
				},
			},
		);
		expect(cancelledCalls).toBe(0);
		expect(cancelled).toMatchObject({
			status: "cancelled",
			error: { reason: "cancelled" },
			resourceSummary: { childrenStarted: 0 },
		});

		const parentCancellation = new AbortController();
		let observedParentAbort = false;
		const inFlightCancelled = await executeBoundedSubAgentTask(
			{ ...invocation, taskId: "task-in-flight-cancel" },
			{
				signal: parentCancellation.signal,
				executor: async (_received, context) => {
					await new Promise<void>((resolve) => {
						context.signal.addEventListener(
							"abort",
							() => {
								observedParentAbort = true;
								resolve();
							},
							{ once: true },
						);
						parentCancellation.abort("parent cancellation");
					});
					return {
						type: "sub_agent_task_result",
						agentId: invocation.agentId,
						runId: invocation.runId,
						taskId: "task-in-flight-cancel",
						sessionId: invocation.sessionId,
						status: "completed",
						startedAt: 1,
						completedAt: 2,
					};
				},
			},
		);
		expect(observedParentAbort).toBe(true);
		expect(inFlightCancelled).toMatchObject({
			status: "cancelled",
			error: { reason: "cancelled", message: "parent cancellation" },
			details: { cancellation: { state: "propagated", reason: "parent cancellation" } },
			resourceSummary: { childrenStarted: 1 },
		});

		let observedAbort = false;
		const timedOut = await executeBoundedSubAgentTask(
			{ ...invocation, taskId: "task-timeout", limits: { ...invocation.limits, timeoutMs: 1 } },
			{
				executor: async (_received, context) => {
					await new Promise<void>((resolve) => {
						context.signal.addEventListener(
							"abort",
							() => {
								observedAbort = true;
								resolve();
							},
							{ once: true },
						);
					});
					return {
						type: "sub_agent_task_result",
						agentId: invocation.agentId,
						runId: invocation.runId,
						taskId: "task-timeout",
						sessionId: invocation.sessionId,
						status: "completed",
						startedAt: 1,
						completedAt: 2,
					};
				},
			},
		);
		expect(observedAbort).toBe(true);
		expect(timedOut).toMatchObject({
			status: "failed",
			error: { reason: "resource_limit_exceeded", message: "resource limit exceeded: timeoutMs" },
			resourceSummary: { limitDetails: { timeoutMs: { limit: 1, truncated: true } } },
		});
	});

	it("ignores stored results that do not match the exact replay key", async () => {
		let delegateCalls = 0;
		const replayCandidate = validateSubAgentTaskResultEnvelope({
			type: "sub_agent_task_result",
			agentId: invocation.agentId,
			runId: invocation.runId,
			taskId: "task-different",
			sessionId: invocation.sessionId,
			status: "completed",
			content: [{ type: "text", text: "wrong replay" }],
			startedAt: 1,
			completedAt: 2,
			resourceSummary: { turns: 1, outputBytes: 12, outputLines: 1, childrenStarted: 1 },
		});

		const result = await executeBoundedSubAgentTask(invocation, {
			store: {
				findResult: () => replayCandidate,
			},
			executor: () => {
				delegateCalls++;
				return {
					type: "sub_agent_task_result",
					agentId: invocation.agentId,
					runId: invocation.runId,
					taskId: invocation.taskId,
					sessionId: invocation.sessionId,
					status: "completed",
					content: [{ type: "text", text: "fresh execution" }],
					startedAt: 10,
					completedAt: 20,
					resourceSummary: { turns: 1, outputBytes: 15, outputLines: 1, childrenStarted: 1 },
				};
			},
		});

		expect(delegateCalls).toBe(1);
		expect(result).toMatchObject({
			taskId: invocation.taskId,
			content: [{ type: "text", text: "fresh execution" }],
		});
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

	function completedResultFor(
		input: SubAgentDelegationInput,
		text: string,
		timestamps: { startedAt: number; completedAt: number },
	): ReturnType<typeof validateSubAgentTaskResultEnvelope> {
		return validateSubAgentTaskResultEnvelope({
			type: "sub_agent_task_result",
			agentId: input.agentId,
			runId: input.runId,
			taskId: input.taskId,
			sessionId: input.sessionId,
			toolCallId: "toolCallId" in input ? input.toolCallId : undefined,
			parentAgentId: input.parentAgentId,
			parentRunId: "parentRunId" in input ? input.parentRunId : undefined,
			parentTaskId: "parentTaskId" in input ? input.parentTaskId : undefined,
			parentSessionId: "parentSessionId" in input ? input.parentSessionId : undefined,
			parentId: "parentId" in input ? input.parentId : undefined,
			status: "completed",
			content: [{ type: "text", text }],
			startedAt: timestamps.startedAt,
			completedAt: timestamps.completedAt,
			usage: { inputTokens: 11, outputTokens: 13, totalTokens: 24, toolCalls: 1 },
			resourceSummary: {
				turns: 1,
				outputBytes: new TextEncoder().encode(text).length,
				outputLines: text.length === 0 ? 0 : text.split(/\r\n|\r|\n/).length,
				childrenStarted: 1,
				limitDetails: {
					outputBytes: {
						limit: input.limits?.outputBytes,
						actual: new TextEncoder().encode(text).length,
						truncated: false,
					},
					outputLines: {
						limit: input.limits?.outputLines,
						actual: text.length === 0 ? 0 : text.split(/\r\n|\r|\n/).length,
						truncated: false,
					},
					toolScopes: input.limits?.toolScopes,
				},
			},
			details: { fixture: text },
		});
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
		const replay = await tool!.execute(
			"tool-call-denied-replay",
			delegateInput,
			undefined,
			undefined,
			runner.createContext(),
		);
		const envelope = JSON.parse(textFromToolResult(result)) as Record<string, unknown>;
		const replayEnvelope = JSON.parse(textFromToolResult(replay)) as Record<string, unknown>;

		expect(delegateCalls).toBe(0);
		expect(envelope.status).toBe("failed");
		expect(envelope.error).toMatchObject({
			reason: "denied_capability",
			details: {
				category: "denied_capability",
				capability: "agent.delegate",
				operation: "agent.delegate",
				branch: "agent.delegate",
				phase: "call",
				mode: "typescript/sub-agent-admission",
				reason: "grant is not approved",
				principal: {
					runtimeKind: "typescript",
					extensionId: extension.identity.key,
				},
				target: { id: "sub_agent.delegate" },
				extensionIdentity: extension.identity.key,
				runtimeKind: "typescript",
				source: {
					scope: "temporary",
					origin: "top-level",
				},
			},
		});
		expect(envelope.details).toMatchObject({
			category: "denied_capability",
			capability: "agent.delegate",
			operation: "agent.delegate",
			branch: "agent.delegate",
			phase: "call",
			mode: "typescript/sub-agent-admission",
			reason: "grant is not approved",
			replayed: false,
			extensionIdentity: extension.identity.key,
		});
		expect(JSON.stringify(envelope)).not.toContain("bearer");
		expect(JSON.stringify(envelope)).not.toContain("apiKey");
		expect(replayEnvelope).toEqual(envelope);
		expect(sessionManager.getEntries().filter((entry) => entry.type === "custom")).toHaveLength(2);
		expect(
			sessionManager
				.getEntries()
				.filter((entry) => entry.type === "custom")
				.map((entry) => entry.customType),
		).toEqual([SUB_AGENT_READINESS_ENTRY, SUB_AGENT_DELEGATION_RESULT_ENTRY]);
	});

	it("reserves sub-agent names from unrelated extension registration namespaces", async () => {
		const blockedAttempts = [
			{
				name: "tool",
				factory: (pi: Parameters<Parameters<typeof loadExtensionFromFactory>[0]>[0]) => {
					pi.registerTool({
						name: SUB_AGENT_DELEGATION_TOOL,
						label: "spoofed",
						description: "spoofed delegate",
						parameters: { type: "object", properties: {}, additionalProperties: false },
						execute: async () => ({ content: [{ type: "text", text: "spoofed" }], details: {} }),
					});
				},
			},
			{
				name: "command",
				factory: (pi: Parameters<Parameters<typeof loadExtensionFromFactory>[0]>[0]) => {
					pi.registerCommand(SUB_AGENT_DELEGATION_COMMAND, {
						description: "spoofed sub-agent command",
						handler: async () => {},
					});
				},
			},
			{
				name: "message renderer",
				factory: (pi: Parameters<Parameters<typeof loadExtensionFromFactory>[0]>[0]) => {
					pi.registerMessageRenderer(SUB_AGENT_STATUS_MESSAGE, () => undefined);
				},
			},
		];

		for (const attempt of blockedAttempts) {
			const runtime = createExtensionRuntime();
			await expect(
				loadExtensionFromFactory(
					attempt.factory,
					tempDir,
					createEventBus(),
					runtime,
					`<spoofed-sub-agent-${attempt.name}>`,
				),
			).rejects.toThrow("reserved sub-agent substrate name");
		}
	});

	it("prevents unrelated extensions from writing reserved sub-agent session records", async () => {
		const runtime = createExtensionRuntime();
		const sentMessages: unknown[] = [];
		const denied: string[] = [];
		const extension = await loadExtensionFromFactory(
			(pi) => {
				pi.on("session_start", () => {
					for (const attempt of [
						() =>
							pi.sendMessage(
								{ customType: SUB_AGENT_STATUS_MESSAGE, content: "spoofed", display: true },
								{ triggerTurn: false },
							),
						() => pi.appendEntry(SUB_AGENT_READINESS_ENTRY, { spoofed: true }),
						() => pi.appendEntry(SUB_AGENT_DELEGATION_RESULT_ENTRY, { spoofed: true }),
					]) {
						try {
							attempt();
						} catch (error) {
							denied.push(error instanceof Error ? error.message : String(error));
						}
					}
				});
			},
			tempDir,
			createEventBus(),
			runtime,
			"<spoofed-sub-agent-writer>",
			{ approvedGrants: ["session.write"] },
		);
		const runner = new ExtensionRunner([extension], runtime, tempDir, sessionManager, modelRegistry);
		bindRunnerCore(runner, sessionManager, sentMessages);

		await runner.emit({ type: "session_start", reason: "startup" });

		expect(denied).toHaveLength(3);
		expect(denied).toEqual([
			expect.stringContaining("reserved sub-agent substrate name"),
			expect.stringContaining("reserved sub-agent substrate name"),
			expect.stringContaining("reserved sub-agent substrate name"),
		]);
		expect(sentMessages).toEqual([]);
		expect(sessionManager.getEntries().filter((entry) => entry.type === "custom")).toHaveLength(0);
	});

	it("applies snapshotted effective policy grants and narrows request limits for delegation", async () => {
		let delegateCalls = 0;
		const observedLimits: Array<SubAgentDelegationInput["limits"]> = [];
		const runtime = createExtensionRuntime();
		const extension = await loadExtensionFromFactory(
			createSubAgentExtension({
				delegate: (invocation) => {
					delegateCalls++;
					observedLimits.push(invocation.limits);
					return completedResultFor(invocation, "line one\nline two", { startedAt: 10, completedAt: 20 });
				},
			}),
			tempDir,
			createEventBus(),
			runtime,
			"<sub-agent-extension>",
		);
		extension.effectivePolicy = {
			approvedGrants: ["agent.delegate"],
			resourceLimits: { turns: 1, outputBytes: 1024, outputLines: 1, toolScopes: ["read"] },
		};
		const runner = new ExtensionRunner([extension], runtime, tempDir, sessionManager, modelRegistry);
		bindRunnerCore(runner, sessionManager);
		const tool = runner.getToolDefinition("sub_agent.delegate");
		expect(tool).toBeDefined();

		const allowed = await tool!.execute(
			"tool-call-policy-allowed",
			{
				...delegateInput,
				taskId: "task-policy-allowed",
				limits: { turns: 5, outputBytes: 2048, outputLines: 5, toolScopes: ["read", "write"] },
			},
			undefined,
			undefined,
			runner.createContext(),
		);
		const allowedEnvelope = JSON.parse(textFromToolResult(allowed)) as Record<string, unknown>;

		expect(delegateCalls).toBe(1);
		expect(observedLimits).toEqual([{ turns: 1, outputBytes: 1024, outputLines: 1, toolScopes: ["read"] }]);
		expect(allowedEnvelope).toMatchObject({
			status: "completed",
			content: [{ type: "text", text: "line one" }],
			resourceSummary: {
				turns: 1,
				outputLines: 1,
				limitDetails: {
					turns: { limit: 1, actual: 1, truncated: false },
					outputLines: { limit: 1, actual: 2, truncated: true },
					toolScopes: ["read"],
				},
			},
		});

		const deniedByRequestLimit = await tool!.execute(
			"tool-call-policy-request-limit",
			{
				...delegateInput,
				taskId: "task-policy-request-limit",
				limits: { turns: 0, toolScopes: ["read"] },
			},
			undefined,
			undefined,
			runner.createContext(),
		);
		const deniedEnvelope = JSON.parse(textFromToolResult(deniedByRequestLimit)) as Record<string, unknown>;

		expect(delegateCalls).toBe(1);
		expect(deniedEnvelope).toMatchObject({
			status: "failed",
			error: {
				reason: "resource_limit_exceeded",
				message: "resource limit exceeded: turns",
				details: {
					category: "resource_limit_exceeded",
					capability: "agent.delegate",
					operation: "agent.delegate",
					branch: "agent.delegate",
					phase: "call",
					mode: "typescript/sub-agent-execution",
					reason: "resource limit exceeded: turns",
					principal: {
						runtimeKind: "typescript",
						extensionId: extension.identity.key,
					},
					target: { id: "sub_agent.delegate" },
					extensionIdentity: extension.identity.key,
					limit: "turns",
				},
			},
			details: {
				category: "resource_limit_exceeded",
				capability: "agent.delegate",
				operation: "agent.delegate",
				branch: "agent.delegate",
				phase: "call",
				mode: "typescript/sub-agent-execution",
				reason: "resource limit exceeded: turns",
				extensionIdentity: extension.identity.key,
				limit: "turns",
			},
			resourceSummary: { turns: 0, childrenStarted: 0 },
		});
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

	it("emits read-only readiness observations for recorded and replayed delegation records", async () => {
		let delegateCalls = 0;
		const observed: Array<{
			observer: string;
			type: string;
			taskId: string;
			phase: string;
			owner: string;
			readOnly: true;
		}> = [];
		const runtime = createExtensionRuntime();
		const observerOne = await loadExtensionFromFactory(
			(pi) => {
				pi.on("sub_agent_readiness", (event) => {
					observed.push({
						observer: "one",
						type: event.envelope.type,
						taskId: event.envelope.taskId,
						phase: event.phase,
						owner: event.owner,
						readOnly: event.readOnly,
					});
					return { cancel: true, spawnPolicy: { automatic: true } } as unknown as undefined;
				});
			},
			tempDir,
			createEventBus(),
			runtime,
			"<readiness-observer-one>",
		);
		const observerTwo = await loadExtensionFromFactory(
			(pi) => {
				pi.on("sub_agent_readiness", (event) => {
					observed.push({
						observer: "two",
						type: event.envelope.type,
						taskId: event.envelope.taskId,
						phase: event.phase,
						owner: event.owner,
						readOnly: event.readOnly,
					});
				});
			},
			tempDir,
			createEventBus(),
			runtime,
			"<readiness-observer-two>",
		);
		const subAgent = await loadExtensionFromFactory(
			createSubAgentExtension({
				approvedCapabilities: ["agent.delegate"],
				delegate: (invocation) => {
					delegateCalls++;
					return completedResultFor(invocation, "observed delegation", { startedAt: 30, completedAt: 40 });
				},
			}),
			tempDir,
			createEventBus(),
			runtime,
			"<sub-agent-extension>",
		);
		const runner = new ExtensionRunner(
			[observerOne, observerTwo, subAgent],
			runtime,
			tempDir,
			sessionManager,
			modelRegistry,
		);
		bindRunnerCore(runner, sessionManager);
		const tool = runner.getToolDefinition("sub_agent.delegate");
		expect(tool).toBeDefined();

		const first = await tool!.execute(
			"tool-call-observed",
			{ ...delegateInput, taskId: "task-observed" },
			undefined,
			undefined,
			runner.createContext(),
		);
		const replay = await tool!.execute(
			"tool-call-observed-replay",
			{ ...delegateInput, taskId: "task-observed" },
			undefined,
			undefined,
			runner.createContext(),
		);
		const firstEnvelope = JSON.parse(textFromToolResult(first)) as Record<string, unknown>;
		const replayEnvelope = JSON.parse(textFromToolResult(replay)) as Record<string, unknown>;

		expect(delegateCalls).toBe(1);
		expect(replayEnvelope).toEqual(firstEnvelope);
		expect(sessionManager.getEntries().filter((entry) => entry.type === "custom")).toHaveLength(2);
		expect(observed).toEqual([
			{
				observer: "one",
				type: "sub_agent_task_invocation",
				taskId: "task-observed",
				phase: "recorded",
				owner: "agent",
				readOnly: true,
			},
			{
				observer: "two",
				type: "sub_agent_task_invocation",
				taskId: "task-observed",
				phase: "recorded",
				owner: "agent",
				readOnly: true,
			},
			{
				observer: "one",
				type: "sub_agent_task_result",
				taskId: "task-observed",
				phase: "recorded",
				owner: "agent",
				readOnly: true,
			},
			{
				observer: "two",
				type: "sub_agent_task_result",
				taskId: "task-observed",
				phase: "recorded",
				owner: "agent",
				readOnly: true,
			},
			{
				observer: "one",
				type: "sub_agent_task_result",
				taskId: "task-observed",
				phase: "replayed",
				owner: "agent",
				readOnly: true,
			},
			{
				observer: "two",
				type: "sub_agent_task_result",
				taskId: "task-observed",
				phase: "replayed",
				owner: "agent",
				readOnly: true,
			},
		]);
	});

	it("composes final substrate validation with isolated lifecycle, policy, schema, diagnostics, and sub-agent ownership", async () => {
		const runtime = createExtensionRuntime();
		const badExtensionBase = path.join(tempDir, "bad-extension");
		const goodExtensionBase = path.join(tempDir, "good-extension");
		const externalSkillDir = path.join(tempDir, "external-skill");
		const goodSkillDir = path.join(goodExtensionBase, "skills", "final-substrate");
		fs.mkdirSync(badExtensionBase, { recursive: true });
		fs.mkdirSync(goodSkillDir, { recursive: true });
		fs.mkdirSync(externalSkillDir, { recursive: true });
		fs.writeFileSync(
			path.join(goodSkillDir, "SKILL.md"),
			"---\nname: final-substrate\ndescription: Final substrate validation fixture\n---\nCLI-only fixture.",
		);

		await expect(
			loadExtensionFromFactory(
				(pi) => {
					pi.registerCommand(SUB_AGENT_DELEGATION_COMMAND, {
						description: "spoofed sub-agent command",
						handler: async () => {},
					});
				},
				tempDir,
				createEventBus(),
				runtime,
				path.join(tempDir, "spoofed-sub-agent.ts"),
			),
		).rejects.toThrow("reserved sub-agent substrate name");

		const deniedOperations: string[] = [];
		const lifecycleEvents: string[] = [];
		const badExtensionPath = path.join(badExtensionBase, "entry.ts");
		const goodExtensionPath = path.join(goodExtensionBase, "entry.ts");
		const badExtension = await loadExtensionFromFactory(
			(pi) => {
				pi.on("session_start", (event) => {
					lifecycleEvents.push(`bad:start:${event.reason}`);
					for (const attempt of [
						() => pi.sendUserMessage("must not enqueue"),
						() => pi.appendEntry("unrelated.final", { sideEffect: true }),
						() => pi.setActiveTools(["write"]),
					]) {
						try {
							attempt();
						} catch (error) {
							deniedOperations.push(error instanceof Error ? error.message : String(error));
						}
					}
				});
				pi.on("resources_discover", (event) => {
					lifecycleEvents.push(`bad:resources:${event.reason}`);
					return { skillPaths: [externalSkillDir] };
				});
				pi.on(
					"input",
					() => ({ action: "transform", text: 42 }) as unknown as { action: "transform"; text: string },
				);
			},
			tempDir,
			createEventBus(),
			runtime,
			badExtensionPath,
		);
		const goodExtension = await loadExtensionFromFactory(
			(pi) => {
				pi.on("session_start", (event) => {
					lifecycleEvents.push(`good:start:${event.reason}`);
				});
				pi.on("resources_discover", (event) => {
					lifecycleEvents.push(`good:resources:${event.reason}`);
					return { skillPaths: [goodSkillDir] };
				});
				pi.on("input", () => ({ action: "transform", text: "good-input" }));
			},
			tempDir,
			createEventBus(),
			runtime,
			goodExtensionPath,
		);

		let delegateCalls = 0;
		const subAgentExtension = await loadExtensionFromFactory(
			createSubAgentExtension({
				delegate: (invocation) => {
					delegateCalls++;
					return completedResultFor(invocation, "final integration delegated", { startedAt: 77, completedAt: 88 });
				},
			}),
			tempDir,
			createEventBus(),
			runtime,
			path.join(tempDir, "sub-agent-extension.ts"),
		);
		subAgentExtension.effectivePolicy = {
			approvedGrants: ["agent.delegate"],
			resourceLimits: { turns: 1, outputBytes: 128, outputLines: 2, toolScopes: ["read"] },
		};

		const sentMessages: unknown[] = [];
		const runner = new ExtensionRunner(
			[badExtension, goodExtension, subAgentExtension],
			runtime,
			tempDir,
			sessionManager,
			modelRegistry,
		);
		bindRunnerCore(runner, sessionManager, sentMessages);
		const errors: ExtensionError[] = [];
		runner.onError((error) => errors.push(error));

		await runner.emit({ type: "session_start", reason: "startup" });
		const discovered = await runner.emitResourcesDiscover(tempDir, "startup");
		const inputResult = await runner.emitInput("original", undefined, "rpc");
		const tool = runner.getToolDefinition(SUB_AGENT_DELEGATION_TOOL);
		expect(tool).toBeDefined();

		await expect(
			tool!.execute(
				"tool-call-product-schema",
				{
					...delegateInput,
					taskId: "task-product-schema",
					metadata: { workflowPreset: "review" },
				} as SubAgentDelegationInput,
				undefined,
				undefined,
				runner.createContext(),
			),
		).rejects.toThrow("$.metadata.workflowPreset: product UX/spawn policy is not allowed");
		const validDelegation = await tool!.execute(
			"tool-call-final-compose",
			{ ...delegateInput, taskId: "task-final-compose" },
			undefined,
			undefined,
			runner.createContext(),
		);
		const validEnvelope = JSON.parse(textFromToolResult(validDelegation)) as Record<string, unknown>;

		expect(lifecycleEvents).toEqual([
			"bad:start:startup",
			"good:start:startup",
			"bad:resources:startup",
			"good:resources:startup",
		]);
		expect(deniedOperations).toEqual([
			expect.stringContaining("lacks capability session.write for send_user_message"),
			expect.stringContaining("lacks capability session.write for append_entry"),
			expect.stringContaining("lacks capability tool.use for set_active_tools"),
		]);
		expect(discovered.skillPaths).toEqual([
			expect.objectContaining({
				path: goodSkillDir,
				extensionPath: goodExtension.path,
				metadata: expect.objectContaining({
					source: "extension:entry",
					scope: "temporary",
					origin: "top-level",
					baseDir: goodExtensionBase,
				}),
			}),
		]);
		expect(inputResult).toEqual({ action: "transform", text: "good-input", images: undefined });
		expect(delegateCalls).toBe(1);
		expect(validEnvelope).toMatchObject({
			type: "sub_agent_task_result",
			taskId: "task-final-compose",
			status: "completed",
			content: [{ type: "text", text: "final integration delegated" }],
			resourceSummary: {
				turns: 1,
				childrenStarted: 1,
				limitDetails: { toolScopes: ["read"] },
			},
		});
		expect(sentMessages).toEqual([]);
		expect(runner.hasUI()).toBe(false);
		expect(
			JSON.stringify(
				runner.getRegisteredCommands().find((command) => command.name === SUB_AGENT_DELEGATION_COMMAND),
			),
		).not.toMatch(/Workflow|Wiki|QA|Review|preset/i);
		expect(
			sessionManager
				.getEntries()
				.filter((entry) => entry.type === "custom")
				.map((entry) => entry.customType),
		).toEqual([SUB_AGENT_READINESS_ENTRY, SUB_AGENT_DELEGATION_RESULT_ENTRY]);
		expect(JSON.stringify(validEnvelope)).not.toMatch(/Workflow|Wiki|QA|Review|preset/i);

		const resourceDenial = errors.find((error) => error.event === "resources_discover");
		expect(resourceDenial).toMatchObject({
			extensionPath: badExtension.path,
			category: "denied_capability",
			capability: "file.read",
			operation: "resources_discover",
			extensionIdentity: badExtension.identity.key,
			envelope: {
				phase: "call",
				runtimeKind: "typescript",
				category: "denied_capability",
				extensionIdentity: badExtension.identity.key,
				capability: "file.read",
				operation: "resources_discover",
			},
		});
		const inputSchemaError = errors.find((error) => error.event === "input");
		expect(inputSchemaError).toMatchObject({
			extensionPath: badExtension.path,
			extensionIdentity: badExtension.identity.key,
			envelope: {
				phase: "event",
				runtimeKind: "typescript",
				category: "extension_runtime_error",
				extensionIdentity: badExtension.identity.key,
				event: "input",
				source: { path: badExtension.path },
			},
		});
		expect(JSON.stringify(errors)).not.toContain("must not enqueue");
	});

	it("uses the exact four-field replay key and preserves lineage, usage, timestamps, and resources", async () => {
		let delegateCalls = 0;
		const runtime = createExtensionRuntime();
		const extension = await loadExtensionFromFactory(
			createSubAgentExtension({
				approvedCapabilities: ["agent.delegate"],
				delegate: (invocation) => {
					delegateCalls++;
					return completedResultFor(
						{
							...delegateInput,
							taskId: invocation.taskId,
							sessionId: invocation.sessionId,
							toolCallId: invocation.toolCallId,
							parentRunId: invocation.parentRunId,
							parentTaskId: invocation.parentTaskId,
							parentSessionId: invocation.parentSessionId,
							parentId: invocation.parentId,
						},
						`executed:${invocation.taskId}:${delegateCalls}`,
						{ startedAt: 101, completedAt: 202 },
					);
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

		const lineageInput = {
			...delegateInput,
			toolCallId: "tool-call-first",
			parentRunId: "parent-run-first",
			parentTaskId: "parent-task-first",
			parentSessionId: "parent-session-first",
			parentId: "parent-entry-first",
		};
		const first = await tool!.execute("tool-call-first", lineageInput, undefined, undefined, runner.createContext());
		const firstEnvelope = JSON.parse(textFromToolResult(first)) as Record<string, unknown>;

		const replayWithChangedNonKeyFields = await tool!.execute(
			"tool-call-replay-non-key",
			{
				...lineageInput,
				toolCallId: "tool-call-changed",
				parentRunId: "parent-run-changed",
				parentTaskId: "parent-task-changed",
				parentSessionId: "parent-session-changed",
				parentId: "parent-entry-changed",
				route: "changed-route",
				input: { prompt: "changed prompt" },
				limits: { ...delegateInput.limits, outputBytes: 128, outputLines: 2 },
				metadata: { source: "changed" },
			},
			undefined,
			undefined,
			runner.createContext(),
		);
		const replayEnvelope = JSON.parse(textFromToolResult(replayWithChangedNonKeyFields)) as Record<string, unknown>;

		const newTask = await tool!.execute(
			"tool-call-new-task",
			{ ...lineageInput, taskId: "task-neutral-new" },
			undefined,
			undefined,
			runner.createContext(),
		);
		const newTaskEnvelope = JSON.parse(textFromToolResult(newTask)) as Record<string, unknown>;

		expect(delegateCalls).toBe(2);
		expect(replayEnvelope).toEqual(firstEnvelope);
		expect(firstEnvelope).toMatchObject({
			toolCallId: "tool-call-first",
			parentRunId: "parent-run-first",
			parentTaskId: "parent-task-first",
			parentSessionId: "parent-session-first",
			parentId: "parent-entry-first",
			startedAt: 101,
			completedAt: 202,
			usage: { inputTokens: 11, outputTokens: 13, totalTokens: 24, toolCalls: 1 },
			resourceSummary: {
				turns: 1,
				childrenStarted: 1,
				limitDetails: { toolScopes: ["read"] },
			},
		});
		expect(newTaskEnvelope).toMatchObject({
			taskId: "task-neutral-new",
			content: [{ type: "text", text: "executed:task-neutral-new:2" }],
		});
	});

	it("skips malformed replay records and uses the latest valid matching result", async () => {
		let delegateCalls = 0;
		const runtime = createExtensionRuntime();
		const extension = await loadExtensionFromFactory(
			createSubAgentExtension({
				approvedCapabilities: ["agent.delegate"],
				delegate: () => {
					delegateCalls++;
					throw new Error("manual replay fixtures must not execute");
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

		const skipMalformedInput = { ...delegateInput, taskId: "task-skip-malformed" };
		const olderValid = completedResultFor(skipMalformedInput, "older valid", { startedAt: 1, completedAt: 2 });
		sessionManager.appendCustomEntry(SUB_AGENT_DELEGATION_RESULT_ENTRY, olderValid);
		sessionManager.appendCustomEntry(SUB_AGENT_DELEGATION_RESULT_ENTRY, {
			...olderValid,
			status: "not-a-valid-status",
			content: [{ type: "text", text: "malformed newest" }],
		});

		const replayAfterMalformed = await tool!.execute(
			"tool-call-skip-malformed",
			skipMalformedInput,
			undefined,
			undefined,
			runner.createContext(),
		);
		const replayAfterMalformedEnvelope = JSON.parse(textFromToolResult(replayAfterMalformed)) as Record<
			string,
			unknown
		>;

		const latestInput = { ...delegateInput, taskId: "task-latest-valid" };
		const oldDuplicate = completedResultFor(latestInput, "old duplicate", { startedAt: 3, completedAt: 4 });
		const latestDuplicate = completedResultFor(latestInput, "latest duplicate", { startedAt: 5, completedAt: 6 });
		sessionManager.appendCustomEntry(SUB_AGENT_DELEGATION_RESULT_ENTRY, oldDuplicate);
		sessionManager.appendCustomEntry(SUB_AGENT_DELEGATION_RESULT_ENTRY, latestDuplicate);

		const replayLatest = await tool!.execute(
			"tool-call-latest-valid",
			latestInput,
			undefined,
			undefined,
			runner.createContext(),
		);
		const replayLatestEnvelope = JSON.parse(textFromToolResult(replayLatest)) as Record<string, unknown>;

		expect(delegateCalls).toBe(0);
		expect(replayAfterMalformedEnvelope).toEqual(olderValid);
		expect(replayLatestEnvelope).toEqual(latestDuplicate);
	});

	it("replays after reopening a persisted session without appending duplicate records", async () => {
		const persistentDir = fs.mkdtempSync(path.join(os.tmpdir(), "pi-sub-agent-reopen-"));
		try {
			let delegateCalls = 0;
			const persistentSession = SessionManager.create(persistentDir, persistentDir);
			persistentSession.appendMessage({ role: "user", content: "start persisted session", timestamp: 1 });
			persistentSession.appendMessage({
				role: "assistant",
				content: [{ type: "text", text: "ready" }],
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
			const runtime = createExtensionRuntime();
			const extension = await loadExtensionFromFactory(
				createSubAgentExtension({
					approvedCapabilities: ["agent.delegate"],
					delegate: (invocation) => {
						delegateCalls++;
						return completedResultFor(
							{ ...delegateInput, taskId: invocation.taskId, sessionId: invocation.sessionId },
							"persisted replay",
							{ startedAt: 500, completedAt: 700 },
						);
					},
				}),
				persistentDir,
				createEventBus(),
				runtime,
				"<sub-agent-extension>",
			);
			const runner = new ExtensionRunner([extension], runtime, persistentDir, persistentSession, modelRegistry);
			bindRunnerCore(runner, persistentSession);
			const tool = runner.getToolDefinition("sub_agent.delegate");
			expect(tool).toBeDefined();

			const first = await tool!.execute(
				"tool-call-persist",
				{ ...delegateInput, taskId: "task-persisted-replay" },
				undefined,
				undefined,
				runner.createContext(),
			);
			const firstEnvelope = JSON.parse(textFromToolResult(first)) as Record<string, unknown>;
			const sessionFile = persistentSession.getSessionFile();
			if (sessionFile === undefined) throw new Error("missing persisted session file");

			const reopenedSession = SessionManager.open(sessionFile, persistentDir);
			const reopenedRuntime = createExtensionRuntime();
			const reopenedExtension = await loadExtensionFromFactory(
				createSubAgentExtension({
					approvedCapabilities: ["agent.delegate"],
					delegate: () => {
						delegateCalls++;
						throw new Error("reopened replay must not execute");
					},
				}),
				persistentDir,
				createEventBus(),
				reopenedRuntime,
				"<sub-agent-extension>",
			);
			const reopenedRunner = new ExtensionRunner(
				[reopenedExtension],
				reopenedRuntime,
				persistentDir,
				reopenedSession,
				modelRegistry,
			);
			bindRunnerCore(reopenedRunner, reopenedSession);
			const reopenedTool = reopenedRunner.getToolDefinition("sub_agent.delegate");
			expect(reopenedTool).toBeDefined();

			const customCountBeforeReplay = reopenedSession.getEntries().filter((entry) => entry.type === "custom").length;
			const replay = await reopenedTool!.execute(
				"tool-call-reopened-replay",
				{ ...delegateInput, taskId: "task-persisted-replay" },
				undefined,
				undefined,
				reopenedRunner.createContext(),
			);
			const replayEnvelope = JSON.parse(textFromToolResult(replay)) as Record<string, unknown>;
			const customEntries = reopenedSession.getEntries().filter((entry) => entry.type === "custom");
			const context = reopenedSession.buildSessionContext();

			expect(delegateCalls).toBe(1);
			expect(replayEnvelope).toEqual(firstEnvelope);
			expect(customEntries).toHaveLength(customCountBeforeReplay);
			expect(customEntries.map((entry) => entry.customType)).toEqual([
				SUB_AGENT_READINESS_ENTRY,
				SUB_AGENT_DELEGATION_RESULT_ENTRY,
			]);
			expect(JSON.stringify(context.messages)).not.toContain("sub_agent_task_invocation");
			expect(JSON.stringify(context.messages)).not.toContain("sub_agent_task_result");
		} finally {
			fs.rmSync(persistentDir, { recursive: true, force: true });
		}
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
		expect(sentMessages[0]).toMatchObject({
			customType: SUB_AGENT_STATUS_MESSAGE,
			content: "cancelled",
			details: { type: "sub_agent_task_result", status: "cancelled" },
		});
	});

	it("rejects invalid tool and command payloads before persistence, status messages, or delegation", async () => {
		let delegateCalls = 0;
		const runtime = createExtensionRuntime();
		const extension = await loadExtensionFromFactory(
			createSubAgentExtension({
				approvedCapabilities: ["agent.delegate"],
				delegate: async () => {
					delegateCalls++;
					throw new Error("invalid payload must not delegate");
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
		const tool = runner.getToolDefinition("sub_agent.delegate");
		const command = runner.getCommand("sub-agent");
		expect(tool).toBeDefined();
		expect(command).toBeDefined();

		await expect(
			tool!.execute(
				"tool-call-invalid-missing-agent",
				{ ...delegateInput, agentId: "" },
				undefined,
				undefined,
				runner.createContext(),
			),
		).rejects.toThrow("$.agentId: must not be empty");
		await expect(
			tool!.execute(
				"tool-call-invalid-product-field",
				{ ...delegateInput, ui: { preset: "workflow" } } as SubAgentDelegationInput,
				undefined,
				undefined,
				runner.createContext(),
			),
		).rejects.toThrow("$.ui: product UX/spawn policy is not allowed");
		await expect(command!.handler("{not-json", runner.createCommandContext())).rejects.toThrow();
		await expect(
			command!.handler(JSON.stringify({ ...delegateInput, taskId: "" }), runner.createCommandContext()),
		).rejects.toThrow("$.taskId: must not be empty");
		await expect(
			command!.handler(
				JSON.stringify({ ...delegateInput, spawnPolicy: { automatic: true } }),
				runner.createCommandContext(),
			),
		).rejects.toThrow("$.spawnPolicy: product UX/spawn policy is not allowed");

		expect(delegateCalls).toBe(0);
		expect(sentMessages).toHaveLength(0);
		expect(sessionManager.getEntries().filter((entry) => entry.type === "custom")).toHaveLength(0);
	});

	it("replays denied limit and cancellation results without child side effects", async () => {
		let delegateCalls = 0;
		const runtime = createExtensionRuntime();
		const extension = await loadExtensionFromFactory(
			createSubAgentExtension({
				approvedCapabilities: ["agent.delegate"],
				delegate: async () => {
					delegateCalls++;
					throw new Error("denied limit or cancelled delegation must not execute");
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

		const maxChildrenInput = {
			...delegateInput,
			taskId: "task-limit-replay",
			limits: { ...delegateInput.limits, maxChildren: 0 },
		};
		const firstLimit = await tool!.execute(
			"tool-call-limit",
			maxChildrenInput,
			undefined,
			undefined,
			runner.createContext(),
		);
		const replayLimit = await tool!.execute(
			"tool-call-limit-replay",
			maxChildrenInput,
			undefined,
			undefined,
			runner.createContext(),
		);
		const limitEnvelope = JSON.parse(textFromToolResult(firstLimit)) as Record<string, unknown>;
		const replayLimitEnvelope = JSON.parse(textFromToolResult(replayLimit)) as Record<string, unknown>;

		expect(delegateCalls).toBe(0);
		expect(replayLimitEnvelope).toEqual(limitEnvelope);
		expect(limitEnvelope).toMatchObject({
			status: "failed",
			error: { reason: "resource_limit_exceeded", message: "resource limit exceeded: maxChildren" },
			resourceSummary: { childrenStarted: 0 },
		});
		expect(sessionManager.getEntries().filter((entry) => entry.type === "custom")).toHaveLength(2);

		const cancelledInput = {
			...delegateInput,
			taskId: "task-cancel-replay",
			cancellation: { state: "requested" as const, reason: "cancel before execution" },
		};
		const firstCancelled = await tool!.execute(
			"tool-call-cancel",
			cancelledInput,
			undefined,
			undefined,
			runner.createContext(),
		);
		const replayCancelled = await tool!.execute(
			"tool-call-cancel-replay",
			cancelledInput,
			undefined,
			undefined,
			runner.createContext(),
		);
		const cancelledEnvelope = JSON.parse(textFromToolResult(firstCancelled)) as Record<string, unknown>;
		const replayCancelledEnvelope = JSON.parse(textFromToolResult(replayCancelled)) as Record<string, unknown>;

		expect(delegateCalls).toBe(0);
		expect(replayCancelledEnvelope).toEqual(cancelledEnvelope);
		expect(cancelledEnvelope).toMatchObject({
			status: "cancelled",
			error: { reason: "cancelled", message: "cancel before execution" },
			resourceSummary: { childrenStarted: 0 },
		});
		expect(sessionManager.getEntries().filter((entry) => entry.type === "custom")).toHaveLength(4);
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
		it("exposes resolved Wasm packages to runner-visible runtime surfaces", () => {
			const wasmExtension = {
				path: path.join(tempDir, "pi-extension.json"),
				enabled: true,
				metadata: {
					source: path.join(tempDir, "wasm-package"),
					scope: "user",
					origin: "package",
					baseDir: path.join(tempDir, "wasm-package"),
					provenance: {
						sourceIdentity: `local:${path.join(tempDir, "wasm-package")}`,
						packageRoot: path.join(tempDir, "wasm-package"),
						packageRootSha256: "a".repeat(64),
						artifactSha256: "b".repeat(64),
					},
				},
				identity: {
					kind: "wasm-manifest",
					runtimeKind: "wasm",
					key: `wasm:package:pi-extension.v0:com.example.runner-wasm:0.1.0:user:local:${path.join(
						tempDir,
						"wasm-package",
					)}:${path.join(tempDir, "wasm-package")}:${"a".repeat(64)}:${"b".repeat(64)}:${path.join(
						tempDir,
						"pi-extension.json",
					)}:${path.join(tempDir, "wasm", "plugin.wasm")}`,
					displayName: "com.example.runner-wasm",
					schemaVersion: "pi-extension.v0",
					manifestId: "com.example.runner-wasm",
					name: "Runner Wasm",
					version: "0.1.0",
					manifestPath: path.join(tempDir, "pi-extension.json"),
					packageRoot: path.join(tempDir, "wasm-package"),
					artifactPath: "wasm/plugin.wasm",
					artifactAbsolutePath: path.join(tempDir, "wasm", "plugin.wasm"),
					artifactSha256: "b".repeat(64),
					toolId: "fixture.runnerWasm",
					sourceInfo: {
						path: path.join(tempDir, "pi-extension.json"),
						source: path.join(tempDir, "wasm-package"),
						scope: "user",
						origin: "package",
						baseDir: path.join(tempDir, "wasm-package"),
					},
				},
				effectivePolicy: {
					resourceLimits: { turns: 2, toolScopes: ["fixture.runnerWasm"] },
				},
			} as unknown as ResolvedWasmExtensionPackage;
			const runner = new ExtensionRunner([], createExtensionRuntime(), tempDir, sessionManager, modelRegistry, [
				wasmExtension,
			]);

			expect(runner.getWasmExtensions()).toEqual([wasmExtension]);
			expect(runner.getWasmExtensions()).not.toBe(runner.getWasmExtensions());
		});

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
		it("exposes read-only session and model registry facades to extension handlers", async () => {
			const runtime = createExtensionRuntime();
			const mutations: string[] = [];
			const extension = await loadExtensionFromFactory(
				(pi) => {
					pi.on("session_start", (_event, ctx) => {
						try {
							(
								ctx.sessionManager as ReadonlySessionManager & {
									appendCustomEntry(customType: string, data?: unknown): string;
								}
							).appendCustomEntry("forbidden", { mutated: true });
						} catch (error) {
							mutations.push(error instanceof Error ? error.message : String(error));
						}
						try {
							ctx.modelRegistry.registerProvider("facade-bypass", providerModelConfig);
						} catch (error) {
							mutations.push(error instanceof Error ? error.message : String(error));
						}
					});
				},
				tempDir,
				createEventBus(),
				runtime,
				"<read-only-facades>",
			);
			const runner = new ExtensionRunner([extension], runtime, tempDir, sessionManager, modelRegistry);

			await runner.emit({ type: "session_start", reason: "startup" });

			expect(mutations).toEqual([
				expect.stringContaining("read-only extension facade denied method appendCustomEntry"),
				expect.stringContaining("read-only extension facade denied method registerProvider"),
			]);
			expect(sessionManager.getEntries().filter((entry) => entry.type === "custom")).toHaveLength(0);
			expect(modelRegistry.find("facade-bypass", "instant-model")).toBeUndefined();
		});

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

		it("revokes extracted context host facades and ignores stale event-bus listeners", async () => {
			const eventBus = createEventBus();
			let capturedEvents: EventBus | undefined;
			let capturedUi: ExtensionUIContext | undefined;
			let capturedSessionManager: ReadonlySessionManager | undefined;
			let capturedModelRegistry: ModelRegistry | undefined;
			let observedBusEvents = 0;
			let statusValue: string | undefined;
			const runtime = createExtensionRuntime();
			const extension = await loadExtensionFromFactory(
				(pi) => {
					capturedEvents = pi.events;
					pi.events.on("extension:test", () => {
						observedBusEvents++;
					});
					pi.on("session_start", (_event, ctx) => {
						capturedUi = ctx.ui;
						capturedSessionManager = ctx.sessionManager;
						capturedModelRegistry = ctx.modelRegistry;
					});
				},
				tempDir,
				eventBus,
				runtime,
				"<revocable-facades>",
			);
			const runner = new ExtensionRunner([extension], runtime, tempDir, sessionManager, modelRegistry);
			const uiContext: ExtensionUIContext = {
				select: async () => undefined,
				confirm: async () => false,
				input: async () => undefined,
				notify: () => {},
				onTerminalInput: () => () => {},
				setStatus: (_key, text) => {
					statusValue = text;
				},
				setWorkingMessage: () => {},
				setWorkingVisible: () => {},
				setWorkingIndicator: () => {},
				setHiddenThinkingLabel: () => {},
				setWidget: () => {},
				setFooter: () => {},
				setHeader: () => {},
				setTitle: () => {},
				custom: async () => undefined as never,
				pasteToEditor: () => {},
				setEditorText: () => {},
				getEditorText: () => "",
				editor: async () => undefined,
				addAutocompleteProvider: () => {},
				setEditorComponent: () => {},
				getEditorComponent: () => undefined,
				get theme() {
					return {} as ExtensionUIContext["theme"];
				},
				getAllThemes: () => [],
				getTheme: () => undefined,
				setTheme: () => ({ success: false, error: "not available" }),
				getToolsExpanded: () => false,
				setToolsExpanded: () => {},
			};
			runner.setUIContext(uiContext);
			runner.bindCore(extensionActions, extensionContextActions);

			await runner.emit({ type: "session_start", reason: "startup" });
			capturedUi?.setStatus("owned", "active");
			capturedEvents?.emit("extension:test", {});
			expect(statusValue).toBe("active");
			expect(observedBusEvents).toBe(1);

			runner.invalidate("stale runtime");

			expect(() => capturedUi?.setStatus("owned", "stale")).toThrow("stale runtime");
			expect(() => capturedSessionManager?.getSessionFile()).toThrow("stale runtime");
			expect(() => capturedModelRegistry?.find("provider", "model")).toThrow("stale runtime");
			expect(() => capturedEvents?.emit("extension:test", {})).toThrow("stale runtime");
			eventBus.emit("extension:test", {});
			expect(statusValue).toBe("active");
			expect(observedBusEvents).toBe(1);
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
		it("constrains existing resource discovery paths to the extension base directory without file grants", async () => {
			const extensionBase = path.join(tempDir, "extension-base");
			const outsideBase = path.join(tempDir, "outside-base");
			fs.mkdirSync(path.join(extensionBase, "skills", "inside"), { recursive: true });
			fs.mkdirSync(path.join(outsideBase, "skills", "outside"), { recursive: true });
			fs.writeFileSync(
				path.join(extensionBase, "skills", "inside", "SKILL.md"),
				"---\nname: inside\ndescription: inside\n---\nInside",
			);
			fs.writeFileSync(
				path.join(outsideBase, "skills", "outside", "SKILL.md"),
				"---\nname: outside\ndescription: outside\n---\nOutside",
			);
			const extensionEntry = path.join(extensionBase, "extension.ts");
			fs.writeFileSync(
				extensionEntry,
				`
					export default function(pi) {
						pi.on("resources_discover", async () => ({
							skillPaths: [
								${JSON.stringify(path.join(extensionBase, "skills", "inside"))},
								${JSON.stringify(path.join(outsideBase, "skills", "outside"))},
							],
						}));
					}
				`,
			);

			const result = await discoverAndLoadExtensions([extensionEntry], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const errors: Array<{ event: string; error: string; capability?: string; operation?: string }> = [];
			runner.onError((error) => errors.push(error));

			const resources = await runner.emitResourcesDiscover(tempDir, "startup");

			expect(resources.skillPaths.map((resource) => resource.path)).toEqual([
				path.join(extensionBase, "skills", "inside"),
			]);
			expect(errors).toEqual([
				expect.objectContaining({
					event: "resources_discover",
					capability: "file.read",
					operation: "resources_discover",
					error: expect.stringContaining("capability file.read"),
				}),
			]);
		});

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
				{
					path: "/skills/one",
					extensionPath: path.join(extensionsDir, "resources-1.ts"),
					metadata: expect.objectContaining({ source: "extension:resources-1", scope: "temporary" }),
				},
			]);
			expect(resources.promptPaths).toEqual([
				{
					path: "/prompts/one",
					extensionPath: path.join(extensionsDir, "resources-1.ts"),
					metadata: expect.objectContaining({ source: "extension:resources-1", scope: "temporary" }),
				},
			]);
			expect(resources.themePaths).toEqual([
				{
					path: "/themes/three",
					extensionPath: path.join(extensionsDir, "resources-3.ts"),
					metadata: expect.objectContaining({ source: "extension:resources-3", scope: "temporary" }),
				},
			]);
		});

		it("times out lifecycle and resource handlers, aborts where supported, and ignores late results", async () => {
			const extCode1 = `
				export default function(pi) {
					pi.on("session_start", async (event) => {
						globalThis.lifecycleSignalWasProvided = event.signal instanceof AbortSignal;
						await new Promise((resolve) => event.signal.addEventListener("abort", resolve, { once: true }));
						globalThis.lifecycleAbortObserved = event.signal.aborted;
					});
					pi.on("resources_discover", async (event) => {
						globalThis.resourceSignalWasProvided = event.signal instanceof AbortSignal;
						await new Promise((resolve) => setTimeout(resolve, 25));
						globalThis.lateResourceResultResolved = true;
						return { skillPaths: ["/late-skill"] };
					});
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.on("session_start", async () => {
						globalThis.lifecycleSecondHandlerRan = true;
					});
					pi.on("resources_discover", async () => ({ promptPaths: ["/prompt-after-timeout"] }));
				}
			`;
			delete (globalThis as { lifecycleSignalWasProvided?: boolean }).lifecycleSignalWasProvided;
			delete (globalThis as { lifecycleAbortObserved?: boolean }).lifecycleAbortObserved;
			delete (globalThis as { lifecycleSecondHandlerRan?: boolean }).lifecycleSecondHandlerRan;
			delete (globalThis as { resourceSignalWasProvided?: boolean }).resourceSignalWasProvided;
			delete (globalThis as { lateResourceResultResolved?: boolean }).lateResourceResultResolved;
			fs.writeFileSync(path.join(extensionsDir, "timeout-1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "timeout-2.ts"), extCode2);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(
				result.extensions,
				result.runtime,
				tempDir,
				sessionManager,
				modelRegistry,
				[],
				{
					handlerTimeoutMs: 5,
				},
			);
			const errors: Array<{ event: string; error: string }> = [];
			runner.onError((error) => errors.push({ event: error.event, error: error.error }));

			await runner.emit({ type: "session_start", reason: "startup" });
			const resources = await runner.emitResourcesDiscover(tempDir, "startup");

			expect((globalThis as { lifecycleSignalWasProvided?: boolean }).lifecycleSignalWasProvided).toBe(true);
			expect((globalThis as { lifecycleAbortObserved?: boolean }).lifecycleAbortObserved).toBe(true);
			expect((globalThis as { lifecycleSecondHandlerRan?: boolean }).lifecycleSecondHandlerRan).toBe(true);
			expect((globalThis as { resourceSignalWasProvided?: boolean }).resourceSignalWasProvided).toBe(true);
			expect(resources).toEqual({
				skillPaths: [],
				promptPaths: [
					{
						path: "/prompt-after-timeout",
						extensionPath: path.join(extensionsDir, "timeout-2.ts"),
						metadata: expect.objectContaining({ source: "extension:timeout-2", scope: "temporary" }),
					},
				],
				themePaths: [],
			});
			expect(errors).toEqual([
				{ event: "session_start", error: "Extension handler timed out after 5ms" },
				{ event: "resources_discover", error: "Extension handler timed out after 5ms" },
			]);

			await new Promise((resolve) => setTimeout(resolve, 35));
			expect((globalThis as { lateResourceResultResolved?: boolean }).lateResourceResultResolved).toBe(true);
			expect(resources.skillPaths).toEqual([]);
		});

		it("isolates immutable lifecycle, context, provider, and input event payloads per handler", async () => {
			const extCode1 = `
				export default function(pi) {
					pi.on("session_start", async (event) => {
						event.reason = "mutated";
					});
					pi.on("context", async (event) => {
						event.messages.push({ role: "user", content: "mutated", timestamp: 2 });
					});
					pi.on("before_provider_request", async (event) => {
						event.payload.mutated = true;
					});
					pi.on("input", async (event) => {
						event.text = "mutated";
					});
				}
			`;
			const extCode2 = `
				export default function(pi) {
					pi.on("session_start", async (event) => {
						globalThis.observedLifecycleReason = event.reason;
					});
					pi.on("context", async (event) => ({
						messages: [...event.messages, { role: "user", content: String(event.messages.length), timestamp: 3 }],
					}));
					pi.on("before_provider_request", async (event) => ({
						...event.payload,
						observedMutated: Boolean(event.payload.mutated),
					}));
					pi.on("input", async (event) => ({
						action: "transform",
						text: event.text + ":observed",
					}));
				}
			`;
			delete (globalThis as { observedLifecycleReason?: string }).observedLifecycleReason;
			fs.writeFileSync(path.join(extensionsDir, "immutable-events-1.ts"), extCode1);
			fs.writeFileSync(path.join(extensionsDir, "immutable-events-2.ts"), extCode2);

			const result = await discoverAndLoadExtensions([], tempDir, tempDir);
			const runner = new ExtensionRunner(result.extensions, result.runtime, tempDir, sessionManager, modelRegistry);
			const message: AgentMessage = { role: "user", content: "base", timestamp: 1 };

			await runner.emit({ type: "session_start", reason: "startup" });
			const context = await runner.emitContext([message]);
			const providerPayload = await runner.emitBeforeProviderRequest({ base: true });
			const input = await runner.emitInput("base input", undefined, "interactive");

			expect((globalThis as { observedLifecycleReason?: string }).observedLifecycleReason).toBe("startup");
			expect(context.map((entry) => ("content" in entry ? entry.content : ""))).toEqual(["base", "1"]);
			expect(providerPayload).toEqual({ base: true, observedMutated: false });
			expect(input).toEqual({ action: "transform", text: "base input:observed", images: undefined });
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
		it("default-denies privileged TypeScript extension host APIs without exact grants", async () => {
			const runtime = createExtensionRuntime();
			const sideEffects = {
				messages: [] as unknown[],
				userMessages: [] as unknown[],
				entries: [] as unknown[],
				names: [] as string[],
				labels: [] as Array<{ entryId: string; label: string | undefined }>,
				activeTools: [] as string[][],
				models: [] as unknown[],
				thinkingLevels: [] as string[],
			};
			const denied: string[] = [];
			const extension = await loadExtensionFromFactory(
				(pi) => {
					pi.on("session_start", async () => {
						const attempts = [
							() => pi.sendMessage({ customType: "denied.message", content: "message", display: true }),
							() => pi.sendUserMessage("denied user"),
							() => pi.appendEntry("denied.entry", { value: true }),
							() => pi.setSessionName("denied-name"),
							() => pi.setLabel("entry-1", "denied-label"),
							() => pi.setActiveTools(["read"]),
							() => pi.setThinkingLevel("high"),
							() => pi.registerProvider("denied-provider", providerModelConfig),
							() => pi.unregisterProvider("denied-provider"),
							() => pi.exec(process.execPath, ["-e", "process.exit(0)"]),
						];
						for (const attempt of attempts) {
							try {
								await attempt();
							} catch (error) {
								denied.push(error instanceof Error ? error.message : String(error));
							}
						}
					});
				},
				tempDir,
				createEventBus(),
				runtime,
				"<policy-denied-host-apis>",
			);
			const runner = new ExtensionRunner([extension], runtime, tempDir, sessionManager, modelRegistry);
			runner.bindCore(
				{
					...extensionActions,
					sendMessage: (message) => sideEffects.messages.push(message),
					sendUserMessage: (content) => sideEffects.userMessages.push(content),
					appendEntry: (customType, data) => sideEffects.entries.push({ customType, data }),
					setSessionName: (name) => sideEffects.names.push(name),
					setLabel: (entryId, label) => sideEffects.labels.push({ entryId, label }),
					setActiveTools: (toolNames) => sideEffects.activeTools.push(toolNames),
					setModel: async (model) => {
						sideEffects.models.push(model);
						return true;
					},
					setThinkingLevel: (level) => sideEffects.thinkingLevels.push(level),
				},
				extensionContextActions,
			);

			await runner.emit({ type: "session_start", reason: "startup" });

			expect(sideEffects).toEqual({
				messages: [],
				userMessages: [],
				entries: [],
				names: [],
				labels: [],
				activeTools: [],
				models: [],
				thinkingLevels: [],
			});
			expect(modelRegistry.find("denied-provider", "instant-model")).toBeUndefined();
			expect(denied).toHaveLength(10);
			expect(denied).toEqual(
				expect.arrayContaining([
					expect.stringContaining("capability session.write"),
					expect.stringContaining("capability tool.use"),
					expect.stringContaining("capability model.call"),
					expect.stringContaining("capability shell.run"),
					expect.stringContaining(extension.identity.key),
				]),
			);
		});

		it("allows privileged TypeScript extension host APIs with exact grants", async () => {
			const runtime = createExtensionRuntime();
			const sideEffects = {
				messages: [] as unknown[],
				userMessages: [] as unknown[],
				entries: [] as unknown[],
				names: [] as string[],
				labels: [] as Array<{ entryId: string; label: string | undefined }>,
				activeTools: [] as string[][],
				thinkingLevels: [] as string[],
			};
			const extension = await loadExtensionFromFactory(
				(pi) => {
					pi.on("session_start", async () => {
						pi.sendMessage({ customType: "allowed.message", content: "message", display: true });
						pi.sendUserMessage("allowed user");
						pi.appendEntry("allowed.entry", { value: true });
						pi.setSessionName("allowed-name");
						pi.setLabel("entry-1", "allowed-label");
						pi.setActiveTools(["read"]);
						pi.setThinkingLevel("high");
						pi.registerProvider("allowed-provider", providerModelConfig);
						const execResult = await pi.exec(process.execPath, ["-e", "process.stdout.write('ok')"]);
						pi.appendEntry("allowed.exec", execResult.stdout);
					});
				},
				tempDir,
				createEventBus(),
				runtime,
				"<policy-allowed-host-apis>",
				{ approvedGrants: ["session.write", "tool.use", "model.call", "shell.run"] },
			);
			const runner = new ExtensionRunner([extension], runtime, tempDir, sessionManager, modelRegistry);
			runner.bindCore(
				{
					...extensionActions,
					sendMessage: (message) => sideEffects.messages.push(message),
					sendUserMessage: (content) => sideEffects.userMessages.push(content),
					appendEntry: (customType, data) => sideEffects.entries.push({ customType, data }),
					setSessionName: (name) => sideEffects.names.push(name),
					setLabel: (entryId, label) => sideEffects.labels.push({ entryId, label }),
					setActiveTools: (toolNames) => sideEffects.activeTools.push(toolNames),
					setThinkingLevel: (level) => sideEffects.thinkingLevels.push(level),
				},
				extensionContextActions,
			);

			await runner.emit({ type: "session_start", reason: "startup" });

			expect(sideEffects).toMatchObject({
				messages: [{ customType: "allowed.message", content: "message" }],
				userMessages: ["allowed user"],
				entries: [
					{ customType: "allowed.entry", data: { value: true } },
					{ customType: "allowed.exec", data: "ok" },
				],
				names: ["allowed-name"],
				labels: [{ entryId: "entry-1", label: "allowed-label" }],
				activeTools: [["read"]],
				thinkingLevels: ["high"],
			});
			expect(modelRegistry.find("allowed-provider", "instant-model")).toBeDefined();
		});

		it("unregisters extension-owned providers when the runner is invalidated", async () => {
			const runtime = createExtensionRuntime();
			const extension = await loadExtensionFromFactory(
				(pi) => {
					pi.registerProvider("owned-provider", providerModelConfig);
				},
				tempDir,
				createEventBus(),
				runtime,
				"<provider-owner>",
				{ approvedGrants: ["model.call"] },
			);
			const runner = new ExtensionRunner([extension], runtime, tempDir, sessionManager, modelRegistry);

			runner.bindCore(extensionActions, extensionContextActions);
			expect(modelRegistry.find("owned-provider", "instant-model")).toBeDefined();

			runner.invalidate("provider owner unloaded");

			expect(modelRegistry.find("owned-provider", "instant-model")).toBeUndefined();
		});

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
