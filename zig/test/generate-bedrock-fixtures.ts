import {
	BedrockRuntimeClient,
	type ConverseStreamOutput,
} from "@aws-sdk/client-bedrock-runtime";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "typebox";
import {
	streamBedrock,
	type BedrockOptions,
	streamSimpleBedrock,
} from "../../packages/ai/src/providers/amazon-bedrock.js";
import type {
	AssistantMessage,
	AssistantMessageEvent,
	Context,
	Message,
	Model,
	SimpleStreamOptions,
	ToolCall,
} from "../../packages/ai/src/types.js";

const scriptPath = fileURLToPath(import.meta.url);
const scriptDir = dirname(scriptPath);
const repoRoot = join(scriptDir, "..", "..");
const fixtureDir = join(scriptDir, "golden", "bedrock");
const schemaVersion = 1;
const checkMode = process.argv.includes("--check");
const maxFixtureBytes = 200_000;
const maxStringLength = 12_000;

const sourceCitations = [
	"packages/ai/src/providers/amazon-bedrock.ts:73-260",
	"packages/ai/src/providers/amazon-bedrock.ts:311-348",
	"packages/ai/src/providers/amazon-bedrock.ts:598-957",
	"zig/src/ai/providers/bedrock.zig:169-754",
	"zig/src/ai/providers/bedrock.zig:781-1427",
] as const;

const allowedScenarioIds = [
	"bedrock-stream-no-explicit-inference",
	"bedrock-stream-basic-text",
	"bedrock-stream-metadata-response",
	"bedrock-tools-choice-none",
	"bedrock-tools-choice-auto",
	"bedrock-tools-choice-any",
	"bedrock-tools-choice-specific",
	"bedrock-unrelated-provider-options-ignored",
	"bedrock-message-history-tool-results",
	"bedrock-vision-image-block",
	"bedrock-nonvision-image-downgrade",
	"bedrock-cache-points-long",
	"bedrock-onpayload-pass-through",
	"bedrock-onpayload-replacement",
	"bedrock-reasoning-fields",
	"bedrock-transform-replay-edge-cases",
	"bedrock-simple-explicit-tokens",
	"bedrock-binary-eventstream-tool-use",
] as const;

const allowedModelIds = [
	"anthropic.claude-3-7-sonnet-20250219-v1:0",
	"anthropic.claude-3-5-haiku-20241022-v1:0",
	"amazon.nova-pro-v1:0",
] as const;

const allowedLocalStreamFormats = ["json-lines", "aws-eventstream"] as const;
const allowedIgnoredPaths = [
	"id",
	"title",
	"input",
	"metadata",
	"schemaVersion",
	"expected.onResponse",
	"expected.binaryEventStream",
] as const;

type ScenarioId = (typeof allowedScenarioIds)[number];
type LocalStreamFormat = (typeof allowedLocalStreamFormats)[number];
type WithoutTimestamp<T> = T extends { timestamp: number } ? Omit<T, "timestamp"> : T;
type DeclarativeMessage = WithoutTimestamp<Message>;

interface FixtureModelInput {
	id: (typeof allowedModelIds)[number];
	name: string;
	api: "bedrock-converse-stream";
	provider: "amazon-bedrock";
	baseUrl: string;
	reasoning: boolean;
	input: ("text" | "image")[];
}

interface SerializableOptions {
	cacheRetention?: "none" | "short" | "long";
	maxTokens?: number;
	temperature?: number;
	toolChoice?: BedrockOptions["toolChoice"];
	googleToolChoice?: "auto" | "any" | "none";
	reasoning?: "minimal" | "low" | "medium" | "high" | "xhigh";
	thinkingBudgets?: BedrockOptions["thinkingBudgets"];
	interleavedThinking?: boolean;
	thinkingDisplay?: BedrockOptions["thinkingDisplay"];
	requestMetadata?: Record<string, string>;
	onPayload?: "pass-through" | "replace";
	onResponse?: "capture";
}

interface DeclarativeContext {
	systemPrompt?: string;
	messages: DeclarativeMessage[];
	tools?: Context["tools"];
}

interface ScenarioInput {
	mode: "streamBedrock" | "streamSimpleBedrock";
	model: FixtureModelInput;
	context: DeclarativeContext;
	options: SerializableOptions;
	localStream: {
		format: LocalStreamFormat;
		events: ConverseStreamFixtureEvent[];
	};
}

interface Scenario {
	id: ScenarioId;
	title: string;
	input: ScenarioInput;
}

type ConverseStreamFixtureEvent =
	| { messageStart: { role: "assistant" | "user" } }
	| { contentBlockStart: { contentBlockIndex: number; start: { toolUse: { toolUseId: string; name: string } } } }
	| { contentBlockDelta: { contentBlockIndex: number; delta: Record<string, unknown> } }
	| { contentBlockStop: { contentBlockIndex: number } }
	| { messageStop: { stopReason: string } }
	| { metadata: { usage: { inputTokens?: number; outputTokens?: number; totalTokens?: number } } }
	| { validationException: { message: string } };

interface SemanticToolCall {
	id: string;
	name: string;
	arguments: unknown;
}

interface SemanticContentBlock {
	type: "text" | "thinking" | "toolCall";
	text?: string;
	thinking?: string;
	thinkingSignature?: string;
	id?: string;
	name?: string;
	arguments?: unknown;
}

