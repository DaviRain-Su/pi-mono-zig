import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import type { AgentEvent, AgentMessage } from "@mariozechner/pi-agent-core";
import type { AssistantMessage, AssistantMessageEvent, Model, ToolCall, ToolResultMessage } from "@mariozechner/pi-ai";
import type { AgentSessionEvent } from "../../packages/coding-agent/src/core/agent-session.js";
import { attachJsonlLineReader, serializeJsonLine } from "../../packages/coding-agent/src/modes/rpc/jsonl.js";
import type {
	RpcCommand,
	RpcExtensionUIRequest,
	RpcExtensionUIResponse,
	RpcResponse,
	RpcSessionState,
	RpcSlashCommand,
} from "../../packages/coding-agent/src/modes/rpc/rpc-types.js";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const fixtureDir = join(scriptDir, "golden", "ts-rpc");
const checkMode = process.argv.includes("--check");

const sourceCitations = [
	"packages/coding-agent/src/modes/rpc/jsonl.ts:10-58",
	"packages/coding-agent/src/modes/rpc/rpc-mode.ts:57-70",
	"packages/coding-agent/src/modes/rpc/rpc-mode.ts:650-704",
	"packages/coding-agent/src/modes/rpc/rpc-mode.ts:706-737",
	"packages/coding-agent/src/modes/rpc/rpc-types.ts:19-264",
	"packages/agent/src/types.ts:350-365",
	"packages/ai/src/types.ts:207-276",
];

