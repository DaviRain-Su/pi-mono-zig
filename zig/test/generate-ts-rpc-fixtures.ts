import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { spawnSync } from "node:child_process";
import { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import type { AgentEvent, AgentMessage } from "@mariozechner/pi-agent-core";
import type { AssistantMessage, Model, ToolCall, ToolResultMessage } from "@mariozechner/pi-ai";
import type { AgentSessionEvent } from "../../packages/coding-agent/src/core/agent-session.js";
import type { AgentSessionRuntime } from "../../packages/coding-agent/src/core/agent-session-runtime.js";
import { runRpcMode } from "../../packages/coding-agent/src/modes/rpc/rpc-mode.js";
import { attachJsonlLineReader, serializeJsonLine } from "../../packages/coding-agent/src/modes/rpc/jsonl.js";
import type {
	RpcCommand,
	RpcExtensionUIResponse,
	RpcSessionState,
	RpcSlashCommand,
} from "../../packages/coding-agent/src/modes/rpc/rpc-types.js";

const scriptPath = fileURLToPath(import.meta.url);
const scriptDir = dirname(scriptPath);
const repoRoot = join(scriptDir, "..", "..");
const fixtureDir = join(scriptDir, "golden", "ts-rpc");
const checkMode = process.argv.includes("--check");
const runtimeChildArg = process.argv.find((arg) => arg.startsWith("--runtime-child="));

const sourceCitations = [
	"packages/coding-agent/src/modes/rpc/jsonl.ts:10-58",
	"packages/coding-agent/src/modes/rpc/rpc-mode.ts:53-70",
	"packages/coding-agent/src/modes/rpc/rpc-mode.ts:313-365",
	"packages/coding-agent/src/modes/rpc/rpc-mode.ts:369-704",
	"packages/coding-agent/src/modes/rpc/rpc-mode.ts:706-737",
	"packages/coding-agent/src/modes/rpc/rpc-types.ts:19-264",
	"packages/agent/src/types.ts:350-365",
	"packages/ai/src/types.ts:207-276",
];

const captureMethod = {
	responses: "spawn runRpcMode with a deterministic faux AgentSessionRuntime and capture child stdout bytes",
	framing: "feed LF, CRLF, invalid, and final unterminated stdin into runRpcMode and capture child stdout bytes",
	events: "emit deterministic faux AgentSession events through session.subscribe inside runRpcMode and capture child stdout bytes",
	extensionUi: "invoke the runRpcMode ExtensionUIContext from bindExtensions with deterministic crypto.randomUUID preload",
};

interface FixtureFile {
	path: string;
	description: string;
	bytes: string;
}

type RuntimeScenario =
	| "responses-basic"
	| "framing-lf"
	| "framing-crlf"
	| "framing-final"
	| "framing-parse"
	| "parse-error-corpus"
	| "events-base-stream"
	| "events-thinking-tool-usage"
	| "events-session-extras"
	| "prompt-concurrency-queue-order"
	| "extension-ui";

interface RuntimeCaptureOptions {
	input?: string;
}

function jsonl(records: readonly unknown[]): string {
	return records.map((record) => serializeJsonLine(record)).join("");
}

async function collectJsonlReaderLines(chunks: readonly (string | Buffer)[]): Promise<string[]> {
	const stream = Readable.from(chunks);
	const lines: string[] = [];
	const done = new Promise<void>((resolve) => {
		stream.on("end", resolve);
	});
	attachJsonlLineReader(stream, (line) => {
		lines.push(line);
	});
	await done;
	return lines;
}

function deterministicCryptoPreload(): string {
	const ids = [
		"ui_select",
		"ui_confirm",
		"ui_input",
		"ui_notify",
		"ui_status",
		"ui_widget",
		"ui_title",
		"ui_editor_text",
		"ui_editor",
		"ui_extra_1",
		"ui_extra_2",
	];
	const source = `import { createRequire } from "node:module";\nconst require = createRequire(process.cwd() + "/package.json");\nconst crypto = require("node:crypto");\nconst ids = ${JSON.stringify(ids)};\ncrypto.randomUUID = () => ids.shift() ?? "ui_extra";\n`;
	return `data:text/javascript,${encodeURIComponent(source)}`;
}

function captureRuntimeStdout(scenario: RuntimeScenario, options: RuntimeCaptureOptions = {}): string {
	const result = spawnSync(
		process.execPath,
		["--import", deterministicCryptoPreload(), "--import", "tsx", scriptPath, `--runtime-child=${scenario}`],
		{
			cwd: repoRoot,
			input: options.input ?? "",
			encoding: "utf8",
			env: { ...process.env, PI_TS_RPC_FIXTURE_CHILD: "1" },
			maxBuffer: 1024 * 1024 * 10,
		},
	);

	if (result.error) {
		throw result.error;
	}
	if (result.status !== 0) {
		throw new Error(
			`Runtime fixture capture failed for ${scenario} with exit ${result.status}\nSTDERR:\n${result.stderr}\nSTDOUT:\n${result.stdout}`,
		);
	}
	return result.stdout;
}

const usage = {
	input: 11,
	output: 22,
	cacheRead: 3,
	cacheWrite: 4,
	totalTokens: 40,
	cost: { input: 0.0011, output: 0.0044, cacheRead: 0.0003, cacheWrite: 0.0008, total: 0.0066 },
} satisfies AssistantMessage["usage"];

const model = {
	id: "claude-sonnet-4-5",
	name: "Claude Sonnet 4.5",
	api: "anthropic-messages",
	provider: "anthropic",
	baseUrl: "https://api.anthropic.com",
	reasoning: true,
	input: ["text", "image"],
	cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
	contextWindow: 200000,
	maxTokens: 64000,
	headers: { "x-pi-fixture": "ts-rpc-m0" },
} satisfies Model<"anthropic-messages">;

const userMessage = {
	role: "user",
	content: "Plan with deterministic fixtures",
	timestamp: 1766880000000,
} satisfies AgentMessage;

const userMessageWithImage = {
	role: "user",
	content: [
		{ type: "text", text: "Inspect this image" },
		{ type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" },
	],
	timestamp: 1766880000001,
} satisfies AgentMessage;

const assistantEmpty = {
	role: "assistant",
	content: [],
	api: "anthropic-messages",
	provider: "anthropic",
	model: "claude-sonnet-4-5",
	responseId: "resp_fixture_0001",
	usage,
	stopReason: "stop",
	timestamp: 1766880000002,
} satisfies AssistantMessage;

const assistantText = {
	...assistantEmpty,
	content: [{ type: "text", text: "Fixtures captured." }],
	timestamp: 1766880000003,
} satisfies AssistantMessage;

const assistantThinking = {
	...assistantEmpty,
	content: [
		{ type: "thinking", thinking: "Need exact field order.", thinkingSignature: "think_sig_1" },
		{ type: "text", text: "I will call the fixture tool." },
	],
	timestamp: 1766880000004,
} satisfies AssistantMessage;

const toolCall = {
	type: "toolCall",
	id: "toolu_fixture_1",
	name: "fixture_tool",
	arguments: { path: "zig/test/golden/ts-rpc", dryRun: false },
	thoughtSignature: "tool_thought_sig_1",
} satisfies ToolCall;

const assistantToolUse = {
	...assistantEmpty,
	content: [
		{ type: "thinking", thinking: "Use a tool.", thinkingSignature: "think_sig_2" },
		toolCall,
	],
	stopReason: "toolUse",
	timestamp: 1766880000005,
} satisfies AssistantMessage;

const assistantLength = {
	...assistantText,
	stopReason: "length",
	timestamp: 1766880000006,
} satisfies AssistantMessage;

const assistantAborted = {
	...assistantEmpty,
	content: [{ type: "text", text: "partial" }],
	stopReason: "aborted",
	errorMessage: "Aborted by user",
	timestamp: 1766880000007,
} satisfies AssistantMessage;

const toolResult = {
	role: "toolResult",
	toolCallId: "toolu_fixture_1",
	toolName: "fixture_tool",
	content: [{ type: "text", text: "wrote 6 fixtures" }],
	details: {
		exit_code: 0,
		timed_out: false,
		full_output_path: "/tmp/pi-ts-rpc-fixture-output.txt",
		truncation: { originalBytes: 2048, keptBytes: 1024 },
	},
	isError: false,
	timestamp: 1766880000008,
} satisfies ToolResultMessage;

const partialToolResult = {
	content: [{ type: "text", text: "writing..." }],
	details: { bytesWritten: 128 },
} as const;

const sessionState = {
	model,
	thinkingLevel: "high",
	isStreaming: false,
	isCompacting: false,
	steeringMode: "one-at-a-time",
	followUpMode: "all",
	sessionFile: "/tmp/pi-ts-rpc/session.jsonl",
	sessionId: "sess_fixture_1",
	sessionName: "fixture session",
	autoCompactionEnabled: true,
	messageCount: 3,
	pendingMessageCount: 2,
} satisfies RpcSessionState;

const framingSessionState = {
	...sessionState,
	sessionName: "fixture\u2028session\u2029name",
} satisfies RpcSessionState;

const slashCommand = {
	name: "fixture",
	description: "Run the deterministic fixture command",
	source: "extension",
	sourceInfo: {
		path: "/tmp/pi-ts-rpc/extensions/fixture",
		source: "fixture-extension",
		scope: "temporary",
		origin: "top-level",
	},
} satisfies RpcSlashCommand;

const commands = [
	{ id: "cmd_prompt", type: "prompt", message: "hello", images: [{ type: "image", data: "aW1n", mimeType: "image/png" }] },
	{ id: "cmd_steer", type: "steer", message: "steer now" },
	{ id: "cmd_follow", type: "follow_up", message: "follow later" },
	{ id: "cmd_abort", type: "abort" },
	{ id: "cmd_new", type: "new_session", parentSession: "/tmp/parent.jsonl" },
	{ id: "cmd_state", type: "get_state" },
	{ id: "cmd_set_model", type: "set_model", provider: "anthropic", modelId: "claude-sonnet-4-5" },
	{ id: "cmd_cycle_model", type: "cycle_model" },
	{ id: "cmd_models", type: "get_available_models" },
	{ id: "cmd_thinking", type: "set_thinking_level", level: "high" },
	{ id: "cmd_cycle_thinking", type: "cycle_thinking_level" },
	{ id: "cmd_steering_mode", type: "set_steering_mode", mode: "one-at-a-time" },
	{ id: "cmd_follow_mode", type: "set_follow_up_mode", mode: "all" },
	{ id: "cmd_compact", type: "compact", customInstructions: "preserve fixture notes" },
	{ id: "cmd_auto_compact", type: "set_auto_compaction", enabled: true },
	{ id: "cmd_auto_retry", type: "set_auto_retry", enabled: false },
	{ id: "cmd_abort_retry", type: "abort_retry" },
	{ id: "cmd_bash", type: "bash", command: "printf fixture" },
	{ id: "cmd_abort_bash", type: "abort_bash" },
	{ id: "cmd_stats", type: "get_session_stats" },
	{ id: "cmd_export", type: "export_html", outputPath: "/tmp/pi-ts-rpc/export.html" },
	{ id: "cmd_switch", type: "switch_session", sessionPath: "/tmp/pi-ts-rpc/other.jsonl" },
	{ id: "cmd_fork", type: "fork", entryId: "entry_fixture_1" },
	{ id: "cmd_clone", type: "clone" },
	{ id: "cmd_fork_messages", type: "get_fork_messages" },
	{ id: "cmd_last_text", type: "get_last_assistant_text" },
	{ id: "cmd_name", type: "set_session_name", name: "fixture session" },
	{ id: "cmd_messages", type: "get_messages" },
	{ id: "cmd_commands", type: "get_commands" },
] satisfies RpcCommand[];

const extensionUiResponses = [
	{ type: "extension_ui_response", id: "ui_select", value: "option-a" },
	{ type: "extension_ui_response", id: "ui_confirm", confirmed: true },
	{ type: "extension_ui_response", id: "ui_input", cancelled: true },
] satisfies RpcExtensionUIResponse[];

const responseScenarioInput = jsonl([
	{ id: "resp_prompt", type: "prompt", message: "accepted prompt" },
	{ type: "steer", message: "steer fixture" },
	{ id: "resp_state", type: "get_state" },
	{ type: "cycle_model" },
	{ id: "resp_models", type: "get_available_models" },
	{ id: "resp_compact", type: "compact", customInstructions: "preserve fixture notes" },
	{ id: "resp_bash", type: "bash", command: "printf fixture" },
	{ id: "resp_stats", type: "get_session_stats" },
	{ id: "resp_export", type: "export_html", outputPath: "/tmp/pi-ts-rpc/export.html" },
	{ id: "resp_fork", type: "fork", entryId: "entry_fixture_1" },
	{ id: "resp_messages", type: "get_messages" },
	{ id: "resp_commands", type: "get_commands" },
	{ id: "resp_set_model_error", type: "set_model", provider: "anthropic", modelId: "missing-model" },
	{ id: "resp_thrown", type: "bash", command: "throw" },
]) + "{not json\n" + serializeJsonLine({ id: "mystery", type: "mystery_command" });

const promptConcurrencyScenarioInput = jsonl([
	{ id: "pc_start", type: "prompt", message: "start slow" },
	{ id: "pc_abort", type: "abort" },
	{ id: "pc_steer", type: "steer", message: "steer while prompt running" },
	{ id: "pc_follow", type: "follow_up", message: "follow while prompt running" },
	{ id: "pc_prompt_steer", type: "prompt", message: "prompt as steer", streamingBehavior: "steer" },
	{ id: "pc_prompt_follow", type: "prompt", message: "prompt as follow", streamingBehavior: "followUp" },
] satisfies RpcCommand[]);

const parseErrorCorpus = [
	{ name: "empty", input: "" },
	{ name: "whitespace", input: "   \t" },
	{ name: "unterminated-object-open", input: "{" },
	{ name: "unterminated-object-value", input: '{"type":' },
	{ name: "unterminated-array-open", input: "[" },
	{ name: "unterminated-array-comma", input: "[1," },
	{ name: "unterminated-string", input: '"unterminated' },
	{ name: "invalid-literal", input: "not-json" },
	{ name: "invalid-literal-short", input: "tru" },
	{ name: "trailing-comma-object", input: '{"type":"get_state",}' },
	{ name: "trailing-comma-array", input: "[1,]" },
	{ name: "extra-tokens-after-primitive", input: "1 2" },
	{ name: "extra-tokens-after-object", input: "{} {}" },
	{ name: "extra-tokens-after-array", input: "[] []" },
	{ name: "missing-colon", input: '{"a" 1}' },
	{ name: "bad-property-name", input: "{foo:1}" },
	{ name: "invalid-value-token", input: '{"a":#}' },
	{ name: "malformed-unicode-escape", input: '"\\u12G4"' },
] as const;

function buildParseErrorCorpusFixtures(): { outputs: string; corpus: string } {
	const inputBytes = parseErrorCorpus.map((entry) => `${entry.input}\n`).join("");
	const outputs = captureRuntimeStdout("parse-error-corpus", { input: inputBytes });
	const outputLines = outputs.split("\n").filter((line) => line.length > 0);
	if (outputLines.length !== parseErrorCorpus.length) {
		throw new Error(`Expected ${parseErrorCorpus.length} parse-error outputs, got ${outputLines.length}`);
	}
	return {
		outputs,
		corpus: jsonl(parseErrorCorpus.map((entry, index) => ({ ...entry, output: `${outputLines[index]}\n` }))),
	};
}

function emitBaseStreamScenario(emit: (event: AgentSessionEvent) => void): void {
	emit({ type: "agent_start" } satisfies AgentEvent);
	emit({ type: "turn_start" } satisfies AgentEvent);
	emit({ type: "message_start", message: userMessage } satisfies AgentEvent);
	emit({ type: "message_end", message: userMessage } satisfies AgentEvent);
	emit({ type: "message_start", message: assistantEmpty } satisfies AgentEvent);
	emit({
		type: "message_update",
		message: assistantEmpty,
		assistantMessageEvent: { type: "start", partial: assistantEmpty },
	} satisfies AgentEvent);
	emit({
		type: "message_update",
		message: assistantText,
		assistantMessageEvent: { type: "text_start", contentIndex: 0, partial: assistantEmpty },
	} satisfies AgentEvent);
	emit({
		type: "message_update",
		message: assistantText,
		assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "Fixtures", partial: assistantText },
	} satisfies AgentEvent);
	emit({
		type: "message_update",
		message: assistantText,
		assistantMessageEvent: { type: "text_end", contentIndex: 0, content: "Fixtures captured.", partial: assistantText },
	} satisfies AgentEvent);
	emit({
		type: "message_update",
		message: assistantText,
		assistantMessageEvent: { type: "done", reason: "stop", message: assistantText },
	} satisfies AgentEvent);
	emit({ type: "message_end", message: assistantText } satisfies AgentEvent);
	emit({ type: "turn_end", message: assistantText, toolResults: [] } satisfies AgentEvent);
	emit({ type: "agent_end", messages: [userMessage, assistantText] } satisfies AgentEvent);
}

function emitThinkingToolUsageScenario(emit: (event: AgentSessionEvent) => void): void {
	emit({ type: "message_start", message: userMessageWithImage } satisfies AgentEvent);
	emit({
		type: "message_update",
		message: assistantThinking,
		assistantMessageEvent: { type: "thinking_start", contentIndex: 0, partial: assistantEmpty },
	} satisfies AgentEvent);
	emit({
		type: "message_update",
		message: assistantThinking,
		assistantMessageEvent: { type: "thinking_delta", contentIndex: 0, delta: "Need exact", partial: assistantThinking },
	} satisfies AgentEvent);
	emit({
		type: "message_update",
		message: assistantThinking,
		assistantMessageEvent: {
			type: "thinking_end",
			contentIndex: 0,
			content: "Need exact field order.",
			partial: assistantThinking,
		},
	} satisfies AgentEvent);
	emit({
		type: "message_update",
		message: assistantToolUse,
		assistantMessageEvent: { type: "toolcall_start", contentIndex: 1, partial: assistantThinking },
	} satisfies AgentEvent);
	emit({
		type: "message_update",
		message: assistantToolUse,
		assistantMessageEvent: {
			type: "toolcall_delta",
			contentIndex: 1,
			delta: "{\"path\":\"zig/test/golden/ts-rpc\"}",
			partial: assistantToolUse,
		},
	} satisfies AgentEvent);
	emit({
		type: "message_update",
		message: assistantToolUse,
		assistantMessageEvent: { type: "toolcall_end", contentIndex: 1, toolCall, partial: assistantToolUse },
	} satisfies AgentEvent);
	emit({
		type: "message_update",
		message: assistantToolUse,
		assistantMessageEvent: { type: "done", reason: "toolUse", message: assistantToolUse },
	} satisfies AgentEvent);
	emit({ type: "tool_execution_start", toolCallId: "toolu_fixture_1", toolName: "fixture_tool", args: toolCall.arguments } satisfies AgentEvent);
	emit({
		type: "tool_execution_update",
		toolCallId: "toolu_fixture_1",
		toolName: "fixture_tool",
		args: toolCall.arguments,
		partialResult: partialToolResult,
	} satisfies AgentEvent);
	emit({
		type: "tool_execution_end",
		toolCallId: "toolu_fixture_1",
		toolName: "fixture_tool",
		result: toolResult,
		isError: false,
	} satisfies AgentEvent);
	emit({ type: "message_end", message: toolResult } satisfies AgentEvent);
	emit({ type: "turn_end", message: assistantToolUse, toolResults: [toolResult] } satisfies AgentEvent);
	emit({
		type: "message_update",
		message: assistantLength,
		assistantMessageEvent: { type: "done", reason: "length", message: assistantLength },
	} satisfies AgentEvent);
	emit({
		type: "message_update",
		message: assistantAborted,
		assistantMessageEvent: { type: "error", reason: "aborted", error: assistantAborted },
	} satisfies AgentEvent);
}

function emitSessionExtrasScenario(emit: (event: AgentSessionEvent) => void): void {
	emit({ type: "queue_update", steering: ["steer one"], followUp: ["follow one", "follow two"] });
	emit({ type: "compaction_start", reason: "manual" });
	emit({ type: "session_info_changed", name: "fixture session" });
	emit({
		type: "compaction_end",
		reason: "manual",
		result: {
			summary: "Compacted fixture history.",
			firstKeptEntryId: "entry_fixture_2",
			tokensBefore: 1234,
			details: { strategy: "faux" },
		},
		aborted: false,
		willRetry: false,
	});
	emit({ type: "auto_retry_start", attempt: 1, maxAttempts: 3, delayMs: 250, errorMessage: "transient fixture error" });
	emit({ type: "auto_retry_end", success: false, attempt: 3, finalError: "fixture retry exhausted" });
}

interface FixtureUiContext {
	select(title: string, options: string[], opts?: { timeout?: number }): Promise<string | undefined>;
	confirm(title: string, message: string, opts?: { timeout?: number }): Promise<boolean>;
	input(title: string, placeholder?: string, opts?: { timeout?: number }): Promise<string | undefined>;
	editor(title: string, prefill?: string): Promise<string | undefined>;
	notify(message: string, type?: "info" | "warning" | "error"): void;
	setStatus(key: string, text: string | undefined): void;
	setWidget(key: string, content: string[] | undefined, options?: { placement?: "aboveEditor" | "belowEditor" }): void;
	setTitle(title: string): void;
	setEditorText(text: string): void;
}

interface BindExtensionsOptions {
	uiContext: FixtureUiContext;
}

class FixtureSession {
	readonly scenario: RuntimeScenario;
	readonly agent = { waitForIdle: async () => {} };
	readonly sessionManager = { getLeafId: () => "entry_fixture_1" };
	readonly modelRegistry = {
		getAvailable: async () => [model],
	};
	readonly extensionRunner = {
		getRegisteredCommands: () => [
			{
				invocationName: slashCommand.name,
				description: slashCommand.description,
				sourceInfo: slashCommand.sourceInfo,
			},
		],
	};
	readonly promptTemplates: RpcSlashCommand[] = [];
	readonly resourceLoader = { getSkills: () => ({ skills: [] }) };
	readonly model = model;
	readonly thinkingLevel = "high";
	readonly isStreaming = false;
	readonly isCompacting = false;
	readonly steeringMode = "one-at-a-time";
	readonly followUpMode = "all";
	readonly sessionFile = "/tmp/pi-ts-rpc/session.jsonl";
	readonly sessionId = "sess_fixture_1";
	readonly sessionName: string;
	readonly autoCompactionEnabled = true;
	readonly messages = [userMessage, assistantText, toolResult];
	readonly pendingMessageCount = 2;
	private listeners: Array<(event: AgentSessionEvent) => void> = [];
	private steeringMessages: string[] = [];
	private followUpMessages: string[] = [];

	constructor(scenario: RuntimeScenario) {
		this.scenario = scenario;
		this.sessionName = scenario.startsWith("framing") ? framingSessionState.sessionName : sessionState.sessionName;
	}

	async bindExtensions(options: BindExtensionsOptions): Promise<void> {
		if (this.scenario !== "extension-ui") return;
		void options.uiContext.select("Choose fixture", ["option-a", "option-b"], { timeout: 1000 });
		void options.uiContext.confirm("Confirm fixture", "Proceed?", { timeout: 1000 });
		void options.uiContext.input("Fixture input", "value", { timeout: 1000 });
		options.uiContext.notify("Fixture notice", "info");
		options.uiContext.setStatus("fixture", "ready");
		options.uiContext.setWidget("fixture", ["line one", "line two"], { placement: "aboveEditor" });
		options.uiContext.setTitle("Fixture Title");
		options.uiContext.setEditorText("fixture editor text");
		void options.uiContext.editor("Edit fixture", "prefill");
	}

	subscribe(listener: (event: AgentSessionEvent) => void): () => void {
		this.listeners.push(listener);
		if (this.scenario === "events-base-stream") {
			emitBaseStreamScenario(listener);
		} else if (this.scenario === "events-thinking-tool-usage") {
			emitThinkingToolUsageScenario(listener);
		} else if (this.scenario === "events-session-extras") {
			emitSessionExtrasScenario(listener);
		}
		return () => {
			this.listeners = this.listeners.filter((item) => item !== listener);
		};
	}

	private emitQueueUpdate(): void {
		for (const listener of this.listeners) {
			listener({ type: "queue_update", steering: [...this.steeringMessages], followUp: [...this.followUpMessages] });
		}
	}

	async prompt(
		message: string,
		options?: { preflightResult?: (didSucceed: boolean) => void; streamingBehavior?: "steer" | "followUp" },
	): Promise<void> {
		if (this.scenario === "prompt-concurrency-queue-order" && options?.streamingBehavior === "steer") {
			await this.steer(message);
			options?.preflightResult?.(true);
			return;
		}
		if (this.scenario === "prompt-concurrency-queue-order" && options?.streamingBehavior === "followUp") {
			await this.followUp(message);
			options?.preflightResult?.(true);
			return;
		}
		options?.preflightResult?.(true);
		if (this.scenario === "prompt-concurrency-queue-order") {
			return new Promise<void>(() => {});
		}
	}

	async steer(message: string, _images?: unknown): Promise<void> {
		this.steeringMessages.push(message);
		this.emitQueueUpdate();
	}

	async followUp(message: string, _images?: unknown): Promise<void> {
		this.followUpMessages.push(message);
		this.emitQueueUpdate();
	}

	async abort(): Promise<void> {}
	async setModel(_nextModel: Model<"anthropic-messages">): Promise<void> {}
	cycleModel(): null {
		return null;
	}
	setThinkingLevel(_level: string): void {}
	cycleThinkingLevel(): null {
		return null;
	}
	setSteeringMode(_mode: "all" | "one-at-a-time"): void {}
	setFollowUpMode(_mode: "all" | "one-at-a-time"): void {}
	async compact(_customInstructions?: string): Promise<object> {
		return {
			summary: "Compacted fixture history.",
			firstKeptEntryId: "entry_fixture_2",
			tokensBefore: 1234,
			details: { strategy: "faux" },
		};
	}
	setAutoCompactionEnabled(_enabled: boolean): void {}
	setAutoRetryEnabled(_enabled: boolean): void {}
	abortRetry(): void {}
	async executeBash(command: string): Promise<object> {
		if (command === "throw") {
			throw new Error("Command fixture failure");
		}
		return {
			output: "fixture\n",
			exitCode: 0,
			cancelled: false,
			truncated: true,
			fullOutputPath: "/tmp/pi-ts-rpc/full-output.txt",
		};
	}
	abortBash(): void {}
	getSessionStats(): object {
		return {
			sessionFile: "/tmp/pi-ts-rpc/session.jsonl",
			sessionId: "sess_fixture_1",
			userMessages: 1,
			assistantMessages: 1,
			toolCalls: 1,
			toolResults: 1,
			totalMessages: 3,
			tokens: { input: 11, output: 22, cacheRead: 3, cacheWrite: 4, total: 40 },
			cost: 0.0066,
			contextUsage: { used: 40, available: 200000, percentage: 0.02 },
		};
	}
	async exportToHtml(_outputPath?: string): Promise<string> {
		return "/tmp/pi-ts-rpc/export.html";
	}
	getUserMessagesForForking(): Array<{ entryId: string; text: string }> {
		return [{ entryId: "entry_fixture_1", text: "Plan with deterministic fixtures" }];
	}
	getLastAssistantText(): string {
		return "Fixtures captured.";
	}
	setSessionName(_name: string): void {}
}

class FixtureRuntimeHost {
	session: FixtureSession;
	private readonly scenario: RuntimeScenario;

	constructor(scenario: RuntimeScenario) {
		this.scenario = scenario;
		this.session = new FixtureSession(scenario);
	}

	setRebindSession(_rebind: () => Promise<void>): void {}

	async newSession(_options?: object): Promise<{ cancelled: boolean }> {
		this.session = new FixtureSession(this.scenario);
		return { cancelled: false };
	}

	async switchSession(_sessionPath: string): Promise<{ cancelled: boolean }> {
		this.session = new FixtureSession(this.scenario);
		return { cancelled: false };
	}

	async fork(_entryId: string, _options?: object): Promise<{ selectedText: string; cancelled: boolean }> {
		return { selectedText: "selected fixture text", cancelled: false };
	}

	async dispose(): Promise<void> {
		await new Promise<void>((resolve) => setTimeout(resolve, 10));
	}
}

async function runRuntimeChild(scenario: RuntimeScenario): Promise<never> {
	const runtimeHost = new FixtureRuntimeHost(scenario) as unknown as AgentSessionRuntime;
	return runRpcMode(runtimeHost);
}

async function buildFixtures(): Promise<FixtureFile[]> {
	const parseErrorFixtures = buildParseErrorCorpusFixtures();
	const lfLines = await collectJsonlReaderLines([Buffer.from('{"case":"lf-a"}\n{"case":"lf-b"}\n')]);
	const crlfLines = await collectJsonlReaderLines([Buffer.from('{"case":"crlf-a"}\r\n{"case":"crlf-b"}\r\n')]);
	const finalLine = await collectJsonlReaderLines([Buffer.from('{"case":"final-no-lf"}')]);
	const framingReaderObservations = jsonl([
		...lfLines.map((line, index) => ({ case: "lf-input-reader", index, line })),
		...crlfLines.map((line, index) => ({ case: "crlf-input-reader", index, line })),
		...finalLine.map((line, index) => ({ case: "final-unterminated-input-reader", index, line })),
	]);
	const runtimeFramingBytes = [
		captureRuntimeStdout("framing-lf", {
			input: jsonl([
				{ id: "framing_lf_a", type: "get_state" },
				{ id: "framing_lf_b", type: "get_state" },
			]),
		}),
		captureRuntimeStdout("framing-crlf", {
			input: '{"id":"framing_crlf_a","type":"get_state"}\r\n{"id":"framing_crlf_b","type":"get_state"}\r\n',
		}),
		captureRuntimeStdout("framing-final", {
			input: '{"id":"framing_final","type":"get_state"}',
		}),
		captureRuntimeStdout("framing-parse", { input: "{bad\n" }),
	].join("");

	const extensionUiResponseInputBytes = jsonl(extensionUiResponses);
	const files: FixtureFile[] = [
		{
			path: "commands-input.jsonl",
			description: "All current TS RPC command input shapes plus extension_ui_response variants.",
			bytes: jsonl([...commands, ...extensionUiResponses]),
		},
		{
			path: "jsonl-framing.jsonl",
			description: "Strict JSONL reader observations plus runRpcMode stdout bytes for LF, CRLF, parse-error, and final unterminated input.",
			bytes: framingReaderObservations + runtimeFramingBytes,
		},
		{
			path: "parse-errors.jsonl",
			description: "Node JSON.parse-derived runRpcMode stdout bytes for the malformed JSONL corpus.",
			bytes: parseErrorFixtures.outputs,
		},
		{
			path: "parse-error-corpus.jsonl",
			description: "Malformed JSONL corpus inputs and their exact Node JSON.parse-derived runRpcMode output bytes.",
			bytes: parseErrorFixtures.corpus,
		},
		{
			path: "responses-basic.jsonl",
			description: "runRpcMode stdout bytes for success, success-with-data, null data, command errors, parse error, and unknown-command quirk responses.",
			bytes: captureRuntimeStdout("responses-basic", { input: responseScenarioInput }),
		},
		{
			path: "events-base-stream.jsonl",
			description: "runRpcMode stdout bytes for base deterministic faux prompt event stream envelopes emitted via AgentSession.subscribe.",
			bytes: captureRuntimeStdout("events-base-stream"),
		},
		{
			path: "events-thinking-tool-usage.jsonl",
			description: "runRpcMode stdout bytes for thinking, tool call, tool execution, usage, details, and stop reason event shapes emitted via AgentSession.subscribe.",
			bytes: captureRuntimeStdout("events-thinking-tool-usage"),
		},
		{
			path: "events-session-extras.jsonl",
			description: "runRpcMode stdout bytes for session-level queue, compaction, retry, and session info events emitted via AgentSession.subscribe.",
			bytes: captureRuntimeStdout("events-session-extras"),
		},
		{
			path: "prompt-concurrency-queue-order.jsonl",
			description: "runRpcMode stdout bytes proving prompt stays fire-and-forget, abort can respond while a prompt promise is in flight, and steer/follow_up plus prompt.streamingBehavior emit queue_update before command responses.",
			bytes: captureRuntimeStdout("prompt-concurrency-queue-order", { input: promptConcurrencyScenarioInput }),
		},
		{
			path: "extension-ui.jsonl",
			description: "runRpcMode stdout bytes for ExtensionUIContext request methods plus extension_ui_response command input shapes.",
			bytes: captureRuntimeStdout("extension-ui") + extensionUiResponseInputBytes,
		},
	];

	const manifest = {
		generatedBy: "zig/test/generate-ts-rpc-fixtures.ts",
		compatibilityTarget: "packages/coding-agent TypeScript RPC mode",
		captureMethod,
		sourceCitations,
		files: files.map(({ path, description, bytes }) => ({
			path,
			description,
			byteLength: Buffer.byteLength(bytes),
			lineCount: bytes.split("\n").filter((line) => line.length > 0).length,
		})),
	};

	files.push({
		path: "manifest.json",
		description: "Fixture inventory, runtime capture method, and TS source citations.",
		bytes: `${JSON.stringify(manifest, null, "\t")}\n`,
	});

	return files;
}

function checkFile(path: string, expected: string): boolean {
	const fullPath = join(fixtureDir, path);
	if (!existsSync(fullPath)) {
		console.error(`Missing fixture: ${relative(process.cwd(), fullPath)}`);
		return false;
	}
	const actual = readFileSync(fullPath, "utf8");
	if (actual !== expected) {
		console.error(`Fixture differs: ${relative(process.cwd(), fullPath)}`);
		return false;
	}
	return true;
}

const scenario = runtimeChildArg?.slice("--runtime-child=".length) as RuntimeScenario | undefined;

if (scenario) {
	await runRuntimeChild(scenario);
} else {
	const files = await buildFixtures();

	if (checkMode) {
		const expectedPaths = new Set(files.map((file) => file.path));
		let ok = true;
		if (existsSync(fixtureDir)) {
			for (const existing of readdirSync(fixtureDir)) {
				if (!expectedPaths.has(existing)) {
					console.error(`Unexpected fixture: ${relative(process.cwd(), join(fixtureDir, existing))}`);
					ok = false;
				}
			}
		}
		for (const file of files) {
			ok = checkFile(file.path, file.bytes) && ok;
		}
		if (!ok) {
			process.exit(1);
		}
		console.log(`TS RPC fixtures are up to date in ${relative(process.cwd(), fixtureDir)}`);
	} else {
		mkdirSync(fixtureDir, { recursive: true });
		for (const file of files) {
			writeFileSync(join(fixtureDir, file.path), file.bytes);
		}
		console.log(`Wrote ${files.length} TS RPC fixture files to ${relative(process.cwd(), fixtureDir)}`);
	}
}