interface SemanticMessage {
	role: "assistant";
	content: SemanticContentBlock[];
	api: "bedrock-converse-stream";
	provider: "amazon-bedrock";
	model: string;
	usage: {
		input: number;
		output: number;
		cacheRead: number;
		cacheWrite: number;
		totalTokens: number;
		cost: { input: number; output: number; cacheRead: number; cacheWrite: number; total: number };
	};
	stopReason: string;
	errorMessage?: string;
}

interface SemanticEvent {
	type: AssistantMessageEvent["type"];
	contentIndex?: number;
	delta?: string;
	content?: string;
	toolCall?: SemanticToolCall;
	message?: SemanticMessage;
	errorMessage?: string;
}

interface FixtureRecord {
	schemaVersion: typeof schemaVersion;
	id: ScenarioId;
	title: string;
	input: ScenarioInput;
	expected: {
		typeScriptRequest: {
			mode: ScenarioInput["mode"];
			payload: unknown;
		};
		typeScriptStream: SemanticEvent[];
		onResponse?: {
			status: number;
			headers: Record<string, string>;
		};
		binaryEventStream?: {
			encoding: "base64";
			format: "aws-eventstream";
			base64: string;
			eventTypes: string[];
		};
	};
	metadata: {
		captureBoundary: string;
		captureMethod: string;
		network: "BedrockRuntimeClient.send prototype mock rejects unhandled remote behavior";
		allowlists: {
			scenarioIds: readonly string[];
			modelIds: readonly string[];
			localStreamFormats: readonly string[];
			ignoredPaths: readonly string[];
		};
		sourceCitations: readonly string[];
	};
}

const baseModel: FixtureModelInput = {
	id: "anthropic.claude-3-7-sonnet-20250219-v1:0",
	name: "Claude 3.7 Sonnet Bedrock Fixture",
	api: "bedrock-converse-stream",
	provider: "amazon-bedrock",
	baseUrl: "https://bedrock-runtime.us-east-1.amazonaws.com",
	reasoning: true,
	input: ["text"],
};

const novaModel: FixtureModelInput = {
	...baseModel,
	id: "amazon.nova-pro-v1:0",
	name: "Nova Pro Bedrock Fixture",
	reasoning: false,
};

const visionModel: FixtureModelInput = {
	...baseModel,
	id: "anthropic.claude-3-5-haiku-20241022-v1:0",
	name: "Claude 3.5 Haiku Bedrock Vision Fixture",
	reasoning: false,
	input: ["text", "image"],
};

const baseContext = {
	systemPrompt: "You are the deterministic Bedrock fixture assistant.",
	messages: [{ role: "user", content: "Return a concise Bedrock fixture response." }],
} satisfies DeclarativeContext;

const fixtureTool = {
	name: "get_weather",
	description: "Return deterministic weather for a city.",
	parameters: Type.Object({
		city: Type.String(),
		unit: Type.Union([Type.Literal("celsius"), Type.Literal("fahrenheit")]),
	}),
};

const secondFixtureTool = {
	name: "lookup_order",
	description: "Return deterministic order details.",
	parameters: Type.Object({
		orderId: Type.String(),
	}),
};

const toolArguments = { city: "Berlin", unit: "celsius" };

const sameModelAssistant = {
	role: "assistant",
	content: [
		{ type: "text", text: "I will call a tool." },
		{
			type: "thinking",
			thinking: "Need weather.",
			thinkingSignature: "thinking-signature-1",
		},
		{ type: "toolCall", id: "tool-call-1", name: "get_weather", arguments: toolArguments },
	],
	api: "bedrock-converse-stream",
	provider: "amazon-bedrock",
	model: baseModel.id,
	usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
	stopReason: "toolUse",
} satisfies DeclarativeMessage;

const externalAssistantWithLongToolId = {
	role: "assistant",
	content: [
		{ type: "thinking", thinking: "Cross model thinking becomes text.", thinkingSignature: "external-thinking-signature" },
		{
			type: "toolCall",
			id: "tool.call/with:special#chars-and-a-very-long-identifier-that-exceeds-sixty-four-characters",
			name: "get_weather",
			arguments: toolArguments,
		},
	],
	api: "openai-responses",
	provider: "openai",
	model: "gpt-5",
	usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
	stopReason: "toolUse",
} satisfies DeclarativeMessage;

const erroredAssistant = {
	role: "assistant",
	content: [{ type: "text", text: "partial failure" }],
	api: "bedrock-converse-stream",
	provider: "amazon-bedrock",
	model: baseModel.id,
	usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
	stopReason: "error",
	errorMessage: "failed",
} satisfies DeclarativeMessage;

const textEvents: ConverseStreamFixtureEvent[] = [
	{ messageStart: { role: "assistant" } },
	{ contentBlockDelta: { contentBlockIndex: 0, delta: { text: "Bedrock fixture response." } } },
	{ contentBlockStop: { contentBlockIndex: 0 } },
	{ messageStop: { stopReason: "end_turn" } },
	{ metadata: { usage: { inputTokens: 7, outputTokens: 5, totalTokens: 12 } } },
];