interface FixtureFile {
	path: string;
	description: string;
	bytes: string;
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

function success<T extends RpcCommand["type"]>(
	id: string | undefined,
	command: T,
	data?: object | null,
): RpcResponse {
	if (data === undefined) {
		return { id, type: "response", command, success: true } as RpcResponse;
	}
	return { id, type: "response", command, success: true, data } as RpcResponse;
}

function error(id: string | undefined, command: string, message: string): RpcResponse {
	return { id, type: "response", command, success: false, error: message };
}

function parseErrorResponse(line: string): RpcResponse {
	try {
		JSON.parse(line);
		throw new Error("Expected fixture parse input to fail");
	} catch (parseError: unknown) {
		return error(
			undefined,
			"parse",
			`Failed to parse command: ${parseError instanceof Error ? parseError.message : String(parseError)}`,
		);
	}
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

const responses = [
	success("resp_prompt", "prompt"),
	success(undefined, "steer"),
	success("resp_state", "get_state", sessionState),
	success(undefined, "cycle_model", null),
	success("resp_models", "get_available_models", { models: [model] }),
	success("resp_compact", "compact", {
		summary: "Compacted fixture history.",
		firstKeptEntryId: "entry_fixture_2",
		tokensBefore: 1234,
		details: { strategy: "faux" },
	}),
	success("resp_bash", "bash", {
		output: "fixture\n",
		exitCode: 0,
		cancelled: false,
		truncated: true,
		fullOutputPath: "/tmp/pi-ts-rpc/full-output.txt",
	}),
	success("resp_stats", "get_session_stats", {
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
	}),
	success("resp_export", "export_html", { path: "/tmp/pi-ts-rpc/export.html" }),
	success("resp_fork", "fork", { text: "selected fixture text", cancelled: false }),
	success("resp_messages", "get_messages", { messages: [userMessage, assistantText, toolResult] }),
	success("resp_commands", "get_commands", { commands: [slashCommand] }),
	error("resp_set_model_error", "set_model", "Model not found: anthropic/missing-model"),
	error("resp_thrown", "bash", "Command fixture failure"),
	parseErrorResponse("{not json"),
	error(undefined, "mystery_command", "Unknown command: mystery_command"),
] satisfies RpcResponse[];

const baseEvents = [
	{ type: "agent_start" },
	{ type: "turn_start" },
	{ type: "message_start", message: userMessage },
	{ type: "message_end", message: userMessage },
	{ type: "message_start", message: assistantEmpty },
	{
		type: "message_update",
		message: assistantEmpty,
		assistantMessageEvent: { type: "start", partial: assistantEmpty },
	},
	{
		type: "message_update",
		message: assistantText,
		assistantMessageEvent: { type: "text_start", contentIndex: 0, partial: assistantEmpty },
	},
	{
		type: "message_update",
		message: assistantText,
		assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "Fixtures", partial: assistantText },
	},
	{
		type: "message_update",
		message: assistantText,
		assistantMessageEvent: { type: "text_end", contentIndex: 0, content: "Fixtures captured.", partial: assistantText },
	},
	{
		type: "message_update",
		message: assistantText,
		assistantMessageEvent: { type: "done", reason: "stop", message: assistantText },
	},
	{ type: "message_end", message: assistantText },
	{ type: "turn_end", message: assistantText, toolResults: [] },
	{ type: "agent_end", messages: [userMessage, assistantText] },
] satisfies AgentEvent[];

const thinkingAndToolEvents = [
	{ type: "message_start", message: userMessageWithImage },
	{
		type: "message_update",
		message: assistantThinking,
		assistantMessageEvent: { type: "thinking_start", contentIndex: 0, partial: assistantEmpty },
	},
	{
		type: "message_update",
		message: assistantThinking,
		assistantMessageEvent: { type: "thinking_delta", contentIndex: 0, delta: "Need exact", partial: assistantThinking },
	},
	{
		type: "message_update",
		message: assistantThinking,
		assistantMessageEvent: {
			type: "thinking_end",
			contentIndex: 0,
			content: "Need exact field order.",
			partial: assistantThinking,
		},
	},
	{
		type: "message_update",
		message: assistantToolUse,
		assistantMessageEvent: { type: "toolcall_start", contentIndex: 1, partial: assistantThinking },
	},
	{
		type: "message_update",
		message: assistantToolUse,
		assistantMessageEvent: {
			type: "toolcall_delta",
			contentIndex: 1,
			delta: "{\"path\":\"zig/test/golden/ts-rpc\"}",
			partial: assistantToolUse,
		},
	},
	{
		type: "message_update",
		message: assistantToolUse,
		assistantMessageEvent: { type: "toolcall_end", contentIndex: 1, toolCall, partial: assistantToolUse },
	},
	{
		type: "message_update",
		message: assistantToolUse,
		assistantMessageEvent: { type: "done", reason: "toolUse", message: assistantToolUse },
	},
	{ type: "tool_execution_start", toolCallId: "toolu_fixture_1", toolName: "fixture_tool", args: toolCall.arguments },
	{
		type: "tool_execution_update",
		toolCallId: "toolu_fixture_1",
		toolName: "fixture_tool",
		args: toolCall.arguments,
		partialResult: partialToolResult,
	},
	{
		type: "tool_execution_end",
		toolCallId: "toolu_fixture_1",
		toolName: "fixture_tool",
		result: toolResult,
		isError: false,
	},
	{ type: "message_end", message: toolResult },
	{ type: "turn_end", message: assistantToolUse, toolResults: [toolResult] },
	{
		type: "message_update",
		message: assistantLength,
		assistantMessageEvent: { type: "done", reason: "length", message: assistantLength },
	},
	{
		type: "message_update",
		message: assistantAborted,
		assistantMessageEvent: { type: "error", reason: "aborted", error: assistantAborted },
	},
] satisfies AgentEvent[];

const sessionEvents = [
	{ type: "queue_update", steering: ["steer one"], followUp: ["follow one", "follow two"] },
	{ type: "compaction_start", reason: "manual" },
	{ type: "session_info_changed", name: "fixture session" },
	{
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
	},
	{ type: "auto_retry_start", attempt: 1, maxAttempts: 3, delayMs: 250, errorMessage: "transient fixture error" },
	{ type: "auto_retry_end", success: false, attempt: 3, finalError: "fixture retry exhausted" },
] satisfies AgentSessionEvent[];

const extensionUiRequests = [
	{ type: "extension_ui_request", id: "ui_select", method: "select", title: "Choose fixture", options: ["option-a", "option-b"], timeout: 1000 },
	{ type: "extension_ui_request", id: "ui_confirm", method: "confirm", title: "Confirm fixture", message: "Proceed?", timeout: 1000 },
	{ type: "extension_ui_request", id: "ui_input", method: "input", title: "Fixture input", placeholder: "value", timeout: 1000 },
	{ type: "extension_ui_request", id: "ui_editor", method: "editor", title: "Edit fixture", prefill: "prefill" },
	{ type: "extension_ui_request", id: "ui_notify", method: "notify", message: "Fixture notice", notifyType: "info" },
	{ type: "extension_ui_request", id: "ui_status", method: "setStatus", statusKey: "fixture", statusText: "ready" },
	{
		type: "extension_ui_request",
		id: "ui_widget",
		method: "setWidget",
		widgetKey: "fixture",
		widgetLines: ["line one", "line two"],
		widgetPlacement: "aboveEditor",
	},
	{ type: "extension_ui_request", id: "ui_title", method: "setTitle", title: "Fixture Title" },
	{ type: "extension_ui_request", id: "ui_editor_text", method: "set_editor_text", text: "fixture editor text" },
] satisfies RpcExtensionUIRequest[];

async function buildFixtures(): Promise<FixtureFile[]> {
	const lfLines = await collectJsonlReaderLines([Buffer.from('{"case":"lf-a"}\n{"case":"lf-b"}\n')]);
	const crlfLines = await collectJsonlReaderLines([Buffer.from('{"case":"crlf-a"}\r\n{"case":"crlf-b"}\r\n')]);
	const finalLine = await collectJsonlReaderLines([Buffer.from('{"case":"final-no-lf"}')]);
	const framingRecords = [
		{ case: "serialize-unicode-separators", bytes: serializeJsonLine({ text: "a\u2028b\u2029c" }) },
		...lfLines.map((line, index) => ({ case: "lf-input", index, line })),
		...crlfLines.map((line, index) => ({ case: "crlf-input", index, line })),
		...finalLine.map((line, index) => ({ case: "final-unterminated-input", index, line })),
		{ case: "parse-error-output", response: parseErrorResponse("") },
	];

	const files: FixtureFile[] = [
		{
			path: "commands-input.jsonl",
			description: "All current TS RPC command input shapes plus extension_ui_response variants.",
			bytes: jsonl([...commands, ...extensionUiResponses]),
		},
		{
			path: "jsonl-framing.jsonl",
			description: "Strict JSONL serialization plus LF, CRLF, and final unterminated input reader observations.",
			bytes: jsonl(framingRecords),
		},
		{
			path: "responses-basic.jsonl",
			description: "Success, success-with-data, null data, command errors, parse error, and unknown-command quirk responses.",
			bytes: jsonl(responses),
		},
		{
			path: "events-base-stream.jsonl",
			description: "Base deterministic faux prompt event stream envelopes.",
			bytes: jsonl(baseEvents),
		},
		{
			path: "events-thinking-tool-usage.jsonl",
			description: "Thinking, tool call, tool execution, usage, details, and stop reason event shapes.",
			bytes: jsonl(thinkingAndToolEvents),
		},
		{
			path: "events-session-extras.jsonl",
			description: "Session-level queue, compaction, retry, and session info events forwarded by TS RPC mode.",
			bytes: jsonl(sessionEvents),
		},
		{
			path: "extension-ui.jsonl",
			description: "Extension UI request methods and response commands with deterministic request ids.",
			bytes: jsonl([...extensionUiRequests, ...extensionUiResponses]),
		},
	];

	const manifest = {
		generatedBy: "zig/test/generate-ts-rpc-fixtures.ts",
		compatibilityTarget: "packages/coding-agent TypeScript RPC mode",
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
		description: "Fixture inventory and TS source citations.",
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