const toolUseEvents: ConverseStreamFixtureEvent[] = [
	{ messageStart: { role: "assistant" } },
	{ contentBlockDelta: { contentBlockIndex: 0, delta: { reasoningContent: { text: "Need weather.", signature: "sig-1" } } } },
	{ contentBlockStop: { contentBlockIndex: 0 } },
	{
		contentBlockStart: {
			contentBlockIndex: 1,
			start: { toolUse: { toolUseId: "tool-1", name: "get_weather" } },
		},
	},
	{ contentBlockDelta: { contentBlockIndex: 1, delta: { toolUse: { input: "{\"city\":\"Ber" } } } },
	{ contentBlockDelta: { contentBlockIndex: 1, delta: { toolUse: { input: "lin\",\"unit\":\"celsius\"}" } } } },
	{ contentBlockStop: { contentBlockIndex: 1 } },
	{ messageStop: { stopReason: "tool_use" } },
	{ metadata: { usage: { inputTokens: 21, outputTokens: 9, totalTokens: 30 } } },
];

const scenarios: Scenario[] = [
	{
		id: "bedrock-stream-no-explicit-inference",
		title: "Bedrock streamBedrock omits low-level max token defaults when no inference options are explicit",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: { messages: [{ role: "user", content: "No explicit inference config." }] },
			options: { cacheRetention: "none" },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-stream-basic-text",
		title: "Bedrock streamBedrock captures a basic Converse request and text stream locally",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64, temperature: 0 },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-stream-metadata-response",
		title: "Bedrock streamBedrock preserves request metadata and response callback metadata",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: {
				...baseContext,
				tools: [fixtureTool],
			},
			options: {
				cacheRetention: "none",
				maxTokens: 96,
				requestMetadata: { project: "m8c", scenario: "metadata-response" },
				onResponse: "capture",
			},
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-tools-choice-none",
		title: "Bedrock toolChoice none omits toolConfig even when tools are present",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: { ...baseContext, tools: [fixtureTool] },
			options: { cacheRetention: "none", maxTokens: 64, toolChoice: "none" },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-tools-choice-auto",
		title: "Bedrock toolChoice auto maps to toolConfig.toolChoice.auto",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: { ...baseContext, tools: [fixtureTool] },
			options: { cacheRetention: "none", maxTokens: 64, toolChoice: "auto" },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-tools-choice-any",
		title: "Bedrock toolChoice any maps to toolConfig.toolChoice.any",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: { ...baseContext, tools: [fixtureTool] },
			options: { cacheRetention: "none", maxTokens: 64, toolChoice: "any" },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-tools-choice-specific",
		title: "Bedrock specific toolChoice maps to toolConfig.toolChoice.tool.name",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: { ...baseContext, tools: [fixtureTool, secondFixtureTool] },
			options: { cacheRetention: "none", maxTokens: 64, toolChoice: { type: "tool", name: "lookup_order" } },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-unrelated-provider-options-ignored",
		title: "Bedrock ignores unrelated provider option fields while honoring dedicated Bedrock options",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: { ...baseContext, tools: [fixtureTool] },
			options: { cacheRetention: "none", maxTokens: 64, googleToolChoice: "any", toolChoice: "auto" },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-message-history-tool-results",
		title: "Bedrock converts assistant history, normalizes cross-provider tool ids, and groups tool results",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: {
				messages: [
					{ role: "user", content: "Use tool history." },
					sameModelAssistant,
					{ role: "toolResult", toolCallId: "tool-call-1", toolName: "get_weather", content: [{ type: "text", text: "sunny" }] },
					externalAssistantWithLongToolId,
					{
						role: "toolResult",
						toolCallId: "tool.call/with:special#chars-and-a-very-long-identifier-that-exceeds-sixty-four-characters",
						toolName: "get_weather",
						content: [{ type: "text", text: "rain" }],
						isError: true,
					},
					{ role: "toolResult", toolCallId: "second-tool", toolName: "lookup_order", content: [{ type: "text", text: "second" }] },
				],
				tools: [fixtureTool, secondFixtureTool],
			},
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-vision-image-block",
		title: "Bedrock vision-capable models convert image content to Bedrock image blocks",
		input: {
			mode: "streamBedrock",
			model: visionModel,
			context: {
				messages: [{ role: "user", content: [{ type: "text", text: "Describe this." }, { type: "image", mimeType: "image/png", data: "aGVsbG8=" }] }],
			},
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-nonvision-image-downgrade",
		title: "Bedrock non-vision models downgrade user and tool-result images to deterministic text placeholders",
		input: {
			mode: "streamBedrock",
			model: novaModel,
			context: {
				messages: [
					{ role: "user", content: [{ type: "image", mimeType: "image/png", data: "aGVsbG8=" }] },
					{
						role: "toolResult",
						toolCallId: "tool-image",
						toolName: "get_weather",
						content: [{ type: "image", mimeType: "image/png", data: "aGVsbG8=" }],
					},
				],
			},
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-cache-points-long",
		title: "Bedrock Claude cache retention adds long cache points to system and last user messages",
		input: {
			mode: "streamBedrock",
			model: visionModel,
			context: baseContext,
			options: { cacheRetention: "long", maxTokens: 64 },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-onpayload-pass-through",
		title: "Bedrock onPayload pass-through preserves the generated payload",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64, onPayload: "pass-through" },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-onpayload-replacement",
		title: "Bedrock onPayload replacement sends exactly the replacement payload",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 64, onPayload: "replace" },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-reasoning-fields",
		title: "Bedrock Claude reasoning emits additional model request fields",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 20000, reasoning: "medium", thinkingBudgets: { medium: 4096 }, thinkingDisplay: "omitted", interleavedThinking: false },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-transform-replay-edge-cases",
		title: "Bedrock transformMessages skips failed assistants and synthesizes orphaned tool results",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: {
				messages: [
					{ role: "user", content: "Replay edge cases." },
					erroredAssistant,
					externalAssistantWithLongToolId,
					{ role: "user", content: "Continue after orphaned call." },
				],
				tools: [fixtureTool],
			},
			options: { cacheRetention: "none", maxTokens: 64 },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-simple-explicit-tokens",
		title: "Bedrock streamSimpleBedrock uses the real simple-option path with explicit max tokens",
		input: {
			mode: "streamSimpleBedrock",
			model: novaModel,
			context: baseContext,
			options: { cacheRetention: "none", maxTokens: 128 },
			localStream: { format: "json-lines", events: textEvents },
		},
	},
	{
		id: "bedrock-binary-eventstream-tool-use",
		title: "Bedrock binary AWS EventStream fixture covers thinking and tool-use chunks",
		input: {
			mode: "streamBedrock",
			model: baseModel,
			context: {
				...baseContext,
				tools: [fixtureTool],
			},
			options: { cacheRetention: "none", maxTokens: 80 },
			localStream: { format: "aws-eventstream", events: toolUseEvents },
		},
	},
];

function toRuntimeModel(model: FixtureModelInput): Model<"bedrock-converse-stream"> {
	return {
		...model,
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		contextWindow: 200_000,
		maxTokens: 4096,
	};
}

function toRuntimeContext(context: DeclarativeContext): Context {
	return {
		...context,
		messages: context.messages.map((message, index) => ({
			...message,
			timestamp: 1_700_000_000_000 + index,
		})) as Context["messages"],
	};
}

function toRuntimeOptions(options: SerializableOptions): BedrockOptions {
	return {
		...(options.cacheRetention !== undefined ? { cacheRetention: options.cacheRetention } : {}),
		...(options.maxTokens !== undefined ? { maxTokens: options.maxTokens } : {}),
		...(options.temperature !== undefined ? { temperature: options.temperature } : {}),
		...(options.toolChoice !== undefined ? { toolChoice: options.toolChoice } : {}),
		...(options.googleToolChoice !== undefined ? { googleToolChoice: options.googleToolChoice } : {}),
		...(options.reasoning !== undefined ? { reasoning: options.reasoning } : {}),
		...(options.thinkingBudgets !== undefined ? { thinkingBudgets: options.thinkingBudgets } : {}),
		...(options.interleavedThinking !== undefined ? { interleavedThinking: options.interleavedThinking } : {}),
		...(options.thinkingDisplay !== undefined ? { thinkingDisplay: options.thinkingDisplay } : {}),
		...(options.requestMetadata !== undefined ? { requestMetadata: options.requestMetadata } : {}),
	} as BedrockOptions;
}

function stableValue(value: unknown): unknown {
	if (value instanceof Uint8Array) {
		return Buffer.from(value).toString("base64");
	}
	if (Array.isArray(value)) {
		return value.map((item) => stableValue(item));
	}
	if (value && typeof value === "object") {
		const output: Record<string, unknown> = {};
		for (const key of Object.keys(value).sort()) {
			const child = (value as Record<string, unknown>)[key];
			if (child !== undefined) {
				output[key] = stableValue(child);
			}
		}
		return output;
	}
	return value;
}

function stableStringify(value: unknown): string {
	return `${JSON.stringify(stableValue(value), null, 2)}\n`;
}

function eventType(event: ConverseStreamFixtureEvent): string {
	return Object.keys(event)[0] ?? "unknown";
}

function eventPayload(event: ConverseStreamFixtureEvent): unknown {
	const key = eventType(event);
	return (event as unknown as Record<string, unknown>)[key];
}

function toSdkEvent(event: ConverseStreamFixtureEvent): Record<string, unknown> {
	return event as unknown as Record<string, unknown>;
}

function buildMockAsyncStream(events: ConverseStreamFixtureEvent[]): AsyncIterable<Record<string, unknown>> {
	return {
		async *[Symbol.asyncIterator]() {
			for (const event of events) {
				yield toSdkEvent(event);
			}
		},
	};
}

function appendBigEndianU32(bytes: number[], value: number): void {
	bytes.push((value >> 24) & 0xff, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff);
}

function appendBigEndianU16(bytes: number[], value: number): void {
	bytes.push((value >> 8) & 0xff, value & 0xff);
}

function eventStreamHeader(name: string, value: string): number[] {
	const encoder = new TextEncoder();
	const nameBytes = [...encoder.encode(name)];
	const valueBytes = [...encoder.encode(value)];
	const bytes: number[] = [];
	bytes.push(nameBytes.length, ...nameBytes, 7);
	appendBigEndianU16(bytes, valueBytes.length);
	bytes.push(...valueBytes);
	return bytes;
}

function buildEventStreamBase64(events: ConverseStreamFixtureEvent[]): string {
	const encoder = new TextEncoder();
	const frames: number[] = [];
	for (const event of events) {
		const headers = eventStreamHeader(":event-type", eventType(event));
		const payload = [...encoder.encode(JSON.stringify(eventPayload(event)))];
		const totalLength = 16 + headers.length + payload.length;
		appendBigEndianU32(frames, totalLength);
		appendBigEndianU32(frames, headers.length);
		appendBigEndianU32(frames, 0);
		frames.push(...headers, ...payload);
		appendBigEndianU32(frames, 0);
	}
	return Buffer.from(frames).toString("base64");
}

function semanticContent(content: AssistantMessage["content"]): SemanticContentBlock[] {
	return content.map((block) => {
		switch (block.type) {
			case "text":
				return { type: "text", text: block.text };
			case "thinking":
				return {
					type: "thinking",
					thinking: block.thinking,
					...(block.thinkingSignature ? { thinkingSignature: block.thinkingSignature } : {}),
				};
			case "toolCall":
				return { type: "toolCall", id: block.id, name: block.name, arguments: stableValue(block.arguments) };
			default:
				throw new Error(`Unsupported semantic content block ${JSON.stringify(block)}`);
		}
	});
}

function semanticMessage(message: AssistantMessage): SemanticMessage {
	return {
		role: "assistant",
		content: semanticContent(message.content),
		api: "bedrock-converse-stream",
		provider: "amazon-bedrock",
		model: message.model,
		usage: {
			input: message.usage.input,
			output: message.usage.output,
			cacheRead: message.usage.cacheRead,
			cacheWrite: message.usage.cacheWrite,
			totalTokens: message.usage.totalTokens,
			cost: {
				input: message.usage.cost.input,
				output: message.usage.cost.output,
				cacheRead: message.usage.cost.cacheRead,
				cacheWrite: message.usage.cost.cacheWrite,
				total: message.usage.cost.total,
			},
		},
		stopReason: message.stopReason,
		...(message.errorMessage ? { errorMessage: message.errorMessage } : {}),
	};
}

function semanticToolCall(toolCall: ToolCall): SemanticToolCall {
	return {
		id: toolCall.id,
		name: toolCall.name,
		arguments: stableValue(toolCall.arguments),
	};
}

function semanticEvent(event: AssistantMessageEvent): SemanticEvent {
	return {
		type: event.type,
		...(event.contentIndex !== undefined ? { contentIndex: event.contentIndex } : {}),
		...(event.delta !== undefined ? { delta: event.delta } : {}),
		...(event.content !== undefined ? { content: event.content } : {}),
		...(event.toolCall !== undefined ? { toolCall: semanticToolCall(event.toolCall) } : {}),
		...(event.message !== undefined ? { message: semanticMessage(event.message) } : {}),
		...(event.errorMessage !== undefined ? { errorMessage: event.errorMessage } : {}),
	};
}

async function captureScenario(scenario: Scenario): Promise<FixtureRecord> {
	const prototype = BedrockRuntimeClient.prototype as unknown as {
		send: (command: unknown, options?: unknown) => Promise<ConverseStreamOutput>;
	};
	const originalSend = prototype.send;
	let capturedPayload: unknown;
	let capturedResponse: FixtureRecord["expected"]["onResponse"];

	prototype.send = async (command: unknown): Promise<ConverseStreamOutput> => {
		const commandWithInput = command as { input?: unknown };
		capturedPayload = stableValue(commandWithInput.input);
		return {
			$metadata: {
				httpStatusCode: 200,
				requestId: `fixture-request-${scenario.id}`,
			},
			stream: buildMockAsyncStream(scenario.input.localStream.events) as ConverseStreamOutput["stream"],
		};
	};

	try {
		const runtimeModel = toRuntimeModel(scenario.input.model);
		const runtimeContext = toRuntimeContext(scenario.input.context);
		const runtimeOptions = toRuntimeOptions(scenario.input.options);
		if (scenario.input.options.onPayload === "pass-through") {
			runtimeOptions.onPayload = () => undefined;
		} else if (scenario.input.options.onPayload === "replace") {
			runtimeOptions.onPayload = () => ({
				modelId: scenario.input.model.id,
				messages: [{ role: "user", content: [{ text: "replacement payload" }] }],
				inferenceConfig: { maxTokens: 7 },
				requestMetadata: { replacement: "true" },
			});
		}
		if (scenario.input.options.onResponse === "capture") {
			runtimeOptions.onResponse = (response) => {
				capturedResponse = {
					status: response.status,
					headers: stableValue(response.headers) as Record<string, string>,
				};
			};
		}

		const stream =
			scenario.input.mode === "streamSimpleBedrock"
				? streamSimpleBedrock(runtimeModel, runtimeContext, runtimeOptions as SimpleStreamOptions)
				: streamBedrock(runtimeModel, runtimeContext, runtimeOptions);
		const events: SemanticEvent[] = [];
		for await (const event of stream) {
			events.push(semanticEvent(event));
		}
		const terminalEvent = events.at(-1);
		if (terminalEvent?.type !== "done") {
			throw new Error(`Scenario ${scenario.id} did not complete with a done event`);
		}
		if (capturedPayload === undefined) {
			throw new Error(`Scenario ${scenario.id} did not capture a Bedrock Converse command input`);
		}
		if (scenario.input.options.onResponse === "capture" && capturedResponse === undefined) {
			throw new Error(`Scenario ${scenario.id} did not capture onResponse metadata`);
		}

		return {
			schemaVersion,
			id: scenario.id,
			title: scenario.title,
			input: scenario.input,
			expected: {
				typeScriptRequest: {
					mode: scenario.input.mode,
					payload: capturedPayload,
				},
				typeScriptStream: events,
				...(capturedResponse ? { onResponse: capturedResponse } : {}),
				...(scenario.input.localStream.format === "aws-eventstream"
					? {
							binaryEventStream: {
								encoding: "base64",
								format: "aws-eventstream",
								base64: buildEventStreamBase64(scenario.input.localStream.events),
								eventTypes: scenario.input.localStream.events.map(eventType),
							},
						}
					: {}),
			},
			metadata: {
				captureBoundary:
					"streamBedrock/streamSimpleBedrock after TypeScript Converse command construction and before BedrockRuntimeClient.send would contact AWS",
				captureMethod:
					"BedrockRuntimeClient.prototype.send is replaced with a deterministic local mock that records command.input and returns fixed Converse stream events",
				network: "BedrockRuntimeClient.send prototype mock rejects unhandled remote behavior",
				allowlists: {
					scenarioIds: allowedScenarioIds,
					modelIds: allowedModelIds,
					localStreamFormats: allowedLocalStreamFormats,
					ignoredPaths: allowedIgnoredPaths,
				},
				sourceCitations,
			},
		};
	} finally {
		prototype.send = originalSend;
	}
}

function validateSecretFree(value: unknown, path: string): void {
	if (typeof value === "string") {
		if (value.length > maxStringLength) {
			throw new Error(`HARNESS_SECRET: ${path} exceeds ${maxStringLength} characters`);
		}
		const forbiddenStrings = [repoRoot, scriptDir, "/Users/", "file://", "Bearer ", "AWS_SECRET_ACCESS_KEY"];
		for (const marker of forbiddenStrings) {
			if (value.includes(marker)) {
				throw new Error(`HARNESS_SECRET: ${path} contains forbidden marker ${JSON.stringify(marker)}`);
			}
		}
		const awsCredentialPatterns = [/AKIA[0-9A-Z]{16}/, /ASIA[0-9A-Z]{16}/, /aws(.{0,20})?(secret|session|token)/i];
		for (const pattern of awsCredentialPatterns) {
			if (pattern.test(value)) {
				throw new Error(`HARNESS_SECRET: ${path} contains secret-like marker`);
			}
		}
		if (/[A-Za-z0-9/+=]{40,}/.test(value) && !/^[A-Za-z0-9+/=]+$/.test(value)) {
			throw new Error(`HARNESS_SECRET: ${path} contains secret-like marker`);
		}
		return;
	}
	if (Array.isArray(value)) {
		value.forEach((item, index) => validateSecretFree(item, `${path}[${index}]`));
		return;
	}
	if (value && typeof value === "object") {
		for (const [key, child] of Object.entries(value)) {
			if (key === "timestamp" || key === "created") {
				throw new Error(`HARNESS_SCHEMA: ${path}.${key} contains a volatile timestamp field`);
			}
			validateSecretFree(child, `${path}.${key}`);
		}
	}
}

function validateStreamEvents(record: FixtureRecord): void {
	let sawStart = false;
	let terminalCount = 0;
	const activeToolBlocks = new Set<number>();
	for (const [index, event] of record.expected.typeScriptStream.entries()) {
		if (event.type === "start") sawStart = true;
		if (!sawStart && event.type !== "start") {
			throw new Error(`HARNESS_STREAM_ORDER: ${record.id} event ${index} appears before start`);
		}
		if (event.type === "toolcall_start") {
			if (event.contentIndex === undefined) {
				throw new Error(`HARNESS_TOOL_FRAMING: ${record.id} toolcall_start missing contentIndex`);
			}
			activeToolBlocks.add(event.contentIndex);
		}
		if (event.type === "toolcall_delta" || event.type === "toolcall_end") {
			if (event.contentIndex === undefined || !activeToolBlocks.has(event.contentIndex)) {
				throw new Error(`HARNESS_TOOL_FRAMING: ${record.id} ${event.type} without active tool block`);
			}
			if (event.type === "toolcall_end") activeToolBlocks.delete(event.contentIndex);
		}
		if (event.type === "done" || event.type === "error_event") {
			terminalCount++;
			if (!event.message) {
				throw new Error(`HARNESS_STREAM_TERMINAL: ${record.id} terminal event missing message`);
			}
			if (!["stop", "length", "toolUse", "error", "aborted"].includes(event.message.stopReason)) {
				throw new Error(`HARNESS_USAGE_STOP: ${record.id} invalid stopReason ${event.message.stopReason}`);
			}
			const usage = event.message.usage;
			if (usage.totalTokens !== usage.input + usage.output && usage.totalTokens === 0) {
				throw new Error(`HARNESS_USAGE_STOP: ${record.id} corrupt usage total`);
			}
		}
	}
	if (terminalCount !== 1) {
		throw new Error(`HARNESS_STREAM_TERMINAL: ${record.id} expected exactly one terminal event`);
	}
}

function validateFixture(record: FixtureRecord): void {
	const allowedTopLevelKeys = ["expected", "id", "input", "metadata", "schemaVersion", "title"];
	for (const key of Object.keys(record)) {
		if (!allowedTopLevelKeys.includes(key)) {
			throw new Error(`HARNESS_SCHEMA: Fixture ${record.id} contains unknown top-level key ${key}`);
		}
	}
	if (record.schemaVersion !== schemaVersion) {
		throw new Error(`HARNESS_SCHEMA: Fixture ${record.id} has unsupported schemaVersion`);
	}
	if (!allowedScenarioIds.includes(record.id)) {
		throw new Error(`HARNESS_ALLOWLIST: unlisted fixture id ${record.id}`);
	}
	if (!allowedModelIds.includes(record.input.model.id)) {
		throw new Error(`HARNESS_ALLOWLIST: ${record.id} uses unlisted model ${record.input.model.id}`);
	}
	if (record.input.model.api !== "bedrock-converse-stream") {
		throw new Error(`HARNESS_SCHEMA: ${record.id} is not a Bedrock Converse fixture`);
	}
	if (!allowedLocalStreamFormats.includes(record.input.localStream.format)) {
		throw new Error(`HARNESS_ALLOWLIST: ${record.id} uses unlisted local stream format`);
	}
	if (!record.expected?.typeScriptRequest?.payload || !record.expected?.typeScriptStream?.length) {
		throw new Error(`HARNESS_SCHEMA: ${record.id} missing request or stream snapshots`);
	}
	if (record.input.localStream.format === "aws-eventstream") {
		const binary = record.expected.binaryEventStream;
		if (!binary || binary.encoding !== "base64" || binary.format !== "aws-eventstream") {
			throw new Error(`HARNESS_BINARY: ${record.id} missing binary AWS EventStream fixture`);
		}
		if (!/^[A-Za-z0-9+/]+={0,2}$/.test(binary.base64)) {
			throw new Error(`HARNESS_BINARY: ${record.id} has malformed base64 EventStream bytes`);
		}
	}
	const serialized = stableStringify(record);
	if (Buffer.byteLength(serialized) > maxFixtureBytes) {
		throw new Error(`HARNESS_SCHEMA: Fixture ${record.id} exceeds ${maxFixtureBytes} bytes`);
	}
	validateStreamEvents(record);
	validateSecretFree(record, record.id);
}

function validateRecords(records: FixtureRecord[]): void {
	const ids = new Set<string>();
	for (const record of records) {
		if (ids.has(record.id)) {
			throw new Error(`HARNESS_MANIFEST: duplicate Bedrock fixture id ${record.id}`);
		}
		ids.add(record.id);
		validateFixture(record);
	}
	for (const id of allowedScenarioIds) {
		if (!ids.has(id)) {
			throw new Error(`HARNESS_MANIFEST: missing allowlisted scenario ${id}`);
		}
	}
}

function cloneRecord(record: FixtureRecord): FixtureRecord {
	return JSON.parse(JSON.stringify(record)) as FixtureRecord;
}

function expectNegative(name: string, expectedCode: string, action: () => void): string {
	try {
		action();
		throw new Error(`negative ${name} unexpectedly passed`);
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		if (!message.includes(expectedCode)) {
			throw new Error(`negative ${name} failed for wrong reason: expected ${expectedCode}, got ${message}`);
		}
		return `${name}:${expectedCode}`;
	}
}

function runNegativeSuite(records: FixtureRecord[]): string[] {
	const first = records[0];
	const output: string[] = [];
	output.push(
		expectNegative("malformed-json", "JSON", () => {
			JSON.parse("{not-json");
		}),
	);
	output.push(
		expectNegative("unsupported-provider", "HARNESS_SCHEMA", () => {
			const record = cloneRecord(first);
			(record.input.model as unknown as { api: string }).api = "openai-completions";
			validateFixture(record);
		}),
	);
	output.push(
		expectNegative("missing-required", "HARNESS_SCHEMA", () => {
			const record = cloneRecord(first);
			delete (record.expected as unknown as { typeScriptRequest?: unknown }).typeScriptRequest;
			validateFixture(record);
		}),
	);
	output.push(
		expectNegative("invalid-tool-framing", "HARNESS_TOOL_FRAMING", () => {
			const record = cloneRecord(first);
			record.expected.typeScriptStream.splice(1, 0, { type: "toolcall_delta", contentIndex: 7, delta: "}" });
			validateFixture(record);
		}),
	);
	output.push(
		expectNegative("out-of-order-stream", "HARNESS_STREAM_ORDER", () => {
			const record = cloneRecord(first);
			record.expected.typeScriptStream.unshift({ type: "text_delta", contentIndex: 0, delta: "early" });
			validateFixture(record);
		}),
	);
	output.push(
		expectNegative("corrupted-usage-stop", "HARNESS_USAGE_STOP", () => {
			const record = cloneRecord(first);
			const terminal = record.expected.typeScriptStream.at(-1);
			if (terminal?.message) terminal.message.stopReason = "unsupported";
			validateFixture(record);
		}),
	);
	output.push(
		expectNegative("duplicate-manifest", "HARNESS_MANIFEST", () => {
			validateRecords([first, first]);
		}),
	);
	output.push(
		expectNegative("unlisted-model", "HARNESS_ALLOWLIST", () => {
			const record = cloneRecord(first);
			(record.input.model as unknown as { id: string }).id = "unlisted.model";
			validateFixture(record);
		}),
	);
	output.push(
		expectNegative("secret-scan", "HARNESS_SECRET", () => {
			const record = cloneRecord(first);
			record.title = "AKIAABCDEFGHIJKLMNOP";
			validateFixture(record);
		}),
	);
	output.push(
		expectNegative("malformed-binary-frame", "HARNESS_BINARY", () => {
			const record = cloneRecord(records.find((candidate) => candidate.expected.binaryEventStream) ?? first);
			if (record.expected.binaryEventStream) record.expected.binaryEventStream.base64 = "@@@";
			validateFixture(record);
		}),
	);
	return output;
}

function fixturePath(id: string): string {
	return join(fixtureDir, `${id}.json`);
}

function manifestPath(): string {
	return join(fixtureDir, "manifest.json");
}

function buildManifest(records: FixtureRecord[]): unknown {
	return {
		schemaVersion,
		generatedBy: "zig/test/generate-bedrock-fixtures.ts",
		fixtureCount: records.length,
		scenarioIds: records.map((record) => record.id),
		modelIds: allowedModelIds,
		localStreamFormats: allowedLocalStreamFormats,
		comparatorMode: "semantic-request-and-stream",
		captureBoundary:
			"TypeScript Bedrock Converse request/stream snapshots after provider conversion and before live AWS SDK send",
		network: "local BedrockRuntimeClient.send mock only; no AWS metadata, credential store, or remote Bedrock access",
		allowlists: {
			scenarioIds: allowedScenarioIds,
			modelIds: allowedModelIds,
			localStreamFormats: allowedLocalStreamFormats,
			ignoredPaths: allowedIgnoredPaths,
		},
		sourceCitations,
	};
}

async function buildRecords(): Promise<FixtureRecord[]> {
	const savedEnv = {
		AWS_ACCESS_KEY_ID: process.env.AWS_ACCESS_KEY_ID,
		AWS_SECRET_ACCESS_KEY: process.env.AWS_SECRET_ACCESS_KEY,
		AWS_SESSION_TOKEN: process.env.AWS_SESSION_TOKEN,
		AWS_PROFILE: process.env.AWS_PROFILE,
		AWS_BEARER_TOKEN_BEDROCK: process.env.AWS_BEARER_TOKEN_BEDROCK,
		AWS_REGION: process.env.AWS_REGION,
		AWS_DEFAULT_REGION: process.env.AWS_DEFAULT_REGION,
		AWS_EC2_METADATA_DISABLED: process.env.AWS_EC2_METADATA_DISABLED,
		AWS_BEDROCK_SKIP_AUTH: process.env.AWS_BEDROCK_SKIP_AUTH,
	};
	Object.assign(process.env, {
		AWS_ACCESS_KEY_ID: "",
		AWS_SECRET_ACCESS_KEY: "",
		AWS_SESSION_TOKEN: "",
		AWS_PROFILE: "",
		AWS_BEARER_TOKEN_BEDROCK: "",
		AWS_REGION: "",
		AWS_DEFAULT_REGION: "",
		AWS_EC2_METADATA_DISABLED: "true",
		AWS_BEDROCK_SKIP_AUTH: "1",
	});
	try {
		const records: FixtureRecord[] = [];
		for (const scenario of scenarios) {
			records.push(await captureScenario(scenario));
		}
		validateRecords(records);
		return records;
	} finally {
		for (const [key, value] of Object.entries(savedEnv)) {
			if (value === undefined) {
				delete process.env[key];
			} else {
				process.env[key] = value;
			}
		}
	}
}

function readCurrentFixture(path: string): FixtureRecord {
	return JSON.parse(readFileSync(path, "utf8")) as FixtureRecord;
}

function checkFiles(records: FixtureRecord[]): void {
	const errors: string[] = [];
	const expectedFiles = new Set(["manifest.json", ...records.map((record) => `${record.id}.json`)]);
	for (const record of records) {
		const path = fixturePath(record.id);
		const next = stableStringify(record);
		if (!existsSync(path)) {
			errors.push(`Missing fixture ${record.id}: ${relative(scriptDir, path)}`);
			continue;
		}
		const current = readFileSync(path, "utf8");
		validateFixture(readCurrentFixture(path));
		if (current !== next) {
			errors.push(`Fixture drift for ${record.id}: ${relative(scriptDir, path)}`);
		}
	}
	const manifest = stableStringify(buildManifest(records));
	if (!existsSync(manifestPath())) {
		errors.push(`Missing Bedrock manifest: ${relative(scriptDir, manifestPath())}`);
	} else if (readFileSync(manifestPath(), "utf8") !== manifest) {
		errors.push(`Fixture drift for manifest: ${relative(scriptDir, manifestPath())}`);
	}
	if (existsSync(fixtureDir)) {
		for (const file of readdirSync(fixtureDir)) {
			if (file.endsWith(".json") && !expectedFiles.has(file)) {
				errors.push(`Unexpected Bedrock fixture file: ${relative(scriptDir, join(fixtureDir, file))}`);
			}
		}
	}
	if (errors.length > 0) {
		throw new Error(
			`Bedrock fixtures are stale. Run \`npx tsx test/generate-bedrock-fixtures.ts\`.\n${errors.join("\n")}`,
		);
	}
}

function writeFiles(records: FixtureRecord[]): void {
	mkdirSync(fixtureDir, { recursive: true });
	for (const record of records) {
		writeFileSync(fixturePath(record.id), stableStringify(record));
	}
	writeFileSync(manifestPath(), stableStringify(buildManifest(records)));
}

async function main(): Promise<void> {
	const records = await buildRecords();
	const negatives = runNegativeSuite(records);
	if (checkMode) {
		checkFiles(records);
		console.log(`Bedrock fixtures are up to date (${records.length} scenarios)`);
	} else {
		writeFiles(records);
		console.log(`Wrote ${records.length} Bedrock fixtures to ${relative(process.cwd(), fixtureDir)}`);
	}
	console.log(`Bedrock manifest/schema validation passed (${records.length} fixtures)`);
	console.log(`Bedrock negative suite passed (${negatives.join(", ")})`);
	console.log("Bedrock secret scan passed");
	console.log("Bedrock deterministic local generator used mocked BedrockRuntimeClient.send; no live AWS calls");
}

main().catch((error: unknown) => {
	const message = error instanceof Error ? error.message : String(error);
	console.error(message);
	process.exitCode = 1;
});
